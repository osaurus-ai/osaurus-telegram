# Osaurus Telegram

Connect Telegram chats to your Osaurus agents. Every message sent to your Telegram bot is forwarded to an Osaurus agent, and the agent's response streams back to the conversation in real time. Choose between **Work Mode** for background multi-step tasks or **Chat Mode** for fast, conversational exchanges with token-by-token streaming.

## How It Works

```
Telegram User                    Osaurus Telegram Plugin                Osaurus Host
     |                                    |                                  |
     |-- sends message ----------------->|                                  |
     |                                    |-- (Work) dispatch agent task --->|
     |                                    |<-- task events (progress, etc) --|
     |<-- typing / draft updates --------|                                  |
     |<-- final response ----------------|                                  |
     |                                    |                                  |
     |-- sends message ----------------->|                                  |
     |                                    |-- (Chat) complete_stream ------->|
     |<-- draft updates (token stream) --|<-- streaming tokens -------------|
     |<-- final message -----------------|                                  |
```

1. A Telegram user sends a message to your bot.
2. The plugin receives it via webhook and checks the configured **agent mode**.
3. **Work Mode** dispatches a background agent task. As the agent works, the plugin relays progress updates (typing indicators, draft messages, or editable status messages) back to Telegram. When the task completes, the final result is sent as a message.
4. **Chat Mode** (private chats) calls the host inference API with streaming enabled. Tokens arrive one by one, and the plugin pushes progressive draft updates to Telegram so the user sees the response being written in real time. In group chats, Chat Mode falls back to the Work Mode dispatch path.

## Features

### Work Mode (`agent_mode = "work"`)

Best for complex, multi-step tasks that benefit from full agent capabilities (tool use, research, file access).

- **Background agent dispatch** — Your message becomes a task that runs asynchronously on the Osaurus agent runtime.
- **Real-time progress in private chats** — Uses Telegram's `sendMessageDraft` API to show live status updates ("Working on it...", "50% — Analyzing data...") without cluttering the chat with extra messages.
- **Progress in group chats** — Sends typing indicators and optionally edits a status message with progress updates.
- **Clarification flow** — If the agent needs more information, an inline keyboard appears with options the user can tap. The selected answer is forwarded back to the agent automatically.
- **Long message splitting** — Responses that exceed Telegram's 4096-character limit are split into multiple messages with MarkdownV2 formatting preserved.

**Task lifecycle:** `started` -> `activity` -> `progress` -> `completed` / `failed` / `cancelled`

### Chat Mode (`agent_mode = "chat"`)

Best for quick, conversational back-and-forth without the overhead of a full agent task.

- **Token-by-token streaming** — In private chats, the plugin calls the host's `complete_stream` inference API. As tokens arrive, draft updates are pushed to Telegram so the user sees the response being typed out progressively.
- **Conversation context** — The last 20 messages from the chat history are included as context, giving the model awareness of the ongoing conversation.
- **Group chat fallback** — In group chats, Chat Mode automatically falls back to the Work Mode dispatch path since Telegram drafts are only available in private chats.
- **Immediate feedback** — A "Thinking..." draft appears instantly while the model generates its response.

### Common Features

- **Chat allowlisting** — Restrict which Telegram chats can interact with your agent by configuring a comma-separated list of allowed chat IDs. Leave blank to allow all.
- **Message history** — Every inbound and outbound message is logged to a local SQLite database. Agents can query this history via the `telegram_get_chat_history` tool.
- **Automatic webhook management** — The plugin registers and deregisters its Telegram webhook automatically when you configure or change the bot token.
- **Secure webhook verification** — A random secret token is generated and verified on every incoming webhook request.

## Conversation Examples

### Work Mode — Multi-step task

```
You:   Summarize the top 5 Hacker News stories today

Bot:   ⏳ Working on it...          (draft update)
Bot:   ⏳ Fetching HN front page... (draft update)
Bot:   ⏳ 60% — Summarizing...      (draft update)

Bot:   Here are today's top 5 HN stories:
       1. ...
       2. ...
```

### Chat Mode — Streaming conversation

```
You:   What's the difference between TCP and UDP?

Bot:   TCP is a connection-oriented protocol that...  (streams in progressively)

You:   Can you give me a simple analogy?

Bot:   Think of TCP like a phone call — you dial,...   (streams in progressively)
```

### Clarification — Agent asks a follow-up

```
You:   Deploy the latest build

Bot:   ❓ Which environment should I deploy to?
       [ Staging ]  [ Production ]  [ Dev ]

You:   (taps "Staging")

Bot:   ✅ Staging
Bot:   Deploying to staging... done! Build v2.3.1 is live.
```

## Setup

### 1. Create a Telegram Bot

1. Open Telegram and message [@BotFather](https://t.me/BotFather)
2. Send `/newbot` and follow the prompts to choose a name and username
3. Copy the **bot token** (e.g. `123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11`)

### 2. Install the Plugin

```bash
swift build -c release
osaurus tools package osaurus.telegram 0.1.0
osaurus tools install ./osaurus.telegram-0.1.0.zip
```

### 3. Configure

1. Open Osaurus and go to **Tools** settings (Cmd+Shift+M)
2. Find the **Telegram** plugin
3. Paste your bot token into the **Bot Token** field
4. The plugin will automatically validate the token and register a webhook with Telegram
5. Choose your preferred **Agent Mode** (Work or Chat)

### 4. Start Chatting

Send a message to your bot in Telegram. In Work Mode, the plugin dispatches it to an Osaurus agent and relays the response. In Chat Mode (private chats), you get a streaming conversational response.

## Bot Commands

| Command | Description |
|---------|-------------|
| `/start` | Start the bot and show a welcome message |
| `/clear` | Clear conversation history and start fresh |

To make these appear in Telegram's command menu, send `/setcommands` to [@BotFather](https://t.me/BotFather) and enter:

```
start - Start the bot
clear - Clear conversation history
```

## Tools

The plugin exposes two tools that agents can call during task execution:

| Tool | Description |
|------|-------------|
| `telegram_send` | Send a message to a Telegram chat. Supports MarkdownV2 formatting, reply threading, and inline keyboard markup. |
| `telegram_get_chat_history` | Retrieve recent messages from the local message log for a given chat. Returns up to 200 messages with sender info, timestamps, and media metadata. |

## Routes

| Route | Method | Auth | Description |
|-------|--------|------|-------------|
| `/webhook` | POST | `verify` | Telegram Bot API webhook endpoint. Validates the secret token header on every request. |
| `/health` | GET | `owner` | Health check. Returns webhook registration status and bot username as JSON. |

## Configuration

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `bot_token` | secret | — | Telegram bot token from [@BotFather](https://t.me/BotFather). Required. |
| `agent_mode` | select | `work` | `work` dispatches background agent tasks. `chat` uses streaming inference in private chats (falls back to work in groups). |
| `allowed_chat_ids` | text | (empty) | Comma-separated Telegram chat IDs. Leave blank to allow all chats. |
| `send_typing` | toggle | on | Show a typing indicator while the agent works. Applies to Work Mode in group chats. |
| `send_progress` | toggle | off | Edit the status message with activity/progress text. Only applies to Work Mode in group chats (private chats use drafts instead). |

## Development

### Build

```bash
swift build -c release
```

### Run Tests

```bash
swift test
```

### Verify Manifest

```bash
osaurus manifest extract .build/release/libosaurus-telegram.dylib
```

### Dev Mode (Hot Reload)

```bash
osaurus tools dev osaurus.telegram
```

## Publishing

This project includes a GitHub Actions workflow (`.github/workflows/release.yml`) that automatically builds and releases the plugin when you push a version tag.

```bash
git tag v0.1.0
git push origin v0.1.0
```

## Project Structure

```
Sources/osaurus_telegram/
├── Plugin.swift          # C ABI entry points and manifest
├── Models.swift          # Telegram API types and internal data models
├── Utilities.swift       # MarkdownV2 escaping, message splitting, JSON helpers
├── Database.swift        # SQLite schema and CRUD operations
├── TelegramAPI.swift     # Outbound Telegram Bot API calls (including sendMessageDraft)
├── PluginContext.swift   # Plugin state and lifecycle management
├── WebhookHandler.swift  # Inbound webhook, route handling, and chat-mode streaming
├── TaskHandler.swift     # Agent task event processing with draft updates
└── Tools.swift           # telegram_send and telegram_get_chat_history
```

## License

MIT
