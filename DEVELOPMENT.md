# Development

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

## Build

```bash
swift build -c release
```

## Run Tests

```bash
swift test
```

## Verify Manifest

```bash
osaurus manifest extract .build/release/libosaurus-telegram.dylib
```

## Dev Mode (Hot Reload)

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
