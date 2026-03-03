import Foundation

// MARK: - C ABI Surface (v2)

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
}

private typealias osr_free_string_t = @convention(c) (UnsafePointer<CChar>?) -> Void
private typealias osr_init_t = @convention(c) () -> osr_plugin_ctx_t?
private typealias osr_destroy_t = @convention(c) (osr_plugin_ctx_t?) -> Void
private typealias osr_get_manifest_t = @convention(c) (osr_plugin_ctx_t?) -> UnsafePointer<CChar>?
private typealias osr_invoke_t =
  @convention(c) (
    osr_plugin_ctx_t?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?
  ) -> UnsafePointer<CChar>?
private typealias osr_handle_route_t =
  @convention(c) (osr_plugin_ctx_t?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
private typealias osr_on_config_changed_t =
  @convention(c) (osr_plugin_ctx_t?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
private typealias osr_on_task_event_t =
  @convention(c) (osr_plugin_ctx_t?, UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?) -> Void

private struct osr_plugin_api {
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

// MARK: - Global State

nonisolated(unsafe) var hostAPI: UnsafePointer<osr_host_api>?

func makeCString(_ s: String) -> UnsafePointer<CChar>? {
  guard let ptr = strdup(s) else { return nil }
  return UnsafePointer(ptr)
}

// MARK: - Plugin API Implementation

private nonisolated(unsafe) var api: osr_plugin_api = {
  var api = osr_plugin_api()

  api.free_string = { ptr in
    if let p = ptr { free(UnsafeMutableRawPointer(mutating: p)) }
  }

  api.`init` = {
    let ctx = PluginContext()
    initPlugin(ctx)

    var available: [String] = []
    var missing: [String] = []
    let checks: [(String, Bool)] = [
      ("dispatch", hostAPI?.pointee.dispatch != nil),
      ("complete_stream", hostAPI?.pointee.complete_stream != nil),
      ("complete", hostAPI?.pointee.complete != nil),
      ("http_request", hostAPI?.pointee.http_request != nil),
      ("db_exec", hostAPI?.pointee.db_exec != nil),
      ("db_query", hostAPI?.pointee.db_query != nil),
      ("config_get", hostAPI?.pointee.config_get != nil),
      ("log", hostAPI?.pointee.log != nil),
      ("dispatch_clarify", hostAPI?.pointee.dispatch_clarify != nil),
    ]
    for (name, ok) in checks {
      if ok { available.append(name) } else { missing.append(name) }
    }
    logInfo(
      "Plugin init complete. Host APIs available: [\(available.joined(separator: ", "))], missing: [\(missing.joined(separator: ", "))]"
    )

    return Unmanaged.passRetained(ctx).toOpaque()
  }

  api.destroy = { ctxPtr in
    guard let ctxPtr else { return }
    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    destroyPlugin(ctx)
    Unmanaged<PluginContext>.fromOpaque(ctxPtr).release()
  }

  api.get_manifest = { _ in
    let manifest = """
      {
        "plugin_id": "osaurus.telegram",
        "name": "Telegram",
        "version": "0.1.0",
        "description": "Connect Telegram chats to your Osaurus agents",
        "license": "MIT",
        "authors": [],
        "min_macos": "15.0",
        "min_osaurus": "0.5.0",
        "capabilities": {
          "tools": [
            {
              "id": "telegram_send",
              "description": "Send a message to a Telegram chat. Supports text, markdown, and reply_markup for inline keyboards.",
              "parameters": {
                "type": "object",
                "properties": {
                  "chat_id": {
                    "type": "string",
                    "description": "Telegram chat ID to send to"
                  },
                  "text": {
                    "type": "string",
                    "description": "Message text. Supports MarkdownV2 formatting."
                  },
                  "reply_to_message_id": {
                    "type": "integer",
                    "description": "Optional message ID to reply to"
                  },
                  "reply_markup": {
                    "type": "object",
                    "description": "Optional inline keyboard markup"
                  }
                },
                "required": ["chat_id", "text"]
              },
              "requirements": [],
              "permission_policy": "auto"
            },
            {
              "id": "telegram_get_chat_history",
              "description": "Retrieve recent messages from the plugin's local message log for a given Telegram chat.",
              "parameters": {
                "type": "object",
                "properties": {
                  "chat_id": {
                    "type": "string",
                    "description": "Telegram chat ID"
                  },
                  "limit": {
                    "type": "integer",
                    "description": "Max messages to return (default 50, max 200)"
                  }
                },
                "required": ["chat_id"]
              },
              "requirements": [],
              "permission_policy": "auto"
            }
          ],
          "routes": [
            {
              "id": "webhook",
              "path": "/webhook",
              "methods": ["POST"],
              "description": "Telegram Bot API webhook endpoint",
              "auth": "verify"
            },
            {
              "id": "health",
              "path": "/health",
              "methods": ["GET"],
              "description": "Health check — returns webhook registration status",
              "auth": "owner"
            }
          ],
          "config": {
            "title": "Telegram",
            "sections": [
              {
                "title": "Bot Configuration",
                "fields": [
                  {
                    "key": "bot_token",
                    "type": "secret",
                    "label": "Bot Token",
                    "placeholder": "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11",
                    "description": "Get this from [@BotFather](https://t.me/BotFather)",
                    "validation": {
                      "required": true,
                      "pattern": "^[0-9]+:[A-Za-z0-9_-]+$",
                      "pattern_hint": "Must be a valid Telegram bot token (e.g. 123456:ABC...)"
                    }
                  },
                  {
                    "key": "webhook_url",
                    "type": "readonly",
                    "label": "Webhook URL",
                    "value_template": "{{plugin_url}}/webhook",
                    "copyable": true
                  },
                  {
                    "key": "webhook_status",
                    "type": "status",
                    "label": "Webhook",
                    "connected_when": "webhook_registered"
                  }
                ]
              },
              {
                "title": "Behavior",
                "fields": [
                  {
                    "key": "agent_mode",
                    "type": "select",
                    "label": "Agent Mode",
                    "options": [
                      { "value": "work", "label": "Work Mode (background, multi-step)" },
                      { "value": "chat", "label": "Chat Mode (conversational)" }
                    ],
                    "default": "work"
                  },
                  {
                    "key": "allowed_chat_ids",
                    "type": "text",
                    "label": "Allowed Chat IDs",
                    "placeholder": "Leave blank to allow all, or comma-separated IDs",
                    "description": "Restrict which Telegram chats can dispatch agent work. Empty = all chats allowed."
                  },
                  {
                    "key": "send_typing",
                    "type": "toggle",
                    "label": "Send typing indicator while agent works",
                    "default": true
                  },
                  {
                    "key": "send_progress",
                    "type": "toggle",
                    "label": "Send progress updates as messages",
                    "default": false
                  }
                ]
              }
            ]
          }
        },
        "docs": {
          "readme": "README.md",
          "changelog": "CHANGELOG.md",
          "links": [
            { "label": "Telegram Bot API", "url": "https://core.telegram.org/bots/api" },
            { "label": "BotFather", "url": "https://t.me/BotFather" }
          ]
        }
      }
      """
    return makeCString(manifest)
  }

  api.invoke = { ctxPtr, typePtr, idPtr, payloadPtr in
    guard let ctxPtr, let typePtr, let idPtr, let payloadPtr else {
      logWarn("invoke called with nil parameters")
      return nil
    }

    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    let type = String(cString: typePtr)
    let id = String(cString: idPtr)
    let payload = String(cString: payloadPtr)

    logDebug("invoke: type=\(type) id=\(id) payload=\(payload.count) chars")

    guard type == "tool" else {
      logWarn("invoke: unknown capability type '\(type)'")
      return makeCString("{\"error\":\"Unknown capability type\"}")
    }

    let result: String
    switch id {
    case ctx.telegramSendTool.name:
      result = ctx.telegramSendTool.run(args: payload)
    case ctx.chatHistoryTool.name:
      result = ctx.chatHistoryTool.run(args: payload)
    default:
      logWarn("invoke: unknown tool '\(id)'")
      return makeCString("{\"error\":\"Unknown tool: \(id)\"}")
    }

    logDebug("invoke: tool \(id) returned \(result.count) chars")
    return makeCString(result)
  }

  api.version = 2

  api.handle_route = { ctxPtr, requestJsonPtr in
    guard let ctxPtr, let requestJsonPtr else {
      logWarn("handle_route called with nil parameters")
      return nil
    }
    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    let requestJson = String(cString: requestJsonPtr)
    logDebug("handle_route: received \(requestJson.count) chars")
    let response = handleRoute(ctx: ctx, requestJSON: requestJson)
    return makeCString(response)
  }

  api.on_config_changed = { ctxPtr, keyPtr, valuePtr in
    guard let ctxPtr, let keyPtr else {
      logWarn("on_config_changed called with nil parameters")
      return
    }
    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    let key = String(cString: keyPtr)
    let value = valuePtr.map { String(cString: $0) }
    logDebug("on_config_changed: key=\(key) hasValue=\(value != nil)")
    onConfigChanged(ctx: ctx, key: key, value: value)
  }

  api.on_task_event = { ctxPtr, taskIdPtr, eventType, eventJsonPtr in
    guard let ctxPtr, let taskIdPtr, let eventJsonPtr else {
      logWarn("on_task_event called with nil parameters")
      return
    }
    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    let taskId = String(cString: taskIdPtr)
    let eventJson = String(cString: eventJsonPtr)
    logDebug(
      "on_task_event: taskId=\(taskId) eventType=\(eventType) json=\(String(eventJson.prefix(200)))"
    )
    handleTaskEvent(ctx: ctx, taskId: taskId, eventType: eventType, eventJSON: eventJson)
  }

  return api
}()

// MARK: - Entry Points

@_cdecl("osaurus_plugin_entry_v2")
public func osaurus_plugin_entry_v2(_ host: UnsafeRawPointer?) -> UnsafeRawPointer? {
  hostAPI = host?.assumingMemoryBound(to: osr_host_api.self)
  return UnsafeRawPointer(&api)
}

@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
  return UnsafeRawPointer(&api)
}
