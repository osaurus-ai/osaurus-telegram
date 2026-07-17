import Foundation
import OsaurusPluginABI
import SQLite3

@testable import osaurus_telegram

// MARK: - In-Process Host Stub
//
// XCTest can't load us into Osaurus, so we synthesise an `osr_host_api`
// table that:
//   * routes db_exec/db_query to an in-memory SQLite database,
//   * stores config_* values in a thread-safe dictionary scoped by
//     (agentId, key) — mirroring the real host's per-(plugin_id, agent_id)
//     Keychain partitioning,
//   * resolves get_active_agent_id() from `TestHostGlobals.activeAgentId`,
//   * captures dispatch / dispatch_interrupt / dispatch_cancel calls so
//     tests can assert on them,
//   * stubs http_request with a configurable response.
//
// All state is held in TestHostGlobals because @convention(c) function
// pointers cannot capture context. install() / uninstall() reset every
// global between tests, so test isolation is unaffected by globals.

private let SQLITE_TRANSIENT = unsafeBitCast(
  OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

/// Default agent UUID used by tests that don't care about cross-agent
/// behavior. install() points `activeAgentId` here; multi-agent tests
/// flip it via `TestHost.setActiveAgent(_:)`.
let defaultTestAgentId = "agent-default"

enum TestHostGlobals {
  nonisolated(unsafe) static var db: OpaquePointer?

  /// Serializes every db_exec / db_query against the shared in-memory
  /// connection, mirroring the real host's per-statement serialization.
  /// Without it, concurrent claims racing through `sqlite3_changes` (a
  /// per-connection counter) could observe each other's counts.
  static let dbLock = NSLock()

  /// (agentId → (key → value)). Mirrors the real host's per-agent
  /// (plugin_id, agent_id, key) Keychain partitioning. The active agent
  /// for a given config_get/set call is whatever `activeAgentId` is at
  /// the moment the stub fires.
  nonisolated(unsafe) static var configStore: [String: [String: String]] = [:]

  /// What `get_active_agent_id()` returns. nil means the plugin is being
  /// invoked outside any per-agent frame (e.g. init or destroy); per-agent
  /// callbacks should refuse to run in that case.
  nonisolated(unsafe) static var activeAgentId: String? = defaultTestAgentId

  nonisolated(unsafe) static var dispatchCalls: [[String: Any]] = []
  nonisolated(unsafe) static var interruptCalls: [(taskId: String, text: String)] = []
  nonisolated(unsafe) static var cancelCalls: [String] = []
  nonisolated(unsafe) static var httpCalls: [[String: Any]] = []

  /// Optional callback fired BEFORE `stub_dispatch` returns. Lets tests
  /// inspect the world (specifically the active_dispatches table) at the
  /// instant the host would receive the dispatch — i.e. verify the
  /// reply_token binding is already pinned in the DB before the agent has
  /// any chance to call `reply`. Reset to nil on install/uninstall.
  nonisolated(unsafe) static var dispatchInspector: (([String: Any]) -> Void)?
  nonisolated(unsafe) static var nextDispatchResponse: String =
    #"{"id":"task-uuid","status":"running"}"#
  nonisolated(unsafe) static var nextHttpResponse: String =
    #"{"status":200,"body":"{\"ok\":true,\"result\":{\"message_id\":1}}"}"#

  /// Per-Bot-API-method response overrides. The stubbed `http_request`
  /// looks up the Telegram method in this map (e.g. `getWebhookInfo`,
  /// `setWebhook`) and uses the matching response if present, otherwise
  /// falls back to `nextHttpResponse`. Lets tests express "setWebhook OK
  /// + getWebhookInfo confirms" or "setWebhook OK + getWebhookInfo shows
  /// recent error" without juggling a queue.
  nonisolated(unsafe) static var httpResponseByMethod: [String: String] = [:]

  /// FIFO response queues per Bot-API method, consulted BEFORE
  /// `httpResponseByMethod`. Lets a test express sequences like
  /// "sendChatAction: first a 429, then a 200" for retry-path coverage.
  nonisolated(unsafe) static var httpResponseQueueByMethod: [String: [String]] = [:]

  /// Most recent URL passed to setWebhook. The stubbed `getWebhookInfo`
  /// echoes this when no explicit override is configured, so the
  /// happy-path tests reflect Telegram-like behavior (i.e. "the URL you
  /// just set is now what I have registered").
  nonisolated(unsafe) static var lastRegisteredURL: String = ""

  /// Files exposed to the plugin's `file_read` host callback, keyed by
  /// requested path. Each entry is the (mime_type, raw bytes) tuple
  /// `readHostFile` will surface back to the caller. Tests seed this
  /// before driving `handleArtifactShare` (the auto-forward hook) so
  /// the upload resolves a real payload instead of an "unavailable"
  /// failure.
  nonisolated(unsafe) static var fileReadStore: [String: (mimeType: String, data: Data)] = [:]

  /// When non-nil, the stubbed `file_read` returns this error verbatim
  /// instead of looking up `fileReadStore`. Used to exercise the
  /// failure path (missing file, permission denied, etc.).
  nonisolated(unsafe) static var fileReadError: String?

  /// Captures every path the plugin asked `file_read` for. Lets tests
  /// assert the artifact hook forwarded the host payload's path verbatim.
  nonisolated(unsafe) static var fileReadCalls: [String] = []

  /// If non-nil, the stubbed `getWebhookInfo` reports this delivery error.
  /// Tests can set this to simulate "Telegram accepted setWebhook but
  /// can't actually reach the URL" scenarios.
  nonisolated(unsafe) static var simulatedWebhookErrorMessage: String?
  nonisolated(unsafe) static var simulatedWebhookErrorDate: Int = 0

  nonisolated(unsafe) static var apiTable = OsrHostAPI()
}

enum TestHost {

  /// Installs the stub host API. Call from `setUp`.
  static func install() {
    TestHostGlobals.configStore = [:]
    TestHostGlobals.activeAgentId = defaultTestAgentId
    TestHostGlobals.dispatchCalls = []
    TestHostGlobals.interruptCalls = []
    TestHostGlobals.cancelCalls = []
    TestHostGlobals.httpCalls = []
    TestHostGlobals.nextDispatchResponse =
      #"{"id":"task-uuid","status":"running"}"#
    TestHostGlobals.nextHttpResponse =
      #"{"status":200,"body":"{\"ok\":true,\"result\":{\"message_id\":1}}"}"#
    TestHostGlobals.httpResponseByMethod = [:]
    TestHostGlobals.httpResponseQueueByMethod = [:]
    TestHostGlobals.lastRegisteredURL = ""
    TestHostGlobals.simulatedWebhookErrorMessage = nil
    TestHostGlobals.simulatedWebhookErrorDate = 0
    TestHostGlobals.dispatchInspector = nil
    TestHostGlobals.fileReadStore = [:]
    TestHostGlobals.fileReadError = nil
    TestHostGlobals.fileReadCalls = []

    if TestHostGlobals.db != nil {
      sqlite3_close(TestHostGlobals.db)
      TestHostGlobals.db = nil
    }
    var handle: OpaquePointer?
    let rc = sqlite3_open(":memory:", &handle)
    precondition(rc == SQLITE_OK, "failed to open in-memory sqlite")
    TestHostGlobals.db = handle

    var api = OsrHostAPI()
    api.version = 6
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
    api.file_read = stub_file_read
    api.list_active_tasks = stub_list_active_tasks
    api.get_active_agent_id = stub_get_active_agent_id
    // v5 / v6 slots — `log_structured` is unused by the plugin but
    // wiring it ensures any future call lands on a known stub instead
    // of NULL. `free_string` mirrors the host's allocator-stable free
    // path so tests exercise the same code path as production.
    api.log_structured = stub_log_structured
    api.free_string = stub_host_free_string

    TestHostGlobals.apiTable = api
    withUnsafePointer(to: &TestHostGlobals.apiTable) { ptr in
      // Same injection path as production entry_v2: raw pointer for the
      // slots the bridge doesn't cover (db/http/dispatch/file_read/...),
      // plus HostBridge for config/log/agent-id/free.
      hostAPI = ptr
      HostBridge.shared.install(ptr)
    }
  }

  /// Tears down the stub host API. Call from `tearDown`.
  static func uninstall() {
    hostAPI = nil
    HostBridge.shared.install(nil)
    if let handle = TestHostGlobals.db {
      sqlite3_close(handle)
      TestHostGlobals.db = nil
    }
    TestHostGlobals.configStore = [:]
    TestHostGlobals.activeAgentId = defaultTestAgentId
    TestHostGlobals.dispatchCalls = []
    TestHostGlobals.interruptCalls = []
    TestHostGlobals.cancelCalls = []
    TestHostGlobals.httpCalls = []
    TestHostGlobals.httpResponseQueueByMethod = [:]
    TestHostGlobals.dispatchInspector = nil
    TestHostGlobals.fileReadStore = [:]
    TestHostGlobals.fileReadError = nil
    TestHostGlobals.fileReadCalls = []
  }

  // MARK: - Per-agent config helpers

  /// Pre-populate the per-agent config store. Use BEFORE driving the
  /// plugin to seed bot_token / tunnel_url / webhook_secret as if the
  /// host had loaded them from Keychain.
  static func setConfig(agent: String, _ key: String, _ value: String?) {
    if let value {
      TestHostGlobals.configStore[agent, default: [:]][key] = value
    } else {
      TestHostGlobals.configStore[agent]?.removeValue(forKey: key)
    }
  }

  /// Read what the plugin wrote for a given agent (e.g. to assert that
  /// the `webhook_registered` flag flipped on the right agent).
  static func getConfig(agent: String, _ key: String) -> String? {
    TestHostGlobals.configStore[agent]?[key]
  }

  /// Set the agent UUID that `get_active_agent_id()` resolves to.
  /// Pass `nil` to simulate a callback firing with no per-agent frame
  /// (e.g. an older host or a background thread).
  static func setActiveAgent(_ id: String?) {
    TestHostGlobals.activeAgentId = id
  }
}

// MARK: - C function pointer stubs

private let stub_config_get: OsrConfigGetFn = { keyPtr in
  guard let keyPtr else { return nil }
  let key = String(cString: keyPtr)
  // Mirrors the real host: outside a per-agent frame we'd resolve to
  // a "default agent" fallback. Tests that pre-populate before setting
  // activeAgentId will get nil here, matching production.
  guard let agent = TestHostGlobals.activeAgentId,
    let value = TestHostGlobals.configStore[agent]?[key]
  else { return nil }
  return UnsafePointer(strdup(value))
}

private let stub_config_set: OsrConfigSetFn = { keyPtr, valuePtr in
  guard let keyPtr, let valuePtr,
    let agent = TestHostGlobals.activeAgentId
  else { return }
  TestHostGlobals.configStore[agent, default: [:]][String(cString: keyPtr)] =
    String(cString: valuePtr)
}

private let stub_config_delete: OsrConfigDeleteFn = { keyPtr in
  guard let keyPtr, let agent = TestHostGlobals.activeAgentId else { return }
  TestHostGlobals.configStore[agent]?.removeValue(forKey: String(cString: keyPtr))
}

private let stub_log: OsrLogFn = { _, _ in /* swallow */ }

private let stub_log_structured: OsrLogStructuredFn = { _, _, _ in /* swallow */ }

private let stub_get_active_agent_id: OsrGetActiveAgentIdFn = {
  guard let id = TestHostGlobals.activeAgentId else { return nil }
  return UnsafePointer(strdup(id))
}

/// Mirrors the real host's `free_string`: it's just `libc free` on the
/// pointer the host allocated with `strdup`. Wiring this in tests means
/// the production code path (which prefers `host->free_string` over a
/// direct `libc free()`) is exercised end-to-end.
private let stub_host_free_string: OsrHostFreeStringFn = { ptr in
  guard let ptr else { return }
  free(UnsafeMutableRawPointer(mutating: ptr))
}

private let stub_db_exec: OsrDbExecFn = { sqlPtr, paramsPtr in
  guard let sqlPtr else { return nil }
  let sql = String(cString: sqlPtr)
  let params = paramsPtr.map { String(cString: $0) } ?? "[]"

  TestHostGlobals.dbLock.lock()
  defer { TestHostGlobals.dbLock.unlock() }

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
  // Mirror the real host's exec result: {"changes":N,"last_insert_rowid":N}.
  let changes = sqlite3_changes(db)
  let lastId = sqlite3_last_insert_rowid(db)
  return UnsafePointer(strdup(#"{"changes":\#(changes),"last_insert_rowid":\#(lastId)}"#))
}

private let stub_db_query: OsrDbQueryFn = { sqlPtr, paramsPtr in
  guard let sqlPtr else { return nil }
  let sql = String(cString: sqlPtr)
  let params = paramsPtr.map { String(cString: $0) } ?? "[]"

  TestHostGlobals.dbLock.lock()
  defer { TestHostGlobals.dbLock.unlock() }

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

private let stub_dispatch: OsrDispatchFn = { reqPtr in
  guard let reqPtr else { return nil }
  let req = String(cString: reqPtr)
  if let parsed = parseJSONObject(req) {
    TestHostGlobals.dispatchCalls.append(parsed)
    // Inspector runs after the call is recorded but before we return —
    // i.e. at the instant the host would start scheduling the agent.
    // The agent has NOT yet had any opportunity to call `reply`, so any
    // pre-bound row must already be visible in the DB at this point.
    TestHostGlobals.dispatchInspector?(parsed)
  }
  return UnsafePointer(strdup(TestHostGlobals.nextDispatchResponse))
}

private let stub_dispatch_cancel: OsrDispatchCancelFn = { taskIdPtr in
  guard let taskIdPtr else { return }
  TestHostGlobals.cancelCalls.append(String(cString: taskIdPtr))
}

private let stub_dispatch_interrupt: OsrDispatchInterruptFn = { taskIdPtr, textPtr in
  guard let taskIdPtr, let textPtr else { return }
  TestHostGlobals.interruptCalls.append(
    (taskId: String(cString: taskIdPtr), text: String(cString: textPtr)))
}

private let stub_http_request: OsrHttpRequestFn = { reqPtr in
  guard let reqPtr else { return nil }
  let req = String(cString: reqPtr)
  let parsed = parseJSONObject(req)
  if let parsed { TestHostGlobals.httpCalls.append(parsed) }

  // Parse the Telegram API method out of the URL (.../bot<token>/<method>).
  let method: String? = {
    guard let url = parsed?["url"] as? String,
      let lastSlash = url.lastIndex(of: "/")
    else { return nil }
    return String(url[url.index(after: lastSlash)...])
  }()

  // setWebhook side-effect: remember the URL the plugin tried to register
  // so getWebhookInfo can echo it back, mirroring real Telegram behavior.
  if method == "setWebhook",
    let bodyStr = parsed?["body"] as? String,
    let bodyData = bodyStr.data(using: .utf8),
    let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
    let registered = body["url"] as? String
  {
    TestHostGlobals.lastRegisteredURL = registered
  }

  // Auto-respond to getWebhookInfo with the most recently registered URL
  // (and any simulated delivery error), unless the test set an explicit
  // override.
  if method == "getWebhookInfo",
    TestHostGlobals.httpResponseByMethod["getWebhookInfo"] == nil
  {
    return UnsafePointer(strdup(buildGetWebhookInfoResponse()))
  }

  // Queued responses win over the static per-method override so tests
  // can express ordered sequences (e.g. 429 then 200).
  if let method, var queue = TestHostGlobals.httpResponseQueueByMethod[method],
    !queue.isEmpty
  {
    let response = queue.removeFirst()
    TestHostGlobals.httpResponseQueueByMethod[method] = queue
    return UnsafePointer(strdup(response))
  }

  let response =
    (method.flatMap { TestHostGlobals.httpResponseByMethod[$0] })
    ?? TestHostGlobals.nextHttpResponse
  return UnsafePointer(strdup(response))
}

private func buildGetWebhookInfoResponse() -> String {
  var result: [String: Any] = [
    "url": TestHostGlobals.lastRegisteredURL,
    "pending_update_count": 0,
    "has_custom_certificate": false,
  ]
  if let msg = TestHostGlobals.simulatedWebhookErrorMessage {
    result["last_error_message"] = msg
    result["last_error_date"] =
      TestHostGlobals.simulatedWebhookErrorDate == 0
      ? Int(Date().timeIntervalSince1970)
      : TestHostGlobals.simulatedWebhookErrorDate
  }
  let body = String(
    data: try! JSONSerialization.data(withJSONObject: ["ok": true, "result": result]),
    encoding: .utf8)!
  let env: [String: Any] = ["status": 200, "body": body]
  return String(
    data: try! JSONSerialization.data(withJSONObject: env), encoding: .utf8)!
}

private let stub_list_active_tasks: OsrListActiveTasksFn = {
  return UnsafePointer(strdup(#"{"tasks":[]}"#))
}

/// Mirrors the production host's `file_read`: takes a JSON request with a
/// `path` field and returns either `{"data": <base64>, "mime_type": "..."}`
/// or `{"error": "..."}`. Tests seed `fileReadStore` (success) or
/// `fileReadError` (failure) before driving `handleArtifactShare`.
private let stub_file_read: OsrFileReadFn = { reqPtr in
  guard let reqPtr else { return nil }
  let req = String(cString: reqPtr)
  let path = (parseJSONObject(req)?["path"] as? String) ?? ""
  TestHostGlobals.fileReadCalls.append(path)

  if let errMsg = TestHostGlobals.fileReadError {
    let env: [String: Any] = ["error": errMsg]
    let json = String(
      data: try! JSONSerialization.data(withJSONObject: env), encoding: .utf8)!
    return UnsafePointer(strdup(json))
  }

  guard let entry = TestHostGlobals.fileReadStore[path] else {
    let env: [String: Any] = ["error": "file not found: \(path)"]
    let json = String(
      data: try! JSONSerialization.data(withJSONObject: env), encoding: .utf8)!
    return UnsafePointer(strdup(json))
  }

  let env: [String: Any] = [
    "data": entry.data.base64EncodedString(),
    "mime_type": entry.mimeType,
  ]
  let json = String(
    data: try! JSONSerialization.data(withJSONObject: env), encoding: .utf8)!
  return UnsafePointer(strdup(json))
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
