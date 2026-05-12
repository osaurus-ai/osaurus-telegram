import XCTest

@testable import osaurus_telegram

/// Pin the Phase 4 polish features:
///   * `/start` and `/help` are plugin-owned static replies that
///     bypass the allowlist and never dispatch.
///   * The activity-keepalive bumps `expires_at` on OUTPUT / ACTIVITY /
///     PROGRESS task events.
///   * `staticCommandReply` recognises both `/cmd` and `/cmd@bot`.
final class PolishTests: XCTestCase {

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

  // MARK: - /start and /help are recognised

  func testStaticCommandReplyRecognisesStartAndHelp() {
    XCTAssertNotNil(staticCommandReply("/start"))
    XCTAssertNotNil(staticCommandReply("/help"))
    XCTAssertNotNil(staticCommandReply("/Start"))
    XCTAssertNotNil(staticCommandReply("/HELP@MyBot"))
    XCTAssertNil(staticCommandReply("/clear"))
    XCTAssertNil(staticCommandReply("/start now"))
    XCTAssertNil(staticCommandReply("hello"))
  }

  // MARK: - end-to-end /start dispatches nothing and replies statically

  func testStartCommandRepliesStaticallyAndBypassesDispatch() {
    let req = webhookRequest(
      secret: secret,
      update: textUpdate(updateId: 1, chatId: 100, text: "/start"))
    let response = parseRouteResponse(
      handleRoute(
        state: state, agentId: agentId, requestJSON: req))
    XCTAssertEqual(response.status, 200)
    XCTAssertTrue(
      TestHostGlobals.dispatchCalls.isEmpty,
      "/start must not dispatch an agent turn")

    let sendCalls = TestHostGlobals.httpCalls.filter {
      ($0["url"] as? String ?? "").contains("/sendMessage")
    }
    XCTAssertEqual(
      sendCalls.count, 1,
      "/start must reply with the welcome message")
    let body = sendCalls[0]["body"] as? String ?? ""
    XCTAssertTrue(
      body.contains("Osaurus") || body.contains("assistant"),
      "/start reply must look like a welcome message; got: \(body)")
  }

  /// `/start` and `/help` MUST work for denied users — the helpful
  /// reply gives them something to send to the admin (e.g. their ID
  /// surfaced via the follow-up `/whoami`).
  func testHelpBypassesAllowlist() {
    state.allowedUsers = AllowedUsers(ids: [42], usernames: [])
    let req = webhookRequest(
      secret: secret,
      update: textUpdate(updateId: 2, chatId: 200, text: "/help"))
    _ = handleRoute(state: state, agentId: agentId, requestJSON: req)

    let sendCalls = TestHostGlobals.httpCalls.filter {
      ($0["url"] as? String ?? "").contains("/sendMessage")
    }
    XCTAssertEqual(
      sendCalls.count, 1,
      "/help must reply even when the allowlist would otherwise reject")
  }

  // MARK: - TTL bump on activity

  /// OUTPUT events extend `expires_at` so a long-running research turn
  /// doesn't lose its reply binding to the 10-minute sweeper. We seed a
  /// row with a near-expired TTL, fire an OUTPUT event, and confirm
  /// the binding's expiry pushed forward.
  func testOutputEventBumpsExpiry() throws {
    let now = Int(Date().timeIntervalSince1970)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-bump", agentId: agentId, chatId: 999,
      replyToken: "TOKBUMP1", sessionId: "s1",
      expiresAt: now + 30 /* near-expired */)

    let beforeRow = try XCTUnwrap(
      DatabaseManager.lookupBindingByTask(taskId: "task-bump"))
    XCTAssertLessThan(beforeRow.expiresAt, now + 60)

    handleTaskEvent(
      state: state, agentId: agentId, taskId: "task-bump",
      eventType: 7 /* OUTPUT */,
      eventJSON: #"{"text":"thinking..."}"#)

    let afterRow = try XCTUnwrap(
      DatabaseManager.lookupBindingByTask(taskId: "task-bump"))
    XCTAssertGreaterThan(
      afterRow.expiresAt, beforeRow.expiresAt,
      "OUTPUT must push expires_at forward")
    XCTAssertGreaterThan(
      afterRow.expiresAt, now + 300,
      "the bumped TTL must include the documented activity-keepalive window")
  }

  /// ACTIVITY events bump TTL — they're proof-of-life even when the
  /// agent isn't streaming text. We exercise PROGRESS in a second
  /// fresh row so the monotone guard in `bumpExpiry` doesn't make the
  /// "second event in the same row" path appear like a no-op.
  func testActivityBumpExpiry() throws {
    let now = Int(Date().timeIntervalSince1970)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-act", agentId: agentId, chatId: 1000,
      replyToken: "TOKACT00", sessionId: "s2",
      expiresAt: now + 30)

    let before = try XCTUnwrap(
      DatabaseManager.lookupBindingByTask(taskId: "task-act"))
    handleTaskEvent(
      state: state, agentId: agentId, taskId: "task-act",
      eventType: 1 /* ACTIVITY */, eventJSON: "{}")
    let after = try XCTUnwrap(
      DatabaseManager.lookupBindingByTask(taskId: "task-act"))
    XCTAssertGreaterThan(after.expiresAt, before.expiresAt)
  }

  func testProgressBumpExpiry() throws {
    let now = Int(Date().timeIntervalSince1970)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-prog", agentId: agentId, chatId: 1001,
      replyToken: "TOKPRG00", sessionId: "s3",
      expiresAt: now + 30)

    let before = try XCTUnwrap(
      DatabaseManager.lookupBindingByTask(taskId: "task-prog"))
    handleTaskEvent(
      state: state, agentId: agentId, taskId: "task-prog",
      eventType: 2 /* PROGRESS */, eventJSON: "{}")
    let after = try XCTUnwrap(
      DatabaseManager.lookupBindingByTask(taskId: "task-prog"))
    XCTAssertGreaterThan(after.expiresAt, before.expiresAt)
  }

  /// `bumpExpiry` is monotone: a stale call with a smaller expiry must
  /// not roll the TTL back.
  func testBumpExpiryRefusesToShrink() throws {
    let now = Int(Date().timeIntervalSince1970)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-mono", agentId: agentId, chatId: 1100,
      replyToken: "TOKMONO0", sessionId: "s3",
      expiresAt: now + 1_000)

    DatabaseManager.bumpExpiry(taskId: "task-mono", newExpiresAt: now + 100)
    let row = try XCTUnwrap(
      DatabaseManager.lookupBindingByTask(taskId: "task-mono"))
    XCTAssertEqual(
      row.expiresAt, now + 1_000,
      "smaller expiry must NOT roll the TTL backward")
  }

}
