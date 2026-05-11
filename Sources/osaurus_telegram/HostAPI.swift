import Foundation

// MARK: - C ABI Surface (v2)
//
// Frozen layout. The host loads us via dlopen and reads `osr_host_api` /
// `osr_plugin_api` byte-for-byte; reordering or removing fields would
// silently corrupt callbacks. Add new entries only at the end.

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

// Extended Agent Dispatch (v2 trailing fields)
typealias osr_list_active_tasks_fn = @convention(c) () -> UnsafePointer<CChar>?
typealias osr_send_draft_fn =
  @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
typealias osr_dispatch_interrupt_fn =
  @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
typealias osr_dispatch_add_issue_fn =
  @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?

// ABI v4: agent context resolution
//
// Returns the UUID of the agent whose frame we're currently inside (handle_route,
// invoke, on_config_changed, on_task_event), or NULL outside any per-agent frame
// (e.g. plugin init or a background thread the plugin spawned). Callers must
// release the returned C string with `free_string`.
typealias osr_get_active_agent_id_fn = @convention(c) () -> UnsafePointer<CChar>?

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

  // Extended Agent Dispatch (v2 trailing fields)
  var list_active_tasks: osr_list_active_tasks_fn?
  var send_draft: osr_send_draft_fn?
  var dispatch_interrupt: osr_dispatch_interrupt_fn?
  var dispatch_add_issue: osr_dispatch_add_issue_fn?

  // ABI v4: agent context resolution. NULL on older hosts and outside per-agent
  // frames. Always guard reads with `version >= 4` AND a nil-check on the slot.
  var get_active_agent_id: osr_get_active_agent_id_fn?
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
