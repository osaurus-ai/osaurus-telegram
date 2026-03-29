import Foundation

// MARK: - Database Manager

enum DatabaseManager {

  // MARK: - Schema

  static func initSchema() {
    let statements = [
      """
      CREATE TABLE IF NOT EXISTS chats (
        chat_id       TEXT PRIMARY KEY,
        chat_type     TEXT NOT NULL,
        title         TEXT,
        username      TEXT,
        created_at    INTEGER DEFAULT (unixepoch()),
        last_active   INTEGER DEFAULT (unixepoch())
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS users (
        user_id       TEXT PRIMARY KEY,
        username      TEXT,
        first_name    TEXT,
        last_name     TEXT,
        created_at    INTEGER DEFAULT (unixepoch()),
        last_active   INTEGER DEFAULT (unixepoch())
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS messages (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        chat_id       TEXT NOT NULL,
        message_id    INTEGER,
        direction     TEXT NOT NULL,
        sender_id     TEXT,
        sender_name   TEXT,
        text          TEXT,
        media_type    TEXT,
        media_file_id TEXT,
        task_id       TEXT,
        created_at    INTEGER DEFAULT (unixepoch()),
        FOREIGN KEY (chat_id) REFERENCES chats(chat_id)
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS tasks (
        task_id       TEXT PRIMARY KEY,
        chat_id       TEXT NOT NULL,
        message_id    INTEGER,
        status        TEXT DEFAULT 'running',
        progress      REAL DEFAULT 0.0,
        status_msg_id INTEGER,
        summary       TEXT,
        clarification_options TEXT,
        user_id       TEXT,
        created_at    INTEGER DEFAULT (unixepoch()),
        updated_at    INTEGER DEFAULT (unixepoch()),
        FOREIGN KEY (chat_id) REFERENCES chats(chat_id)
      )
      """,
      "CREATE INDEX IF NOT EXISTS idx_messages_chat ON messages(chat_id, created_at DESC)",
      "CREATE INDEX IF NOT EXISTS idx_tasks_chat ON tasks(chat_id, created_at DESC)",
      "CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status)",
    ]

    for sql in statements {
      dbExec(sql, params: "[]")
    }

    let migrations = [
      "ALTER TABLE tasks ADD COLUMN clarification_options TEXT",
      "ALTER TABLE tasks ADD COLUMN user_id TEXT",
    ]
    for sql in migrations {
      dbExecSilent(sql, params: "[]")
    }
  }

  // MARK: - Chats

  static func upsertChat(chatId: String, chatType: String, title: String?, username: String?) {
    let params = serializeParams([
      chatId,
      chatType,
      title ?? "",
      username ?? "",
    ])

    let sql = """
      INSERT INTO chats (chat_id, chat_type, title, username)
      VALUES (?1, ?2, ?3, ?4)
      ON CONFLICT(chat_id) DO UPDATE SET
        title = ?3,
        username = ?4,
        last_active = unixepoch()
      """
    dbExec(sql, params: params)
  }

  static func getChats(username: String? = nil, chatType: String? = nil) -> [[String: Any]] {
    var conditions: [String] = []
    var values: [Any] = []
    var paramIdx = 1

    if let username {
      let cleaned = username.replacingOccurrences(of: "@", with: "").lowercased()
      conditions.append("LOWER(username) = ?\(paramIdx)")
      values.append(cleaned)
      paramIdx += 1
    }
    if let chatType {
      conditions.append("chat_type = ?\(paramIdx)")
      values.append(chatType)
      paramIdx += 1
    }

    var sql = "SELECT chat_id, chat_type, title, username, last_active FROM chats"
    if !conditions.isEmpty {
      sql += " WHERE " + conditions.joined(separator: " AND ")
    }
    sql += " ORDER BY last_active DESC LIMIT 50"

    guard let resultStr = dbQuery(sql, params: serializeParams(values)),
      let rows = extractRows(resultStr)
    else {
      return []
    }

    return rows.map { row in
      var chat: [String: Any] = [:]
      if row.count > 0 { chat["chat_id"] = row[0] }
      if row.count > 1, let t = row[1] as? String { chat["chat_type"] = t }
      if row.count > 2, let title = row[2] as? String, !title.isEmpty { chat["title"] = title }
      if row.count > 3, let u = row[3] as? String, !u.isEmpty { chat["username"] = u }
      if row.count > 4 { chat["last_active"] = row[4] }
      return chat
    }
  }

  // MARK: - Users

  static func upsertUser(userId: String, username: String?, firstName: String?, lastName: String?) {
    let params = serializeParams([
      userId,
      username ?? NSNull(),
      firstName ?? NSNull(),
      lastName ?? NSNull(),
    ])

    let sql = """
      INSERT INTO users (user_id, username, first_name, last_name)
      VALUES (?1, ?2, ?3, ?4)
      ON CONFLICT(user_id) DO UPDATE SET
        username = ?2,
        first_name = ?3,
        last_name = ?4,
        last_active = unixepoch()
      """
    dbExec(sql, params: params)
  }

  static func getUserByUsername(_ username: String) -> [String: Any]? {
    let cleaned = username.replacingOccurrences(of: "@", with: "").lowercased()
    let sql = """
      SELECT user_id, username, first_name, last_name
      FROM users
      WHERE LOWER(username) = ?1
      LIMIT 1
      """
    guard let resultStr = dbQuery(sql, params: serializeParams([cleaned])),
      let rows = extractRows(resultStr),
      let row = rows.first
    else {
      return nil
    }

    var user: [String: Any] = [:]
    if row.count > 0 { user["user_id"] = row[0] }
    if row.count > 1, let u = row[1] as? String { user["username"] = u }
    if row.count > 2, let fn = row[2] as? String { user["first_name"] = fn }
    if row.count > 3, let ln = row[3] as? String { user["last_name"] = ln }
    return user
  }

  // MARK: - Messages

  static func insertMessage(
    chatId: String,
    messageId: Int?,
    direction: String,
    senderId: String?,
    senderName: String?,
    text: String?,
    mediaType: String?,
    mediaFileId: String?,
    taskId: String?
  ) {
    let params: [Any] = [
      chatId,
      messageId as Any,
      direction,
      senderId ?? NSNull(),
      senderName ?? NSNull(),
      text ?? NSNull(),
      mediaType ?? NSNull(),
      mediaFileId ?? NSNull(),
      taskId ?? NSNull(),
    ]
    let paramsSerialized = serializeParams(params)

    let sql = """
      INSERT INTO messages (chat_id, message_id, direction, sender_id, sender_name, text, media_type, media_file_id, task_id)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
      """
    dbExec(sql, params: paramsSerialized)
  }

  // MARK: - Tasks

  static func insertTask(taskId: String, chatId: String, messageId: Int?, userId: String? = nil) {
    let params = serializeParams([taskId, chatId, messageId as Any, userId ?? NSNull()])
    let sql = """
      INSERT INTO tasks (task_id, chat_id, message_id, user_id)
      VALUES (?1, ?2, ?3, ?4)
      """
    dbExec(sql, params: params)
  }

  static func updateTask(
    taskId: String,
    status: String? = nil,
    progress: Double? = nil,
    statusMsgId: Int? = nil,
    summary: String? = nil,
    clarificationOptions: String? = nil
  ) {
    var setClauses: [String] = ["updated_at = unixepoch()"]
    var values: [Any] = []
    var paramIdx = 1

    if let status {
      setClauses.append("status = ?\(paramIdx)")
      values.append(status)
      paramIdx += 1
    }
    if let progress {
      setClauses.append("progress = ?\(paramIdx)")
      values.append(progress)
      paramIdx += 1
    }
    if let statusMsgId {
      setClauses.append("status_msg_id = ?\(paramIdx)")
      values.append(statusMsgId)
      paramIdx += 1
    }
    if let summary {
      setClauses.append("summary = ?\(paramIdx)")
      values.append(summary)
      paramIdx += 1
    }
    if let clarificationOptions {
      setClauses.append("clarification_options = ?\(paramIdx)")
      values.append(clarificationOptions)
      paramIdx += 1
    }

    values.append(taskId)
    let sql = "UPDATE tasks SET \(setClauses.joined(separator: ", ")) WHERE task_id = ?\(paramIdx)"
    dbExec(sql, params: serializeParams(values))
  }

  private static let taskSelectColumns = """
    SELECT t.task_id, t.chat_id, t.message_id, t.status, t.status_msg_id, \
    t.summary, c.chat_type, t.clarification_options, t.user_id
    FROM tasks t
    LEFT JOIN chats c ON t.chat_id = c.chat_id
    """

  static func getTask(taskId: String) -> TaskRow? {
    let sql = "\(taskSelectColumns) WHERE t.task_id = ?1"
    guard let resultStr = dbQuery(sql, params: serializeParams([taskId])) else { return nil }
    return parseTaskRow(resultStr)
  }

  static func getRunningTasks() -> [TaskRow] {
    let sql =
      "\(taskSelectColumns) WHERE t.status IN ('running', 'awaiting_clarification')"
    guard let resultStr = dbQuery(sql, params: "[]"),
      let rows = extractRows(resultStr)
    else { return [] }
    return rows.compactMap { taskRowFromArray($0) }
  }

  static func parseTaskRow(_ resultStr: String) -> TaskRow? {
    guard let rows = extractRows(resultStr),
      let row = rows.first
    else {
      return nil
    }
    return taskRowFromArray(row)
  }

  private static func taskRowFromArray(_ row: [Any]) -> TaskRow? {
    guard row.count >= 7 else { return nil }
    return TaskRow(
      taskId: "\(row[0])",
      chatId: "\(row[1])",
      messageId: row[2] as? Int,
      status: "\(row[3])",
      statusMsgId: row[4] as? Int,
      summary: row[5] as? String,
      chatType: (row[6] as? String) ?? "private",
      clarificationOptions: row.count > 7 ? row[7] as? String : nil,
      userId: row.count > 8 ? row[8] as? String : nil
    )
  }

  static func getTaskByMessageId(chatId: String, messageId: Int) -> TaskRow? {
    let params = serializeParams([chatId, messageId])

    let directSQL = """
      \(taskSelectColumns)
      WHERE t.chat_id = ?1 AND (t.message_id = ?2 OR t.status_msg_id = ?2)
      ORDER BY t.updated_at DESC LIMIT 1
      """
    if let resultStr = dbQuery(directSQL, params: params),
      let row = parseTaskRow(resultStr)
    {
      return row
    }

    let msgSQL = """
      SELECT t.task_id, t.chat_id, t.message_id, t.status, t.status_msg_id, \
      t.summary, c.chat_type, t.clarification_options, t.user_id
      FROM messages m
      JOIN tasks t ON m.task_id = t.task_id
      LEFT JOIN chats c ON t.chat_id = c.chat_id
      WHERE m.chat_id = ?1 AND m.message_id = ?2 AND m.task_id IS NOT NULL
      ORDER BY t.updated_at DESC LIMIT 1
      """
    if let resultStr = dbQuery(msgSQL, params: params),
      let row = parseTaskRow(resultStr)
    {
      return row
    }

    return nil
  }

  static func getAwaitingClarification(chatId: String, userId: String? = nil) -> TaskRow? {
    var sql = "\(taskSelectColumns) WHERE t.chat_id = ?1 AND t.status = 'awaiting_clarification'"
    var params: [Any] = [chatId]

    if let userId {
      sql += " AND t.user_id = ?2"
      params.append(userId)
    }

    sql += " ORDER BY t.updated_at DESC LIMIT 1"
    guard let resultStr = dbQuery(sql, params: serializeParams(params)) else { return nil }
    return parseTaskRow(resultStr)
  }

  static func getRecentTasks(chatId: String, limit: Int = 5) -> [TaskRow] {
    let clampedLimit = min(max(limit, 1), 20)
    let sql = "\(taskSelectColumns) WHERE t.chat_id = ?1 ORDER BY t.updated_at DESC LIMIT ?2"
    let params = serializeParams([chatId, clampedLimit])
    guard let resultStr = dbQuery(sql, params: params),
      let rows = extractRows(resultStr)
    else {
      return []
    }
    return rows.compactMap(taskRowFromArray)
  }

  static func getRunningTask(chatId: String, userId: String? = nil) -> TaskRow? {
    var sql = "\(taskSelectColumns) WHERE t.chat_id = ?1 AND t.status = 'running'"
    var params: [Any] = [chatId]

    if let userId {
      sql += " AND t.user_id = ?2"
      params.append(userId)
    }

    sql += " ORDER BY t.updated_at DESC LIMIT 1"
    guard let resultStr = dbQuery(sql, params: serializeParams(params)) else { return nil }
    return parseTaskRow(resultStr)
  }

  static func clearChat(chatId: String) {
    let params = serializeParams([chatId])
    dbExec("DELETE FROM messages WHERE chat_id = ?1", params: params)
    dbExec("DELETE FROM tasks WHERE chat_id = ?1", params: params)
  }

  static func clearUserInChat(chatId: String, userId: String) {
    let params = serializeParams([chatId, userId])
    dbExec("DELETE FROM messages WHERE chat_id = ?1 AND sender_id = ?2", params: params)
    dbExec("DELETE FROM tasks WHERE chat_id = ?1 AND user_id = ?2", params: params)
  }

  static func getLastActiveChatId() -> String? {
    let sql = """
      SELECT chat_id FROM tasks
      WHERE status = 'running'
      ORDER BY updated_at DESC
      LIMIT 1
      """
    guard let resultStr = dbQuery(sql, params: "[]") else { return nil }
    guard let rows = extractRows(resultStr),
      let row = rows.first, !row.isEmpty
    else {
      return nil
    }
    return row[0] as? String
  }

  static func getMessages(chatId: String, limit: Int) -> String {
    let clampedLimit = min(max(limit, 1), 200)
    let sql = """
      SELECT message_id, direction, sender_name, text, media_type, created_at
      FROM messages
      WHERE chat_id = ?1
      ORDER BY created_at DESC
      LIMIT ?2
      """
    let params = serializeParams([chatId, clampedLimit])

    guard let resultStr = dbQuery(sql, params: params) else { return "[]" }

    guard let rows = extractRows(resultStr) else {
      return "[]"
    }

    let messages: [[String: Any]] = rows.map { row in
      var msg: [String: Any] = [:]
      if row.count > 0, let mid = row[0] as? Int { msg["message_id"] = mid }
      if row.count > 1, let dir = row[1] as? String { msg["direction"] = dir }
      if row.count > 2, let name = row[2] as? String { msg["sender_name"] = name }
      if row.count > 3, let text = row[3] as? String { msg["text"] = text }
      if row.count > 4, let media = row[4] as? String { msg["media_type"] = media }
      if row.count > 5, let ts = row[5] as? Int { msg["created_at"] = ts }
      return msg
    }

    guard let jsonData = try? JSONSerialization.data(withJSONObject: messages),
      let jsonStr = String(data: jsonData, encoding: .utf8)
    else {
      return "[]"
    }
    return jsonStr
  }

  // MARK: - Helpers

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

  /// Like `dbExec`, but silently ignores errors (used for idempotent migrations).
  static func dbExecSilent(_ sql: String, params: String) {
    guard let exec = hostAPI?.pointee.db_exec else { return }
    sql.withCString { sqlPtr in
      params.withCString { paramsPtr in
        _ = exec(sqlPtr, paramsPtr)
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
    guard let data = try? JSONSerialization.data(withJSONObject: values),
      let str = String(data: data, encoding: .utf8)
    else {
      logWarn("serializeParams: failed to serialize \(values.count) values, returning empty array")
      return "[]"
    }
    return str
  }
}
