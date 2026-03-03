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
    "handleWebhook: update_id=\(update.update_id) hasMessage=\(update.message != nil) hasCallback=\(update.callback_query != nil) agentAddress=\(agentAddress ?? "nil")"
  )

  if let message = update.message {
    handleMessage(ctx: ctx, message: message, agentAddress: agentAddress)
  } else if let callbackQuery = update.callback_query {
    handleCallback(ctx: ctx, query: callbackQuery)
  } else {
    logDebug("handleWebhook: update has neither message nor callback_query, ignoring")
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
  logDebug(
    "handleMessage: stored incoming message (text=\((message.text ?? message.caption)?.count ?? 0) chars, media=\(mediaType ?? "none"))"
  )

  if let allowed = configGet("allowed_chat_ids"), !allowed.isEmpty {
    let allowedIds = Set(
      allowed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    if !allowedIds.contains(chatId) {
      guard let token = ctx.botToken else {
        logWarn("handleMessage: chat \(chatId) not allowed and no bot token to send rejection")
        return
      }
      _ = telegramSendMessage(token: token, chatId: chatId, text: "Not authorized.")
      logWarn("Chat \(chatId) not in allowed_chat_ids [\(allowed)], rejecting")
      return
    }
    logDebug("handleMessage: chat \(chatId) is in allowed_chat_ids")
  }

  if let text = message.text, text.hasPrefix("/start") {
    guard let token = ctx.botToken else {
      logWarn("handleMessage: /start received but no bot token")
      return
    }
    logDebug("handleMessage: /start command received")
    let welcome =
      "Hello! I'm connected to your Osaurus agent. Send me a message and I'll get to work."
    _ = telegramSendMessage(
      token: token, chatId: chatId, text: welcome, replyTo: message.message_id)
    return
  }

  if let text = message.text, text.hasPrefix("/clear") {
    guard let token = ctx.botToken else {
      logWarn("handleMessage: /clear received but no bot token")
      return
    }
    logDebug("handleMessage: /clear command received for chat \(chatId)")
    DatabaseManager.clearChat(chatId: chatId)
    _ = telegramSendMessage(
      token: token, chatId: chatId,
      text: "Conversation cleared. Send a new message to start fresh.",
      replyTo: message.message_id)
    return
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

  if let pendingTask = DatabaseManager.getAwaitingClarification(chatId: chatId) {
    logDebug("handleMessage: found pending clarification for task \(pendingTask.taskId)")
    if let clarify = hostAPI?.pointee.dispatch_clarify {
      pendingTask.taskId.withCString { tid in
        prompt.withCString { p in
          clarify(tid, p)
        }
      }
      logDebug("handleMessage: sent clarification response for task \(pendingTask.taskId)")
    } else {
      logWarn("handleMessage: dispatch_clarify not available, cannot respond to clarification")
    }
    DatabaseManager.updateTask(taskId: pendingTask.taskId, status: "running")
    _ = telegramSendMessage(
      token: token, chatId: chatId, text: "\u{2705} Response sent, continuing...")
    return
  }

  telegramSendChatAction(token: token, chatId: chatId)

  let agentMode = configGet("agent_mode") ?? "work"
  logDebug(
    "handleMessage: agent_mode=\(agentMode) isPrivate=\(isPrivateChat) complete_stream=\(hostAPI?.pointee.complete_stream != nil)"
  )

  if agentMode == "chat" && isPrivateChat && hostAPI?.pointee.complete_stream != nil {
    logDebug("handleMessage: -> chat mode streaming path")
    handleChatModeStreaming(
      token: token, chatId: chatId,
      prompt: prompt, messageId: message.message_id,
      agentAddress: agentAddress
    )
    return
  }

  logDebug("handleMessage: -> work mode dispatch path")

  let titleText = message.text ?? message.caption ?? "Media message"
  let firstLine = String(titleText.prefix(60))

  guard let dispatch = hostAPI?.pointee.dispatch else {
    logError("dispatch not available")
    _ = telegramSendMessage(token: token, chatId: chatId, text: "Agent dispatch unavailable.")
    return
  }

  let dispatchMode = (agentMode == "chat" && !isPrivateChat) ? "work" : agentMode
  var dispatchPayload: [String: Any] = [
    "prompt": prompt,
    "mode": dispatchMode,
    "title": "Telegram: \(firstLine)",
  ]
  if let agentAddress { dispatchPayload["agent_address"] = agentAddress }
  guard let dispatchJSON = makeJSONString(dispatchPayload) else {
    logError("Failed to build dispatch JSON from payload keys: \(Array(dispatchPayload.keys))")
    return
  }

  logDebug(
    "handleMessage: dispatching with mode=\(dispatchMode) payload=\(String(dispatchJSON.prefix(300)))"
  )

  let dispatchResultStr: String? = dispatchJSON.withCString { ptr in
    guard let resultPtr = dispatch(ptr) else { return nil }
    return String(cString: resultPtr)
  }
  guard let resultStr = dispatchResultStr else {
    logError("dispatch returned nil")
    _ = telegramSendMessage(token: token, chatId: chatId, text: "Failed to start agent task.")
    return
  }

  logDebug("handleMessage: dispatch result=\(String(resultStr.prefix(300)))")

  guard let dispatchResult = parseJSON(resultStr, as: DispatchResponse.self),
    let taskId = dispatchResult.id
  else {
    logError("Failed to parse dispatch response: \(resultStr)")
    return
  }

  DatabaseManager.insertTask(taskId: taskId, chatId: chatId, messageId: message.message_id)
  logDebug("handleMessage: inserted task \(taskId) for chat \(chatId)")

  let sendTypingEnabled = configGet("send_typing") != "false"
  if sendTypingEnabled && !isPrivateChat {
    if let statusMsgId = telegramSendMessage(
      token: token, chatId: chatId, text: "\u{23F3} Working on it...")
    {
      DatabaseManager.updateTask(taskId: taskId, statusMsgId: statusMsgId)
      logDebug("handleMessage: created status message \(statusMsgId) for task \(taskId)")
    } else {
      logWarn("handleMessage: failed to send status message for task \(taskId)")
    }
  }

  logInfo("Dispatched task \(taskId) for chat \(chatId)")
}

// MARK: - Chat Mode Streaming

/// State accumulated during streaming inference, passed through the C callback via user_data.
final class ChatStreamState {
  var accumulated = ""
  var lastFlushLength = 0
  var receivedFirstChunk = false
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

    if !state.receivedFirstChunk {
      state.receivedFirstChunk = true
      logDebug("streamChunkCallback: first chunk received (\(chunk.count) chars)")
    }

    if let content = extractStreamContent(chunk) {
      state.accumulated += content
    }

    let newChars = state.accumulated.count - state.lastFlushLength
    if newChars >= ChatStreamState.flushThreshold {
      logDebug("streamChunkCallback: flush at \(state.accumulated.count) chars")
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

private func handleChatModeStreaming(
  token: String, chatId: String, prompt: String, messageId: Int, agentAddress: String?
) {
  logDebug(
    "handleChatModeStreaming: chatId=\(chatId) prompt=\(prompt.count) chars msgId=\(messageId)")

  let chatDraftId = draftId(for: "chat-\(chatId)-\(messageId)")

  let draftOk = telegramSendMessageDraft(
    token: token, chatId: chatId,
    draftId: chatDraftId, text: "Thinking..."
  )
  logDebug("handleChatModeStreaming: initial draft sent ok=\(draftOk)")

  DispatchQueue.global(qos: .userInitiated).async {
    let historyJSON = DatabaseManager.getMessages(chatId: chatId, limit: 20)
    let messages = buildCompletionMessages(historyJSON: historyJSON, currentPrompt: prompt)
    logDebug("handleChatModeStreaming: built \(messages.count) completion messages from history")

    var request: [String: Any] = [
      "model": "",
      "messages": messages,
      "max_tokens": 4096,
    ]
    if let agentAddress { request["agent_address"] = agentAddress }
    guard let requestJSON = makeJSONString(request) else {
      logError("handleChatModeStreaming: failed to serialize completion request")
      _ = telegramSendMessage(token: token, chatId: chatId, text: "Failed to build request.")
      return
    }

    logDebug("handleChatModeStreaming: calling complete_stream (\(requestJSON.count) chars)")

    let state = ChatStreamState(token: token, chatId: chatId, draftId: chatDraftId)
    let statePtr = Unmanaged.passRetained(state).toOpaque()

    let result: UnsafePointer<CChar>? = requestJSON.withCString { ptr in
      hostAPI?.pointee.complete_stream?(ptr, streamChunkCallback, statePtr)
    }

    var streamError: String?
    if let result {
      let resultStr = String(cString: result)
      free(UnsafeMutableRawPointer(mutating: result))
      logDebug(
        "handleChatModeStreaming: complete_stream returned: \(String(resultStr.prefix(300)))")
      if let resultData = resultStr.data(using: .utf8),
        let resultJSON = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any],
        let errorMsg = resultJSON["error"] as? String
      {
        logError("Streaming inference error: \(errorMsg)")
        streamError = errorMsg
      }
    } else {
      logDebug("handleChatModeStreaming: complete_stream returned nil (no error object)")
    }

    logDebug(
      "handleChatModeStreaming: stream finished, accumulated=\(state.accumulated.count) chars, error=\(streamError ?? "none")"
    )

    let finalText: String
    if let streamError, state.accumulated.isEmpty {
      finalText = "Error: \(streamError)"
    } else if state.accumulated.isEmpty {
      logWarn("handleChatModeStreaming: no content accumulated and no error")
      finalText = "I couldn't generate a response."
    } else {
      finalText = state.accumulated
    }

    let msgId = telegramSendLongMessage(
      token: token, chatId: chatId, text: finalText, replyTo: messageId)
    logDebug("handleChatModeStreaming: sent final message, msgId=\(msgId.map { "\($0)" } ?? "nil")")

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

    logInfo("Chat mode streaming complete for chat \(chatId)")
  }
}

// MARK: - Callback Handler

private func handleCallback(ctx: PluginContext, query: TelegramCallbackQuery) {
  logDebug("handleCallback: callbackId=\(query.id) data=\(query.data ?? "nil")")

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
  logDebug("handleCallback: taskId=\(taskId) optionIndex=\(optionIndex)")

  guard let task = DatabaseManager.getTask(taskId: taskId) else {
    logWarn("Callback for unknown task: \(taskId)")
    return
  }

  guard let token = ctx.botToken else {
    logWarn("handleCallback: no bot token, cannot process callback for task \(taskId)")
    return
  }

  var selectedText = "Option \(optionIndex + 1)"
  if let optionsJSON = task.clarificationOptions,
    let optionsData = optionsJSON.data(using: .utf8),
    let options = try? JSONSerialization.jsonObject(with: optionsData) as? [String],
    optionIndex < options.count
  {
    selectedText = options[optionIndex]
  }
  logDebug("handleCallback: selectedText=\"\(selectedText)\"")

  if let clarify = hostAPI?.pointee.dispatch_clarify {
    taskId.withCString { tid in
      selectedText.withCString { sel in
        clarify(tid, sel)
      }
    }
    logDebug("handleCallback: sent clarification response to host")
  } else {
    logWarn("handleCallback: dispatch_clarify not available, clarification not sent to host")
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

  DatabaseManager.updateTask(taskId: taskId, status: "running", clarificationOptions: nil)
  logDebug("handleCallback: task \(taskId) updated to running")
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
