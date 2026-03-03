import Foundation

// MARK: - Task Event Handler

private enum TaskEventType {
  static let started: Int32 = 0
  static let activity: Int32 = 1
  static let progress: Int32 = 2
  static let clarification: Int32 = 3
  static let completed: Int32 = 4
  static let failed: Int32 = 5
  static let cancelled: Int32 = 6
  static let output: Int32 = 7
}

/// Derives a stable non-zero draft ID from a task ID string.
func draftId(for taskId: String) -> Int {
  var h: UInt = 5381
  for byte in taskId.utf8 {
    h = h &* 33 &+ UInt(byte)
  }
  return Int(h & 0x7FFF_FFFE) | 1
}

private let taskEventNames: [Int32: String] = [
  0: "STARTED", 1: "ACTIVITY", 2: "PROGRESS", 3: "CLARIFICATION",
  4: "COMPLETED", 5: "FAILED", 6: "CANCELLED", 7: "OUTPUT",
]

func handleTaskEvent(ctx: PluginContext, taskId: String, eventType: Int32, eventJSON: String) {
  let eventName = taskEventNames[eventType] ?? "UNKNOWN(\(eventType))"
  logDebug(
    "handleTaskEvent: taskId=\(taskId) type=\(eventName) json=\(String(eventJSON.prefix(200)))")

  guard let task = DatabaseManager.getTask(taskId: taskId) else {
    logWarn("Task event for unknown task \(taskId), event type \(eventName)")
    return
  }

  guard let token = ctx.botToken, !token.isEmpty else {
    logWarn("No bot token for task event \(taskId) (\(eventName))")
    return
  }

  let chatId = task.chatId
  let isPrivate = task.chatType == "private"
  logDebug("handleTaskEvent: chatId=\(chatId) isPrivate=\(isPrivate) status=\(task.status)")

  switch eventType {
  case TaskEventType.started:
    handleStarted(token: token, chatId: chatId, task: task, isPrivate: isPrivate)

  case TaskEventType.activity:
    handleActivity(
      token: token, chatId: chatId, task: task, isPrivate: isPrivate, eventJSON: eventJSON)

  case TaskEventType.progress:
    handleProgress(
      token: token, chatId: chatId, task: task, isPrivate: isPrivate, eventJSON: eventJSON)

  case TaskEventType.clarification:
    handleClarification(token: token, chatId: chatId, taskId: taskId, eventJSON: eventJSON)

  case TaskEventType.completed:
    handleCompleted(
      token: token, chatId: chatId, task: task, isPrivate: isPrivate, eventJSON: eventJSON)

  case TaskEventType.failed:
    handleFailed(
      token: token, chatId: chatId, task: task, isPrivate: isPrivate, eventJSON: eventJSON)

  case TaskEventType.cancelled:
    handleCancelled(token: token, chatId: chatId, task: task, isPrivate: isPrivate)

  case TaskEventType.output:
    handleOutput(
      token: token, chatId: chatId, task: task, isPrivate: isPrivate, eventJSON: eventJSON)

  default:
    logWarn("Unknown task event type \(eventType) for task \(taskId)")
  }
}

// MARK: - Event Handlers

private func handleStarted(token: String, chatId: String, task: TaskRow, isPrivate: Bool) {
  logDebug("handleStarted: task \(task.taskId) isPrivate=\(isPrivate)")
  DatabaseManager.updateTask(taskId: task.taskId, status: "running")
  if isPrivate {
    let ok = telegramSendMessageDraft(
      token: token, chatId: chatId,
      draftId: draftId(for: task.taskId),
      text: "\u{23F3} Working on it..."
    )
    logDebug("handleStarted: sent draft ok=\(ok)")
  } else {
    telegramSendChatAction(token: token, chatId: chatId)
  }
}

private func handleActivity(
  token: String, chatId: String, task: TaskRow, isPrivate: Bool, eventJSON: String
) {
  if isPrivate {
    if let event = parseJSON(eventJSON, as: TaskActivityEvent.self),
      let title = event.title
    {
      logDebug("handleActivity: task \(task.taskId) title=\"\(title)\"")
      _ = telegramSendMessageDraft(
        token: token, chatId: chatId,
        draftId: draftId(for: task.taskId),
        text: "\u{23F3} \(title)..."
      )
    } else {
      logDebug("handleActivity: task \(task.taskId) failed to parse activity event")
    }
    return
  }

  let sendTyping = configGet("send_typing") != "false"
  if sendTyping {
    telegramSendChatAction(token: token, chatId: chatId)
  }

  let sendProgress = configGet("send_progress") == "true"
  if sendProgress, let statusMsgId = task.statusMsgId {
    if let event = parseJSON(eventJSON, as: TaskActivityEvent.self),
      let title = event.title
    {
      logDebug(
        "handleActivity: task \(task.taskId) updating status msg \(statusMsgId) title=\"\(title)\"")
      _ = telegramEditMessage(
        token: token,
        chatId: chatId,
        messageId: statusMsgId,
        text: "\u{23F3} \(title)..."
      )
    } else {
      logDebug(
        "handleActivity: task \(task.taskId) failed to parse activity event for status update")
    }
  }
}

private func handleProgress(
  token: String, chatId: String, task: TaskRow, isPrivate: Bool, eventJSON: String
) {
  guard let event = parseJSON(eventJSON, as: TaskProgressEvent.self) else {
    logDebug("handleProgress: task \(task.taskId) failed to parse progress event")
    return
  }

  let progressValue = event.progress ?? 0.0
  DatabaseManager.updateTask(taskId: task.taskId, progress: progressValue)

  let pct = Int(progressValue * 100)
  let step = event.current_step ?? "Processing"
  logDebug("handleProgress: task \(task.taskId) \(pct)% step=\"\(step)\"")

  if isPrivate {
    _ = telegramSendMessageDraft(
      token: token, chatId: chatId,
      draftId: draftId(for: task.taskId),
      text: "\u{23F3} \(pct)% \u{2014} \(step)"
    )
  } else if let statusMsgId = task.statusMsgId {
    _ = telegramEditMessage(
      token: token,
      chatId: chatId,
      messageId: statusMsgId,
      text: "\u{23F3} \(pct)% \u{2014} \(step)"
    )
  }
}

private func handleClarification(token: String, chatId: String, taskId: String, eventJSON: String) {
  guard let event = parseJSON(eventJSON, as: TaskClarificationEvent.self),
    let question = event.question
  else {
    logWarn(
      "Clarification event missing question for task \(taskId), json=\(String(eventJSON.prefix(200)))"
    )
    return
  }

  let options = event.options ?? []
  logDebug(
    "handleClarification: task \(taskId) question=\"\(String(question.prefix(100)))\" options=\(options.count)"
  )

  if options.isEmpty {
    _ = telegramSendMessage(
      token: token,
      chatId: chatId,
      text: "\u{2753} \(question)"
    )
    DatabaseManager.updateTask(taskId: taskId, status: "awaiting_clarification")
    return
  }

  let keyboard: [[Any]] = options.enumerated().map { (idx, option) in
    let callbackData = "clarify:\(taskId):\(idx)"
    return [["text": String(option.prefix(128)), "callback_data": callbackData] as [String: Any]]
  }

  let replyMarkup: [String: Any] = ["inline_keyboard": keyboard]

  let optionsJSON = (try? JSONSerialization.data(withJSONObject: options))
    .flatMap { String(data: $0, encoding: .utf8) }

  _ = telegramSendMessage(
    token: token,
    chatId: chatId,
    text: "\u{2753} \(question)",
    replyMarkup: replyMarkup
  )

  DatabaseManager.updateTask(
    taskId: taskId, status: "awaiting_clarification",
    clarificationOptions: optionsJSON
  )
}

private func handleCompleted(
  token: String, chatId: String, task: TaskRow, isPrivate: Bool, eventJSON: String
) {
  let event = parseJSON(eventJSON, as: TaskCompletedEvent.self)
  let summary = event?.summary ?? "Task completed."
  logDebug(
    "handleCompleted: task \(task.taskId) summary=\(String(summary.prefix(200))) (\(summary.count) chars)"
  )

  if !isPrivate, let statusMsgId = task.statusMsgId {
    _ = telegramDeleteMessage(token: token, chatId: chatId, messageId: statusMsgId)
  }

  let msgId = telegramSendLongMessage(token: token, chatId: chatId, text: summary)
  logDebug("handleCompleted: sent summary message, msgId=\(msgId.map { "\($0)" } ?? "nil")")

  if let msgId {
    DatabaseManager.insertMessage(
      chatId: chatId,
      messageId: msgId,
      direction: "out",
      senderId: nil,
      senderName: "Agent",
      text: summary,
      mediaType: nil,
      mediaFileId: nil,
      taskId: task.taskId
    )
  }

  DatabaseManager.updateTask(taskId: task.taskId, status: "completed", summary: summary)
  logInfo("Task \(task.taskId) completed for chat \(chatId)")
}

private func handleFailed(
  token: String, chatId: String, task: TaskRow, isPrivate: Bool, eventJSON: String
) {
  let event = parseJSON(eventJSON, as: TaskFailedEvent.self)
  let summary = event?.summary ?? "Task failed."
  logDebug("handleFailed: task \(task.taskId) summary=\"\(String(summary.prefix(200)))\"")

  if !isPrivate, let statusMsgId = task.statusMsgId {
    _ = telegramDeleteMessage(token: token, chatId: chatId, messageId: statusMsgId)
  }

  _ = telegramSendMessage(token: token, chatId: chatId, text: "\u{274C} \(summary)")
  DatabaseManager.updateTask(taskId: task.taskId, status: "failed", summary: summary)
  logWarn("Task \(task.taskId) failed for chat \(chatId): \(summary)")
}

private func handleCancelled(token: String, chatId: String, task: TaskRow, isPrivate: Bool) {
  logDebug("handleCancelled: task \(task.taskId)")
  if !isPrivate, let statusMsgId = task.statusMsgId {
    _ = telegramDeleteMessage(token: token, chatId: chatId, messageId: statusMsgId)
  }

  _ = telegramSendMessage(token: token, chatId: chatId, text: "\u{1F6AB} Task cancelled")
  DatabaseManager.updateTask(taskId: task.taskId, status: "cancelled")
  logInfo("Task \(task.taskId) cancelled for chat \(chatId)")
}

private func handleOutput(
  token: String, chatId: String, task: TaskRow, isPrivate: Bool, eventJSON: String
) {
  guard let event = parseJSON(eventJSON, as: TaskOutputEvent.self),
    let text = event.text, !text.isEmpty
  else {
    logDebug("handleOutput: task \(task.taskId) failed to parse output event or empty text")
    return
  }

  logDebug("handleOutput: task \(task.taskId) text=\(text.count) chars")

  if isPrivate {
    _ = telegramSendMessageDraft(
      token: token, chatId: chatId,
      draftId: draftId(for: task.taskId),
      text: String(text.prefix(4096))
    )
  } else {
    telegramSendChatAction(token: token, chatId: chatId)
  }
}
