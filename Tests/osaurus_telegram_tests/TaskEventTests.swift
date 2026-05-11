import XCTest

@testable import osaurus_telegram

// MARK: - TaskEvent / safety-net coverage
//
// COMPLETED is the last-resort path: when the agent ends a run without
// calling `reply`, we still need to surface something useful to the user.
// These tests pin two contracts:
//   1. `safetyNetCompletedMessage` picks `output` (the agent's final prose)
//      over `summary` (often a generic title like "Chat completed").
//   2. The end-to-end COMPLETED handler honors that pick when posting to
//      Telegram, and stays silent if the agent already replied.

final class TaskEventTests: XCTestCase {

  private var state: AgentState!
  private let agentId = defaultTestAgentId

  override func setUp() {
    super.setUp()
    TestHost.install()
    DatabaseManager.initSchema()
    state = AgentState(agentId: agentId)
    state.botToken = "123:fake"
    // Tests want synchronous safety-net behaviour; production defers by
    // a few seconds to absorb the host's multi-round COMPLETED quirk.
    safetyNetDelaySeconds = 0
  }

  override func tearDown() {
    state = nil
    TestHost.uninstall()
    safetyNetDelaySeconds = 5
    super.tearDown()
  }

  // MARK: helpers

  /// Seed an active dispatch the safety-net handler can find.
  @discardableResult
  private func seedBinding(
    taskId: String = "task-completed",
    chatId: Int64 = 100
  ) -> String {
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: chatId)
    let token = "TOK\(taskId.suffix(5))"
    DatabaseManager.insertActiveDispatch(
      taskId: taskId, agentId: agentId, chatId: chatId, replyToken: String(token),
      sessionId: "session-1",
      expiresAt: Int(Date().timeIntervalSince1970) + 600)
    return String(token)
  }

  private func sentMessageText() -> String? {
    let call = TestHostGlobals.httpCalls.first { call in
      (call["url"] as? String ?? "").contains("/sendMessage")
    }
    guard let bodyStr = call?["body"] as? String,
      let bodyData = bodyStr.data(using: .utf8),
      let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
    else { return nil }
    return body["text"] as? String
  }

  // MARK: pure precedence

  func testSafetyNetPrefersOutputOverSummary() {
    let json = #"{"summary":"Chat completed","output":"Weather in NYC: +63°F"}"#
    XCTAssertEqual(safetyNetCompletedMessage(eventJSON: json), "Weather in NYC: +63°F")
  }

  func testSafetyNetFallsBackToSummaryWhenOutputMissing() {
    let json = #"{"summary":"Chat completed"}"#
    XCTAssertEqual(safetyNetCompletedMessage(eventJSON: json), "Chat completed")
  }

  func testSafetyNetFallsBackToSummaryWhenOutputBlank() {
    // Whitespace-only output must not win over a real summary.
    let json = #"{"summary":"Chat completed","output":"   \n\t  "}"#
    XCTAssertEqual(safetyNetCompletedMessage(eventJSON: json), "Chat completed")
  }

  func testSafetyNetFallsBackToDoneWhenBothMissing() {
    XCTAssertEqual(safetyNetCompletedMessage(eventJSON: "{}"), "(done)")
  }

  func testSafetyNetFallsBackToDoneWhenBothBlank() {
    let json = #"{"summary":"  ","output":""}"#
    XCTAssertEqual(safetyNetCompletedMessage(eventJSON: json), "(done)")
  }

  func testSafetyNetTrimsSurroundingWhitespace() {
    let json = #"{"output":"  hello  \n"}"#
    XCTAssertEqual(safetyNetCompletedMessage(eventJSON: json), "hello")
  }

  func testSafetyNetClampsTo4000Chars() {
    let long = String(repeating: "x", count: 5_000)
    let payload = ["output": long]
    let json = String(
      data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
    XCTAssertEqual(safetyNetCompletedMessage(eventJSON: json).count, 4_000)
  }

  func testSafetyNetTolleratesMalformedJSON() {
    XCTAssertEqual(safetyNetCompletedMessage(eventJSON: "not json"), "(done)")
  }

  // MARK: end-to-end COMPLETED handler

  func testCompletedWithoutReplyPostsOutputToTelegram() {
    seedBinding(taskId: "task-weather", chatId: 555)

    let event = #"{"summary":"Chat completed","output":"Weather in NYC: +63°F","success":true}"#
    handleTaskEvent(
      state: state, agentId: agentId,
      taskId: "task-weather", eventType: 4, eventJSON: event)

    XCTAssertEqual(sentMessageText(), "Weather in NYC: +63°F")
    // The row is intentionally retained — a late `reply` from a
    // subsequent LLM round must still find the binding. The TTL sweep
    // is what eventually retires it.
    XCTAssertNotNil(
      DatabaseManager.activeDispatch(agentId: agentId, forChat: 555),
      "COMPLETED must keep the binding alive for late replies; TTL cleans it up")
    XCTAssertTrue(
      DatabaseManager.hasReplied(taskId: "task-weather"),
      "safety-net firing must flip has_replied so a duplicate COMPLETED can't double-post")
  }

  func testCompletedWithReplyAlreadySentStaysSilent() {
    seedBinding(taskId: "task-ok", chatId: 600)
    DatabaseManager.markReplied(taskId: "task-ok")

    let event = #"{"summary":"Chat completed","output":"Final answer","success":true}"#
    handleTaskEvent(
      state: state, agentId: agentId,
      taskId: "task-ok", eventType: 4, eventJSON: event)

    XCTAssertTrue(
      TestHostGlobals.httpCalls.filter {
        ($0["url"] as? String ?? "").contains("/sendMessage")
      }.isEmpty,
      "if the agent already replied, the safety net must not double-post")
    XCTAssertNotNil(
      DatabaseManager.activeDispatch(agentId: agentId, forChat: 600),
      "row stays alive; cleanup is the TTL sweep's job")
  }

  func testCompletedFallsBackToSummaryWhenOutputAbsent() {
    seedBinding(taskId: "task-only-summary", chatId: 700)

    let event = #"{"summary":"Researched the weather","success":true}"#
    handleTaskEvent(
      state: state, agentId: agentId,
      taskId: "task-only-summary", eventType: 4, eventJSON: event)

    XCTAssertEqual(sentMessageText(), "Researched the weather")
  }

  // MARK: - host's premature COMPLETED + late `reply` (regression)

  /// Reproduces the user's reported scenario: the host fires COMPLETED with
  /// the agent's interim text output (`"No response needed."`) after the
  /// first streaming round, then starts a second round that calls `reply`
  /// with the actual answer. Before this fix the safety-net post landed
  /// first and deleted the binding, leaving the agent's `reply` to fail
  /// with `stale_token` and the user staring at the wrong text.
  func testLateReplySucceedsAgainstRetainedRow() {
    let token = seedBinding(taskId: "task-multi-round", chatId: 999)

    // Host's premature COMPLETED — agent isn't actually done yet.
    let event = #"{"output":"No response needed.","success":true}"#
    handleTaskEvent(
      state: state, agentId: agentId,
      taskId: "task-multi-round", eventType: 4, eventJSON: event)

    // Row must still be lookupable so a late reply can land.
    let bindingAfterCompleted = DatabaseManager.lookupBinding(token: token)
    XCTAssertNotNil(
      bindingAfterCompleted,
      "row must outlive the safety-net post so a late reply can find it")
    XCTAssertEqual(bindingAfterCompleted?.taskId, "task-multi-round")
  }

  /// A second COMPLETED for the same task (the host's "real" terminal event
  /// after the tool-call round) must not double-post the safety-net text.
  /// `has_replied` is the dedupe flag.
  func testDuplicateCompletedDoesNotDoublePost() {
    seedBinding(taskId: "task-dup", chatId: 1_001)

    let event = #"{"output":"interim text","success":true}"#
    handleTaskEvent(
      state: state, agentId: agentId,
      taskId: "task-dup", eventType: 4, eventJSON: event)
    handleTaskEvent(
      state: state, agentId: agentId,
      taskId: "task-dup", eventType: 4, eventJSON: event)

    let posts = TestHostGlobals.httpCalls.filter {
      ($0["url"] as? String ?? "").contains("/sendMessage")
    }
    XCTAssertEqual(
      posts.count, 1,
      "two COMPLETED events for the same task must not produce two safety-net posts")
  }

  // MARK: CANCELLED — must NOT delete the row

  /// Regression test for the v3 schema redesign: when a turn is
  /// soft-interrupted by a new user message, some host versions emit a
  /// CANCELLED event for the prior task. The prior task may still be
  /// "finishing the current step" (per dispatch_interrupt semantics),
  /// which includes the agent's pending `reply` tool call. Deleting the
  /// row on CANCELLED would manufacture a `stale_token` against the
  /// agent's own reply.
  func testCancelledDoesNotDeleteBinding() {
    let token = seedBinding(taskId: "task-interrupted", chatId: 800)

    handleTaskEvent(
      state: state, agentId: agentId,
      taskId: "task-interrupted", eventType: 6, eventJSON: #"{"title":"x"}"#)

    XCTAssertNotNil(
      DatabaseManager.lookupBinding(token: token),
      "CANCELLED must leave the row in place so a trailing reply can land")
    XCTAssertTrue(
      TestHostGlobals.httpCalls.filter {
        ($0["url"] as? String ?? "").contains("/sendMessage")
      }.isEmpty,
      "CANCELLED is observability-only — no Telegram post")
  }
}
