import Foundation

// MARK: - AgentState
//
// One per agent that loads this plugin. Holds the cached config values for
// that agent so we don't make a `config_get` round-trip on every callback.
// All persistent state still lives in the per-plugin SQLite DB; this class
// is purely the in-memory mirror.
//
// Lifetime: created lazily by `PluginContext.state(for:)` the first time we
// see a per-agent callback for a given agent_id. Freed only when the plugin
// itself is destroyed.
final class AgentState: @unchecked Sendable {
  let agentId: String
  var botToken: String?
  var botId: String?
  var botUsername: String?
  var webhookSecret: String?
  /// Public base URL of the agent's Osaurus tunnel. The host pushes this via
  /// `on_config_changed("tunnel_url", ...)` once the tunnel is up — there is
  /// no synchronous getter, so the plugin must wait for the push.
  var tunnelURL: String?

  /// Hydration is one-shot per-agent. The lock makes concurrent first-touches
  /// for the same agent_id wait for the inserter rather than racing against a
  /// half-populated state object. Per-agent (not registry-wide) so different
  /// agents can hydrate in parallel.
  private let hydrationLock = NSLock()
  private var didHydrate = false

  /// Per-agent set of `host_path`s that the plugin has already uploaded to
  /// Telegram for this agent. Idempotency for the artifact auto-forward
  /// hook: if the host fires `invoke(type: "artifact")` twice for the same
  /// `host_path` (e.g. file watcher re-fires), the second call short-
  /// circuits. Bounded by plugin process lifetime; in practice an agent
  /// only emits a handful of artifacts per session.
  private let artifactLock = NSLock()
  private var uploadedArtifactPaths: Set<String> = []

  /// Per-task cache of the agent's most recent streamed text output.
  /// Populated from `OUTPUT` task events (event type 7), which carry the
  /// agent's running prose throttled to 1/sec. Used as the safety-net
  /// source when COMPLETED arrives but the agent never called `reply` —
  /// preferred over COMPLETED's own `output` field because the host
  /// sometimes fires multiple COMPLETED events per task and the first one
  /// can carry interim text like `"No response needed."` that races the
  /// real answer.
  ///
  /// Cleared when `clearOutput(taskId:)` is called from the safety-net
  /// path after `markReplied`, so the cache doesn't grow unbounded.
  private let outputLock = NSLock()
  private var latestOutputByTask: [String: String] = [:]

  init(agentId: String) {
    self.agentId = agentId
  }

  /// Atomically inserts `path` into the per-agent uploaded set.
  /// Returns `true` if the path was already uploaded (caller should skip),
  /// `false` on first claim (caller should proceed with the upload).
  func claimArtifactUpload(_ path: String) -> Bool {
    artifactLock.lock()
    defer { artifactLock.unlock() }
    if uploadedArtifactPaths.contains(path) { return true }
    uploadedArtifactPaths.insert(path)
    return false
  }

  /// Stash the latest streamed text for `taskId`. Each call overwrites the
  /// previous entry — OUTPUT events carry cumulative content, so the most
  /// recent one is the most accurate snapshot of what the agent has said.
  /// No-op for empty strings to avoid blanking out a previously-good cache
  /// when the host fires a stray empty event.
  func recordOutput(taskId: String, text: String) {
    guard !text.isEmpty else { return }
    outputLock.lock()
    defer { outputLock.unlock() }
    latestOutputByTask[taskId] = text
  }

  /// Returns the most recently recorded streamed text for `taskId`, or nil
  /// if nothing was ever stashed.
  func latestOutput(taskId: String) -> String? {
    outputLock.lock()
    defer { outputLock.unlock() }
    return latestOutputByTask[taskId]
  }

  /// Drop the cached entry for `taskId`. Called from the safety-net path
  /// after `markReplied` so the cache mirrors the active-dispatch lifetime.
  func clearOutput(taskId: String) {
    outputLock.lock()
    defer { outputLock.unlock() }
    latestOutputByTask.removeValue(forKey: taskId)
  }

  /// Runs `body` exactly once across all callers. Subsequent calls are
  /// cheap (just a lock acquire). Hydration may do Keychain reads + a
  /// blocking Telegram round-trip, so callers should only invoke this from
  /// inside a per-agent host frame and outside any other lock.
  func hydrateOnce(_ body: () -> Void) {
    hydrationLock.lock()
    defer { hydrationLock.unlock() }
    if didHydrate { return }
    body()
    didHydrate = true
  }

  /// Convenience: prefixes log lines with the agent id so cross-agent logs
  /// stay legible in the Insights tab.
  func log(_ level: LogLevel, _ message: String) {
    let prefixed = "[\(agentId)] \(message)"
    switch level {
    case .debug: logDebug(prefixed)
    case .info: logInfo(prefixed)
    case .warn: logWarn(prefixed)
    case .error: logError(prefixed)
    }
  }
}

enum LogLevel { case debug, info, warn, error }

// MARK: - PluginContext (agent registry)
//
// The opaque pointer the host hands back to us on every callback. There is
// exactly one of these per plugin load, regardless of how many agents the
// host wires up to it. Its only job is to hand out per-agent `AgentState`
// instances.
final class PluginContext: @unchecked Sendable {
  private let lock = NSLock()
  private var states: [String: AgentState] = [:]

  /// Returns the cached `AgentState` for `agentId`, creating it on first
  /// encounter and triggering a one-shot hydration from `config_get`. MUST
  /// be called from inside a per-agent callback frame so config_get and
  /// config_set resolve to the right agent.
  func state(for agentId: String) -> AgentState {
    let state = lock.withLock {
      if let existing = states[agentId] { return existing }
      let fresh = AgentState(agentId: agentId)
      states[agentId] = fresh
      return fresh
    }
    // Hydrate outside the registry lock — Keychain reads and the optional
    // Telegram reconciliation are slow. AgentState's own lock makes this
    // race-free for the same agent.
    state.hydrateOnce { hydrate(state) }
    return state
  }

  /// Snapshot of every (agentId, state) pair. Used by `destroy` to tear down
  /// every agent's webhook even though we no longer have per-agent context.
  func allStates() -> [(String, AgentState)] {
    lock.withLock { states.map { ($0.key, $0.value) } }
  }

  private func hydrate(_ state: AgentState) {
    if let secret = configGet("webhook_secret"), !secret.isEmpty {
      state.webhookSecret = secret
      state.log(.debug, "webhook_secret loaded from config")
    } else {
      let secret = randomHexString(bytes: 32)
      configSet("webhook_secret", secret)
      state.webhookSecret = secret
      state.log(.info, "generated new webhook_secret")
    }

    if let token = configGet("bot_token"), !token.isEmpty {
      state.botToken = token
      state.log(.debug, "bot_token loaded from config (\(token.count) chars)")
    }

    if let url = configGet("tunnel_url"), !url.isEmpty {
      state.tunnelURL = url
      state.log(.debug, "tunnel_url loaded from config")
    }

    // If both halves are already on disk, reconcile with Telegram now so
    // the UI indicator is accurate by the time the user opens the plugin
    // pane. Otherwise log what we're still waiting on.
    if let token = state.botToken, let url = state.tunnelURL {
      setupWebhook(state: state, token: token, tunnelURL: url)
    } else {
      setWebhookRegistered(false)
      logWebhookWaitingState(state: state)
    }
  }
}

// MARK: - Webhook status flag
//
// `connected_when: "webhook_registered"` (declared in the manifest) drives
// the green/grey indicator next to the bot token field. We treat the flag
// as ground truth for the UI and only flip it to "true" after Telegram
// itself confirms (via getWebhookInfo) that our URL is registered with no
// recent delivery errors. Any state change that invalidates the previous
// registration clears it eagerly so the UI never shows stale-green.

private let webhookRegisteredKey = "webhook_registered"

private func setWebhookRegistered(_ on: Bool) {
  if on {
    configSet(webhookRegisteredKey, "true")
  } else {
    configDelete(webhookRegisteredKey)
  }
}

// MARK: - Lifecycle

func initPlugin(_ ctx: PluginContext) {
  logDebug("initPlugin: starting")
  DatabaseManager.initSchema()
  DatabaseManager.sweepExpiredDispatches()
  // No per-agent config_get here — there is no agent context at plugin-load
  // time. Each agent's state hydrates lazily on its first per-agent callback
  // (handle_route / on_config_changed / invoke / on_task_event), where TLS
  // is bound and config_get resolves to the right agent.
  logInfo("initPlugin: ready (per-agent state hydrates on first event)")
}

// MARK: - Webhook Setup

private func withRetry<T>(
  maxAttempts: Int = 3,
  initialDelay: TimeInterval = 1.0,
  operation: String,
  block: () -> T?
) -> T? {
  for attempt in 1...maxAttempts {
    if let result = block() { return result }
    if attempt < maxAttempts {
      let delay = initialDelay * pow(2.0, Double(attempt - 1))
      logWarn("\(operation) failed (attempt \(attempt)/\(maxAttempts)), retrying in \(delay)s")
      Thread.sleep(forTimeInterval: delay)
    }
  }
  logError("\(operation) failed after \(maxAttempts) attempts")
  return nil
}

func setupWebhook(state: AgentState, token: String, tunnelURL: String) {
  // Whatever was registered before is at best "unknown" until this attempt
  // lands — surface that in the UI immediately rather than letting the old
  // green linger across getMe + setWebhook + getWebhookInfo (~1-3s).
  setWebhookRegistered(false)

  state.log(.debug, "setupWebhook: calling getMe to validate token")
  guard let botInfo = withRetry(operation: "getMe", block: { telegramGetMe(token: token) }) else {
    state.log(.error, "Failed to validate bot token with getMe")
    return
  }

  state.botId = botInfo.botId
  state.botUsername = botInfo.username
  state.log(.info, "Telegram bot @\(botInfo.username) (id: \(botInfo.botId)) validated")

  guard let secret = state.webhookSecret, !secret.isEmpty else {
    state.log(.error, "setupWebhook: no webhook_secret available")
    return
  }

  let pluginId = "osaurus.telegram"
  let webhookURL =
    tunnelURL.trimmingCharacters(in: .init(charactersIn: "/"))
    + "/plugins/\(pluginId)/webhook"
  state.log(.debug, "setupWebhook: registering webhook at \(webhookURL)")

  let registered =
    withRetry(operation: "setWebhook") {
      telegramSetWebhook(token: token, url: webhookURL, secretToken: secret) ? true : nil
    } != nil
  guard registered else {
    state.log(.error, "Failed to register webhook at \(webhookURL)")
    return
  }

  // setWebhook only validates the request shape. Confirm with getWebhookInfo
  // that Telegram has the URL we expect AND isn't already failing to deliver
  // to it (e.g. our tunnel went down between requests).
  if verifyWebhook(token: token, expectedURL: webhookURL) {
    setWebhookRegistered(true)
    state.log(.info, "Webhook registered at \(webhookURL)")
  } else {
    // Don't trust the optimistic setWebhook response — the indicator stays
    // red so the user sees something is wrong.
    state.log(
      .error,
      "setWebhook accepted, but Telegram doesn't confirm \(webhookURL) "
        + "or is reporting a recent delivery error.")
  }
}

/// Asks Telegram what URL it has registered and whether delivery is healthy.
/// Returns true only if both checks pass.
@discardableResult
func verifyWebhook(token: String, expectedURL: String) -> Bool {
  guard let info = telegramGetWebhookInfo(token: token) else {
    logWarn("verifyWebhook: getWebhookInfo failed; assuming disconnected")
    return false
  }
  if info.url != expectedURL {
    logWarn(
      "verifyWebhook: Telegram has url=\"\(info.url)\" but we expected \"\(expectedURL)\"")
    return false
  }
  if info.hasRecentError() {
    logWarn(
      "verifyWebhook: Telegram reports recent delivery error: \(info.lastErrorMessage)")
    return false
  }
  if info.pendingUpdateCount > 0 {
    logDebug("verifyWebhook: \(info.pendingUpdateCount) pending updates queued")
  }
  return true
}

func onConfigChanged(state: AgentState, key: String, value: String?) {
  state.log(.debug, "onConfigChanged: key=\(key) hasValue=\(value != nil)")

  switch key {
  case "tunnel_url":
    handleTunnelURLChange(state: state, value: value)

  case "webhook_secret":
    if let v = value, !v.isEmpty {
      state.webhookSecret = v
      state.log(.debug, "onConfigChanged: webhook_secret refreshed")
    }

  case "bot_token":
    handleBotTokenChange(state: state, value: value)

  default:
    state.log(.debug, "onConfigChanged: ignoring key '\(key)'")
  }
}

private func handleTunnelURLChange(state: AgentState, value: String?) {
  let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)

  guard let newURL = trimmed, !newURL.isEmpty else {
    state.log(.debug, "onConfigChanged: tunnel_url cleared")
    state.tunnelURL = nil
    setWebhookRegistered(false)
    return
  }

  // No-op if the value is identical — avoids a pointless re-registration
  // and the brief red-flash that comes with it.
  if newURL == state.tunnelURL {
    state.log(.debug, "onConfigChanged: tunnel_url unchanged, skipping")
    return
  }

  state.tunnelURL = newURL
  // The previous registration (if any) is now stale; flip red until the new
  // setup completes.
  setWebhookRegistered(false)

  guard let token = state.botToken, !token.isEmpty else {
    state.log(.info, "Got tunnel_url; waiting for bot_token before registering webhook.")
    return
  }
  state.log(.debug, "tunnel_url + bot_token both available, registering webhook")
  setupWebhook(state: state, token: token, tunnelURL: newURL)
}

private func handleBotTokenChange(state: AgentState, value: String?) {
  let newToken = (value?.isEmpty == false) ? value : nil

  if newToken == state.botToken {
    state.log(.debug, "onConfigChanged: bot_token unchanged, skipping")
    return
  }

  // Eagerly flip red — whatever was registered with the old token (or with
  // the agent's previous bot) is no longer the source of truth.
  setWebhookRegistered(false)

  if let oldToken = state.botToken, !oldToken.isEmpty {
    state.log(.debug, "tearing down old webhook")
    _ = telegramDeleteWebhook(token: oldToken)
    state.log(.info, "Old webhook deleted")
  }

  state.botToken = nil
  state.botId = nil
  state.botUsername = nil

  guard let newToken else {
    state.log(.info, "Bot token cleared")
    return
  }

  state.botToken = newToken
  state.log(.debug, "bot_token stored (\(newToken.count) chars)")

  guard let tunnelURL = state.tunnelURL, !tunnelURL.isEmpty else {
    state.log(
      .info,
      "Saved bot_token; waiting for tunnel_url before registering webhook. "
        + "Osaurus will push it once the agent's tunnel is up.")
    return
  }
  setupWebhook(state: state, token: newToken, tunnelURL: tunnelURL)
}

/// Logs a single line summarising what's still missing for webhook setup, so
/// the user can quickly see why the bot isn't replying after install.
private func logWebhookWaitingState(state: AgentState) {
  var missing: [String] = []
  if state.botToken == nil { missing.append("bot_token (set in plugin Bot Configuration)") }
  if state.tunnelURL == nil { missing.append("tunnel_url (pushed by Osaurus when tunnel is up)") }
  if missing.isEmpty { return }
  state.log(
    .info,
    "Webhook not yet registered \u{2014} waiting on: \(missing.joined(separator: "; "))")
}

/// Tears down a single agent's webhook. Called from `destroy` for every
/// agent the registry has cached.
///
/// Note: `destroy` runs without a per-agent TLS frame, so we deliberately
/// do NOT call `setWebhookRegistered(false)` here — that would write to the
/// host's default-agent fallback. The host clears its own caches at plugin
/// shutdown; the per-agent `webhook_registered` flag will be re-evaluated
/// the next time the plugin loads.
func destroyAgent(state: AgentState) {
  if let token = state.botToken, !token.isEmpty {
    _ = telegramDeleteWebhook(token: token)
    logInfo("Webhook deleted on destroy for agent \(state.agentId)")
  }
}
