import Foundation

// MARK: - Types

struct TaskStreamState {
  var messageId: Int
  var lastEditTime: Date
}

struct TaskDraftState {
  var chatId: String
  var toolCallCount: Int = 0
  var latestToolName: String?
  var recentMessages: [String] = []
  var outputOffset: Int = 0
  var newSegment: Bool = true
}

// MARK: - Plugin Context

final class PluginContext: @unchecked Sendable {
  var botToken: String?
  var botId: String?
  var botUsername: String?
  var webhookSecret: String?
  var tunnelURL: String?

  var taskOutputTexts: [String: String] = [:]
  var taskDraftStates: [String: TaskDraftState] = [:]
  var taskStreamStates: [String: TaskStreamState] = [:]

  private var draftPingTimer: DispatchSourceTimer?

  let telegramSendTool = TelegramSendTool()
  let chatHistoryTool = TelegramGetChatHistoryTool()
  let sendFileTool = TelegramSendFileTool()

  func startDraftPing() {
    guard draftPingTimer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now() + 5, repeating: 5)
    timer.setEventHandler { [weak self] in
      guard let ctx = self, let token = ctx.botToken else { return }
      let drafts = ctx.taskDraftStates
      if drafts.isEmpty {
        ctx.stopDraftPing()
        return
      }
      for (taskId, state) in drafts {
        sendTaskDraft(ctx: ctx, token: token, chatId: state.chatId, taskId: taskId)
      }
    }
    timer.resume()
    draftPingTimer = timer
  }

  func stopDraftPing() {
    draftPingTimer?.cancel()
    draftPingTimer = nil
  }
}

// MARK: - Lifecycle

func initPlugin(_ ctx: PluginContext) {
  logDebug("initPlugin: starting")
  DatabaseManager.initSchema()

  if let token = configGet("bot_token"), !token.isEmpty {
    ctx.botToken = token
    logDebug("initPlugin: bot_token loaded from config (\(token.count) chars)")
  }

  recoverActiveTasks(ctx: ctx)

  logInfo("initPlugin: ready, waiting for config delivery")
}

private func recoverActiveTasks(ctx: PluginContext) {
  let dbTasks = DatabaseManager.getRunningTasks()
  guard !dbTasks.isEmpty else { return }

  guard let json = listActiveTasks(),
    let data = json.data(using: .utf8),
    let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let hostTasks = parsed["tasks"] as? [[String: Any]]
  else {
    logDebug("recoverActiveTasks: no active tasks from host")
    return
  }

  let activeIds = Set(hostTasks.compactMap { $0["id"] as? String })

  var recovered = 0
  for task in dbTasks where activeIds.contains(task.taskId) {
    if task.chatType == "private" {
      ctx.taskDraftStates[task.taskId] = TaskDraftState(chatId: task.chatId)
      recovered += 1
    }
  }

  if recovered > 0 {
    ctx.startDraftPing()
    logInfo("recoverActiveTasks: recovered \(recovered) active task(s)")
  }
}

func setupWebhook(ctx: PluginContext, token: String, tunnelURL: String) {
  logDebug("setupWebhook: calling getMe to validate token")
  guard let botInfo = telegramGetMe(token: token) else {
    logError("Failed to validate bot token with getMe")
    configSet("webhook_registered", "false")
    return
  }

  ctx.botId = botInfo.botId
  ctx.botUsername = botInfo.username
  logInfo("Telegram bot @\(botInfo.username) (id: \(botInfo.botId)) validated")

  let secret = randomHexString(bytes: 32)
  ctx.webhookSecret = secret
  logDebug("setupWebhook: generated new webhook secret")

  let pluginId = "osaurus.telegram"
  let webhookURL = "\(tunnelURL)/plugins/\(pluginId)/webhook"
  logDebug("setupWebhook: registering webhook at \(webhookURL)")

  if telegramSetWebhook(token: token, url: webhookURL, secretToken: secret) {
    configSet("webhook_secret", secret)
    configSet("webhook_registered", "true")
    logInfo("Webhook registered at \(webhookURL)")
  } else {
    configSet("webhook_registered", "false")
    logError("Failed to register webhook at \(webhookURL)")
  }
}

func onConfigChanged(ctx: PluginContext, key: String, value: String?) {
  logDebug("onConfigChanged: key=\(key) hasValue=\(value != nil)")

  if key == "tunnel_url" {
    guard let newURL = value, !newURL.isEmpty else {
      logDebug("onConfigChanged: tunnel_url cleared")
      ctx.tunnelURL = nil
      return
    }
    ctx.tunnelURL = newURL
    guard let token = ctx.botToken, !token.isEmpty else {
      logDebug("onConfigChanged: tunnel_url stored, waiting for bot_token")
      return
    }
    logDebug("onConfigChanged: tunnel_url + bot_token both available, registering webhook")
    setupWebhook(ctx: ctx, token: token, tunnelURL: newURL)
    return
  }

  guard key == "bot_token" else {
    logDebug("onConfigChanged: ignoring key '\(key)'")
    return
  }

  let newToken = (value?.isEmpty == false) ? value : nil

  if newToken == ctx.botToken {
    logDebug("onConfigChanged: bot_token unchanged, skipping")
    return
  }

  if let oldToken = ctx.botToken, !oldToken.isEmpty {
    logDebug("onConfigChanged: tearing down old webhook")
    _ = telegramDeleteWebhook(token: oldToken)
    logInfo("Old webhook deleted")
  }

  ctx.botToken = nil
  ctx.botId = nil
  ctx.botUsername = nil
  ctx.webhookSecret = nil

  guard let newToken else {
    configSet("webhook_registered", "false")
    logInfo("Bot token cleared")
    return
  }

  ctx.botToken = newToken
  logDebug("onConfigChanged: bot_token stored (\(newToken.count) chars)")

  guard let tunnelURL = ctx.tunnelURL, !tunnelURL.isEmpty else {
    logDebug("onConfigChanged: bot_token stored, waiting for tunnel_url")
    return
  }
  setupWebhook(ctx: ctx, token: newToken, tunnelURL: tunnelURL)
}

func destroyPlugin(_ ctx: PluginContext) {
  ctx.stopDraftPing()
  if let token = ctx.botToken, !token.isEmpty {
    _ = telegramDeleteWebhook(token: token)
    logInfo("Webhook deleted on destroy")
  }
  configSet("webhook_registered", "false")
}
