import XCTest

@testable import osaurus_telegram

/// Pin Phase 3c: a `callback_query` update (inline keyboard button
/// press) is acknowledged via `answerCallbackQuery` and routed as a
/// synthetic user turn whose body is `[button:<callback_data>]`. The
/// turn keys on the BUTTON-PRESSER's user_id (not the source message
/// author's), so in groups the button press hits the presser's session.
final class CallbackQueryTests: XCTestCase {

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
    state.botUsername = "MyTestBot"
    state.botId = 9001
  }

  override func tearDown() {
    state = nil
    TestHost.uninstall()
    super.tearDown()
  }

  // MARK: - decoding

  func testTGUpdateDecodesCallbackQuery() throws {
    let body = """
      {
        "update_id": 7,
        "callback_query": {
          "id": "cb-1",
          "from": { "id": 555, "username": "alice" },
          "data": "yes",
          "message": {
            "message_id": 12,
            "chat": { "id": 100 }
          }
        }
      }
      """
    let parsed = try XCTUnwrap(parseJSON(body, as: TGUpdate.self))
    XCTAssertEqual(parsed.callback_query?.id, "cb-1")
    XCTAssertEqual(parsed.callback_query?.data, "yes")
    XCTAssertEqual(parsed.callback_query?.from?.id, 555)
    XCTAssertEqual(parsed.callback_query?.message?.chat.id, 100)
  }

  // MARK: - end-to-end button press

  /// A button press dispatches a user turn with body
  /// `[button:<callback_data>]` and acknowledges the callback so the
  /// Telegram client clears the spinner.
  func testCallbackQueryDispatchesSyntheticUserTurnAndAcks() throws {
    _ = handleRoute(
      state: state, agentId: agentId,
      requestJSON: webhookRequest(
        secret: secret,
        update: callbackUpdate(
          updateId: 1, cbId: "cb-1", chatId: 100, msgId: 12,
          fromId: 555, data: "yes")))

    // answerCallbackQuery fires regardless of routing outcome.
    let ackCalls = TestHostGlobals.httpCalls.filter {
      ($0["url"] as? String ?? "").contains("/answerCallbackQuery")
    }
    XCTAssertEqual(ackCalls.count, 1, "callback must be acknowledged")
    let ackBody = ackCalls[0]["body"] as? String ?? ""
    XCTAssertTrue(ackBody.contains("\"callback_query_id\":\"cb-1\""))

    // And the synthetic user turn dispatches.
    XCTAssertEqual(TestHostGlobals.dispatchCalls.count, 1)
    let prompt = TestHostGlobals.dispatchCalls[0]["prompt"] as? String ?? ""
    XCTAssertTrue(
      prompt.contains("[button:yes]"),
      "synthetic body must surface the callback_data verbatim; got: \(prompt)")
  }

  /// The synthetic turn keys on the button PRESSER's user id, not the
  /// source message's author. That's the right behaviour in groups: a
  /// member can press a button on a bot reply they didn't trigger and
  /// the resulting follow-up lands in their own session.
  func testCallbackKeysOnPressersUserId() throws {
    _ = handleRoute(
      state: state, agentId: agentId,
      requestJSON: webhookRequest(
        secret: secret,
        update: callbackUpdate(
          updateId: 2, cbId: "cb-2", chatId: -100_2, msgId: 99,
          fromId: 6_001, data: "click")))

    XCTAssertEqual(TestHostGlobals.dispatchCalls.count, 1)
    let key = TestHostGlobals.dispatchCalls[0]["external_session_key"] as? String
    XCTAssertEqual(
      key, externalSessionKey(chatId: -100_2, userId: 6_001, salt: 0),
      "session key must derive from the button-presser's user_id")
  }

  /// A button press in a blocked chat is silently ignored — the
  /// callback is still acknowledged so Telegram clears the spinner,
  /// but no agent turn dispatches.
  func testCallbackInBlockedChatDoesNotDispatch() {
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 333)
    DatabaseManager.markChatBlocked(agentId: agentId, chatId: 333)

    _ = handleRoute(
      state: state, agentId: agentId,
      requestJSON: webhookRequest(
        secret: secret,
        update: callbackUpdate(
          updateId: 3, cbId: "cb-3", chatId: 333, msgId: 1,
          fromId: 1, data: "x")))

    XCTAssertTrue(TestHostGlobals.dispatchCalls.isEmpty)
    let ackCalls = TestHostGlobals.httpCalls.filter {
      ($0["url"] as? String ?? "").contains("/answerCallbackQuery")
    }
    XCTAssertEqual(
      ackCalls.count, 1,
      "Telegram must still see an ack so the spinner clears")
  }

  /// Duplicate update_ids short-circuit: a Telegram retry must not
  /// double-dispatch the synthetic turn.
  func testCallbackIsDeduplicatedByUpdateId() {
    let req = webhookRequest(
      secret: secret,
      update: callbackUpdate(
        updateId: 9, cbId: "cb-x", chatId: 100, msgId: 1,
        fromId: 1, data: "go"))
    _ = handleRoute(state: state, agentId: agentId, requestJSON: req)
    _ = handleRoute(state: state, agentId: agentId, requestJSON: req)
    XCTAssertEqual(
      TestHostGlobals.dispatchCalls.count, 1,
      "duplicate callback updates must short-circuit")
  }

  // MARK: - Helpers

  private func callbackUpdate(
    updateId: Int, cbId: String, chatId: Int64, msgId: Int64,
    fromId: Int64, data: String
  ) -> [String: Any] {
    return [
      "update_id": updateId,
      "callback_query": [
        "id": cbId,
        "from": [
          "id": fromId, "username": "presser", "first_name": "Press",
        ] as [String: Any],
        "data": data,
        "message": [
          "message_id": msgId,
          "chat": ["id": chatId],
        ] as [String: Any],
      ] as [String: Any],
    ]
  }

}
