import Foundation
import OsaurusPluginABI
import OsaurusPluginKit

// MARK: - C ABI Surface
//
// The hand-rolled `osr_host_api` / `osr_plugin_api` mirrors (previously in
// HostAPI.swift) are replaced by the pinned `osaurus-plugin-sdk`'s
// `OsrHostAPI` / `OsrPluginAPI`, which pin the frozen v6 layout (offsets
// 0 / 176 / 184 / 192, stride 200). `HostBridge.shared` (installed by
// `PluginEntry.enterV2`) covers config, logging, agent-id resolution, and
// host-string freeing; the raw pointer below is kept for the slots the
// bridge does not expose (db_exec / db_query / dispatch /
// dispatch_interrupt / dispatch_cancel / http_request / file_read /
// list_active_tasks).

nonisolated(unsafe) var hostAPI: UnsafePointer<OsrHostAPI>?

// MARK: - Plugin API table
//
// We assemble the function table once at module init and hand the same
// pointer to the host on every entry. Closures here are thin trampolines:
// validate inputs, resolve the active agent (ABI v4) via
// `resolveAgentFrame`, and call into the per-callback implementations
// defined in WebhookHandler.swift / Tools.swift / etc.

private nonisolated(unsafe) var api: OsrPluginAPI = makeAPI()

/// Resolved agent context for one host callback. nil here means we can't
/// safely run the per-agent path (either ctx was nil, the host is older
/// than ABI v4, or we're being called outside any per-agent frame).
private struct AgentFrame {
  let registry: PluginContext
  let state: AgentState
  let agentId: String
}

/// Common preamble for every per-agent C trampoline: extract the registry,
/// resolve the active agent via `get_active_agent_id`, and look up its
/// state. Returns nil with a warning logged on any failure.
private func resolveAgentFrame(
  _ ctxPtr: OsrPluginCtx?, caller: String
) -> AgentFrame? {
  guard let ctxPtr else {
    logWarn("\(caller) called with nil ctx")
    return nil
  }
  let registry = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
  guard let agentId = getActiveAgentId() else {
    logWarn("\(caller): no active agent_id resolvable")
    return nil
  }
  return AgentFrame(registry: registry, state: registry.state(for: agentId), agentId: agentId)
}

private let noAgentRouteResponse =
  #"{"ok":false,"description":"plugin requires per-agent host frame (ABI v4)"}"#

private let noAgentInvokeEnvelope = Envelope.failure(
  .unavailable,
  "Plugin invoked outside any per-agent frame. Host must implement ABI v4.")

/// Best-effort routing for artifact events fired without a per-agent
/// frame. The host's file watcher can dispatch `invoke(type: "artifact", ...)`
/// from a thread that doesn't bind a frame — without this fallback the
/// user would never receive generated files.
///
/// Multi-agent safety: we only auto-route when the cross-agent picture
/// is unambiguous (exactly ONE agent has any in-flight dispatch). With
/// two or more agents in flight at the same instant, a "latest task
/// wins" heuristic would silently mis-deliver the file to the wrong
/// user; we drop with a warn-level log instead so the misroute is
/// loud and the user just sees nothing rather than the wrong thing.
/// In the common single-agent install this is exactly the legacy
/// behaviour.
private func routeArtifactWithoutFrame(
  ctxPtr: OsrPluginCtx?, payload: String
) -> String {
  guard let ctxPtr else {
    logWarn(
      "invoke: artifact fired without a per-agent frame AND nil ctx; "
        + "skipping (payload=\(payload.count) chars)")
    return #"{"skipped":true,"reason":"no_agent_frame_no_dispatch"}"#
  }
  let inFlight = DatabaseManager.inFlightAgentCount()
  if inFlight == 0 {
    logWarn(
      "invoke: artifact fired without a per-agent frame AND no in-flight dispatch; "
        + "skipping (payload=\(payload.count) chars)")
    return #"{"skipped":true,"reason":"no_agent_frame_no_dispatch"}"#
  }
  if inFlight > 1 {
    logWarn(
      "invoke: artifact fired without a per-agent frame AND multiple agents in flight "
        + "(count=\(inFlight)); refusing to guess which chat to route to "
        + "(payload=\(payload.count) chars)")
    return #"{"skipped":true,"reason":"ambiguous_agent_no_frame"}"#
  }
  // Exactly one agent in flight — unambiguous. Pick its latest dispatch.
  guard let binding = DatabaseManager.latestActiveDispatchAcrossAgents() else {
    return #"{"skipped":true,"reason":"no_agent_frame_no_dispatch"}"#
  }
  let registry = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
  let state = registry.state(for: binding.agentId)
  logInfo(
    "invoke: artifact fallback (no per-agent frame, single in-flight agent) "
      + "routing via DB agent=\(binding.agentId) chat=\(binding.chatId) "
      + "task=\(binding.taskId)")
  return handleArtifactShare(state: state, payload: payload)
}

private func makeAPI() -> OsrPluginAPI {
  PluginEntry.makeAPI(
    version: OsrABIVersion.v2,
    init: {
      let ctx = PluginContext()
      initPlugin(ctx)
      logHostAPIAvailability()
      return Unmanaged.passRetained(ctx).toOpaque()
    },
    destroy: { ctxPtr in
      guard let ctxPtr else { return }
      let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
      // We're outside any per-agent frame — iterate every cached agent and
      // tear down its Telegram webhook directly. We deliberately skip
      // `setWebhookRegistered(false)` per-agent because that would write to
      // the host's default-agent fallback (no TLS).
      for (_, state) in ctx.allStates() {
        destroyAgent(state: state)
      }
      Unmanaged<PluginContext>.fromOpaque(ctxPtr).release()
    },
    getManifest: { _ in osrMakeCString(pluginManifestJSON) },
    invoke: { ctxPtr, typePtr, idPtr, payloadPtr in
      guard let typePtr, let idPtr, let payloadPtr else {
        logWarn("invoke called with nil arguments")
        return nil
      }
      let type = String(cString: typePtr)
      let id = String(cString: idPtr)
      let payload = String(cString: payloadPtr)

      if let frame = resolveAgentFrame(ctxPtr, caller: "invoke") {
        return osrMakeCString(
          handleInvoke(state: frame.state, type: type, id: id, payload: payload))
      }

      // No per-agent frame. Artifact events specifically have a fallback
      // path (see `routeArtifactWithoutFrame`); everything else is rejected.
      if type == "artifact" {
        return osrMakeCString(routeArtifactWithoutFrame(ctxPtr: ctxPtr, payload: payload))
      }
      return osrMakeCString(noAgentInvokeEnvelope)
    },
    handleRoute: { ctxPtr, requestJsonPtr in
      guard let requestJsonPtr else {
        logWarn("handle_route called with nil request")
        return nil
      }
      guard let frame = resolveAgentFrame(ctxPtr, caller: "handle_route") else {
        return osrMakeCString(makeRouteResponse(status: 503, body: noAgentRouteResponse))
      }
      return osrMakeCString(
        handleRoute(
          state: frame.state, agentId: frame.agentId,
          requestJSON: String(cString: requestJsonPtr)))
    },
    onConfigChanged: { ctxPtr, keyPtr, valuePtr in
      guard let keyPtr else {
        logWarn("on_config_changed called with nil key")
        return
      }
      let key = String(cString: keyPtr)
      // Pre-flight ABI probe (v6+). The host fires this synthetic
      // (key, UUID) pair through `on_config_changed` before any real
      // per-agent push, specifically to trigger a misalignment crash if
      // the `osr_host_api` mirror is wrong. Early-return here keeps the
      // probe cheap and stops a synthetic agent_id from leaking into the
      // registry (which would generate a webhook_secret for a
      // non-existent agent). See docs/plugins/HOST_API.md → "Pre-flight
      // ABI probe".
      if key == "__osaurus_abi_probe__" {
        logDebug("on_config_changed: ABI probe acknowledged")
        return
      }
      guard let frame = resolveAgentFrame(ctxPtr, caller: "on_config_changed") else { return }
      onConfigChanged(
        state: frame.state,
        key: key,
        value: valuePtr.map { String(cString: $0) })
    },
    onTaskEvent: { ctxPtr, taskIdPtr, eventType, eventJsonPtr in
      guard let taskIdPtr, let eventJsonPtr else {
        logWarn("on_task_event called with nil arguments")
        return
      }
      guard let frame = resolveAgentFrame(ctxPtr, caller: "on_task_event") else { return }
      handleTaskEvent(
        state: frame.state, agentId: frame.agentId,
        taskId: String(cString: taskIdPtr),
        eventType: eventType,
        eventJSON: String(cString: eventJsonPtr))
    }
  )
}

// MARK: - Invoke dispatcher

private func handleInvoke(
  state: AgentState, type: String, id: String, payload: String
) -> String {
  state.log(.debug, "invoke: type=\(type) id=\(id) payload=\(payload.count) chars")

  // Artifact auto-forward: the host fires this whenever the agent
  // writes a file under ~/.osaurus/artifacts/. We don't switch on `id`
  // — historically the host has only ever passed "share" here and there
  // is no benefit to being strict.
  if type == "artifact" {
    return handleArtifactShare(state: state, payload: payload)
  }

  guard type == "tool" else {
    logWarn("invoke: unknown capability type '\(type)'")
    return Envelope.failure(.invalidArgs, "Type \(type) not supported")
  }

  switch id {
  case "reply": return handleReply(state: state, payload: payload)
  case "reply_typing": return handleReplyTyping(state: state, payload: payload)
  case "reply_photo": return handleReplyPhoto(state: state, payload: payload)
  case "reply_document": return handleReplyDocument(state: state, payload: payload)
  case "reply_voice": return handleReplyVoice(state: state, payload: payload)
  case "reply_audio": return handleReplyAudio(state: state, payload: payload)
  case "reply_video": return handleReplyVideo(state: state, payload: payload)
  default:
    logWarn("invoke: unknown tool '\(id)'")
    return Envelope.failure(.notFound, "Unknown tool: \(id)")
  }
}

// MARK: - Diagnostics

private func logHostAPIAvailability() {
  let hostVersion = hostAPI?.pointee.version ?? 0
  let checks: [(String, Bool)] = [
    ("dispatch", hostAPI?.pointee.dispatch != nil),
    ("dispatch_interrupt", hostAPI?.pointee.dispatch_interrupt != nil),
    ("dispatch_cancel", hostAPI?.pointee.dispatch_cancel != nil),
    ("http_request", hostAPI?.pointee.http_request != nil),
    ("file_read", hostAPI?.pointee.file_read != nil),
    ("db_exec", hostAPI?.pointee.db_exec != nil),
    ("db_query", hostAPI?.pointee.db_query != nil),
    ("config_get", hostAPI?.pointee.config_get != nil),
    ("log", hostAPI?.pointee.log != nil),
    ("list_active_tasks", hostAPI?.pointee.list_active_tasks != nil),
    // ABI v4
    ("get_active_agent_id", hostVersion >= 4 && hostAPI?.pointee.get_active_agent_id != nil),
  ]
  let available = checks.filter { $0.1 }.map { $0.0 }
  let missing = checks.filter { !$0.1 }.map { $0.0 }
  logInfo(
    "Plugin init complete (host ABI v\(hostVersion)). Host APIs available: "
      + "[\(available.joined(separator: ", "))], missing: [\(missing.joined(separator: ", "))]")
  if hostVersion < 4 {
    logWarn(
      "Host ABI < 4: no per-agent isolation possible. Per-agent callbacks will be rejected. "
        + "Upgrade Osaurus to a version that exposes get_active_agent_id.")
  }
}

// MARK: - Entry Points

@_cdecl("osaurus_plugin_entry_v2")
public func osaurus_plugin_entry_v2(_ host: UnsafeRawPointer?) -> UnsafeRawPointer? {
  hostAPI = host?.assumingMemoryBound(to: OsrHostAPI.self)
  return PluginEntry.enterV2(host, api: &api)
}

@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
  return PluginEntry.enterV1(api: &api)
}
