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
        created_at    INTEGER DEFAULT (unixepoch()),
        updated_at    INTEGER DEFAULT (unixepoch()),
        FOREIGN KEY (chat_id) REFERENCES chats(chat_id)
      )
      """,
      "CREATE INDEX IF NOT EXISTS idx_messages_chat ON messages(chat_id, created_at DESC)",
      "CREATE INDEX IF NOT EXISTS idx_tasks_chat ON tasks(chat_id, created_at DESC)",
      "CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status)",
    ]

    guard let dbExec = hostAPI?.pointee.db_exec else {
      logError("db_exec not available")
      return
    }

    for sql in statements {
      let result = dbExec(makeCString(sql), makeCString("[]"))
      if let result {
        let str = String(cString: result)
        if str.contains("\"error\"") {
          logError("Schema init failed: \(str)")
        }
      }
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

  static func insertTask(taskId: String, chatId: String, messageId: Int?) {
    let params = serializeParams([taskId, chatId, messageId as Any])
    let sql = """
      INSERT INTO tasks (task_id, chat_id, message_id)
      VALUES (?1, ?2, ?3)
      """
    dbExec(sql, params: params)
  }

  static func updateTask(
    taskId: String,
    status: String? = nil,
    progress: Double? = nil,
    statusMsgId: Int? = nil,
    summary: String? = nil
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

    values.append(taskId)
    let sql = "UPDATE tasks SET \(setClauses.joined(separator: ", ")) WHERE task_id = ?\(paramIdx)"
    dbExec(sql, params: serializeParams(values))
  }

  static func getTask(taskId: String) -> TaskRow? {
    guard let dbQuery = hostAPI?.pointee.db_query else { return nil }

    let sql = """
      SELECT t.task_id, t.chat_id, t.message_id, t.status, t.status_msg_id, t.summary, c.chat_type
      FROM tasks t
      LEFT JOIN chats c ON t.chat_id = c.chat_id
      WHERE t.task_id = ?1
      """
    let params = serializeParams([taskId])

    guard let resultPtr = dbQuery(makeCString(sql), makeCString(params)) else { return nil }
    let resultStr = String(cString: resultPtr)

    guard let data = resultStr.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [[Any]],
      let row = json.first, row.count >= 7
    else {
      return nil
    }

    return TaskRow(
      taskId: "\(row[0])",
      chatId: "\(row[1])",
      messageId: row[2] as? Int,
      status: "\(row[3])",
      statusMsgId: row[4] as? Int,
      summary: row[5] as? String,
      chatType: (row[6] as? String) ?? "private"
    )
  }

  static func getChatType(chatId: String) -> String? {
    guard let dbQuery = hostAPI?.pointee.db_query else { return nil }
    let sql = "SELECT chat_type FROM chats WHERE chat_id = ?1"
    let params = serializeParams([chatId])
    guard let resultPtr = dbQuery(makeCString(sql), makeCString(params)) else { return nil }
    let resultStr = String(cString: resultPtr)
    guard let data = resultStr.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [[Any]],
      let row = json.first, !row.isEmpty
    else {
      return nil
    }
    return row[0] as? String
  }

  static func getMessages(chatId: String, limit: Int) -> String {
    guard let dbQuery = hostAPI?.pointee.db_query else { return "[]" }

    let clampedLimit = min(max(limit, 1), 200)
    let sql = """
      SELECT message_id, direction, sender_name, text, media_type, created_at
      FROM messages
      WHERE chat_id = ?1
      ORDER BY created_at DESC
      LIMIT ?2
      """
    let params = serializeParams([chatId, clampedLimit])

    guard let resultPtr = dbQuery(makeCString(sql), makeCString(params)) else { return "[]" }
    let resultStr = String(cString: resultPtr)

    guard let data = resultStr.data(using: .utf8),
      let rows = try? JSONSerialization.jsonObject(with: data) as? [[Any]]
    else {
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

  static func dbExec(_ sql: String, params: String) {
    guard let exec = hostAPI?.pointee.db_exec else {
      logError("db_exec not available")
      return
    }
    let result = exec(makeCString(sql), makeCString(params))
    if let result {
      let str = String(cString: result)
      if str.contains("\"error\"") {
        logWarn("DB exec error: \(str)")
      }
    }
  }

  /// Serializes an array of mixed values to a JSON array string for SQLite params.
  static func serializeParams(_ values: [Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: values),
      let str = String(data: data, encoding: .utf8)
    else {
      return "[]"
    }
    return str
  }
}
