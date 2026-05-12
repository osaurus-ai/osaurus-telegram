import XCTest

@testable import osaurus_telegram

/// Pin the allowlist semantics introduced in Phase 2a:
///   * empty / nil config = allow everyone (legacy behaviour preserved),
///   * chat allowlist + user allowlist combine cleanly, both as
///     opt-in restrictions,
///   * matches are by numeric id OR case-insensitive @username,
///   * /whoami bypasses the gate so denied users can find their IDs,
///   * `on_config_changed` refreshes the parsed shape live without
///     a plugin restart,
///   * the allowlist is per-`AgentState` and never bleeds across agents.
final class AllowlistTests: XCTestCase {

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
    // Set bot identity so the group-chat tests below pass the mention
    // gate via reply-to.
    state.botUsername = "MyTestBot"
    state.botId = 9001
  }

  override func tearDown() {
    state = nil
    TestHost.uninstall()
    super.tearDown()
  }

  // MARK: - parseAllowedUsers

  func testParseAllowedUsersEmptyAndNilAreNoRestriction() {
    XCTAssertTrue(parseAllowedUsers(nil).isEmpty)
    XCTAssertTrue(parseAllowedUsers("").isEmpty)
    XCTAssertTrue(parseAllowedUsers("   ").isEmpty)
    XCTAssertTrue(parseAllowedUsers(",,,").isEmpty)
  }

  func testParseAllowedUsersHandlesIdsAndUsernamesAndBareNames() {
    let parsed = parseAllowedUsers("123, @Alice, BOB, 456")
    XCTAssertEqual(parsed.ids, [123, 456])
    XCTAssertEqual(parsed.usernames, ["alice", "bob"])
  }

  func testParseAllowedUsersTrimsWhitespaceAndIgnoresGarbage() {
    // Whitespace around tokens is fine; pure punctuation tokens that
    // aren't numeric and aren't `@something` get rejected with a warn
    // (no test for stderr; we just assert they don't sneak in).
    let parsed = parseAllowedUsers("  @ALICE  ,   789 , !!!  ")
    XCTAssertEqual(parsed.ids, [789])
    XCTAssertEqual(parsed.usernames, ["alice"])
  }

  func testParseAllowedChatIdsHandlesSignedIds() {
    let parsed = parseAllowedChatIds("12345, -1001234567890, 0, abc")
    XCTAssertEqual(parsed, [12345, -1_001_234_567_890, 0])
  }

  // MARK: - End-to-end allowlist gate

  /// Empty allowlists keep the legacy behaviour: every chat passes,
  /// every user passes.
  func testEmptyAllowlistAllowsEveryone() {
    state.allowedUsers = AllowedUsers(ids: [], usernames: [])
    state.allowedChatIds = []
    let req = webhookRequest(
      secret: secret,
      update: textUpdate(updateId: 1, chatId: 12_345, text: "hi", fromId: 999))
    let response = parseRouteResponse(route(req))
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(
      TestHostGlobals.dispatchCalls.count, 1,
      "no allowlist must mean no restriction")
  }

  /// Chat allowlist non-empty + chat NOT in list = silent drop.
  func testChatNotInAllowlistIsSilentlyDropped() {
    state.allowedChatIds = [777]
    let req = webhookRequest(
      secret: secret,
      update: textUpdate(updateId: 2, chatId: 9_999, text: "hi", fromId: 1))
    let response = parseRouteResponse(route(req))
    XCTAssertEqual(response.status, 200)
    XCTAssertTrue(
      TestHostGlobals.dispatchCalls.isEmpty,
      "rejected chat must not dispatch")
    XCTAssertTrue(
      TestHostGlobals.httpCalls.isEmpty,
      "rejected chat must NOT receive any plugin-owned reply (silent drop)")
  }

  /// Chat allowlist empty but user allowlist non-empty + user not in
  /// list = silent drop.
  func testUserNotInAllowlistIsSilentlyDropped() {
    state.allowedUsers = AllowedUsers(ids: [11], usernames: [])
    let req = webhookRequest(
      secret: secret,
      update: textUpdate(
        updateId: 3, chatId: 8_888, text: "hi", fromId: 22, username: "carol"))
    _ = route(req)
    XCTAssertTrue(TestHostGlobals.dispatchCalls.isEmpty)
    XCTAssertTrue(TestHostGlobals.httpCalls.isEmpty)
  }

  /// Numeric id match passes the user gate.
  func testUserMatchedByNumericIdIsAllowed() {
    state.allowedUsers = AllowedUsers(ids: [555], usernames: [])
    let req = webhookRequest(
      secret: secret,
      update: textUpdate(
        updateId: 4, chatId: 1_010, text: "hi", fromId: 555, username: "carol"))
    _ = route(req)
    XCTAssertEqual(TestHostGlobals.dispatchCalls.count, 1)
  }

  /// `@username` match is case-insensitive.
  func testUserMatchedByUsernameIsCaseInsensitive() {
    state.allowedUsers = AllowedUsers(ids: [], usernames: ["alice"])
    let req = webhookRequest(
      secret: secret,
      update: textUpdate(
        updateId: 5, chatId: 1_011, text: "hi", fromId: 1, username: "ALICE"))
    _ = route(req)
    XCTAssertEqual(TestHostGlobals.dispatchCalls.count, 1)
  }

  /// Both gates active: chat is allowed but user is not — still rejected.
  func testBothGatesAppliedIndependently() {
    state.allowedChatIds = [42]
    state.allowedUsers = AllowedUsers(ids: [777], usernames: [])
    // Chat passes, but the user (id=999) does not.
    _ = route(
      webhookRequest(
        secret: secret,
        update: textUpdate(
          updateId: 6, chatId: 42, text: "hi", fromId: 999, username: "x")))
    XCTAssertTrue(TestHostGlobals.dispatchCalls.isEmpty)
  }

  // MARK: - /whoami bypasses the allowlist

  /// `/whoami` MUST work even when both gates would normally reject the
  /// caller — denied users still need a way to surface their numeric id
  /// to the admin.
  func testWhoamiBypassesAllowlist() {
    state.allowedChatIds = [1]
    state.allowedUsers = AllowedUsers(ids: [1], usernames: [])

    let req = webhookRequest(
      secret: secret,
      update: textUpdate(
        updateId: 7, chatId: 9_876, text: "/whoami",
        fromId: 5_432, username: "stranger"))
    _ = route(req)

    XCTAssertTrue(
      TestHostGlobals.dispatchCalls.isEmpty,
      "/whoami must NOT dispatch — it's a static plugin reply")
    let sendCalls = TestHostGlobals.httpCalls.filter {
      ($0["url"] as? String ?? "").contains("/sendMessage")
    }
    XCTAssertEqual(
      sendCalls.count, 1,
      "/whoami must reply with a single sendMessage even when allowlisted out")
    let body = sendCalls[0]["body"] as? String ?? ""
    XCTAssertTrue(body.contains("user_id"))
    XCTAssertTrue(body.contains("5432"))
    XCTAssertTrue(body.contains("9876"))
    XCTAssertTrue(body.contains("@stranger"))
  }

  func testIsWhoamiCommandAcceptsCommonCasings() {
    XCTAssertTrue(isWhoamiCommand("/whoami"))
    XCTAssertTrue(isWhoamiCommand("/WHOAMI"))
    XCTAssertTrue(isWhoamiCommand("/whoami@MyTestBot"))
    XCTAssertFalse(isWhoamiCommand("whoami"))
    XCTAssertFalse(isWhoamiCommand("/whoami plus"))
  }

  // MARK: - on_config_changed refresh

  /// Live refresh: config push updates the parsed allowlist on the
  /// existing AgentState without a restart.
  func testConfigChangeRefreshesAllowedUsers() {
    XCTAssertTrue(state.allowedUsers.isEmpty)
    onConfigChanged(state: state, key: "allowed_users", value: "@Alice, 12")
    XCTAssertEqual(state.allowedUsers.usernames, ["alice"])
    XCTAssertEqual(state.allowedUsers.ids, [12])

    // Empty value clears the gate again.
    onConfigChanged(state: state, key: "allowed_users", value: "")
    XCTAssertTrue(state.allowedUsers.isEmpty)
  }

  func testConfigChangeRefreshesAllowedChatIds() {
    XCTAssertTrue(state.allowedChatIds.isEmpty)
    onConfigChanged(
      state: state, key: "allowed_chat_ids",
      value: "42, -1001234567890")
    XCTAssertEqual(state.allowedChatIds, [42, -1_001_234_567_890])

    onConfigChanged(state: state, key: "allowed_chat_ids", value: nil)
    XCTAssertTrue(state.allowedChatIds.isEmpty)
  }

  // MARK: - Per-agent isolation

  /// The allowlist lives on `AgentState`, so two agents sharing the
  /// same plugin instance keep independent gates.
  func testAllowlistIsPerAgent() {
    let stateA = AgentState(agentId: "agent-A")
    let stateB = AgentState(agentId: "agent-B")
    onConfigChanged(state: stateA, key: "allowed_users", value: "@alice")
    onConfigChanged(state: stateB, key: "allowed_users", value: "999")

    XCTAssertEqual(stateA.allowedUsers.usernames, ["alice"])
    XCTAssertTrue(stateA.allowedUsers.ids.isEmpty)
    XCTAssertEqual(stateB.allowedUsers.ids, [999])
    XCTAssertTrue(stateB.allowedUsers.usernames.isEmpty)
  }

  // MARK: - Helpers

  private func route(_ requestJSON: String) -> String {
    handleRoute(state: state, agentId: agentId, requestJSON: requestJSON)
  }
}
