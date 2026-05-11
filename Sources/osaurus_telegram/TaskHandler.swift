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
    // See `safetyNetDelaySeconds` comment for the reason we defer.
    scheduleSafetyNet(delay: safetyNetDelaySeconds) {
      runTerminalSafetyNet(
        state: state, taskId: taskId, caller: "handleCompleted",
        logLevel: .info,
        message: { safetyNetCompletedMessage(eventJSON: eventJSON) })
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

  case TaskEventType.started,
    TaskEventType.activity,
    TaskEventType.progress,
    TaskEventType.clarification,
    TaskEventType.output,
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
  guard let binding = DatabaseManager.lookupBindingByTask(taskId: taskId) else {
    logDebug("\(caller): no binding for task \(taskId), skipping")
    return
  }
  // Defense-in-depth: a misrouted task event must never post on the
  // wrong agent's bot.
  guard binding.agentId == state.agentId else {
    logWarn(
      "\(caller): task \(taskId) belongs to agent \(binding.agentId), "
        + "not active agent \(state.agentId); ignoring")
    return
  }
  guard !DatabaseManager.hasReplied(taskId: taskId) else { return }

  state.log(logLevel, "\(caller): safety-net post for task \(taskId) chat \(binding.chatId)")
  if let token = state.botToken {
    _ = telegramSendMessage(token: token, chatId: binding.chatId, text: message())
  }
  // Flip has_replied so a duplicate COMPLETED can't double-post.
  DatabaseManager.markReplied(taskId: taskId)
}

/// Runs `work` after `delay` seconds on a utility queue, or inline when
/// `delay <= 0` (tests, or any caller that wants synchronous semantics).
private func scheduleSafetyNet(
  delay: TimeInterval, _ work: @escaping @Sendable () -> Void
) {
  guard delay > 0 else { return work() }
  DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
}

// MARK: - Safety-net message extraction
//
// When a task COMPLETEs without the agent ever calling `reply`, we need to
// surface *something* to the user. The host's COMPLETED event carries both
// `output` (the agent's final generated prose) and `summary` (a short
// title-like description, e.g. "Chat completed"). Prefer `output` because
// "Chat completed" is not an answer; only fall back to `summary` when the
// agent produced no final prose at all.
func safetyNetCompletedMessage(eventJSON: String) -> String {
  let obj = parseJSONObject(eventJSON)
  let whitespace = CharacterSet.whitespacesAndNewlines
  let output = (obj?["output"] as? String)?.trimmingCharacters(in: whitespace)
  let summary = (obj?["summary"] as? String)?.trimmingCharacters(in: whitespace)

  let pick: String
  if let output, !output.isEmpty {
    pick = output
  } else if let summary, !summary.isEmpty {
    pick = summary
  } else {
    pick = "(done)"
  }
  return String(pick.prefix(4000))
}
