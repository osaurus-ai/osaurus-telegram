import Foundation

// MARK: - Plugin Context

final class PluginContext: @unchecked Sendable {
  var botToken: String?
  var botId: String?
  var botUsername: String?
  var webhookSecret: String?

  let telegramSendTool = TelegramSendTool()
  let chatHistoryTool = TelegramGetChatHistoryTool()
}

// MARK: - Lifecycle

func initPlugin(_ ctx: PluginContext) {
  DatabaseManager.initSchema()

  if let token = configGet("bot_token"), !token.isEmpty {
    ctx.botToken = token

    // Restore cached webhook secret
    if let secret = configGet("webhook_secret"), !secret.isEmpty {
      ctx.webhookSecret = secret
    }

    setupWebhook(ctx: ctx, token: token)
  } else {
    logInfo("No bot_token configured — waiting for configuration")
  }
}

func setupWebhook(ctx: PluginContext, token: String) {
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

  // Build webhook URL using the plugin_id
  let pluginId = "ai.osaurus.telegram"
  guard let tunnelBase = configGet("tunnel_url") else {
    // If tunnel_url isn't in config, we can't register webhook.
    // The host may provide it via plugin_url or the user sets it manually.
    logWarn("No tunnel_url in config, skipping webhook registration")
    return
  }

  let webhookURL = "\(tunnelBase)/plugins/\(pluginId)/webhook"

  if telegramSetWebhook(token: token, url: webhookURL, secretToken: secret) {
    configSet("webhook_registered", "true")
    logInfo("Webhook registered at \(webhookURL)")
  } else {
    configSet("webhook_registered", "false")
    logError("Failed to register webhook at \(webhookURL)")
  }
}

func onConfigChanged(ctx: PluginContext, key: String, value: String?) {
  guard key == "bot_token" else { return }

  // Tear down old webhook if we had a token
  if let oldToken = ctx.botToken, !oldToken.isEmpty {
    _ = telegramDeleteWebhook(token: oldToken)
    logInfo("Old webhook deleted")
  }

  // Clear bot state
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
