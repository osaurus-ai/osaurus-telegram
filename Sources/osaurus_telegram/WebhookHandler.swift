import Foundation

// MARK: - Route Handler

func handleRoute(ctx: PluginContext, requestJSON: String) -> String {
  guard let req = parseJSON(requestJSON, as: RouteRequest.self) else {
    return makeRouteResponse(status: 400, body: "{\"error\":\"Invalid request\"}")
  }

  switch req.route_id {
  case "webhook":
    return handleWebhook(ctx: ctx, req: req)
  case "health":
    return handleHealth(ctx: ctx)
  default:
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
  guard let secret = ctx.webhookSecret else {
    logWarn("Webhook request rejected: no webhook secret configured")
    return makeRouteResponse(status: 401, body: "{\"error\":\"Unauthorized\"}")
  }

  guard let headers = req.headers else {
    logWarn("Webhook request rejected: no headers")
    return makeRouteResponse(status: 401, body: "{\"error\":\"Unauthorized\"}")
  }

  guard let headerToken = extractSecretHeader(from: headers), headerToken == secret else {
    logWarn("Webhook request rejected: invalid secret token")
    return makeRouteResponse(status: 401, body: "{\"error\":\"Unauthorized\"}")
  }

  guard let body = req.body,
    let update = parseJSON(body, as: TelegramUpdate.self)
  else {
    logWarn("Webhook: failed to parse update body")
    return makeRouteResponse(status: 200, body: "ok")
  }

  if let message = update.message {
    handleMessage(ctx: ctx, message: message)
  } else if let callbackQuery = update.callback_query {
    handleCallback(ctx: ctx, query: callbackQuery)
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

private func handleMessage(ctx: PluginContext, message: TelegramMessage) {
  let chat = message.chat
  let chatId = "\(chat.id)"
  let isPrivateChat = chat.type == "private"

  let chatTitle = chat.title ?? chat.first_name ?? chat.username
  DatabaseManager.upsertChat(
    chatId: chatId,
    chatType: chat.type,
    title: chatTitle,
    username: chat.username
  )

  let senderName = formatSenderName(from: message.from)
  let mediaType = detectMediaType(message: message)
  let mediaFileId = detectMediaFileId(message: message)

  DatabaseManager.insertMessage(
    chatId: chatId,
    messageId: message.message_id,
    direction: "in",
    senderId: message.from.map { "\($0.id)" },
    senderName: senderName,
    text: message.text ?? message.caption,
    mediaType: mediaType,
    mediaFileId: mediaFileId,
    taskId: nil
  )

  if let allowed = configGet("allowed_chat_ids"), !allowed.isEmpty {
    let allowedIds = Set(
      allowed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    if !allowedIds.contains(chatId) {
      guard let token = ctx.botToken else { return }
      _ = telegramSendMessage(token: token, chatId: chatId, text: "Not authorized.")
      logWarn("Chat \(chatId) not in allowed_chat_ids, rejecting")
      return
    }
  }

  if let text = message.text, text.hasPrefix("/start") {
    guard let token = ctx.botToken else { return }
    let welcome =
      "Hello! I'm connected to your Osaurus agent. Send me a message and I'll get to work."
    _ = telegramSendMessage(
      token: token, chatId: chatId, text: welcome, replyTo: message.message_id)
    return
  }

  let prompt = buildPrompt(from: message)
  guard !prompt.isEmpty else { return }
  guard let token = ctx.botToken else { return }

  telegramSendChatAction(token: token, chatId: chatId)

  let agentMode = configGet("agent_mode") ?? "work"

  // Chat mode streaming for private chats
  if agentMode == "chat" && isPrivateChat && hostAPI?.pointee.complete_stream != nil {
    handleChatModeStreaming(
      token: token, chatId: chatId,
      prompt: prompt, messageId: message.message_id
    )
    return
  }

  // Work mode (or fallback): dispatch agent task
  let titleText = message.text ?? message.caption ?? "Media message"
  let firstLine = String(titleText.prefix(60))

  guard let dispatch = hostAPI?.pointee.dispatch else {
    logError("dispatch not available")
    _ = telegramSendMessage(token: token, chatId: chatId, text: "Agent dispatch unavailable.")
    return
  }

  let dispatchPayload: [String: Any] = [
    "prompt": prompt,
    "mode": agentMode,
    "title": "Telegram: \(firstLine)",
  ]
  guard let dispatchJSON = makeJSONString(dispatchPayload) else {
    logError("Failed to build dispatch JSON")
    return
  }

  guard let resultPtr = dispatch(makeCString(dispatchJSON)) else {
    logError("dispatch returned nil")
    _ = telegramSendMessage(token: token, chatId: chatId, text: "Failed to start agent task.")
    return
  }
  let resultStr = String(cString: resultPtr)

  guard let dispatchResult = parseJSON(resultStr, as: DispatchResponse.self),
    let taskId = dispatchResult.id
  else {
    logError("Failed to parse dispatch response: \(resultStr)")
    return
  }

  DatabaseManager.insertTask(taskId: taskId, chatId: chatId, messageId: message.message_id)

  // For private chats, the task handler uses sendMessageDraft for progress.
  // For groups, create a status message that can be edited.
  let sendTypingEnabled = configGet("send_typing") != "false"
  if sendTypingEnabled && !isPrivateChat {
    if let statusMsgId = telegramSendMessage(
      token: token, chatId: chatId, text: "\u{23F3} Working on it...")
    {
      DatabaseManager.updateTask(taskId: taskId, statusMsgId: statusMsgId)
    }
  }

  logInfo("Dispatched task \(taskId) for chat \(chatId)")
}

// MARK: - Chat Mode Streaming

/// State accumulated during streaming inference, passed through the C callback via user_data.
final class ChatStreamState {
  var accumulated = ""
  var lastFlushLength = 0
  let token: String
  let chatId: String
  let draftId: Int
  static let flushThreshold = 100

  init(token: String, chatId: String, draftId: Int) {
    self.token = token
    self.chatId = chatId
    self.draftId = draftId
  }
}

/// C-compatible callback for complete_stream chunks.
private let streamChunkCallback:
  @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { chunkPtr, userData in
    guard let chunkPtr, let userData else { return }
    let state = Unmanaged<ChatStreamState>.fromOpaque(userData).takeUnretainedValue()
    let chunk = String(cString: chunkPtr)

    if let content = extractStreamContent(chunk) {
      state.accumulated += content
    } else {
      state.accumulated += chunk
    }

    let newChars = state.accumulated.count - state.lastFlushLength
    if newChars >= ChatStreamState.flushThreshold {
      _ = telegramSendMessageDraft(
        token: state.token,
        chatId: state.chatId,
        draftId: state.draftId,
        text: String(state.accumulated.prefix(4096))
      )
      state.lastFlushLength = state.accumulated.count
    }
  }

/// Extracts the text content from an OpenAI-compatible streaming chunk JSON.
func extractStreamContent(_ chunk: String) -> String? {
  guard let data = chunk.data(using: .utf8),
    let parsed = parseJSON(chunk, as: StreamChunk.self),
    let choices = parsed.choices,
    let first = choices.first,
    let delta = first.delta,
    let content = delta.content
  else {
    return nil
  }
  _ = data
  return content
}

/// Builds an OpenAI-compatible messages array from chat history + the current prompt.
func buildCompletionMessages(historyJSON: String, currentPrompt: String) -> [[String: Any]] {
  var messages: [[String: Any]] = [
    [
      "role": "system",
      "content":
        "You are a helpful assistant communicating via Telegram. Keep responses concise and well-formatted.",
    ]
  ]

  if let data = historyJSON.data(using: .utf8),
    let history = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
  {
    for msg in history.reversed() {
      let direction = msg["direction"] as? String
      let text = msg["text"] as? String ?? ""
      guard !text.isEmpty else { continue }
      let role = direction == "out" ? "assistant" : "user"
      messages.append(["role": role, "content": text])
    }
  }

  messages.append(["role": "user", "content": currentPrompt])
  return messages
}

private func handleChatModeStreaming(token: String, chatId: String, prompt: String, messageId: Int)
{
  let chatDraftId = draftId(for: "chat-\(chatId)-\(messageId)")

  _ = telegramSendMessageDraft(
    token: token, chatId: chatId,
    draftId: chatDraftId, text: "Thinking..."
  )

  DispatchQueue.global(qos: .userInitiated).async {
    let historyJSON = DatabaseManager.getMessages(chatId: chatId, limit: 20)
    let messages = buildCompletionMessages(historyJSON: historyJSON, currentPrompt: prompt)

    let request: [String: Any] = [
      "model": "",
      "messages": messages,
      "max_tokens": 4096,
    ]
    guard let requestJSON = makeJSONString(request) else {
      _ = telegramSendMessage(token: token, chatId: chatId, text: "Failed to build request.")
      return
    }

    let state = ChatStreamState(token: token, chatId: chatId, draftId: chatDraftId)
    let statePtr = Unmanaged.passRetained(state).toOpaque()

    let result = hostAPI?.pointee.complete_stream?(
      makeCString(requestJSON),
      streamChunkCallback,
      statePtr
    )

    let finalText =
      state.accumulated.isEmpty ? "I couldn't generate a response." : state.accumulated

    let msgId = telegramSendLongMessage(
      token: token, chatId: chatId, text: finalText, replyTo: messageId)

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

    if let result {
      free(UnsafeMutableRawPointer(mutating: result))
    }

    logInfo("Chat mode streaming complete for chat \(chatId)")
  }
}

// MARK: - Callback Handler

private func handleCallback(ctx: PluginContext, query: TelegramCallbackQuery) {
  guard let data = query.data, data.hasPrefix("clarify:") else {
    logWarn("Callback query with unrecognized data: \(query.data ?? "nil")")
    return
  }

  let parts = data.split(separator: ":", maxSplits: 2)
  guard parts.count == 3,
    let optionIndex = Int(parts[2])
  else {
    logWarn("Malformed clarify callback data: \(data)")
    return
  }

  let taskId = String(parts[1])

  guard DatabaseManager.getTask(taskId: taskId) != nil else {
    logWarn("Callback for unknown task: \(taskId)")
    return
  }

  guard let token = ctx.botToken else { return }

  let selectedText = "Option \(optionIndex + 1)"

  if let clarify = hostAPI?.pointee.dispatch_clarify {
    clarify(makeCString(taskId), makeCString(selectedText))
  }

  telegramAnswerCallbackQuery(
    token: token, callbackQueryId: query.id, text: "Selected: \(selectedText)")

  if let message = query.message {
    let msgChatId = "\(message.chat.id)"
    _ = telegramEditMessage(
      token: token,
      chatId: msgChatId,
      messageId: message.message_id,
      text: "\u{2705} \(selectedText)"
    )
  }

  DatabaseManager.updateTask(taskId: taskId, status: "running")
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

// MARK: - Response Builder

func makeRouteResponse(status: Int, body: String, contentType: String = "text/plain") -> String {
  let resp: [String: Any] = [
    "status": status,
    "headers": ["Content-Type": contentType],
    "body": body,
  ]
  return makeJSONString(resp) ?? "{\"status\":500}"
}
