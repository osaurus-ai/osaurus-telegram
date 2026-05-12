import Foundation

// MARK: - Task Event Handler
//
// `on_task_event` is observability + a safety net, not the delivery
// mechanism. The agent owns user-visible UI via the reply tools. We log
// every lifecycle event at debug level and only post to Telegram when a
// run terminated without ever calling reply (so the user isn't left
// hanging) or hard-failed.

/// Delay applied to the COMPLETED safety-net check.
///
/// The Osaurus host can emit COMPLETED more than once per task: first
/// after the agent's initial streaming round (carrying interim text like
/// `"No response needed."`), then again after the tool-call round finishes.
/// Posting the safety-net text on the first COMPLETED would beat the
/// agent's actual `reply` from the next round to the user — and the row
/// would be gone by the time `reply` was invoked, producing `stale_token`.
///
/// The fix: defer the check. A late `reply` flips `has_replied` and the
/// deferred handler short-circuits. Tests set this to 0 so behaviour
/// stays synchronous; production keeps a few-second cushion.
nonisolated(unsafe) var safetyNetDelaySeconds: TimeInterval = 5

private enum TaskEventType {
  static let started: Int32 = 0
  static let activity: Int32 = 1
  static let progress: Int32 = 2
  static let clarification: Int32 = 3
  static let completed: Int32 = 4
  static let failed: Int32 = 5
  static let cancelled: Int32 = 6
  static let output: Int32 = 7
  static let draft: Int32 = 8
}

private let taskEventNames: [Int32: String] = [
  0: "STARTED", 1: "ACTIVITY", 2: "PROGRESS", 3: "CLARIFICATION",
  4: "COMPLETED", 5: "FAILED", 6: "CANCELLED", 7: "OUTPUT", 8: "DRAFT",
]

func handleTaskEvent(
  state: AgentState, agentId: String, taskId: String,
  eventType: Int32, eventJSON: String
) {
  let eventName = taskEventNames[eventType] ?? "UNKNOWN(\(eventType))"
  state.log(
    .debug,
    "handleTaskEvent: taskId=\(taskId) type=\(eventName) "
      + "json=\(String(eventJSON.prefix(200)))")

  switch eventType {
  case TaskEventType.completed:
    // Snapshot the streamed-output cache value at scheduling time so the
    // deferred closure isn't observing late writes from a subsequent
    // COMPLETED on the same task. See `safetyNetDelaySeconds` comment
    // for the reason we defer.
    scheduleSafetyNet(delay: safetyNetDelaySeconds) {
      runTerminalSafetyNet(
        state: state, taskId: taskId, caller: "handleCompleted",
        logLevel: .info,
        message: {
          safetyNetCompletedMessage(
            eventJSON: eventJSON,
            streamingOutput: state.latestOutput(taskId: taskId))
        })
    }

  case TaskEventType.failed:
    // FAILED isn't fired prematurely between LLM rounds (unlike COMPLETED),
    // so the apology can post synchronously without racing a late reply.
    runTerminalSafetyNet(
      state: state, taskId: taskId, caller: "handleFailed",
      logLevel: .warn,
      message: { "Sorry, something went wrong handling that." })

  case TaskEventType.cancelled:
    // CANCELLED reaches us when /reset hard-cancels (already cleaned up in
    // handleReset) or when `dispatch_interrupt` is treated as a cancel by
    // some host versions. The current step at that moment can be the
    // reply tool call we're waiting on, so deleting the row here would
    // re-introduce exactly the stale_token race v3 was meant to fix.
    // Leave it alone — TTL retires anything /reset didn't already clear.
    logDebug("handleTaskEvent: CANCELLED for task \(taskId); leaving binding for trailing reply")

  case TaskEventType.output:
    // OUTPUT events carry the agent's running text, throttled to ~1/sec.
    // Capture the latest snapshot per task so the COMPLETED safety net
    // can fall back to the agent's actual streamed prose when the host
    // fires a multi-round COMPLETED whose `output` field contains
    // interim text instead of the final answer.
    if let obj = parseJSONObject(eventJSON),
      let text = obj["text"] as? String
    {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        state.recordOutput(taskId: taskId, text: trimmed)
      }
    }

  case TaskEventType.clarification:
    // See `handleClarification` below.
    handleClarification(state: state, taskId: taskId, eventJSON: eventJSON)

  case TaskEventType.started,
    TaskEventType.activity,
    TaskEventType.progress,
    TaskEventType.draft:
    // Observability only. Agent owns user-visible UI via tools.
    break

  default:
    logWarn("Unknown task event type \(eventType) for task \(taskId)")
  }
}

// MARK: - Terminal events
//
// COMPLETED and FAILED share this body — only the message text and log
// level differ. The row is intentionally NOT deleted here; a late `reply`
// from a subsequent LLM round still needs the binding. The 10-minute
// TTL sweep retires anything that never gets replied to.

private func runTerminalSafetyNet(
  state: AgentState,
  taskId: String,
  caller: String,
  logLevel: LogLevel,
  message: () -> String
) {
  guard let binding = resolveAgentBinding(state: state, taskId: taskId, caller: caller)
  else { return }
  guard !DatabaseManager.hasReplied(taskId: taskId) else {
    // Agent did call `reply`. Drop the cached streaming text now that
    // the row is permanently has_replied=1 — no future safety-net pass
    // will need it.
    state.clearOutput(taskId: taskId)
    return
  }

  state.log(logLevel, "\(caller): safety-net post for task \(taskId) chat \(binding.chatId)")
  if let token = state.botToken {
    _ = telegramSendMessage(token: token, chatId: binding.chatId, text: message())
    // Clear the loading 👀. The reaction outlives the dispatch row and
    // would otherwise be left dangling on chats where the agent never
    // called `reply` itself.
    _ = telegramSetMessageReaction(
      token: token, chatId: binding.chatId,
      messageId: binding.incomingMessageId, emoji: nil)
  }
  // Flip has_replied so a duplicate COMPLETED can't double-post.
  DatabaseManager.markReplied(taskId: taskId)
  state.clearOutput(taskId: taskId)
}

/// Runs `work` after `delay` seconds on a utility queue, or inline when
/// `delay <= 0` (tests, or any caller that wants synchronous semantics).
private func scheduleSafetyNet(
  delay: TimeInterval, _ work: @escaping @Sendable () -> Void
) {
  guard delay > 0 else { return work() }
  DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
}

/// Looks up the active dispatch for `taskId` and confirms it belongs to
/// `state.agentId`. Returns nil with a log line on either miss; the
/// caller just bails. Centralises the defence-in-depth check that keeps
/// a misrouted task event from posting on the wrong agent's bot.
private func resolveAgentBinding(
  state: AgentState, taskId: String, caller: String
) -> ActiveDispatchRow? {
  guard let binding = DatabaseManager.lookupBindingByTask(taskId: taskId) else {
    logDebug("\(caller): no binding for task \(taskId), skipping")
    return nil
  }
  guard binding.agentId == state.agentId else {
    logWarn(
      "\(caller): task \(taskId) belongs to agent \(binding.agentId), "
        + "not active agent \(state.agentId); ignoring")
    return nil
  }
  return binding
}

// MARK: - Clarification
//
// CLARIFICATION (type 3) is the canonical handoff for an agent-side
// clarify pause. The host fires this with `{question, options,
// allow_multiple}`, holds the task in a paused state, and SUPPRESSES
// the trailing COMPLETED that used to leak the raw tool envelope.
//
// Our job per event:
//   1. Render the question (see `clarificationMessageText`).
//   2. Flip `has_replied` so the safety net stays silent if any
//      downgraded host ever fires COMPLETED through anyway.
//   3. Clear the loading 👀, same as a real `reply` would.
//
// The binding is intentionally NOT deleted — `(task_id, reply_token)`
// survives the pause so the resumed task can call `reply` once the
// user's follow-up lands. The follow-up routes back via the existing
// `external_session_key` re-attachment path (no special-case resume
// logic needed here).
//
// `sanitizeSafetyNetCandidate` (below) is the backstop for older hosts
// that route `clarify` through their own native UI without emitting
// type 3.

func handleClarification(state: AgentState, taskId: String, eventJSON: String) {
  guard
    let binding = resolveAgentBinding(
      state: state, taskId: taskId, caller: "handleClarification")
  else { return }

  // If the agent already called `reply` on this turn (rare, but possible
  // if the model both clarified AND replied), don't double-post.
  if DatabaseManager.hasReplied(taskId: taskId) {
    state.log(
      .debug,
      "handleClarification: task \(taskId) already replied; skipping question post")
    return
  }

  guard let text = clarificationMessageText(eventJSON: eventJSON) else {
    // No `question` field, or it's blank. Don't manufacture a question —
    // let the existing safety net handle the eventual COMPLETED.
    state.log(
      .warn,
      "handleClarification: empty or missing question in event for task \(taskId); "
        + "falling through to safety net")
    return
  }

  guard let token = state.botToken, !token.isEmpty else {
    state.log(.warn, "handleClarification: no bot_token configured; cannot post question")
    return
  }

  let chatId = binding.chatId
  let response = runOnSendActor(agentId: state.agentId, chatId: chatId) {
    telegramSendMessage(token: token, chatId: chatId, text: text)
  }
  guard response.ok else {
    state.log(
      .warn,
      "handleClarification: sendMessage failed for task \(taskId) chat \(chatId): "
        + response.description)
    return
  }

  state.log(
    .info,
    "handleClarification: posted question to chat \(chatId) for task \(taskId)")
  DatabaseManager.markReplied(taskId: taskId)
  clearLoadingReaction(state: state, binding: binding)
  state.clearOutput(taskId: taskId)
}

/// Renders the CLARIFICATION event payload into a Telegram-ready message.
/// Returns `nil` when there's no usable `question` so the caller can fall
/// through to the safety net rather than posting an empty message.
///
/// Rendering follows the canonical doc:
///   - Options are numbered (`1. A\n2. B`) so the user can reply with a
///     number and the agent can correlate. Inline keyboards would be
///     nicer; left for a future change (needs `callback_query` route).
///   - When `allow_multiple` is explicitly present we append a one-line
///     selection hint. Absent means the agent didn't say, so we don't
///     manufacture intent.
func clarificationMessageText(eventJSON: String) -> String? {
  let obj = parseJSONObject(eventJSON)
  let question = (obj?["question"] as? String)?
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard let question, !question.isEmpty else { return nil }

  let options = (obj?["options"] as? [Any] ?? [])
    .compactMap { $0 as? String }
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty }

  var body = question
  if !options.isEmpty {
    let numbered = options.enumerated()
      .map { "\($0.offset + 1). \($0.element)" }
      .joined(separator: "\n")
    body += "\n\n\(numbered)"
  }
  if let allowMultiple = obj?["allow_multiple"] as? Bool {
    body +=
      allowMultiple
      ? "\n\n(reply with one or more)"
      : "\n\n(reply with one)"
  }
  return String(body.prefix(4000))
}

// MARK: - Safety-net message extraction
//
// When a task COMPLETEs without the agent ever calling `reply`, we need to
// surface *something* to the user. Precedence:
//
//   1. `streamingOutput` — the latest text from the agent's OUTPUT events
//      stashed by `handleTaskEvent`. Beats `output` because the host
//      sometimes fires multiple COMPLETED events per task and the first
//      one's `output` field carries interim text like "No response
//      needed." that races the actual answer.
//   2. COMPLETED `output` — the host's "agent's final generated prose"
//      field. Reliable when there's only one COMPLETED.
//   3. COMPLETED `summary` — a short title-like description, e.g. "Chat
//      completed". Not an answer, but better than nothing.
//   4. "(done)" — a literal placeholder for the rare case where every
//      signal is empty.
//
// Each candidate is run through `sanitizeSafetyNetCandidate` before being
// accepted, which strips/replaces tool-envelope JSON (`{"ok":true,...,
// "tool":"clarify"}` and friends). Without this guard the user sees raw
// JSON whenever the agent ends a turn on a host-provided tool call (e.g.
// the legacy `clarify` tool) instead of `reply`.
func safetyNetCompletedMessage(
  eventJSON: String, streamingOutput: String? = nil
) -> String {
  let obj = parseJSONObject(eventJSON)
  let pick =
    sanitizeSafetyNetCandidate(streamingOutput)
    ?? sanitizeSafetyNetCandidate(obj?["output"] as? String)
    ?? sanitizeSafetyNetCandidate(obj?["summary"] as? String)
    ?? "(done)"
  return String(pick.prefix(4000))
}

/// Returns a usable safety-net string for `candidate`, or nil when the
/// candidate is blank or contains nothing more than a tool envelope.
///
/// Tool envelopes (e.g. `{"ok":true,"result":{"text":"Awaiting user
/// response."},"tool":"clarify"}`) leak in two cases:
///   1. The host fires COMPLETED with `output` equal to the tool's return
///      value verbatim. This is what happens with the agent-side
///      `clarify` tool on host versions that don't emit a separate
///      `CLARIFICATION` event.
///   2. The agent's streamed output echoes the tool result back as its
///      final assistant message.
///
/// In either case the user must not see raw JSON. For the specific
/// `tool:"clarify"` envelope we substitute a clarification fallback so
/// the conversation keeps moving — the user's next message will route
/// back into the same session and the agent can answer for real.
/// Anything else is dropped so the caller falls through to the next
/// precedence level.
func sanitizeSafetyNetCandidate(_ candidate: String?) -> String? {
  let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
  guard let trimmed, !trimmed.isEmpty else { return nil }

  if let envelopeTool = detectToolEnvelopeName(in: trimmed) {
    if envelopeTool == "clarify" {
      return clarifyFallbackMessage
    }
    // Unknown tool envelope: don't post JSON. Drop and fall through.
    return nil
  }
  return trimmed
}

/// User-visible fallback when we know the agent called the host `clarify`
/// tool but the question text never reached the plugin. Phrased as an
/// open-ended prompt so the user can re-send whatever the agent was
/// actually missing.
let clarifyFallbackMessage =
  "I need a bit more detail to help with that. Could you share what you have in mind?"

/// Returns the value of `"tool"` when `text` parses as a tool-result
/// envelope shaped like `{"ok":..., "tool":"<name>", ...}`. Returns nil
/// otherwise. Lets the safety-net path treat the entire string as
/// "structured noise" without misclassifying legitimate prose that just
/// happens to contain a JSON snippet.
///
/// We require both a `tool` key AND at least one of `ok` / `result` /
/// `error` so a stray message like `{"tool":"hammer"}` doesn't trip the
/// detector — those keys are what give it true envelope shape.
func detectToolEnvelopeName(in text: String) -> String? {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
    let obj = parseJSONObject(trimmed),
    obj["ok"] != nil || obj["result"] != nil || obj["error"] != nil,
    let tool = (obj["tool"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
    !tool.isEmpty
  else { return nil }
  return tool
}
