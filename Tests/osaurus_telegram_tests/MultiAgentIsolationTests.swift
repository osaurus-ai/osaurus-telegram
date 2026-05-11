import XCTest

@testable import osaurus_telegram

/// Verifies that ABI v4's `get_active_agent_id` properly partitions both
/// in-memory state (`AgentState`) and persistent state (SQLite tables) so
/// two agents loaded into the same plugin instance can't trample each other.
///
/// These exercise the fix for the bug class called out in the ABI v4 docs:
/// "one bot session being reused across agents".
final class MultiAgentIsolationTests: XCTestCase {

  private let agentA = "agent-A-uuid"
  private let agentB = "agent-B-uuid"

  override func setUp() {
    super.setUp()
    TestHost.install()
    // Stub Telegram so any incidental getMe / setWebhook / deleteWebhook
    // calls during hydration don't error out — we don't care about the
    // network round-trips for these tests, only the partitioning.
    TestHostGlobals.httpResponseByMethod = [
      "getMe":
        #"{"status":200,"body":"{\"ok\":true,\"result\":{\"id\":1,\"username\":\"bot\"}}"}"#,
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

  // MARK: - In-memory state (AgentState) isolation

  func testTwoAgentsHoldIndependentBotTokens() {
    let ctx = PluginContext()
    initPlugin(ctx)

    // Push bot_token for agent A.
    TestHost.setActiveAgent(agentA)
    let stateA = ctx.state(for: agentA)
    onConfigChanged(state: stateA, key: "bot_token", value: "111:tokenA")

    // Push a different bot_token for agent B.
    TestHost.setActiveAgent(agentB)
    let stateB = ctx.state(for: agentB)
    onConfigChanged(state: stateB, key: "bot_token", value: "222:tokenB")

    // Switch back to A and re-resolve — the registry must hand back the
    // SAME AgentState instance with the original token intact.
    TestHost.setActiveAgent(agentA)
    let stateAAgain = ctx.state(for: agentA)
    XCTAssertTrue(
      stateA === stateAAgain,
      "registry must memoize AgentState per agent_id")
    XCTAssertEqual(stateA.botToken, "111:tokenA")
    XCTAssertEqual(stateB.botToken, "222:tokenB")
  }

  func testWebhookSecretsAreScopedPerAgent() {
    let ctx = PluginContext()
    initPlugin(ctx)

    // First hydration generates a secret for A and stores it under A's
    // partition.
    TestHost.setActiveAgent(agentA)
    let stateA = ctx.state(for: agentA)
    XCTAssertNotNil(stateA.webhookSecret)
    let secretA = TestHost.getConfig(agent: agentA, "webhook_secret")
    XCTAssertEqual(stateA.webhookSecret, secretA)

    // Now hydrate B; it must get its OWN generated secret, independent
    // of A's.
    TestHost.setActiveAgent(agentB)
    let stateB = ctx.state(for: agentB)
    let secretB = TestHost.getConfig(agent: agentB, "webhook_secret")
    XCTAssertEqual(stateB.webhookSecret, secretB)
    XCTAssertNotNil(secretB)
    XCTAssertNotEqual(secretA, secretB, "each agent must get its own secret")

    // A's secret must not have been overwritten by B's hydration.
    XCTAssertEqual(
      TestHost.getConfig(agent: agentA, "webhook_secret"), secretA,
      "B's hydration must not bleed into A's config partition")
  }

  func testWebhookRegistrationsAreScopedPerAgent() {
    let ctx = PluginContext()
    initPlugin(ctx)

    // Bring agent A all the way up. webhook_registered=true under A.
    TestHost.setActiveAgent(agentA)
    let stateA = ctx.state(for: agentA)
    onConfigChanged(state: stateA, key: "bot_token", value: "111:tokenA")
    onConfigChanged(state: stateA, key: "tunnel_url", value: "https://A.osaurus.ai")
    XCTAssertEqual(TestHost.getConfig(agent: agentA, "webhook_registered"), "true")

    // Switch to B and just set a token (no tunnel yet) — this should
    // explicitly clear B's webhook_registered, but MUST NOT touch A's.
    TestHost.setActiveAgent(agentB)
    let stateB = ctx.state(for: agentB)
    onConfigChanged(state: stateB, key: "bot_token", value: "222:tokenB")
    XCTAssertNil(
      TestHost.getConfig(agent: agentB, "webhook_registered"),
      "B has no tunnel yet — flag stays cleared")
    XCTAssertEqual(
      TestHost.getConfig(agent: agentA, "webhook_registered"), "true",
      "B's transition must not flap A's status indicator")
  }

  // MARK: - DB partitioning (chat_sessions / active_dispatches / seen_updates)

  func testActiveDispatchRowsAreIsolatedAcrossAgents() {
    DatabaseManager.initSchema()

    // Both agents see chat_id 99 (very plausible — Telegram chat_id is
    // per-USER, not per-bot, so the same Telegram user talking to two
    // different bots produces the same chat_id).
    let now = Int(Date().timeIntervalSince1970)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-A", agentId: agentA, chatId: 99,
      replyToken: "TOKEN_A", sessionId: "sA", expiresAt: now + 600)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-B", agentId: agentB, chatId: 99,
      replyToken: "TOKEN_B", sessionId: "sB", expiresAt: now + 600)

    // Both inserts must have landed — old PK would have collided here.
    let activeA = DatabaseManager.activeDispatch(agentId: agentA, forChat: 99)
    let activeB = DatabaseManager.activeDispatch(agentId: agentB, forChat: 99)
    XCTAssertEqual(activeA?.taskId, "task-A")
    XCTAssertEqual(activeB?.taskId, "task-B")

    // reply_token lookup must return rows tagged with their owning agent.
    XCTAssertEqual(DatabaseManager.lookupBinding(token: "TOKEN_A")?.agentId, agentA)
    XCTAssertEqual(DatabaseManager.lookupBinding(token: "TOKEN_B")?.agentId, agentB)
  }

  func testChatSessionsAreIsolatedAcrossAgents() {
    DatabaseManager.initSchema()

    // Agent A blocks chat 1234. Agent B's view of chat 1234 must be
    // unaffected — they're different bot conversations even though the
    // chat_id integer collides.
    _ = DatabaseManager.upsertChatSession(agentId: agentA, chatId: 1234)
    DatabaseManager.markChatBlocked(agentId: agentA, chatId: 1234)

    _ = DatabaseManager.upsertChatSession(agentId: agentB, chatId: 1234)

    XCTAssertTrue(DatabaseManager.isChatBlocked(agentId: agentA, chatId: 1234))
    XCTAssertFalse(
      DatabaseManager.isChatBlocked(agentId: agentB, chatId: 1234),
      "blocking on agent A must not block on agent B")
  }

  func testSeenUpdateIdsAreScopedPerAgent() {
    DatabaseManager.initSchema()

    // Same Telegram update_id from two different bots — both should
    // record cleanly under their own agent's partition.
    DatabaseManager.markUpdateSeen(agentId: agentA, updateId: 5_000)
    DatabaseManager.markUpdateSeen(agentId: agentB, updateId: 5_000)

    XCTAssertTrue(
      DatabaseManager.isUpdateAlreadySeen(agentId: agentA, updateId: 5_000))
    XCTAssertTrue(
      DatabaseManager.isUpdateAlreadySeen(agentId: agentB, updateId: 5_000))

    // And critically: marking on B must not have made A think it had
    // already seen something it hadn't (or vice versa).
    XCTAssertFalse(
      DatabaseManager.isUpdateAlreadySeen(agentId: agentA, updateId: 5_001))
    XCTAssertFalse(
      DatabaseManager.isUpdateAlreadySeen(agentId: agentB, updateId: 5_002))
  }

  // MARK: - Reply tools refuse cross-agent token replay

  func testReplyToolRejectsTokenBoundToDifferentAgent() {
    DatabaseManager.initSchema()

    // Agent A dispatches and gets a reply_token bound to agent A.
    let now = Int(Date().timeIntervalSince1970)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-A", agentId: agentA, chatId: 1,
      replyToken: "AUUUUUUU", sessionId: "sA", expiresAt: now + 600)

    // Agent B tries to use A's reply_token. Tools must refuse — the
    // binding's agent_id doesn't match B's.
    let ctx = PluginContext()
    initPlugin(ctx)
    TestHost.setActiveAgent(agentB)
    let stateB = ctx.state(for: agentB)
    stateB.botToken = "222:tokenB"  // bypass hydration noise

    let payload = #"{"reply_token":"AUUUUUUU","text":"hi"}"#
    let envelope = handleReply(state: stateB, payload: payload)

    XCTAssertTrue(
      envelope.contains("\"ok\":false"),
      "agent B must not be able to send via agent A's reply_token")
    XCTAssertTrue(
      envelope.contains("stale_token"),
      "rejection should surface as stale_token to the agent")
  }

  // MARK: - destroy spans every cached agent

  func testDestroyTearsDownEveryCachedAgent() {
    let ctx = PluginContext()
    initPlugin(ctx)

    TestHost.setActiveAgent(agentA)
    let stateA = ctx.state(for: agentA)
    onConfigChanged(state: stateA, key: "bot_token", value: "111:tokenA")
    onConfigChanged(state: stateA, key: "tunnel_url", value: "https://A.osaurus.ai")

    TestHost.setActiveAgent(agentB)
    let stateB = ctx.state(for: agentB)
    onConfigChanged(state: stateB, key: "bot_token", value: "222:tokenB")
    onConfigChanged(state: stateB, key: "tunnel_url", value: "https://B.osaurus.ai")

    // Destroy iterates every cached agent — both bots' webhooks should
    // get torn down with Telegram. We don't care about the order.
    TestHostGlobals.httpCalls = []
    TestHost.setActiveAgent(nil)  // destroy runs without per-agent TLS
    for (_, s) in ctx.allStates() {
      destroyAgent(state: s)
    }

    let deleteCalls = TestHostGlobals.httpCalls.filter {
      ($0["url"] as? String ?? "").hasSuffix("deleteWebhook")
    }
    XCTAssertGreaterThanOrEqual(
      deleteCalls.count, 2,
      "destroy must call deleteWebhook for every cached agent")
  }
}
