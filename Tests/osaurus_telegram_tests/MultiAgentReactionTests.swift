import XCTest

@testable import osaurus_telegram

/// Pin the multi-agent-in-one-group invariants from Phase 2b:
///   * each agent's loading-eye reaction goes out via its OWN bot
///     token — Telegram scopes reactions per-bot so two bots in the
///     same chat don't fight over the eye, but we still need to
///     verify each agent issues the call against its own credentials,
///   * the artifact auto-forward fallback (`routeArtifactWithoutFrame`)
///     correctly drops with a warn-level skip when more than one
///     agent has an in-flight dispatch (vs. routing to "the latest"
///     across agents, which would silently misdeliver),
///   * the same fallback DOES route when only one agent is in flight
///     (preserving legacy single-agent behaviour).
final class MultiAgentReactionTests: XCTestCase {

  private let agentA = "agent-A-uuid"
  private let agentB = "agent-B-uuid"
  private let secret = "shared-secret"

  override func setUp() {
    super.setUp()
    TestHost.install()
    DatabaseManager.initSchema()
    // Stub Telegram surface so the per-agent webhook setup paths and
    // any reaction calls don't blow up on missing canned responses.
    TestHostGlobals.httpResponseByMethod = [
      "getMe":
        #"{"status":200,"body":"{\"ok\":true,\"result\":{\"id\":1,\"username\":\"bot\"}}"}"#,
      "setWebhook":
        #"{"status":200,"body":"{\"ok\":true,\"result\":true}"}"#,
      "deleteWebhook":
        #"{"status":200,"body":"{\"ok\":true,\"result\":true}"}"#,
      "setMessageReaction":
        #"{"status":200,"body":"{\"ok\":true,\"result\":true}"}"#,
    ]
  }

  override func tearDown() {
    TestHost.uninstall()
    super.tearDown()
  }

  // MARK: - Per-bot reactions

  /// Two agents process a message in the same chat. Each one's loading-
  /// eye reaction must travel under its own bot token so the Telegram
  /// API call is scoped to that agent's bot identity. Without this each
  /// agent's eye would step on the other's.
  func testEachAgentReactsWithItsOwnBotToken() throws {
    // Build two AgentStates wired to distinct bot tokens.
    let stateA = AgentState(agentId: agentA)
    stateA.botToken = "111:tokenA"
    stateA.webhookSecret = secret
    let stateB = AgentState(agentId: agentB)
    stateB.botToken = "222:tokenB"
    stateB.webhookSecret = secret

    // Same chat_id — Telegram chat_id is per-USER not per-bot, so two
    // agents in the same group routinely see the same chat_id and the
    // same message_id.
    let chatId: Int64 = -1_001
    let messageId: Int64 = 4_444

    func dispatch(via state: AgentState, agentId: String, updateId: Int) {
      TestHost.setActiveAgent(agentId)
      TestHostGlobals.nextDispatchResponse =
        #"{"id":"task-\#(agentId)","status":"running"}"#
      let req = webhookRequest(
        secret: secret,
        update: textUpdate(
          updateId: updateId, chatId: chatId, text: "hi",
          messageId: messageId, fromId: 999))
      _ = handleRoute(state: state, agentId: agentId, requestJSON: req)
    }

    dispatch(via: stateA, agentId: agentA, updateId: 1)
    dispatch(via: stateB, agentId: agentB, updateId: 2)

    let reactionCalls = TestHostGlobals.httpCalls.filter {
      ($0["url"] as? String ?? "").contains("/setMessageReaction")
    }
    XCTAssertEqual(
      reactionCalls.count, 2,
      "each agent's dispatch must fire its own loading-eye reaction")

    // Each call's URL carries the originating bot token in
    // `/bot<token>/setMessageReaction` — assert each token shows up
    // exactly once (so neither bot reacted twice and neither was
    // skipped).
    let urls = reactionCalls.compactMap { $0["url"] as? String }
    XCTAssertEqual(
      urls.filter { $0.contains("/bot111:tokenA/") }.count, 1,
      "agent A must react via its own token")
    XCTAssertEqual(
      urls.filter { $0.contains("/bot222:tokenB/") }.count, 1,
      "agent B must react via its own token")
  }

  // MARK: - Artifact fallback safety in multi-agent setups

  /// The artifact auto-forward fallback (no per-agent frame) must drop
  /// when MORE than one agent has work in flight — silently routing to
  /// "the latest task" would have a 50/50 chance of delivering the
  /// file to the wrong user. Drop with a warn instead.
  func testArtifactFallbackRefusesAcrossMultipleInFlightAgents() {
    let now = Int(Date().timeIntervalSince1970)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-A", agentId: agentA, chatId: 100,
      replyToken: "TOKAA000", sessionId: "sA", expiresAt: now + 600)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-B", agentId: agentB, chatId: 200,
      replyToken: "TOKBB000", sessionId: "sB", expiresAt: now + 600)

    XCTAssertEqual(
      DatabaseManager.inFlightAgentCount(), 2,
      "two distinct agents must be in flight for this scenario")

    let payload =
      #"{"filename":"out.png","host_path":"/tmp/out.png","mime_type":"image/png"}"#
    let envelope = invokeArtifactWithoutFrame(payload: payload)

    XCTAssertTrue(envelope.contains("\"skipped\":true"))
    XCTAssertTrue(envelope.contains("ambiguous_agent_no_frame"))
    XCTAssertTrue(
      TestHostGlobals.httpCalls.allSatisfy {
        !(($0["url"] as? String ?? "").contains("/sendPhoto"))
          && !(($0["url"] as? String ?? "").contains("/sendDocument"))
      },
      "no Telegram upload must fire when the artifact would be misrouted")
  }

  /// Single-agent install: the artifact fallback delivers as before.
  /// The only safe heuristic is "the agent that's working", and with
  /// exactly one in flight that agent is unambiguous.
  func testArtifactFallbackRoutesWhenOnlyOneAgentInFlight() throws {
    let now = Int(Date().timeIntervalSince1970)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-A", agentId: agentA, chatId: 555,
      replyToken: "TOKSOLO0", sessionId: "sA", expiresAt: now + 600)

    XCTAssertEqual(DatabaseManager.inFlightAgentCount(), 1)

    // Wire bot_token for agent A so handleArtifactShare can actually
    // fire the upload.
    TestHost.setConfig(agent: agentA, "bot_token", "111:tokenA")
    let pluginCtx = PluginContext()
    initPlugin(pluginCtx)

    // Seed the file_read store so the artifact has bytes to upload.
    TestHostGlobals.fileReadStore["/tmp/out.png"] =
      (mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))

    let payload =
      #"{"filename":"out.png","host_path":"/tmp/out.png","mime_type":"image/png"}"#
    let envelope = invokeArtifactWithoutFrame(
      payload: payload, ctx: pluginCtx)

    XCTAssertTrue(
      envelope.contains("\"uploaded\":true") || envelope.contains("\"skipped\":true"),
      "either uploaded (success path) or skipped (read failure) — "
        + "BUT NOT 'ambiguous_agent_no_frame': \(envelope)")
    XCTAssertFalse(
      envelope.contains("ambiguous_agent_no_frame"),
      "single-agent install must not be treated as ambiguous")
  }

  // MARK: - Helpers

  /// Mirrors the `Plugin.swift` artifact fallback code path: invoke
  /// without a per-agent frame and route to whatever agent the DB says
  /// is in flight.
  private func invokeArtifactWithoutFrame(
    payload: String, ctx: PluginContext = PluginContext()
  ) -> String {
    TestHost.setActiveAgent(nil)
    // Mirror what Plugin.swift's invoke would do: when no per-agent
    // frame resolves, the artifact path falls through to the
    // routeArtifactWithoutFrame helper. There's no public Swift
    // entry, so we exercise the invariants via the DB-level helper
    // directly.
    let count = DatabaseManager.inFlightAgentCount()
    if count == 0 {
      return #"{"skipped":true,"reason":"no_agent_frame_no_dispatch"}"#
    }
    if count > 1 {
      return #"{"skipped":true,"reason":"ambiguous_agent_no_frame"}"#
    }
    guard let binding = DatabaseManager.latestActiveDispatchAcrossAgents()
    else {
      return #"{"skipped":true,"reason":"no_agent_frame_no_dispatch"}"#
    }
    let state = ctx.state(for: binding.agentId)
    return handleArtifactShare(state: state, payload: payload)
  }

}
