import Foundation

/// Emoji used for the loading-eye reaction set on incoming user messages
/// while a dispatch is in flight. Cleared by the first content-bearing
/// reply (`reply` / `reply_photo`), by the artifact auto-forward hook,
/// or by the terminal safety net. Pinned here so tests can compare
/// against a single source.
let loadingReactionEmoji = "\u{1F440}"

// MARK: - Route Handler

/// Upper bound on accepted request bodies. Telegram Update payloads are a
/// few KB (text caps at 4096 chars; media arrives as metadata, not bytes);
/// anything near this size is hostile or corrupt.
let maxRouteBodyBytes = 1_048_576

func handleRoute(state: AgentState, agentId: String, requestJSON: String) -> String {
  guard let req = parseJSON(requestJSON, as: RouteRequest.self) else {
    logWarn("handleRoute: failed to parse request JSON (\(requestJSON.count) chars)")
    return makeRouteResponse(status: 400, body: #"{"ok":false,"description":"bad request"}"#)
  }

  logDebug("handleRoute[\(agentId)]: route_id=\(req.route_id) method=\(req.method)")

  switch req.route_id {
  case "webhook":
    if let rejection = validateWebhookRequest(req) {
      return rejection
    }
    return handleWebhook(state: state, agentId: agentId, req: req)
  default:
    logWarn("handleRoute: unknown route_id '\(req.route_id)'")
    return makeRouteResponse(status: 404, body: #"{"ok":false,"description":"not found"}"#)
  }
}

/// Method / content-type / body-size gate applied before the webhook handler
/// runs. Returns a ready-made rejection response, or nil when acceptable.
private func validateWebhookRequest(_ req: RouteRequest) -> String? {
  if req.method.uppercased() != "POST" {
    logWarn("handleRoute: method \(req.method) not allowed for webhook")
    return makeRouteResponse(
      status: 405, body: #"{"ok":false,"description":"method not allowed"}"#)
  }
  if let body = req.body, body.utf8.count > maxRouteBodyBytes {
    logWarn("handleRoute: webhook body too large (\(body.utf8.count) bytes)")
    return makeRouteResponse(
      status: 413, body: #"{"ok":false,"description":"payload too large"}"#)
  }
  if let body = req.body, !body.isEmpty {
    let contentType = headerValue(req.headers, name: "content-type") ?? ""
    if !contentType.lowercased().contains("application/json") {
      logWarn("handleRoute: unsupported webhook content type '\(contentType)'")
      return makeRouteResponse(
        status: 415, body: #"{"ok":false,"description":"unsupported media type"}"#)
    }
  }
  return nil
}

/// Case-insensitive header lookup (HTTP headers are case-insensitive but
/// the host forwards them verbatim).
private func headerValue(_ headers: [String: String]?, name: String) -> String? {
  guard let headers else { return nil }
  if let exact = headers[name] { return exact }
  let target = name.lowercased()
  for (key, value) in headers where key.lowercased() == target {
    return value
  }
  return nil
}

// MARK: - Webhook Endpoint

private func extractSecretHeader(from headers: [String: String]) -> String {
  if let v = headers["x-telegram-bot-api-secret-token"] { return v }
  if let v = headers["X-Telegram-Bot-Api-Secret-Token"] { return v }
  return ""
}

/// Hot path. Telegram retries on slow / 4xx / 5xx, so this MUST return 200
/// quickly. Any heavy lifting goes through dispatch — never await inference
/// here.
private func handleWebhook(state: AgentState, agentId: String, req: RouteRequest) -> String {
  // 1. Verify Telegram's secret header (constant-time).
  let expectedSecret = state.webhookSecret ?? configGet("webhook_secret") ?? ""
  let receivedSecret = extractSecretHeader(from: req.headers ?? [:])
  guard !expectedSecret.isEmpty,
    constantTimeEquals(expectedSecret, receivedSecret)
  else {
    logWarn("Webhook rejected: bad or missing secret token")
    return makeRouteResponse(
      status: 401, body: #"{"ok":false,"description":"bad secret"}"#)
  }

  // 2. Parse the Telegram Update. Stickers, photos, callbacks, etc. are
  //    accepted with a 200 so Telegram doesn't retry them.
  guard let body = req.body,
    let update = parseJSON(body, as: TGUpdate.self)
  else {
    logWarn("Webhook: failed to parse update body (\(req.body?.count ?? 0) chars)")
    return makeRouteResponse(status: 200, body: #"{"ok":true}"#)
  }

  // 3. Dispatch by update type. Today we handle plain `message` and
  //    `callback_query`; everything else is acked silently.
  if let cb = update.callback_query {
    return handleCallbackQuery(
      state: state, agentId: agentId,
      updateId: update.update_id, cb: cb)
  }

  guard let message = update.message else {
    logDebug("handleWebhook: non-message update_id=\(update.update_id), ignoring")
    return makeRouteResponse(status: 200, body: #"{"ok":true}"#)
  }

  return handleMessageUpdate(
    state: state, agentId: agentId,
    updateId: update.update_id, message: message)
}

/// Returns the user-visible content of the message: prefer `text` (plain
/// text message) then `caption` (caption attached to media). Empty string
/// when neither is set; callers may still proceed if media is attached.
private func messageBodyText(_ message: TGUpdate.Message) -> String {
  if let t = message.text, !t.isEmpty { return t }
  if let c = message.caption, !c.isEmpty { return c }
  return ""
}

/// True when the message carries any media attachment. Any non-text path
/// the agent should still respond to lands here.
private func messageHasMedia(_ message: TGUpdate.Message) -> Bool {
  if let p = message.photo, !p.isEmpty { return true }
  return message.document != nil || message.voice != nil
    || message.audio != nil || message.video != nil
    || message.animation != nil
}

/// Resolves the per-user identifier we use for session keying. Falls back
/// to `chat_id` when the message has no `from` (channel posts, anonymous
/// admin posts) so behaviour matches the legacy "one session per chat"
/// contract for those cases.
private func effectiveUserId(message: TGUpdate.Message) -> Int64 {
  message.from?.id ?? message.chat.id
}

/// True when the chat is `group` or `supergroup`. The mention/reply gate
/// only fires in groups — DMs always pass through.
private func isGroupChat(_ chat: TGUpdate.Chat) -> Bool {
  guard let type = chat.type else { return false }
  return type == "group" || type == "supergroup"
}

/// In groups Telegram delivers every message to bots whose privacy mode
/// is disabled. We only respond when the bot is *addressed*: by @mention,
/// by reply-to-bot, or via a slash command containing the bot's username
/// (the latter is already accepted by `isResetCommand`).
///
/// In DMs (and anything that isn't a group/supergroup) the message is
/// always considered addressed.
func shouldRespondInChat(
  message: TGUpdate.Message, botId: Int64?, botUsername: String?
) -> Bool {
  guard isGroupChat(message.chat) else { return true }

  // Reply-to-bot wins immediately. Telegram populates `reply_to_message`
  // when the user explicitly replies to one of our prior messages.
  if let botId, let replyTarget = message.reply_to_message?.from?.id,
    replyTarget == botId
  {
    return true
  }

  // Mention via @username entity. Both `entities` (text body) and
  // `caption_entities` (media caption) are valid sources.
  let allEntities = (message.entities ?? []) + (message.caption_entities ?? [])
  let body = message.text ?? message.caption ?? ""

  // text_mention entity: targets a specific user_id directly (no
  // @username substring lookup needed).
  if let botId {
    for entity in allEntities where entity.type == "text_mention" {
      if entity.user?.id == botId { return true }
    }
  }

  // mention entity: must @<our-bot-username> within the body. Compare
  // case-insensitively because users routinely type `@MyBot` even when
  // the canonical username is `mybot`. Slice via UTF-16 offsets because
  // that's what Telegram uses for entity offsets/lengths.
  if let username = botUsername, !username.isEmpty {
    let target = "@\(username)".lowercased()
    let bodyUTF16 = Array(body.utf16)
    for entity in allEntities where entity.type == "mention" {
      let start = entity.offset
      let end = entity.offset + entity.length
      guard start >= 0, end <= bodyUTF16.count, start < end else { continue }
      let slice = String(utf16CodeUnits: Array(bodyUTF16[start..<end]), count: end - start)
      if slice.lowercased() == target { return true }
    }
  }

  // Slash commands with @<bot> (e.g. `/help@MyBot some args`) are
  // explicitly addressed to us. The leading-slash check is cheap.
  if body.hasPrefix("/"), let username = botUsername, !username.isEmpty {
    let firstToken = body.split(whereSeparator: { $0.isWhitespace }).first ?? ""
    if firstToken.lowercased().hasSuffix("@\(username.lowercased())") {
      return true
    }
  }

  return false
}

private func handleMessageUpdate(
  state: AgentState, agentId: String, updateId: Int, message: TGUpdate.Message
) -> String {
  let chatId = message.chat.id
  let incomingMessageId = message.message_id

  let bodyText = messageBodyText(message)
  let hasMedia = messageHasMedia(message)
  guard !bodyText.isEmpty || hasMedia else {
    logDebug("handleMessageUpdate: empty/non-actionable message update_id=\(updateId), ignoring")
    return makeRouteResponse(status: 200, body: #"{"ok":true}"#)
  }

  // Idempotency: atomically claim the update. The claim is only marked
  // completed after processing finishes (durable dispatch or a
  // deterministic drop), so a crash/timeout mid-processing lets Telegram's
  // retry take over the stale claim instead of being dropped with 200.
  switch DatabaseManager.claimUpdate(agentId: agentId, updateId: updateId) {
  case .claimed:
    break
  case .alreadyCompleted:
    logDebug("handleMessageUpdate: duplicate update_id=\(updateId), 200 OK")
    return makeRouteResponse(status: 200, body: #"{"ok":true}"#)
  case .inFlight:
    logDebug("handleMessageUpdate: update_id=\(updateId) still in flight, asking for retry")
    return makeRouteResponse(
      status: 503, body: #"{"ok":false,"description":"update is being processed"}"#)
  }
  DatabaseManager.pruneOldSeenUpdates()
  // active_dispatches rows outlive COMPLETED (see runTerminalSafetyNet),
  // so piggy-back a TTL sweep here instead of running a background timer.
  DatabaseManager.sweepExpiredDispatches()

  // Deterministic drops below complete the claim: retrying them can never
  // change the outcome, so Telegram should stop redelivering.
  let completeAndAck: () -> String = {
    DatabaseManager.completeUpdate(agentId: agentId, updateId: updateId)
    return makeRouteResponse(status: 200, body: #"{"ok":true}"#)
  }

  // Resolve / refuse blocked chats early.
  if DatabaseManager.isChatBlocked(agentId: agentId, chatId: chatId) {
    logDebug("handleMessageUpdate: chat \(chatId) is blocked, ignoring")
    return completeAndAck()
  }

  let userId = effectiveUserId(message: message)
  let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)

  // /whoami is a plugin-owned helper that bypasses the allowlist by
  // design — denied users still get a useful response with the IDs
  // an admin needs to add them to the list. Nothing it returns leaks
  // information the user couldn't already see in any Telegram client.
  if isWhoamiCommand(trimmed) {
    handleWhoami(state: state, message: message)
    return completeAndAck()
  }

  // /start and /help are plugin-owned static-text commands. They run
  // BEFORE the allowlist gate so a denied user still gets the welcome
  // text (and can see whose ID they need to ask the admin to add).
  // Nothing about the response is sensitive.
  if let staticReply = staticCommandReply(trimmed) {
    if let token = state.botToken, !token.isEmpty {
      _ = telegramSendMessage(
        token: token, chatId: chatId, text: staticReply,
        replyToMessageId: incomingMessageId)
    }
    return completeAndAck()
  }

  // Allowlist gate (silent). Order: chat-list first (cheap set check),
  // then user-list (also a set check). Only one info-level log per
  // rejection, no Telegram reaction or deny_message — the plan
  // explicitly opted for silent drops.
  if let denial = checkAllowlist(state: state, message: message, userId: userId) {
    logInfo(denial)
    return completeAndAck()
  }

  // Upsert the per-(agent, chat, user) row so we have a salt to derive
  // the session UUID from.
  let chat = DatabaseManager.upsertChatSession(
    agentId: agentId, chatId: chatId, userId: userId)

  // Reset commands are dispatched BEFORE the group-mention gate so a
  // user in a group can run `/clear@MyBot` even when the privacy mode
  // would otherwise hide subsequent messages from us.
  if let resetVerb = parseResetCommand(trimmed) {
    handleReset(
      state: state, agentId: agentId, chatId: chatId, userId: userId,
      scope: resetVerb)
    return completeAndAck()
  }

  // Group chats: stay silent unless we're addressed. Doing this AFTER
  // dedup means duplicate retries still short-circuit cheaply, but
  // BEFORE dispatch means we don't burn agent runs on chatter.
  if !shouldRespondInChat(
    message: message, botId: state.botId,
    botUsername: state.botUsername)
  {
    logDebug(
      "handleMessageUpdate: group chat \(chatId) message not addressed to bot, ignoring "
        + "(user=\(userId))")
    return completeAndAck()
  }

  // Inbound media: bounded synchronous download (short per-file timeout,
  // cumulative per-update byte cap, wall-clock budget) so the path is
  // ready to inject into the prompt without risking a webhook stall long
  // enough for Telegram to redeliver. Failures don't abort the turn: the
  // agent is told explicitly which attachments failed instead of the
  // update silently losing its media.
  let media =
    hasMedia
    ? downloadInboundMedia(state: state, agentId: agentId, message: message)
    : InboundMediaResult()

  // Dispatch, then settle the claim based on the outcome: completed on
  // durable dispatch (or deterministic drop inside), released on
  // transient failure so Telegram's retry re-processes the update.
  switch dispatchUserTurn(
    state: state, agentId: agentId,
    chat: chat, message: message, bodyText: bodyText,
    incomingMessageId: incomingMessageId, media: media)
  {
  case .completed(let response):
    DatabaseManager.completeUpdate(agentId: agentId, updateId: updateId)
    return response
  case .transientFailure(let description):
    DatabaseManager.releaseUpdate(agentId: agentId, updateId: updateId)
    logWarn("handleMessageUpdate: transient failure (\(description)), asking Telegram to retry")
    return makeRouteResponse(
      status: 503, body: #"{"ok":false,"description":"temporarily unavailable"}"#)
  }
}

// MARK: - allowlist gate
//
// Returns nil when the message passes; returns a one-line audit log
// string (which the caller logs at info) when the message should be
// silently dropped. Per the plan: silent drops, no deny_message, no
// reaction, exactly one log line per rejection.
//
// Order of checks matches the plan's explicit ordering: chat first
// (cheaper, more selective), then user. Either non-empty allowlist on
// its own restricts the surface; both can be combined.

private func checkAllowlist(
  state: AgentState, message: TGUpdate.Message, userId: Int64
) -> String? {
  let chatId = message.chat.id

  if !state.allowedChatIds.isEmpty, !state.allowedChatIds.contains(chatId) {
    return "allowlist: chat \(chatId) not allowed"
  }

  if !state.allowedUsers.isEmpty {
    let from = message.from
    let usernameMatches: Bool
    if let name = from?.username?.lowercased(), !name.isEmpty {
      usernameMatches = state.allowedUsers.usernames.contains(name)
    } else {
      usernameMatches = false
    }
    let idMatches: Bool
    if let id = from?.id {
      idMatches = state.allowedUsers.ids.contains(id)
    } else {
      idMatches = false
    }
    if !usernameMatches && !idMatches {
      let nameTrace = from?.username.map { "@\($0)" } ?? "(no username)"
      return "allowlist: user \(userId)/\(nameTrace) not allowed in chat \(chatId)"
    }
  }
  return nil
}

/// How a user turn ended, from the claim's point of view: `completed`
/// carries the route response to return after marking the update done;
/// `transientFailure` means the claim must be released so Telegram's
/// retry can re-process the turn.
private enum TurnOutcome {
  case completed(String)
  case transientFailure(String)
}

/// Builds the dispatch payload for a user turn, pre-binds the reply token,
/// soft-interrupts the prior in-flight task for the same user, and fires
/// the dispatch. Caller is responsible for the post-dispatch loading-eye
/// reaction and for settling the update claim based on the outcome.
private func dispatchUserTurn(
  state: AgentState, agentId: String,
  chat: ChatSessionRow, message: TGUpdate.Message,
  bodyText: String, incomingMessageId: Int64,
  media: InboundMediaResult = InboundMediaResult()
) -> TurnOutcome {
  let chatId = chat.chatId
  let userId = chat.userId
  let session = sessionUUID(
    forChatId: chatId, userId: userId, salt: chat.sessionSalt)
  let replyToken = mintReplyToken()

  let displayName =
    message.from?.username ?? message.from?.first_name ?? "user"

  // The per-turn header is the highest-recency place to remind the model of
  // the reply contract. Without this, models that lean on a generic
  // "gather → complete" agent loop sometimes finish a turn after a
  // data-gathering tool without ever calling `reply`, leaving the user
  // staring at our safety-net fallback instead of the actual answer.
  //
  // In group chats the model also benefits from knowing the user's
  // message_id so it can thread its reply via `reply_to_message_id`. The
  // hint is informational; in DMs threading is unnecessary.
  var header = "[reply_token \(replyToken) from \(displayName)"
  if isGroupChat(message.chat) {
    header += " in_group reply_to_message_id=\(incomingMessageId)"
  }
  header += "] "
  if let attachmentsSegment = renderAttachmentsHeader(media.attachments) {
    header += attachmentsSegment + " "
  }
  if let failuresSegment = renderAttachmentFailuresHeader(media.failures) {
    header += failuresSegment + " "
  }
  // For media-only turns Telegram's `text` is empty; tell the agent
  // explicitly so it doesn't think it's missing context.
  let effectiveBody =
    bodyText.isEmpty
    ? "(user sent media without a text caption — describe / act on the attached file(s))"
    : bodyText
  let prompt =
    header
    + "respond by calling reply(reply_token=\"\(replyToken)\", text=...) "
    + "before ending the turn.\n\(effectiveBody)"

  // Pre-bind reply_token BEFORE calling `dispatch`. The host can
  // schedule the agent the instant dispatch returns, and a fast agent
  // can call `reply` before our INSERT lands if we don't get ahead of
  // it. The placeholder task_id is patched to the real one once
  // dispatch returns; reply lookups key on reply_token (the PK).
  let expiresAt = Int(Date().timeIntervalSince1970) + 600  // 10 minutes
  DatabaseManager.insertActiveDispatch(
    taskId: pendingTaskId(for: replyToken),
    agentId: agentId, chatId: chatId, userId: userId,
    replyToken: replyToken, sessionId: session.uuidString,
    expiresAt: expiresAt, incomingMessageId: incomingMessageId)

  // Soft-stop the previous in-flight task FOR THE SAME USER (if any). In
  // a group two parallel users typing simultaneously must NOT interrupt
  // each other — that's the whole point of per-user routing.
  if let prior = DatabaseManager.priorActiveDispatch(
    agentId: agentId, forChat: chatId, userId: userId, excluding: replyToken)
  {
    logDebug(
      "dispatchUserTurn: interrupting prior task \(prior.taskId) for "
        + "chat \(chatId) user \(userId)")
    if let interrupt = hostAPI?.pointee.dispatch_interrupt {
      prior.taskId.withCString { tid in
        bodyText.withCString { p in interrupt(tid, p) }
      }
    } else if let cancel = hostAPI?.pointee.dispatch_cancel {
      logWarn("dispatchUserTurn: dispatch_interrupt unavailable; cancelling instead")
      prior.taskId.withCString { tid in cancel(tid) }
    }
  }

  // Dispatch. Fire and forget — the agent will call our reply tools.
  //   - `tools` (v3+) explicitly requests the reply surface so an agent
  //     with manual tool selection still has it loaded.
  //   - `external_session_key` is the canonical re-attachment key on
  //     v4+ hosts (see `externalSessionKey` for the salt rationale).
  //     Per-user keying means two participants in the same group each
  //     get their own conversation.
  //   - `session_id` is the legacy UUID5 path; kept for backwards
  //     compatibility and stays in sync with `external_session_key` so
  //     either lookup resolves to the same logical conversation.
  let dispatchPayload: [String: Any] = [
    "prompt": prompt,
    "title": "Telegram \(displayName)",
    "session_id": session.uuidString,
    "external_session_key": externalSessionKey(
      chatId: chatId, userId: userId, salt: chat.sessionSalt),
    "tools": dispatchToolNames,
  ]
  guard let dispatchJSON = makeJSONString(dispatchPayload) else {
    logError("dispatchUserTurn: failed to serialize dispatch payload")
    DatabaseManager.deleteActiveDispatch(replyToken: replyToken)
    return .transientFailure("dispatch payload serialize failed")
  }

  guard let resultStr = callHostString(hostAPI?.pointee.dispatch, dispatchJSON),
    let parsed = parseJSON(resultStr, as: DispatchResponse.self)
  else {
    logError("dispatchUserTurn: dispatch unavailable or returned malformed result")
    DatabaseManager.deleteActiveDispatch(replyToken: replyToken)
    return .transientFailure("dispatch unavailable")
  }

  if let errCode = parsed.error {
    DatabaseManager.deleteActiveDispatch(replyToken: replyToken)
    if errCode == "rate_limit_exceeded" {
      // Plugin-owned meta-message: the user must hear *something*. The
      // user was told to retry, so the update counts as handled —
      // letting Telegram redeliver it would double the meta-message
      // AND eventually re-run a turn the user already re-sent.
      if let token = state.botToken {
        _ = telegramSendMessage(
          token: token, chatId: chatId,
          text: "I'm catching up on a few things. Please retry in a moment.")
      }
    } else {
      logWarn("dispatchUserTurn: dispatch failed: \(errCode)")
    }
    return .completed(makeRouteResponse(status: 200, body: #"{"ok":true}"#))
  }

  guard let taskId = parsed.id else {
    logError(
      "dispatchUserTurn: dispatch result missing id: \(String(resultStr.prefix(200)))")
    DatabaseManager.deleteActiveDispatch(replyToken: replyToken)
    return .transientFailure("dispatch result missing id")
  }

  // Patch the placeholder task_id so terminal events can resolve back
  // to the binding via lookupBindingByTask.
  DatabaseManager.updateTaskId(replyToken: replyToken, newTaskId: taskId)
  logInfo(
    "Dispatched task \(taskId) for chat \(chatId) user \(userId) (token=\(replyToken))")

  // Loading-eye: react with 👀 on the user's message so they see
  // "I'm working on it" within a heartbeat. Best-effort.
  if let token = state.botToken {
    _ = telegramSetMessageReaction(
      token: token, chatId: chatId, messageId: incomingMessageId,
      emoji: loadingReactionEmoji)
  }

  return .completed(makeRouteResponse(status: 200, body: #"{"ok":true}"#))
}

// MARK: - callback_query (inline keyboard button presses)

private func handleCallbackQuery(
  state: AgentState, agentId: String, updateId: Int,
  cb: TGUpdate.CallbackQuery
) -> String {
  // Idempotency uses the synthetic update_id Telegram already supplies.
  // Same claim-then-complete contract as message updates.
  switch DatabaseManager.claimUpdate(agentId: agentId, updateId: updateId) {
  case .claimed:
    break
  case .alreadyCompleted:
    logDebug("handleCallbackQuery: duplicate update_id=\(updateId), 200 OK")
    return makeRouteResponse(status: 200, body: #"{"ok":true}"#)
  case .inFlight:
    logDebug("handleCallbackQuery: update_id=\(updateId) still in flight, asking for retry")
    return makeRouteResponse(
      status: 503, body: #"{"ok":false,"description":"update is being processed"}"#)
  }
  DatabaseManager.pruneOldSeenUpdates()
  DatabaseManager.sweepExpiredDispatches()

  let completeAndAck: () -> String = {
    DatabaseManager.completeUpdate(agentId: agentId, updateId: updateId)
    return makeRouteResponse(status: 200, body: #"{"ok":true}"#)
  }

  // Always acknowledge the callback first so the spinner clears in
  // Telegram even if we end up dropping the event. Safe under retries —
  // answering the same callback twice is a no-op on Telegram's side.
  if let token = state.botToken, !token.isEmpty {
    _ = telegramAnswerCallbackQuery(token: token, callbackQueryId: cb.id)
  }

  guard let message = cb.message else {
    logDebug(
      "handleCallbackQuery: callback \(cb.id) has no source message; "
        + "can't route, dropping")
    return completeAndAck()
  }

  let chatId = message.chat.id
  if DatabaseManager.isChatBlocked(agentId: agentId, chatId: chatId) {
    logDebug("handleCallbackQuery: chat \(chatId) is blocked, ignoring")
    return completeAndAck()
  }

  // Use the BUTTON-PRESSER's user_id (cb.from), not the source message's
  // author. In a group it's normal for someone to press a button on a
  // bot message they didn't send.
  let userId = cb.from?.id ?? chatId
  let presserName =
    cb.from?.username ?? cb.from?.first_name ?? "user"
  let chatRow = DatabaseManager.upsertChatSession(
    agentId: agentId, chatId: chatId, userId: userId)

  // Synthesize the user turn. The bracketed marker mirrors the prompt
  // header the agent already understands — easy to spot in logs and
  // distinguishable from a freeform message.
  let data = cb.data ?? ""
  let synthetic = "[button:\(data)]"

  // Synthesize a minimal Message so dispatchUserTurn can reuse the
  // existing pipeline. We don't have a direct `message_id` for the
  // press itself; reuse the source message_id so the loading eye lands
  // on the message the user clicked (visually accurate enough).
  let synthMessage = TGUpdate.Message(
    message_id: message.message_id,
    date: nil,
    chat: message.chat,
    from: TGUpdate.From(
      id: userId, username: presserName, first_name: nil, is_bot: nil),
    text: synthetic,
    caption: nil,
    entities: nil,
    caption_entities: nil,
    reply_to_message: nil,
    photo: nil, document: nil, voice: nil, audio: nil,
    video: nil, animation: nil)

  switch dispatchUserTurn(
    state: state, agentId: agentId,
    chat: chatRow, message: synthMessage,
    bodyText: synthetic, incomingMessageId: message.message_id)
  {
  case .completed(let response):
    DatabaseManager.completeUpdate(agentId: agentId, updateId: updateId)
    return response
  case .transientFailure(let description):
    DatabaseManager.releaseUpdate(agentId: agentId, updateId: updateId)
    logWarn("handleCallbackQuery: transient failure (\(description)), asking Telegram to retry")
    return makeRouteResponse(
      status: 503, body: #"{"ok":false,"description":"temporarily unavailable"}"#)
  }
}

/// Placeholder task_id stamped on the pre-inserted row before `dispatch`
/// returns the real one. Unique because reply_tokens are; the `_pending_`
/// prefix is a debugging marker for rows that lost the dispatch race.
func pendingTaskId(for replyToken: String) -> String {
  "_pending_\(replyToken)"
}

/// Builds the host's session-re-attachment key for a Telegram chat. The
/// salt is bumped on `/reset`, so /reset cleanly partitions before and
/// after into separate sessions even though the chat_id is unchanged.
/// Format is intentionally human-readable so it shows up legibly in
/// host-side traces.
///
/// Per-user keying (since v4) means each participant in a group gets
/// their own session. In DMs `userId == chatId` so the key collapses to
/// a per-chat identifier, matching legacy behaviour.
func externalSessionKey(chatId: Int64, userId: Int64, salt: Int) -> String {
  "telegram:chat-\(chatId):user-\(userId):salt-\(salt)"
}

/// DM-style overload: `userId == chatId`.
func externalSessionKey(chatId: Int64, salt: Int) -> String {
  externalSessionKey(chatId: chatId, userId: chatId, salt: salt)
}

// MARK: - Response Builder

func makeRouteResponse(status: Int, body: String, contentType: String = "application/json")
  -> String
{
  let resp: [String: Any] = [
    "status": status,
    "headers": ["Content-Type": contentType],
    "body": body,
  ]
  return makeJSONString(resp) ?? #"{"status":500}"#
}
