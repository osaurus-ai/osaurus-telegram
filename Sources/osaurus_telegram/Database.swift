import Foundation

// MARK: - Database Manager
//
// The plugin keeps three tables in its per-plugin SQLite DB:
//   * chat_sessions      \u2014 one row per chat we've seen; stores session_salt
//                          (bumped on /reset) and a blocked flag.
//   * active_dispatches  \u2014 at most one row per chat (UNIQUE chat_id);
//                          binds a reply_token to a running task + session_id
//                          so reply tools can find their destination.
//   * seen_updates       \u2014 idempotency cache for Telegram update_id retries,
//                          TTL-pruned to 24h.

struct ChatSessionRow {
  let chatId: Int64
  let sessionSalt: Int
  let blocked: Int
}

struct ActiveDispatchRow {
  let taskId: String
  let chatId: Int64
  let replyToken: String
  let sessionId: String
  let expiresAt: Int
  let hasReplied: Int
}

enum DatabaseManager {

  // MARK: - Schema

  static func initSchema() {
    let statements = [
      """
      CREATE TABLE IF NOT EXISTS chat_sessions (
        chat_id        INTEGER PRIMARY KEY,
        session_salt   INTEGER NOT NULL DEFAULT 0,
        blocked        INTEGER NOT NULL DEFAULT 0,
        last_msg_at    INTEGER NOT NULL,
        created_at     INTEGER NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS active_dispatches (
        task_id        TEXT PRIMARY KEY,
        chat_id        INTEGER NOT NULL UNIQUE,
        reply_token    TEXT NOT NULL UNIQUE,
        session_id     TEXT NOT NULL,
        started_at     INTEGER NOT NULL,
        expires_at     INTEGER NOT NULL,
        has_replied    INTEGER NOT NULL DEFAULT 0
      )
      """,
      "CREATE INDEX IF NOT EXISTS idx_dispatches_token ON active_dispatches(reply_token)",
      """
      CREATE TABLE IF NOT EXISTS seen_updates (
        update_id      INTEGER PRIMARY KEY,
        seen_at        INTEGER NOT NULL
      )
      """,
    ]

    for sql in statements {
      dbExec(sql, params: "[]")
    }
  }

  // MARK: - chat_sessions

  /// Inserts or refreshes the chat row, returning the post-upsert state. Always
  /// preserves `session_salt` and `blocked`.
  @discardableResult
  static func upsertChatSession(chatId: Int64) -> ChatSessionRow {
    let now = Int(Date().timeIntervalSince1970)
    let upsert = """
      INSERT INTO chat_sessions (chat_id, session_salt, blocked, last_msg_at, created_at)
      VALUES (?1, 0, 0, ?2, ?2)
      ON CONFLICT(chat_id) DO UPDATE SET last_msg_at = ?2
      """
    dbExec(upsert, params: serializeParams([chatId, now]))
    return getChatSession(chatId: chatId)
      ?? ChatSessionRow(chatId: chatId, sessionSalt: 0, blocked: 0)
  }

  static func getChatSession(chatId: Int64) -> ChatSessionRow? {
    let sql = """
      SELECT chat_id, session_salt, blocked
      FROM chat_sessions
      WHERE chat_id = ?1
      LIMIT 1
      """
    guard let resultStr = dbQuery(sql, params: serializeParams([chatId])),
      let rows = extractRows(resultStr),
      let row = rows.first, row.count >= 3
    else { return nil }
    return ChatSessionRow(
      chatId: int64FromAny(row[0]) ?? chatId,
      sessionSalt: intFromAny(row[1]) ?? 0,
      blocked: intFromAny(row[2]) ?? 0
    )
  }

  static func bumpSessionSalt(chatId: Int64) {
    let sql = """
      UPDATE chat_sessions SET session_salt = session_salt + 1 WHERE chat_id = ?1
      """
    dbExec(sql, params: serializeParams([chatId]))
  }

  static func markChatBlocked(chatId: Int64) {
    let sql = "UPDATE chat_sessions SET blocked = 1 WHERE chat_id = ?1"
    dbExec(sql, params: serializeParams([chatId]))
  }

  static func isChatBlocked(chatId: Int64) -> Bool {
    return (getChatSession(chatId: chatId)?.blocked ?? 0) == 1
  }

  // MARK: - active_dispatches

  static func insertActiveDispatch(
    taskId: String, chatId: Int64, replyToken: String,
    sessionId: String, expiresAt: Int
  ) {
    let now = Int(Date().timeIntervalSince1970)
    let sql = """
      INSERT INTO active_dispatches
        (task_id, chat_id, reply_token, session_id, started_at, expires_at, has_replied)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0)
      """
    dbExec(
      sql,
      params: serializeParams([taskId, chatId, replyToken, sessionId, now, expiresAt])
    )
  }

  static func activeDispatch(forChat chatId: Int64) -> ActiveDispatchRow? {
    let sql = """
      SELECT task_id, chat_id, reply_token, session_id, expires_at, has_replied
      FROM active_dispatches
      WHERE chat_id = ?1
      LIMIT 1
      """
    guard let resultStr = dbQuery(sql, params: serializeParams([chatId])) else { return nil }
    return parseDispatchRow(resultStr)
  }

  static func lookupBinding(token: String) -> ActiveDispatchRow? {
    let sql = """
      SELECT task_id, chat_id, reply_token, session_id, expires_at, has_replied
      FROM active_dispatches
      WHERE reply_token = ?1
      LIMIT 1
      """
    guard let resultStr = dbQuery(sql, params: serializeParams([token])) else { return nil }
    return parseDispatchRow(resultStr)
  }

  static func lookupBindingByTask(taskId: String) -> ActiveDispatchRow? {
    let sql = """
      SELECT task_id, chat_id, reply_token, session_id, expires_at, has_replied
      FROM active_dispatches
      WHERE task_id = ?1
      LIMIT 1
      """
    guard let resultStr = dbQuery(sql, params: serializeParams([taskId])) else { return nil }
    return parseDispatchRow(resultStr)
  }

  static func deleteActiveDispatch(taskId: String) {
    let sql = "DELETE FROM active_dispatches WHERE task_id = ?1"
    dbExec(sql, params: serializeParams([taskId]))
  }

  static func markReplied(taskId: String) {
    let sql = "UPDATE active_dispatches SET has_replied = 1 WHERE task_id = ?1"
    dbExec(sql, params: serializeParams([taskId]))
  }

  static func hasReplied(taskId: String) -> Bool {
    let sql = "SELECT has_replied FROM active_dispatches WHERE task_id = ?1 LIMIT 1"
    guard let resultStr = dbQuery(sql, params: serializeParams([taskId])),
      let rows = extractRows(resultStr),
      let row = rows.first, !row.isEmpty
    else { return false }
    return (intFromAny(row[0]) ?? 0) == 1
  }

  /// Removes bindings whose expires_at has passed. Run periodically as a
  /// safety net for cases where the host crashed before delivering the
  /// terminal task event.
  static func sweepExpiredDispatches() {
    let now = Int(Date().timeIntervalSince1970)
    dbExec(
      "DELETE FROM active_dispatches WHERE expires_at < ?1",
      params: serializeParams([now])
    )
  }

  // MARK: - seen_updates

  static func isUpdateAlreadySeen(updateId: Int) -> Bool {
    let sql = "SELECT 1 FROM seen_updates WHERE update_id = ?1 LIMIT 1"
    guard let resultStr = dbQuery(sql, params: serializeParams([updateId])),
      let rows = extractRows(resultStr)
    else { return false }
    return !rows.isEmpty
  }

  static func markUpdateSeen(updateId: Int) {
    let now = Int(Date().timeIntervalSince1970)
    let sql = """
      INSERT INTO seen_updates (update_id, seen_at) VALUES (?1, ?2)
      ON CONFLICT(update_id) DO NOTHING
      """
    dbExec(sql, params: serializeParams([updateId, now]))
  }

  /// Drops idempotency rows older than 24h. Cheap; called inline from the
  /// webhook hot path after marking a new update.
  static func pruneOldSeenUpdates() {
    let cutoff = Int(Date().timeIntervalSince1970) - 86_400
    dbExec(
      "DELETE FROM seen_updates WHERE seen_at < ?1",
      params: serializeParams([cutoff])
    )
  }

  // MARK: - Row helpers

  private static func parseDispatchRow(_ resultStr: String) -> ActiveDispatchRow? {
    guard let rows = extractRows(resultStr),
      let row = rows.first, row.count >= 6
    else { return nil }
    return ActiveDispatchRow(
      taskId: "\(row[0])",
      chatId: int64FromAny(row[1]) ?? 0,
      replyToken: "\(row[2])",
      sessionId: "\(row[3])",
      expiresAt: intFromAny(row[4]) ?? 0,
      hasReplied: intFromAny(row[5]) ?? 0
    )
  }

  private static func intFromAny(_ value: Any) -> Int? {
    if let i = value as? Int { return i }
    if let i = value as? Int64 { return Int(i) }
    if let d = value as? Double { return Int(d) }
    if let s = value as? String { return Int(s) }
    return nil
  }

  private static func int64FromAny(_ value: Any) -> Int64? {
    if let i = value as? Int64 { return i }
    if let i = value as? Int { return Int64(i) }
    if let d = value as? Double { return Int64(d) }
    if let s = value as? String { return Int64(s) }
    return nil
  }

  // MARK: - Generic Helpers

  /// Extracts row arrays from a db_query result string.
  /// Handles both `{"rows": [[...]]}` (host format) and bare `[[...]]`.
  static func extractRows(_ resultStr: String) -> [[Any]]? {
    guard let data = resultStr.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data)
    else {
      logDebug(
        "extractRows: failed to parse JSON (\(resultStr.count) chars): \(String(resultStr.prefix(200)))"
      )
      return nil
    }

    if let dict = json as? [String: Any],
      let rows = dict["rows"] as? [[Any]]
    {
      return rows
    }

    if let rows = json as? [[Any]] {
      return rows
    }

    logDebug("extractRows: JSON parsed but no rows found in result")
    return nil
  }

  static func dbExec(_ sql: String, params: String) {
    guard let exec = hostAPI?.pointee.db_exec else {
      logError("db_exec not available")
      return
    }
    let result = sql.withCString { sqlPtr in
      params.withCString { paramsPtr in
        exec(sqlPtr, paramsPtr)
      }
    }
    if let result {
      let str = String(cString: result)
      if str.contains("\"error\"") {
        logWarn("DB exec error: \(str)")
      }
    }
  }

  static func dbQuery(_ sql: String, params: String) -> String? {
    guard let query = hostAPI?.pointee.db_query else {
      logDebug("dbQuery: db_query not available")
      return nil
    }
    let result: String? = sql.withCString { sqlPtr in
      params.withCString { paramsPtr in
        guard let resultPtr = query(sqlPtr, paramsPtr) else { return nil }
        return String(cString: resultPtr)
      }
    }
    if result == nil {
      logDebug("dbQuery: query returned nil for sql=\(String(sql.prefix(100)))")
    }
    return result
  }

  /// Serializes an array of mixed values to a JSON array string for SQLite params.
  static func serializeParams(_ values: [Any]) -> String {
    let normalized = values.map { value -> Any in
      if let i64 = value as? Int64 { return NSNumber(value: i64) }
      return value
    }
    guard let data = try? JSONSerialization.data(withJSONObject: normalized),
      let str = String(data: data, encoding: .utf8)
    else {
      logWarn("serializeParams: failed to serialize \(values.count) values, returning empty array")
      return "[]"
    }
    return str
  }
}
