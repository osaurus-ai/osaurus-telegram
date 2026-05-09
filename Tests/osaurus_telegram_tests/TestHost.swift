import Foundation
import SQLite3

@testable import osaurus_telegram

// MARK: - In-Process Host Stub
//
// XCTest can't load us into Osaurus, so we synthesise an `osr_host_api`
// table that:
//   * routes db_exec/db_query to an in-memory SQLite database,
//   * stores config_* values in a thread-safe dictionary,
//   * captures dispatch / dispatch_interrupt / dispatch_cancel calls so
//     tests can assert on them,
//   * stubs http_request with a configurable response.
//
// All state is held in TestHostGlobals because @convention(c) function
// pointers cannot capture context. install() / uninstall() reset every
// global between tests, so test isolation is unaffected by globals.

private let SQLITE_TRANSIENT = unsafeBitCast(
  OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

enum TestHostGlobals {
  nonisolated(unsafe) static var db: OpaquePointer?
  nonisolated(unsafe) static var configStore: [String: String] = [:]
  nonisolated(unsafe) static var dispatchCalls: [[String: Any]] = []
  nonisolated(unsafe) static var interruptCalls: [(taskId: String, text: String)] = []
  nonisolated(unsafe) static var cancelCalls: [String] = []
  nonisolated(unsafe) static var httpCalls: [[String: Any]] = []
  nonisolated(unsafe) static var nextDispatchResponse: String =
    #"{"id":"task-uuid","status":"running"}"#
  nonisolated(unsafe) static var nextHttpResponse: String =
    #"{"status":200,"body":"{\"ok\":true,\"result\":{\"message_id\":1}}"}"#

  nonisolated(unsafe) static var apiTable = osr_host_api()
}

enum TestHost {

  /// Installs the stub host API. Call from `setUp`.
  static func install() {
    TestHostGlobals.configStore = [:]
    TestHostGlobals.dispatchCalls = []
    TestHostGlobals.interruptCalls = []
    TestHostGlobals.cancelCalls = []
    TestHostGlobals.httpCalls = []
    TestHostGlobals.nextDispatchResponse =
      #"{"id":"task-uuid","status":"running"}"#
    TestHostGlobals.nextHttpResponse =
      #"{"status":200,"body":"{\"ok\":true,\"result\":{\"message_id\":1}}"}"#

    if TestHostGlobals.db != nil {
      sqlite3_close(TestHostGlobals.db)
      TestHostGlobals.db = nil
    }
    var handle: OpaquePointer?
    let rc = sqlite3_open(":memory:", &handle)
    precondition(rc == SQLITE_OK, "failed to open in-memory sqlite")
    TestHostGlobals.db = handle

    var api = osr_host_api()
    api.config_get = stub_config_get
    api.config_set = stub_config_set
    api.config_delete = stub_config_delete
    api.db_exec = stub_db_exec
    api.db_query = stub_db_query
    api.log = stub_log
    api.dispatch = stub_dispatch
    api.dispatch_cancel = stub_dispatch_cancel
    api.dispatch_interrupt = stub_dispatch_interrupt
    api.http_request = stub_http_request
    api.list_active_tasks = stub_list_active_tasks

    TestHostGlobals.apiTable = api
    withUnsafePointer(to: &TestHostGlobals.apiTable) { ptr in
      hostAPI = ptr
    }
  }

  /// Tears down the stub host API. Call from `tearDown`.
  static func uninstall() {
    hostAPI = nil
    if let handle = TestHostGlobals.db {
      sqlite3_close(handle)
      TestHostGlobals.db = nil
    }
    TestHostGlobals.configStore = [:]
    TestHostGlobals.dispatchCalls = []
    TestHostGlobals.interruptCalls = []
    TestHostGlobals.cancelCalls = []
    TestHostGlobals.httpCalls = []
  }
}

// MARK: - C function pointer stubs

private let stub_config_get: osr_config_get_fn = { keyPtr in
  guard let keyPtr else { return nil }
  let key = String(cString: keyPtr)
  guard let value = TestHostGlobals.configStore[key] else { return nil }
  return UnsafePointer(strdup(value))
}

private let stub_config_set: osr_config_set_fn = { keyPtr, valuePtr in
  guard let keyPtr, let valuePtr else { return }
  TestHostGlobals.configStore[String(cString: keyPtr)] = String(cString: valuePtr)
}

private let stub_config_delete: osr_config_delete_fn = { keyPtr in
  guard let keyPtr else { return }
  TestHostGlobals.configStore.removeValue(forKey: String(cString: keyPtr))
}

private let stub_log: osr_log_fn = { _, _ in /* swallow */ }

private let stub_db_exec: osr_db_exec_fn = { sqlPtr, paramsPtr in
  guard let sqlPtr else { return nil }
  let sql = String(cString: sqlPtr)
  let params = paramsPtr.map { String(cString: $0) } ?? "[]"

  guard let db = TestHostGlobals.db else {
    return UnsafePointer(strdup(#"{"error":"db not open"}"#))
  }

  var stmt: OpaquePointer?
  let prepare = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
  if prepare != SQLITE_OK {
    let msg = String(cString: sqlite3_errmsg(db))
    return UnsafePointer(strdup(#"{"error":"\#(msg)"}"#))
  }
  defer { sqlite3_finalize(stmt) }

  if let err = bindParams(stmt: stmt, paramsJSON: params) {
    return UnsafePointer(strdup(#"{"error":"\#(err)"}"#))
  }

  var step = sqlite3_step(stmt)
  while step == SQLITE_ROW { step = sqlite3_step(stmt) }
  if step != SQLITE_DONE && step != SQLITE_OK {
    let msg = String(cString: sqlite3_errmsg(db))
    return UnsafePointer(strdup(#"{"error":"\#(msg)"}"#))
  }
  return UnsafePointer(strdup(#"{"ok":true}"#))
}

private let stub_db_query: osr_db_query_fn = { sqlPtr, paramsPtr in
  guard let sqlPtr else { return nil }
  let sql = String(cString: sqlPtr)
  let params = paramsPtr.map { String(cString: $0) } ?? "[]"

  guard let db = TestHostGlobals.db else {
    return UnsafePointer(strdup(#"{"error":"db not open"}"#))
  }

  var stmt: OpaquePointer?
  let prepare = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
  if prepare != SQLITE_OK {
    let msg = String(cString: sqlite3_errmsg(db))
    return UnsafePointer(strdup(#"{"error":"\#(msg)"}"#))
  }
  defer { sqlite3_finalize(stmt) }

  if let err = bindParams(stmt: stmt, paramsJSON: params) {
    return UnsafePointer(strdup(#"{"error":"\#(err)"}"#))
  }

  var rows: [[Any]] = []
  while sqlite3_step(stmt) == SQLITE_ROW {
    let columnCount = Int(sqlite3_column_count(stmt))
    var row: [Any] = []
    for i in 0..<columnCount {
      row.append(readColumn(stmt: stmt, index: Int32(i)))
    }
    rows.append(row)
  }

  let payload: [String: Any] = ["rows": rows]
  let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
  let str = String(data: data, encoding: .utf8) ?? "{\"rows\":[]}"
  return UnsafePointer(strdup(str))
}

private let stub_dispatch: osr_dispatch_fn = { reqPtr in
  guard let reqPtr else { return nil }
  let req = String(cString: reqPtr)
  if let parsed = parseJSONObject(req) {
    TestHostGlobals.dispatchCalls.append(parsed)
  }
  return UnsafePointer(strdup(TestHostGlobals.nextDispatchResponse))
}

private let stub_dispatch_cancel: osr_dispatch_cancel_fn = { taskIdPtr in
  guard let taskIdPtr else { return }
  TestHostGlobals.cancelCalls.append(String(cString: taskIdPtr))
}

private let stub_dispatch_interrupt: osr_dispatch_interrupt_fn = { taskIdPtr, textPtr in
  guard let taskIdPtr, let textPtr else { return }
  TestHostGlobals.interruptCalls.append(
    (taskId: String(cString: taskIdPtr), text: String(cString: textPtr)))
}

private let stub_http_request: osr_http_request_fn = { reqPtr in
  guard let reqPtr else { return nil }
  let req = String(cString: reqPtr)
  if let parsed = parseJSONObject(req) {
    TestHostGlobals.httpCalls.append(parsed)
  }
  return UnsafePointer(strdup(TestHostGlobals.nextHttpResponse))
}

private let stub_list_active_tasks: osr_list_active_tasks_fn = {
  return UnsafePointer(strdup(#"{"tasks":[]}"#))
}

// MARK: - SQLite binding helpers

private func bindParams(stmt: OpaquePointer?, paramsJSON: String) -> String? {
  guard let data = paramsJSON.data(using: .utf8),
    let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
  else {
    return "invalid params json: \(paramsJSON)"
  }

  for (i, value) in array.enumerated() {
    let idx = Int32(i + 1)
    if value is NSNull {
      sqlite3_bind_null(stmt, idx)
    } else if let n = value as? NSNumber {
      // NSNumber covers Int, Int64, Double, Bool — disambiguate by class id.
      if CFGetTypeID(n) == CFBooleanGetTypeID() {
        sqlite3_bind_int(stmt, idx, n.boolValue ? 1 : 0)
      } else if CFNumberIsFloatType(n) {
        sqlite3_bind_double(stmt, idx, n.doubleValue)
      } else {
        sqlite3_bind_int64(stmt, idx, n.int64Value)
      }
    } else if let s = value as? String {
      sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
    } else {
      return "unsupported param type at index \(i): \(type(of: value))"
    }
  }
  return nil
}

private func readColumn(stmt: OpaquePointer?, index: Int32) -> Any {
  switch sqlite3_column_type(stmt, index) {
  case SQLITE_INTEGER:
    return Int(sqlite3_column_int64(stmt, index))
  case SQLITE_FLOAT:
    return sqlite3_column_double(stmt, index)
  case SQLITE_TEXT:
    if let cstr = sqlite3_column_text(stmt, index) {
      return String(cString: cstr)
    }
    return ""
  case SQLITE_NULL:
    return NSNull()
  case SQLITE_BLOB:
    return NSNull()
  default:
    return NSNull()
  }
}
