import Foundation

// MARK: - Plugin Manifest
//
// The manifest is what Osaurus reads to discover the plugin's id, version,
// routes, tools, and config. Keep it as a static JSON literal so the host's
// `osaurus manifest extract` can pull it directly out of the dylib symbol
// table without instantiating the plugin.
//
// Why `capabilities.config` (instead of a top-level `secrets:` array):
// the `webhook_url` field with `value_template: "{{plugin_url}}/webhook"`
// is what tells Osaurus "this plugin is reachable through the tunnel and
// needs the resolved tunnel URL pushed to it". When `tunnel_url` becomes
// available the host calls `on_config_changed("tunnel_url", ...)` and the
// plugin can register the webhook with Telegram. Without that field the
// per-agent autoconfig flow does not fire.

/// Single source of truth for the plugin version. Keep in lockstep with
/// `osaurus-plugin.json` (ManifestTests pins the alignment).
let telegramPluginVersion = "1.6.0"

/// Earliest Osaurus host guaranteeing ABI v4 (`get_active_agent_id`),
/// which every per-agent callback in this plugin depends on. 0.18.14 is
/// the floor the osaurus-resend plugin (same ABI requirement) ships
/// with; older hosts leave the v4 slot NULL and per-agent routing
/// silently degrades.
let telegramMinOsaurusVersion = "0.18.14"

let pluginManifestJSON = #"""
  {
    "plugin_id": "osaurus.telegram",
    "name": "Telegram",
    "version": "\#(telegramPluginVersion)",
    "description": "Conversational Telegram bot. Each chat becomes a continuous Osaurus session and the agent talks to the user via reply tools.",
    "instructions": "You are connected to a Telegram chat. Each user message arrives prefixed with [reply_token <token> from <name>]. In group chats the header also carries `in_group reply_to_message_id=<id>` \u2014 thread your replies by passing that id as `reply_to_message_id` so the answer doesn't get lost in busy chats. The ONLY way the user sees anything is through the `reply` family of tools \u2014 every other tool (sandbox_exec, http_request, search_memory, clarify, etc.) is internal and invisible to them. The turn is not over until you have called `reply` (or another reply_* tool) with the answer.\n\nDo NOT call the `clarify` tool. Telegram has no native clarification UI \u2014 a `clarify` call lands silently on the user's end. If you need more information, call `reply` with the question phrased conversationally (you can list options as a short bulleted list inside the text, or attach an `inline_keyboard` for quick-pick buttons), then end the turn. The user's next chat message will continue the same session and your follow-up dispatch will receive it as the next user turn.\n\nRequired pattern for every user turn:\n1. (optional) call `reply_typing` if the next step is slow.\n2. (optional) call any data-gathering tools you need.\n3. ALWAYS call `reply` (or a `reply_*` media tool) with the answer (or the clarifying question), passing the exact reply_token verbatim, before ending the turn or calling any \"complete\"/\"done\" signal. Never end a turn with only a tool result \u2014 the user will see nothing.\n4. Call `reply` multiple times if it helps (one message per major thought). Keep each text under 4000 characters.\n\nRich media: send `reply_photo` with a public image URL, `reply_document` for files (PDFs, transcripts, archives), `reply_voice` for ogg/opus voice notes, `reply_audio` for music, `reply_video` for video. All of them accept a public URL and an optional caption (max 1024 chars). For inline keyboards on a `reply`, pass `inline_keyboard` as a 2D array of `{text, callback_data}` (or `{text, url}`) buttons; the user's button press will arrive as a follow-up user turn whose body is `[button:<callback_data>]`.\n\nFiles you generate in the sandbox (images, PDFs, transcripts, screenshots, etc.) are auto-forwarded to the user by the host \u2014 you do NOT need a tool call for them. Just produce the file and continue with `reply` for any narration. Do not try to attach sandbox paths via any tool; the auto-forward handles it.\n\nDo not echo the reply_token, the bracketed header, or any meta text \u2014 only conversational content goes in `reply.text`.",
    "license": "MIT",
    "authors": [],
    "min_macos": "15.0",
    "min_osaurus": "\#(telegramMinOsaurusVersion)",
    "capabilities": {
      "artifact_handler": true,
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
          "description": "Send a text message to the Telegram user. Call this whenever you have something to tell the user \u2014 partial answers, status updates, or final replies. May be called multiple times per turn. In group chats pass `reply_to_message_id` from the bracketed header so the reply threads under the user's question.",
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
              },
              "reply_to_message_id": {
                "type": "integer",
                "description": "Telegram message_id to thread under (the value from the prompt header in groups). Optional in DMs."
              },
              "inline_keyboard": {
                "type": "array",
                "description": "Optional 2D array of inline keyboard buttons. Each button is {text, callback_data} or {text, url}.",
                "items": {
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "text": { "type": "string" },
                      "callback_data": { "type": "string" },
                      "url": { "type": "string" }
                    },
                    "required": ["text"]
                  }
                }
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
              "caption": { "type": "string" },
              "reply_to_message_id": { "type": "integer" }
            },
            "required": ["reply_token", "photo_url"]
          },
          "requirements": ["network"],
          "permission_policy": "auto"
        },
        {
          "id": "reply_document",
          "description": "Send a generic file (PDF, transcript, archive, etc.) to the Telegram user. URL must be publicly reachable.",
          "parameters": {
            "type": "object",
            "properties": {
              "reply_token": { "type": "string" },
              "document_url": { "type": "string" },
              "caption": { "type": "string" },
              "reply_to_message_id": { "type": "integer" }
            },
            "required": ["reply_token", "document_url"]
          },
          "requirements": ["network"],
          "permission_policy": "auto"
        },
        {
          "id": "reply_voice",
          "description": "Send a voice note (ogg/opus) to the Telegram user. URL must be publicly reachable. Telegram renders this as a playable waveform.",
          "parameters": {
            "type": "object",
            "properties": {
              "reply_token": { "type": "string" },
              "voice_url": { "type": "string" },
              "caption": { "type": "string" },
              "reply_to_message_id": { "type": "integer" }
            },
            "required": ["reply_token", "voice_url"]
          },
          "requirements": ["network"],
          "permission_policy": "auto"
        },
        {
          "id": "reply_audio",
          "description": "Send a music/audio file (mp3 etc.) to the Telegram user. URL must be publicly reachable. Telegram renders this as a music player.",
          "parameters": {
            "type": "object",
            "properties": {
              "reply_token": { "type": "string" },
              "audio_url": { "type": "string" },
              "caption": { "type": "string" },
              "reply_to_message_id": { "type": "integer" }
            },
            "required": ["reply_token", "audio_url"]
          },
          "requirements": ["network"],
          "permission_policy": "auto"
        },
        {
          "id": "reply_video",
          "description": "Send a video file to the Telegram user. URL must be publicly reachable.",
          "parameters": {
            "type": "object",
            "properties": {
              "reply_token": { "type": "string" },
              "video_url": { "type": "string" },
              "caption": { "type": "string" },
              "reply_to_message_id": { "type": "integer" }
            },
            "required": ["reply_token", "video_url"]
          },
          "requirements": ["network"],
          "permission_policy": "auto"
        }
      ],
      "config": {
        "title": "Telegram",
        "sections": [
          {
            "title": "Bot Configuration",
            "fields": [
              {
                "key": "bot_token",
                "type": "secret",
                "label": "Bot Token",
                "placeholder": "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11",
                "description": "Get this from [@BotFather](https://t.me/BotFather)",
                "validation": {
                  "required": true,
                  "pattern": "^[0-9]+:[A-Za-z0-9_-]+$",
                  "pattern_hint": "Must be a valid Telegram bot token (e.g. 123456:ABC...)"
                }
              },
              {
                "key": "webhook_url",
                "type": "readonly",
                "label": "Webhook URL",
                "value_template": "{{plugin_url}}/webhook",
                "copyable": true
              },
              {
                "key": "webhook_status",
                "type": "status",
                "label": "Webhook",
                "connected_when": "webhook_registered"
              },
              {
                "key": "allowed_users",
                "type": "text",
                "label": "Allowed Users",
                "placeholder": "e.g. 123456789, @alice, @bob",
                "description": "Comma-separated Telegram user IDs or @usernames. Leave blank to allow everyone. Note: @usernames can change \u2014 numeric IDs are more durable. Send /whoami to the bot to discover your numeric ID."
              },
              {
                "key": "allowed_chat_ids",
                "type": "text",
                "label": "Allowed Chat IDs",
                "placeholder": "e.g. -1001234567890",
                "description": "Comma-separated Telegram numeric chat IDs (negative for groups). Leave blank to allow every chat. Send /whoami in a chat to discover its ID."
              }
            ]
          }
        ]
      }
    },
    "docs": {
      "readme": "README.md",
      "changelog": "CHANGELOG.md",
      "links": [
        { "label": "Telegram Bot API", "url": "https://core.telegram.org/bots/api" },
        { "label": "BotFather", "url": "https://t.me/BotFather" }
      ]
    }
  }
  """#
