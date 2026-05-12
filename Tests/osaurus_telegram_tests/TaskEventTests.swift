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
    chatId: Int64 = 100,
    incomingMessageId: Int64 = 0
  ) -> String {
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: chatId)
    let token = "TOK\(taskId.suffix(5))"
    DatabaseManager.insertActiveDispatch(
      taskId: taskId, agentId: agentId, chatId: chatId, replyToken: String(token),
      sessionId: "session-1",
      expiresAt: Int(Date().timeIntervalSince1970) + 600,
      incomingMessageId: incomingMessageId)
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

  // MARK: - OUTPUT-stash safety-net precedence
  //
  // OUTPUT events carry the agent's actual streaming prose (throttled to
  // ~1/sec). They beat COMPLETED's `output` field because the host fires
  // multiple COMPLETED events per task and the first one's `output` can
  // carry interim text like "No response needed." that races the answer.

  /// Pure-function precedence: streamingOutput > output > summary > "(done)".
  func testSafetyNetCompletedMessageRespectsStreamingArg() {
    let json = #"{"summary":"Chat completed","output":"interim"}"#
    XCTAssertEqual(
      safetyNetCompletedMessage(eventJSON: json, streamingOutput: "real answer"),
      "real answer",
      "streamingOutput must beat both output and summary")
    XCTAssertEqual(
      safetyNetCompletedMessage(eventJSON: json, streamingOutput: "   "),
      "interim",
      "blank streamingOutput must fall through to output")
    XCTAssertEqual(
      safetyNetCompletedMessage(eventJSON: json, streamingOutput: nil),
      "interim",
      "nil streamingOutput must behave like the legacy 1-arg call")
  }

  /// End-to-end: an OUTPUT event followed by a COMPLETED with empty
  /// output must surface the streamed text.
  func testOutputEventStashesLatestPerTask() {
    seedBinding(taskId: "task-stream", chatId: 1_100)

    handleTaskEvent(
      state: state, agentId: agentId,
      taskId: "task-stream", eventType: 7,
      eventJSON: #"{"text":"Healthy snacks include apples and almonds."}"#)
    XCTAssertEqual(
      state.latestOutput(taskId: "task-stream"),
      "Healthy snacks include apples and almonds.",
      "OUTPUT event must populate the per-task cache")

    let event = #"{"summary":"Chat completed","output":"","success":true}"#
    handleTaskEvent(
      state: state, agentId: agentId,
      taskId: "task-stream", eventType: 4, eventJSON: event)

    XCTAssertEqual(
      sentMessageText(), "Healthy snacks include apples and almonds.")
  }

  /// Reproduction of the silent-reply scenario: OUTPUT carries the real
  /// answer, COMPLETED carries interim "No response needed.". The
  /// streamed text must win.
  func testStreamingOutputBeatsCompletedInterimText() {
    seedBinding(taskId: "task-multi", chatId: 1_101)

    handleTaskEvent(
      state: state, agentId: agentId,
      taskId: "task-multi", eventType: 7,
      eventJSON: #"{"text":"The capital of France is Paris."}"#)

    let event = #"{"output":"No response needed.","success":true}"#
    handleTaskEvent(
      state: state, agentId: agentId,
      taskId: "task-multi", eventType: 4, eventJSON: event)

    XCTAssertEqual(
      sentMessageText(), "The capital of France is Paris.",
      "the agent's actual streamed text must reach Telegram, "
        + "not the host's interim COMPLETED.output")
  }

  /// When the agent did call `reply` (so has_replied=1), a stashed
  /// OUTPUT must NOT cause the safety net to double-post.
  func testRepliedTaskIgnoresStashedOutput() {
    seedBinding(taskId: "task-already-replied", chatId: 1_102)
    DatabaseManager.markReplied(taskId: "task-already-replied")

    handleTaskEvent(
      state: state, agentId: agentId,
      taskId: "task-already-replied", eventType: 7,
      eventJSON: #"{"text":"This must NOT be posted."}"#)
    handleTaskEvent(
      state: state, agentId: agentId,
      taskId: "task-already-replied", eventType: 4,
      eventJSON: #"{"output":"","success":true}"#)

    XCTAssertTrue(
      TestHostGlobals.httpCalls.filter {
        ($0["url"] as? String ?? "").contains("/sendMessage")
      }.isEmpty,
      "agent already replied; safety net must not double-post the OUTPUT cache")
    XCTAssertNil(
      state.latestOutput(taskId: "task-already-replied"),
      "the cache must be cleared once we know the task already replied")
  }

  /// Empty OUTPUT events must not blow away a previously-good cache —
  /// the host occasionally fires stray empties between content events.
  func testEmptyOutputEventDoesNotEvictCache() {
    seedBinding(taskId: "task-empty-stream", chatId: 1_103)

    handleTaskEvent(
      state: state, agentId: agentId,
      taskId: "task-empty-stream", eventType: 7,
      eventJSON: #"{"text":"Real answer text."}"#)
    handleTaskEvent(
      state: state, agentId: agentId,
      taskId: "task-empty-stream", eventType: 7,
      eventJSON: #"{"text":""}"#)
    handleTaskEvent(
      state: state, agentId: agentId,
      taskId: "task-empty-stream", eventType: 7,
      eventJSON: #"{"text":"   \n  "}"#)

    XCTAssertEqual(
      state.latestOutput(taskId: "task-empty-stream"),
      "Real answer text.",
      "empty / whitespace-only OUTPUT events must not evict prior content")
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

  // MARK: - CANCELLED — must NOT delete the row

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

  // MARK: - safety net clears the loading eye

  /// When the agent never replies, the COMPLETED safety-net path must
  /// clear the 👀 reaction in the same pass as it posts the fallback
  /// text. Without this clearance the eye lingers on a chat where the
  /// user actually got an answer.
  func testCompletedSafetyNetClearsLoadingReaction() {
    seedBinding(taskId: "task-eye-safetynet", chatId: 1_500, incomingMessageId: 33)

    let event = #"{"summary":"Chat completed","output":"Answer text","success":true}"#
    handleTaskEvent(
      state: state, agentId: agentId,
      taskId: "task-eye-safetynet", eventType: 4, eventJSON: event)

    let calls = TestHostGlobals.httpCalls.filter {
      ($0["url"] as? String ?? "").contains("/setMessageReaction")
    }
    XCTAssertEqual(calls.count, 1, "safety net must clear the eye exactly once")
    let body = calls[0]["body"] as? String ?? ""
    let bodyObj =
      (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
    XCTAssertEqual(bodyObj["chat_id"] as? Int, 1_500)
    XCTAssertEqual(bodyObj["message_id"] as? Int, 33)
    XCTAssertTrue(
      (bodyObj["reaction"] as? [[String: Any]] ?? [["sentinel": "x"]]).isEmpty,
      "clear means an empty reaction array")
  }

  // MARK: - tool-envelope sanitization
  //
  // Even when the host doesn't fire CLARIFICATION (older host versions
  // route the agent's `clarify` tool entirely through their own native
  // UI), the safety-net must not leak the tool's JSON envelope to the
  // user. We detect `{"ok":..., "tool":"<name>", ...}` and either
  // substitute a helpful fallback (clarify) or drop it (any other tool)
  // so the caller falls through to the next precedence level.

  func testSafetyNetReplacesClarifyEnvelopeWithFallback() {
    let envelope =
      #"{"ok":true,"result":{"text":"Awaiting user response."},"tool":"clarify"}"#
    let json = #"{"output":"\#(envelope.replacingOccurrences(of: "\"", with: "\\\""))"}"#
    XCTAssertEqual(safetyNetCompletedMessage(eventJSON: json), clarifyFallbackMessage)
  }

  func testSafetyNetDropsUnknownToolEnvelopeAndFallsThrough() {
    let envelope =
      #"{"ok":true,"result":{"foo":"bar"},"tool":"some_internal_tool"}"#
    // `output` is the bad envelope; `summary` is real prose. The
    // envelope must drop and summary wins.
    var obj: [String: Any] = [
      "output": envelope,
      "summary": "Researched the weather",
    ]
    let json = String(
      data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    XCTAssertEqual(safetyNetCompletedMessage(eventJSON: json), "Researched the weather")

    // No summary either → "(done)" rather than the envelope.
    obj.removeValue(forKey: "summary")
    let json2 = String(
      data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    XCTAssertEqual(safetyNetCompletedMessage(eventJSON: json2), "(done)")
  }

  func testSafetyNetSanitizesStreamingOutputEnvelope() {
    // The streamed text leg can also carry the envelope (the agent's
    // final assistant message is sometimes just the tool result).
    let envelope =
      #"{"ok":true,"result":{"text":"Awaiting user response."},"tool":"clarify"}"#
    let json = #"{"summary":"Chat completed"}"#
    XCTAssertEqual(
      safetyNetCompletedMessage(eventJSON: json, streamingOutput: envelope),
      clarifyFallbackMessage,
      "envelope in streamingOutput must be sanitized just like envelope in output")
  }

  func testSafetyNetLeavesLegitimateJSONLookingProseAlone() {
    // A real reply that happens to mention JSON-looking braces (but
    // isn't a tool envelope — no `tool` key, no `ok`) must pass through
    // unmodified.
    let json = #"{"output":"Here is your config: {\"key\":\"value\"}"}"#
    XCTAssertEqual(
      safetyNetCompletedMessage(eventJSON: json),
      #"Here is your config: {"key":"value"}"#,
      "prose that mentions JSON must not be misclassified as a tool envelope")
  }

  /// End-to-end: the exact scenario from the bug report. The agent
  /// called the host clarify tool, the host emitted COMPLETED with
  /// `output` set to the tool envelope, no CLARIFICATION event ever
  /// fired. The user must see the fallback, not the JSON.
  func testCompletedWithClarifyEnvelopePostsFallback() {
    seedBinding(taskId: "task-clarify-envelope", chatId: 3_000, incomingMessageId: 42)

    let envelope =
      #"{\"ok\":true,\"result\":{\"text\":\"Awaiting user response.\"},\"tool\":\"clarify\"}"#
    let event = "{\"output\":\"\(envelope)\",\"success\":true}"
    handleTaskEvent(
      state: state, agentId: agentId,
      taskId: "task-clarify-envelope", eventType: 4, eventJSON: event)

    XCTAssertEqual(
      sentMessageText(), clarifyFallbackMessage,
      "the user must see the clarify fallback, not the tool envelope JSON")
  }

  // MARK: - tool-envelope detector

  func testDetectToolEnvelopeNameIdentifiesClarify() {
    XCTAssertEqual(
      detectToolEnvelopeName(
        in: #"{"ok":true,"result":{"text":"x"},"tool":"clarify"}"#),
      "clarify")
  }

  func testDetectToolEnvelopeNameRequiresEnvelopeShape() {
    // Just `{"tool":"x"}` without ok/result/error isn't an envelope —
    // could be legitimate agent prose.
    XCTAssertNil(detectToolEnvelopeName(in: #"{"tool":"clarify"}"#))
  }

  func testDetectToolEnvelopeNameReturnsNilForNonEnvelope() {
    XCTAssertNil(detectToolEnvelopeName(in: "plain text"))
    XCTAssertNil(detectToolEnvelopeName(in: ""))
    XCTAssertNil(detectToolEnvelopeName(in: #"{"ok":true,"result":"hi"}"#))
    XCTAssertNil(detectToolEnvelopeName(in: "not json at all"))
  }

  // MARK: - CLARIFICATION
  //
  // CLARIFICATION is the host's new canonical "agent wants to ask the user
  // something" signal — the legacy `dispatch_clarify` round-trip is a
  // no-op. Without an explicit handler the user only ever sees the
  // safety-net fallback (often the raw tool envelope JSON). These tests
  // pin: the question reaches Telegram, has_replied flips so the
  // trailing COMPLETED stays silent, the 👀 reaction is cleared, and an
  // empty payload falls through to the safety net.

  /// Helper: extract the most recent sendMessage body as a JSON dict.
  private func sentMessageBody() -> [String: Any]? {
    let call = TestHostGlobals.httpCalls.last { call in
      (call["url"] as? String ?? "").contains("/sendMessage")
    }
    guard let bodyStr = call?["body"] as? String,
      let bodyData = bodyStr.data(using: .utf8),
      let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
    else { return nil }
    return body
  }

  func testClarificationPostsQuestionAndMarksReplied() {
    seedBinding(taskId: "task-clarify", chatId: 2_000)

    let event = #"{"question":"What name should appear on the card?"}"#
    handleTaskEvent(
      state: state, agentId: agentId,
      taskId: "task-clarify", eventType: 3, eventJSON: event)

    XCTAssertEqual(
      sentMessageText(),
      "What name should appear on the card?",
      "the clarification question must be posted as-is to Telegram")
    XCTAssertEqual(sentMessageBody()?["chat_id"] as? Int, 2_000)
    XCTAssertTrue(
      DatabaseManager.hasReplied(taskId: "task-clarify"),
      "posting the question must flip has_replied so the trailing COMPLETED stays silent")
  }

  func testClarificationRendersOptionsAsNumberedList() {
    seedBinding(taskId: "task-clarify-options", chatId: 2_001)

    let event = #"{"question":"Which style?","options":["Modern","Classic"]}"#
    handleTaskEvent(
      state: state, agentId: agentId,
      taskId: "task-clarify-options", eventType: 3, eventJSON: event)

    XCTAssertEqual(
      sentMessageText(),
      "Which style?\n\n1. Modern\n2. Classic",
      "options must render as a numbered list under the question so users can reply by index")
  }

  func testClarificationAppendsAllowMultipleHint() {
    XCTAssertTrue(
      clarificationMessageText(
        eventJSON:
          #"{"question":"X","options":["A","B"],"allow_multiple":true}"#)?
        .hasSuffix("\n\n(reply with one or more)") ?? false,
      "allow_multiple:true must append the multi-pick hint")

    XCTAssertTrue(
      clarificationMessageText(
        eventJSON:
          #"{"question":"X","options":["A","B"],"allow_multiple":false}"#)?
        .hasSuffix("\n\n(reply with one)") ?? false,
      "allow_multiple:false must append the single-pick hint")

    // Field absent → no manufactured hint.
    let withoutField =
      clarificationMessageText(eventJSON: #"{"question":"X","options":["A","B"]}"#)
    XCTAssertEqual(
      withoutField, "X\n\n1. A\n2. B",
      "absent allow_multiple must not manufacture a hint")
  }

  func testClarificationFollowedByCompletedDoesNotDoublePost() {
    seedBinding(taskId: "task-clarify-then-complete", chatId: 2_002)

    handleTaskEvent(
      state: state, agentId: agentId,
      taskId: "task-clarify-then-complete", eventType: 3,
      eventJSON: #"{"question":"Need your email?"}"#)

    // Trailing COMPLETED whose `output` is the legacy clarify tool
    // envelope — this is exactly the JSON that leaked to users before
    // the fix.
    let bogus =
      #"{\"ok\":true,\"result\":{\"text\":\"Awaiting user response.\"},\"tool\":\"clarify\"}"#
    handleTaskEvent(
      state: state, agentId: agentId,
      taskId: "task-clarify-then-complete", eventType: 4,
      eventJSON: "{\"output\":\"\(bogus)\",\"success\":true}")

    let posts = TestHostGlobals.httpCalls.filter {
      ($0["url"] as? String ?? "").contains("/sendMessage")
    }
    XCTAssertEqual(
      posts.count, 1,
      "CLARIFICATION posts once; the safety net must stay silent because has_replied=1")
    XCTAssertEqual(
      sentMessageText(), "Need your email?",
      "the user-visible message must be the agent's question, not the tool envelope JSON")
  }

  func testClarificationClearsLoadingReaction() {
    seedBinding(taskId: "task-clarify-eye", chatId: 2_003, incomingMessageId: 77)

    handleTaskEvent(
      state: state, agentId: agentId,
      taskId: "task-clarify-eye", eventType: 3,
      eventJSON: #"{"question":"Any preferred color?"}"#)

    let calls = TestHostGlobals.httpCalls.filter {
      ($0["url"] as? String ?? "").contains("/setMessageReaction")
    }
    XCTAssertEqual(
      calls.count, 1,
      "clarification posts the question and clears the 👀 exactly once")
    let body = calls[0]["body"] as? String ?? ""
    let bodyObj =
      (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
    XCTAssertEqual(bodyObj["chat_id"] as? Int, 2_003)
    XCTAssertEqual(bodyObj["message_id"] as? Int, 77)
    XCTAssertTrue(
      (bodyObj["reaction"] as? [[String: Any]] ?? [["sentinel": "x"]]).isEmpty,
      "clearing the eye means an empty reaction array")
  }

  func testEmptyClarificationFallsThroughToSafetyNet() {
    seedBinding(taskId: "task-clarify-empty", chatId: 2_004)

    // CLARIFICATION with a blank question must not produce a Telegram
    // post (we'd be making up a question the agent never asked).
    handleTaskEvent(
      state: state, agentId: agentId,
      taskId: "task-clarify-empty", eventType: 3,
      eventJSON: #"{"question":"   "}"#)

    XCTAssertTrue(
      TestHostGlobals.httpCalls.filter {
        ($0["url"] as? String ?? "").contains("/sendMessage")
      }.isEmpty,
      "blank question must not post — let the safety net handle COMPLETED")
    XCTAssertFalse(
      DatabaseManager.hasReplied(taskId: "task-clarify-empty"),
      "no post means no markReplied; safety net must still fire on COMPLETED")

    // And the subsequent COMPLETED's safety net should still surface the
    // agent's real prose, exactly as before.
    handleTaskEvent(
      state: state, agentId: agentId,
      taskId: "task-clarify-empty", eventType: 4,
      eventJSON: #"{"output":"Final answer.","success":true}"#)
    XCTAssertEqual(sentMessageText(), "Final answer.")
  }

  // MARK: pure clarification-text rendering

  func testClarificationMessageTextReturnsNilOnMissingQuestion() {
    XCTAssertNil(clarificationMessageText(eventJSON: "{}"))
    XCTAssertNil(clarificationMessageText(eventJSON: #"{"question":""}"#))
    XCTAssertNil(clarificationMessageText(eventJSON: #"{"question":"   \n  "}"#))
    XCTAssertNil(clarificationMessageText(eventJSON: "not json"))
  }

  func testClarificationMessageTextIgnoresBlankOptions() {
    let json = #"{"question":"Pick one","options":["A","","   ","B"]}"#
    XCTAssertEqual(
      clarificationMessageText(eventJSON: json),
      "Pick one\n\n1. A\n2. B",
      "blank/whitespace options are filtered BEFORE numbering, so the numbers stay 1-based")
  }

  func testClarificationMessageTextClampsTo4000Chars() {
    let long = String(repeating: "x", count: 5_000)
    let payload = ["question": long]
    let json = String(
      data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
    XCTAssertEqual(clarificationMessageText(eventJSON: json)?.count, 4_000)
  }
}
