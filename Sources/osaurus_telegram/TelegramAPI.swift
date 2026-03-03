import Foundation

// MARK: - Telegram Bot API Transport

/// Makes a Telegram Bot API request via host->http_request.
/// Returns (ok, resultJSON, retryAfter).
func telegramRequest(token: String, method: String, body: [String: Any]? = nil) -> (
  ok: Bool, resultJSON: Any?, retryAfter: Int?
) {
  let bodyKeys = body.map { Array($0.keys).sorted().joined(separator: ", ") } ?? "none"
  logDebug("telegramRequest: method=\(method) bodyKeys=[\(bodyKeys)]")

  guard let httpRequest = hostAPI?.pointee.http_request else {
    logError("http_request not available")
    return (false, nil, nil)
  }

  var request: [String: Any] = [
    "method": "POST",
    "url": "https://api.telegram.org/bot\(token)/\(method)",
    "headers": ["Content-Type": "application/json"],
    "timeout_ms": 10000,
  ]

  if let body {
    if let bodyData = try? JSONSerialization.data(withJSONObject: body),
      let bodyStr = String(data: bodyData, encoding: .utf8)
    {
      request["body"] = bodyStr
    } else {
      logWarn("telegramRequest: failed to serialize body for \(method)")
    }
  }

  guard let requestJSON = makeJSONString(request) else {
    logError("Failed to serialize request for \(method)")
    return (false, nil, nil)
  }

  let responseStr: String? = requestJSON.withCString { ptr in
    guard let responsePtr = httpRequest(ptr) else { return nil }
    return String(cString: responsePtr)
  }
  guard let responseStr else {
    logError("No response from http_request for \(method)")
    return (false, nil, nil)
  }

  guard let responseData = responseStr.data(using: .utf8),
    let httpResponse = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
  else {
    logError(
      "Failed to parse http_request response for \(method): \(String(responseStr.prefix(200)))")
    return (false, nil, nil)
  }

  let httpStatus = httpResponse["status"] as? Int ?? 0
  guard let httpBody = httpResponse["body"] as? String,
    let bodyData = httpBody.data(using: .utf8),
    let tgResponse = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
  else {
    logError(
      "Telegram \(method) returned non-JSON body (HTTP \(httpStatus)): \(String((httpResponse["body"] as? String ?? "").prefix(200)))"
    )
    return (false, nil, nil)
  }

  let ok = tgResponse["ok"] as? Bool ?? false
  let result = tgResponse["result"]
  let description = tgResponse["description"] as? String
  let parameters = tgResponse["parameters"] as? [String: Any]
  let retryAfter = parameters?["retry_after"] as? Int

  logDebug(
    "telegramRequest: \(method) HTTP \(httpStatus) ok=\(ok)\(description.map { " desc=\"\($0)\"" } ?? "")"
  )

  if !ok {
    if httpStatus == 401 {
      logError("Telegram \(method): unauthorized (bad token)")
      configSet("webhook_registered", "false")
    } else if httpStatus == 429, let retryAfter {
      logWarn("Telegram \(method): rate limited, retry after \(retryAfter)s")
    } else {
      logWarn("Telegram \(method) failed: \(description ?? "unknown error") (HTTP \(httpStatus))")
    }
  }

  return (ok, result, retryAfter)
}

// MARK: - Typed Wrappers

/// Validates a bot token and returns bot info.
func telegramGetMe(token: String) -> (botId: String, username: String)? {
  let (ok, result, _) = telegramRequest(token: token, method: "getMe")
  guard ok, let dict = result as? [String: Any] else { return nil }

  let botId = dict["id"]
  let username = dict["username"] as? String ?? ""

  return (botId: "\(botId ?? "")", username: username)
}

/// Registers a webhook URL with Telegram.
func telegramSetWebhook(token: String, url: String, secretToken: String) -> Bool {
  let body: [String: Any] = [
    "url": url,
    "secret_token": secretToken,
    "allowed_updates": ["message", "callback_query"],
    "drop_pending_updates": false,
  ]
  let (ok, _, _) = telegramRequest(token: token, method: "setWebhook", body: body)
  return ok
}

/// Removes the webhook.
func telegramDeleteWebhook(token: String) -> Bool {
  let (ok, _, _) = telegramRequest(token: token, method: "deleteWebhook")
  return ok
}

/// Sends a text message. Returns the sent message_id on success.
func telegramSendMessage(
  token: String,
  chatId: String,
  text: String,
  parseMode: String? = nil,
  replyTo: Int? = nil,
  replyMarkup: [String: Any]? = nil
) -> Int? {
  var body: [String: Any] = [
    "chat_id": chatId,
    "text": text,
  ]
  if let parseMode { body["parse_mode"] = parseMode }
  if let replyTo { body["reply_to_message_id"] = replyTo }
  if let replyMarkup { body["reply_markup"] = replyMarkup }

  let (ok, result, _) = telegramRequest(token: token, method: "sendMessage", body: body)

  if !ok, parseMode != nil {
    logWarn("sendMessage failed with parse_mode=\(parseMode!), retrying as plain text")
    var plainBody: [String: Any] = ["chat_id": chatId, "text": text]
    if let replyTo { plainBody["reply_to_message_id"] = replyTo }
    if let replyMarkup { plainBody["reply_markup"] = replyMarkup }
    let (retryOk, retryResult, _) = telegramRequest(
      token: token, method: "sendMessage", body: plainBody)
    guard retryOk, let dict = retryResult as? [String: Any] else {
      logWarn("sendMessage: plain text retry also failed for chat \(chatId)")
      return nil
    }
    return dict["message_id"] as? Int
  }

  guard ok, let dict = result as? [String: Any] else {
    logDebug("sendMessage: failed for chat \(chatId)")
    return nil
  }
  return dict["message_id"] as? Int
}

/// Edits the text of an existing message.
func telegramEditMessage(
  token: String,
  chatId: String,
  messageId: Int,
  text: String,
  parseMode: String? = nil
) -> Bool {
  var body: [String: Any] = [
    "chat_id": chatId,
    "message_id": messageId,
    "text": text,
  ]
  if let parseMode { body["parse_mode"] = parseMode }

  let (ok, _, _) = telegramRequest(token: token, method: "editMessageText", body: body)
  if !ok, parseMode != nil {
    logWarn("editMessageText failed with parse_mode=\(parseMode!), retrying as plain text")
    let plainBody: [String: Any] = [
      "chat_id": chatId,
      "message_id": messageId,
      "text": text,
    ]
    let (retryOk, _, _) = telegramRequest(token: token, method: "editMessageText", body: plainBody)
    return retryOk
  }
  return ok
}

/// Deletes a message.
func telegramDeleteMessage(token: String, chatId: String, messageId: Int) -> Bool {
  let body: [String: Any] = [
    "chat_id": chatId,
    "message_id": messageId,
  ]
  let (ok, _, _) = telegramRequest(token: token, method: "deleteMessage", body: body)
  return ok
}

/// Sends a chat action (e.g. "typing").
func telegramSendChatAction(token: String, chatId: String, action: String = "typing") {
  let body: [String: Any] = [
    "chat_id": chatId,
    "action": action,
  ]
  _ = telegramRequest(token: token, method: "sendChatAction", body: body)
}

/// Answers a callback query to dismiss the loading indicator.
func telegramAnswerCallbackQuery(token: String, callbackQueryId: String, text: String? = nil) {
  var body: [String: Any] = ["callback_query_id": callbackQueryId]
  if let text { body["text"] = text }
  _ = telegramRequest(token: token, method: "answerCallbackQuery", body: body)
}

/// Streams a partial message draft to a private chat (Bot API 9.0+).
/// The draft is displayed progressively and replaced when sendMessage is called.
/// Only works in private chats; returns false for groups.
func telegramSendMessageDraft(
  token: String,
  chatId: String,
  draftId: Int,
  text: String,
  parseMode: String? = nil
) -> Bool {
  var body: [String: Any] = [
    "chat_id": chatId,
    "draft_id": draftId,
    "text": String(text.prefix(4096)),
  ]
  if let parseMode { body["parse_mode"] = parseMode }
  let (ok, _, _) = telegramRequest(token: token, method: "sendMessageDraft", body: body)
  if !ok {
    logDebug("sendMessageDraft: failed for chat \(chatId) draftId=\(draftId)")
  }
  return ok
}

/// Sends a long response, splitting into multiple messages as needed.
func telegramSendLongMessage(
  token: String,
  chatId: String,
  text: String,
  parseMode: String? = nil,
  replyTo: Int? = nil
) -> Int? {
  if text.count <= 4096 {
    return telegramSendMessage(
      token: token, chatId: chatId, text: text,
      parseMode: parseMode, replyTo: replyTo
    )
  }

  // Split into chunks and send sequentially
  let chunks = splitMessage(text)
  var lastMsgId: Int? = nil
  for (i, chunk) in chunks.enumerated() {
    // Only apply parseMode and replyTo to the first chunk
    lastMsgId = telegramSendMessage(
      token: token,
      chatId: chatId,
      text: chunk,
      parseMode: i == 0 ? parseMode : nil,
      replyTo: i == 0 ? replyTo : nil
    )
  }
  return lastMsgId
}
