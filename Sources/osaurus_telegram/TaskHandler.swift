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

func handleTaskEvent(ctx: PluginContext, taskId: String, eventType: Int32, eventJSON: String) {
  let eventName = taskEventNames[eventType] ?? "UNKNOWN(\(eventType))"
  logDebug(
    "handleTaskEvent: taskId=\(taskId) type=\(eventName) json=\(String(eventJSON.prefix(200)))")

  switch eventType {
  case TaskEventType.completed:
    handleCompleted(ctx: ctx, taskId: taskId, eventJSON: eventJSON)

  case TaskEventType.failed:
    handleFailed(ctx: ctx, taskId: taskId, eventJSON: eventJSON)

  case TaskEventType.cancelled:
    handleCancelled(taskId: taskId)

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

private func handleCompleted(ctx: PluginContext, taskId: String, eventJSON: String) {
  guard let binding = DatabaseManager.lookupBindingByTask(taskId: taskId) else {
    logDebug("handleCompleted: no binding for task \(taskId), skipping")
    return
  }

  if !DatabaseManager.hasReplied(taskId: taskId) {
    let summary = (parseJSONObject(eventJSON)?["summary"] as? String) ?? "(done)"
    logInfo(
      "handleCompleted: safety-net post for task \(taskId) chat \(binding.chatId)")
    if let token = ctx.botToken {
      _ = telegramSendMessage(
        token: token, chatId: binding.chatId,
        text: String(summary.prefix(4000)))
    }
  }
  DatabaseManager.deleteActiveDispatch(taskId: taskId)
}

private func handleFailed(ctx: PluginContext, taskId: String, eventJSON: String) {
  guard let binding = DatabaseManager.lookupBindingByTask(taskId: taskId) else {
    logDebug("handleFailed: no binding for task \(taskId), skipping")
    return
  }

  if !DatabaseManager.hasReplied(taskId: taskId) {
    logWarn(
      "handleFailed: safety-net post for task \(taskId) chat \(binding.chatId)")
    if let token = ctx.botToken {
      _ = telegramSendMessage(
        token: token, chatId: binding.chatId,
        text: "Sorry, something went wrong handling that.")
    }
  }
  DatabaseManager.deleteActiveDispatch(taskId: taskId)
}

private func handleCancelled(taskId: String) {
  // Cancellation happens either from /reset or because a new message arrived
  // and we issued dispatch_interrupt — we already cleaned up the row in both
  // paths. Belt-and-suspenders: delete again here.
  DatabaseManager.deleteActiveDispatch(taskId: taskId)
}
