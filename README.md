# Osaurus Telegram

Connect Telegram chats to your Osaurus agents. Messages sent to your bot get a streaming conversational response by default. Use the `/work` command to dispatch background multi-step tasks when you need the full agent runtime.

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
2. The plugin receives it via webhook.
3. **Private chats** use the host inference API with streaming. Tokens arrive one by one, and the plugin pushes progressive draft updates to Telegram so the user sees the response being written in real time. A final permanent message is sent when streaming completes.
4. **Group chats** dispatch a background agent task. The plugin relays progress updates (typing indicators, editable status messages) and sends the final result as a message.
5. **`/work` command** explicitly dispatches a background agent task in any chat (e.g. `/work summarize today's news`). This is useful for complex multi-step tasks that benefit from full agent capabilities.

## Features

### Chat Mode (default)

All private chat messages use streaming inference for fast, conversational responses.

- **Token-by-token streaming** — Calls the host's `complete_stream` inference API. Draft updates are pushed to Telegram so the user sees the response being typed out progressively.
- **Conversation context** — The last 20 messages from the chat history are included, giving the model awareness of the ongoing conversation.
- **Immediate feedback** — A "Thinking..." draft appears instantly while the model generates its response.

### Work Mode (`/work` command)

Use `/work <prompt>` for complex, multi-step tasks that benefit from full agent capabilities (tool use, research, file access).

- **Background agent dispatch** — Your prompt becomes a task that runs asynchronously on the Osaurus agent runtime.
- **Real-time progress** — In private chats, a real message is created and updated with streaming output. In group chats, typing indicators and status messages show progress.
- **Clarification flow** — If the agent needs more information, an inline keyboard appears with options the user can tap. The selected answer is forwarded back to the agent automatically.
- **Long message splitting** — Responses that exceed Telegram's 4096-character limit are split into multiple messages.

**Task lifecycle:** `started` -> `activity` -> `progress` -> `completed` / `failed` / `cancelled`

### Group Chats

Group chat messages always use work mode dispatch since Telegram drafts are only available in private chats. The `/work` command also works in groups.

### Common Features

- **Chat allowlisting** — Restrict which Telegram chats can interact with your agent by configuring a comma-separated list of allowed chat IDs. Leave blank to allow all.
- **Message history** — Every inbound and outbound message is logged to a local SQLite database. Agents can query this history via the `telegram_get_chat_history` tool.
- **Automatic webhook management** — The plugin registers and deregisters its Telegram webhook automatically when you configure or change the bot token.
- **Secure webhook verification** — A random secret token is generated and verified on every incoming webhook request.

## Conversation Examples

### Chat — Streaming conversation (default)

```
You:   What's the difference between TCP and UDP?

Bot:   TCP is a connection-oriented protocol that...  (streams in progressively)

You:   Can you give me a simple analogy?

Bot:   Think of TCP like a phone call — you dial,...   (streams in progressively)
```

### Work — Background task via /work command

```
You:   /work summarize the top 5 Hacker News stories today

Bot:   ⏳ Working on it...          (status update)
Bot:   ⏳ Fetching HN front page... (status update)

Bot:   Here are today's top 5 HN stories:
       1. ...
       2. ...
```

### Clarification — Agent asks a follow-up

```
You:   /work deploy the latest build

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

### 4. Start Chatting

Send a message to your bot in Telegram. In private chats, you get a streaming conversational response. Use `/work <prompt>` to dispatch a background agent task for complex multi-step work.

## Bot Commands

| Command | Description |
|---------|-------------|
| `/start` | Start the bot and show a welcome message |
| `/clear` | Clear conversation history and start fresh |
| `/work <prompt>` | Dispatch a background agent task for multi-step work |

To make these appear in Telegram's command menu, send `/setcommands` to [@BotFather](https://t.me/BotFather) and enter:

```
start - Start the bot
clear - Clear conversation history
work - Dispatch a background agent task
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
| `allowed_chat_ids` | text | (empty) | Comma-separated Telegram chat IDs. Leave blank to allow all chats. |
| `send_typing` | toggle | on | Show a typing indicator while the agent works. Applies to work mode in group chats. |
| `send_progress` | toggle | off | Edit the status message with activity/progress text. Only applies to work mode in group chats. |

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
