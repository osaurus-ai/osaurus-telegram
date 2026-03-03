import Foundation
import Testing

@testable import osaurus_telegram

// MARK: - Mock Host API

nonisolated(unsafe) private var mockDB: [String: [[Any]]] = [:]
nonisolated(unsafe) private var mockHostAPIStorage = osr_host_api()
nonisolated(unsafe) private var mockLogMessages: [(Int32, String)] = []

/// C-convention callbacks use globals since they can't capture Swift state.

private let mockDbExec: osr_db_exec_fn = { sqlPtr, paramsPtr in
  guard let sqlPtr, let paramsPtr else { return nil }
  let sql = String(cString: sqlPtr)
  let paramsStr = String(cString: paramsPtr)

  guard let paramsData = paramsStr.data(using: .utf8),
    let params = try? JSONSerialization.jsonObject(with: paramsData) as? [Any]
  else {
    return makeCString("{\"error\":\"invalid params\"}")
  }

  if sql.contains("INSERT INTO tasks"), params.count >= 3 {
    mockDB["tasks", default: []].append([
      "\(params[0])", "\(params[1])", params[2], "running", NSNull(), NSNull(),
    ])
  }

  if sql.contains("INSERT INTO chats"), params.count >= 2 {
    mockDB["chats", default: []].append(["\(params[0])", "\(params[1])"])
  }

  return makeCString("{\"changes\":1}")
}

private let mockDbQuery: osr_db_query_fn = { sqlPtr, paramsPtr in
  guard let sqlPtr, let paramsPtr else { return nil }
  let sql = String(cString: sqlPtr)
  let paramsStr = String(cString: paramsPtr)

  guard let paramsData = paramsStr.data(using: .utf8),
    let params = try? JSONSerialization.jsonObject(with: paramsData) as? [Any]
  else {
    return makeCString("{\"rows\":[]}")
  }

  if sql.contains("FROM tasks"), !params.isEmpty {
    let searchId = "\(params[0])"
    var results: [[Any]] = []

    for taskRow in mockDB["tasks"] ?? [] {
      guard taskRow.count >= 3, "\(taskRow[0])" == searchId else { continue }
      let chatId = "\(taskRow[1])"
      let chatType = (mockDB["chats"] ?? [])
        .first { "\($0[0])" == chatId }
        .flatMap { $0.count > 1 ? "\($0[1])" : nil }

      var fullRow = Array(taskRow.prefix(6))
      while fullRow.count < 6 { fullRow.append(NSNull()) }
      fullRow.append(chatType as Any? ?? NSNull())
      results.append(fullRow)
    }

    guard let data = try? JSONSerialization.data(withJSONObject: ["rows": results]),
      let str = String(data: data, encoding: .utf8)
    else {
      return makeCString("{\"rows\":[]}")
    }
    return makeCString(str)
  }

  return makeCString("{\"rows\":[]}")
}

private let mockLog: osr_log_fn = { level, msgPtr in
  guard let msgPtr else { return }
  mockLogMessages.append((level, String(cString: msgPtr)))
}

private func setupMockHost() {
  mockDB = [:]
  mockLogMessages = []
  mockHostAPIStorage = osr_host_api()
  mockHostAPIStorage.version = 2
  mockHostAPIStorage.db_exec = mockDbExec
  mockHostAPIStorage.db_query = mockDbQuery
  mockHostAPIStorage.log = mockLog
  hostAPI = withUnsafePointer(to: &mockHostAPIStorage) { $0 }
}

private func teardownMockHost() {
  hostAPI = nil
  mockDB = [:]
  mockLogMessages = []
}

// MARK: - serializeParams

@Suite("serializeParams")
struct SerializeParamsTests {

  @Test("Serializes string array")
  func allStrings() {
    let result = DatabaseManager.serializeParams(["abc", "def", "ghi"])
    #expect(result == #"["abc","def","ghi"]"#)
  }

  @Test("Serializes non-optional Int")
  func nonOptionalInt() {
    let result = DatabaseManager.serializeParams(["task-id", "chat-id", 42 as Any])
    #expect(result != "[]")
    #expect(result.contains("42"))
  }

  @Test("Serializes Optional<Int>.some via `as Any`")
  func optionalSomeAsAny() {
    let msgId: Int? = 42
    let result = DatabaseManager.serializeParams(["task-id", "chat-id", msgId as Any])
    #expect(result != "[]")
    #expect(result.contains("42"))
  }

  @Test("Serializes Optional<Int>.none via `as Any`")
  func optionalNoneAsAny() {
    let msgId: Int? = nil
    let result = DatabaseManager.serializeParams(["task-id", "chat-id", msgId as Any])
    #expect(result != "[]")
  }

  @Test("Serializes NSNull to JSON null")
  func nsNull() {
    let result = DatabaseManager.serializeParams(["task-id", "chat-id", NSNull()])
    #expect(result != "[]")
    #expect(result.contains("null"))
  }
}

// MARK: - extractRows

@Suite("extractRows")
struct ExtractRowsTests {

  @Test("Extracts from host format {\"rows\": [...]}")
  func hostFormat() {
    let rows = DatabaseManager.extractRows(#"{"rows":[["a","b",1],["c","d",2]]}"#)
    #expect(rows?.count == 2)
    #expect(rows?[0].count == 3)
  }

  @Test("Extracts from bare array [[...]]")
  func bareArray() {
    let rows = DatabaseManager.extractRows(#"[["a","b",1]]"#)
    #expect(rows?.count == 1)
  }

  @Test("Returns nil for invalid JSON")
  func invalidJSON() {
    #expect(DatabaseManager.extractRows("not json") == nil)
  }

  @Test("Returns empty array for empty host result")
  func emptyHost() {
    let rows = DatabaseManager.extractRows(#"{"rows":[]}"#)
    #expect(rows?.isEmpty == true)
  }

  @Test("Returns empty array for empty bare result")
  func emptyBare() {
    let rows = DatabaseManager.extractRows("[]")
    #expect(rows?.isEmpty == true)
  }
}

// MARK: - parseTaskRow

@Suite("parseTaskRow")
struct ParseTaskRowTests {

  @Test("Parses bare array format")
  func bareArray() {
    let row = DatabaseManager.parseTaskRow(
      #"[["task-1","chat-1",42,"running",null,null,"private"]]"#)
    #expect(row != nil)
    #expect(row?.taskId == "task-1")
    #expect(row?.chatId == "chat-1")
    #expect(row?.messageId == 42)
    #expect(row?.status == "running")
    #expect(row?.chatType == "private")
  }

  @Test("Parses host format with rows wrapper")
  func hostFormat() {
    let row = DatabaseManager.parseTaskRow(
      #"{"rows":[["task-1","chat-1",19,"running",null,null,"private"]]}"#)
    #expect(row != nil)
    #expect(row?.taskId == "task-1")
    #expect(row?.messageId == 19)
    #expect(row?.chatType == "private")
  }

  @Test("Parses real host response format")
  func realHostResponse() {
    let row = DatabaseManager.parseTaskRow(
      #"{"rows":[["2DB68CCC-1234-5678-AAAA-BBBBBBBBBBBB","1689414522",19,"running",null,null,"private"]]}"#
    )
    #expect(row != nil)
    #expect(row?.messageId == 19)
    #expect(row?.chatId == "1689414522")
  }

  @Test("Defaults null chat_type to private")
  func nullChatType() {
    let row = DatabaseManager.parseTaskRow(
      #"{"rows":[["t1","c1",42,"running",null,null,null]]}"#)
    #expect(row != nil)
    #expect(row?.chatType == "private")
  }

  @Test("Parses all fields including status_msg_id and summary")
  func fullRow() {
    let row = DatabaseManager.parseTaskRow(
      #"{"rows":[["t1","c1",42,"completed",99,"All done","supergroup"]]}"#)
    #expect(row?.statusMsgId == 99)
    #expect(row?.summary == "All done")
    #expect(row?.chatType == "supergroup")
  }

  @Test("Returns nil for empty results")
  func emptyResults() {
    #expect(DatabaseManager.parseTaskRow("[]") == nil)
    #expect(DatabaseManager.parseTaskRow(#"{"rows":[]}"#) == nil)
    #expect(DatabaseManager.parseTaskRow("") == nil)
    #expect(DatabaseManager.parseTaskRow("not json") == nil)
  }

  @Test("Returns nil when row has fewer than 7 elements")
  func shortRow() {
    #expect(DatabaseManager.parseTaskRow(#"[["t1","c1",42,"running"]]"#) == nil)
  }
}

// MARK: - Round-trip integration (mock host)

@Suite("Task insert/query round-trip", .serialized)
struct TaskRoundTripTests {

  @Test("insertTask then getTask returns the task")
  func basicRoundTrip() {
    setupMockHost()
    defer { teardownMockHost() }

    DatabaseManager.upsertChat(
      chatId: "1689414522", chatType: "private", title: "Test", username: nil)
    DatabaseManager.insertTask(
      taskId: "8EF0458F-775F-45FD-99AF-C690AB4CB2EC", chatId: "1689414522", messageId: 42)

    let task = DatabaseManager.getTask(taskId: "8EF0458F-775F-45FD-99AF-C690AB4CB2EC")
    #expect(task != nil)
    #expect(task?.taskId == "8EF0458F-775F-45FD-99AF-C690AB4CB2EC")
    #expect(task?.chatId == "1689414522")
    #expect(task?.messageId == 42)
    #expect(task?.status == "running")
    #expect(task?.chatType == "private")
  }

  @Test("getTask returns nil for non-existent task")
  func nonExistent() {
    setupMockHost()
    defer { teardownMockHost() }

    #expect(DatabaseManager.getTask(taskId: "does-not-exist") == nil)
  }

  @Test("insertTask without chat defaults chatType to private")
  func noChat() {
    setupMockHost()
    defer { teardownMockHost() }

    DatabaseManager.insertTask(taskId: "task-1", chatId: "unknown-chat", messageId: nil)

    let task = DatabaseManager.getTask(taskId: "task-1")
    #expect(task != nil)
    #expect(task?.chatType == "private")
  }

  @Test("handleTaskEvent finds task after insertTask")
  func taskEventAfterInsert() {
    setupMockHost()
    defer { teardownMockHost() }

    let ctx = PluginContext()
    ctx.botToken = "test-token"

    DatabaseManager.upsertChat(chatId: "999", chatType: "private", title: nil, username: nil)
    DatabaseManager.insertTask(taskId: "task-event-test", chatId: "999", messageId: 1)

    mockLogMessages = []
    handleTaskEvent(ctx: ctx, taskId: "task-event-test", eventType: 0, eventJSON: "{}")

    let warnings = mockLogMessages.filter { $0.0 >= 2 && $0.1.contains("unknown task") }
    #expect(warnings.isEmpty, "Should NOT log 'unknown task' after insertTask")
  }

  @Test("handleTaskEvent logs warning for missing task")
  func taskEventMissing() {
    setupMockHost()
    defer { teardownMockHost() }

    mockLogMessages = []
    handleTaskEvent(ctx: PluginContext(), taskId: "nonexistent", eventType: 0, eventJSON: "{}")

    let warnings = mockLogMessages.filter { $0.0 >= 2 && $0.1.contains("unknown task") }
    #expect(!warnings.isEmpty)
  }
}
