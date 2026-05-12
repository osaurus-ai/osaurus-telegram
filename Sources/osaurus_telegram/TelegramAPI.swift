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

/// Validates a bot token and returns bot info. `botId` is the numeric
/// Telegram user_id of the bot (parsed from the `id` field, which can
/// arrive as `Int`, `Int64`, `Double`, or `String` depending on the
/// JSON decoder's intermediate boxing). Returns nil when the call
/// fails or the response is malformed; callers treat that as an
/// invalid token and surface the failure to the user.
func telegramGetMe(token: String) -> (botId: Int64, username: String)? {
  let response = telegramRequest(token: token, method: "getMe")
  guard response.ok, let dict = response.result as? [String: Any] else { return nil }
  let username = dict["username"] as? String ?? ""
  let rawId = dict["id"]
  let botId: Int64
  if let v = rawId as? Int64 {
    botId = v
  } else if let v = rawId as? Int {
    botId = Int64(v)
  } else if let v = rawId as? Double {
    botId = Int64(v)
  } else if let v = rawId as? String, let parsed = Int64(v) {
    botId = parsed
  } else {
    logWarn("telegramGetMe: bot id missing or unparsable: \(String(describing: rawId))")
    return nil
  }
  return (botId: botId, username: username)
}

/// Registers a webhook URL with Telegram. We subscribe to the union of
/// update types the plugin can act on:
///   * `message` — the bread-and-butter user turn (text / photo /
///     document / voice / video / etc.).
///   * `edited_message` — currently treated like a fresh message (the
///     dedup table guarantees we won't double-respond if Telegram
///     re-delivers the original) so the user can correct themselves.
///   * `callback_query` — inline-keyboard button presses become
///     synthetic user turns via `handleCallbackQuery`.
///   * `my_chat_member` — bot-side membership changes (added/removed
///     from a group). Currently observability-only; subscribing now so
///     a future feature doesn't need a re-registration.
/// `drop_pending_updates` defaults to `true` so a stale tunnel doesn't
/// thrash the agent loop with hours of queued backlog at first boot.
/// Re-registrations triggered by transient tunnel failures pass
/// `false` so the user's just-typed messages aren't lost when the
/// tunnel flips green again (see `setupWebhook`).
func telegramSetWebhook(
  token: String, url: String, secretToken: String,
  dropPendingUpdates: Bool = true
) -> Bool {
  let body: [String: Any] = [
    "url": url,
    "secret_token": secretToken,
    "allowed_updates": [
      "message", "edited_message", "callback_query", "my_chat_member",
    ],
    "drop_pending_updates": dropPendingUpdates,
  ]
  return telegramRequest(token: token, method: "setWebhook", body: body).ok
}

// MARK: - setMyCommands
//
// Populates Telegram's "/" menu so users discover bot-supported commands
// without having to read documentation. Best-effort; failures are
// logged but don't block setup.

/// One entry in the bot's "/" command menu. `command` is the verb
/// without the leading slash, lowercase, max 32 chars per Telegram
/// spec.
struct TelegramBotCommand {
  let command: String
  let description: String
}

@discardableResult
func telegramSetMyCommands(token: String, commands: [TelegramBotCommand]) -> Bool {
  let body: [String: Any] = [
    "commands": commands.map { ["command": $0.command, "description": $0.description] }
  ]
  return telegramRequest(token: token, method: "setMyCommands", body: body).ok
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
///
/// `replyToMessageId` threads the reply (Telegram-side "reply" UI). In
/// groups the agent should pass the user's incoming `message_id` so the
/// answer doesn't get lost in a busy chat. `allowSendingWithoutReply:
/// true` is implied so a deleted source message doesn't kill the send.
///
/// `replyMarkupJSON` is forwarded verbatim — currently used for inline
/// keyboards (`{"inline_keyboard": [[{"text":..., "callback_data":...}]]}`).
/// Callers pre-serialize to a JSON string so the closure boundary into
/// `PerChatSendActor` stays `Sendable` (a raw `[String: Any]` doesn't
/// satisfy the Sendable-closure constraint).
func telegramSendMessage(
  token: String,
  chatId: Int64,
  text: String,
  parseMode: String? = nil,
  replyToMessageId: Int64? = nil,
  replyMarkupJSON: String? = nil
) -> (ok: Bool, description: String) {
  var body: [String: Any] = [
    "chat_id": chatId,
    "text": text,
  ]
  if let parseMode, !parseMode.isEmpty { body["parse_mode"] = parseMode }
  if let replyToMessageId, replyToMessageId > 0 {
    body["reply_parameters"] = [
      "message_id": replyToMessageId,
      "allow_sending_without_reply": true,
    ]
  }
  if let replyMarkupJSON, !replyMarkupJSON.isEmpty,
    let data = replyMarkupJSON.data(using: .utf8),
    let markup = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  {
    body["reply_markup"] = markup
  }

  let response = telegramRequest(token: token, method: "sendMessage", body: body)
  if response.ok { return (true, "") }

  // If parse_mode tripped, retry once as plain text (preserving the
  // reply target / markup). The forgiving retry exists because
  // small markup errors shouldn't lose the agent's reply.
  if !response.ok, parseMode != nil, !(parseMode?.isEmpty ?? true) {
    logWarn("sendMessage failed with parse_mode=\(parseMode!), retrying as plain text")
    var plainBody: [String: Any] = ["chat_id": chatId, "text": text]
    if let replyToMessageId, replyToMessageId > 0 {
      plainBody["reply_parameters"] = [
        "message_id": replyToMessageId,
        "allow_sending_without_reply": true,
      ]
    }
    if let replyMarkupJSON, !replyMarkupJSON.isEmpty,
      let data = replyMarkupJSON.data(using: .utf8),
      let markup = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      plainBody["reply_markup"] = markup
    }
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
/// Optionally threads the reply via `replyToMessageId`.
func telegramSendPhotoByURL(
  token: String, chatId: Int64, photoURL: String, caption: String?,
  replyToMessageId: Int64? = nil
) -> (ok: Bool, description: String) {
  var body: [String: Any] = [
    "chat_id": chatId,
    "photo": photoURL,
  ]
  if let caption, !caption.isEmpty {
    body["caption"] = String(caption.prefix(1024))
  }
  if let replyToMessageId, replyToMessageId > 0 {
    body["reply_parameters"] = [
      "message_id": replyToMessageId,
      "allow_sending_without_reply": true,
    ]
  }
  let response = telegramRequest(token: token, method: "sendPhoto", body: body)
  return (response.ok, response.ok ? "" : response.description)
}

/// Generic "send by URL" helper for non-photo media. Telegram supports
/// a public URL in the `<media>` field for sendDocument / sendAudio /
/// sendVoice / sendVideo / sendAnimation, mirroring sendPhoto. The
/// `mediaField` is the Telegram parameter name (`document`, `voice`,
/// etc.) and `method` is the corresponding API method.
func telegramSendMediaByURL(
  token: String, method: String, mediaField: String,
  chatId: Int64, mediaURL: String, caption: String?,
  replyToMessageId: Int64? = nil
) -> (ok: Bool, description: String) {
  var body: [String: Any] = [
    "chat_id": chatId,
    mediaField: mediaURL,
  ]
  if let caption, !caption.isEmpty {
    body["caption"] = String(caption.prefix(1024))
  }
  if let replyToMessageId, replyToMessageId > 0 {
    body["reply_parameters"] = [
      "message_id": replyToMessageId,
      "allow_sending_without_reply": true,
    ]
  }
  let response = telegramRequest(token: token, method: method, body: body)
  return (response.ok, response.ok ? "" : response.description)
}

// MARK: - getFile / file download
//
// `getFile` resolves a Telegram `file_id` into a download path; the file
// then lives at `https://api.telegram.org/file/bot<token>/<file_path>`.
// We use this for the inbound media path (Phase 3a): the user uploads a
// photo / voice note / document, the webhook handler resolves the
// largest variant via `getFile`, downloads the bytes via `http_request`,
// and stashes them into `~/.osaurus/artifacts/` for the agent to read.

struct TelegramFileDescriptor {
  /// Telegram-side relative path (e.g. `documents/file_42.pdf`). Pair
  /// with the bot token to build a download URL.
  let filePath: String
  let fileSize: Int64
}

func telegramGetFile(token: String, fileId: String) -> TelegramFileDescriptor? {
  let response = telegramRequest(
    token: token, method: "getFile", body: ["file_id": fileId])
  guard response.ok, let dict = response.result as? [String: Any],
    let path = dict["file_path"] as? String, !path.isEmpty
  else { return nil }
  let size: Int64
  if let v = dict["file_size"] as? Int64 {
    size = v
  } else if let v = dict["file_size"] as? Int {
    size = Int64(v)
  } else {
    size = 0
  }
  return TelegramFileDescriptor(filePath: path, fileSize: size)
}

/// Downloads a Telegram file by `file_path` (as returned from `getFile`).
/// Uses the host's HTTP client so SSRF protection still applies (the
/// host whitelists `api.telegram.org`). Returns the raw bytes on success.
func telegramDownloadFile(token: String, filePath: String) -> Data? {
  guard let httpRequest = hostAPI?.pointee.http_request else {
    logError("telegramDownloadFile: http_request not available")
    return nil
  }
  let request: [String: Any] = [
    "method": "GET",
    "url": "https://api.telegram.org/file/bot\(token)/\(filePath)",
    "timeout_ms": 60_000,
    // We MUST receive bytes back as base64; UTF-8 framing would corrupt
    // the binary payload (and Telegram serves arbitrary bytes here).
    "response_encoding": "base64",
  ]
  guard let requestJSON = makeJSONString(request),
    let responseStr = callHostString(httpRequest, requestJSON),
    let httpResponse = parseJSONObject(responseStr)
  else {
    logError("telegramDownloadFile: failed to parse host response for \(filePath)")
    return nil
  }
  let status = httpResponse["status"] as? Int ?? 0
  guard status == 200 else {
    logWarn("telegramDownloadFile: HTTP \(status) for \(filePath)")
    return nil
  }
  // Prefer base64 when the host honoured response_encoding; fall back
  // to a UTF-8 decode of `body` for hosts that don't (older builds).
  if let encoding = httpResponse["body_encoding"] as? String, encoding == "base64",
    let bodyStr = httpResponse["body"] as? String,
    let data = Data(base64Encoded: bodyStr)
  {
    return data
  }
  if let bodyStr = httpResponse["body"] as? String {
    return Data(bodyStr.utf8)
  }
  return nil
}

// MARK: - answerCallbackQuery
//
// Acknowledges a callback_query so Telegram clears the spinner on the
// inline button the user pressed. Best-effort.
@discardableResult
func telegramAnswerCallbackQuery(
  token: String, callbackQueryId: String, text: String? = nil
) -> Bool {
  var body: [String: Any] = ["callback_query_id": callbackQueryId]
  if let text, !text.isEmpty { body["text"] = String(text.prefix(200)) }
  return telegramRequest(token: token, method: "answerCallbackQuery", body: body).ok
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
///
/// `replyToMessageId` threads via Telegram's reply UI when set; the
/// boundary header approach mirrors sendMessage's `reply_parameters`.
func telegramMultipartUpload(
  token: String,
  method: String,
  fileField: String,
  chatId: Int64,
  fileData: Data,
  filename: String,
  mimeType: String,
  caption: String?,
  replyToMessageId: Int64? = nil
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
  if let replyToMessageId, replyToMessageId > 0 {
    // Telegram accepts the JSON-stringified `reply_parameters` object as
    // a multipart form field.
    let replyParams = #"{"message_id":\#(replyToMessageId),"allow_sending_without_reply":true}"#
    fields.append(("reply_parameters", replyParams))
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
  caption: String?, replyToMessageId: Int64? = nil
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
    mimeType: mimeType, caption: caption,
    replyToMessageId: replyToMessageId)
}

/// Sends an arbitrary file as a Telegram document (anything that isn't a
/// photo: PDFs, transcripts, archives, etc.). Caller picks the mimeType.
func telegramSendDocument(
  token: String, chatId: Int64,
  fileData: Data, filename: String, mimeType: String,
  caption: String?, replyToMessageId: Int64? = nil
) -> (ok: Bool, description: String) {
  return telegramMultipartUpload(
    token: token, method: "sendDocument", fileField: "document",
    chatId: chatId, fileData: fileData, filename: filename,
    mimeType: mimeType, caption: caption,
    replyToMessageId: replyToMessageId)
}

/// Sends a voice note (ogg/opus). Telegram displays these as a
/// playable waveform in the chat. Always uses the `voice` API method;
/// caller's responsibility to send compatible bytes (the agent should
/// only call this with files generated as ogg).
func telegramSendVoice(
  token: String, chatId: Int64,
  fileData: Data, filename: String,
  caption: String?, replyToMessageId: Int64? = nil
) -> (ok: Bool, description: String) {
  return telegramMultipartUpload(
    token: token, method: "sendVoice", fileField: "voice",
    chatId: chatId, fileData: fileData, filename: filename,
    mimeType: "audio/ogg", caption: caption,
    replyToMessageId: replyToMessageId)
}

/// Sends an audio (music) file. Telegram displays these as a music
/// player; useful for songs, podcasts, longer recorded audio.
func telegramSendAudio(
  token: String, chatId: Int64,
  fileData: Data, filename: String, mimeType: String,
  caption: String?, replyToMessageId: Int64? = nil
) -> (ok: Bool, description: String) {
  return telegramMultipartUpload(
    token: token, method: "sendAudio", fileField: "audio",
    chatId: chatId, fileData: fileData, filename: filename,
    mimeType: mimeType, caption: caption,
    replyToMessageId: replyToMessageId)
}

/// Sends a video file. Telegram inspects the bytes; common containers
/// (mp4, mov) play inline.
func telegramSendVideo(
  token: String, chatId: Int64,
  fileData: Data, filename: String, mimeType: String,
  caption: String?, replyToMessageId: Int64? = nil
) -> (ok: Bool, description: String) {
  return telegramMultipartUpload(
    token: token, method: "sendVideo", fileField: "video",
    chatId: chatId, fileData: fileData, filename: filename,
    mimeType: mimeType, caption: caption,
    replyToMessageId: replyToMessageId)
}
