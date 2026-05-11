import XCTest

@testable import osaurus_telegram

final class LifecycleTests: XCTestCase {

  /// Convenience: every test in this suite runs as one specific agent. Multi-agent
  /// behaviors live in `MultiAgentIsolationTests`.
  private let agentId = defaultTestAgentId

  override func setUp() {
    super.setUp()
    TestHost.install()
    stubHealthyTelegram()
  }

  /// Happy-path Telegram stub: getMe + setWebhook + deleteWebhook all
  /// succeed, and getWebhookInfo (auto-handled by TestHost) echoes
  /// whatever URL was most recently registered with no delivery error.
  private func stubHealthyTelegram() {
    TestHostGlobals.httpResponseByMethod = [
      "getMe":
        #"{"status":200,"body":"{\"ok\":true,\"result\":{\"id\":42,\"username\":\"my_bot\"}}"}"#,
      "setWebhook":
        #"{"status":200,"body":"{\"ok\":true,\"result\":true}"}"#,
      "deleteWebhook":
        #"{"status":200,"body":"{\"ok\":true,\"result\":true}"}"#,
    ]
  }

  override func tearDown() {
    TestHost.uninstall()
    super.tearDown()
  }

  // MARK: - Helpers
  //
  // All per-agent state hydration moved out of `initPlugin` and into the
  // first `state(for:)` lookup (which is what real per-agent callbacks do
  // before delegating). Tests call `bootstrap()` to drive that flow with
  // the active agent already set.

  private func bootstrap() -> (PluginContext, AgentState) {
    let ctx = PluginContext()
    initPlugin(ctx)
    let state = ctx.state(for: agentId)
    return (ctx, state)
  }

  // MARK: - webhook_secret bootstrapping

  func testInitGeneratesWebhookSecretIfAbsent() {
    let (_, state) = bootstrap()
    let secret = TestHost.getConfig(agent: agentId, "webhook_secret")
    XCTAssertNotNil(secret, "first hydration must generate webhook_secret")
    XCTAssertEqual(secret?.count, 64, "32-byte hex string is 64 chars")
    XCTAssertEqual(state.webhookSecret, secret)
  }

  func testInitLoadsExistingWebhookSecret() {
    TestHost.setConfig(agent: agentId, "webhook_secret", "preexisting-secret")
    let (_, state) = bootstrap()
    XCTAssertEqual(state.webhookSecret, "preexisting-secret")
    XCTAssertEqual(
      TestHost.getConfig(agent: agentId, "webhook_secret"), "preexisting-secret",
      "hydration must not overwrite an existing webhook_secret")
  }

  func testInitDoesNotPreClearFlagWhenAboutToReRegister() {
    // Regression: first hydration used to unconditionally configDelete the
    // flag, causing a brief red flash on every restart even when both
    // signals were already on disk and registration was about to succeed.
    TestHost.setConfig(agent: agentId, "webhook_registered", "true")
    TestHost.setConfig(agent: agentId, "bot_token", "999:abc")
    TestHost.setConfig(agent: agentId, "tunnel_url", "https://my.osaurus.ai")

    _ = bootstrap()

    XCTAssertEqual(
      TestHost.getConfig(agent: agentId, "webhook_registered"), "true",
      "first hydration should let setupWebhook decide based on Telegram's "
        + "response, not blindly clear the flag")
  }

  func testInitClearsFlagWhenEnteringWaitingState() {
    TestHost.setConfig(agent: agentId, "webhook_registered", "true")  // stale
    // bot_token + tunnel_url not present → we ARE in the waiting state
    _ = bootstrap()
    XCTAssertNil(
      TestHost.getConfig(agent: agentId, "webhook_registered"),
      "if we know we're not registered (waiting on config), reflect that")
  }

  // MARK: - hydration when both pieces of config are present

  func testInitRegistersWebhookWhenBotTokenAndTunnelURLPresent() {
    TestHost.setConfig(agent: agentId, "bot_token", "999:abc")
    TestHost.setConfig(
      agent: agentId, "tunnel_url", "https://0xabc.agent.osaurus.ai")

    let (_, state) = bootstrap()

    XCTAssertEqual(state.botToken, "999:abc")
    XCTAssertEqual(state.tunnelURL, "https://0xabc.agent.osaurus.ai")
    XCTAssertEqual(state.botUsername, "my_bot", "getMe response should populate botUsername")
    assertSetWebhookCalled(
      with: "https://0xabc.agent.osaurus.ai/plugins/osaurus.telegram/webhook")
    XCTAssertEqual(
      TestHost.getConfig(agent: agentId, "webhook_registered"), "true",
      "successful registration must drive the UI status indicator")
  }

  func testInitDoesNotRegisterWhenTunnelURLMissing() {
    TestHost.setConfig(agent: agentId, "bot_token", "999:abc")

    let (_, state) = bootstrap()

    XCTAssertEqual(state.botToken, "999:abc")
    XCTAssertNil(state.tunnelURL)
    assertNoTelegramAPIRequests("must not register webhook without tunnel_url")
  }

  // MARK: - canonical autoconfig flow

  func testTunnelURLPushedAfterBotTokenTriggersRegistration() {
    // Simulates: user installs plugin, enters bot_token, then the host pushes
    // the tunnel URL once the agent's tunnel comes up.
    let (_, state) = bootstrap()
    TestHostGlobals.httpCalls = []  // discard hydration noise

    onConfigChanged(state: state, key: "bot_token", value: "100:tok")
    XCTAssertTrue(
      TestHostGlobals.httpCalls.isEmpty,
      "bot_token alone must not trigger setWebhook — wait for tunnel_url")

    onConfigChanged(
      state: state, key: "tunnel_url", value: "https://my.agent.osaurus.ai")
    assertSetWebhookCalled(
      with: "https://my.agent.osaurus.ai/plugins/osaurus.telegram/webhook")
  }

  func testBotTokenSavedAfterTunnelURLTriggersRegistration() {
    // Reverse order: tunnel_url is pushed first (e.g. before user opens the
    // plugin to enter the bot token), then user pastes the token.
    let (_, state) = bootstrap()
    TestHostGlobals.httpCalls = []

    onConfigChanged(
      state: state, key: "tunnel_url", value: "https://my.agent.osaurus.ai")
    XCTAssertTrue(
      TestHostGlobals.httpCalls.isEmpty,
      "tunnel_url alone must not trigger setWebhook — wait for bot_token")

    onConfigChanged(state: state, key: "bot_token", value: "100:tok")
    assertSetWebhookCalled(
      with: "https://my.agent.osaurus.ai/plugins/osaurus.telegram/webhook")
  }

  func testTrailingSlashOnTunnelURLIsTrimmed() {
    let (_, state) = bootstrap()
    TestHostGlobals.httpCalls = []

    onConfigChanged(state: state, key: "bot_token", value: "100:tok")
    onConfigChanged(
      state: state, key: "tunnel_url", value: "https://my.agent.osaurus.ai/")

    assertSetWebhookCalled(
      with: "https://my.agent.osaurus.ai/plugins/osaurus.telegram/webhook")
  }

  // MARK: - re-registration on URL or token changes

  func testUpdatingTunnelURLReRegistersWebhook() {
    let (_, state) = bootstrap()

    onConfigChanged(state: state, key: "bot_token", value: "100:tok")
    onConfigChanged(state: state, key: "tunnel_url", value: "https://old.osaurus.ai")
    let firstCalls = TestHostGlobals.httpCalls.count
    XCTAssertGreaterThan(firstCalls, 0)

    onConfigChanged(state: state, key: "tunnel_url", value: "https://new.osaurus.ai")
    XCTAssertGreaterThan(
      TestHostGlobals.httpCalls.count, firstCalls,
      "updating the tunnel URL should trigger another setWebhook call")
    assertSetWebhookCalled(
      with: "https://new.osaurus.ai/plugins/osaurus.telegram/webhook")
  }

  func testReplacingBotTokenDeletesOldWebhookAndRegistersNew() {
    let (_, state) = bootstrap()
    onConfigChanged(state: state, key: "bot_token", value: "111:old")
    onConfigChanged(state: state, key: "tunnel_url", value: "https://my.osaurus.ai")
    TestHostGlobals.httpCalls = []

    onConfigChanged(state: state, key: "bot_token", value: "222:new")

    XCTAssertEqual(state.botToken, "222:new")
    let methods = TestHostGlobals.httpCalls.compactMap { call -> String? in
      guard let url = call["url"] as? String else { return nil }
      return url.split(separator: "/").last.map(String.init)
    }
    XCTAssertTrue(
      methods.contains("deleteWebhook"),
      "old token must have its webhook torn down")
    XCTAssertTrue(
      methods.contains("setWebhook"),
      "new token must register a fresh webhook")
  }

  func testClearingBotTokenDeletesWebhookAndStopsRegistering() {
    let (_, state) = bootstrap()
    onConfigChanged(state: state, key: "bot_token", value: "111:tok")
    onConfigChanged(state: state, key: "tunnel_url", value: "https://my.osaurus.ai")
    TestHostGlobals.httpCalls = []

    onConfigChanged(state: state, key: "bot_token", value: nil)

    XCTAssertNil(state.botToken)
    XCTAssertNil(state.botUsername)
    let urls = TestHostGlobals.httpCalls.compactMap { $0["url"] as? String }
    XCTAssertTrue(urls.contains { $0.hasSuffix("deleteWebhook") })
    XCTAssertFalse(urls.contains { $0.hasSuffix("setWebhook") })
    XCTAssertNil(
      TestHost.getConfig(agent: agentId, "webhook_registered"),
      "clearing bot_token must clear the UI status")
  }

  func testClearingTunnelURLClearsWebhookRegisteredFlag() {
    let (_, state) = bootstrap()
    onConfigChanged(state: state, key: "bot_token", value: "111:tok")
    onConfigChanged(state: state, key: "tunnel_url", value: "https://my.osaurus.ai")
    XCTAssertEqual(TestHost.getConfig(agent: agentId, "webhook_registered"), "true")

    onConfigChanged(state: state, key: "tunnel_url", value: nil)
    XCTAssertNil(state.tunnelURL)
    XCTAssertNil(
      TestHost.getConfig(agent: agentId, "webhook_registered"),
      "tunnel teardown must reflect in the UI status")
  }

  // MARK: - getWebhookInfo verification (the indicator now reflects Telegram's view)

  func testFlagIsSetOnlyAfterTelegramConfirmsTheURL() {
    let (_, state) = bootstrap()
    onConfigChanged(state: state, key: "bot_token", value: "111:tok")
    onConfigChanged(state: state, key: "tunnel_url", value: "https://my.osaurus.ai")

    // The auto-stub echoes the just-registered URL back via getWebhookInfo,
    // so the verification step should pass and flip the flag green.
    XCTAssertEqual(TestHost.getConfig(agent: agentId, "webhook_registered"), "true")
    XCTAssertTrue(
      TestHostGlobals.httpCalls.contains {
        ($0["url"] as? String ?? "").hasSuffix("getWebhookInfo")
      },
      "setupWebhook must call getWebhookInfo to verify Telegram's view")
  }

  func testFlagStaysClearedWhenTelegramHasDifferentURL() {
    // Force getWebhookInfo to report a different (e.g. stale) URL so the
    // verification step rejects the registration.
    let staleResponse = #"""
      {"status":200,"body":"{\"ok\":true,\"result\":{\"url\":\"https://OLD.osaurus.ai/plugins/osaurus.telegram/webhook\",\"pending_update_count\":0,\"has_custom_certificate\":false}}"}
      """#
    TestHostGlobals.httpResponseByMethod["getWebhookInfo"] = staleResponse

    let (_, state) = bootstrap()
    onConfigChanged(state: state, key: "bot_token", value: "111:tok")
    onConfigChanged(state: state, key: "tunnel_url", value: "https://NEW.osaurus.ai")

    XCTAssertNil(
      TestHost.getConfig(agent: agentId, "webhook_registered"),
      "if Telegram doesn't confirm our URL, flag must stay cleared even "
        + "though setWebhook returned ok")
  }

  func testFlagStaysClearedWhenTelegramReportsRecentDeliveryError() {
    // setWebhook accepts our request, but Telegram reports a recent
    // delivery failure (e.g. tunnel went down between requests).
    TestHostGlobals.simulatedWebhookErrorMessage = "Connection refused"
    TestHostGlobals.simulatedWebhookErrorDate = Int(Date().timeIntervalSince1970)

    let (_, state) = bootstrap()
    onConfigChanged(state: state, key: "bot_token", value: "111:tok")
    onConfigChanged(state: state, key: "tunnel_url", value: "https://my.osaurus.ai")

    XCTAssertNil(
      TestHost.getConfig(agent: agentId, "webhook_registered"),
      "recent delivery error means the indicator must show disconnected")
  }

  func testFlagIgnoresOldDeliveryErrors() {
    // An error from > 5 min ago is considered recovered; the flag should
    // still flip green.
    TestHostGlobals.simulatedWebhookErrorMessage = "Was failing earlier"
    TestHostGlobals.simulatedWebhookErrorDate =
      Int(Date().timeIntervalSince1970) - 3_600  // 1h ago

    let (_, state) = bootstrap()
    onConfigChanged(state: state, key: "bot_token", value: "111:tok")
    onConfigChanged(state: state, key: "tunnel_url", value: "https://my.osaurus.ai")

    XCTAssertEqual(TestHost.getConfig(agent: agentId, "webhook_registered"), "true")
  }

  // MARK: - eager flag clears on transitions (no stale-green window)

  func testBotTokenSwapEagerlyClearsFlagBeforeReRegistering() {
    let (_, state) = bootstrap()
    onConfigChanged(state: state, key: "bot_token", value: "111:old")
    onConfigChanged(state: state, key: "tunnel_url", value: "https://my.osaurus.ai")
    XCTAssertEqual(TestHost.getConfig(agent: agentId, "webhook_registered"), "true")

    // Now swap to a new token but make Telegram unreachable so we can
    // observe that the flag was cleared *before* the new setWebhook tried.
    TestHostGlobals.httpResponseByMethod["getMe"] =
      #"{"status":500,"body":"{\"ok\":false,\"description\":\"server error\"}"}"#
    onConfigChanged(state: state, key: "bot_token", value: "222:new")

    XCTAssertNil(
      TestHost.getConfig(agent: agentId, "webhook_registered"),
      "eager clear means UI flips red as soon as the swap starts, not "
        + "after setupWebhook fails ~3s later")
  }

  func testBotTokenSavedWithoutTunnelClearsStaleFlag() {
    // Simulate: an earlier bot was registered (flag=true), user changes
    // the bot token while the tunnel happens to be down.
    TestHost.setConfig(agent: agentId, "webhook_registered", "true")
    let (ctx, _) = bootstrap()
    // Override the auto-hydrated state to mirror the scenario: an old
    // token was loaded and the tunnel happens to be unknown.
    let state = ctx.state(for: agentId)
    state.botToken = "111:old"
    state.tunnelURL = nil

    onConfigChanged(state: state, key: "bot_token", value: "222:new")

    XCTAssertNil(
      TestHost.getConfig(agent: agentId, "webhook_registered"),
      "even when waiting on tunnel_url, the new bot has no registered "
        + "webhook — flag must reflect that")
  }

  func testTunnelURLChangeClearsFlagBeforeReRegistering() {
    let (_, state) = bootstrap()
    onConfigChanged(state: state, key: "bot_token", value: "111:tok")
    onConfigChanged(state: state, key: "tunnel_url", value: "https://old.osaurus.ai")
    XCTAssertEqual(TestHost.getConfig(agent: agentId, "webhook_registered"), "true")

    // Change tunnel URL but make setWebhook fail; flag should be cleared
    // BEFORE setupWebhook runs, not left stale.
    TestHostGlobals.httpResponseByMethod["setWebhook"] =
      #"{"status":500,"body":"{\"ok\":false,\"description\":\"server error\"}"}"#
    onConfigChanged(state: state, key: "tunnel_url", value: "https://new.osaurus.ai")

    XCTAssertNil(TestHost.getConfig(agent: agentId, "webhook_registered"))
  }

  func testIdenticalTunnelURLPushIsNoOp() {
    let (_, state) = bootstrap()
    onConfigChanged(state: state, key: "bot_token", value: "111:tok")
    onConfigChanged(state: state, key: "tunnel_url", value: "https://my.osaurus.ai")
    let countAfterFirstRegister = TestHostGlobals.httpCalls.count
    XCTAssertEqual(TestHost.getConfig(agent: agentId, "webhook_registered"), "true")

    // Re-push the same URL; should not re-register or flap the indicator.
    onConfigChanged(state: state, key: "tunnel_url", value: "https://my.osaurus.ai")
    XCTAssertEqual(
      TestHostGlobals.httpCalls.count, countAfterFirstRegister,
      "identical tunnel_url must not trigger another setWebhook")
    XCTAssertEqual(
      TestHost.getConfig(agent: agentId, "webhook_registered"), "true",
      "identical tunnel_url must not flap the indicator")
  }

  // MARK: - destroy clears the flag

  func testDestroyTearsDownEachAgentsWebhook() {
    let (ctx, state) = bootstrap()
    onConfigChanged(state: state, key: "bot_token", value: "111:tok")
    onConfigChanged(state: state, key: "tunnel_url", value: "https://my.osaurus.ai")
    XCTAssertEqual(TestHost.getConfig(agent: agentId, "webhook_registered"), "true")

    // Drive `destroy` directly. We don't call setWebhookRegistered here
    // because destroy runs without per-agent TLS — the host clears its
    // own caches at plugin shutdown. We DO expect a deleteWebhook HTTP
    // call so Telegram stops sending updates.
    TestHostGlobals.httpCalls = []
    for (_, s) in ctx.allStates() {
      destroyAgent(state: s)
    }

    let urls = TestHostGlobals.httpCalls.compactMap { $0["url"] as? String }
    XCTAssertTrue(
      urls.contains { $0.hasSuffix("deleteWebhook") },
      "destroy must tear down each cached agent's webhook with Telegram")
  }

  // MARK: - helpers

  private func assertSetWebhookCalled(
    with expectedURL: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let setCalls = TestHostGlobals.httpCalls.filter { call in
      (call["url"] as? String ?? "").hasSuffix("setWebhook")
    }
    XCTAssertGreaterThanOrEqual(
      setCalls.count, 1,
      "expected at least one setWebhook call",
      file: file, line: line)
    guard let bodyStr = setCalls.last?["body"] as? String,
      let bodyData = bodyStr.data(using: .utf8),
      let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
    else {
      XCTFail("setWebhook body unparseable", file: file, line: line)
      return
    }
    XCTAssertEqual(
      body["url"] as? String, expectedURL,
      "setWebhook url mismatch", file: file, line: line)
  }

  private func assertNoTelegramAPIRequests(
    _ reason: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(
      TestHostGlobals.httpCalls.isEmpty, reason, file: file, line: line)
  }
}
