import XCTest

@testable import osaurus_telegram

final class DatabaseTests: XCTestCase {

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
    let row = DatabaseManager.upsertChatSession(chatId: 100)
    XCTAssertEqual(row.chatId, 100)
    XCTAssertEqual(row.sessionSalt, 0)
    XCTAssertEqual(row.blocked, 0)
  }

  func testUpsertChatSessionPreservesSaltAndBlocked() {
    _ = DatabaseManager.upsertChatSession(chatId: 100)
    DatabaseManager.bumpSessionSalt(chatId: 100)
    DatabaseManager.markChatBlocked(chatId: 100)

    let row = DatabaseManager.upsertChatSession(chatId: 100)
    XCTAssertEqual(row.sessionSalt, 1, "subsequent upsert must not reset salt")
    XCTAssertEqual(row.blocked, 1, "subsequent upsert must not unblock")
  }

  func testBumpSessionSaltIncrementsMonotonically() {
    _ = DatabaseManager.upsertChatSession(chatId: 200)
    DatabaseManager.bumpSessionSalt(chatId: 200)
    DatabaseManager.bumpSessionSalt(chatId: 200)
    DatabaseManager.bumpSessionSalt(chatId: 200)
    XCTAssertEqual(DatabaseManager.getChatSession(chatId: 200)?.sessionSalt, 3)
  }

  func testIsChatBlockedReflectsState() {
    _ = DatabaseManager.upsertChatSession(chatId: 300)
    XCTAssertFalse(DatabaseManager.isChatBlocked(chatId: 300))
    DatabaseManager.markChatBlocked(chatId: 300)
    XCTAssertTrue(DatabaseManager.isChatBlocked(chatId: 300))
  }

  func testGetChatSessionReturnsNilForUnknownChat() {
    XCTAssertNil(DatabaseManager.getChatSession(chatId: 999_999))
  }

  // MARK: active_dispatches

  func testInsertAndLookupBindingByToken() {
    _ = DatabaseManager.upsertChatSession(chatId: 1)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-1", chatId: 1, replyToken: "ABC123",
      sessionId: "session-1", expiresAt: Int(Date().timeIntervalSince1970) + 600)

    let binding = DatabaseManager.lookupBinding(token: "ABC123")
    XCTAssertNotNil(binding)
    XCTAssertEqual(binding?.taskId, "task-1")
    XCTAssertEqual(binding?.chatId, 1)
    XCTAssertEqual(binding?.sessionId, "session-1")
    XCTAssertEqual(binding?.hasReplied, 0)
  }

  func testLookupBindingReturnsNilForUnknownToken() {
    XCTAssertNil(DatabaseManager.lookupBinding(token: "DOES_NOT_EXIST"))
  }

  func testActiveDispatchForChatReturnsLatest() {
    _ = DatabaseManager.upsertChatSession(chatId: 2)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-2", chatId: 2, replyToken: "TOKEN2",
      sessionId: "s-2", expiresAt: Int(Date().timeIntervalSince1970) + 600)
    let active = DatabaseManager.activeDispatch(forChat: 2)
    XCTAssertEqual(active?.taskId, "task-2")
    XCTAssertEqual(active?.replyToken, "TOKEN2")
  }

  func testActiveDispatchUniqueChatIdEnforced() {
    _ = DatabaseManager.upsertChatSession(chatId: 3)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-a", chatId: 3, replyToken: "TOK_A",
      sessionId: "s", expiresAt: Int(Date().timeIntervalSince1970) + 600)
    // Second insert for the same chat should be a no-op due to UNIQUE(chat_id).
    DatabaseManager.insertActiveDispatch(
      taskId: "task-b", chatId: 3, replyToken: "TOK_B",
      sessionId: "s", expiresAt: Int(Date().timeIntervalSince1970) + 600)

    XCTAssertEqual(
      DatabaseManager.activeDispatch(forChat: 3)?.taskId, "task-a",
      "UNIQUE(chat_id) should reject the second insert; first row stays")
    XCTAssertNil(
      DatabaseManager.lookupBinding(token: "TOK_B"),
      "rejected insert must not appear under its token")
  }

  func testMarkRepliedAndHasReplied() {
    _ = DatabaseManager.upsertChatSession(chatId: 4)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-r", chatId: 4, replyToken: "TOK_R",
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
    _ = DatabaseManager.upsertChatSession(chatId: 5)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-d", chatId: 5, replyToken: "TOK_D",
      sessionId: "s", expiresAt: Int(Date().timeIntervalSince1970) + 600)
    XCTAssertNotNil(DatabaseManager.activeDispatch(forChat: 5))
    DatabaseManager.deleteActiveDispatch(taskId: "task-d")
    XCTAssertNil(DatabaseManager.activeDispatch(forChat: 5))
    XCTAssertNil(DatabaseManager.lookupBinding(token: "TOK_D"))
  }

  func testSweepExpiredDispatchesDropsOnlyExpired() {
    _ = DatabaseManager.upsertChatSession(chatId: 10)
    _ = DatabaseManager.upsertChatSession(chatId: 11)
    let now = Int(Date().timeIntervalSince1970)
    DatabaseManager.insertActiveDispatch(
      taskId: "old", chatId: 10, replyToken: "OLD_TOK",
      sessionId: "s", expiresAt: now - 60)
    DatabaseManager.insertActiveDispatch(
      taskId: "fresh", chatId: 11, replyToken: "FRESH_TOK",
      sessionId: "s", expiresAt: now + 600)

    DatabaseManager.sweepExpiredDispatches()

    XCTAssertNil(DatabaseManager.lookupBinding(token: "OLD_TOK"))
    XCTAssertNotNil(DatabaseManager.lookupBinding(token: "FRESH_TOK"))
  }

  // MARK: seen_updates (idempotency)

  func testIsUpdateAlreadySeenAndMarkSeenRoundtrip() {
    XCTAssertFalse(DatabaseManager.isUpdateAlreadySeen(updateId: 42))
    DatabaseManager.markUpdateSeen(updateId: 42)
    XCTAssertTrue(DatabaseManager.isUpdateAlreadySeen(updateId: 42))
  }

  func testMarkUpdateSeenIsIdempotent() {
    DatabaseManager.markUpdateSeen(updateId: 7)
    DatabaseManager.markUpdateSeen(updateId: 7)  // no error from ON CONFLICT
    XCTAssertTrue(DatabaseManager.isUpdateAlreadySeen(updateId: 7))
  }

  func testPruneOldSeenUpdatesDropsOnlyAged() {
    // Insert one fresh + one synthetic-old row using the host stub directly.
    DatabaseManager.markUpdateSeen(updateId: 100)  // fresh, ~now

    // Force an ancient seen_at (>24h) by going through dbExec directly.
    DatabaseManager.dbExec(
      "INSERT INTO seen_updates (update_id, seen_at) VALUES (?1, ?2)",
      params: DatabaseManager.serializeParams(
        [101, Int(Date().timeIntervalSince1970) - 100_000]))

    DatabaseManager.pruneOldSeenUpdates()

    XCTAssertTrue(DatabaseManager.isUpdateAlreadySeen(updateId: 100))
    XCTAssertFalse(DatabaseManager.isUpdateAlreadySeen(updateId: 101))
  }

  // MARK: schema sanity

  func testInitSchemaIsIdempotent() {
    // Calling initSchema twice should not fail. Already called in setUp.
    DatabaseManager.initSchema()
    DatabaseManager.initSchema()
    // Sanity: still able to insert.
    _ = DatabaseManager.upsertChatSession(chatId: 9_999)
    XCTAssertNotNil(DatabaseManager.getChatSession(chatId: 9_999))
  }
}
