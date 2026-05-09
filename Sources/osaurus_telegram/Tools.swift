import Foundation

// MARK: - Tool Handlers
//
// The agent owns user-visible content. These three tools are the primary
// delivery path: every reply the user sees flows through here, gated by an
// opaque `reply_token` so the agent never learns the chat_id (prompt
// injection cannot redirect outbound messages).
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

func handleReply(ctx: PluginContext, payload: String) -> String {
  runReplyTool(
    ctx: ctx, payload: payload,
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

func handleReplyTyping(ctx: PluginContext, payload: String) -> String {
  runReplyTool(
    ctx: ctx, payload: payload,
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

func handleReplyPhoto(ctx: PluginContext, payload: String) -> String {
  runReplyTool(
    ctx: ctx, payload: payload,
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

// MARK: - Shared reply pipeline
//
// All three tools share the same shape:
//   1. parse args
//   2. validate the binding (token expiry / blocked chat)
//   3. require a configured bot token
//   4. run the Telegram POST through the per-chat send actor
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

/// Tool name for envelope error context — anonymous "decode" otherwise.
private func runReplyTool<Args: Decodable>(
  ctx: PluginContext,
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

  switch validateBinding(token: replyToken) {
  case .failure(.staleToken):
    return toolEnvelopeError(
      "stale_token",
      "Reply token expired or unknown. End the turn — a new token will arrive on the next user message."
    )
  case .failure(.chatBlocked):
    return toolEnvelopeError("chat_blocked", "User has blocked the bot.")
  case .success(let binding):
    guard let token = ctx.botToken, !token.isEmpty else {
      return toolEnvelopeError("not_configured", "Bot token not configured.")
    }

    let plan = build(args, token, binding)
    let response = runOnSendActor(chatId: binding.chatId, plan.action)

    if response.ok {
      if plan.successMarksReplied {
        DatabaseManager.markReplied(taskId: binding.taskId)
      }
      return toolEnvelopeSuccess(["sent": true], summary: plan.successSummary)
    }
    return mapTelegramFailure(response.description, binding: binding)
  }
}

// MARK: - Validation + failure mapping

private enum BindingValidationFailure: Error {
  case staleToken
  case chatBlocked
}

private func validateBinding(token: String) -> Result<ActiveDispatchRow, BindingValidationFailure> {
  guard let binding = DatabaseManager.lookupBinding(token: token) else {
    return .failure(.staleToken)
  }
  if binding.expiresAt <= Int(Date().timeIntervalSince1970) {
    return .failure(.staleToken)
  }
  if DatabaseManager.isChatBlocked(chatId: binding.chatId) {
    return .failure(.chatBlocked)
  }
  return .success(binding)
}

/// Translates a Telegram failure description into a tool envelope, with
/// special handling for "bot was blocked by the user": flag the chat
/// blocked, cancel the running task, and surface `chat_blocked` in-band so
/// the agent stops trying.
private func mapTelegramFailure(
  _ description: String, binding: ActiveDispatchRow
) -> String {
  if description.lowercased().contains("bot was blocked") {
    DatabaseManager.markChatBlocked(chatId: binding.chatId)
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

private func runOnSendActor(
  chatId: Int64,
  _ work: @Sendable @escaping () -> (ok: Bool, description: String)
) -> (ok: Bool, description: String) {
  let semaphore = DispatchSemaphore(value: 0)
  let box = ResultBox<(ok: Bool, description: String)>()

  Task {
    box.value = await PerChatSendActor.shared.send(chatId: chatId, work)
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
