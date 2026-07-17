import Foundation

// MARK: - Tool Handlers
//
// The agent owns user-visible text content. The reply surface is gated
// by an opaque `reply_token` so the agent never learns the chat_id
// (prompt injection cannot redirect outbound messages):
//
//   * `reply` / `reply_typing` / `reply_photo` (legacy, unchanged shape)
//   * `reply_document` / `reply_voice` / `reply_audio` / `reply_video`
//     — additional media surfaces, all routed by URL through the
//     `telegramSendMediaByURL` helper.
//
// Files the agent writes into the sandbox are NOT sent via a tool —
// they're auto-forwarded by `handleArtifactShare` (host hook below)
// because the agent only ever has the sandbox path, never the host
// artifact path that `host->file_read` requires.
//
// `invoke` is a synchronous C callback, but the Telegram POST goes through
// `PerChatSendActor` to preserve send order across multiple `reply` calls
// in one run. We bridge with a DispatchSemaphore so the synchronous
// callback can block briefly until the network call returns.

// MARK: - Dispatch tool surface
//
// Names of the tools the agent is allowed (and expected) to use to talk
// back to Telegram. We pass these on every dispatch via the v3+ `tools`
// field so an agent with manual / restrictive tool selection still has
// the reply surface loaded — without it, the agent would receive the
// user's message but have no way to respond.
//
// MUST stay in sync with the manifest's `capabilities.tools[].id`
// values. `ManifestTests.testToolsListIsExactlyTheReplySurface` pins the
// manifest side; `WebhookTests.testWebhookDispatchesValidTextMessage`
// pins this set on the dispatch payload.
let dispatchToolNames: [String] = [
  "reply", "reply_typing", "reply_photo",
  "reply_document", "reply_voice", "reply_audio", "reply_video",
]

// MARK: - Inline keyboard arg
//
// Telegram inline keyboards are a 2D array of buttons. The agent passes
// them through verbatim; we validate the shape, then forward as the
// `reply_markup.inline_keyboard` field. Only `text` + (`callback_data`
// XOR `url`) are supported — login URLs / web-app buttons / pay buttons
// are intentionally excluded so the surface stays small and the agent
// can't accidentally embed credentials.
private struct InlineKeyboardButton: Decodable {
  let text: String
  let callback_data: String?
  let url: String?
}

/// Pre-serializes the inline keyboard to a JSON string so it survives
/// the `Sendable` closure boundary into `PerChatSendActor`. Returns nil
/// for an absent / empty keyboard so the caller can skip the field.
private func encodeInlineKeyboardJSON(
  _ rows: [[InlineKeyboardButton]]?
) -> String? {
  guard let rows, !rows.isEmpty else { return nil }
  let encoded: [[[String: Any]]] = rows.map { row in
    row.map { btn -> [String: Any] in
      var dict: [String: Any] = ["text": String(btn.text.prefix(64))]
      if let cb = btn.callback_data, !cb.isEmpty {
        // Telegram caps callback_data at 64 bytes UTF-8.
        dict["callback_data"] = String(cb.prefix(64))
      } else if let url = btn.url, !url.isEmpty {
        dict["url"] = url
      }
      return dict
    }
  }
  let payload: [String: Any] = ["inline_keyboard": encoded]
  return makeJSONString(payload)
}

// MARK: - Argument types

private struct ReplyArgs: Decodable {
  let reply_token: String
  let text: String
  let parse_mode: String?
  let reply_to_message_id: Int64?
  let inline_keyboard: [[InlineKeyboardButton]]?
}

private struct ReplyTypingArgs: Decodable {
  let reply_token: String
}

private struct ReplyPhotoArgs: Decodable {
  let reply_token: String
  let photo_url: String
  let caption: String?
  let reply_to_message_id: Int64?
}

private struct ReplyDocumentArgs: Decodable {
  let reply_token: String
  let document_url: String
  let caption: String?
  let reply_to_message_id: Int64?
}

private struct ReplyVoiceArgs: Decodable {
  let reply_token: String
  let voice_url: String
  let caption: String?
  let reply_to_message_id: Int64?
}

private struct ReplyAudioArgs: Decodable {
  let reply_token: String
  let audio_url: String
  let caption: String?
  let reply_to_message_id: Int64?
}

private struct ReplyVideoArgs: Decodable {
  let reply_token: String
  let video_url: String
  let caption: String?
  let reply_to_message_id: Int64?
}

// MARK: - reply

func handleReply(state: AgentState, payload: String) -> String {
  runReplyTool(
    state: state, payload: payload,
    invalidArgsMessage: "reply requires reply_token and text"
  ) { (args: ReplyArgs, token, binding) in
    let clamped = String(args.text.prefix(4000))
    let parseMode = args.parse_mode
    let replyTo = args.reply_to_message_id
    let markupJSON = encodeInlineKeyboardJSON(args.inline_keyboard)
    return ReplyAction(
      action: {
        telegramSendMessage(
          token: token, chatId: binding.chatId,
          text: clamped, parseMode: parseMode,
          replyToMessageId: replyTo, replyMarkupJSON: markupJSON)
      },
      successMarksReplied: true,
      successSummary: "Sent message to user."
    )
  }
}

// MARK: - reply_typing

/// Upper bound on the in-tool 429 backoff for `reply_typing`. Typing
/// indicators are worthless once stale, so waiting longer than a couple
/// of seconds inside the (synchronous) tool call is worse than failing.
let replyTypingMaxBackoffSeconds = 2

/// `sendChatAction` is the one reply surface where a duplicate send is
/// literally impossible to observe (the typing indicator is idempotent
/// state, not a message), so a bounded in-place retry on 429 is safe.
/// One retry, capped backoff — content-bearing tools must NOT get this
/// treatment because a retry after an ambiguous failure could double-post.
func handleReplyTyping(state: AgentState, payload: String) -> String {
  runReplyTool(
    state: state, payload: payload,
    invalidArgsMessage: "reply_typing requires reply_token"
  ) { (_: ReplyTypingArgs, token, binding) in
    ReplyAction(
      action: {
        let first = telegramSendChatAction(token: token, chatId: binding.chatId)
        guard !first.ok, let retryAfter = first.retryAfter else { return first }
        let backoff = min(retryAfter, replyTypingMaxBackoffSeconds)
        if backoff > 0 {
          Thread.sleep(forTimeInterval: TimeInterval(backoff))
        }
        return telegramSendChatAction(token: token, chatId: binding.chatId)
      },
      successMarksReplied: false,
      successSummary: nil
    )
  }
}

// MARK: - reply_photo

func handleReplyPhoto(state: AgentState, payload: String) -> String {
  runReplyTool(
    state: state, payload: payload,
    invalidArgsMessage: "reply_photo requires reply_token and photo_url"
  ) { (args: ReplyPhotoArgs, token, binding) in
    let photoURL = args.photo_url
    let caption = args.caption
    let replyTo = args.reply_to_message_id
    return ReplyAction(
      action: {
        telegramSendPhotoByURL(
          token: token, chatId: binding.chatId,
          photoURL: photoURL, caption: caption,
          replyToMessageId: replyTo)
      },
      successMarksReplied: true,
      successSummary: "Sent photo to user."
    )
  }
}

// MARK: - reply_document / reply_voice / reply_audio / reply_video
//
// All four follow the same shape: a public URL plus optional caption,
// routed through `telegramSendMediaByURL` (Telegram accepts a URL string
// in the media field for every Bot-API send method we use here, just
// like `sendPhoto`). The reply token + chat_id resolution + send-order
// serialization lives in `runReplyTool` — these handlers just pick the
// API method and the JSON field name.

func handleReplyDocument(state: AgentState, payload: String) -> String {
  runReplyTool(
    state: state, payload: payload,
    invalidArgsMessage: "reply_document requires reply_token and document_url"
  ) { (args: ReplyDocumentArgs, token, binding) in
    return ReplyAction(
      action: {
        telegramSendMediaByURL(
          token: token, method: "sendDocument", mediaField: "document",
          chatId: binding.chatId, mediaURL: args.document_url,
          caption: args.caption, replyToMessageId: args.reply_to_message_id)
      },
      successMarksReplied: true,
      successSummary: "Sent document to user."
    )
  }
}

func handleReplyVoice(state: AgentState, payload: String) -> String {
  runReplyTool(
    state: state, payload: payload,
    invalidArgsMessage: "reply_voice requires reply_token and voice_url"
  ) { (args: ReplyVoiceArgs, token, binding) in
    return ReplyAction(
      action: {
        telegramSendMediaByURL(
          token: token, method: "sendVoice", mediaField: "voice",
          chatId: binding.chatId, mediaURL: args.voice_url,
          caption: args.caption, replyToMessageId: args.reply_to_message_id)
      },
      successMarksReplied: true,
      successSummary: "Sent voice note to user."
    )
  }
}

func handleReplyAudio(state: AgentState, payload: String) -> String {
  runReplyTool(
    state: state, payload: payload,
    invalidArgsMessage: "reply_audio requires reply_token and audio_url"
  ) { (args: ReplyAudioArgs, token, binding) in
    return ReplyAction(
      action: {
        telegramSendMediaByURL(
          token: token, method: "sendAudio", mediaField: "audio",
          chatId: binding.chatId, mediaURL: args.audio_url,
          caption: args.caption, replyToMessageId: args.reply_to_message_id)
      },
      successMarksReplied: true,
      successSummary: "Sent audio to user."
    )
  }
}

func handleReplyVideo(state: AgentState, payload: String) -> String {
  runReplyTool(
    state: state, payload: payload,
    invalidArgsMessage: "reply_video requires reply_token and video_url"
  ) { (args: ReplyVideoArgs, token, binding) in
    return ReplyAction(
      action: {
        telegramSendMediaByURL(
          token: token, method: "sendVideo", mediaField: "video",
          chatId: binding.chatId, mediaURL: args.video_url,
          caption: args.caption, replyToMessageId: args.reply_to_message_id)
      },
      successMarksReplied: true,
      successSummary: "Sent video to user."
    )
  }
}

// MARK: - artifact share (host hook)
//
// `invoke(type: "artifact", id: "share", payload)` is fired by the host
// whenever an agent writes a file under `~/.osaurus/artifacts/`. The
// payload carries no chat or task identifier, so we route to "the chat
// the agent is currently working on" — i.e. the latest in-flight
// dispatch row for the agent.
//
// Logs use a stable `artifact-share:` prefix so they're grep-able in
// Insights. Per-step trace lines are debug; the final outcome (and any
// failure) is info/warn so the timeline stays readable in production.

func handleArtifactShare(state: AgentState, payload: String) -> String {
  state.log(.debug, "artifact-share: received payload_size=\(payload.count)")

  guard let artifact = parseJSON(payload, as: ArtifactPayload.self) else {
    let preview = String(payload.prefix(512))
    return artifactSkip(state, reason: "bad_payload", level: .warn, detail: "raw=\(preview)")
  }

  state.log(
    .debug,
    "artifact-share: parsed filename=\(artifact.filename) "
      + "host_path=\(artifact.host_path) "
      + "mime=\(artifact.mime_type ?? "<nil>") "
      + "is_dir=\(artifact.is_directory ?? false)")

  if artifact.is_directory == true {
    return artifactSkip(
      state, reason: "directory", level: .debug,
      detail: "filename=\(artifact.filename)")
  }

  // Idempotency: the host file watcher can re-fire `invoke(type: "artifact")`
  // for the same `host_path` (e.g. moves, atomic renames). First call wins.
  if state.claimArtifactUpload(artifact.host_path) {
    return artifactSkip(
      state, reason: "already_uploaded", level: .debug,
      detail: "host_path=\(artifact.host_path)")
  }

  guard let binding = DatabaseManager.latestActiveDispatch(agentId: state.agentId) else {
    // No turn in flight for this agent — there's no obvious chat to
    // send the file to. The agent must have generated it outside any
    // user-triggered turn (e.g. background work).
    return artifactSkip(
      state, reason: "no_active_chat", level: .info,
      detail: "filename=\(artifact.filename)")
  }

  guard let token = state.botToken, !token.isEmpty else {
    return artifactSkip(state, reason: "not_configured", level: .warn)
  }

  let file: HostFileResult
  switch readHostFile(path: artifact.host_path) {
  case .success(let f):
    file = f
  case .failure(let err):
    return artifactSkip(
      state, reason: "read_failed", level: .warn,
      detail: "host_path=\(artifact.host_path) error=\(err)")
  }

  // Trust the host's MIME hint when available; fall back to the one
  // file_read returned, which itself defaults to application/octet-stream.
  let mimeType = artifact.mime_type ?? file.mimeType
  let isPhoto = mimeType.hasPrefix("image/") && !mimeType.lowercased().contains("svg")
  let method = isPhoto ? "sendPhoto" : "sendDocument"

  let chatId = binding.chatId
  let agentId = state.agentId
  let filename = artifact.filename
  let bytes = file.data

  let response = runOnSendActor(agentId: agentId, chatId: chatId) {
    if isPhoto {
      return telegramSendPhoto(
        token: token, chatId: chatId,
        fileData: bytes, filename: filename, caption: nil)
    }
    return telegramSendDocument(
      token: token, chatId: chatId,
      fileData: bytes, filename: filename,
      mimeType: mimeType, caption: nil)
  }

  if !response.ok {
    return artifactSkip(
      state, reason: "telegram_failed", level: .warn,
      detail: "filename=\(filename) chat=\(chatId) error=\(response.description)")
  }

  // The file IS the reply — flip has_replied so the safety net at
  // task-completion doesn't post a duplicate "I'm done" text.
  let isFirstContentReply = binding.hasReplied == 0
  DatabaseManager.markReplied(taskId: binding.taskId)
  if isFirstContentReply {
    clearLoadingReaction(state: state, binding: binding)
  }

  state.log(
    .info,
    "artifact-share: uploaded filename=\(filename) size=\(bytes.count) "
      + "mime=\(mimeType) method=\(method) chat=\(chatId) task=\(binding.taskId)")
  return makeJSONString(["uploaded": true]) ?? #"{"uploaded":true}"#
}

/// Logs a `skipped reason=...` line at the requested level and returns
/// the matching `{"skipped":true,"reason":...}` envelope. Optional
/// `detail` is appended after the reason to keep all skip-path log lines
/// consistent.
private func artifactSkip(
  _ state: AgentState, reason: String, level: LogLevel, detail: String? = nil
) -> String {
  var line = "artifact-share: skipped reason=\(reason)"
  if let detail, !detail.isEmpty { line += " " + detail }
  state.log(level, line)
  return makeJSONString(["skipped": true, "reason": reason])
    ?? #"{"skipped":true,"reason":"internal"}"#
}

// MARK: - Shared reply pipeline
//
// Every reply tool follows the same shape:
//   1. parse args
//   2. validate the binding (token expiry / blocked chat / agent ownership)
//   3. require a configured bot token
//   4. run the Telegram POST through the per-(agent,chat) send actor
//   5. on success, optionally mark the dispatch as having replied
//   6. on failure, special-case "bot was blocked" so the agent stops trying
// This helper captures that flow once.

private struct ReplyAction {
  /// Called inside the per-chat actor. Must be self-contained.
  let action: @Sendable () -> TGSendOutcome
  /// True when the action carries user-visible content (reply, reply_photo).
  /// The typing-indicator does not flip the safety-net flag.
  let successMarksReplied: Bool
  /// Optional human-readable summary inserted into the success envelope.
  let successSummary: String?
}

/// Captures the parse → validate → send → mark pipeline shared by all
/// reply tools.
private func runReplyTool<Args: Decodable>(
  state: AgentState,
  payload: String,
  invalidArgsMessage: String,
  build: (Args, _ botToken: String, _ binding: ActiveDispatchRow) -> ReplyAction
) -> String {
  guard let args = parseJSON(payload, as: Args.self) else {
    return Envelope.failure(.invalidArgs, invalidArgsMessage)
  }

  // Pull the reply_token off the args without forcing every caller to
  // re-extract it. Decoded structs always carry it as `reply_token`.
  guard let replyToken = readReplyToken(from: args), !replyToken.isEmpty else {
    return Envelope.failure(.invalidArgs, "missing reply_token")
  }

  let binding: ActiveDispatchRow
  switch validateBinding(state: state, token: replyToken) {
  case .reject(let envelope):
    return envelope
  case .ok(let row):
    binding = row
  }

  guard let token = state.botToken, !token.isEmpty else {
    return Envelope.failure(.unavailable, "Bot token not configured.")
  }

  let plan = build(args, token, binding)
  // Snapshot whether this is the first content-bearing reply BEFORE the
  // send (which can flip has_replied). Used after a successful send to
  // decide whether to clear the loading 👀 reaction.
  let isFirstContentReply = plan.successMarksReplied && binding.hasReplied == 0
  let response = runOnSendActor(
    agentId: state.agentId, chatId: binding.chatId, plan.action)

  if response.ok {
    if plan.successMarksReplied {
      DatabaseManager.markReplied(taskId: binding.taskId)
    }
    if isFirstContentReply {
      clearLoadingReaction(state: state, binding: binding)
    }
    return toolEnvelopeSuccess(["sent": true], summary: plan.successSummary)
  }
  return mapTelegramFailure(
    state: state, response.description, binding: binding,
    retryAfter: response.retryAfter)
}

/// Clears the loading 👀 reaction set by the webhook handler. Routed
/// through `PerChatSendActor` so the clear arrives at Telegram strictly
/// after the content message that just landed (otherwise a fast clear
/// could race the slower sendMessage and the eye would briefly reappear).
/// Safe to call when no reaction was ever set — the helper short-circuits
/// when `incomingMessageId == 0`.
func clearLoadingReaction(state: AgentState, binding: ActiveDispatchRow) {
  guard binding.incomingMessageId > 0,
    let token = state.botToken, !token.isEmpty
  else { return }
  let chatId = binding.chatId
  let messageId = binding.incomingMessageId
  _ = runOnSendActor(
    agentId: state.agentId, chatId: chatId
  ) {
    telegramSetMessageReaction(
      token: token, chatId: chatId, messageId: messageId, emoji: nil)
  }
}

// MARK: - Validation + failure mapping

/// Outcome of `validateBinding`. The reject case carries a fully-formed tool
/// envelope so the call site stays flat — no second layer of error mapping.
private enum BindingResult {
  case ok(ActiveDispatchRow)
  case reject(String)
}

/// Validates the reply_token can be acted on by `state`. Every rejection
/// returns the same opaque `stale_token` envelope to the agent (so a
/// malicious peer can't probe ours) but logs a distinguishable reason for
/// operators reading Insights. Tokens are opaque 8-char randoms with no
/// chat info encoded — safe to include in the log line.
private func validateBinding(state: AgentState, token: String) -> BindingResult {
  guard let binding = DatabaseManager.lookupBinding(token: token) else {
    return rejectStale(state: state, token: token, reason: "no binding")
  }
  if binding.agentId != state.agentId {
    return rejectStale(
      state: state, token: token,
      reason: "agent_id mismatch (binding=\(binding.agentId) caller=\(state.agentId))")
  }
  let now = Int(Date().timeIntervalSince1970)
  if binding.expiresAt <= now {
    return rejectStale(
      state: state, token: token,
      reason: "expired (expires_at=\(binding.expiresAt) now=\(now))")
  }
  if DatabaseManager.isChatBlocked(agentId: state.agentId, chatId: binding.chatId) {
    // Permanent for this chat — the agent should stop retrying.
    return .reject(Envelope.failure(.executionError, "User has blocked the bot.", retryable: false))
  }
  return .ok(binding)
}

private func rejectStale(state: AgentState, token: String, reason: String) -> BindingResult {
  state.log(.warn, "reply rejected: stale_token (\(reason)) token=\(token)")
  return .reject(staleTokenEnvelope)
}

private let staleTokenEnvelope = Envelope.failure(
  .notFound,
  "Reply token expired or unknown. End the turn — a new token will arrive on the next user message."
)

/// Translates a Telegram failure description into a tool envelope, with
/// special handling for "bot was blocked by the user": flag the chat
/// blocked, cancel the running task, and surface `chat_blocked` in-band so
/// the agent stops trying.
///
/// `retryAfter` (Telegram's 429 `parameters.retry_after`, seconds) is
/// surfaced in the envelope's `data` so the agent's retry policy can wait
/// the right amount instead of hammering the API.
private func mapTelegramFailure(
  state: AgentState, _ description: String, binding: ActiveDispatchRow,
  retryAfter: Int? = nil
) -> String {
  if description.lowercased().contains("bot was blocked") {
    DatabaseManager.markChatBlocked(agentId: state.agentId, chatId: binding.chatId)
    binding.taskId.withCString { hostAPI?.pointee.dispatch_cancel?($0) }
    // Blocked is permanent for this chat — don't ask the agent to retry.
    return Envelope.failure(.executionError, description, retryable: false)
  }
  let data: [String: Any]? = retryAfter.map { ["retry_after": $0] }
  return Envelope.failure(.executionError, description, data: data)
}

/// All tool arg structs name the field `reply_token`. Reflect once to pull
/// it out so the generic `runReplyTool` doesn't need a protocol indirection.
private func readReplyToken<Args>(from args: Args) -> String? {
  let mirror = Mirror(reflecting: args)
  for child in mirror.children where child.label == "reply_token" {
    return child.value as? String
  }
  return nil
}

// MARK: - Sync ↔ async bridge
//
// The C `invoke` callback is synchronous, but `PerChatSendActor` enforces
// send order via `await`. Bridge with a semaphore: spawn a Task that hits
// the actor, signal back, and block until it completes. Network timeout
// already caps total wait (telegramRequest uses 10s).

func runOnSendActor(
  agentId: String,
  chatId: Int64,
  _ work: @Sendable @escaping () -> TGSendOutcome
) -> TGSendOutcome {
  let semaphore = DispatchSemaphore(value: 0)
  let box = ResultBox<TGSendOutcome>()

  Task {
    box.value = await PerChatSendActor.shared.send(
      agentId: agentId, chatId: chatId, work)
    semaphore.signal()
  }

  semaphore.wait()
  return box.value ?? TGSendOutcome(ok: false, description: "internal: actor result missing")
}

/// One-shot value transfer across the Task ↔ semaphore boundary.
/// Safety: the wait/signal pair on the semaphore establishes
/// happens-before, so a single write before signal and a single read after
/// wait are race-free without an additional lock.
private final class ResultBox<T>: @unchecked Sendable {
  var value: T?
}
