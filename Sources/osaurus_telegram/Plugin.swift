import Foundation

// MARK: - Plugin API table
//
// We assemble the function table once at module init and hand the same
// pointer to the host on every entry. Closures here are thin trampolines:
// validate inputs, look up the PluginContext, and call into the per-callback
// implementations defined in WebhookHandler.swift / Tools.swift / etc.

private nonisolated(unsafe) var api: osr_plugin_api = makeAPI()

private func makeAPI() -> osr_plugin_api {
  var api = osr_plugin_api()
  api.version = 2

  api.free_string = { ptr in
    if let p = ptr { free(UnsafeMutableRawPointer(mutating: p)) }
  }

  api.`init` = {
    let ctx = PluginContext()
    initPlugin(ctx)
    logHostAPIAvailability()
    return Unmanaged.passRetained(ctx).toOpaque()
  }

  api.destroy = { ctxPtr in
    guard let ctxPtr else { return }
    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    destroyPlugin(ctx)
    Unmanaged<PluginContext>.fromOpaque(ctxPtr).release()
  }

  api.get_manifest = { _ in makeCString(pluginManifestJSON) }

  api.invoke = { ctxPtr, typePtr, idPtr, payloadPtr in
    guard let ctxPtr, let typePtr, let idPtr, let payloadPtr else {
      logWarn("invoke called with nil parameters")
      return nil
    }
    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    let type = String(cString: typePtr)
    let id = String(cString: idPtr)
    let payload = String(cString: payloadPtr)
    return makeCString(handleInvoke(ctx: ctx, type: type, id: id, payload: payload))
  }

  api.handle_route = { ctxPtr, requestJsonPtr in
    guard let ctxPtr, let requestJsonPtr else {
      logWarn("handle_route called with nil parameters")
      return nil
    }
    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    let requestJson = String(cString: requestJsonPtr)
    return makeCString(handleRoute(ctx: ctx, requestJSON: requestJson))
  }

  api.on_config_changed = { ctxPtr, keyPtr, valuePtr in
    guard let ctxPtr, let keyPtr else {
      logWarn("on_config_changed called with nil parameters")
      return
    }
    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    let key = String(cString: keyPtr)
    let value = valuePtr.map { String(cString: $0) }
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
    handleTaskEvent(ctx: ctx, taskId: taskId, eventType: eventType, eventJSON: eventJson)
  }

  return api
}

// MARK: - Invoke dispatcher

private func handleInvoke(
  ctx: PluginContext, type: String, id: String, payload: String
) -> String {
  logDebug("invoke: type=\(type) id=\(id) payload=\(payload.count) chars")

  guard type == "tool" else {
    logWarn("invoke: unknown capability type '\(type)'")
    return toolEnvelopeError("unknown_capability", "Type \(type) not supported")
  }

  switch id {
  case "reply":
    return handleReply(ctx: ctx, payload: payload)
  case "reply_typing":
    return handleReplyTyping(ctx: ctx, payload: payload)
  case "reply_photo":
    return handleReplyPhoto(ctx: ctx, payload: payload)
  default:
    logWarn("invoke: unknown tool '\(id)'")
    return toolEnvelopeError("unknown_tool", "Unknown tool: \(id)")
  }
}

// MARK: - Diagnostics

private func logHostAPIAvailability() {
  let checks: [(String, Bool)] = [
    ("dispatch", hostAPI?.pointee.dispatch != nil),
    ("dispatch_interrupt", hostAPI?.pointee.dispatch_interrupt != nil),
    ("dispatch_cancel", hostAPI?.pointee.dispatch_cancel != nil),
    ("http_request", hostAPI?.pointee.http_request != nil),
    ("db_exec", hostAPI?.pointee.db_exec != nil),
    ("db_query", hostAPI?.pointee.db_query != nil),
    ("config_get", hostAPI?.pointee.config_get != nil),
    ("log", hostAPI?.pointee.log != nil),
    ("list_active_tasks", hostAPI?.pointee.list_active_tasks != nil),
  ]
  let available = checks.filter { $0.1 }.map { $0.0 }
  let missing = checks.filter { !$0.1 }.map { $0.0 }
  logInfo(
    "Plugin init complete. Host APIs available: [\(available.joined(separator: ", "))], missing: [\(missing.joined(separator: ", "))]"
  )
}

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
