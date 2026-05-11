import Foundation

// MARK: - Task Event Handler
//
// In the agent-driven model `on_task_event` is observability + a safety net,
// not the delivery mechanism. The agent owns user-visible UI via the reply
// tools. We log lifecycle events at debug level and only post to Telegram
// when a run terminated without ever calling reply (so the user isn't left
// hanging) or hard-failed.

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
    runTerminalSafetyNet(
      state: state, taskId: taskId, caller: "handleCompleted",
      logLevel: .info,
      message: {
        let summary = (parseJSONObject(eventJSON)?["summary"] as? String) ?? "(done)"
        return String(summary.prefix(4000))
      })

  case TaskEventType.failed:
    runTerminalSafetyNet(
      state: state, taskId: taskId, caller: "handleFailed",
      logLevel: .warn,
      message: { "Sorry, something went wrong handling that." })

  case TaskEventType.cancelled:
    // Cancellation happens either from /reset or because a new message
    // arrived and we issued dispatch_interrupt — we already cleaned up the
    // row in both paths. Belt-and-suspenders: delete again here.
    DatabaseManager.deleteActiveDispatch(taskId: taskId)

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
// COMPLETED and FAILED differ only in the safety-net message and log
// severity. Everything else — binding lookup, agent-ownership check,
// hasReplied gate, and row cleanup — is identical, so we share one
// implementation.

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
  // Defense-in-depth: a misrouted task event must never trigger a Telegram
  // post on the wrong agent's bot.
  guard binding.agentId == state.agentId else {
    logWarn(
      "\(caller): task \(taskId) belongs to agent \(binding.agentId), "
        + "not the active agent \(state.agentId); ignoring")
    return
  }

  if !DatabaseManager.hasReplied(taskId: taskId) {
    state.log(
      logLevel, "\(caller): safety-net post for task \(taskId) chat \(binding.chatId)")
    if let token = state.botToken {
      _ = telegramSendMessage(
        token: token, chatId: binding.chatId,
        text: message())
    }
  }
  DatabaseManager.deleteActiveDispatch(taskId: taskId)
}
