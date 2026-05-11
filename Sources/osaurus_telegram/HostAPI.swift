import Foundation

// MARK: - C ABI Surface
//
// Mirrors `osr_host_api` from the Osaurus plugin SDK
// (`Packages/OsaurusCore/Tools/PluginABI/osaurus_plugin.h`). The struct
// layout is FROZEN — every slot's offset is pinned. Host versions append
// new callbacks at the end; mirrors that drop or reorder a single slot
// dispatch every later callback into the wrong host function and
// typically crash inside `libc free()` on a non-malloc pointer.
//
// Pinned offsets (Apple Silicon, default C alignment) at the time of
// writing — these MUST match what the host writes:
//   version              0
//   get_active_agent_id  176
//   log_structured       184
//   free_string          192
//   (struct stride)      200
//
// `Tests/.../HostAPILayoutTests.swift` asserts these offsets at test
// time so a future skipped slot fails CI before it ships.

typealias osr_plugin_ctx_t = UnsafeMutableRawPointer

// Config + Storage + Logging
typealias osr_config_get_fn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_config_set_fn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
typealias osr_config_delete_fn = @convention(c) (UnsafePointer<CChar>?) -> Void
typealias osr_db_exec_fn =
  @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_db_query_fn =
  @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_log_fn = @convention(c) (Int32, UnsafePointer<CChar>?) -> Void

// Agent Dispatch
typealias osr_dispatch_fn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_task_status_fn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_dispatch_cancel_fn = @convention(c) (UnsafePointer<CChar>?) -> Void
typealias osr_dispatch_clarify_fn =
  @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void

// Inference
typealias osr_complete_fn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_complete_stream_fn =
  @convention(c) (
    UnsafePointer<CChar>?,
    (@convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void)?,
    UnsafeMutableRawPointer?
  ) -> UnsafePointer<CChar>?
typealias osr_embed_fn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_list_models_fn = @convention(c) () -> UnsafePointer<CChar>?

// HTTP Client
typealias osr_http_request_fn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?

// File I/O
typealias osr_file_read_fn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?

// Extended Agent Dispatch (added in v2; preserved through v6)
typealias osr_list_active_tasks_fn = @convention(c) () -> UnsafePointer<CChar>?
typealias osr_send_draft_fn =
  @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
typealias osr_dispatch_interrupt_fn =
  @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
typealias osr_dispatch_add_issue_fn =
  @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?

// ABI v3: streaming control. Cancels an in-flight `complete_stream` by
// the `stream_id` UUID the plugin passed in the request body.
typealias osr_complete_cancel_fn = @convention(c) (UnsafePointer<CChar>?) -> Void

// ABI v4: agent context resolution.
//
// Returns the UUID of the agent whose frame we're currently inside
// (handle_route, invoke, on_config_changed, on_task_event), or NULL
// outside any per-agent frame (e.g. plugin init or a background thread
// the plugin spawned). Callers must release the returned C string with
// `host->free_string` (v6+) or `libc free()` on older hosts.
typealias osr_get_active_agent_id_fn = @convention(c) () -> UnsafePointer<CChar>?

// ABI v5: structured logging companion to `osr_log_fn`. `payload` is a
// JSON object string surfaced as searchable fields in Insights. Pass
// nil to log a message with no fields.
typealias osr_log_structured_fn =
  @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void

// ABI v6: host-side `free_string`. Pairs with the `strdup` every host
// trampoline uses for its return value. NULL is a no-op. Plugins MUST
// use this for host-returned strings instead of the plugin's own
// `free_string` (which is the *opposite* direction). Older hosts leave
// this slot NULL and the plugin should fall back to `libc free()`.
typealias osr_host_free_string_fn = @convention(c) (UnsafePointer<CChar>?) -> Void

struct osr_host_api {
  var version: UInt32 = 0

  // Config + Storage + Logging
  var config_get: osr_config_get_fn?
  var config_set: osr_config_set_fn?
  var config_delete: osr_config_delete_fn?
  var db_exec: osr_db_exec_fn?
  var db_query: osr_db_query_fn?
  var log: osr_log_fn?

  // Agent Dispatch
  var dispatch: osr_dispatch_fn?
  var task_status: osr_task_status_fn?
  var dispatch_cancel: osr_dispatch_cancel_fn?
  var dispatch_clarify: osr_dispatch_clarify_fn?

  // Inference
  var complete: osr_complete_fn?
  var complete_stream: osr_complete_stream_fn?
  var embed: osr_embed_fn?
  var list_models: osr_list_models_fn?

  // HTTP Client
  var http_request: osr_http_request_fn?

  // File I/O
  var file_read: osr_file_read_fn?

  // Extended Agent Dispatch (added in v2; preserved through v6)
  var list_active_tasks: osr_list_active_tasks_fn?
  var send_draft: osr_send_draft_fn?
  var dispatch_interrupt: osr_dispatch_interrupt_fn?
  var dispatch_add_issue: osr_dispatch_add_issue_fn?

  // Streaming control (added in v3). NULL on v2 hosts.
  var complete_cancel: osr_complete_cancel_fn?

  // Agent context introspection (added in v4). NULL on v3 and earlier
  // hosts. Always guard with `version >= 4` before invoking.
  var get_active_agent_id: osr_get_active_agent_id_fn?

  // Structured logging (added in v5). NULL on v4 and earlier hosts.
  // The slot's presence is what makes `free_string` (v6) land at the
  // right offset, so it MUST appear here even if we never call it.
  var log_structured: osr_log_structured_fn?

  // Host-side free for strings the host returned (added in v6). When
  // available, prefer this over `libc free()` so a future allocator
  // change on the host stays transparent.
  var free_string: osr_host_free_string_fn?
}

// MARK: - Plugin API table (returned to host)

typealias osr_free_string_t = @convention(c) (UnsafePointer<CChar>?) -> Void
typealias osr_init_t = @convention(c) () -> osr_plugin_ctx_t?
typealias osr_destroy_t = @convention(c) (osr_plugin_ctx_t?) -> Void
typealias osr_get_manifest_t = @convention(c) (osr_plugin_ctx_t?) -> UnsafePointer<CChar>?
typealias osr_invoke_t =
  @convention(c) (
    osr_plugin_ctx_t?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?
  ) -> UnsafePointer<CChar>?
typealias osr_handle_route_t =
  @convention(c) (osr_plugin_ctx_t?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_on_config_changed_t =
  @convention(c) (osr_plugin_ctx_t?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
typealias osr_on_task_event_t =
  @convention(c) (osr_plugin_ctx_t?, UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?) -> Void

struct osr_plugin_api {
  var free_string: osr_free_string_t?
  var `init`: osr_init_t?
  var destroy: osr_destroy_t?
  var get_manifest: osr_get_manifest_t?
  var invoke: osr_invoke_t?
  var version: UInt32 = 0
  var handle_route: osr_handle_route_t?
  var on_config_changed: osr_on_config_changed_t?
  var on_task_event: osr_on_task_event_t?
}

// MARK: - Global host pointer

nonisolated(unsafe) var hostAPI: UnsafePointer<osr_host_api>?

// MARK: - C-string helpers

/// Allocates a C string the host will own and free via our `free_string`.
func makeCString(_ s: String) -> UnsafePointer<CChar>? {
  guard let ptr = strdup(s) else { return nil }
  return UnsafePointer(ptr)
}
