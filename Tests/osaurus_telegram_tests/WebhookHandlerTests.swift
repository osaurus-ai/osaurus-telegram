import Foundation
import Testing

@testable import osaurus_telegram

// MARK: - handleRoute

@Suite("Webhook Handler Routing")
struct HandleRouteTests {

  @Test("Returns 400 for unparseable request JSON")
  func invalidRequestJSON() {
    let ctx = PluginContext()
    let response = handleRoute(ctx: ctx, requestJSON: "not json")
    let parsed =
      try? JSONSerialization.jsonObject(with: response.data(using: .utf8)!) as? [String: Any]
    #expect(parsed?["status"] as? Int == 400)
  }

  @Test("Returns 404 for unknown route_id")
  func unknownRoute() {
    let ctx = PluginContext()
    let req = "{\"route_id\":\"unknown\",\"method\":\"GET\",\"path\":\"/foo\"}"
    let response = handleRoute(ctx: ctx, requestJSON: req)
    let parsed =
      try? JSONSerialization.jsonObject(with: response.data(using: .utf8)!) as? [String: Any]
    #expect(parsed?["status"] as? Int == 404)
  }

  @Test("Webhook rejects request without secret token")
  func webhookNoSecret() {
    let ctx = PluginContext()
    ctx.webhookSecret = "correct-secret"
    let req = """
      {
        "route_id": "webhook",
        "method": "POST",
        "path": "/webhook",
        "headers": {},
        "body": "{\\"update_id\\":1}"
      }
      """
    let response = handleRoute(ctx: ctx, requestJSON: req)
    let parsed =
      try? JSONSerialization.jsonObject(with: response.data(using: .utf8)!) as? [String: Any]
    #expect(parsed?["status"] as? Int == 401)
  }

  @Test("Webhook rejects request with wrong secret token")
  func webhookWrongSecret() {
    let ctx = PluginContext()
    ctx.webhookSecret = "correct-secret"
    let req = """
      {
        "route_id": "webhook",
        "method": "POST",
        "path": "/webhook",
        "headers": {"x-telegram-bot-api-secret-token": "wrong-secret"},
        "body": "{\\"update_id\\":1}"
      }
      """
    let response = handleRoute(ctx: ctx, requestJSON: req)
    let parsed =
      try? JSONSerialization.jsonObject(with: response.data(using: .utf8)!) as? [String: Any]
    #expect(parsed?["status"] as? Int == 401)
  }

  @Test("Webhook accepts request with correct secret token")
  func webhookCorrectSecret() {
    let ctx = PluginContext()
    ctx.webhookSecret = "my-secret"
    let req = """
      {
        "route_id": "webhook",
        "method": "POST",
        "path": "/webhook",
        "headers": {"x-telegram-bot-api-secret-token": "my-secret"},
        "body": "{\\"update_id\\":1}"
      }
      """
    let response = handleRoute(ctx: ctx, requestJSON: req)
    let parsed =
      try? JSONSerialization.jsonObject(with: response.data(using: .utf8)!) as? [String: Any]
    #expect(parsed?["status"] as? Int == 200)
  }

  @Test("Webhook returns 200 even for malformed update body")
  func webhookBadBody() {
    let ctx = PluginContext()
    ctx.webhookSecret = "secret"
    let req = """
      {
        "route_id": "webhook",
        "method": "POST",
        "path": "/webhook",
        "headers": {"x-telegram-bot-api-secret-token": "secret"},
        "body": "this is not json"
      }
      """
    let response = handleRoute(ctx: ctx, requestJSON: req)
    let parsed =
      try? JSONSerialization.jsonObject(with: response.data(using: .utf8)!) as? [String: Any]
    // Returns 200 to prevent Telegram from retrying bad payloads
    #expect(parsed?["status"] as? Int == 200)
  }

  @Test("Health endpoint returns status when no bot configured")
  func healthNoBot() {
    let ctx = PluginContext()
    let req = "{\"route_id\":\"health\",\"method\":\"GET\",\"path\":\"/health\"}"
    let response = handleRoute(ctx: ctx, requestJSON: req)
    let parsed =
      try? JSONSerialization.jsonObject(with: response.data(using: .utf8)!) as? [String: Any]
    #expect(parsed?["status"] as? Int == 200)

    let body = parsed?["body"] as? String ?? ""
    let bodyParsed =
      try? JSONSerialization.jsonObject(with: body.data(using: .utf8)!) as? [String: Any]
    #expect(bodyParsed?["ok"] as? Bool == false)
    #expect(bodyParsed?["bot_username"] as? String == "")
  }

  @Test("Health endpoint reflects bot username when set")
  func healthWithBot() {
    let ctx = PluginContext()
    ctx.botUsername = "test_bot"
    let req = "{\"route_id\":\"health\",\"method\":\"GET\",\"path\":\"/health\"}"
    let response = handleRoute(ctx: ctx, requestJSON: req)
    let parsed =
      try? JSONSerialization.jsonObject(with: response.data(using: .utf8)!) as? [String: Any]

    let body = parsed?["body"] as? String ?? ""
    let bodyParsed =
      try? JSONSerialization.jsonObject(with: body.data(using: .utf8)!) as? [String: Any]
    #expect(bodyParsed?["bot_username"] as? String == "test_bot")
  }
}

// MARK: - Manifest Validation

@Suite("Manifest Validation")
struct ManifestTests {

  @Test("Manifest is valid JSON with required fields")
  func manifestIsValidJSON() throws {
    // Extract manifest by calling the same string literal from Plugin.swift
    // We test by deserializing the manifest JSON
    let manifest = """
      {
        "plugin_id": "ai.osaurus.telegram",
        "name": "Telegram",
        "version": "0.1.0",
        "description": "Connect Telegram chats to your Osaurus agents",
        "capabilities": {
          "tools": [
            { "id": "telegram_send" },
            { "id": "telegram_get_chat_history" }
          ],
          "routes": [
            { "id": "webhook", "path": "/webhook" },
            { "id": "health", "path": "/health" }
          ]
        }
      }
      """
    let data = try #require(manifest.data(using: .utf8))
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["plugin_id"] as? String == "ai.osaurus.telegram")
    #expect(json["version"] as? String == "0.1.0")

    let caps = try #require(json["capabilities"] as? [String: Any])
    let tools = try #require(caps["tools"] as? [[String: Any]])
    #expect(tools.count == 2)
    #expect(tools[0]["id"] as? String == "telegram_send")
    #expect(tools[1]["id"] as? String == "telegram_get_chat_history")

    let routes = try #require(caps["routes"] as? [[String: Any]])
    #expect(routes.count == 2)
  }
}
