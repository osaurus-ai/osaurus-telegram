import Foundation

// MARK: - Database Manager
//
// The plugin keeps three tables in its per-plugin SQLite DB. As of schema v2
// (ABI v4 migration) every table is partitioned by `agent_id` so two agents
// loaded into the same plugin instance can't trample each other's rows.
// Telegram chat_ids are NOT bot-scoped — the same Telegram user talking to
// two different bots produces the same chat_id, which would otherwise
// collide on the old PK / UNIQUE constraints.
//
//   * chat_sessions      \u2014 (agent_id, chat_id) PK; session_salt bumped on /reset
//                          plus a blocked flag.
//   * active_dispatches  \u2014 task_id PK; UNIQUE (agent_id, chat_id) so each
//                          (agent, chat) has at most one in-flight dispatch.
//                          reply_token stays globally unique because tokens
//                          are random and the lookup is one-way.
//   * seen_updates       \u2014 (agent_id, update_id) PK; idempotency cache for
//                          Telegram retries, TTL-pruned to 24h.

struct ChatSessionRow {
  let chatId: Int64
  let sessionSalt: Int
  let blocked: Int
}

struct ActiveDispatchRow {
  let taskId: String
  let agentId: String
  let chatId: Int64
  let replyToken: String
  let sessionId: String
  let expiresAt: Int
  let hasReplied: Int
}

enum DatabaseManager {

  // MARK: - Schema

  static func initSchema() {
    // Detect pre-v2 schema (no agent_id column on chat_sessions). If present,
    // drop and recreate every table — the data is mostly transient (10-min
    // dispatches, 24-hour seen_updates) and chat_sessions only carries a
    // session salt that resets cleanly to zero.
    if tableExists("chat_sessions"), !columnExists(table: "chat_sessions", column: "agent_id") {
      logInfo(
        "Database: detected pre-ABI-v4 schema (no agent_id column); dropping legacy tables")
      for sql in [
        "DROP TABLE IF EXISTS chat_sessions",
        "DROP TABLE IF EXISTS active_dispatches",
        "DROP TABLE IF EXISTS seen_updates",
      ] {
        dbExec(sql, params: "[]")
      }
    }

    let statements = [
      """
      CREATE TABLE IF NOT EXISTS chat_sessions (
        agent_id       TEXT    NOT NULL,
        chat_id        INTEGER NOT NULL,
        session_salt   INTEGER NOT NULL DEFAULT 0,
        blocked        INTEGER NOT NULL DEFAULT 0,
        last_msg_at    INTEGER NOT NULL,
        created_at     INTEGER NOT NULL,
        PRIMARY KEY (agent_id, chat_id)
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS active_dispatches (
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
      """,
      "CREATE INDEX IF NOT EXISTS idx_dispatches_token ON active_dispatches(reply_token)",
      """
      CREATE TABLE IF NOT EXISTS seen_updates (
        agent_id       TEXT NOT NULL,
        update_id      INTEGER NOT NULL,
        seen_at        INTEGER NOT NULL,
        PRIMARY KEY (agent_id, update_id)
      )
      """,
    ]

    for sql in statements {
      dbExec(sql, params: "[]")
    }
  }

  // MARK: - Schema introspection

  /// True if a table with `name` exists in the current SQLite database.
  private static func tableExists(_ name: String) -> Bool {
    let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1 LIMIT 1"
    guard let resultStr = dbQuery(sql, params: serializeParams([name])),
      let rows = extractRows(resultStr)
    else { return false }
    return !rows.isEmpty
  }

  /// True if `table` has a column named `column`. Uses `PRAGMA table_info`,
  /// which returns one row per column — column name is the second field.
  private static func columnExists(table: String, column: String) -> Bool {
    // PRAGMA can't be parameterised in SQLite; the table name is a literal
    // we control so injection isn't a concern.
    let sql = "PRAGMA table_info(\(table))"
    guard let resultStr = dbQuery(sql, params: "[]"),
      let rows = extractRows(resultStr)
    else { return false }
    for row in rows where row.count >= 2 {
      if let name = row[1] as? String, name == column { return true }
    }
    return false
  }

  // MARK: - chat_sessions

  /// Inserts or refreshes the chat row, returning the post-upsert state. Always
  /// preserves `session_salt` and `blocked`.
  @discardableResult
  static func upsertChatSession(agentId: String, chatId: Int64) -> ChatSessionRow {
    let now = Int(Date().timeIntervalSince1970)
    let upsert = """
      INSERT INTO chat_sessions (agent_id, chat_id, session_salt, blocked, last_msg_at, created_at)
      VALUES (?1, ?2, 0, 0, ?3, ?3)
      ON CONFLICT(agent_id, chat_id) DO UPDATE SET last_msg_at = ?3
      """
    dbExec(upsert, params: serializeParams([agentId, chatId, now]))
    return getChatSession(agentId: agentId, chatId: chatId)
      ?? ChatSessionRow(chatId: chatId, sessionSalt: 0, blocked: 0)
  }

  static func getChatSession(agentId: String, chatId: Int64) -> ChatSessionRow? {
    let sql = """
      SELECT chat_id, session_salt, blocked
      FROM chat_sessions
      WHERE agent_id = ?1 AND chat_id = ?2
      LIMIT 1
      """
    guard let resultStr = dbQuery(sql, params: serializeParams([agentId, chatId])),
      let rows = extractRows(resultStr),
      let row = rows.first, row.count >= 3
    else { return nil }
    return ChatSessionRow(
      chatId: int64FromAny(row[0]) ?? chatId,
      sessionSalt: intFromAny(row[1]) ?? 0,
      blocked: intFromAny(row[2]) ?? 0
    )
  }

  static func bumpSessionSalt(agentId: String, chatId: Int64) {
    let sql = """
      UPDATE chat_sessions SET session_salt = session_salt + 1
      WHERE agent_id = ?1 AND chat_id = ?2
      """
    dbExec(sql, params: serializeParams([agentId, chatId]))
  }

  static func markChatBlocked(agentId: String, chatId: Int64) {
    let sql =
      "UPDATE chat_sessions SET blocked = 1 WHERE agent_id = ?1 AND chat_id = ?2"
    dbExec(sql, params: serializeParams([agentId, chatId]))
  }

  static func isChatBlocked(agentId: String, chatId: Int64) -> Bool {
    return (getChatSession(agentId: agentId, chatId: chatId)?.blocked ?? 0) == 1
  }

  // MARK: - active_dispatches

  static func insertActiveDispatch(
    taskId: String, agentId: String, chatId: Int64, replyToken: String,
    sessionId: String, expiresAt: Int
  ) {
    let now = Int(Date().timeIntervalSince1970)
    let sql = """
      INSERT INTO active_dispatches
        (task_id, agent_id, chat_id, reply_token, session_id, started_at, expires_at, has_replied)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 0)
      """
    dbExec(
      sql,
      params: serializeParams([taskId, agentId, chatId, replyToken, sessionId, now, expiresAt])
    )
  }

  static func activeDispatch(agentId: String, forChat chatId: Int64) -> ActiveDispatchRow? {
    let sql = """
      SELECT task_id, agent_id, chat_id, reply_token, session_id, expires_at, has_replied
      FROM active_dispatches
      WHERE agent_id = ?1 AND chat_id = ?2
      LIMIT 1
      """
    guard let resultStr = dbQuery(sql, params: serializeParams([agentId, chatId])) else {
      return nil
    }
    return parseDispatchRow(resultStr)
  }

  /// Looks up a dispatch by reply_token. reply_token is globally unique so
  /// no agent_id is required here — callers can read `row.agentId` from the
  /// returned row to verify the binding belongs to the agent that owns the
  /// current callback frame.
  static func lookupBinding(token: String) -> ActiveDispatchRow? {
    let sql = """
      SELECT task_id, agent_id, chat_id, reply_token, session_id, expires_at, has_replied
      FROM active_dispatches
      WHERE reply_token = ?1
      LIMIT 1
      """
    guard let resultStr = dbQuery(sql, params: serializeParams([token])) else { return nil }
    return parseDispatchRow(resultStr)
  }

  static func lookupBindingByTask(taskId: String) -> ActiveDispatchRow? {
    let sql = """
      SELECT task_id, agent_id, chat_id, reply_token, session_id, expires_at, has_replied
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

  static func isUpdateAlreadySeen(agentId: String, updateId: Int) -> Bool {
    let sql =
      "SELECT 1 FROM seen_updates WHERE agent_id = ?1 AND update_id = ?2 LIMIT 1"
    guard let resultStr = dbQuery(sql, params: serializeParams([agentId, updateId])),
      let rows = extractRows(resultStr)
    else { return false }
    return !rows.isEmpty
  }

  static func markUpdateSeen(agentId: String, updateId: Int) {
    let now = Int(Date().timeIntervalSince1970)
    let sql = """
      INSERT INTO seen_updates (agent_id, update_id, seen_at) VALUES (?1, ?2, ?3)
      ON CONFLICT(agent_id, update_id) DO NOTHING
      """
    dbExec(sql, params: serializeParams([agentId, updateId, now]))
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
      let row = rows.first, row.count >= 7
    else { return nil }
    return ActiveDispatchRow(
      taskId: "\(row[0])",
      agentId: "\(row[1])",
      chatId: int64FromAny(row[2]) ?? 0,
      replyToken: "\(row[3])",
      sessionId: "\(row[4])",
      expiresAt: intFromAny(row[5]) ?? 0,
      hasReplied: intFromAny(row[6]) ?? 0
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
