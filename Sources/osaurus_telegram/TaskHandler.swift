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
}

/// Derives a stable non-zero draft ID from a task ID string.
func draftId(for taskId: String) -> Int {
  var h: UInt = 5381
  for byte in taskId.utf8 {
    h = h &* 33 &+ UInt(byte)
  }
  return Int(h & 0x7FFF_FFFE) | 1
}

func handleTaskEvent(ctx: PluginContext, taskId: String, eventType: Int32, eventJSON: String) {
  guard let task = DatabaseManager.getTask(taskId: taskId) else {
    logWarn("Task event for unknown task \(taskId), event type \(eventType)")
    return
  }

  guard let token = ctx.botToken, !token.isEmpty else {
    logWarn("No bot token for task event \(taskId)")
    return
  }

  let chatId = task.chatId
  let isPrivate = task.chatType == "private"

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

  default:
    logWarn("Unknown task event type \(eventType) for task \(taskId)")
  }
}

// MARK: - Event Handlers

private func handleStarted(token: String, chatId: String, task: TaskRow, isPrivate: Bool) {
  DatabaseManager.updateTask(taskId: task.taskId, status: "running")
  if isPrivate {
    _ = telegramSendMessageDraft(
      token: token, chatId: chatId,
      draftId: draftId(for: task.taskId),
      text: "\u{23F3} Working on it..."
    )
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
      _ = telegramSendMessageDraft(
        token: token, chatId: chatId,
        draftId: draftId(for: task.taskId),
        text: "\u{23F3} \(title)..."
      )
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
      _ = telegramEditMessage(
        token: token,
        chatId: chatId,
        messageId: statusMsgId,
        text: "\u{23F3} \(title)..."
      )
    }
  }
}

private func handleProgress(
  token: String, chatId: String, task: TaskRow, isPrivate: Bool, eventJSON: String
) {
  guard let event = parseJSON(eventJSON, as: TaskProgressEvent.self) else { return }

  let progressValue = event.progress ?? 0.0
  DatabaseManager.updateTask(taskId: task.taskId, progress: progressValue)

  let pct = Int(progressValue * 100)
  let step = event.current_step ?? "Processing"

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
    logWarn("Clarification event missing question for task \(taskId)")
    return
  }

  let options = event.options ?? []

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

  if !isPrivate, let statusMsgId = task.statusMsgId {
    _ = telegramDeleteMessage(token: token, chatId: chatId, messageId: statusMsgId)
  }

  let msgId = telegramSendLongMessage(token: token, chatId: chatId, text: summary)

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

  if !isPrivate, let statusMsgId = task.statusMsgId {
    _ = telegramDeleteMessage(token: token, chatId: chatId, messageId: statusMsgId)
  }

  _ = telegramSendMessage(token: token, chatId: chatId, text: "\u{274C} \(summary)")
  DatabaseManager.updateTask(taskId: task.taskId, status: "failed", summary: summary)
  logWarn("Task \(task.taskId) failed for chat \(chatId)")
}

private func handleCancelled(token: String, chatId: String, task: TaskRow, isPrivate: Bool) {
  if !isPrivate, let statusMsgId = task.statusMsgId {
    _ = telegramDeleteMessage(token: token, chatId: chatId, messageId: statusMsgId)
  }

  _ = telegramSendMessage(token: token, chatId: chatId, text: "\u{1F6AB} Task cancelled")
  DatabaseManager.updateTask(taskId: task.taskId, status: "cancelled")
  logInfo("Task \(task.taskId) cancelled for chat \(chatId)")
}
