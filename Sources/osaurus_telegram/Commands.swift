import Foundation

// MARK: - Plugin-owned slash commands
//
// Commands the plugin handles itself (without dispatching to an agent):
//
//   * `/start`, `/help` — static welcome / help text. Bypasses the
//     allowlist so a denied user gets something to send to the admin.
//   * `/whoami` — echoes the caller's user_id, @username, and chat_id
//     so an admin can populate `allowed_users` / `allowed_chat_ids`
//     without external tooling. Bypasses the allowlist by design.
//   * `/clear` (alias `/reset`, `/new`, `/restart`) — bumps the per-user
//     session salt, cleanly partitioning before/after into separate
//     host sessions. Cancels in-flight dispatches for that user.
//   * `/clearall` — same, but for every participant in the chat.
//
// All command parsing accepts the `/cmd` and `/cmd@botname` forms
// uniformly. Telegram appends `@botname` in groups; we strip it so DM
// and group behaviour matches.

// MARK: - /start and /help (static replies)

private let startMessageText = """
  Hi! I'm an Osaurus-powered assistant on Telegram.

  Just send me a message and I'll respond. I can answer questions, work \
  through problems with you, look things up, and run tools on your behalf.

  Useful commands:
    /help — show what I can do
    /clear — start a fresh conversation
    /whoami — show your user/chat IDs (handy for admins)
  """

private let helpMessageText = """
  Send me any message — text, photo, voice, document — and I'll respond. \
  You don't need to mention me in private chats.

  In group chats, mention me by @username or reply to one of my messages \
  so I know you're talking to me. Each person in a group gets their own \
  conversation thread with me.

  Commands:
    /start — welcome message
    /help — this message
    /clear — reset YOUR conversation with me
    /clearall — reset every participant's conversation (groups only)
    /whoami — show your user_id, @username, and the chat_id

  Tip: I can work with files you upload — try sending a photo, PDF, or voice note.
  """

/// Returns the static reply text when `text` is a plugin-owned
/// command (`/start` or `/help`), or nil for anything else. Same
/// `/command` / `/command@bot` parsing as `parseResetCommand`.
func staticCommandReply(_ text: String) -> String? {
  guard let verb = parseCommandVerb(text) else { return nil }
  switch verb {
  case "start": return startMessageText
  case "help": return helpMessageText
  default: return nil
  }
}

// MARK: - /whoami

func isWhoamiCommand(_ text: String) -> Bool {
  parseCommandVerb(text) == "whoami"
}

func handleWhoami(state: AgentState, message: TGUpdate.Message) {
  guard let token = state.botToken, !token.isEmpty else {
    logWarn("/whoami: no bot_token configured; cannot reply")
    return
  }
  let chatId = message.chat.id
  let from = message.from
  let userId = from?.id ?? chatId
  let username = from?.username.map { "@\($0)" } ?? "(no username)"
  let text =
    "your user_id: \(userId)\nyour username: \(username)\nthis chat_id: \(chatId)"
  _ = telegramSendMessage(
    token: token, chatId: chatId, text: text,
    replyToMessageId: message.message_id)
}

// MARK: - /clear and /clearall

/// Per-user vs chat-wide reset scope. `clear` and aliases default to
/// per-user so a group member can wipe their own transcript without
/// disturbing other members; `clearall` explicitly bumps every user's
/// salt for the chat.
enum ResetScope {
  case currentUser
  case allUsers
}

/// Verbs the user can send to bump the chat's session salt. Compared
/// case-insensitively after stripping the `/` prefix and any
/// `@botname` suffix Telegram appends in group chats.
private let resetCommandVerbs: Set<String> = ["reset", "clear", "new", "restart"]

/// Returns the reset scope when `text` (already trimmed of surrounding
/// whitespace) is one of the documented reset commands. Returns nil for
/// non-reset input. Handles `/clear`, `/clearall`, `/clear@MyBot`, etc.
/// uniformly.
func parseResetCommand(_ text: String) -> ResetScope? {
  guard let verb = parseCommandVerb(text) else { return nil }
  if verb == "clearall" { return .allUsers }
  if resetCommandVerbs.contains(verb) { return .currentUser }
  return nil
}

/// Backward-compatible wrapper preserved for tests that just want a
/// boolean answer. New call sites should use `parseResetCommand` so they
/// get the scope back in one parse.
func isResetCommand(_ text: String) -> Bool {
  parseResetCommand(text) != nil
}

func handleReset(
  state: AgentState, agentId: String, chatId: Int64, userId: Int64,
  scope: ResetScope
) {
  switch scope {
  case .currentUser:
    logDebug("handleReset: chat \(chatId) user \(userId) (per-user)")
    DatabaseManager.bumpSessionSalt(
      agentId: agentId, chatId: chatId, userId: userId)
    cancelEveryDispatch(
      DatabaseManager.allActiveDispatches(
        agentId: agentId, forChat: chatId, userId: userId))

  case .allUsers:
    logDebug("handleReset: chat \(chatId) (all users)")
    DatabaseManager.bumpAllSessionSalts(agentId: agentId, chatId: chatId)
    cancelEveryDispatch(
      DatabaseManager.allActiveDispatches(agentId: agentId, forChat: chatId))
  }

  if let token = state.botToken {
    let suffix = (scope == .allUsers) ? " (all participants)" : ""
    _ = telegramSendMessage(
      token: token, chatId: chatId, text: "Conversation reset.\(suffix)")
  }
}

/// Issues `dispatch_cancel` for every supplied row and removes the row
/// from `active_dispatches`. Called by `handleReset` for both per-user
/// and chat-wide scopes.
private func cancelEveryDispatch(_ rows: [ActiveDispatchRow]) {
  for active in rows {
    active.taskId.withCString { tid in
      hostAPI?.pointee.dispatch_cancel?(tid)
    }
    DatabaseManager.deleteActiveDispatch(taskId: active.taskId)
  }
}

// MARK: - shared command parsing

/// Returns the lowercased command verb for `text` if it looks like a
/// `/cmd` or `/cmd@botname` token (no whitespace, no payload). Returns
/// nil for plain chat messages, commands with arguments, or anything
/// that doesn't start with `/`. Stripping `@botname` is harmless in DMs
/// since `@` isn't valid inside a verb.
private func parseCommandVerb(_ text: String) -> String? {
  guard text.hasPrefix("/") else { return nil }
  var verb = Substring(text.dropFirst())
  if let at = verb.firstIndex(of: "@") { verb = verb[..<at] }
  guard !verb.isEmpty,
    !verb.contains(where: { $0.isWhitespace })
  else { return nil }
  return verb.lowercased()
}
