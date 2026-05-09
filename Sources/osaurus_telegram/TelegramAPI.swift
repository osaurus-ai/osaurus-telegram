import Foundation

// MARK: - Telegram Bot API Transport

/// Result of a Bot API call. `description` is set on failure so callers can
/// surface it to the agent via tool envelopes.
struct TelegramResult {
  let ok: Bool
  let result: Any?
  let description: String
  let httpStatus: Int
  let retryAfter: Int?
}

/// Makes a Telegram Bot API request via host->http_request.
func telegramRequest(token: String, method: String, body: [String: Any]? = nil) -> TelegramResult {
  let bodyKeys = body.map { Array($0.keys).sorted().joined(separator: ", ") } ?? "none"
  logDebug("telegramRequest: method=\(method) bodyKeys=[\(bodyKeys)]")

  guard let httpRequest = hostAPI?.pointee.http_request else {
    logError("http_request not available")
    return TelegramResult(
      ok: false, result: nil, description: "http_request unavailable",
      httpStatus: 0, retryAfter: nil)
  }

  var request: [String: Any] = [
    "method": "POST",
    "url": "https://api.telegram.org/bot\(token)/\(method)",
    "headers": ["Content-Type": "application/json"],
    "timeout_ms": 10_000,
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
    return TelegramResult(
      ok: false, result: nil, description: "request serialize failed",
      httpStatus: 0, retryAfter: nil)
  }

  guard let responseStr = callHostString(httpRequest, requestJSON) else {
    logError("No response from http_request for \(method)")
    return TelegramResult(
      ok: false, result: nil, description: "no response",
      httpStatus: 0, retryAfter: nil)
  }

  guard let httpResponse = parseJSONObject(responseStr) else {
    logError(
      "Failed to parse http_request response for \(method): \(String(responseStr.prefix(200)))")
    return TelegramResult(
      ok: false, result: nil, description: "malformed http response",
      httpStatus: 0, retryAfter: nil)
  }

  let httpStatus = httpResponse["status"] as? Int ?? 0
  guard let httpBody = httpResponse["body"] as? String,
    let bodyData = httpBody.data(using: .utf8),
    let tgResponse = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
  else {
    logError(
      "Telegram \(method) returned non-JSON body (HTTP \(httpStatus)): \(String((httpResponse["body"] as? String ?? "").prefix(200)))"
    )
    return TelegramResult(
      ok: false, result: nil, description: "non-json telegram body",
      httpStatus: httpStatus, retryAfter: nil)
  }

  let ok = tgResponse["ok"] as? Bool ?? false
  let result = tgResponse["result"]
  let description = tgResponse["description"] as? String ?? ""
  let parameters = tgResponse["parameters"] as? [String: Any]
  let retryAfter = parameters?["retry_after"] as? Int

  logDebug(
    "telegramRequest: \(method) HTTP \(httpStatus) ok=\(ok)\(description.isEmpty ? "" : " desc=\"\(description)\"")"
  )

  if !ok {
    if httpStatus == 429, let retryAfter {
      logWarn("Telegram \(method): rate limited, retry after \(retryAfter)s")
    } else if httpStatus == 401 {
      logError("Telegram \(method): unauthorized (bad token)")
    } else {
      logWarn("Telegram \(method) failed: \(description) (HTTP \(httpStatus))")
    }
  }

  return TelegramResult(
    ok: ok, result: result, description: description,
    httpStatus: httpStatus, retryAfter: retryAfter)
}

// MARK: - Typed Wrappers

/// Validates a bot token and returns bot info.
func telegramGetMe(token: String) -> (botId: String, username: String)? {
  let response = telegramRequest(token: token, method: "getMe")
  guard response.ok, let dict = response.result as? [String: Any] else { return nil }
  let botId = dict["id"]
  let username = dict["username"] as? String ?? ""
  return (botId: "\(botId ?? "")", username: username)
}

/// Registers a webhook URL with Telegram. We only ask for plain `message`
/// updates because that's all the new agent-driven design consumes.
func telegramSetWebhook(token: String, url: String, secretToken: String) -> Bool {
  let body: [String: Any] = [
    "url": url,
    "secret_token": secretToken,
    "allowed_updates": ["message"],
    "drop_pending_updates": true,
  ]
  return telegramRequest(token: token, method: "setWebhook", body: body).ok
}

/// Removes the webhook.
func telegramDeleteWebhook(token: String) -> Bool {
  return telegramRequest(token: token, method: "deleteWebhook").ok
}

/// Sends a text message. Returns `(ok, description)` so callers can surface
/// the Telegram error string to the agent through tool envelopes.
func telegramSendMessage(
  token: String,
  chatId: Int64,
  text: String,
  parseMode: String? = nil
) -> (ok: Bool, description: String) {
  var body: [String: Any] = [
    "chat_id": chatId,
    "text": text,
  ]
  if let parseMode, !parseMode.isEmpty { body["parse_mode"] = parseMode }

  let response = telegramRequest(token: token, method: "sendMessage", body: body)
  if response.ok { return (true, "") }

  // If parse_mode tripped, retry once as plain text. This matches the prior
  // forgiving behavior and avoids losing the agent's reply on minor markup
  // errors.
  if !response.ok, parseMode != nil, !(parseMode?.isEmpty ?? true) {
    logWarn("sendMessage failed with parse_mode=\(parseMode!), retrying as plain text")
    let plainBody: [String: Any] = ["chat_id": chatId, "text": text]
    let retry = telegramRequest(token: token, method: "sendMessage", body: plainBody)
    return (retry.ok, retry.ok ? "" : retry.description)
  }

  return (false, response.description)
}

/// Sends a chat action (e.g. "typing").
func telegramSendChatAction(
  token: String, chatId: Int64, action: String = "typing"
) -> (ok: Bool, description: String) {
  let body: [String: Any] = [
    "chat_id": chatId,
    "action": action,
  ]
  let response = telegramRequest(token: token, method: "sendChatAction", body: body)
  return (response.ok, response.ok ? "" : response.description)
}

/// Sends a photo by URL. Bot API accepts a public URL string for `photo`,
/// so no multipart upload is needed for the agent's `reply_photo` tool.
func telegramSendPhotoByURL(
  token: String, chatId: Int64, photoURL: String, caption: String?
) -> (ok: Bool, description: String) {
  var body: [String: Any] = [
    "chat_id": chatId,
    "photo": photoURL,
  ]
  if let caption, !caption.isEmpty {
    body["caption"] = String(caption.prefix(1024))
  }
  let response = telegramRequest(token: token, method: "sendPhoto", body: body)
  return (response.ok, response.ok ? "" : response.description)
}
