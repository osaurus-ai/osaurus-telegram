import XCTest

@testable import osaurus_telegram

final class WebhookTests: XCTestCase {

  private var state: AgentState!
  private let agentId = defaultTestAgentId
  private let secret = "super-secret"

  override func setUp() {
    super.setUp()
    TestHost.install()
    DatabaseManager.initSchema()
    state = AgentState(agentId: agentId)
    state.botToken = "123:fake"
    state.webhookSecret = secret
  }

  override func tearDown() {
    state = nil
    TestHost.uninstall()
    super.tearDown()
  }

  // MARK: - Pure decoding tests (no host required)

  func testTGUpdateDecodesTextMessage() throws {
    let body = """
      {
        "update_id": 42,
        "message": {
          "message_id": 7,
          "chat": { "id": 12345 },
          "from": { "username": "alice", "first_name": "Alice" },
          "text": "hello"
        }
      }
      """
    let parsed = try XCTUnwrap(parseJSON(body, as: TGUpdate.self))
    XCTAssertEqual(parsed.update_id, 42)
    XCTAssertEqual(parsed.message?.chat.id, 12345)
    XCTAssertEqual(parsed.message?.from?.username, "alice")
    XCTAssertEqual(parsed.message?.text, "hello")
    XCTAssertEqual(parsed.message?.message_id, 7)
  }

  func testTGUpdateAcceptsNonTextMessage() throws {
    let body = """
      {
        "update_id": 99,
        "message": {
          "message_id": 7,
          "chat": { "id": 999 }
        }
      }
      """
    let parsed = try XCTUnwrap(parseJSON(body, as: TGUpdate.self))
    XCTAssertNil(parsed.message?.text)
    XCTAssertNil(parsed.message?.from)
  }

  func testRouteResponseShape() throws {
    let json = makeRouteResponse(status: 200, body: #"{"ok":true}"#)
    let data = try XCTUnwrap(json.data(using: .utf8))
    let parsed = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(parsed["status"] as? Int, 200)
    XCTAssertEqual(parsed["body"] as? String, #"{"ok":true}"#)
    let headers = try XCTUnwrap(parsed["headers"] as? [String: String])
    XCTAssertEqual(headers["Content-Type"], "application/json")
  }

  func testDispatchResponseDecodesSuccessAndError() throws {
    let okJSON = #"{"id":"task-uuid","status":"running"}"#
    let okParsed = try XCTUnwrap(parseJSON(okJSON, as: DispatchResponse.self))
    XCTAssertEqual(okParsed.id, "task-uuid")
    XCTAssertNil(okParsed.error)

    let errJSON = #"{"error":"rate_limit_exceeded"}"#
    let errParsed = try XCTUnwrap(parseJSON(errJSON, as: DispatchResponse.self))
    XCTAssertEqual(errParsed.error, "rate_limit_exceeded")
    XCTAssertNil(errParsed.id)
  }

  // MARK: - Helpers for end-to-end webhook tests

  private func webhookRequest(
    secret: String?,
    update: [String: Any],
    method: String = "POST"
  ) -> String {
    let body = String(
      data: try! JSONSerialization.data(withJSONObject: update),
      encoding: .utf8)!
    var headers: [String: String] = [:]
    if let secret { headers["x-telegram-bot-api-secret-token"] = secret }
    let req: [String: Any] = [
      "route_id": "webhook",
      "method": method,
      "path": "/webhook",
      "headers": headers,
      "body": body,
    ]
    return String(
      data: try! JSONSerialization.data(withJSONObject: req),
      encoding: .utf8)!
  }

  private func textUpdate(
    updateId: Int,
    chatId: Int64,
    text: String,
    username: String = "alice"
  ) -> [String: Any] {
    return [
      "update_id": updateId,
      "message": [
        "message_id": 1,
        "chat": ["id": chatId],
        "from": ["username": username, "first_name": "Alice"],
        "text": text,
      ],
    ]
  }

  private func parseRouteResponse(_ s: String) -> (status: Int, body: String) {
    let data = s.data(using: .utf8) ?? Data()
    let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    return (obj["status"] as? Int ?? 0, obj["body"] as? String ?? "")
  }

  /// Convenience wrapper so test bodies don't have to repeat the
  /// `state: state, agentId: agentId` boilerplate every call.
  private func route(_ requestJSON: String) -> String {
    handleRoute(state: state, agentId: agentId, requestJSON: requestJSON)
  }

  // MARK: - End-to-end webhook flow

  func testWebhookRejectsMissingSecret() {
    let req = webhookRequest(secret: nil, update: textUpdate(updateId: 1, chatId: 1, text: "hi"))
    let response = parseRouteResponse(route(req))
    XCTAssertEqual(response.status, 401)
    XCTAssertTrue(TestHostGlobals.dispatchCalls.isEmpty)
  }

  func testWebhookRejectsWrongSecret() {
    let req = webhookRequest(
      secret: "wrong", update: textUpdate(updateId: 1, chatId: 1, text: "hi"))
    let response = parseRouteResponse(route(req))
    XCTAssertEqual(response.status, 401)
    XCTAssertTrue(TestHostGlobals.dispatchCalls.isEmpty)
  }

  func testWebhookUnknownRouteReturns404() {
    let req: [String: Any] = [
      "route_id": "totally-not-real",
      "method": "POST",
      "path": "/x",
      "headers": [:],
      "body": "{}",
    ]
    let json = String(
      data: try! JSONSerialization.data(withJSONObject: req), encoding: .utf8)!
    let response = parseRouteResponse(route(json))
    XCTAssertEqual(response.status, 404)
  }

  func testWebhookDispatchesValidTextMessage() throws {
    let req = webhookRequest(
      secret: secret, update: textUpdate(updateId: 100, chatId: 555, text: "hello"))
    let response = parseRouteResponse(route(req))
    XCTAssertEqual(response.status, 200)

    XCTAssertEqual(TestHostGlobals.dispatchCalls.count, 1)
    let dispatch = TestHostGlobals.dispatchCalls[0]

    let prompt = try XCTUnwrap(dispatch["prompt"] as? String)
    XCTAssertTrue(prompt.contains("[reply_token "))
    XCTAssertTrue(prompt.contains("from alice"))
    XCTAssertTrue(prompt.contains("hello"))

    let title = try XCTUnwrap(dispatch["title"] as? String)
    XCTAssertEqual(title, "Telegram alice")

    let sessionId = try XCTUnwrap(dispatch["session_id"] as? String)
    let chat = try XCTUnwrap(
      DatabaseManager.getChatSession(agentId: agentId, chatId: 555))
    let expected = sessionUUID(forChatId: 555, salt: chat.sessionSalt).uuidString
    XCTAssertEqual(sessionId, expected, "session id must be deterministic UUID5")

    // The dispatch carries an agent-scoped external_session_key so the
    // host's reattach lookup can't collide across agents.
    let externalKey = try XCTUnwrap(dispatch["external_session_key"] as? String)
    XCTAssertEqual(externalKey, "telegram:agent-\(agentId):chat-555")

    // Active dispatch row inserted for this chat.
    let active = try XCTUnwrap(
      DatabaseManager.activeDispatch(agentId: agentId, forChat: 555))
    XCTAssertEqual(active.taskId, "task-uuid")
    XCTAssertEqual(active.agentId, agentId)
    XCTAssertGreaterThan(active.expiresAt, Int(Date().timeIntervalSince1970))
  }

  func testWebhookSessionIdStableAcrossMessages() throws {
    let firstReq = webhookRequest(
      secret: secret, update: textUpdate(updateId: 200, chatId: 777, text: "first"))
    _ = route(firstReq)

    // Need a fresh task id for the second one (UNIQUE (agent_id, chat_id)
    // requires we remove the prior row first; the interrupt branch handles
    // that).
    TestHostGlobals.nextDispatchResponse =
      #"{"id":"task-uuid-2","status":"running"}"#

    let secondReq = webhookRequest(
      secret: secret, update: textUpdate(updateId: 201, chatId: 777, text: "second"))
    _ = route(secondReq)

    XCTAssertEqual(TestHostGlobals.dispatchCalls.count, 2)
    let s1 = TestHostGlobals.dispatchCalls[0]["session_id"] as? String
    let s2 = TestHostGlobals.dispatchCalls[1]["session_id"] as? String
    XCTAssertEqual(s1, s2, "same chat must reattach to the same session")
  }

  func testWebhookDeduplicatesByUpdateId() {
    let req = webhookRequest(
      secret: secret, update: textUpdate(updateId: 300, chatId: 1, text: "hi"))
    _ = route(req)
    _ = route(req)
    XCTAssertEqual(
      TestHostGlobals.dispatchCalls.count, 1,
      "duplicate update_id must short-circuit before dispatch")
  }

  func testWebhookIgnoresNonTextMessage() {
    let update: [String: Any] = [
      "update_id": 400,
      "message": [
        "message_id": 1,
        "chat": ["id": 1],
        "from": ["username": "x", "first_name": "X"],
      ],
    ]
    let req = webhookRequest(secret: secret, update: update)
    let response = parseRouteResponse(route(req))
    XCTAssertEqual(response.status, 200)
    XCTAssertTrue(TestHostGlobals.dispatchCalls.isEmpty)
  }

  func testWebhookSkipsBlockedChat() {
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 600)
    DatabaseManager.markChatBlocked(agentId: agentId, chatId: 600)
    let req = webhookRequest(
      secret: secret, update: textUpdate(updateId: 500, chatId: 600, text: "hi"))
    let response = parseRouteResponse(route(req))
    XCTAssertEqual(response.status, 200)
    XCTAssertTrue(TestHostGlobals.dispatchCalls.isEmpty)
  }

  // MARK: - /reset

  func testResetBumpsSaltAndCancelsActiveDispatch() {
    // Seed an active dispatch for chat 800.
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 800)
    DatabaseManager.insertActiveDispatch(
      taskId: "running-task", agentId: agentId, chatId: 800,
      replyToken: "TOKABCDE", sessionId: "old-session",
      expiresAt: Int(Date().timeIntervalSince1970) + 600)

    let req = webhookRequest(
      secret: secret, update: textUpdate(updateId: 700, chatId: 800, text: "/reset"))
    let response = parseRouteResponse(route(req))
    XCTAssertEqual(response.status, 200)

    // Salt bumped, active dispatch cleared, no new dispatch issued.
    XCTAssertEqual(
      DatabaseManager.getChatSession(agentId: agentId, chatId: 800)?.sessionSalt, 1)
    XCTAssertNil(DatabaseManager.activeDispatch(agentId: agentId, forChat: 800))
    XCTAssertEqual(TestHostGlobals.cancelCalls, ["running-task"])
    XCTAssertTrue(TestHostGlobals.dispatchCalls.isEmpty, "/reset must not dispatch")

    // The plugin posted the "Conversation reset." meta-message.
    XCTAssertEqual(TestHostGlobals.httpCalls.count, 1)
    let httpBody = TestHostGlobals.httpCalls[0]["body"] as? String ?? ""
    XCTAssertTrue(httpBody.contains("Conversation reset"))
  }

  // MARK: - dispatch_interrupt on concurrent message

  func testActiveDispatchInterruptedByNewMessage() {
    // First message lands -> seeds active dispatch row.
    let first = webhookRequest(
      secret: secret,
      update: textUpdate(updateId: 900, chatId: 900, text: "what's on my calendar?"))
    _ = route(first)
    XCTAssertEqual(TestHostGlobals.dispatchCalls.count, 1)

    // Second message arrives mid-flight. Configure a new task id so the
    // fresh insert succeeds after we delete the prior row.
    TestHostGlobals.nextDispatchResponse =
      #"{"id":"task-second","status":"running"}"#

    let second = webhookRequest(
      secret: secret,
      update: textUpdate(updateId: 901, chatId: 900, text: "actually, just tomorrow"))
    _ = route(second)

    // dispatch_interrupt called once with the prior task id and the raw user text.
    XCTAssertEqual(TestHostGlobals.interruptCalls.count, 1)
    let interrupt = TestHostGlobals.interruptCalls[0]
    XCTAssertEqual(interrupt.taskId, "task-uuid")
    XCTAssertEqual(interrupt.text, "actually, just tomorrow")

    // A fresh dispatch was issued for the new turn against the same session.
    XCTAssertEqual(TestHostGlobals.dispatchCalls.count, 2)
    XCTAssertEqual(
      TestHostGlobals.dispatchCalls[0]["session_id"] as? String,
      TestHostGlobals.dispatchCalls[1]["session_id"] as? String)

    // Active dispatch row now points at the new task.
    let active = DatabaseManager.activeDispatch(agentId: agentId, forChat: 900)
    XCTAssertEqual(active?.taskId, "task-second")
  }

  // MARK: - dispatch error: rate_limit_exceeded posts a meta-message

  func testRateLimitErrorPostsApologyMetaMessage() {
    TestHostGlobals.nextDispatchResponse = #"{"error":"rate_limit_exceeded"}"#
    let req = webhookRequest(
      secret: secret, update: textUpdate(updateId: 1000, chatId: 50, text: "hi"))
    let response = parseRouteResponse(route(req))

    XCTAssertEqual(response.status, 200)
    // No active dispatch row inserted because the dispatch failed.
    XCTAssertNil(DatabaseManager.activeDispatch(agentId: agentId, forChat: 50))
    // Plugin posted the apology directly via http_request.
    XCTAssertEqual(TestHostGlobals.httpCalls.count, 1)
    let body = TestHostGlobals.httpCalls[0]["body"] as? String ?? ""
    XCTAssertTrue(body.contains("catching up"))
  }

  // MARK: - prompt header includes minted token

  func testPromptHeaderIncludesMintedReplyToken() throws {
    let req = webhookRequest(
      secret: secret, update: textUpdate(updateId: 1100, chatId: 60, text: "ping"))
    _ = route(req)

    let prompt = try XCTUnwrap(
      TestHostGlobals.dispatchCalls.first?["prompt"] as? String)
    let active = try XCTUnwrap(
      DatabaseManager.activeDispatch(agentId: agentId, forChat: 60))
    XCTAssertTrue(
      prompt.contains("[reply_token \(active.replyToken)"),
      "prompt header must carry the same token stored in active_dispatches")
  }
}
