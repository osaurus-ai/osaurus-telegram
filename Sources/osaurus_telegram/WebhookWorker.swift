import Foundation

// MARK: - Background webhook worker (Wave 2 async drain)
//
// Wave 1 processed updates synchronously on the webhook request path,
// bounded at ~30s of media download plus dispatch. Wave 2 moves to
// claim-then-async-drain:
//
//   1. request path: verify secret, parse, atomically claim the update
//      into the inbox WITH the raw payload persisted in the same
//      statement (durable-first), respond 200 immediately;
//   2. a background worker owned by the per-agent state — serialized per
//      chat, following the PerChatSendActor keyed-serialization pattern —
//      performs media download + dispatch and marks the claim
//      completed / leaves it incomplete on transient failure;
//   3. startup and every incoming webhook trigger reconciliation: stale
//      incomplete claims (lease expired = crashed or failed worker) are
//      atomically re-claimed and reprocessed from the stored payload.
//
// Invariants:
//   * durable-first — the 200 only goes out after the claim+payload row
//     is durable (claim INSERT is atomic; `.claimed` implies persisted);
//   * at-least-once — a transient worker failure leaves the claim
//     incomplete; the lease expires and reconciliation reprocesses it;
//   * no double-processing — Telegram retries while a claim is in-lease
//     get 200 without enqueueing (the payload is already durably queued);
//     reconciliation re-claims through the same atomic lease-takeover
//     statement, so a concurrent redelivery and a reconciliation pass
//     can never both win the same update.

/// Per-agent work queue: one serial lane per chat (ordering per chat, the
/// same keying the PerChatSendActor uses for outbound sends) plus a
/// control lane for reconciliation and health refresh. Uses real
/// DispatchQueues rather than Swift-concurrency tasks because the work is
/// blocking (bounded media downloads, synchronous host HTTP callbacks)
/// and must not starve the cooperative pool.
final class WebhookWorkQueue: @unchecked Sendable {

  /// Test hook: when true, enqueued work runs inline on the caller's
  /// thread. This keeps the production code path identical (claim →
  /// enqueue → process → complete) while letting the existing synchronous
  /// test suites assert right after `handleRoute` returns. Async-drain
  /// regression tests flip this off and use `waitUntilIdle`.
  nonisolated(unsafe) static var executeInlineForTesting = false

  private let lock = NSLock()
  private var chatLanes: [Int64: DispatchQueue] = [:]
  private let controlLane: DispatchQueue
  private let group = DispatchGroup()
  private let label: String

  init(label: String = "osaurus.telegram.webhook-worker") {
    self.label = label
    self.controlLane = DispatchQueue(label: "\(label).control")
  }

  /// Enqueues `work` on the serial lane for `chatId`. Work for the same
  /// chat runs in FIFO order; different chats run in parallel.
  func enqueue(chatId: Int64, _ work: @escaping @Sendable () -> Void) {
    if Self.executeInlineForTesting {
      work()
      return
    }
    let lane = lock.withLock { () -> DispatchQueue in
      if let existing = chatLanes[chatId] { return existing }
      let fresh = DispatchQueue(label: "\(label).chat-\(chatId)")
      chatLanes[chatId] = fresh
      return fresh
    }
    group.enter()
    lane.async { [group] in
      defer { group.leave() }
      work()
    }
  }

  /// Enqueues housekeeping (reconciliation, health refresh) off every
  /// chat lane so a slow chat can't delay recovery of the others.
  func enqueueControl(_ work: @escaping @Sendable () -> Void) {
    if Self.executeInlineForTesting {
      work()
      return
    }
    group.enter()
    controlLane.async { [group] in
      defer { group.leave() }
      work()
    }
  }

  /// Blocks until every enqueued unit of work (across all lanes) has
  /// finished, or the timeout passes. Test-only synchronization point.
  @discardableResult
  func waitUntilIdle(timeout: TimeInterval = 15) -> Bool {
    group.wait(timeout: .now() + timeout) == .success
  }
}

// MARK: - Claimed-update processing (runs on the worker)

/// Drains one claimed update from its stored payload. Runs on the
/// per-chat worker lane. The caller must already OWN the claim (either
/// the webhook handler that just inserted it, or reconciliation after an
/// atomic lease takeover).
///
/// Completion contract: deterministic outcomes (dispatched, deliberately
/// dropped) complete the claim; transient failures record the error and
/// leave the claim incomplete so reconciliation reprocesses it after the
/// lease expires.
func processClaimedUpdate(
  state: AgentState, agentId: String, updateId: Int, body: String
) {
  guard let update = parseJSON(body, as: TGUpdate.self) else {
    // Can't happen for rows enqueued by the webhook handler (it parsed
    // the body before claiming) but a corrupt stored payload must not
    // wedge reconciliation forever.
    logWarn("worker: stored payload for update_id=\(updateId) does not parse; completing")
    DatabaseManager.completeUpdate(agentId: agentId, updateId: updateId)
    return
  }

  // Inline TTL housekeeping, moved off the webhook hot path in Wave 2.
  DatabaseManager.pruneOldSeenUpdates()
  DatabaseManager.sweepExpiredDispatches()

  let outcome: ProcessOutcome
  if let cb = update.callback_query {
    outcome = processCallbackQuery(state: state, agentId: agentId, cb: cb)
  } else if let message = update.message {
    outcome = processMessageUpdate(state: state, agentId: agentId, message: message)
  } else {
    outcome = .completed
  }

  switch outcome {
  case .completed:
    DatabaseManager.completeUpdate(agentId: agentId, updateId: updateId)
  case .transientFailure(let description):
    // Leave the claim incomplete: the lease expires in
    // `updateClaimLeaseSeconds` and reconciliation reprocesses the
    // stored payload. Deleting it (the wave-1 release) would depend on
    // Telegram redelivering an update we already acked with 200.
    state.recordDeliveryError("update \(updateId): \(description)")
    logWarn(
      "worker: transient failure for update_id=\(updateId) (\(description)); "
        + "claim left for reconciliation after lease expiry")
  }
}

// MARK: - Reconciliation

/// Schedules a reconciliation pass on the control lane. Called from
/// startup (agent hydration) and from every incoming webhook, so stalled
/// claims recover as long as the agent sees any traffic — no timer loop.
func triggerReconciliation(state: AgentState, agentId: String) {
  // Reconciliation passes double as health checkpoints: piggy-back the
  // throttled getWebhookInfo probe so startup recovery also re-verifies
  // the registration.
  maybeScheduleWebhookHealthRefresh(state: state)
  state.webhookWorker.enqueueControl {
    reconcileStaleClaims(state: state, agentId: agentId)
  }
}

/// Re-drives stale incomplete claims (lease expired, payload available).
/// The re-claim happens INSIDE the target chat's lane through the same
/// atomic lease-takeover statement the webhook path uses, so a concurrent
/// Telegram redelivery and this pass can never both process the update.
func reconcileStaleClaims(state: AgentState, agentId: String) {
  let stale = DatabaseManager.staleIncompleteUpdates(agentId: agentId)
  guard !stale.isEmpty else { return }
  logInfo("reconcile: \(stale.count) stale claim(s) eligible for reprocessing")

  for row in stale {
    guard let update = parseJSON(row.payload, as: TGUpdate.self) else {
      logWarn("reconcile: unparseable payload for update_id=\(row.updateId); completing")
      DatabaseManager.completeUpdate(agentId: agentId, updateId: row.updateId)
      continue
    }
    let chatId =
      update.message?.chat.id
      ?? update.callback_query?.message?.chat.id
      ?? 0
    state.webhookWorker.enqueue(chatId: chatId) {
      // Atomic takeover: only proceeds if the claim is STILL stale at
      // execution time (a concurrent redelivery may have re-claimed and
      // processed it while this closure sat in the lane).
      guard
        DatabaseManager.claimUpdate(agentId: agentId, updateId: row.updateId) == .claimed
      else { return }
      processClaimedUpdate(
        state: state, agentId: agentId, updateId: row.updateId, body: row.payload)
    }
  }
}

// MARK: - Webhook health monitoring

/// Config keys surfacing webhook health in the existing config surface
/// (next to `webhook_registered`, which keeps driving the UI indicator).
let webhookLastVerifiedAtKey = "webhook_last_verified_at"
let webhookLastErrorKey = "webhook_last_error"

/// Minimum interval between opportunistic `getWebhookInfo` re-queries.
/// Checked on webhook traffic and reconciliation passes — no timer loop.
/// Overridable in tests.
nonisolated(unsafe) var webhookHealthRefreshIntervalSeconds = 15 * 60

/// Schedules a background `getWebhookInfo` health probe if one hasn't run
/// in the last `webhookHealthRefreshIntervalSeconds`. Requires both the
/// bot token and the tunnel URL (without them there is no registration to
/// verify). The probe runs on the control lane so the webhook hot path
/// never waits on Telegram.
func maybeScheduleWebhookHealthRefresh(state: AgentState) {
  guard let token = state.botToken, !token.isEmpty,
    let tunnelURL = state.tunnelURL, !tunnelURL.isEmpty
  else { return }
  let now = Int(Date().timeIntervalSince1970)
  guard state.claimHealthRefreshSlot(now: now, interval: webhookHealthRefreshIntervalSeconds)
  else { return }

  let expectedURL = makeWebhookURL(tunnelURL: tunnelURL)
  state.webhookWorker.enqueueControl {
    refreshWebhookHealth(state: state, token: token, expectedURL: expectedURL)
  }
}

/// One `getWebhookInfo` round-trip: records `last_verified_at` when
/// Telegram confirms our URL with no recent delivery error, records the
/// delivery error otherwise. Results land in AgentState and are persisted
/// to config by the next in-frame callback (config is agent-scoped via
/// host TLS, so the worker thread itself must not write it).
func refreshWebhookHealth(state: AgentState, token: String, expectedURL: String) {
  guard let info = telegramGetWebhookInfo(token: token) else {
    state.recordDeliveryError("health: getWebhookInfo failed")
    return
  }
  if info.url != expectedURL {
    state.recordDeliveryError(
      "health: telegram has url=\"\(info.url)\", expected \"\(expectedURL)\"")
    return
  }
  if info.hasRecentError() {
    state.recordDeliveryError("health: telegram delivery error: \(info.lastErrorMessage)")
    return
  }
  state.recordWebhookVerified(at: Int(Date().timeIntervalSince1970))
  logDebug("health: webhook verified via getWebhookInfo")
}

/// Persists any pending health snapshot to the agent-scoped config keys.
/// MUST be called from inside a per-agent host frame (webhook handler,
/// config-change hook) — never from a worker thread, where config writes
/// would land on the host's default-agent fallback.
func persistPendingWebhookHealth(state: AgentState) {
  guard let snapshot = state.takeHealthSnapshotIfDirty() else { return }
  if let verifiedAt = snapshot.lastVerifiedAt {
    configSet(webhookLastVerifiedAtKey, String(verifiedAt))
  }
  if let error = snapshot.lastDeliveryError {
    configSet(webhookLastErrorKey, error)
  } else {
    configDelete(webhookLastErrorKey)
  }
}
