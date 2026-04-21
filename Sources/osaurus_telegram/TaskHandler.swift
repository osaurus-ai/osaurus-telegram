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
  static let draft: Int32 = 8
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
  4: "COMPLETED", 5: "FAILED", 6: "CANCELLED", 7: "OUTPUT", 8: "DRAFT",
]

private let outputEditThrottleInterval: TimeInterval = 3.0

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
    handleStarted(ctx: ctx, token: token, chatId: chatId, task: task, isPrivate: isPrivate)

  case TaskEventType.activity:
    handleActivity(
      ctx: ctx, token: token, chatId: chatId, task: task, isPrivate: isPrivate,
      eventJSON: eventJSON)

  case TaskEventType.progress:
    handleProgress(
      ctx: ctx, token: token, chatId: chatId, task: task, isPrivate: isPrivate,
      eventJSON: eventJSON)

  case TaskEventType.clarification:
    handleClarification(token: token, chatId: chatId, task: task, eventJSON: eventJSON)

  case TaskEventType.completed:
    handleCompleted(
      ctx: ctx, token: token, chatId: chatId, task: task, isPrivate: isPrivate, eventJSON: eventJSON
    )

  case TaskEventType.failed:
    handleFailed(
      ctx: ctx, token: token, chatId: chatId, task: task, isPrivate: isPrivate, eventJSON: eventJSON
    )

  case TaskEventType.cancelled:
    handleCancelled(ctx: ctx, token: token, chatId: chatId, task: task, isPrivate: isPrivate)

  case TaskEventType.output:
    handleOutput(
      ctx: ctx, token: token, chatId: chatId, task: task, isPrivate: isPrivate, eventJSON: eventJSON
    )

  case TaskEventType.draft:
    handleDraft(
      ctx: ctx, token: token, chatId: chatId, task: task, isPrivate: isPrivate, eventJSON: eventJSON
    )

  default:
    logWarn("Unknown task event type \(eventType) for task \(taskId)")
  }
}

// MARK: - Helpers

private func cleanupTaskState(ctx: PluginContext, taskId: String) {
  ctx.taskOutputTexts.removeValue(forKey: taskId)
  ctx.taskDraftStates.removeValue(forKey: taskId)
  ctx.taskStreamStates.removeValue(forKey: taskId)
  if ctx.taskDraftStates.isEmpty {
    ctx.stopDraftPing()
  }
}

private func activityLabel(for event: TaskActivityEvent) -> String {
  switch event.kind {
  case "tool_call":
    return event.metadata?["tool_name"] ?? event.detail ?? "Tool"
  case "thinking":
    return "Thinking\u{2026}"
  case "writing":
    return "Writing\u{2026}"
  default:
    return event.detail ?? event.title ?? "Working"
  }
}

private func truncateToWordBoundary(_ text: String, maxLength: Int = 120) -> String {
  guard text.count > maxLength else { return text }
  var tail = String(text.suffix(maxLength))
  if let spaceIdx = tail.firstIndex(of: " ") {
    tail = String(tail[tail.index(after: spaceIdx)...])
  }
  return "...\(tail)"
}

private func buildStatusCard(state: TaskDraftState, status: String) -> String {
  var parts: [String] = [status]
  if state.toolCallCount > 0 {
    let noun = state.toolCallCount == 1 ? "step" : "steps"
    parts.append("\(state.toolCallCount) \(noun)")
  }
  if let name = state.latestToolName {
    parts.append(name)
  }

  var lines: [String] = [parts.joined(separator: " \u{00B7} ")]

  for msg in state.recentMessages {
    lines.append("")
    lines.append(msg)
  }

  return lines.joined(separator: "\n")
}

private func sendTerminalCard(
  ctx: PluginContext, token: String, chatId: String, task: TaskRow,
  isPrivate: Bool, status: String, summary: String,
  draftState: TaskDraftState?, groupIcon: String? = nil
) {
  if isPrivate {
    var finalState = draftState ?? TaskDraftState(chatId: chatId)
    finalState.recentMessages.append(summary)
    if finalState.recentMessages.count > 3 { finalState.recentMessages.removeFirst() }
    let cardText = buildStatusCard(state: finalState, status: status)
    if let msgId = telegramSendMessage(
      token: token, chatId: chatId, text: cardText, replyTo: task.messageId)
    {
      DatabaseManager.insertMessage(
        chatId: chatId, messageId: msgId, direction: "out",
        senderId: nil, senderName: "Agent", text: cardText,
        mediaType: nil, mediaFileId: nil, taskId: task.taskId)
    }
  } else {
    if let statusMsgId = task.statusMsgId {
      _ = telegramEditMessage(
        token: token, chatId: chatId, messageId: statusMsgId, text: status)
    }
    let icon = groupIcon ?? ""
    let messageText = icon.isEmpty ? summary : "\(icon) \(summary)"
    if let msgId = telegramSendMessage(
      token: token, chatId: chatId, text: messageText, replyTo: task.messageId)
    {
      DatabaseManager.insertMessage(
        chatId: chatId, messageId: msgId, direction: "out",
        senderId: nil, senderName: "Agent", text: summary,
        mediaType: nil, mediaFileId: nil, taskId: task.taskId)
    }
  }
}

func sendTaskDraft(ctx: PluginContext, token: String, chatId: String, taskId: String) {
  guard let state = ctx.taskDraftStates[taskId] else { return }
  let text = buildStatusCard(state: state, status: "\u{23F3} Working...")
  _ = telegramSendMessageDraft(
    token: token, chatId: chatId,
    draftId: draftId(for: taskId), text: text)
}

/// Sends a new message or throttle-edits an existing one for group chats.
/// Creates a `TaskStreamState` entry on first send; subsequent calls edit
/// the same message at most once per `outputEditThrottleInterval`.
private func editOrSendGroupMessage(
  ctx: PluginContext, token: String, chatId: String, task: TaskRow,
  text: String, parseMode: String? = nil
) {
  if let state = ctx.taskStreamStates[task.taskId] {
    let elapsed = Date().timeIntervalSince(state.lastEditTime)
    guard elapsed >= outputEditThrottleInterval else { return }
    let ok = telegramEditMessage(
      token: token, chatId: chatId, messageId: state.messageId,
      text: text, parseMode: parseMode)
    if ok {
      ctx.taskStreamStates[task.taskId]?.lastEditTime = Date()
    }
    logDebug("editOrSendGroupMessage: edited msg \(state.messageId) ok=\(ok)")
  } else {
    if let msgId = telegramSendMessage(
      token: token, chatId: chatId, text: text,
      parseMode: parseMode, replyTo: task.messageId)
    {
      ctx.taskStreamStates[task.taskId] = TaskStreamState(
        messageId: msgId, lastEditTime: Date())
      DatabaseManager.insertMessage(
        chatId: chatId, messageId: msgId, direction: "out",
        senderId: nil, senderName: "Agent", text: text,
        mediaType: nil, mediaFileId: nil, taskId: task.taskId)
      logDebug("editOrSendGroupMessage: sent new msg \(msgId)")
    }
  }
}

// MARK: - Event Handlers

private func handleStarted(
  ctx: PluginContext, token: String, chatId: String, task: TaskRow, isPrivate: Bool
) {
  logDebug("handleStarted: task \(task.taskId) isPrivate=\(isPrivate)")
  DatabaseManager.updateTask(taskId: task.taskId, status: "running")

  if let msgId = task.messageId {
    _ = telegramSetMessageReaction(
      token: token, chatId: chatId, messageId: msgId, emoji: "\u{1F440}")
  }

  if isPrivate {
    ctx.taskDraftStates[task.taskId] = TaskDraftState(chatId: chatId)
    sendTaskDraft(ctx: ctx, token: token, chatId: chatId, taskId: task.taskId)
    ctx.startDraftPing()
  } else {
    telegramSendChatAction(token: token, chatId: chatId)
  }
}

private func handleActivity(
  ctx: PluginContext, token: String, chatId: String, task: TaskRow, isPrivate: Bool,
  eventJSON: String
) {
  guard let event = parseJSON(eventJSON, as: TaskActivityEvent.self) else { return }
  let kind = event.kind ?? ""
  let label = activityLabel(for: event)

  if isPrivate {
    switch kind {
    case "tool_call":
      if let msgId = task.messageId {
        _ = telegramSetMessageReaction(
          token: token, chatId: chatId, messageId: msgId, emoji: "\u{2699}")
      }
      ctx.taskDraftStates[task.taskId, default: TaskDraftState(chatId: chatId)].toolCallCount += 1
      ctx.taskDraftStates[task.taskId]?.latestToolName = label
      if let currentOutput = ctx.taskOutputTexts[task.taskId] {
        ctx.taskDraftStates[task.taskId]?.outputOffset = currentOutput.count
      }
      ctx.taskDraftStates[task.taskId]?.newSegment = true
      sendTaskDraft(ctx: ctx, token: token, chatId: chatId, taskId: task.taskId)

    case "tool_result":
      if let currentOutput = ctx.taskOutputTexts[task.taskId] {
        ctx.taskDraftStates[task.taskId]?.outputOffset = currentOutput.count
      }
      ctx.taskDraftStates[task.taskId]?.newSegment = true

    case "thinking":
      if let msgId = task.messageId {
        _ = telegramSetMessageReaction(
          token: token, chatId: chatId, messageId: msgId, emoji: "\u{1F4AD}")
      }

    case "writing":
      if let msgId = task.messageId {
        _ = telegramSetMessageReaction(
          token: token, chatId: chatId, messageId: msgId, emoji: "\u{270D}")
      }

    default:
      break
    }
    return
  }

  if configGet("send_typing") != "false" {
    telegramSendChatAction(token: token, chatId: chatId)
  }

  if let statusMsgId = task.statusMsgId {
    logDebug(
      "handleActivity: task \(task.taskId) updating status msg \(statusMsgId) label=\"\(label)\"")
    _ = telegramEditMessage(
      token: token, chatId: chatId, messageId: statusMsgId,
      text: "\u{23F3} \(label)")
  }
}

private func handleProgress(
  ctx: PluginContext, token: String, chatId: String, task: TaskRow, isPrivate: Bool,
  eventJSON: String
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
    if ctx.taskOutputTexts[task.taskId] != nil {
      logDebug("handleProgress: skipping draft, output already shown for task \(task.taskId)")
      return
    }
    ctx.taskDraftStates[task.taskId, default: TaskDraftState(chatId: chatId)].latestToolName =
      "\(pct)% \u{2014} \(step)"
    sendTaskDraft(ctx: ctx, token: token, chatId: chatId, taskId: task.taskId)
  } else if let statusMsgId = task.statusMsgId {
    _ = telegramEditMessage(
      token: token,
      chatId: chatId,
      messageId: statusMsgId,
      text: "\u{23F3} \(pct)% \u{2014} \(step)"
    )
  }
}

/// Surfaces a clarification question as a plain reply.
///
/// The deprecated `dispatch_clarify` round-trip has been replaced by the
/// unified chat agent loop: the user simply replies to the agent's message
/// and `handleTaskThreadReply` redispatches the answer with the same
/// `external_session_key`. We append the available options to the prompt as
/// a hint instead of rendering a now-dead inline keyboard.
private func handleClarification(
  token: String, chatId: String, task: TaskRow, eventJSON: String
) {
  let taskId = task.taskId
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

  var questionText = "\u{2753} \(question)"
  if !options.isEmpty {
    let bullets = options.map { "\u{2022} \($0)" }.joined(separator: "\n")
    questionText += "\n\n\(bullets)"
  }

  if let msgId = telegramSendMessage(
    token: token, chatId: chatId, text: questionText,
    replyTo: task.messageId)
  {
    DatabaseManager.insertMessage(
      chatId: chatId, messageId: msgId, direction: "out",
      senderId: nil, senderName: "Agent", text: questionText,
      mediaType: nil, mediaFileId: nil, taskId: taskId)
  }
}

private func handleCompleted(
  ctx: PluginContext, token: String, chatId: String, task: TaskRow, isPrivate: Bool,
  eventJSON: String
) {
  let event = parseJSON(eventJSON, as: TaskCompletedEvent.self)
  let summary = event?.summary ?? "Task completed."
  let draftState = ctx.taskDraftStates[task.taskId]
  let streamState = ctx.taskStreamStates[task.taskId]
  let accumulatedOutput = ctx.taskOutputTexts[task.taskId]
  cleanupTaskState(ctx: ctx, taskId: task.taskId)

  logDebug("handleCompleted: task \(task.taskId) summary=\(summary.count) chars")

  if isPrivate {
    sendTerminalCard(
      ctx: ctx, token: token, chatId: chatId, task: task, isPrivate: true,
      status: "\u{2705} Done", summary: summary, draftState: draftState)

    let fullOutput = event?.output ?? accumulatedOutput
    if let fullOutput, !fullOutput.isEmpty, fullOutput != summary {
      let htmlText = markdownToTelegramHTML(fullOutput)
      if let outMsgId = telegramSendLongMessage(
        token: token, chatId: chatId, text: htmlText, parseMode: "HTML",
        replyTo: task.messageId)
      {
        DatabaseManager.insertMessage(
          chatId: chatId, messageId: outMsgId, direction: "out",
          senderId: nil, senderName: "Agent", text: fullOutput,
          mediaType: nil, mediaFileId: nil, taskId: task.taskId)
      }
    }
  } else {
    if let statusMsgId = task.statusMsgId {
      _ = telegramEditMessage(
        token: token, chatId: chatId, messageId: statusMsgId,
        text: "\u{2705} Done")
    }
    let eventOutput = event?.output
    let messageText = eventOutput ?? accumulatedOutput ?? summary
    let htmlText = markdownToTelegramHTML(messageText)

    if let streamState {
      let ok = telegramEditMessage(
        token: token, chatId: chatId, messageId: streamState.messageId,
        text: String(htmlText.prefix(4096)), parseMode: "HTML")
      logDebug("handleCompleted: final edit msg \(streamState.messageId) ok=\(ok)")
    } else {
      let msgId = telegramSendLongMessage(
        token: token, chatId: chatId, text: htmlText, parseMode: "HTML",
        replyTo: task.messageId)
      logDebug("handleCompleted: sent new message, msgId=\(msgId.map { "\($0)" } ?? "nil")")

      if let msgId {
        DatabaseManager.insertMessage(
          chatId: chatId, messageId: msgId, direction: "out",
          senderId: nil, senderName: "Agent", text: messageText,
          mediaType: nil, mediaFileId: nil, taskId: task.taskId)
      }
    }
  }

  if let msgId = task.messageId {
    _ = telegramSetMessageReaction(
      token: token, chatId: chatId, messageId: msgId, emoji: "\u{2705}")
  }

  DatabaseManager.updateTask(taskId: task.taskId, status: "completed", summary: summary)
  logInfo("Task \(task.taskId) completed for chat \(chatId)")
}

private func handleFailed(
  ctx: PluginContext, token: String, chatId: String, task: TaskRow, isPrivate: Bool,
  eventJSON: String
) {
  let draftState = ctx.taskDraftStates[task.taskId]
  cleanupTaskState(ctx: ctx, taskId: task.taskId)
  let event = parseJSON(eventJSON, as: TaskFailedEvent.self)
  let summary = event?.summary ?? "Task failed."
  logDebug("handleFailed: task \(task.taskId) summary=\"\(String(summary.prefix(200)))\"")

  sendTerminalCard(
    ctx: ctx, token: token, chatId: chatId, task: task, isPrivate: isPrivate,
    status: "\u{274C} Failed", summary: summary, draftState: draftState,
    groupIcon: "\u{274C}")

  if let msgId = task.messageId {
    _ = telegramSetMessageReaction(
      token: token, chatId: chatId, messageId: msgId, emoji: "\u{274C}")
  }

  DatabaseManager.updateTask(taskId: task.taskId, status: "failed", summary: summary)
  logWarn("Task \(task.taskId) failed for chat \(chatId): \(summary)")
}

private func handleCancelled(
  ctx: PluginContext, token: String, chatId: String, task: TaskRow, isPrivate: Bool
) {
  let draftState = ctx.taskDraftStates[task.taskId]
  cleanupTaskState(ctx: ctx, taskId: task.taskId)
  logDebug("handleCancelled: task \(task.taskId)")

  sendTerminalCard(
    ctx: ctx, token: token, chatId: chatId, task: task, isPrivate: isPrivate,
    status: "\u{1F6AB} Cancelled", summary: "Task cancelled", draftState: draftState,
    groupIcon: "\u{1F6AB}")

  DatabaseManager.updateTask(taskId: task.taskId, status: "cancelled")
  logInfo("Task \(task.taskId) cancelled for chat \(chatId)")
}

private func handleOutput(
  ctx: PluginContext, token: String, chatId: String, task: TaskRow, isPrivate: Bool,
  eventJSON: String
) {
  guard let event = parseJSON(eventJSON, as: TaskOutputEvent.self),
    let text = event.text, !text.isEmpty
  else {
    logDebug("handleOutput: task \(task.taskId) failed to parse output event or empty text")
    return
  }

  logDebug("handleOutput: task \(task.taskId) text=\(text.count) chars")

  ctx.taskOutputTexts[task.taskId] = text

  if isPrivate {
    var state = ctx.taskDraftStates[task.taskId] ?? TaskDraftState(chatId: chatId)
    let segment = String(text.dropFirst(state.outputOffset))
    guard !segment.isEmpty else { return }
    let preview = truncateToWordBoundary(segment)

    if state.newSegment {
      state.recentMessages.append(preview)
      if state.recentMessages.count > 3 { state.recentMessages.removeFirst() }
      state.newSegment = false
    } else if !state.recentMessages.isEmpty {
      state.recentMessages[state.recentMessages.count - 1] = preview
    } else {
      state.recentMessages.append(preview)
      state.newSegment = false
    }

    ctx.taskDraftStates[task.taskId] = state
    sendTaskDraft(ctx: ctx, token: token, chatId: chatId, taskId: task.taskId)
  } else {
    telegramSendChatAction(token: token, chatId: chatId)
    if let statusMsgId = task.statusMsgId {
      let preview = String(text.prefix(200))
      let statusText = "\u{23F3} \(preview)\(text.count > 200 ? "..." : "")"
      _ = telegramEditMessage(
        token: token, chatId: chatId, messageId: statusMsgId,
        text: String(statusText.prefix(4096)))
    }
  }
}

// MARK: - Draft Handler

private func handleDraft(
  ctx: PluginContext, token: String, chatId: String, task: TaskRow, isPrivate: Bool,
  eventJSON: String
) {
  guard let event = parseJSON(eventJSON, as: TaskDraftEvent.self),
    let draft = event.draft,
    let text = draft.text, !text.isEmpty
  else {
    logDebug("handleDraft: task \(task.taskId) failed to parse draft event or empty text")
    return
  }

  logDebug("handleDraft: task \(task.taskId) text=\(text.count) chars")

  let parseMode = draft.parse_mode
  let htmlText = (parseMode == nil) ? markdownToTelegramHTML(text) : text
  let effectiveParseMode = parseMode ?? "HTML"
  let truncated = String(htmlText.prefix(4096))

  if isPrivate {
    _ = telegramSendMessageDraft(
      token: token, chatId: chatId,
      draftId: draftId(for: task.taskId),
      text: truncated
    )
  } else {
    editOrSendGroupMessage(
      ctx: ctx, token: token, chatId: chatId, task: task,
      text: truncated, parseMode: effectiveParseMode)
  }
}
