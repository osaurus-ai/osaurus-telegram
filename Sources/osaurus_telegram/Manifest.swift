import Foundation

// MARK: - Plugin Manifest
//
// The manifest is what Osaurus reads to discover the plugin's id, version,
// secrets, routes, and tools. Keep it as a static JSON literal so the host's
// `osaurus manifest extract` can pull it directly out of the dylib symbol
// table without instantiating the plugin.

let pluginManifestJSON = #"""
  {
    "plugin_id": "osaurus.telegram",
    "name": "Telegram",
    "version": "1.5.0",
    "description": "Conversational Telegram bot. Each chat becomes a continuous Osaurus session and the agent talks to the user via reply tools.",
    "instructions": "You are connected to a Telegram chat. The user message is prefixed with [reply_token <token>]. To talk back, call the `reply` tool and pass that token verbatim. Use `reply_typing` before slow work, and call `reply` as many times as needed \u2014 one message per major thought. Keep each message under 4000 characters. Do not echo the reply_token or any meta text \u2014 only conversational content.",
    "license": "MIT",
    "authors": [],
    "min_macos": "15.0",
    "min_osaurus": "0.5.0",
    "secrets": [
      {
        "id": "bot_token",
        "label": "Bot Token",
        "description": "From [@BotFather](https://t.me/BotFather)",
        "required": true,
        "url": "https://t.me/BotFather"
      },
      {
        "id": "webhook_secret",
        "label": "Webhook Secret",
        "description": "Random string Telegram sends back in X-Telegram-Bot-Api-Secret-Token. Generated automatically on first run.",
        "required": true
      }
    ],
    "capabilities": {
      "routes": [
        {
          "id": "webhook",
          "path": "/webhook",
          "methods": ["POST"],
          "description": "Telegram webhook endpoint",
          "auth": "verify",
          "tunnel_exposed": true
        }
      ],
      "tools": [
        {
          "id": "reply",
          "description": "Send a text message to the Telegram user. Call this whenever you have something to tell the user \u2014 partial answers, status updates, or final replies. May be called multiple times per turn.",
          "parameters": {
            "type": "object",
            "properties": {
              "reply_token": {
                "type": "string",
                "description": "The token from the [reply_token ...] header in the user message."
              },
              "text": {
                "type": "string",
                "description": "Message text. Will be clamped to 4000 characters."
              },
              "parse_mode": {
                "type": "string",
                "enum": ["", "HTML", "MarkdownV2"]
              }
            },
            "required": ["reply_token", "text"]
          },
          "requirements": ["network"],
          "permission_policy": "auto"
        },
        {
          "id": "reply_typing",
          "description": "Show the Telegram 'typing...' indicator. Lasts ~5s; call again before long operations.",
          "parameters": {
            "type": "object",
            "properties": {
              "reply_token": { "type": "string" }
            },
            "required": ["reply_token"]
          },
          "requirements": ["network"],
          "permission_policy": "auto"
        },
        {
          "id": "reply_photo",
          "description": "Send a photo to the Telegram user. URL must be publicly reachable.",
          "parameters": {
            "type": "object",
            "properties": {
              "reply_token": { "type": "string" },
              "photo_url": { "type": "string" },
              "caption": { "type": "string" }
            },
            "required": ["reply_token", "photo_url"]
          },
          "requirements": ["network"],
          "permission_policy": "auto"
        }
      ]
    },
    "docs": {
      "readme": "README.md",
      "changelog": "CHANGELOG.md"
    }
  }
  """#
