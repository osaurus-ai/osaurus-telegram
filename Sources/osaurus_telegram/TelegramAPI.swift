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

// MARK: - getWebhookInfo

/// Snapshot of Telegram's view of our registered webhook. Used by
/// `setupWebhook` to confirm what Telegram has actually stored, and to
/// surface delivery failures (`last_error_message`) that `setWebhook`
/// alone cannot detect — `setWebhook` only validates the request, not
/// whether Telegram can subsequently reach the URL.
struct TelegramWebhookInfo {
  let url: String
  let pendingUpdateCount: Int
  let lastErrorDate: Int
  let lastErrorMessage: String
  let lastSyncErrorDate: Int

  /// True if Telegram reported a delivery error within `staleAfterSeconds`.
  func hasRecentError(staleAfterSeconds: Int = 300) -> Bool {
    if lastErrorDate == 0 { return false }
    let now = Int(Date().timeIntervalSince1970)
    return (now - lastErrorDate) < staleAfterSeconds
  }
}

func telegramGetWebhookInfo(token: String) -> TelegramWebhookInfo? {
  let response = telegramRequest(token: token, method: "getWebhookInfo")
  guard response.ok, let dict = response.result as? [String: Any] else {
    return nil
  }
  return TelegramWebhookInfo(
    url: dict["url"] as? String ?? "",
    pendingUpdateCount: dict["pending_update_count"] as? Int ?? 0,
    lastErrorDate: dict["last_error_date"] as? Int ?? 0,
    lastErrorMessage: dict["last_error_message"] as? String ?? "",
    lastSyncErrorDate: dict["last_synchronization_error_date"] as? Int ?? 0
  )
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

// MARK: - setMessageReaction
//
// Used as the "loading" indicator: the webhook handler reacts with 👀 on
// the user's incoming message right after dispatch, then clears the
// reaction (passing nil) the moment the agent posts its first content
// reply or the safety net fires. Bots can set their own reactions in
// any chat without additional scopes; failures are non-fatal so we
// swallow them at debug level.
func telegramSetMessageReaction(
  token: String, chatId: Int64, messageId: Int64, emoji: String?
) -> (ok: Bool, description: String) {
  // messageId == 0 is our "no source message recorded" sentinel (older
  // rows / synthetic test seeds). Calling setMessageReaction with an
  // invalid id would only earn a 400; short-circuit to silent success.
  guard messageId > 0 else { return (true, "") }

  var body: [String: Any] = [
    "chat_id": chatId,
    "message_id": messageId,
  ]
  if let emoji, !emoji.isEmpty {
    body["reaction"] = [["type": "emoji", "emoji": emoji]]
  } else {
    // Empty array clears all of the bot's reactions for this message.
    body["reaction"] = [[String: Any]]()
  }
  let response = telegramRequest(token: token, method: "setMessageReaction", body: body)
  return (response.ok, response.ok ? "" : response.description)
}

// MARK: - File upload (multipart/form-data)
//
// `sendPhoto` / `sendDocument` accept multipart uploads when the file
// data isn't already on a public URL. We build the body ourselves and
// hand it to `host->http_request` as base64 so the host's HTTP client
// (which transports as JSON) can carry the raw bytes.

private func multipartBody(
  boundary: String,
  fields: [(name: String, value: String)],
  fileField: String,
  fileData: Data,
  filename: String,
  mimeType: String
) -> Data {
  var body = Data()
  let crlf = "\r\n"

  for (name, value) in fields {
    body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
    body.append(
      "Content-Disposition: form-data; name=\"\(name)\"\(crlf)\(crlf)".data(using: .utf8)!)
    body.append("\(value)\(crlf)".data(using: .utf8)!)
  }

  body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
  body.append(
    "Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\(crlf)"
      .data(using: .utf8)!)
  body.append("Content-Type: \(mimeType)\(crlf)\(crlf)".data(using: .utf8)!)
  body.append(fileData)
  body.append("\(crlf)--\(boundary)--\(crlf)".data(using: .utf8)!)

  return body
}

/// Issues a multipart Telegram upload. Returns `(ok, description)` so the
/// reply-tool layer can map failures the same way it does for sendMessage
/// (specifically: "bot was blocked" → mark blocked + cancel task).
func telegramMultipartUpload(
  token: String,
  method: String,
  fileField: String,
  chatId: Int64,
  fileData: Data,
  filename: String,
  mimeType: String,
  caption: String?
) -> (ok: Bool, description: String) {
  guard let httpRequest = hostAPI?.pointee.http_request else {
    logError("http_request not available for \(method)")
    return (false, "http_request unavailable")
  }

  let boundary = "OsaurusTelegram\(randomHexString(bytes: 16))"
  var fields: [(name: String, value: String)] = [("chat_id", "\(chatId)")]
  if let caption, !caption.isEmpty {
    fields.append(("caption", String(caption.prefix(1024))))
  }
  let body = multipartBody(
    boundary: boundary, fields: fields,
    fileField: fileField, fileData: fileData,
    filename: filename, mimeType: mimeType)

  // Multipart bodies are binary, so we send through the host's
  // base64 body_encoding. timeout_ms is generous because file uploads
  // legitimately take longer than text sends.
  let request: [String: Any] = [
    "method": "POST",
    "url": "https://api.telegram.org/bot\(token)/\(method)",
    "headers": ["Content-Type": "multipart/form-data; boundary=\(boundary)"],
    "body": body.base64EncodedString(),
    "body_encoding": "base64",
    "timeout_ms": 60_000,
  ]

  guard let requestJSON = makeJSONString(request) else {
    logError("Failed to serialize \(method) request")
    return (false, "request serialize failed")
  }
  guard let responseStr = callHostString(httpRequest, requestJSON) else {
    logError("No response from \(method)")
    return (false, "no response")
  }
  guard let httpResponse = parseJSONObject(responseStr),
    let httpBody = httpResponse["body"] as? String,
    let bodyData = httpBody.data(using: .utf8),
    let tgResponse = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
  else {
    logError("\(method) returned non-JSON envelope: \(String(responseStr.prefix(200)))")
    return (false, "non-json telegram body")
  }

  let ok = tgResponse["ok"] as? Bool ?? false
  let description = tgResponse["description"] as? String ?? ""
  if !ok {
    logWarn("Telegram \(method) failed: \(description)")
  }
  return (ok, ok ? "" : description)
}

/// Sends a photo by uploading bytes (sendPhoto multipart variant). MIME
/// type is implicit (Telegram inspects the bytes), but Telegram does
/// reject obviously non-image payloads under this method.
func telegramSendPhoto(
  token: String, chatId: Int64,
  fileData: Data, filename: String,
  caption: String?
) -> (ok: Bool, description: String) {
  let mimeType: String
  switch (filename as NSString).pathExtension.lowercased() {
  case "png": mimeType = "image/png"
  case "gif": mimeType = "image/gif"
  case "webp": mimeType = "image/webp"
  default: mimeType = "image/jpeg"
  }
  return telegramMultipartUpload(
    token: token, method: "sendPhoto", fileField: "photo",
    chatId: chatId, fileData: fileData, filename: filename,
    mimeType: mimeType, caption: caption)
}

/// Sends an arbitrary file as a Telegram document (anything that isn't a
/// photo: PDFs, transcripts, archives, etc.). Caller picks the mimeType.
func telegramSendDocument(
  token: String, chatId: Int64,
  fileData: Data, filename: String, mimeType: String,
  caption: String?
) -> (ok: Bool, description: String) {
  return telegramMultipartUpload(
    token: token, method: "sendDocument", fileField: "document",
    chatId: chatId, fileData: fileData, filename: filename,
    mimeType: mimeType, caption: caption)
}
