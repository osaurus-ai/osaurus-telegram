import Foundation

// MARK: - Dispatch tool surface
//
// Names of the tools the agent is allowed (and expected) to use to talk
// back to Telegram. We pass these on every dispatch via the v3+ `tools`
// field so an agent with manual / restrictive tool selection still has
// the reply surface loaded — without it, the agent would receive the
// user's message but have no way to respond.
//
// MUST stay in sync with the manifest's `capabilities.tools[].id`
// values. `ManifestTests.testToolsListIsExactlyReplyReplyTypingReplyPhoto`
// pins the manifest side; `WebhookTests.testWebhookDispatchesValidTextMessage`
// pins this set on the dispatch payload.
let dispatchToolNames: [String] = ["reply", "reply_typing", "reply_photo"]

// MARK: - Route Handler

func handleRoute(state: AgentState, agentId: String, requestJSON: String) -> String {
  guard let req = parseJSON(requestJSON, as: RouteRequest.self) else {
    logWarn("handleRoute: failed to parse request JSON (\(requestJSON.count) chars)")
    return makeRouteResponse(status: 400, body: #"{"ok":false,"description":"bad request"}"#)
  }

  logDebug("handleRoute[\(agentId)]: route_id=\(req.route_id) method=\(req.method)")

  switch req.route_id {
  case "webhook":
    return handleWebhook(state: state, agentId: agentId, req: req)
  default:
    logWarn("handleRoute: unknown route_id '\(req.route_id)'")
    return makeRouteResponse(status: 404, body: #"{"ok":false,"description":"not found"}"#)
  }
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

  guard let message = update.message,
    let text = message.text, !text.isEmpty
  else {
    logDebug("handleWebhook: non-text update_id=\(update.update_id), ignoring")
    return makeRouteResponse(status: 200, body: #"{"ok":true}"#)
  }

  let chatId = message.chat.id

  // 3. Idempotency: drop duplicate Telegram retries.
  if DatabaseManager.isUpdateAlreadySeen(agentId: agentId, updateId: update.update_id) {
    logDebug("handleWebhook: duplicate update_id=\(update.update_id), 200 OK")
    return makeRouteResponse(status: 200, body: #"{"ok":true}"#)
  }
  DatabaseManager.markUpdateSeen(agentId: agentId, updateId: update.update_id)
  DatabaseManager.pruneOldSeenUpdates()
  // active_dispatches rows outlive COMPLETED (see runTerminalSafetyNet),
  // so piggy-back a TTL sweep here instead of running a background timer.
  DatabaseManager.sweepExpiredDispatches()

  // 4. Resolve / create chat row. Skip if blocked.
  let chat = DatabaseManager.upsertChatSession(agentId: agentId, chatId: chatId)
  if chat.blocked == 1 {
    logDebug("handleWebhook: chat \(chatId) is blocked, ignoring")
    return makeRouteResponse(status: 200, body: #"{"ok":true}"#)
  }

  // 5. Handle reset commands inline before dispatching. Telegram appends
  //    `@botname` to commands sent in group chats — `/clear@MyBot` should
  //    behave identically to `/clear`. We also accept `/reset` as a
  //    historical alias.
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  if isResetCommand(trimmed) {
    handleReset(state: state, agentId: agentId, chatId: chatId)
    return makeRouteResponse(status: 200, body: #"{"ok":true}"#)
  }

  // 6. Build session id (deterministic per chat+salt) and a reply token.
  let session = sessionUUID(forChatId: chatId, salt: chat.sessionSalt)
  let replyToken = mintReplyToken()

  let displayName =
    message.from?.username ?? message.from?.first_name ?? "user"
  // The per-turn header is the highest-recency place to remind the model of
  // the reply contract. Without this, models that lean on a generic
  // "gather → complete" agent loop sometimes finish a turn after a
  // data-gathering tool without ever calling `reply`, leaving the user
  // staring at our safety-net fallback instead of the actual answer.
  let prompt =
    "[reply_token \(replyToken) from \(displayName)] "
    + "respond by calling reply(reply_token=\"\(replyToken)\", text=...) "
    + "before ending the turn.\n\(text)"

  // 7. Pre-bind reply_token BEFORE calling `dispatch`. The host can
  //    schedule the agent the instant dispatch returns, and a fast agent
  //    can call `reply` before our INSERT lands if we don't get ahead of
  //    it. The placeholder task_id is patched to the real one once
  //    dispatch returns; reply lookups key on reply_token (the PK).
  let expiresAt = Int(Date().timeIntervalSince1970) + 600  // 10 minutes
  DatabaseManager.insertActiveDispatch(
    taskId: pendingTaskId(for: replyToken),
    agentId: agentId, chatId: chatId,
    replyToken: replyToken, sessionId: session.uuidString,
    expiresAt: expiresAt)

  // 8. Soft-stop the previous in-flight task for this chat (if any) so
  //    the host doesn't keep burning tokens on an answer the user has
  //    already moved past. We DO NOT delete its row — its own terminal
  //    event handles that. `priorActiveDispatch` filters out our just-
  //    inserted row so we never interrupt ourselves.
  if let prior = DatabaseManager.priorActiveDispatch(
    agentId: agentId, forChat: chatId, excluding: replyToken)
  {
    logDebug("handleWebhook: interrupting prior task \(prior.taskId) for chat \(chatId)")
    if let interrupt = hostAPI?.pointee.dispatch_interrupt {
      prior.taskId.withCString { tid in
        text.withCString { p in interrupt(tid, p) }
      }
    } else if let cancel = hostAPI?.pointee.dispatch_cancel {
      logWarn("handleWebhook: dispatch_interrupt unavailable; cancelling instead")
      prior.taskId.withCString { tid in cancel(tid) }
    }
  }

  // 9. Dispatch. Fire and forget — the agent will call our reply tools.
  //    `tools` (v3+) explicitly requests the reply surface so an agent
  //    with manual tool selection still has it loaded. `session_id` is
  //    a deterministic UUID5 per chat; the host uses it as the external
  //    grouping key so repeated turns reattach to the same session row.
  let dispatchPayload: [String: Any] = [
    "prompt": prompt,
    "title": "Telegram \(displayName)",
    "session_id": session.uuidString,
    "tools": dispatchToolNames,
  ]
  guard let dispatchJSON = makeJSONString(dispatchPayload) else {
    logError("handleWebhook: failed to serialize dispatch payload")
    DatabaseManager.deleteActiveDispatch(replyToken: replyToken)
    return makeRouteResponse(status: 200, body: #"{"ok":true}"#)
  }

  guard let resultStr = callHostString(hostAPI?.pointee.dispatch, dispatchJSON),
    let parsed = parseJSON(resultStr, as: DispatchResponse.self)
  else {
    logError("handleWebhook: dispatch unavailable or returned malformed result")
    DatabaseManager.deleteActiveDispatch(replyToken: replyToken)
    return makeRouteResponse(status: 200, body: #"{"ok":true}"#)
  }

  if let errCode = parsed.error {
    DatabaseManager.deleteActiveDispatch(replyToken: replyToken)
    if errCode == "rate_limit_exceeded" {
      // Plugin-owned meta-message: the user must hear *something*.
      if let token = state.botToken {
        _ = telegramSendMessage(
          token: token, chatId: chatId,
          text: "I'm catching up on a few things. Please retry in a moment.")
      }
    } else {
      logWarn("handleWebhook: dispatch failed: \(errCode)")
    }
    return makeRouteResponse(status: 200, body: #"{"ok":true}"#)
  }

  guard let taskId = parsed.id else {
    logError("handleWebhook: dispatch result missing id: \(String(resultStr.prefix(200)))")
    DatabaseManager.deleteActiveDispatch(replyToken: replyToken)
    return makeRouteResponse(status: 200, body: #"{"ok":true}"#)
  }

  // 10. Patch the placeholder task_id so terminal events can resolve back
  //     to the binding via lookupBindingByTask.
  DatabaseManager.updateTaskId(replyToken: replyToken, newTaskId: taskId)
  logInfo("Dispatched task \(taskId) for chat \(chatId) (token=\(replyToken))")

  return makeRouteResponse(status: 200, body: #"{"ok":true}"#)
}

/// Placeholder task_id stamped on the pre-inserted row before `dispatch`
/// returns the real one. Unique because reply_tokens are; the `_pending_`
/// prefix is a debugging marker for rows that lost the dispatch race.
func pendingTaskId(for replyToken: String) -> String {
  "_pending_\(replyToken)"
}

// MARK: - reset commands

/// Verbs the user can send to bump the chat's session salt. Compared
/// case-insensitively after stripping the `/` prefix and any
/// `@botname` suffix Telegram appends in group chats.
private let resetCommandVerbs: Set<String> = ["reset", "clear", "new", "restart"]

/// True when `text` (already trimmed of surrounding whitespace) is one
/// of the documented reset commands. Handles `/clear`, `/clear@MyBot`,
/// `/CLEAR`, etc. uniformly.
func isResetCommand(_ text: String) -> Bool {
  guard text.hasPrefix("/") else { return false }
  // Drop the leading slash, then lop off Telegram's `@botname` suffix
  // (only present in group chats; harmless to strip in DMs since `@`
  // isn't valid inside a command verb).
  var verb = Substring(text.dropFirst())
  if let at = verb.firstIndex(of: "@") { verb = verb[..<at] }
  // Reject anything with embedded whitespace ("/clear now" is a chat
  // message, not a command).
  guard !verb.contains(where: { $0.isWhitespace }) else { return false }
  return resetCommandVerbs.contains(verb.lowercased())
}

private func handleReset(state: AgentState, agentId: String, chatId: Int64) {
  logDebug("handleReset: chat \(chatId)")
  DatabaseManager.bumpSessionSalt(agentId: agentId, chatId: chatId)

  // v3 allows multiple in-flight rows per chat; /reset means "wipe
  // everything for this chat", so cancel and delete each one. Any
  // terminal events that fire afterwards no-op (binding lookup misses).
  for active in DatabaseManager.allActiveDispatches(agentId: agentId, forChat: chatId) {
    active.taskId.withCString { tid in
      hostAPI?.pointee.dispatch_cancel?(tid)
    }
    DatabaseManager.deleteActiveDispatch(taskId: active.taskId)
  }

  if let token = state.botToken {
    _ = telegramSendMessage(token: token, chatId: chatId, text: "Conversation reset.")
  }
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
