import Foundation

// MARK: - Route Handler

func handleRoute(ctx: PluginContext, requestJSON: String) -> String {
  guard let req = parseJSON(requestJSON, as: RouteRequest.self) else {
    logWarn("handleRoute: failed to parse request JSON (\(requestJSON.count) chars)")
    return makeRouteResponse(status: 400, body: "{\"error\":\"Invalid request\"}")
  }

  logDebug("handleRoute: route_id=\(req.route_id) method=\(req.method)")

  switch req.route_id {
  case "webhook":
    return handleWebhook(ctx: ctx, req: req)
  case "health":
    return handleHealth(ctx: ctx)
  default:
    logWarn("handleRoute: unknown route_id '\(req.route_id)'")
    return makeRouteResponse(status: 404, body: "{\"error\":\"Not found\"}")
  }
}

// MARK: - Webhook Endpoint

private func extractSecretHeader(from headers: [String: String]) -> String? {
  if let v = headers["x-telegram-bot-api-secret-token"] { return v }
  if let v = headers["X-Telegram-Bot-Api-Secret-Token"] { return v }
  return nil
}

private func handleWebhook(ctx: PluginContext, req: RouteRequest) -> String {
  logDebug("handleWebhook: body=\(String((req.body ?? "nil").prefix(300)))")

  guard let secret = ctx.webhookSecret else {
    logWarn("Webhook request rejected: no webhook secret configured")
    return makeRouteResponse(status: 401, body: "{\"error\":\"Unauthorized\"}")
  }

  guard let headers = req.headers else {
    logWarn("Webhook request rejected: no headers")
    return makeRouteResponse(status: 401, body: "{\"error\":\"Unauthorized\"}")
  }

  guard let headerToken = extractSecretHeader(from: headers), headerToken == secret else {
    logWarn(
      "Webhook request rejected: invalid secret token (header present: \(extractSecretHeader(from: headers) != nil))"
    )
    return makeRouteResponse(status: 401, body: "{\"error\":\"Unauthorized\"}")
  }

  guard let body = req.body,
    let update = parseJSON(body, as: TelegramUpdate.self)
  else {
    logWarn("Webhook: failed to parse update body (\(req.body?.count ?? 0) chars)")
    return makeRouteResponse(status: 200, body: "ok")
  }

  let agentAddress = req.osaurus?.agent_address
  logDebug(
    "handleWebhook: update_id=\(update.update_id) hasMessage=\(update.message != nil) hasCallback=\(update.callback_query != nil) hasReaction=\(update.message_reaction != nil) agentAddress=\(agentAddress ?? "nil")"
  )

  if let message = update.message {
    handleMessage(ctx: ctx, message: message, agentAddress: agentAddress)
  } else if let callbackQuery = update.callback_query {
    handleCallback(ctx: ctx, query: callbackQuery)
  } else if let reaction = update.message_reaction {
    handleReaction(ctx: ctx, reaction: reaction)
  } else {
    logDebug("handleWebhook: update has no message, callback_query, or reaction, ignoring")
  }

  return makeRouteResponse(status: 200, body: "ok")
}

// MARK: - Message Handler

private func detectMediaType(message: TelegramMessage) -> String? {
  if message.photo != nil { return "photo" }
  if message.document != nil { return "document" }
  if message.voice != nil { return "voice" }
  return nil
}

private func detectMediaFileId(message: TelegramMessage) -> String? {
  if let photo = message.photo?.last { return photo.file_id }
  if let doc = message.document { return doc.file_id }
  if let voice = message.voice { return voice.file_id }
  return nil
}

private func formatSenderName(from user: TelegramUser?) -> String? {
  guard let user = user else { return nil }
  if let username = user.username {
    return "\(user.first_name) (@\(username))"
  }
  return user.first_name
}

private func handleMessage(ctx: PluginContext, message: TelegramMessage, agentAddress: String?) {
  let chat = message.chat
  let chatId = "\(chat.id)"
  let isPrivateChat = chat.type == "private"
  let senderName = formatSenderName(from: message.from)
  let senderId = message.from.map { "\($0.id)" }

  logDebug(
    "handleMessage: chatId=\(chatId) type=\(chat.type) sender=\(senderName ?? "unknown") msgId=\(message.message_id)"
  )

  let chatTitle = chat.title ?? chat.first_name ?? chat.username
  DatabaseManager.upsertChat(
    chatId: chatId,
    chatType: chat.type,
    title: chatTitle,
    username: chat.username
  )

  if let from = message.from {
    DatabaseManager.upsertUser(
      userId: "\(from.id)",
      username: from.username,
      firstName: from.first_name,
      lastName: from.last_name
    )
  }

  let mediaType = detectMediaType(message: message)
  let mediaFileId = detectMediaFileId(message: message)

  DatabaseManager.insertMessage(
    chatId: chatId,
    messageId: message.message_id,
    direction: "in",
    senderId: senderId,
    senderName: senderName,
    text: message.text ?? message.caption,
    mediaType: mediaType,
    mediaFileId: mediaFileId,
    taskId: nil
  )
  logDebug(
    "handleMessage: stored incoming message (text=\((message.text ?? message.caption)?.count ?? 0) chars, media=\(mediaType ?? "none"))"
  )

  if let allowed = configGet("allowed_users"), !allowed.isEmpty {
    let allowedUsers = Set(
      allowed.split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespaces)
          .lowercased()
          .replacingOccurrences(of: "@", with: "")
      })
    let senderUsername = message.from?.username?.lowercased()
    guard let username = senderUsername, allowedUsers.contains(username) else {
      guard let token = ctx.botToken else {
        logWarn(
          "handleMessage: user \(senderUsername ?? "unknown") not allowed and no bot token to send rejection"
        )
        return
      }
      _ = telegramSendMessage(token: token, chatId: chatId, text: "Not authorized.")
      logWarn("User \(senderUsername ?? "unknown") not in allowed_users [\(allowed)], rejecting")
      return
    }
    logDebug("handleMessage: user @\(username) is in allowed_users")
  }

  if let text = message.text, text.hasPrefix("/") {
    guard let token = ctx.botToken else {
      logWarn("handleMessage: command received but no bot token")
      return
    }

    if text.hasPrefix("/start") {
      let welcome =
        "Hello! I'm connected to your Osaurus agent. Send me a message and I'll get to work."
      _ = telegramSendMessage(
        token: token, chatId: chatId, text: welcome, replyTo: message.message_id)
      return
    }

    if text.hasPrefix("/clear") {
      logDebug("handleMessage: /clear for chat \(chatId)")
      if !isPrivateChat, let userId = senderId {
        DatabaseManager.clearUserInChat(chatId: chatId, userId: userId)
        _ = telegramSendMessage(
          token: token, chatId: chatId,
          text: "Your conversation history cleared. Send a new message to start fresh.",
          replyTo: message.message_id)
      } else {
        DatabaseManager.clearChat(chatId: chatId)
        _ = telegramSendMessage(
          token: token, chatId: chatId,
          text: "Conversation cleared. Send a new message to start fresh.",
          replyTo: message.message_id)
      }
      return
    }

    if text.hasPrefix("/status") {
      handleStatusCommand(
        token: token, chatId: chatId, message: message,
        isPrivateChat: isPrivateChat, userId: senderId)
      return
    }

    if text.hasPrefix("/cancel") {
      handleCancelCommand(
        token: token, chatId: chatId, message: message,
        isPrivateChat: isPrivateChat, userId: senderId)
      return
    }
  }

  let prompt = buildPrompt(from: message)
  guard !prompt.isEmpty else {
    logDebug("handleMessage: empty prompt, ignoring message")
    return
  }
  guard let token = ctx.botToken else {
    logWarn("handleMessage: no bot token configured, cannot respond to chat \(chatId)")
    return
  }

  logDebug("handleMessage: prompt=\"\(String(prompt.prefix(100)))\" (\(prompt.count) chars)")

  if let replyTo = message.reply_to_message,
    let task = DatabaseManager.getTaskByMessageId(chatId: chatId, messageId: replyTo.message_id)
  {
    logDebug(
      "handleMessage: reply to task thread \(task.taskId) status=\(task.status)")
    handleTaskThreadReply(
      token: token, chatId: chatId, prompt: prompt, message: message,
      task: task, isPrivateChat: isPrivateChat, senderName: senderName,
      userId: senderId, agentAddress: agentAddress)
    return
  }

  if !isPrivateChat {
    telegramSendChatAction(token: token, chatId: chatId)
  }

  logDebug(
    "handleMessage: isPrivate=\(isPrivateChat) complete_stream=\(hostAPI?.pointee.complete_stream != nil)"
  )

  if isPrivateChat && hostAPI?.pointee.complete_stream != nil {
    logDebug("handleMessage: -> chat mode streaming path")
    handleChatModeStreaming(
      ctx: ctx, token: token, chatId: chatId,
      prompt: prompt, messageId: message.message_id,
      senderName: senderName,
      agentAddress: agentAddress
    )
    return
  }

  logDebug("handleMessage: -> dispatch path (group chat)")
  dispatchAgentTask(
    token: token, chatId: chatId, prompt: prompt, message: message,
    isPrivateChat: isPrivateChat, senderName: senderName,
    userId: senderId, agentAddress: agentAddress)
}

// MARK: - Agent Dispatch

/// Builds a stable external session key for `dispatch()` so repeated turns from the
/// same Telegram conversation reattach to one Osaurus session row in the sidebar.
/// In groups we scope per user, so each participant gets their own thread.
func sessionKey(chatId: String, userId: String?) -> String {
  if let userId { return "telegram:chat-\(chatId):user-\(userId)" }
  return "telegram:chat-\(chatId)"
}

private func dispatchAgentTask(
  token: String, chatId: String, prompt: String, message: TelegramMessage,
  isPrivateChat: Bool, senderName: String?, userId: String?, agentAddress: String?
) {
  let titleText = message.text ?? message.caption ?? "Media message"
  let firstLine = String(titleText.prefix(60))

  guard let dispatch = hostAPI?.pointee.dispatch else {
    logError("dispatch not available")
    _ = telegramSendMessage(token: token, chatId: chatId, text: "Agent dispatch unavailable.")
    return
  }

  var enrichedPrompt = prompt
  if !isPrivateChat, let name = senderName {
    enrichedPrompt = "[\(name)] asked: \(prompt)"
  }

  var dispatchPayload: [String: Any] = [
    "prompt": enrichedPrompt,
    "title": "Telegram: \(firstLine)",
    "external_session_key": sessionKey(chatId: chatId, userId: userId),
  ]
  if let agentAddress { dispatchPayload["agent_address"] = agentAddress }
  guard let dispatchJSON = makeJSONString(dispatchPayload) else {
    logError("Failed to build dispatch JSON from payload keys: \(Array(dispatchPayload.keys))")
    return
  }

  logDebug("dispatchAgentTask: payload=\(String(dispatchJSON.prefix(300)))")

  let dispatchResultStr: String? = dispatchJSON.withCString { ptr in
    guard let resultPtr = dispatch(ptr) else { return nil }
    return String(cString: resultPtr)
  }
  guard let resultStr = dispatchResultStr else {
    logError("dispatch returned nil")
    _ = telegramSendMessage(token: token, chatId: chatId, text: "Failed to start agent task.")
    return
  }

  logDebug("dispatchAgentTask: result=\(String(resultStr.prefix(300)))")

  guard let dispatchResult = parseJSON(resultStr, as: DispatchResponse.self),
    let taskId = dispatchResult.id
  else {
    logError("Failed to parse dispatch response: \(resultStr)")
    _ = telegramSendMessage(
      token: token, chatId: chatId, text: "Failed to start task.",
      replyTo: message.message_id)
    return
  }

  DatabaseManager.insertTask(
    taskId: taskId, chatId: chatId, messageId: message.message_id, userId: userId)
  logDebug("dispatchAgentTask: inserted task \(taskId) for chat \(chatId) user \(userId ?? "nil")")

  let sendTypingEnabled = configGet("send_typing") != "false"
  if sendTypingEnabled && !isPrivateChat {
    if let statusMsgId = telegramSendMessage(
      token: token, chatId: chatId, text: "\u{23F3} Working on it...",
      replyTo: message.message_id)
    {
      DatabaseManager.updateTask(taskId: taskId, statusMsgId: statusMsgId)
      logDebug("dispatchAgentTask: created status message \(statusMsgId) for task \(taskId)")
    } else {
      logWarn("dispatchAgentTask: failed to send status message for task \(taskId)")
    }
  }

  logInfo("Dispatched task \(taskId) for chat \(chatId)")
}

// MARK: - Task Thread Reply

/// Handles a Telegram reply addressed to a previous agent message.
///
/// - If the task is still `running`, soft-interrupt it with the new prompt so
///   the agent reroutes mid-flight (`dispatch_interrupt` is still supported).
/// - Otherwise (completed/failed/cancelled/awaiting_clarification), fire a
///   fresh `dispatch()` with the same `external_session_key`. The host
///   reattaches to the existing session row, preserving conversation context.
///   This replaces the deprecated `dispatch_add_issue` and `dispatch_clarify`
///   paths, which are now no-ops.
private func handleTaskThreadReply(
  token: String, chatId: String, prompt: String, message: TelegramMessage,
  task: TaskRow, isPrivateChat: Bool, senderName: String?, userId: String?,
  agentAddress: String?
) {
  if task.status == "running", let interrupt = hostAPI?.pointee.dispatch_interrupt {
    logDebug("handleTaskThreadReply: interrupting running task \(task.taskId)")
    task.taskId.withCString { tid in
      prompt.withCString { p in interrupt(tid, p) }
    }
    _ = telegramSendMessage(
      token: token, chatId: chatId, text: "Got it, redirecting",
      replyTo: message.message_id)
    return
  }

  logDebug(
    "handleTaskThreadReply: redispatching as new turn in same session for task \(task.taskId) (status=\(task.status))"
  )
  telegramSendChatAction(token: token, chatId: chatId)
  dispatchAgentTask(
    token: token, chatId: chatId, prompt: prompt, message: message,
    isPrivateChat: isPrivateChat, senderName: senderName,
    userId: userId, agentAddress: agentAddress)
}

// MARK: - Status Command

private func handleStatusCommand(
  token: String, chatId: String, message: TelegramMessage,
  isPrivateChat: Bool, userId: String?
) {
  let tasks = DatabaseManager.getRecentTasks(chatId: chatId, limit: 5)

  if tasks.isEmpty {
    _ = telegramSendMessage(
      token: token, chatId: chatId, text: "No recent tasks.",
      replyTo: message.message_id)
    return
  }

  var lines: [String] = []
  for task in tasks {
    let icon: String
    switch task.status {
    case "running": icon = "\u{23F3}"
    case "completed": icon = "\u{2705}"
    case "failed": icon = "\u{274C}"
    case "cancelled": icon = "\u{1F6AB}"
    case "awaiting_clarification": icon = "\u{2753}"
    default: icon = "\u{2022}"
    }

    let shortId = String(task.taskId.prefix(8))
    let summaryText = task.summary.map { " \u{2014} \(String($0.prefix(80)))" } ?? ""
    lines.append("\(icon) \(shortId) [\(task.status)]\(summaryText)")
  }

  let responseText = lines.joined(separator: "\n")
  _ = telegramSendMessage(
    token: token, chatId: chatId, text: responseText,
    replyTo: message.message_id)
}

// MARK: - Cancel Command

private func handleCancelCommand(
  token: String, chatId: String, message: TelegramMessage,
  isPrivateChat: Bool, userId: String?
) {
  let arg = String((message.text ?? "").dropFirst(7)).trimmingCharacters(in: .whitespaces)

  let taskToCancel: TaskRow?
  if !arg.isEmpty {
    taskToCancel = DatabaseManager.getTask(taskId: arg)
    if taskToCancel == nil {
      _ = telegramSendMessage(
        token: token, chatId: chatId,
        text: "Task \(arg) not found.",
        replyTo: message.message_id)
      return
    }
  } else {
    taskToCancel = DatabaseManager.getRunningTask(
      chatId: chatId, userId: isPrivateChat ? nil : userId)
  }

  guard let task = taskToCancel else {
    _ = telegramSendMessage(
      token: token, chatId: chatId, text: "No running task to cancel.",
      replyTo: message.message_id)
    return
  }

  guard task.status == "running" || task.status == "awaiting_clarification" else {
    _ = telegramSendMessage(
      token: token, chatId: chatId,
      text: "Task is already \(task.status).",
      replyTo: message.message_id)
    return
  }

  if let cancel = hostAPI?.pointee.dispatch_cancel {
    task.taskId.withCString { tid in
      cancel(tid)
    }
    logDebug("handleCancelCommand: cancelled task \(task.taskId)")
  } else {
    logWarn("handleCancelCommand: dispatch_cancel not available")
  }

  let shortId = String(task.taskId.prefix(8))
  _ = telegramSendMessage(
    token: token, chatId: chatId,
    text: "\u{1F6AB} Cancelling task \(shortId)...",
    replyTo: message.message_id)
}

// MARK: - Chat Mode Streaming

/// State accumulated during streaming inference, passed through the C callback via user_data.
final class ChatStreamState {
  let token: String
  let chatId: String
  let messageId: Int
  let draftId: Int
  static let flushThreshold = 100

  var accumulated = ""
  var lastFlushLength = 0
  var receivedFirstChunk = false
  var hasSetWritingReaction = false
  var currentToolName: String?

  init(token: String, chatId: String, messageId: Int, draftId: Int) {
    self.token = token
    self.chatId = chatId
    self.messageId = messageId
    self.draftId = draftId
  }

  func react(_ emoji: String) {
    _ = telegramSetMessageReaction(
      token: token, chatId: chatId, messageId: messageId, emoji: emoji)
  }

  func draft(_ text: String) {
    _ = telegramSendMessageDraft(
      token: token, chatId: chatId, draftId: draftId, text: text)
  }
}

/// C-compatible callback for complete_stream chunks (handles content, tool calls, and tool results).
private let streamChunkCallback:
  @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { chunkPtr, userData in
    guard let chunkPtr, let userData else { return }
    let state = Unmanaged<ChatStreamState>.fromOpaque(userData).takeUnretainedValue()
    let chunk = String(cString: chunkPtr)

    if !state.receivedFirstChunk {
      state.receivedFirstChunk = true
      logDebug("streamChunkCallback: first chunk received (\(chunk.count) chars)")
    }

    if let toolInfo = extractToolCallInfo(chunk) {
      if toolInfo.isToolResult {
        state.currentToolName = nil
      } else if let name = toolInfo.name {
        state.currentToolName = name
        logDebug("streamChunkCallback: tool call \(name)")
        state.react("\u{2699}")
        state.draft(friendlyToolName(name))
      }
      return
    }

    if let content = extractStreamContent(chunk) {
      state.currentToolName = nil
      state.accumulated += content

      if !state.hasSetWritingReaction {
        state.hasSetWritingReaction = true
        state.react("\u{270D}")
      }
    }

    let newChars = state.accumulated.count - state.lastFlushLength
    if newChars >= ChatStreamState.flushThreshold {
      logDebug("streamChunkCallback: flush at \(state.accumulated.count) chars")
      state.draft(String(state.accumulated.prefix(4096)))
      state.lastFlushLength = state.accumulated.count
    }
  }

/// Extracts the text content from an OpenAI-compatible streaming chunk JSON.
func extractStreamContent(_ chunk: String) -> String? {
  guard let parsed = parseJSON(chunk, as: StreamChunk.self),
    let choices = parsed.choices,
    let first = choices.first,
    let delta = first.delta,
    let content = delta.content
  else {
    return nil
  }
  return content
}

/// Extracts tool call metadata from an agentic streaming chunk.
/// Returns the tool name for tool call requests, or flags tool result chunks.
/// Returns nil if the chunk is not tool-related (e.g. a content delta).
func extractToolCallInfo(_ chunk: String) -> (name: String?, isToolResult: Bool)? {
  guard let parsed = parseJSON(chunk, as: StreamChunk.self),
    let choices = parsed.choices,
    let first = choices.first,
    let delta = first.delta
  else {
    return nil
  }

  if delta.role == "tool" {
    return (name: nil, isToolResult: true)
  }

  if let toolCalls = delta.tool_calls, let firstCall = toolCalls.first {
    return (name: firstCall.function?.name, isToolResult: false)
  }

  return nil
}

/// Maps raw tool names to natural-language status descriptions for draft messages.
/// Users can override these via the `tool_status_messages` config key (JSON object).
func friendlyToolName(_ name: String) -> String {
  if let customJSON = configGet("tool_status_messages"),
    let data = customJSON.data(using: .utf8),
    let overrides = try? JSONSerialization.jsonObject(with: data) as? [String: String]
  {
    for (prefix, label) in overrides {
      if name.hasPrefix(prefix) { return label }
    }
  }

  if name.hasPrefix("sandbox_exec") { return "Running code" }
  if name.hasPrefix("sandbox_install") { return "Installing packages" }
  if name.hasPrefix("sandbox_read") { return "Reading files" }
  if name.hasPrefix("sandbox_write") { return "Writing code" }
  if name.hasPrefix("sandbox_list") { return "Browsing files" }
  if name.hasPrefix("sandbox_search") { return "Searching files" }
  if name.hasPrefix("sandbox") { return "Setting up environment" }
  if name.hasPrefix("web_search") || name.hasPrefix("search") { return "Searching the web" }
  if name.hasPrefix("web_browse") || name.hasPrefix("browse") { return "Reading a webpage" }
  if name.hasPrefix("telegram_send") { return "Sending a message" }
  if name.hasPrefix("telegram_get") { return "Checking chat history" }
  return "Working on it"
}

/// Builds an OpenAI-compatible messages array from chat history + the current prompt.
/// When `isGroupChat` is true, user messages are prefixed with the sender's name
/// so the model can distinguish between participants.
func buildCompletionMessages(
  historyJSON: String, currentPrompt: String, isGroupChat: Bool = false
) -> [[String: Any]] {
  var messages: [[String: Any]] = []

  if let data = historyJSON.data(using: .utf8),
    let history = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
  {
    for msg in history.reversed() {
      let direction = msg["direction"] as? String
      let text = msg["text"] as? String ?? ""
      guard !text.isEmpty else { continue }
      let role = direction == "out" ? "assistant" : "user"

      if isGroupChat && role == "user", let name = msg["sender_name"] as? String {
        messages.append(["role": role, "content": "[\(name)]: \(text)"])
      } else {
        messages.append(["role": role, "content": text])
      }
    }
  }

  messages.append(["role": "user", "content": currentPrompt])
  return messages
}

private func handleChatModeStreaming(
  ctx: PluginContext, token: String, chatId: String, prompt: String, messageId: Int,
  senderName: String?, agentAddress: String?
) {
  logDebug(
    "handleChatModeStreaming: chatId=\(chatId) prompt=\(prompt.count) chars msgId=\(messageId)")

  let chatDraftId = draftId(for: "chat-\(chatId)-\(messageId)")

  DispatchQueue.global(qos: .userInitiated).async {
    let historyJSON = DatabaseManager.getMessages(chatId: chatId, limit: 20)
    var messages = buildCompletionMessages(historyJSON: historyJSON, currentPrompt: prompt)
    logDebug("handleChatModeStreaming: built \(messages.count) completion messages from history")

    let enableTools = configGet("enable_tools") != "false"
    let enableSandbox = configGet("enable_sandbox") != "false"
    let enablePreflight = configGet("enable_preflight") == "true"
    let maxIter = Int(configGet("max_iterations") ?? "") ?? 10

    var systemParts: [String] = []

    let customPrompt = configGet("system_prompt")
    if let customPrompt, !customPrompt.isEmpty {
      systemParts.append(customPrompt)
    }

    let displayName = senderName ?? "the user"
    systemParts.append(
      "You are a helpful assistant in a Telegram chat with \(displayName). Keep responses concise and conversational \u{2014} this is a chat, not an essay. Use short paragraphs. Only include code blocks when specifically asked. Avoid excessive markdown formatting."
    )

    if enableTools && !enableSandbox {
      systemParts.append(
        "IMPORTANT: Do not use sandbox tools (sandbox_exec, sandbox_read_file, sandbox_write_file, sandbox_list_directory, sandbox_search_files, sandbox_install). Only use non-sandbox tools."
      )
    }

    messages.insert(
      ["role": "system", "content": systemParts.joined(separator: "\n\n")], at: 0)

    var request: [String: Any] = [
      "model": "",
      "messages": messages,
      "max_tokens": 4096,
    ]
    if enableTools {
      request["tools"] = true
      request["max_iterations"] = maxIter
    }
    if enablePreflight { request["preflight"] = true }
    if let agentAddress { request["agent_address"] = agentAddress }
    guard let requestJSON = makeJSONString(request) else {
      logError("handleChatModeStreaming: failed to serialize completion request")
      _ = telegramSendMessage(token: token, chatId: chatId, text: "Failed to build request.")
      return
    }

    logDebug("handleChatModeStreaming: calling complete_stream (\(requestJSON.count) chars)")

    ctx.activeStreamingChatId = chatId
    defer { ctx.activeStreamingChatId = nil }

    let state = ChatStreamState(
      token: token, chatId: chatId, messageId: messageId, draftId: chatDraftId)
    state.react("\u{1F440}")
    let statePtr = Unmanaged.passRetained(state).toOpaque()

    let result: UnsafePointer<CChar>? = requestJSON.withCString { ptr in
      hostAPI?.pointee.complete_stream?(ptr, streamChunkCallback, statePtr)
    }

    var streamError: String?
    var sharedArtifacts: [SharedArtifact] = []
    if let result {
      let resultStr = String(cString: result)
      free(UnsafeMutableRawPointer(mutating: result))
      logDebug(
        "handleChatModeStreaming: complete_stream returned: \(String(resultStr.prefix(300)))")
      if let envelope = parseJSON(resultStr, as: CompletionResultEnvelope.self) {
        if let errorMsg = envelope.error {
          logError("Streaming inference error: \(errorMsg)")
          streamError = errorMsg
        }
        if let artifacts = envelope.shared_artifacts, !artifacts.isEmpty {
          sharedArtifacts = artifacts
          logDebug(
            "handleChatModeStreaming: response includes \(artifacts.count) shared artifact(s)")
        }
      }
    } else {
      logDebug("handleChatModeStreaming: complete_stream returned nil (no error object)")
    }

    logDebug(
      "handleChatModeStreaming: stream finished, accumulated=\(state.accumulated.count) chars, error=\(streamError ?? "none")"
    )

    let finalText: String
    let isError: Bool
    if let streamError, state.accumulated.isEmpty {
      finalText = "Error: \(streamError)"
      isError = true
    } else if state.accumulated.isEmpty {
      logWarn("handleChatModeStreaming: no content accumulated and no error")
      finalText = "I couldn't generate a response."
      isError = true
    } else {
      finalText = state.accumulated
      isError = false
    }

    let htmlText = markdownToTelegramHTML(finalText)
    let msgId = telegramSendLongMessage(
      token: token, chatId: chatId, text: htmlText,
      parseMode: "HTML", replyTo: messageId)
    logDebug("handleChatModeStreaming: sent final message, msgId=\(msgId.map { "\($0)" } ?? "nil")")

    state.react(isError ? "\u{274C}" : "\u{2705}")

    if let msgId {
      DatabaseManager.insertMessage(
        chatId: chatId,
        messageId: msgId,
        direction: "out",
        senderId: nil,
        senderName: "Agent",
        text: finalText,
        mediaType: nil,
        mediaFileId: nil,
        taskId: nil
      )
    }

    Unmanaged<ChatStreamState>.fromOpaque(statePtr).release()

    if !sharedArtifacts.isEmpty {
      uploadSharedArtifacts(
        ctx: ctx, token: token, chatId: chatId,
        artifacts: sharedArtifacts, replyTo: messageId)
    }

    logInfo("Chat mode streaming complete for chat \(chatId)")
  }
}

/// Uploads artifacts surfaced by the inference response directly to the
/// originating chat. Preferred over the `invoke(type: "artifact")` callback
/// fallback because we know exactly which chat triggered the inference call,
/// rather than relying on a "last active chat" heuristic.
private func uploadSharedArtifacts(
  ctx: PluginContext? = nil,
  token: String, chatId: String, artifacts: [SharedArtifact], replyTo: Int?
) {
  guard configGet("auto_upload_artifacts") != "false" else {
    logDebug("uploadSharedArtifacts: auto_upload_artifacts disabled, skipping")
    return
  }

  for artifact in artifacts {
    if artifact.is_directory == true {
      logDebug("uploadSharedArtifacts: skipping directory \(artifact.filename)")
      continue
    }
    guard let path = artifact.host_path, !path.isEmpty else {
      logDebug("uploadSharedArtifacts: missing host_path for \(artifact.filename)")
      continue
    }
    if let ctx, ctx.claimArtifactUpload(path) {
      logDebug("uploadSharedArtifacts: \(artifact.filename) already uploaded, skipping")
      continue
    }

    let file: HostFileResult
    switch readHostFile(path: path) {
    case .success(let f):
      file = f
    case .failure(let error):
      logError("uploadSharedArtifacts: \(artifact.filename) read failed: \(error)")
      continue
    }

    let mimeType = artifact.mime_type ?? file.mimeType
    guard
      let result = uploadFileToTelegram(
        token: token, chatId: chatId,
        fileData: file.data, filename: artifact.filename, mimeType: mimeType,
        caption: artifact.description, replyTo: replyTo)
    else {
      logError("uploadSharedArtifacts: failed to upload \(artifact.filename)")
      continue
    }

    DatabaseManager.insertMessage(
      chatId: chatId,
      messageId: result.messageId,
      direction: "out",
      senderId: nil,
      senderName: "Agent",
      text: artifact.description ?? artifact.filename,
      mediaType: result.isPhoto ? "photo" : "document",
      mediaFileId: nil,
      taskId: nil
    )
    logInfo(
      "uploadSharedArtifacts: \(artifact.filename) uploaded to chat \(chatId) as message \(result.messageId)"
    )
  }
}

// MARK: - Callback Handler

/// Acknowledges legacy clarify inline-keyboard taps from older messages.
/// New clarification events no longer ship inline keyboards (the agent's
/// `clarify` intercept surfaces the question inline; the user's reply is
/// routed back via `handleTaskThreadReply`), but old chat history may still
/// contain pre-deprecation buttons. Just ack them so Telegram clears the
/// loading spinner.
private func handleCallback(ctx: PluginContext, query: TelegramCallbackQuery) {
  logDebug("handleCallback: callbackId=\(query.id) data=\(query.data ?? "nil")")

  guard let token = ctx.botToken else {
    logWarn("handleCallback: no bot token, cannot ack callback")
    return
  }

  telegramAnswerCallbackQuery(
    token: token, callbackQueryId: query.id,
    text: "Reply to the agent's message to continue.")
}

// MARK: - Reaction Handler

private func handleReaction(ctx: PluginContext, reaction: TelegramMessageReactionUpdated) {
  let chatId = "\(reaction.chat.id)"
  let messageId = reaction.message_id

  let addedEmojis = reaction.new_reaction.compactMap { $0.emoji }
  let removedEmojis = reaction.old_reaction.compactMap { $0.emoji }
  let userId = reaction.user.map { "\($0.id)" }

  logDebug(
    "handleReaction: chatId=\(chatId) msgId=\(messageId) user=\(userId ?? "anon") added=\(addedEmojis) removed=\(removedEmojis)"
  )

  let chatTitle = reaction.chat.title ?? reaction.chat.first_name ?? reaction.chat.username
  DatabaseManager.upsertChat(
    chatId: chatId, chatType: reaction.chat.type,
    title: chatTitle, username: reaction.chat.username)

  if let user = reaction.user {
    DatabaseManager.upsertUser(
      userId: "\(user.id)", username: user.username,
      firstName: user.first_name, lastName: user.last_name)
  }

  if let uid = userId, reaction.new_reaction.isEmpty {
    DatabaseManager.deleteReaction(chatId: chatId, messageId: messageId, userId: uid)
    logDebug("handleReaction: cleared reaction from user \(uid) on message \(messageId)")
    return
  }

  for rt in reaction.new_reaction {
    let emoji = rt.emoji ?? rt.custom_emoji_id ?? "paid"
    let isCustom = rt.type == "custom_emoji"
    DatabaseManager.upsertReaction(
      chatId: chatId, messageId: messageId,
      userId: userId, emoji: emoji, isCustom: isCustom)
  }

  if let task = DatabaseManager.getTaskByMessageId(chatId: chatId, messageId: messageId) {
    logInfo(
      "handleReaction: reaction on task \(task.taskId) (status=\(task.status)) emojis=\(addedEmojis)"
    )
  }
}

// MARK: - Health Endpoint

private func handleHealth(ctx: PluginContext) -> String {
  let registered = configGet("webhook_registered") == "true"
  let username = ctx.botUsername ?? ""
  let body: [String: Any] = [
    "ok": registered,
    "bot_username": username,
    "webhook_registered": registered,
  ]
  let bodyStr = makeJSONString(body) ?? "{}"
  return makeRouteResponse(status: 200, body: bodyStr, contentType: "application/json")
}

// MARK: - Prompt Builder

private func buildPrompt(from message: TelegramMessage) -> String {
  var parts: [String] = []

  if let text = message.text {
    parts.append(text)
  }

  if let caption = message.caption {
    parts.append(caption)
  }

  if message.photo != nil {
    parts.append("[User sent a photo]")
  }

  if let doc = message.document {
    let name = doc.file_name ?? "unnamed"
    parts.append("[User sent a document: \(name)]")
  }

  if let voice = message.voice {
    parts.append("[User sent a voice message (\(voice.duration)s)]")
  }

  return parts.joined(separator: "\n")
}

// MARK: - Artifact Handler

func handleArtifactShare(ctx: PluginContext, payload: String) -> String {
  guard configGet("auto_upload_artifacts") != "false" else {
    logDebug("handleArtifactShare: auto_upload_artifacts disabled, skipping")
    return "{\"skipped\":true}"
  }

  guard let artifact = parseJSON(payload, as: ArtifactPayload.self) else {
    logWarn("handleArtifactShare: failed to parse artifact payload")
    return "{\"error\":\"Invalid artifact payload\"}"
  }

  if artifact.is_directory == true {
    logDebug("handleArtifactShare: skipping directory artifact \(artifact.filename)")
    return "{\"skipped\":true}"
  }

  if ctx.claimArtifactUpload(artifact.host_path) {
    logDebug(
      "handleArtifactShare: \(artifact.filename) already uploaded via shared_artifacts, skipping")
    return "{\"skipped\":true,\"reason\":\"already_uploaded\"}"
  }

  guard let chatId = DatabaseManager.getLastActiveChatId() ?? ctx.activeStreamingChatId else {
    logWarn("handleArtifactShare: no active chat to upload to")
    return "{\"error\":\"No active chat\"}"
  }

  guard let token = ctx.botToken, !token.isEmpty else {
    logWarn("handleArtifactShare: no bot token configured")
    return "{\"error\":\"Bot token not configured\"}"
  }

  let file: HostFileResult
  switch readHostFile(path: artifact.host_path) {
  case .success(let f):
    file = f
  case .failure(let error):
    logError("handleArtifactShare: \(error)")
    return "{\"error\":\"Failed to read artifact file\"}"
  }

  let mimeType = artifact.mime_type ?? file.mimeType
  logDebug(
    "handleArtifactShare: uploading \(artifact.filename) (\(file.data.count) bytes, \(mimeType)) to chat \(chatId)"
  )

  guard
    let result = uploadFileToTelegram(
      token: token, chatId: chatId,
      fileData: file.data, filename: artifact.filename, mimeType: mimeType)
  else {
    logError("handleArtifactShare: failed to upload \(artifact.filename) to chat \(chatId)")
    return "{\"error\":\"Failed to upload artifact\"}"
  }

  DatabaseManager.insertMessage(
    chatId: chatId,
    messageId: result.messageId,
    direction: "out",
    senderId: nil,
    senderName: "Agent",
    text: artifact.filename,
    mediaType: result.isPhoto ? "photo" : "document",
    mediaFileId: nil,
    taskId: nil
  )

  logInfo(
    "Artifact \(artifact.filename) uploaded to chat \(chatId) as message \(result.messageId)")
  return "{\"uploaded\":true,\"message_id\":\(result.messageId)}"
}

// MARK: - Response Builder

func makeRouteResponse(status: Int, body: String, contentType: String = "text/plain") -> String {
  let resp: [String: Any] = [
    "status": status,
    "headers": ["Content-Type": contentType],
    "body": body,
  ]
  return makeJSONString(resp) ?? "{\"status\":500}"
}
