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
    // Per-turn reminder: without this, models that lean on a generic
    // "gather → complete" loop drop the reply step after a sandbox tool
    // call. The directive must reach the model on every single turn.
    XCTAssertTrue(
      prompt.contains("respond by calling reply"),
      "per-turn header must remind the model to call reply before ending the turn")

    let title = try XCTUnwrap(dispatch["title"] as? String)
    XCTAssertEqual(title, "Telegram alice")

    let sessionId = try XCTUnwrap(dispatch["session_id"] as? String)
    let chat = try XCTUnwrap(
      DatabaseManager.getChatSession(agentId: agentId, chatId: 555))
    let expected = sessionUUID(forChatId: 555, salt: chat.sessionSalt).uuidString
    XCTAssertEqual(sessionId, expected, "session id must be deterministic UUID5")

    // The dispatch must explicitly request our reply tools on the
    // host's v3+ `tools` field. Without this, an agent with manual
    // tool selection would receive the user's message but have no way
    // to respond.
    let tools = try XCTUnwrap(dispatch["tools"] as? [String])
    XCTAssertEqual(
      Set(tools), Set(["reply", "reply_typing", "reply_photo"]),
      "dispatch must request the full reply surface")

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

    // Second turn gets a different host task id. Schema v3 lets the new
    // row coexist with the old one (no UNIQUE constraint to fight); both
    // attach to the same session id so the agent sees a single thread.
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

  // MARK: - reset commands (/clear, /reset, aliases, @botname suffix)

  func testIsResetCommandRecognizesAllAliasesAndCasings() {
    // Documented verbs.
    for verb in ["/clear", "/reset", "/new", "/restart"] {
      XCTAssertTrue(isResetCommand(verb), "\(verb) must be recognised")
      XCTAssertTrue(
        isResetCommand(verb.uppercased()),
        "case-insensitive match must accept \(verb.uppercased())")
    }
    // Telegram appends `@botname` in group chats — must be tolerated.
    XCTAssertTrue(isResetCommand("/clear@MyBot"))
    XCTAssertTrue(isResetCommand("/Reset@SomeBot_Test"))

    // Non-matches.
    XCTAssertFalse(isResetCommand(""))
    XCTAssertFalse(isResetCommand("clear"), "must require leading slash")
    XCTAssertFalse(isResetCommand("/cleared"))
    XCTAssertFalse(
      isResetCommand("/clear now"),
      "embedded whitespace means it's a chat message, not a bare command")
    XCTAssertFalse(isResetCommand("/start"))
  }

  func testClearCommandResetsTheConversation() {
    // Same flow as /reset: bump salt, cancel active dispatch, post the
    // confirmation, do NOT dispatch a fresh agent turn.
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 810)
    DatabaseManager.insertActiveDispatch(
      taskId: "running-task-clear", agentId: agentId, chatId: 810,
      replyToken: "TOKCLEAR1", sessionId: "old-session",
      expiresAt: Int(Date().timeIntervalSince1970) + 600)

    let req = webhookRequest(
      secret: secret, update: textUpdate(updateId: 710, chatId: 810, text: "/clear"))
    let response = parseRouteResponse(route(req))
    XCTAssertEqual(response.status, 200)

    XCTAssertEqual(
      DatabaseManager.getChatSession(agentId: agentId, chatId: 810)?.sessionSalt, 1,
      "/clear must bump the session salt")
    XCTAssertNil(DatabaseManager.activeDispatch(agentId: agentId, forChat: 810))
    XCTAssertEqual(TestHostGlobals.cancelCalls, ["running-task-clear"])
    XCTAssertTrue(
      TestHostGlobals.dispatchCalls.isEmpty,
      "/clear must NOT dispatch a fresh agent turn")
  }

  func testClearWithBotMentionInGroupChatStillResets() {
    // Group chats deliver `/clear@BotName` instead of bare `/clear`.
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 820)
    let req = webhookRequest(
      secret: secret,
      update: textUpdate(updateId: 720, chatId: 820, text: "/clear@MyTestBot"))
    _ = route(req)

    XCTAssertEqual(
      DatabaseManager.getChatSession(agentId: agentId, chatId: 820)?.sessionSalt, 1,
      "/clear@<bot> must be treated as /clear")
    XCTAssertTrue(TestHostGlobals.dispatchCalls.isEmpty)
  }

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

    // Second message arrives mid-flight with its own task id.
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

    // Schema v3: BOTH rows coexist after the interrupt. The prior row is
    // not deleted by the webhook handler — it's left to its own terminal
    // event (or the TTL sweep) to clean up. activeDispatch returns the
    // latest one.
    let allActive = DatabaseManager.allActiveDispatches(
      agentId: agentId, forChat: 900)
    XCTAssertEqual(
      Set(allActive.map { $0.taskId }), Set(["task-uuid", "task-second"]),
      "schema v3 keeps the prior row until its terminal event arrives")
    XCTAssertEqual(
      DatabaseManager.activeDispatch(agentId: agentId, forChat: 900)?.taskId,
      "task-second",
      "activeDispatch returns the most recently dispatched row")
  }

  func testReplyTokenBoundBeforeDispatchReturns() throws {
    // The whole point of the v3 redesign: the agent can never observe a
    // "stale_token" for the current turn because the binding is in the DB
    // before the host returns from `dispatch`. We assert that invariant by
    // looking up the binding from the dispatch inspector, which fires
    // synchronously inside `stub_dispatch` BEFORE the response is
    // returned to the plugin.
    var observedToken: String?
    var observedTaskIdAtDispatch: String?
    TestHostGlobals.dispatchInspector = { request in
      let prompt = request["prompt"] as? String ?? ""
      // Pull the token out of the per-turn header `[reply_token <token>
      // from <name>]` exactly the way `Tools.reply` does in production.
      guard let openBracket = prompt.firstIndex(of: "["),
        let closeBracket = prompt.firstIndex(of: "]")
      else { return }
      let header = prompt[prompt.index(after: openBracket)..<closeBracket]
      let parts = header.split(separator: " ")
      guard parts.count >= 2, parts[0] == "reply_token" else { return }
      let token = String(parts[1])
      observedToken = token
      observedTaskIdAtDispatch =
        DatabaseManager.lookupBinding(token: token)?.taskId
    }

    let req = webhookRequest(
      secret: secret, update: textUpdate(updateId: 1200, chatId: 1200, text: "hi"))
    _ = route(req)

    let token = try XCTUnwrap(
      observedToken, "test inspector should have captured the minted token")
    // Inside the dispatch call the row exists, but its task_id is still
    // the pre-insert placeholder — proving the binding was pinned BEFORE
    // the host returned `task_id` to the plugin.
    let placeholder = try XCTUnwrap(
      observedTaskIdAtDispatch,
      "binding must exist in the DB before dispatch returns")
    XCTAssertEqual(
      placeholder, pendingTaskId(for: token),
      "binding inside dispatch should still carry the pre-insert placeholder")

    // After the webhook returns the placeholder must be patched to the
    // real task_id that the host returned.
    XCTAssertEqual(
      DatabaseManager.lookupBinding(token: token)?.taskId, "task-uuid",
      "placeholder task_id must be patched to the host-returned task_id")
  }

  // MARK: - dispatch error unwinds the pre-inserted row

  func testRateLimitErrorUnwindsPreInsertedRow() {
    TestHostGlobals.nextDispatchResponse = #"{"error":"rate_limit_exceeded"}"#
    let req = webhookRequest(
      secret: secret, update: textUpdate(updateId: 1300, chatId: 1300, text: "hi"))
    _ = route(req)

    // The webhook handler pre-inserts the binding BEFORE calling
    // dispatch. Once dispatch returns an error, that pre-insert must be
    // unwound — otherwise we'd leak a "phantom" row that only the TTL
    // sweep would eventually reap.
    XCTAssertNil(DatabaseManager.activeDispatch(agentId: agentId, forChat: 1300))
    XCTAssertTrue(
      DatabaseManager.allActiveDispatches(agentId: agentId, forChat: 1300).isEmpty,
      "pre-inserted row must be unwound on rate-limit error")
  }

  func testDispatchMissingIdUnwindsPreInsertedRow() {
    // Host returns a 200-OK shaped response but with no id and no error.
    // The webhook handler can't possibly patch the placeholder task_id —
    // unwinding the row keeps the DB clean.
    TestHostGlobals.nextDispatchResponse = #"{"status":"running"}"#
    let req = webhookRequest(
      secret: secret, update: textUpdate(updateId: 1301, chatId: 1301, text: "hi"))
    _ = route(req)

    XCTAssertNil(DatabaseManager.activeDispatch(agentId: agentId, forChat: 1301))
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
