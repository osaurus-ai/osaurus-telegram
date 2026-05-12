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

  /// Schema v3 allows multiple in-flight rows per (agent, chat). The
  /// previous v2 schema enforced `UNIQUE(agent_id, chat_id)` and silently
  /// rejected the second insert — this test pins the new behaviour so a
  /// regression that reintroduces the constraint is caught immediately.
  func testActiveDispatchAllowsMultipleRowsPerChat() {
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 3)
    let now = Int(Date().timeIntervalSince1970)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-a", agentId: agentId, chatId: 3, replyToken: "TOK_A",
      sessionId: "s", expiresAt: now + 600)
    // started_at is stored in milliseconds, so a 2ms sleep is enough to
    // guarantee strict ordering between two back-to-back inserts.
    Thread.sleep(forTimeInterval: 0.002)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-b", agentId: agentId, chatId: 3, replyToken: "TOK_B",
      sessionId: "s", expiresAt: now + 600)

    XCTAssertNotNil(
      DatabaseManager.lookupBinding(token: "TOK_A"),
      "first dispatch must survive the second insert")
    XCTAssertNotNil(
      DatabaseManager.lookupBinding(token: "TOK_B"),
      "second concurrent dispatch must be insertable")
    XCTAssertEqual(
      DatabaseManager.activeDispatch(agentId: agentId, forChat: 3)?.taskId, "task-b",
      "activeDispatch must return the latest row by started_at")
  }

  func testPriorActiveDispatchSkipsCurrentToken() {
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 31)
    let now = Int(Date().timeIntervalSince1970)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-old", agentId: agentId, chatId: 31, replyToken: "TOK_OLD",
      sessionId: "s", expiresAt: now + 600)
    Thread.sleep(forTimeInterval: 0.002)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-new", agentId: agentId, chatId: 31, replyToken: "TOK_NEW",
      sessionId: "s", expiresAt: now + 600)

    // Soft-interrupt branch in handleWebhook just inserted the new row and
    // now asks for "the previous in-flight row, not me".
    let prior = DatabaseManager.priorActiveDispatch(
      agentId: agentId, forChat: 31, excluding: "TOK_NEW")
    XCTAssertEqual(prior?.taskId, "task-old")
    XCTAssertEqual(prior?.replyToken, "TOK_OLD")

    // When only the current row exists, prior must be nil — otherwise
    // handleWebhook would interrupt itself.
    DatabaseManager.deleteActiveDispatch(taskId: "task-old")
    XCTAssertNil(
      DatabaseManager.priorActiveDispatch(
        agentId: agentId, forChat: 31, excluding: "TOK_NEW"))
  }

  func testUpdateTaskIdPatchesPlaceholderRow() {
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 32)
    let token = "TOK_PRE"
    DatabaseManager.insertActiveDispatch(
      taskId: pendingTaskId(for: token), agentId: agentId, chatId: 32,
      replyToken: token, sessionId: "s",
      expiresAt: Int(Date().timeIntervalSince1970) + 600)

    // Pre-patch state: the placeholder row is the binding under the token,
    // but the lookup by real task_id should miss.
    XCTAssertEqual(
      DatabaseManager.lookupBinding(token: token)?.taskId,
      pendingTaskId(for: token))
    XCTAssertNil(DatabaseManager.lookupBindingByTask(taskId: "real-task"))

    DatabaseManager.updateTaskId(replyToken: token, newTaskId: "real-task")

    // Post-patch: the row is the same (PK didn't move), but its task_id is
    // now the real one; both directions of lookup agree.
    XCTAssertEqual(DatabaseManager.lookupBinding(token: token)?.taskId, "real-task")
    XCTAssertEqual(
      DatabaseManager.lookupBindingByTask(taskId: "real-task")?.replyToken, token)
  }

  func testUpdateTaskIdNoOpForUnknownToken() {
    // Patching a row that isn't there must not invent one — keeps the
    // dispatch-error unwind path simple.
    DatabaseManager.updateTaskId(replyToken: "GHOST", newTaskId: "x")
    XCTAssertNil(DatabaseManager.lookupBinding(token: "GHOST"))
  }

  func testDeleteActiveDispatchByReplyTokenRemovesPlaceholderOnly() {
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 33)
    let now = Int(Date().timeIntervalSince1970)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-keep", agentId: agentId, chatId: 33, replyToken: "TOK_KEEP",
      sessionId: "s", expiresAt: now + 600)
    DatabaseManager.insertActiveDispatch(
      taskId: pendingTaskId(for: "TOK_UNDO"), agentId: agentId, chatId: 33,
      replyToken: "TOK_UNDO", sessionId: "s", expiresAt: now + 600)

    // Unwind the placeholder row only.
    DatabaseManager.deleteActiveDispatch(replyToken: "TOK_UNDO")

    XCTAssertNil(DatabaseManager.lookupBinding(token: "TOK_UNDO"))
    XCTAssertNotNil(
      DatabaseManager.lookupBinding(token: "TOK_KEEP"),
      "sibling rows for the same chat must be unaffected")
  }

  /// The artifact auto-forward hook resolves "which chat?" via this
  /// selector — and unlike `activeDispatch(forChat:)`, it must reach
  /// across chats and pick the most recently dispatched row for the
  /// agent. Two dispatches in different chats; the latter must win.
  func testLatestActiveDispatchReturnsMostRecentAcrossChats() {
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 40)
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 41)
    let now = Int(Date().timeIntervalSince1970)
    DatabaseManager.insertActiveDispatch(
      taskId: "first", agentId: agentId, chatId: 40, replyToken: "TOK_FIRST",
      sessionId: "s", expiresAt: now + 600)
    Thread.sleep(forTimeInterval: 0.002)
    DatabaseManager.insertActiveDispatch(
      taskId: "second", agentId: agentId, chatId: 41, replyToken: "TOK_SECOND",
      sessionId: "s", expiresAt: now + 600)

    let latest = DatabaseManager.latestActiveDispatch(agentId: agentId)
    XCTAssertEqual(
      latest?.taskId, "second",
      "the artifact hook must route to the most recent in-flight chat")
    XCTAssertEqual(latest?.chatId, 41)
  }

  /// When the agent has no in-flight turns at all, the artifact hook
  /// must skip cleanly rather than uploading to a stale chat.
  func testLatestActiveDispatchReturnsNilWhenAgentHasNoneInFlight() {
    XCTAssertNil(DatabaseManager.latestActiveDispatch(agentId: agentId))

    // A row for a different agent must not leak through.
    _ = DatabaseManager.upsertChatSession(agentId: "agent-other", chatId: 50)
    DatabaseManager.insertActiveDispatch(
      taskId: "other-task", agentId: "agent-other", chatId: 50,
      replyToken: "TOK_OTHER_AGENT", sessionId: "s",
      expiresAt: Int(Date().timeIntervalSince1970) + 600)
    XCTAssertNil(
      DatabaseManager.latestActiveDispatch(agentId: agentId),
      "another agent's in-flight row must not be visible to this agent")
  }

  /// `latestActiveDispatchAcrossAgents` is the no-frame fallback for the
  /// artifact auto-forward hook. Two agents in flight, the most recent
  /// must win — that's the only useful heuristic when the host fires
  /// `invoke(type: "artifact")` outside any per-agent frame.
  func testLatestActiveDispatchAcrossAgentsReturnsMostRecent() {
    _ = DatabaseManager.upsertChatSession(agentId: "agent-a", chatId: 60)
    _ = DatabaseManager.upsertChatSession(agentId: "agent-b", chatId: 61)
    let now = Int(Date().timeIntervalSince1970)
    DatabaseManager.insertActiveDispatch(
      taskId: "older", agentId: "agent-a", chatId: 60, replyToken: "TOK_A",
      sessionId: "s", expiresAt: now + 600)
    Thread.sleep(forTimeInterval: 0.002)
    DatabaseManager.insertActiveDispatch(
      taskId: "newer", agentId: "agent-b", chatId: 61, replyToken: "TOK_B",
      sessionId: "s", expiresAt: now + 600)

    let row = DatabaseManager.latestActiveDispatchAcrossAgents()
    XCTAssertEqual(row?.taskId, "newer")
    XCTAssertEqual(row?.agentId, "agent-b")
    XCTAssertEqual(row?.chatId, 61)
  }

  func testLatestActiveDispatchAcrossAgentsReturnsNilWhenEmpty() {
    XCTAssertNil(
      DatabaseManager.latestActiveDispatchAcrossAgents(),
      "with no in-flight rows the artifact fallback must skip")
  }

  func testAllActiveDispatchesReturnsEveryRowForChat() {
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 34)
    let now = Int(Date().timeIntervalSince1970)
    DatabaseManager.insertActiveDispatch(
      taskId: "t-a", agentId: agentId, chatId: 34, replyToken: "TOK_AA",
      sessionId: "s", expiresAt: now + 600)
    Thread.sleep(forTimeInterval: 0.002)
    DatabaseManager.insertActiveDispatch(
      taskId: "t-b", agentId: agentId, chatId: 34, replyToken: "TOK_BB",
      sessionId: "s", expiresAt: now + 600)
    // Row for a different chat must be excluded.
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 35)
    DatabaseManager.insertActiveDispatch(
      taskId: "t-other", agentId: agentId, chatId: 35, replyToken: "TOK_OTHER",
      sessionId: "s", expiresAt: now + 600)

    let rows = DatabaseManager.allActiveDispatches(agentId: agentId, forChat: 34)
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(
      rows.map { $0.taskId }, ["t-b", "t-a"],
      "rows must come back in started_at DESC order")
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

  // MARK: incoming_message_id round-trip + migration

  func testIncomingMessageIdRoundTrips() {
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 909)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-eye", agentId: agentId, chatId: 909, replyToken: "TOK_EYE",
      sessionId: "s", expiresAt: Int(Date().timeIntervalSince1970) + 600,
      incomingMessageId: 42)

    let binding = DatabaseManager.lookupBinding(token: "TOK_EYE")
    XCTAssertEqual(
      binding?.incomingMessageId, 42,
      "incoming_message_id must persist so the safety net + clearer can address it")
  }

  func testIncomingMessageIdDefaultsToZeroWhenAbsent() {
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: 910)
    // Older callers (and most existing test seeds) omit the new arg —
    // it must default to 0, which our reaction helpers treat as
    // "no source message recorded; skip the call".
    DatabaseManager.insertActiveDispatch(
      taskId: "task-no-eye", agentId: agentId, chatId: 910, replyToken: "TOK_NO_EYE",
      sessionId: "s", expiresAt: Int(Date().timeIntervalSince1970) + 600)
    XCTAssertEqual(
      DatabaseManager.lookupBinding(token: "TOK_NO_EYE")?.incomingMessageId, 0)
  }

  /// Pre-reaction schema (v3 without `incoming_message_id`) must be
  /// detected and rebuilt by `initSchema` — the data is transient so
  /// dropping the row is harmless, but failing to detect would surface
  /// as "no such column" errors at runtime.
  func testInitSchemaMigratesPreReactionActiveDispatches() {
    DatabaseManager.dbExec("DROP TABLE IF EXISTS active_dispatches", params: "[]")
    DatabaseManager.dbExec(
      """
      CREATE TABLE active_dispatches (
        reply_token    TEXT PRIMARY KEY,
        task_id        TEXT NOT NULL,
        agent_id       TEXT NOT NULL,
        chat_id        INTEGER NOT NULL,
        session_id     TEXT NOT NULL,
        started_at     INTEGER NOT NULL,
        expires_at     INTEGER NOT NULL,
        has_replied    INTEGER NOT NULL DEFAULT 0
      )
      """, params: "[]")
    DatabaseManager.dbExec(
      """
      INSERT INTO active_dispatches
        (task_id, agent_id, chat_id, reply_token, session_id, started_at, expires_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
      """,
      params: DatabaseManager.serializeParams(
        [
          "pre-reaction", agentId, 911, "PRE_REACT", "s",
          Int(Date().timeIntervalSince1970),
          Int(Date().timeIntervalSince1970) + 600,
        ]))
    // Sanity check that the row landed using a column-agnostic count
    // (we can't use lookupBinding here because its SELECT references
    // the new incoming_message_id column that doesn't exist yet).
    XCTAssertEqual(legacyRowCount(token: "PRE_REACT"), 1)

    DatabaseManager.initSchema()

    XCTAssertNil(
      DatabaseManager.lookupBinding(token: "PRE_REACT"),
      "pre-reaction row must be dropped during the column-add migration")

    // Schema is now writable with the new column.
    DatabaseManager.insertActiveDispatch(
      taskId: "post", agentId: agentId, chatId: 912, replyToken: "POST_REACT",
      sessionId: "s", expiresAt: Int(Date().timeIntervalSince1970) + 600,
      incomingMessageId: 7)
    XCTAssertEqual(
      DatabaseManager.lookupBinding(token: "POST_REACT")?.incomingMessageId, 7)
  }

  func testInitSchemaMigratesV2ActiveDispatchesToReplyTokenPK() {
    // Stand up the v2 active_dispatches table (task_id PK + UNIQUE(agent_id,
    // chat_id)) directly so we can assert that initSchema() detects the
    // outdated PK and rebuilds the table.
    DatabaseManager.dbExec("DROP TABLE IF EXISTS active_dispatches", params: "[]")
    DatabaseManager.dbExec(
      """
      CREATE TABLE active_dispatches (
        task_id        TEXT PRIMARY KEY,
        agent_id       TEXT NOT NULL,
        chat_id        INTEGER NOT NULL,
        reply_token    TEXT NOT NULL UNIQUE,
        session_id     TEXT NOT NULL,
        started_at     INTEGER NOT NULL,
        expires_at     INTEGER NOT NULL,
        has_replied    INTEGER NOT NULL DEFAULT 0,
        UNIQUE (agent_id, chat_id)
      )
      """, params: "[]")
    // Seed a row in the legacy schema; after migration it should be gone.
    DatabaseManager.dbExec(
      """
      INSERT INTO active_dispatches
        (task_id, agent_id, chat_id, reply_token, session_id, started_at, expires_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
      """,
      params: DatabaseManager.serializeParams(
        [
          "legacy-task", agentId, 8_888, "LEGACY_TOK", "s",
          Int(Date().timeIntervalSince1970),
          Int(Date().timeIntervalSince1970) + 600,
        ]))
    // Sanity-check insertion via a column-agnostic count; lookupBinding
    // can't be used here because its SELECT references columns the
    // legacy schema doesn't have.
    XCTAssertEqual(legacyRowCount(token: "LEGACY_TOK"), 1)

    // Run the migration.
    DatabaseManager.initSchema()

    // Legacy row is gone — we rebuilt the table.
    XCTAssertNil(DatabaseManager.lookupBinding(token: "LEGACY_TOK"))

    // Post-migration: schema now allows two in-flight rows for the same
    // (agent, chat), which the v2 UNIQUE constraint would have rejected.
    let now = Int(Date().timeIntervalSince1970)
    DatabaseManager.insertActiveDispatch(
      taskId: "post-a", agentId: agentId, chatId: 8_889,
      replyToken: "POST_A", sessionId: "s", expiresAt: now + 600)
    DatabaseManager.insertActiveDispatch(
      taskId: "post-b", agentId: agentId, chatId: 8_889,
      replyToken: "POST_B", sessionId: "s", expiresAt: now + 600)
    XCTAssertNotNil(DatabaseManager.lookupBinding(token: "POST_A"))
    XCTAssertNotNil(DatabaseManager.lookupBinding(token: "POST_B"))
  }

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

  // MARK: helpers

  /// Counts rows in `active_dispatches` matching the given reply_token via
  /// a column-agnostic SQL query. Used by migration tests to verify legacy
  /// rows landed in the previous schema without going through the
  /// production accessors (which now SELECT columns the legacy schema
  /// doesn't have).
  private func legacyRowCount(token: String) -> Int {
    let resultStr =
      DatabaseManager.dbQuery(
        "SELECT COUNT(*) FROM active_dispatches WHERE reply_token = ?1",
        params: DatabaseManager.serializeParams([token])) ?? "{}"
    guard let rows = DatabaseManager.extractRows(resultStr),
      let row = rows.first, let count = row.first as? Int
    else { return 0 }
    return count
  }
}
