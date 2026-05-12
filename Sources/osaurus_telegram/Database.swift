import Foundation

// MARK: - Database Manager
//
// Three tables in a per-plugin SQLite DB. All tables are partitioned by
// `agent_id` (schema v2 / ABI v4) because Telegram chat_ids are user-
// scoped, not bot-scoped — the same chat_id can mean different things to
// two agents sharing the plugin.
//
//   * chat_sessions      — (agent_id, chat_id) PK. session_salt + blocked.
//   * active_dispatches  — reply_token PK (schema v3). Pre-inserted BEFORE
//                          `dispatch` so a fast agent can't race past us
//                          and hit `stale_token`. The placeholder task_id
//                          is patched by `updateTaskId` once dispatch
//                          returns. Multiple in-flight rows per
//                          (agent_id, chat_id) coexist and age out under
//                          the 10-minute TTL sweep.
//   * seen_updates       — (agent_id, update_id) PK; Telegram-retry
//                          idempotency cache, pruned to 24h.

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
  /// Telegram message_id of the user message that triggered this dispatch.
  /// Used to set/clear the "loading" 👀 reaction. 0 means "unknown" (older
  /// rows / synthetic test rows without a real Telegram source).
  let incomingMessageId: Int64
}

enum DatabaseManager {

  // MARK: - Schema

  static func initSchema() {
    // Migrations are drop-and-rebuild. Every table is short-lived
    // (10-min dispatches, 24h dedup, salts default to zero) so losing
    // rows is harmless.

    // Pre-v2 (no agent_id column) — drop everything.
    if tableExists("chat_sessions"), !columnExists(table: "chat_sessions", column: "agent_id") {
      logInfo("Database: detected pre-ABI-v4 schema; dropping legacy tables")
      for sql in [
        "DROP TABLE IF EXISTS chat_sessions",
        "DROP TABLE IF EXISTS active_dispatches",
        "DROP TABLE IF EXISTS seen_updates",
      ] {
        dbExec(sql, params: "[]")
      }
    }

    // v2 active_dispatches (task_id PK) → v3 (reply_token PK).
    if tableExists("active_dispatches"),
      primaryKeyColumn(table: "active_dispatches") != "reply_token"
    {
      logInfo("Database: detected v2 active_dispatches; rebuilding with reply_token PK")
      dbExec("DROP TABLE IF EXISTS active_dispatches", params: "[]")
    }

    // v3 → v3.1: incoming_message_id column added so the loading-eye
    // reaction can address the user's original Telegram message at
    // terminal/clear time. The row data is transient (10-min TTL) so
    // dropping is harmless.
    if tableExists("active_dispatches"),
      !columnExists(table: "active_dispatches", column: "incoming_message_id")
    {
      logInfo("Database: detected pre-reaction active_dispatches; rebuilding")
      dbExec("DROP TABLE IF EXISTS active_dispatches", params: "[]")
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
        reply_token         TEXT PRIMARY KEY,
        task_id             TEXT NOT NULL,
        agent_id            TEXT NOT NULL,
        chat_id             INTEGER NOT NULL,
        session_id          TEXT NOT NULL,
        started_at          INTEGER NOT NULL,
        expires_at          INTEGER NOT NULL,
        has_replied         INTEGER NOT NULL DEFAULT 0,
        incoming_message_id INTEGER NOT NULL DEFAULT 0
      )
      """,
      "CREATE INDEX IF NOT EXISTS idx_dispatches_task ON active_dispatches(task_id)",
      "CREATE INDEX IF NOT EXISTS idx_dispatches_chat "
        + "ON active_dispatches(agent_id, chat_id, started_at)",
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

  /// Returns the name of the single-column primary key for `table`, or nil
  /// if the table doesn't exist or has a composite / no PK. `PRAGMA
  /// table_info` row layout is `(cid, name, type, notnull, dflt_value, pk)`
  /// where `pk` is 0 for non-key columns and 1+ for key columns (the value
  /// is the position within a composite PK). For a single-column PK,
  /// exactly one row has pk=1.
  private static func primaryKeyColumn(table: String) -> String? {
    let sql = "PRAGMA table_info(\(table))"
    guard let resultStr = dbQuery(sql, params: "[]"),
      let rows = extractRows(resultStr)
    else { return nil }
    var pkColumns: [String] = []
    for row in rows where row.count >= 6 {
      if let pk = intFromAny(row[5]), pk > 0, let name = row[1] as? String {
        pkColumns.append(name)
      }
    }
    return pkColumns.count == 1 ? pkColumns.first : nil
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
    sessionId: String, expiresAt: Int, incomingMessageId: Int64 = 0
  ) {
    // started_at is an ordering key (not a wall-clock); milliseconds give
    // rapid-fire turns and unit tests strict ordering. expires_at stays
    // in seconds — they're never compared.
    let nowMillis = Int(Date().timeIntervalSince1970 * 1000)
    let sql = """
      INSERT INTO active_dispatches
        (task_id, agent_id, chat_id, reply_token, session_id,
         started_at, expires_at, has_replied, incoming_message_id)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 0, ?8)
      """
    dbExec(
      sql,
      params: serializeParams(
        [
          taskId, agentId, chatId, replyToken, sessionId,
          nowMillis, expiresAt, incomingMessageId,
        ]))
  }

  /// Returns the most recently dispatched row for `(agentId, chatId)` or nil
  /// if no dispatches are in flight. Multiple rows can coexist for the same
  /// chat (each turn pre-inserts before `dispatch`); only the latest matters
  /// for the soft-interrupt branch in `handleWebhook`.
  static func activeDispatch(agentId: String, forChat chatId: Int64) -> ActiveDispatchRow? {
    let sql = """
      SELECT task_id, agent_id, chat_id, reply_token, session_id, expires_at, has_replied, incoming_message_id
      FROM active_dispatches
      WHERE agent_id = ?1 AND chat_id = ?2
      ORDER BY started_at DESC
      LIMIT 1
      """
    guard let resultStr = dbQuery(sql, params: serializeParams([agentId, chatId])) else {
      return nil
    }
    return parseDispatchRow(resultStr)
  }

  /// Returns the most recently dispatched in-flight row for `agentId` across
  /// all chats. Used by the artifact auto-forward hook because the host's
  /// `invoke(type: "artifact", ...)` payload doesn't carry chat context — the
  /// only sane heuristic is "the chat the agent is currently working on,"
  /// which translates to the latest pre-inserted dispatch row for the agent.
  static func latestActiveDispatch(agentId: String) -> ActiveDispatchRow? {
    let sql = """
      SELECT task_id, agent_id, chat_id, reply_token, session_id, expires_at, has_replied, incoming_message_id
      FROM active_dispatches
      WHERE agent_id = ?1
      ORDER BY started_at DESC
      LIMIT 1
      """
    guard let resultStr = dbQuery(sql, params: serializeParams([agentId])) else {
      return nil
    }
    return parseDispatchRow(resultStr)
  }

  /// Returns the most recently dispatched in-flight row across ALL agents.
  /// Used as a fallback when the host fires `invoke(type: "artifact")` from
  /// a thread that doesn't bind a per-agent frame — the artifact must
  /// belong to an agent that's currently running a task, and "the only
  /// agent in flight" is the unambiguous case. With multiple agents in
  /// flight we bias to the latest; the wrong-chat risk is documented at
  /// the call site in `Plugin.swift`.
  static func latestActiveDispatchAcrossAgents() -> ActiveDispatchRow? {
    let sql = """
      SELECT task_id, agent_id, chat_id, reply_token, session_id, expires_at, has_replied, incoming_message_id
      FROM active_dispatches
      ORDER BY started_at DESC
      LIMIT 1
      """
    guard let resultStr = dbQuery(sql, params: "[]") else {
      return nil
    }
    return parseDispatchRow(resultStr)
  }

  /// Like `activeDispatch`, but skips a specific `reply_token`. Used by the
  /// soft-interrupt branch in `handleWebhook` AFTER it has pre-inserted the
  /// current turn's row — we want the *prior* in-flight task to interrupt,
  /// not ourselves.
  static func priorActiveDispatch(
    agentId: String, forChat chatId: Int64, excluding replyToken: String
  ) -> ActiveDispatchRow? {
    let sql = """
      SELECT task_id, agent_id, chat_id, reply_token, session_id, expires_at, has_replied, incoming_message_id
      FROM active_dispatches
      WHERE agent_id = ?1 AND chat_id = ?2 AND reply_token != ?3
      ORDER BY started_at DESC
      LIMIT 1
      """
    guard
      let resultStr = dbQuery(
        sql, params: serializeParams([agentId, chatId, replyToken]))
    else { return nil }
    return parseDispatchRow(resultStr)
  }

  /// Returns every in-flight dispatch row for `(agentId, chatId)`. Used by
  /// `/reset` so we can hard-cancel every concurrent turn for a chat in one
  /// pass, not just the latest one.
  static func allActiveDispatches(agentId: String, forChat chatId: Int64)
    -> [ActiveDispatchRow]
  {
    let sql = """
      SELECT task_id, agent_id, chat_id, reply_token, session_id, expires_at, has_replied, incoming_message_id
      FROM active_dispatches
      WHERE agent_id = ?1 AND chat_id = ?2
      ORDER BY started_at DESC
      """
    guard let resultStr = dbQuery(sql, params: serializeParams([agentId, chatId]))
    else { return [] }
    return parseDispatchRows(resultStr)
  }

  /// Looks up a dispatch by reply_token. reply_token is globally unique so
  /// no agent_id is required here — callers can read `row.agentId` from the
  /// returned row to verify the binding belongs to the agent that owns the
  /// current callback frame.
  static func lookupBinding(token: String) -> ActiveDispatchRow? {
    let sql = """
      SELECT task_id, agent_id, chat_id, reply_token, session_id, expires_at, has_replied, incoming_message_id
      FROM active_dispatches
      WHERE reply_token = ?1
      LIMIT 1
      """
    guard let resultStr = dbQuery(sql, params: serializeParams([token])) else { return nil }
    return parseDispatchRow(resultStr)
  }

  static func lookupBindingByTask(taskId: String) -> ActiveDispatchRow? {
    let sql = """
      SELECT task_id, agent_id, chat_id, reply_token, session_id, expires_at, has_replied, incoming_message_id
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

  /// Removes a row by reply_token. Used by the webhook handler to unwind
  /// a pre-inserted binding when the subsequent `dispatch` call failed
  /// (no real task_id to delete by yet).
  static func deleteActiveDispatch(replyToken: String) {
    let sql = "DELETE FROM active_dispatches WHERE reply_token = ?1"
    dbExec(sql, params: serializeParams([replyToken]))
  }

  /// Patches the placeholder task_id on a pre-inserted row to the real
  /// one returned by `dispatch`.
  static func updateTaskId(replyToken: String, newTaskId: String) {
    let sql = "UPDATE active_dispatches SET task_id = ?1 WHERE reply_token = ?2"
    dbExec(sql, params: serializeParams([newTaskId, replyToken]))
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
      let row = rows.first, row.count >= 8
    else { return nil }
    return dispatchRow(from: row)
  }

  /// Multi-row variant for callers that want every match (e.g. `/reset`
  /// cancels every in-flight turn for a chat). Skips malformed rows but
  /// otherwise preserves the SELECT order.
  private static func parseDispatchRows(_ resultStr: String) -> [ActiveDispatchRow] {
    guard let rows = extractRows(resultStr) else { return [] }
    return rows.compactMap { row -> ActiveDispatchRow? in
      guard row.count >= 8 else { return nil }
      return dispatchRow(from: row)
    }
  }

  private static func dispatchRow(from row: [Any]) -> ActiveDispatchRow {
    ActiveDispatchRow(
      taskId: "\(row[0])",
      agentId: "\(row[1])",
      chatId: int64FromAny(row[2]) ?? 0,
      replyToken: "\(row[3])",
      sessionId: "\(row[4])",
      expiresAt: intFromAny(row[5]) ?? 0,
      hasReplied: intFromAny(row[6]) ?? 0,
      incomingMessageId: int64FromAny(row[7]) ?? 0
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
