import Foundation

// MARK: - Plugin Context

/// In-memory state cached from the host. Everything persistent lives in the
/// per-plugin SQLite DB; this just avoids a `config_get` round-trip on the
/// hot path.
final class PluginContext: @unchecked Sendable {
  var botToken: String?
  var botId: String?
  var botUsername: String?
  var webhookSecret: String?
  var tunnelURL: String?
}

// MARK: - Lifecycle

func initPlugin(_ ctx: PluginContext) {
  logDebug("initPlugin: starting")
  DatabaseManager.initSchema()
  DatabaseManager.sweepExpiredDispatches()

  if let secret = configGet("webhook_secret"), !secret.isEmpty {
    ctx.webhookSecret = secret
    logDebug("initPlugin: webhook_secret loaded from config")
  } else {
    let secret = randomHexString(bytes: 32)
    configSet("webhook_secret", secret)
    ctx.webhookSecret = secret
    logInfo("initPlugin: generated new webhook_secret")
  }

  if let token = configGet("bot_token"), !token.isEmpty {
    ctx.botToken = token
    logDebug("initPlugin: bot_token loaded from config (\(token.count) chars)")
  }

  if let tunnelURL = configGet("tunnel_url"), !tunnelURL.isEmpty {
    ctx.tunnelURL = tunnelURL
    logDebug("initPlugin: tunnel_url loaded from config")
  }

  logInfo("initPlugin: ready, waiting for config delivery")
}

// MARK: - Webhook Setup

private func withRetry<T>(
  maxAttempts: Int = 3,
  initialDelay: TimeInterval = 1.0,
  operation: String,
  block: () -> T?
) -> T? {
  for attempt in 1...maxAttempts {
    if let result = block() { return result }
    if attempt < maxAttempts {
      let delay = initialDelay * pow(2.0, Double(attempt - 1))
      logWarn("\(operation) failed (attempt \(attempt)/\(maxAttempts)), retrying in \(delay)s")
      Thread.sleep(forTimeInterval: delay)
    }
  }
  logError("\(operation) failed after \(maxAttempts) attempts")
  return nil
}

func setupWebhook(ctx: PluginContext, token: String, tunnelURL: String) {
  logDebug("setupWebhook: calling getMe to validate token")
  guard let botInfo = withRetry(operation: "getMe", block: { telegramGetMe(token: token) }) else {
    logError("Failed to validate bot token with getMe")
    return
  }

  ctx.botId = botInfo.botId
  ctx.botUsername = botInfo.username
  logInfo("Telegram bot @\(botInfo.username) (id: \(botInfo.botId)) validated")

  guard let secret = ctx.webhookSecret, !secret.isEmpty else {
    logError("setupWebhook: no webhook_secret available")
    return
  }

  let pluginId = "osaurus.telegram"
  let webhookURL =
    tunnelURL.trimmingCharacters(in: .init(charactersIn: "/")) + "/plugins/\(pluginId)/webhook"
  logDebug("setupWebhook: registering webhook at \(webhookURL)")

  let registered =
    withRetry(operation: "setWebhook") {
      telegramSetWebhook(token: token, url: webhookURL, secretToken: secret) ? true : nil
    } != nil
  if registered {
    logInfo("Webhook registered at \(webhookURL)")
  } else {
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

  if key == "webhook_secret" {
    if let v = value, !v.isEmpty {
      ctx.webhookSecret = v
      logDebug("onConfigChanged: webhook_secret refreshed")
    }
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

  guard let newToken else {
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
  if let token = ctx.botToken, !token.isEmpty {
    _ = telegramDeleteWebhook(token: token)
    logInfo("Webhook deleted on destroy")
  }
}
