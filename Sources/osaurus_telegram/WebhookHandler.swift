import Foundation

// MARK: - Route Handler

func handleRoute(ctx: PluginContext, requestJSON: String) -> String {
  guard let req = parseJSON(requestJSON, as: RouteRequest.self) else {
    logWarn("handleRoute: failed to parse request JSON (\(requestJSON.count) chars)")
    return makeRouteResponse(status: 400, body: #"{"ok":false,"description":"bad request"}"#)
  }

  logDebug("handleRoute: route_id=\(req.route_id) method=\(req.method)")

  switch req.route_id {
  case "webhook":
    return handleWebhook(ctx: ctx, req: req)
  default:
    logWarn("handleRoute: unknown route_id '\(req.route_id)'")
    return makeRouteResponse(status: 404, body: #"{"ok":false,"description":"not found"}"#)
  }
}

// MARK: - Webhook Endpoint

private func extractSecretHeader(from headers: [String: String]) -> String {
  if let v = headers["x-telegram-bot-api-secret-token"] { return v }
  if let v = headers["X-Telegram-Bot-Api-Secret-Token"] { return v }
  return ""
}

/// Hot path. Telegram retries on slow / 4xx / 5xx, so this MUST return 200
/// quickly. Any heavy lifting goes through dispatch — never await inference
/// here.
private func handleWebhook(ctx: PluginContext, req: RouteRequest) -> String {
  // 1. Verify Telegram's secret header (constant-time).
  let expectedSecret = ctx.webhookSecret ?? configGet("webhook_secret") ?? ""
  let receivedSecret = extractSecretHeader(from: req.headers ?? [:])
  guard !expectedSecret.isEmpty,
    constantTimeEquals(expectedSecret, receivedSecret)
  else {
    logWarn("Webhook rejected: bad or missing secret token")
    return makeRouteResponse(
      status: 401, body: #"{"ok":false,"description":"bad secret"}"#)
  }

  // 2. Parse the Telegram Update. Stickers, photos, callbacks, etc. are
  //    accepted with a 200 so Telegram doesn't retry them.
  guard let body = req.body,
    let update = parseJSON(body, as: TGUpdate.self)
  else {
    logWarn("Webhook: failed to parse update body (\(req.body?.count ?? 0) chars)")
    return makeRouteResponse(status: 200, body: #"{"ok":true}"#)
  }

  guard let message = update.message,
    let text = message.text, !text.isEmpty
  else {
    logDebug("handleWebhook: non-text update_id=\(update.update_id), ignoring")
    return makeRouteResponse(status: 200, body: #"{"ok":true}"#)
  }

  let chatId = message.chat.id

  // 3. Idempotency: drop duplicate Telegram retries.
  if DatabaseManager.isUpdateAlreadySeen(updateId: update.update_id) {
    logDebug("handleWebhook: duplicate update_id=\(update.update_id), 200 OK")
    return makeRouteResponse(status: 200, body: #"{"ok":true}"#)
  }
  DatabaseManager.markUpdateSeen(updateId: update.update_id)
  DatabaseManager.pruneOldSeenUpdates()

  // 4. Resolve / create chat row. Skip if blocked.
  let chat = DatabaseManager.upsertChatSession(chatId: chatId)
  if chat.blocked == 1 {
    logDebug("handleWebhook: chat \(chatId) is blocked, ignoring")
    return makeRouteResponse(status: 200, body: #"{"ok":true}"#)
  }

  // 5. Handle /reset inline before dispatching.
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed == "/reset" {
    handleReset(ctx: ctx, chatId: chatId)
    return makeRouteResponse(status: 200, body: #"{"ok":true}"#)
  }

  // 6. Build session id (deterministic per chat+salt) and a reply token.
  let session = sessionUUID(forChatId: chatId, salt: chat.sessionSalt)
  let replyToken = mintReplyToken()

  let displayName =
    message.from?.username ?? message.from?.first_name ?? "user"
  let prompt = "[reply_token \(replyToken) from \(displayName)]\n\(text)"

  // 7. If a task is already running for this chat, interrupt it (host
  //    appends our text into the live session and cancels the stream),
  //    then dispatch a fresh turn against the same session_id. Naturally
  //    handles rapid-fire messages without queues.
  if let active = DatabaseManager.activeDispatch(forChat: chatId) {
    logDebug(
      "handleWebhook: interrupting active task \(active.taskId) for chat \(chatId)")
    if let interrupt = hostAPI?.pointee.dispatch_interrupt {
      active.taskId.withCString { tid in
        text.withCString { p in interrupt(tid, p) }
      }
    } else if let cancel = hostAPI?.pointee.dispatch_cancel {
      logWarn("handleWebhook: dispatch_interrupt unavailable; cancelling instead")
      active.taskId.withCString { tid in cancel(tid) }
    }
    DatabaseManager.deleteActiveDispatch(taskId: active.taskId)
  }

  // 8. Dispatch. Fire and forget. The agent will call our reply tool.
  let dispatchPayload: [String: Any] = [
    "prompt": prompt,
    "title": "Telegram \(displayName)",
    "session_id": session.uuidString,
  ]
  guard let dispatchJSON = makeJSONString(dispatchPayload) else {
    logError("handleWebhook: failed to serialize dispatch payload")
    return makeRouteResponse(status: 200, body: #"{"ok":true}"#)
  }

  guard let resultStr = callHostString(hostAPI?.pointee.dispatch, dispatchJSON),
    let parsed = parseJSON(resultStr, as: DispatchResponse.self)
  else {
    logError("handleWebhook: dispatch unavailable or returned malformed result")
    return makeRouteResponse(status: 200, body: #"{"ok":true}"#)
  }

  if let errCode = parsed.error {
    if errCode == "rate_limit_exceeded" {
      // Plugin-owned meta-message: the user must hear *something*.
      if let token = ctx.botToken {
        _ = telegramSendMessage(
          token: token, chatId: chatId,
          text: "I'm catching up on a few things. Please retry in a moment.")
      }
    } else {
      logWarn("handleWebhook: dispatch failed: \(errCode)")
    }
    return makeRouteResponse(status: 200, body: #"{"ok":true}"#)
  }

  guard let taskId = parsed.id else {
    logError("handleWebhook: dispatch result missing id: \(String(resultStr.prefix(200)))")
    return makeRouteResponse(status: 200, body: #"{"ok":true}"#)
  }

  let expiresAt = Int(Date().timeIntervalSince1970) + 600  // 10 minutes
  DatabaseManager.insertActiveDispatch(
    taskId: taskId, chatId: chatId, replyToken: replyToken,
    sessionId: session.uuidString, expiresAt: expiresAt)
  logInfo("Dispatched task \(taskId) for chat \(chatId) (token=\(replyToken))")

  return makeRouteResponse(status: 200, body: #"{"ok":true}"#)
}

// MARK: - /reset

private func handleReset(ctx: PluginContext, chatId: Int64) {
  logDebug("handleReset: chat \(chatId)")
  DatabaseManager.bumpSessionSalt(chatId: chatId)

  if let active = DatabaseManager.activeDispatch(forChat: chatId) {
    active.taskId.withCString { tid in
      hostAPI?.pointee.dispatch_cancel?(tid)
    }
    DatabaseManager.deleteActiveDispatch(taskId: active.taskId)
  }

  if let token = ctx.botToken {
    _ = telegramSendMessage(
      token: token, chatId: chatId, text: "Conversation reset.")
  }
}

// MARK: - Response Builder

func makeRouteResponse(status: Int, body: String, contentType: String = "application/json")
  -> String
{
  let resp: [String: Any] = [
    "status": status,
    "headers": ["Content-Type": contentType],
    "body": body,
  ]
  return makeJSONString(resp) ?? #"{"status":500}"#
}
