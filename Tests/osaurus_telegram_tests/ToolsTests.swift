import XCTest

@testable import osaurus_telegram

final class ToolsTests: XCTestCase {

  private var state: AgentState!
  private let agentId = defaultTestAgentId

  override func setUp() {
    super.setUp()
    TestHost.install()
    DatabaseManager.initSchema()
    state = AgentState(agentId: agentId)
    state.botToken = "123:fake"
  }

  override func tearDown() {
    state = nil
    TestHost.uninstall()
    super.tearDown()
  }

  // MARK: helpers

  private func parseEnvelope(_ s: String) -> [String: Any] {
    let data = s.data(using: .utf8) ?? Data()
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }

  /// Inserts an active dispatch row for a fresh chat and returns the token.
  @discardableResult
  private func makeBinding(
    chatId: Int64 = 100,
    taskId: String = "task-1",
    expiresInSeconds: Int = 600
  ) -> String {
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: chatId)
    let token = "TOKABC12"
    DatabaseManager.insertActiveDispatch(
      taskId: taskId, agentId: agentId, chatId: chatId, replyToken: token,
      sessionId: "session-1",
      expiresAt: Int(Date().timeIntervalSince1970) + expiresInSeconds)
    return token
  }

  private func setHTTPSuccess(messageId: Int = 1) {
    TestHostGlobals.nextHttpResponse =
      #"{"status":200,"body":"{\"ok\":true,\"result\":{\"message_id\":\#(messageId)}}"}"#
  }

  private func setHTTPBotWasBlocked() {
    TestHostGlobals.nextHttpResponse =
      #"{"status":403,"body":"{\"ok\":false,\"description\":\"Forbidden: bot was blocked by the user\"}"}"#
  }

  private func setHTTPGenericError() {
    TestHostGlobals.nextHttpResponse =
      #"{"status":400,"body":"{\"ok\":false,\"description\":\"Bad Request: chat not found\"}"}"#
  }

  // MARK: invalid args

  func testReplyRejectsInvalidJSON() {
    let env = parseEnvelope(handleReply(state: state, payload: "not-json"))
    XCTAssertEqual(env["ok"] as? Bool, false)
    XCTAssertEqual(env["error"] as? String, "invalid_request")
  }

  func testReplyTypingRejectsMissingToken() {
    let env = parseEnvelope(handleReplyTyping(state: state, payload: "{}"))
    XCTAssertEqual(env["error"] as? String, "invalid_request")
  }

  func testReplyPhotoRejectsMissingURL() {
    let env = parseEnvelope(
      handleReplyPhoto(state: state, payload: #"{"reply_token":"TOK"}"#))
    XCTAssertEqual(env["error"] as? String, "invalid_request")
  }

  // MARK: stale token

  func testReplyStaleTokenWhenUnknown() {
    let env = parseEnvelope(
      handleReply(
        state: state,
        payload: #"{"reply_token":"NOPE","text":"hi"}"#))
    XCTAssertEqual(env["error"] as? String, "stale_token")
  }

  func testReplyStaleTokenWhenExpired() {
    let token = makeBinding(expiresInSeconds: -10)
    let env = parseEnvelope(
      handleReply(
        state: state,
        payload: #"{"reply_token":"\#(token)","text":"hi"}"#))
    XCTAssertEqual(env["error"] as? String, "stale_token")
    XCTAssertTrue(TestHostGlobals.httpCalls.isEmpty, "no HTTP call on stale token")
  }

  // MARK: chat blocked (already flagged)

  func testReplyChatBlockedWhenChatPreviouslyBlocked() {
    let token = makeBinding(chatId: 200)
    DatabaseManager.markChatBlocked(agentId: agentId, chatId: 200)
    let env = parseEnvelope(
      handleReply(
        state: state,
        payload: #"{"reply_token":"\#(token)","text":"hi"}"#))
    XCTAssertEqual(env["error"] as? String, "chat_blocked")
    XCTAssertTrue(TestHostGlobals.httpCalls.isEmpty)
  }

  // MARK: not configured

  func testReplyFailsWhenBotTokenMissing() {
    let token = makeBinding()
    state.botToken = nil
    let env = parseEnvelope(
      handleReply(
        state: state,
        payload: #"{"reply_token":"\#(token)","text":"hi"}"#))
    XCTAssertEqual(env["error"] as? String, "not_configured")
  }

  // MARK: success paths

  func testReplySuccessSendsHTTPCallAndMarksReplied() {
    let token = makeBinding(taskId: "task-success")
    setHTTPSuccess()

    let env = parseEnvelope(
      handleReply(
        state: state,
        payload: #"{"reply_token":"\#(token)","text":"hello world"}"#))

    XCTAssertEqual(env["ok"] as? Bool, true)
    XCTAssertEqual((env["data"] as? [String: Any])?["sent"] as? Bool, true)
    XCTAssertEqual(env["summary"] as? String, "Sent message to user.")
    XCTAssertTrue(DatabaseManager.hasReplied(taskId: "task-success"))
    XCTAssertEqual(TestHostGlobals.httpCalls.count, 1)
    let call = TestHostGlobals.httpCalls[0]
    XCTAssertEqual(call["method"] as? String, "POST")
    XCTAssertTrue((call["url"] as? String ?? "").contains("/sendMessage"))
  }

  func testReplyTypingSuccessDoesNotMarkReplied() {
    let token = makeBinding(taskId: "task-typing")
    setHTTPSuccess()

    let env = parseEnvelope(
      handleReplyTyping(
        state: state, payload: #"{"reply_token":"\#(token)"}"#))

    XCTAssertEqual(env["ok"] as? Bool, true)
    XCTAssertFalse(
      DatabaseManager.hasReplied(taskId: "task-typing"),
      "typing-only must not flip the safety-net flag")
    XCTAssertEqual(TestHostGlobals.httpCalls.count, 1)
    let call = TestHostGlobals.httpCalls[0]
    XCTAssertTrue((call["url"] as? String ?? "").contains("/sendChatAction"))
  }

  func testReplyPhotoSuccess() {
    let token = makeBinding(taskId: "task-photo")
    setHTTPSuccess()

    let env = parseEnvelope(
      handleReplyPhoto(
        state: state,
        payload:
          #"{"reply_token":"\#(token)","photo_url":"https://example.com/p.jpg","caption":"cap"}"#))

    XCTAssertEqual(env["ok"] as? Bool, true)
    XCTAssertTrue(DatabaseManager.hasReplied(taskId: "task-photo"))
    let call = TestHostGlobals.httpCalls[0]
    XCTAssertTrue((call["url"] as? String ?? "").contains("/sendPhoto"))
  }

  func testReplyClampsLongTextToFourThousandChars() {
    let token = makeBinding(taskId: "task-long")
    setHTTPSuccess()

    let longText = String(repeating: "x", count: 5_000)
    let payload: [String: Any] = ["reply_token": token, "text": longText]
    let payloadJSON =
      String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!

    _ = handleReply(state: state, payload: payloadJSON)

    let body = TestHostGlobals.httpCalls[0]["body"] as? String ?? ""
    let bodyObj = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
    let sentText = bodyObj?["text"] as? String ?? ""
    XCTAssertEqual(sentText.count, 4_000, "text must be clamped to 4000 chars")
  }

  // MARK: failure mapping

  func testReplyMapsBotWasBlockedAndCancelsTask() {
    let token = makeBinding(chatId: 300, taskId: "task-blocked")
    setHTTPBotWasBlocked()

    let env = parseEnvelope(
      handleReply(
        state: state,
        payload: #"{"reply_token":"\#(token)","text":"hi"}"#))

    XCTAssertEqual(env["error"] as? String, "chat_blocked")
    XCTAssertTrue(DatabaseManager.isChatBlocked(agentId: agentId, chatId: 300))
    XCTAssertEqual(TestHostGlobals.cancelCalls, ["task-blocked"])
    XCTAssertFalse(
      DatabaseManager.hasReplied(taskId: "task-blocked"),
      "failed reply must not flip has_replied")
  }

  func testReplyMapsGenericTelegramError() {
    let token = makeBinding(chatId: 400, taskId: "task-err")
    setHTTPGenericError()

    let env = parseEnvelope(
      handleReply(
        state: state,
        payload: #"{"reply_token":"\#(token)","text":"hi"}"#))

    XCTAssertEqual(env["error"] as? String, "telegram_api_error")
    XCTAssertTrue(
      (env["message"] as? String ?? "").contains("chat not found"),
      "telegram description should propagate")
    XCTAssertFalse(DatabaseManager.isChatBlocked(agentId: agentId, chatId: 400))
    XCTAssertTrue(TestHostGlobals.cancelCalls.isEmpty)
  }

  // MARK: invoke dispatcher (smoke)

  func testHandleReplyPassesParseModeThrough() {
    let token = makeBinding(taskId: "task-pm")
    setHTTPSuccess()

    _ = handleReply(
      state: state,
      payload: #"{"reply_token":"\#(token)","text":"<b>hi</b>","parse_mode":"HTML"}"#)

    let body = TestHostGlobals.httpCalls[0]["body"] as? String ?? ""
    let bodyObj = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
    XCTAssertEqual(bodyObj?["parse_mode"] as? String, "HTML")
  }
}
