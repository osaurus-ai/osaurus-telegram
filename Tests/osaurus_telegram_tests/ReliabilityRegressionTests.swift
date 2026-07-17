import XCTest

@testable import osaurus_telegram

/// Regression coverage for the reliability audit fixes:
///   * claim-then-complete update inbox (no more mark-seen-before-processing),
///   * retryable 503 on transient dispatch failure so Telegram redelivers,
///   * atomic claim under concurrency (exactly one winner),
///   * stale-claim takeover after the lease expires,
///   * method / content-type / body-size validation on the webhook route,
///   * 429 retry_after surfaced in reply-tool failure envelopes,
///   * bounded in-place retry for reply_typing (the only duplicate-safe tool),
///   * explicit attachment failure state in the dispatch prompt.
final class ReliabilityRegressionTests: XCTestCase {

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

  private func route(_ requestJSON: String) -> (status: Int, body: String) {
    parseRouteResponse(
      handleRoute(state: state, agentId: agentId, requestJSON: requestJSON))
  }

  // MARK: - Claim-then-complete (Wave 2: claim-then-async-drain)

  func testTransientDispatchFailureLeavesClaimResumableAndReconciliationReprocesses() {
    // First delivery: the host's dispatch returns garbage (host mid-crash
    // / unavailable). Wave 2 contract: the webhook already answered 200
    // after the durable enqueue; the worker's failure must leave the
    // claim INCOMPLETE (with the payload intact) so reconciliation can
    // reprocess it after the lease expires.
    TestHostGlobals.nextDispatchResponse = "not-json"
    let update = textUpdate(updateId: 7_001, chatId: 71, text: "hello")
    let first = route(webhookRequest(secret: secret, update: update))
    XCTAssertEqual(
      first.status, 200,
      "the update was durably enqueued; the 200 must not depend on processing")
    XCTAssertEqual(TestHostGlobals.dispatchCalls.count, 1)

    // Redelivery while the failed claim is still inside its lease: acked
    // without re-processing (the payload is already durably queued).
    let inLease = route(webhookRequest(secret: secret, update: update))
    XCTAssertEqual(inLease.status, 200)
    XCTAssertEqual(
      TestHostGlobals.dispatchCalls.count, 1,
      "an in-lease retry must not double-process")

    // Age the claim past the lease (as if the worker crashed) and let a
    // redelivery take it over: dispatch works now, so the turn goes
    // through and the claim completes.
    let stale = Int(Date().timeIntervalSince1970)
      - DatabaseManager.updateClaimLeaseSeconds - 10
    _ = DatabaseManager.dbExec(
      "UPDATE seen_updates SET seen_at = ?1 WHERE agent_id = ?2 AND update_id = ?3",
      params: "[\(stale),\"\(agentId)\",7001]")
    TestHostGlobals.nextDispatchResponse = #"{"id":"task-retry","status":"running"}"#
    let second = route(webhookRequest(secret: secret, update: update))
    XCTAssertEqual(second.status, 200)
    XCTAssertEqual(
      TestHostGlobals.dispatchCalls.count, 2,
      "lease takeover must re-process the update")

    // Third delivery is a true duplicate of a COMPLETED update.
    let third = route(webhookRequest(secret: secret, update: update))
    XCTAssertEqual(third.status, 200)
    XCTAssertEqual(
      TestHostGlobals.dispatchCalls.count, 2,
      "a completed update must never be re-dispatched")
  }

  func testInFlightClaimAcksWithoutProcessing() {
    // Simulate another delivery of the same update still being processed
    // by the worker. Wave 2 contract: the retry is acked 200 (payload is
    // durably enqueued) but MUST NOT enqueue/process a second time.
    XCTAssertEqual(
      DatabaseManager.claimUpdate(
        agentId: agentId, updateId: 7_002, payload: #"{"update_id":7002}"#),
      .claimed)

    let update = textUpdate(updateId: 7_002, chatId: 72, text: "dup")
    let result = route(webhookRequest(secret: secret, update: update))
    XCTAssertEqual(
      result.status, 200,
      "an in-lease claim is already durably enqueued; ack without double-processing")
    XCTAssertTrue(TestHostGlobals.dispatchCalls.isEmpty)
  }

  func testStaleClaimIsTakenOverByRedelivery() {
    XCTAssertEqual(
      DatabaseManager.claimUpdate(agentId: agentId, updateId: 7_003), .claimed)

    // Age the claim past the lease (crash/hang scenario).
    let stale = Int(Date().timeIntervalSince1970)
      - DatabaseManager.updateClaimLeaseSeconds - 10
    DatabaseManager.dbExec(
      "UPDATE seen_updates SET seen_at = ?1 WHERE agent_id = ?2 AND update_id = ?3",
      params: "[\(stale),\"\(agentId)\",7003]")

    XCTAssertEqual(
      DatabaseManager.claimUpdate(agentId: agentId, updateId: 7_003), .claimed,
      "an expired incomplete claim must be re-claimable by a redelivery")
  }

  func testConcurrentClaimsGrantExactlyOneWinner() {
    let winners = LockedCounter()
    let agent = agentId
    DispatchQueue.concurrentPerform(iterations: 16) { _ in
      if DatabaseManager.claimUpdate(agentId: agent, updateId: 7_004) == .claimed {
        winners.increment()
      }
    }
    XCTAssertEqual(
      winners.value, 1,
      "exactly one concurrent delivery of an update may win the claim")
  }

  func testDeterministicDropCompletesClaim() {
    // Allowlist rejection is deterministic: retrying can never change the
    // outcome, so the claim must be completed (200 + no reprocessing).
    state.allowedUsers = parseAllowedUsers("999999")
    let update = textUpdate(updateId: 7_005, chatId: 75, text: "hi", fromId: 42)
    let result = route(webhookRequest(secret: secret, update: update))
    XCTAssertEqual(result.status, 200)
    XCTAssertTrue(TestHostGlobals.dispatchCalls.isEmpty)

    XCTAssertEqual(
      DatabaseManager.claimUpdate(agentId: agentId, updateId: 7_005),
      .alreadyCompleted,
      "a deterministic drop must complete the claim so retries are skipped")
  }

  func testDispatchSuccessCompletesClaim() {
    let update = textUpdate(updateId: 7_006, chatId: 76, text: "hello")
    XCTAssertEqual(route(webhookRequest(secret: secret, update: update)).status, 200)
    XCTAssertEqual(TestHostGlobals.dispatchCalls.count, 1)
    XCTAssertEqual(
      DatabaseManager.claimUpdate(agentId: agentId, updateId: 7_006),
      .alreadyCompleted)
  }

  func testCallbackQueryUsesClaimSemantics() {
    let update: [String: Any] = [
      "update_id": 7_007,
      "callback_query": [
        "id": "cb-1",
        "from": ["id": 999, "username": "alice"] as [String: Any],
        "data": "opt-a",
        "message": [
          "message_id": 3,
          "chat": ["id": 77],
        ] as [String: Any],
      ] as [String: Any],
    ]
    XCTAssertEqual(route(webhookRequest(secret: secret, update: update)).status, 200)
    XCTAssertEqual(TestHostGlobals.dispatchCalls.count, 1)

    // Duplicate delivery of the same callback update: skipped.
    XCTAssertEqual(route(webhookRequest(secret: secret, update: update)).status, 200)
    XCTAssertEqual(TestHostGlobals.dispatchCalls.count, 1)
  }

  // MARK: - Route validation

  func testWebhookRejectsNonPOSTMethods() {
    let update = textUpdate(updateId: 7_100, chatId: 80, text: "hi")
    for method in ["GET", "PUT", "DELETE", "PATCH"] {
      let result = route(webhookRequest(secret: secret, update: update, method: method))
      XCTAssertEqual(result.status, 405, "\(method) must be rejected with 405")
    }
    XCTAssertTrue(TestHostGlobals.dispatchCalls.isEmpty)
  }

  func testWebhookRejectsNonJSONContentType() {
    let update = textUpdate(updateId: 7_101, chatId: 81, text: "hi")
    let result = route(
      webhookRequest(secret: secret, update: update, contentType: "text/plain"))
    XCTAssertEqual(result.status, 415)
    XCTAssertTrue(TestHostGlobals.dispatchCalls.isEmpty)
  }

  func testWebhookAcceptsJSONContentTypeWithCharset() {
    let update = textUpdate(updateId: 7_102, chatId: 82, text: "hi")
    let result = route(
      webhookRequest(
        secret: secret, update: update,
        contentType: "application/json; charset=utf-8"))
    XCTAssertEqual(result.status, 200)
    XCTAssertEqual(TestHostGlobals.dispatchCalls.count, 1)
  }

  func testWebhookRejectsOversizedBody() {
    // Real Telegram updates are a few KB; anything over the cap is
    // hostile or corrupt and must be refused before parsing.
    let huge = String(repeating: "a", count: maxRouteBodyBytes + 1)
    let update = textUpdate(updateId: 7_103, chatId: 83, text: huge)
    let result = route(webhookRequest(secret: secret, update: update))
    XCTAssertEqual(result.status, 413)
    XCTAssertTrue(TestHostGlobals.dispatchCalls.isEmpty)
  }

  // MARK: - 429 retry_after in reply-tool envelopes

  private func makeBinding(chatId: Int64 = 100, taskId: String = "task-1") -> String {
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: chatId)
    let token = "TOKRETRY"
    DatabaseManager.insertActiveDispatch(
      taskId: taskId, agentId: agentId, chatId: chatId, replyToken: token,
      sessionId: "session-1",
      expiresAt: Int(Date().timeIntervalSince1970) + 600,
      incomingMessageId: 0)
    return token
  }

  func testReplyFailureSurfacesRetryAfterInEnvelopeData() throws {
    let token = makeBinding()
    TestHostGlobals.nextHttpResponse =
      #"{"status":429,"body":"{\"ok\":false,\"description\":\"Too Many Requests: retry after 7\",\"parameters\":{\"retry_after\":7}}"}"#

    let envelope = handleReply(
      state: state, payload: #"{"reply_token":"\#(token)","text":"hi"}"#)
    let parsed = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any])
    XCTAssertEqual(parsed["ok"] as? Bool, false)
    XCTAssertEqual(parsed["retryable"] as? Bool, true)
    let data = try XCTUnwrap(
      parsed["data"] as? [String: Any],
      "429 failures must carry machine-readable retry_after; got: \(envelope)")
    XCTAssertEqual(data["retry_after"] as? Int, 7)
  }

  func testReplyFailureWithoutRetryAfterOmitsData() throws {
    let token = makeBinding()
    TestHostGlobals.nextHttpResponse =
      #"{"status":400,"body":"{\"ok\":false,\"description\":\"Bad Request: chat not found\"}"}"#

    let envelope = handleReply(
      state: state, payload: #"{"reply_token":"\#(token)","text":"hi"}"#)
    let parsed = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any])
    XCTAssertEqual(parsed["ok"] as? Bool, false)
    XCTAssertNil(parsed["data"])
  }

  // MARK: - reply_typing bounded retry (duplicate-safe surface only)

  func testReplyTypingRetriesOnceAfter429() throws {
    let token = makeBinding()
    TestHostGlobals.httpResponseQueueByMethod["sendChatAction"] = [
      #"{"status":429,"body":"{\"ok\":false,\"description\":\"Too Many Requests: retry after 1\",\"parameters\":{\"retry_after\":1}}"}"#,
      #"{"status":200,"body":"{\"ok\":true,\"result\":true}"}"#,
    ]

    let envelope = handleReplyTyping(
      state: state, payload: #"{"reply_token":"\#(token)"}"#)
    let parsed = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any])
    XCTAssertEqual(
      parsed["ok"] as? Bool, true,
      "typing indicator should succeed via the bounded in-place retry")

    let typingCalls = TestHostGlobals.httpCalls.filter {
      ($0["url"] as? String)?.hasSuffix("/sendChatAction") == true
    }
    XCTAssertEqual(typingCalls.count, 2, "exactly one retry after the 429")
  }

  func testReplyTypingDoesNotRetryWithoutRetryAfter() throws {
    let token = makeBinding()
    TestHostGlobals.nextHttpResponse =
      #"{"status":400,"body":"{\"ok\":false,\"description\":\"Bad Request\"}"}"#

    let envelope = handleReplyTyping(
      state: state, payload: #"{"reply_token":"\#(token)"}"#)
    let parsed = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any])
    XCTAssertEqual(parsed["ok"] as? Bool, false)

    let typingCalls = TestHostGlobals.httpCalls.filter {
      ($0["url"] as? String)?.hasSuffix("/sendChatAction") == true
    }
    XCTAssertEqual(typingCalls.count, 1, "non-429 failures must not be retried")
  }

  /// Content-bearing reply must NOT be retried in place even on 429 —
  /// an ambiguous failure (send landed but response was lost) would
  /// double-post the message. The envelope carries retry_after instead.
  func testReplyDoesNotAutoRetryOn429() throws {
    let token = makeBinding()
    TestHostGlobals.nextHttpResponse =
      #"{"status":429,"body":"{\"ok\":false,\"description\":\"Too Many Requests: retry after 3\",\"parameters\":{\"retry_after\":3}}"}"#

    _ = handleReply(state: state, payload: #"{"reply_token":"\#(token)","text":"hi"}"#)

    let sendCalls = TestHostGlobals.httpCalls.filter {
      ($0["url"] as? String)?.hasSuffix("/sendMessage") == true
    }
    XCTAssertEqual(
      sendCalls.count, 1,
      "content-bearing sends must never auto-retry (duplicate risk)")
  }

  // MARK: - Inbound media: explicit failure state

  func testFailedMediaDownloadIsSurfacedInPrompt() throws {
    // getFile fails (default stubbed response carries no file_path), so
    // the attachment can't be resolved. The dispatch must still happen
    // AND the prompt must tell the agent an attachment was lost.
    let update: [String: Any] = [
      "update_id": 7_200,
      "message": [
        "message_id": 9,
        "chat": ["id": 90],
        "from": ["id": 999, "username": "alice"] as [String: Any],
        "photo": [
          ["file_id": "p1", "file_unique_id": "u1", "width": 800, "height": 600]
            as [String: Any]
        ],
        "caption": "what is this?",
      ] as [String: Any],
    ]
    XCTAssertEqual(route(webhookRequest(secret: secret, update: update)).status, 200)

    XCTAssertEqual(TestHostGlobals.dispatchCalls.count, 1)
    let prompt = try XCTUnwrap(TestHostGlobals.dispatchCalls[0]["prompt"] as? String)
    XCTAssertTrue(
      prompt.contains("[attachment_errors"),
      "lost attachments must be explicit in the prompt; got: \(prompt)")
    XCTAssertTrue(prompt.contains("photo"))
  }

  func testOversizedMediaIsSkippedWithExplicitReason() throws {
    // getFile resolves, but the file exceeds the per-file cap.
    let oversize = (20 * 1024 * 1024) + 1
    TestHostGlobals.httpResponseByMethod["getFile"] =
      #"{"status":200,"body":"{\"ok\":true,\"result\":{\"file_path\":\"documents/big.bin\",\"file_size\":\#(oversize)}}"}"#

    let update: [String: Any] = [
      "update_id": 7_201,
      "message": [
        "message_id": 10,
        "chat": ["id": 91],
        "from": ["id": 999, "username": "alice"] as [String: Any],
        "document": [
          "file_id": "big", "file_name": "big.bin",
          "mime_type": "application/octet-stream",
        ] as [String: Any],
        "caption": "here you go",
      ] as [String: Any],
    ]
    XCTAssertEqual(route(webhookRequest(secret: secret, update: update)).status, 200)

    let prompt = try XCTUnwrap(TestHostGlobals.dispatchCalls[0]["prompt"] as? String)
    XCTAssertTrue(
      prompt.contains("[attachment_errors"),
      "oversized attachments must surface an explicit skip; got: \(prompt)")
    XCTAssertTrue(prompt.contains("exceeds"))
    // The oversized file must never be fetched.
    let downloads = TestHostGlobals.httpCalls.filter {
      ($0["url"] as? String)?.contains("/file/bot") == true
    }
    XCTAssertTrue(downloads.isEmpty, "the byte download must be skipped entirely")
  }
}

// MARK: - Tiny lock-based counter for the concurrency test

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  func increment() {
    lock.lock()
    storage += 1
    lock.unlock()
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}
