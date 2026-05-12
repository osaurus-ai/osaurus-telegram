import Foundation

// MARK: - Tool Handlers
//
// The agent owns user-visible text content. These three tools (`reply`,
// `reply_typing`, `reply_photo`) are the agent-driven delivery path,
// gated by an opaque `reply_token` so the agent never learns the
// chat_id (prompt injection cannot redirect outbound messages).
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

// MARK: - Argument types

private struct ReplyArgs: Decodable {
  let reply_token: String
  let text: String
  let parse_mode: String?
}

private struct ReplyTypingArgs: Decodable {
  let reply_token: String
}

private struct ReplyPhotoArgs: Decodable {
  let reply_token: String
  let photo_url: String
  let caption: String?
}

// MARK: - reply

func handleReply(state: AgentState, payload: String) -> String {
  runReplyTool(
    state: state, payload: payload,
    invalidArgsMessage: "reply requires reply_token and text"
  ) { (args: ReplyArgs, token, binding) in
    let clamped = String(args.text.prefix(4000))
    let parseMode = args.parse_mode
    return ReplyAction(
      action: {
        telegramSendMessage(
          token: token, chatId: binding.chatId,
          text: clamped, parseMode: parseMode)
      },
      successMarksReplied: true,
      successSummary: "Sent message to user."
    )
  }
}

// MARK: - reply_typing

func handleReplyTyping(state: AgentState, payload: String) -> String {
  runReplyTool(
    state: state, payload: payload,
    invalidArgsMessage: "reply_typing requires reply_token"
  ) { (_: ReplyTypingArgs, token, binding) in
    ReplyAction(
      action: { telegramSendChatAction(token: token, chatId: binding.chatId) },
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
    return ReplyAction(
      action: {
        telegramSendPhotoByURL(
          token: token, chatId: binding.chatId,
          photoURL: photoURL, caption: caption)
      },
      successMarksReplied: true,
      successSummary: "Sent photo to user."
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
    // Truncate so a giant payload doesn't blow up Insights.
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
// All three tools share the same shape:
//   1. parse args
//   2. validate the binding (token expiry / blocked chat / agent ownership)
//   3. require a configured bot token
//   4. run the Telegram POST through the per-(agent,chat) send actor
//   5. on success, optionally mark the dispatch as having replied
//   6. on failure, special-case "bot was blocked" so the agent stops trying
// This helper captures that flow once.

private struct ReplyAction {
  /// Called inside the per-chat actor. Must be self-contained.
  let action: @Sendable () -> (ok: Bool, description: String)
  /// True when the action carries user-visible content (reply, reply_photo).
  /// The typing-indicator does not flip the safety-net flag.
  let successMarksReplied: Bool
  /// Optional human-readable summary inserted into the success envelope.
  let successSummary: String?
}

/// Captures the parse → validate → send → mark pipeline shared by all
/// three reply tools.
private func runReplyTool<Args: Decodable>(
  state: AgentState,
  payload: String,
  invalidArgsMessage: String,
  build: (Args, _ botToken: String, _ binding: ActiveDispatchRow) -> ReplyAction
) -> String {
  guard let args = parseJSON(payload, as: Args.self) else {
    return toolEnvelopeError("invalid_request", invalidArgsMessage)
  }

  // Pull the reply_token off the args without forcing every caller to
  // re-extract it. Decoded structs always carry it as `reply_token`.
  guard let replyToken = readReplyToken(from: args) else {
    return toolEnvelopeError("invalid_request", "missing reply_token")
  }

  let binding: ActiveDispatchRow
  switch validateBinding(state: state, token: replyToken) {
  case .reject(let envelope):
    return envelope
  case .ok(let row):
    binding = row
  }

  guard let token = state.botToken, !token.isEmpty else {
    return toolEnvelopeError("not_configured", "Bot token not configured.")
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
  return mapTelegramFailure(state: state, response.description, binding: binding)
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
    return .reject(toolEnvelopeError("chat_blocked", "User has blocked the bot."))
  }
  return .ok(binding)
}

private func rejectStale(state: AgentState, token: String, reason: String) -> BindingResult {
  state.log(.warn, "reply rejected: stale_token (\(reason)) token=\(token)")
  return .reject(staleTokenEnvelope)
}

private let staleTokenEnvelope = toolEnvelopeError(
  "stale_token",
  "Reply token expired or unknown. End the turn — a new token will arrive on the next user message."
)

/// Translates a Telegram failure description into a tool envelope, with
/// special handling for "bot was blocked by the user": flag the chat
/// blocked, cancel the running task, and surface `chat_blocked` in-band so
/// the agent stops trying.
private func mapTelegramFailure(
  state: AgentState, _ description: String, binding: ActiveDispatchRow
) -> String {
  if description.lowercased().contains("bot was blocked") {
    DatabaseManager.markChatBlocked(agentId: state.agentId, chatId: binding.chatId)
    binding.taskId.withCString { hostAPI?.pointee.dispatch_cancel?($0) }
    return toolEnvelopeError("chat_blocked", description)
  }
  return toolEnvelopeError("telegram_api_error", description)
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
  _ work: @Sendable @escaping () -> (ok: Bool, description: String)
) -> (ok: Bool, description: String) {
  let semaphore = DispatchSemaphore(value: 0)
  let box = ResultBox<(ok: Bool, description: String)>()

  Task {
    box.value = await PerChatSendActor.shared.send(
      agentId: agentId, chatId: chatId, work)
    semaphore.signal()
  }

  semaphore.wait()
  return box.value ?? (false, "internal: actor result missing")
}

/// One-shot value transfer across the Task ↔ semaphore boundary.
/// Safety: the wait/signal pair on the semaphore establishes
/// happens-before, so a single write before signal and a single read after
/// wait are race-free without an additional lock.
private final class ResultBox<T>: @unchecked Sendable {
  var value: T?
}
