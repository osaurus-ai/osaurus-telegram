import XCTest

@testable import osaurus_telegram

final class DatabaseTests: XCTestCase {

  /// Single-agent baseline. Cross-agent isolation lives in
  /// `MultiAgentIsolationTests`.
  private let agentId = defaultTestAgentId

  override func setUp() {
    super.setUp()
    TestHost.install()
    DatabaseManager.initSchema()
  }

  override func tearDown() {
    TestHost.uninstall()
    super.tearDown()
  }

  // MARK: chat_sessions

  func testUpsertChatSessionCreatesRowWithDefaults() {
    let row = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 100)
    XCTAssertEqual(row.chatId, 100)
    XCTAssertEqual(row.sessionSalt, 0)
    XCTAssertEqual(row.blocked, 0)
  }

  func testUpsertChatSessionPreservesSaltAndBlocked() {
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 100)
    DatabaseManager.bumpSessionSalt(agentId: agentId, chatId: 100)
    DatabaseManager.markChatBlocked(agentId: agentId, chatId: 100)

    let row = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 100)
    XCTAssertEqual(row.sessionSalt, 1, "subsequent upsert must not reset salt")
    XCTAssertEqual(row.blocked, 1, "subsequent upsert must not unblock")
  }

  func testBumpSessionSaltIncrementsMonotonically() {
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 200)
    DatabaseManager.bumpSessionSalt(agentId: agentId, chatId: 200)
    DatabaseManager.bumpSessionSalt(agentId: agentId, chatId: 200)
    DatabaseManager.bumpSessionSalt(agentId: agentId, chatId: 200)
    XCTAssertEqual(
      DatabaseManager.getChatSession(agentId: agentId, chatId: 200)?.sessionSalt, 3)
  }

  func testIsChatBlockedReflectsState() {
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 300)
    XCTAssertFalse(DatabaseManager.isChatBlocked(agentId: agentId, chatId: 300))
    DatabaseManager.markChatBlocked(agentId: agentId, chatId: 300)
    XCTAssertTrue(DatabaseManager.isChatBlocked(agentId: agentId, chatId: 300))
  }

  func testGetChatSessionReturnsNilForUnknownChat() {
    XCTAssertNil(DatabaseManager.getChatSession(agentId: agentId, chatId: 999_999))
  }

  // MARK: active_dispatches

  func testInsertAndLookupBindingByToken() {
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 1)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-1", agentId: agentId, chatId: 1, replyToken: "ABC123",
      sessionId: "session-1", expiresAt: Int(Date().timeIntervalSince1970) + 600)

    let binding = DatabaseManager.lookupBinding(token: "ABC123")
    XCTAssertNotNil(binding)
    XCTAssertEqual(binding?.taskId, "task-1")
    XCTAssertEqual(binding?.agentId, agentId)
    XCTAssertEqual(binding?.chatId, 1)
    XCTAssertEqual(binding?.sessionId, "session-1")
    XCTAssertEqual(binding?.hasReplied, 0)
  }

  func testLookupBindingReturnsNilForUnknownToken() {
    XCTAssertNil(DatabaseManager.lookupBinding(token: "DOES_NOT_EXIST"))
  }

  func testActiveDispatchForChatReturnsLatest() {
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 2)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-2", agentId: agentId, chatId: 2, replyToken: "TOKEN2",
      sessionId: "s-2", expiresAt: Int(Date().timeIntervalSince1970) + 600)
    let active = DatabaseManager.activeDispatch(agentId: agentId, forChat: 2)
    XCTAssertEqual(active?.taskId, "task-2")
    XCTAssertEqual(active?.replyToken, "TOKEN2")
  }

  func testActiveDispatchUniqueChatIdEnforced() {
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 3)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-a", agentId: agentId, chatId: 3, replyToken: "TOK_A",
      sessionId: "s", expiresAt: Int(Date().timeIntervalSince1970) + 600)
    // Second insert for the same (agent, chat) should be a no-op due to
    // UNIQUE(agent_id, chat_id).
    DatabaseManager.insertActiveDispatch(
      taskId: "task-b", agentId: agentId, chatId: 3, replyToken: "TOK_B",
      sessionId: "s", expiresAt: Int(Date().timeIntervalSince1970) + 600)

    XCTAssertEqual(
      DatabaseManager.activeDispatch(agentId: agentId, forChat: 3)?.taskId, "task-a",
      "UNIQUE(agent_id, chat_id) should reject the second insert; first row stays")
    XCTAssertNil(
      DatabaseManager.lookupBinding(token: "TOK_B"),
      "rejected insert must not appear under its token")
  }

  func testMarkRepliedAndHasReplied() {
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 4)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-r", agentId: agentId, chatId: 4, replyToken: "TOK_R",
      sessionId: "s", expiresAt: Int(Date().timeIntervalSince1970) + 600)

    XCTAssertFalse(DatabaseManager.hasReplied(taskId: "task-r"))
    DatabaseManager.markReplied(taskId: "task-r")
    XCTAssertTrue(DatabaseManager.hasReplied(taskId: "task-r"))
    XCTAssertEqual(DatabaseManager.lookupBindingByTask(taskId: "task-r")?.hasReplied, 1)
  }

  func testHasRepliedFalseForUnknownTask() {
    XCTAssertFalse(DatabaseManager.hasReplied(taskId: "ghost-task"))
  }

  func testDeleteActiveDispatchRemovesBinding() {
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 5)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-d", agentId: agentId, chatId: 5, replyToken: "TOK_D",
      sessionId: "s", expiresAt: Int(Date().timeIntervalSince1970) + 600)
    XCTAssertNotNil(DatabaseManager.activeDispatch(agentId: agentId, forChat: 5))
    DatabaseManager.deleteActiveDispatch(taskId: "task-d")
    XCTAssertNil(DatabaseManager.activeDispatch(agentId: agentId, forChat: 5))
    XCTAssertNil(DatabaseManager.lookupBinding(token: "TOK_D"))
  }

  func testSweepExpiredDispatchesDropsOnlyExpired() {
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 10)
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 11)
    let now = Int(Date().timeIntervalSince1970)
    DatabaseManager.insertActiveDispatch(
      taskId: "old", agentId: agentId, chatId: 10, replyToken: "OLD_TOK",
      sessionId: "s", expiresAt: now - 60)
    DatabaseManager.insertActiveDispatch(
      taskId: "fresh", agentId: agentId, chatId: 11, replyToken: "FRESH_TOK",
      sessionId: "s", expiresAt: now + 600)

    DatabaseManager.sweepExpiredDispatches()

    XCTAssertNil(DatabaseManager.lookupBinding(token: "OLD_TOK"))
    XCTAssertNotNil(DatabaseManager.lookupBinding(token: "FRESH_TOK"))
  }

  // MARK: seen_updates (idempotency)

  func testIsUpdateAlreadySeenAndMarkSeenRoundtrip() {
    XCTAssertFalse(DatabaseManager.isUpdateAlreadySeen(agentId: agentId, updateId: 42))
    DatabaseManager.markUpdateSeen(agentId: agentId, updateId: 42)
    XCTAssertTrue(DatabaseManager.isUpdateAlreadySeen(agentId: agentId, updateId: 42))
  }

  func testMarkUpdateSeenIsIdempotent() {
    DatabaseManager.markUpdateSeen(agentId: agentId, updateId: 7)
    DatabaseManager.markUpdateSeen(agentId: agentId, updateId: 7)  // no error from ON CONFLICT
    XCTAssertTrue(DatabaseManager.isUpdateAlreadySeen(agentId: agentId, updateId: 7))
  }

  func testPruneOldSeenUpdatesDropsOnlyAged() {
    // Insert one fresh + one synthetic-old row using the host stub directly.
    DatabaseManager.markUpdateSeen(agentId: agentId, updateId: 100)  // fresh, ~now

    // Force an ancient seen_at (>24h) by going through dbExec directly.
    DatabaseManager.dbExec(
      "INSERT INTO seen_updates (agent_id, update_id, seen_at) VALUES (?1, ?2, ?3)",
      params: DatabaseManager.serializeParams(
        [agentId, 101, Int(Date().timeIntervalSince1970) - 100_000]))

    DatabaseManager.pruneOldSeenUpdates()

    XCTAssertTrue(DatabaseManager.isUpdateAlreadySeen(agentId: agentId, updateId: 100))
    XCTAssertFalse(DatabaseManager.isUpdateAlreadySeen(agentId: agentId, updateId: 101))
  }

  // MARK: schema sanity

  func testInitSchemaIsIdempotent() {
    // Calling initSchema twice should not fail. Already called in setUp.
    DatabaseManager.initSchema()
    DatabaseManager.initSchema()
    // Sanity: still able to insert.
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 9_999)
    XCTAssertNotNil(
      DatabaseManager.getChatSession(agentId: agentId, chatId: 9_999))
  }

  // MARK: schema migration

  func testInitSchemaMigratesPreV4SchemaByDropping() {
    // Stand up the legacy schema (no agent_id column) directly so we can
    // assert that initSchema() detects it and rebuilds the tables.
    for sql in [
      "DROP TABLE IF EXISTS chat_sessions",
      "DROP TABLE IF EXISTS active_dispatches",
      "DROP TABLE IF EXISTS seen_updates",
    ] { DatabaseManager.dbExec(sql, params: "[]") }

    DatabaseManager.dbExec(
      """
      CREATE TABLE chat_sessions (
        chat_id INTEGER PRIMARY KEY,
        session_salt INTEGER NOT NULL DEFAULT 0,
        blocked INTEGER NOT NULL DEFAULT 0,
        last_msg_at INTEGER NOT NULL,
        created_at INTEGER NOT NULL
      )
      """, params: "[]")
    DatabaseManager.dbExec(
      """
      CREATE TABLE active_dispatches (
        task_id TEXT PRIMARY KEY,
        chat_id INTEGER NOT NULL UNIQUE,
        reply_token TEXT NOT NULL UNIQUE,
        session_id TEXT NOT NULL,
        started_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        has_replied INTEGER NOT NULL DEFAULT 0
      )
      """, params: "[]")
    DatabaseManager.dbExec(
      """
      CREATE TABLE seen_updates (
        update_id INTEGER PRIMARY KEY,
        seen_at INTEGER NOT NULL
      )
      """, params: "[]")

    // Seed a row in the legacy schema. After migration this row is gone.
    DatabaseManager.dbExec(
      "INSERT INTO chat_sessions (chat_id, last_msg_at, created_at) VALUES (?1, ?2, ?2)",
      params: DatabaseManager.serializeParams([777, Int(Date().timeIntervalSince1970)]))

    // Run the migration.
    DatabaseManager.initSchema()

    // Pre-migration row is gone — we rebuilt the table.
    XCTAssertNil(DatabaseManager.getChatSession(agentId: agentId, chatId: 777))

    // Post-migration the table has the new agent_id column and is writable.
    let row = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 778)
    XCTAssertEqual(row.chatId, 778)
  }
}
