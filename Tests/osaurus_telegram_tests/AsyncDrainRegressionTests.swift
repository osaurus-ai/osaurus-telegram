import XCTest

@testable import osaurus_telegram

/// Wave 2 regression coverage for the claim-then-async-drain conversion:
///   * durable-first: the payload is persisted atomically with the claim
///     BEFORE the 200 goes out, and a store failure yields 503,
///   * enqueue-then-drain ordering: the webhook answers 200 before the
///     worker processes; per-chat lanes drain FIFO,
///   * worker crash simulation: an incomplete claim whose lease expired is
///     reprocessed from the stored payload by reconciliation,
///   * no double-dispatch under concurrent webhook redelivery +
///     reconciliation racing for the same stale claim.
///
/// Unlike the synchronous suites, these tests run the worker for real
/// (`executeInlineForTesting = false`) and synchronize via
/// `state.webhookWorker.waitUntilIdle()`.
final class AsyncDrainRegressionTests: XCTestCase {

  private var state: AgentState!
  private let agentId = defaultTestAgentId
  private let secret = "drain-secret"

  override func setUp() {
    super.setUp()
    TestHost.install()
    WebhookWorkQueue.executeInlineForTesting = false
    DatabaseManager.initSchema()
    state = AgentState(agentId: agentId)
    state.botToken = "123:fake"
    state.webhookSecret = secret
  }

  override func tearDown() {
    XCTAssertTrue(
      state.webhookWorker.waitUntilIdle(),
      "worker lanes must drain before teardown")
    state = nil
    WebhookWorkQueue.executeInlineForTesting = true
    TestHost.uninstall()
    super.tearDown()
  }

  private func route(_ requestJSON: String) -> (status: Int, body: String) {
    parseRouteResponse(
      handleRoute(state: state, agentId: agentId, requestJSON: requestJSON))
  }

  private func ageClaim(updateId: Int, extraSeconds: Int = 10) {
    let stale = Int(Date().timeIntervalSince1970)
      - DatabaseManager.updateClaimLeaseSeconds - extraSeconds
    _ = DatabaseManager.dbExec(
      "UPDATE seen_updates SET seen_at = ?1 WHERE agent_id = ?2 AND update_id = ?3",
      params: "[\(stale),\"\(agentId)\",\(updateId)]")
  }

  // MARK: - Durable-first

  func testPayloadIsDurableBeforeTheWorkerRuns() {
    // Freeze the chat lane so the enqueue happens but the drain can't:
    // whatever is on disk after `handleRoute` returns is exactly what a
    // crash immediately after the 200 would leave behind.
    let gate = DispatchSemaphore(value: 0)
    state.webhookWorker.enqueue(chatId: 61) { gate.wait() }

    let update = textUpdate(updateId: 8_001, chatId: 61, text: "durable?")
    let result = route(webhookRequest(secret: secret, update: update))
    XCTAssertEqual(result.status, 200)
    XCTAssertTrue(
      TestHostGlobals.dispatchCalls.isEmpty,
      "the worker is gated; nothing may have processed yet")

    // The claim row must already carry the raw payload.
    ageClaim(updateId: 8_001)
    let stale = DatabaseManager.staleIncompleteUpdates(agentId: agentId)
    XCTAssertEqual(stale.map(\.updateId), [8_001])
    XCTAssertTrue(
      stale[0].payload.contains("\"update_id\""),
      "the raw update JSON must be persisted with the claim")

    gate.signal()
  }

  func testStoreUnavailableYields503NotAck() {
    // Both the claim INSERT and the fallback probe fail: durable-first
    // forbids acking, so Telegram's retry stays the recovery path.
    TestHostGlobals.failDbExec = true
    TestHostGlobals.failDbQuery = true
    defer {
      TestHostGlobals.failDbExec = false
      TestHostGlobals.failDbQuery = false
    }

    let update = textUpdate(updateId: 8_002, chatId: 62, text: "hi")
    let result = route(webhookRequest(secret: secret, update: update))
    XCTAssertEqual(
      result.status, 503,
      "an update that could not be durably enqueued must not be acked")
    XCTAssertTrue(TestHostGlobals.dispatchCalls.isEmpty)
  }

  // MARK: - Enqueue-then-drain ordering

  func testWebhookAcksBeforeWorkerProcessesAndDrainCompletes() {
    let gate = DispatchSemaphore(value: 0)
    state.webhookWorker.enqueue(chatId: 63) { gate.wait() }

    let update = textUpdate(updateId: 8_003, chatId: 63, text: "queued")
    XCTAssertEqual(route(webhookRequest(secret: secret, update: update)).status, 200)
    XCTAssertTrue(
      TestHostGlobals.dispatchCalls.isEmpty,
      "200 must be returned before processing, not after")

    gate.signal()
    XCTAssertTrue(state.webhookWorker.waitUntilIdle())
    XCTAssertEqual(TestHostGlobals.dispatchCalls.count, 1)
    XCTAssertEqual(
      DatabaseManager.claimUpdate(agentId: agentId, updateId: 8_003),
      .alreadyCompleted, "the drained claim must be marked completed")
  }

  func testSameChatUpdatesDrainInFIFOOrder() throws {
    let gate = DispatchSemaphore(value: 0)
    state.webhookWorker.enqueue(chatId: 64) { gate.wait() }

    for (i, text) in ["first", "second", "third"].enumerated() {
      let update = textUpdate(updateId: 8_010 + i, chatId: 64, text: text)
      XCTAssertEqual(route(webhookRequest(secret: secret, update: update)).status, 200)
    }
    gate.signal()
    XCTAssertTrue(state.webhookWorker.waitUntilIdle())

    XCTAssertEqual(TestHostGlobals.dispatchCalls.count, 3)
    let prompts = TestHostGlobals.dispatchCalls.compactMap { $0["prompt"] as? String }
    let order = ["first", "second", "third"].map { word in
      try! XCTUnwrap(prompts.firstIndex { $0.contains(word) })
    }
    XCTAssertEqual(order, order.sorted(), "per-chat lane must preserve arrival order")
  }

  // MARK: - Worker crash simulation → reconciliation reprocesses

  func testReconciliationReprocessesExpiredIncompleteClaim() {
    // A claim with a stored payload whose worker "crashed": incomplete,
    // lease expired. Startup/webhook-triggered reconciliation must
    // re-claim it and reprocess from the stored payload.
    let body = makeJSONString(textUpdate(updateId: 8_020, chatId: 65, text: "lost turn"))!
    XCTAssertEqual(
      DatabaseManager.claimUpdate(agentId: agentId, updateId: 8_020, payload: body),
      .claimed)
    ageClaim(updateId: 8_020)

    triggerReconciliation(state: state, agentId: agentId)
    XCTAssertTrue(state.webhookWorker.waitUntilIdle())

    XCTAssertEqual(
      TestHostGlobals.dispatchCalls.count, 1,
      "reconciliation must reprocess the stored payload")
    XCTAssertEqual(
      DatabaseManager.claimUpdate(agentId: agentId, updateId: 8_020),
      .alreadyCompleted)
  }

  func testReconciliationSkipsInLeaseAndCompletedClaims() {
    // In-lease incomplete claim (a worker is presumably on it) and a
    // completed claim: neither is eligible for reprocessing.
    let bodyA = makeJSONString(textUpdate(updateId: 8_021, chatId: 66, text: "busy"))!
    XCTAssertEqual(
      DatabaseManager.claimUpdate(agentId: agentId, updateId: 8_021, payload: bodyA),
      .claimed)

    let bodyB = makeJSONString(textUpdate(updateId: 8_022, chatId: 66, text: "done"))!
    XCTAssertEqual(
      DatabaseManager.claimUpdate(agentId: agentId, updateId: 8_022, payload: bodyB),
      .claimed)
    DatabaseManager.completeUpdate(agentId: agentId, updateId: 8_022)

    triggerReconciliation(state: state, agentId: agentId)
    XCTAssertTrue(state.webhookWorker.waitUntilIdle())
    XCTAssertTrue(
      TestHostGlobals.dispatchCalls.isEmpty,
      "neither in-lease nor completed claims may be reprocessed")
  }

  // MARK: - No double-dispatch: concurrent webhook + reconciliation

  func testConcurrentRedeliveryAndReconciliationDispatchExactlyOnce() {
    // One stale incomplete claim; hammer it with 8 concurrent webhook
    // redeliveries racing 8 concurrent reconciliation passes. The atomic
    // lease takeover must grant exactly one processor.
    let body = makeJSONString(textUpdate(updateId: 8_030, chatId: 67, text: "race"))!
    XCTAssertEqual(
      DatabaseManager.claimUpdate(agentId: agentId, updateId: 8_030, payload: body),
      .claimed)
    ageClaim(updateId: 8_030)

    let request = webhookRequest(
      secret: secret, update: textUpdate(updateId: 8_030, chatId: 67, text: "race"))
    let racingState = state!
    let racingAgent = agentId
    DispatchQueue.concurrentPerform(iterations: 16) { i in
      if i % 2 == 0 {
        _ = handleRoute(state: racingState, agentId: racingAgent, requestJSON: request)
      } else {
        reconcileStaleClaims(state: racingState, agentId: racingAgent)
      }
    }
    XCTAssertTrue(state.webhookWorker.waitUntilIdle())

    XCTAssertEqual(
      TestHostGlobals.dispatchCalls.count, 1,
      "exactly one of the racing paths may win the stale claim")
    XCTAssertEqual(
      DatabaseManager.claimUpdate(agentId: agentId, updateId: 8_030),
      .alreadyCompleted)
  }

  // MARK: - Health monitoring

  func testWebhookVerificationRecordsLastVerifiedAt() {
    // Worker-side probe confirms the registration; the snapshot is
    // persisted by the next in-frame callback (here: directly).
    state.tunnelURL = "https://tunnel.example.com"
    state.recordWebhookVerified(at: 1_752_000_000)
    persistPendingWebhookHealth(state: state)

    XCTAssertEqual(
      TestHost.getConfig(agent: agentId, webhookLastVerifiedAtKey), "1752000000")
    XCTAssertNil(TestHost.getConfig(agent: agentId, webhookLastErrorKey))
  }

  func testDeliveryErrorIsSurfacedAndClearedOnNextVerification() {
    state.recordDeliveryError("update 42: dispatch failed")
    persistPendingWebhookHealth(state: state)
    XCTAssertEqual(
      TestHost.getConfig(agent: agentId, webhookLastErrorKey),
      "update 42: dispatch failed")

    state.recordWebhookVerified(at: 1_752_000_100)
    persistPendingWebhookHealth(state: state)
    XCTAssertNil(
      TestHost.getConfig(agent: agentId, webhookLastErrorKey),
      "a successful verification must clear the stored delivery error")
    XCTAssertEqual(
      TestHost.getConfig(agent: agentId, webhookLastVerifiedAtKey), "1752000100")
  }

  func testHealthRefreshIsThrottled() {
    // The opportunistic getWebhookInfo probe fires at most once per
    // interval regardless of how much webhook traffic arrives.
    let now = Int(Date().timeIntervalSince1970)
    XCTAssertTrue(state.claimHealthRefreshSlot(now: now, interval: 900))
    XCTAssertFalse(state.claimHealthRefreshSlot(now: now + 1, interval: 900))
    XCTAssertFalse(state.claimHealthRefreshSlot(now: now + 899, interval: 900))
    XCTAssertTrue(state.claimHealthRefreshSlot(now: now + 900, interval: 900))
  }

  func testTransientWorkerFailureRecordsDeliveryError() {
    WebhookWorkQueue.executeInlineForTesting = true
    TestHostGlobals.nextDispatchResponse = "not-json"
    let update = textUpdate(updateId: 8_040, chatId: 68, text: "will fail")
    XCTAssertEqual(route(webhookRequest(secret: secret, update: update)).status, 200)

    // The failure lands in the in-memory snapshot; the next in-frame
    // callback persists it.
    persistPendingWebhookHealth(state: state)
    let stored = TestHost.getConfig(agent: agentId, webhookLastErrorKey)
    XCTAssertNotNil(stored, "worker failures must be surfaced in webhook health")
    XCTAssertTrue(stored?.contains("8040") == true)
  }
}
