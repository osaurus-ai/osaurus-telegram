import Foundation

// MARK: - Types

struct TaskStreamState {
  var messageId: Int
  var lastEditTime: Date
}

// MARK: - Plugin Context

final class PluginContext: @unchecked Sendable {
  var botToken: String?
  var botId: String?
  var botUsername: String?
  var webhookSecret: String?

  var taskOutputTexts: [String: String] = [:]
  var taskStreamStates: [String: TaskStreamState] = [:]

  let telegramSendTool = TelegramSendTool()
  let chatHistoryTool = TelegramGetChatHistoryTool()
}

// MARK: - Lifecycle

func initPlugin(_ ctx: PluginContext) {
  logDebug("initPlugin: starting")
  DatabaseManager.initSchema()
  logDebug("initPlugin: schema initialized")

  if let token = configGet("bot_token"), !token.isEmpty {
    ctx.botToken = token
    logDebug("initPlugin: bot_token found (\(token.count) chars)")

    if let secret = configGet("webhook_secret"), !secret.isEmpty {
      ctx.webhookSecret = secret
      logDebug("initPlugin: restored cached webhook_secret")
    } else {
      logDebug("initPlugin: no cached webhook_secret")
    }

    setupWebhook(ctx: ctx, token: token)
  } else {
    logInfo("No bot_token configured — waiting for configuration")
  }
  logDebug("initPlugin: complete")
}

func setupWebhook(ctx: PluginContext, token: String) {
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
  configSet("webhook_secret", secret)
  logDebug("setupWebhook: generated new webhook secret")

  let pluginId = "osaurus.telegram"
  guard let tunnelBase = configGet("tunnel_url") else {
    logWarn("No tunnel_url in config, skipping webhook registration")
    return
  }

  let webhookURL = "\(tunnelBase)/plugins/\(pluginId)/webhook"
  logDebug("setupWebhook: registering webhook at \(webhookURL)")

  if telegramSetWebhook(token: token, url: webhookURL, secretToken: secret) {
    configSet("webhook_registered", "true")
    logInfo("Webhook registered at \(webhookURL)")
  } else {
    configSet("webhook_registered", "false")
    logError("Failed to register webhook at \(webhookURL)")
  }
}

func onConfigChanged(ctx: PluginContext, key: String, value: String?) {
  logDebug("onConfigChanged: key=\(key) hasValue=\(value != nil)")
  guard key == "bot_token" else {
    logDebug("onConfigChanged: ignoring key '\(key)' (not bot_token)")
    return
  }

  if let oldToken = ctx.botToken, !oldToken.isEmpty {
    logDebug("onConfigChanged: tearing down old webhook (had token)")
    _ = telegramDeleteWebhook(token: oldToken)
    logInfo("Old webhook deleted")
  } else {
    logDebug("onConfigChanged: no old token to tear down")
  }

  ctx.botToken = nil
  ctx.botId = nil
  ctx.botUsername = nil
  ctx.webhookSecret = nil

  guard let newToken = value, !newToken.isEmpty else {
    configSet("webhook_registered", "false")
    configDelete("webhook_secret")
    logInfo("Bot token cleared")
    return
  }

  logDebug("onConfigChanged: new token provided (\(newToken.count) chars), setting up webhook")
  ctx.botToken = newToken
  setupWebhook(ctx: ctx, token: newToken)
}

func destroyPlugin(_ ctx: PluginContext) {
  if let token = ctx.botToken, !token.isEmpty {
    _ = telegramDeleteWebhook(token: token)
    logInfo("Webhook deleted on destroy")
  }
  configSet("webhook_registered", "false")
}
