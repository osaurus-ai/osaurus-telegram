# Osaurus Telegram

Connect Telegram chats to your Osaurus agents. Private chats stream conversational replies in real time using the host's unified agent loop (tools, sandbox, multi-step reasoning all included). Group chats dispatch each message as a background agent task that reattaches to a per-user session, so each participant has their own continuous thread.

## Features

### Private chats — streaming agent loop

Direct messages use the host's `complete_stream` inference API end-to-end.

- **Token-by-token streaming** — Draft updates are pushed to Telegram so the user sees the response being typed out progressively.
- **Tool calling + sandbox** — `tools: true` and `max_iterations` (default 10) are enabled, so the agent can run tools, write code, browse the web, etc., in the same chat turn.
- **Conversation context** — The last 20 messages from the chat history are included.
- **Immediate feedback** — A "Thinking..." draft appears instantly while the model generates its response, and reactions on the user's message track tool / writing / done states.

### Group chats — dispatched per-user sessions

In groups the plugin dispatches each message via `host->dispatch` with an `external_session_key` of `telegram:chat-<chatId>:user-<userId>`. Repeated messages from the same user reattach to one Osaurus session row in the sidebar, so each participant has a continuous thread the agent can reason over.

- **Real-time progress** — The bot edits a status message ("⏳ Working on it...") with current activity and progress.
- **Reply-to-thread interrupt** — Replying to an in-flight agent message soft-interrupts the running task with the new prompt (`dispatch_interrupt`). Replying to an ended agent message redispatches as the next turn in the same session.

### Common features

- **Unified clarification flow** — When the agent needs more info it just asks inline; the user replies normally and the answer is routed back as the next dispatch turn (the legacy inline-keyboard / `dispatch_clarify` round-trip has been removed in line with the deprecated host APIs).
- **Artifact uploads** — Files produced by the agent during streaming are surfaced via the `complete_stream` response's `shared_artifacts` array and uploaded directly to the originating chat. Artifacts produced during dispatched tasks come through the artifact-handler invoke. Both paths dedupe so files aren't double-uploaded.
- **User allowlisting** — Restrict which Telegram users can interact with your agent by configuring a comma-separated list of usernames (e.g. `@alice, @bob`). Leave blank to allow everyone.
- **Message history** — Every inbound and outbound message is logged to a local SQLite database. Agents can query this history via the `telegram_get_chat_history` tool.
- **Automatic webhook management** — The plugin registers and deregisters its Telegram webhook automatically when you configure or change the bot token.
- **Secure webhook verification** — A random secret token is generated and verified on every incoming webhook request.

## Conversation Examples

### Streaming chat (private chat)

```
You:   What's the difference between TCP and UDP?

Bot:   TCP is a connection-oriented protocol that...  (streams in progressively)

You:   Can you give me a simple analogy?

Bot:   Think of TCP like a phone call — you dial,...   (streams in progressively)
```

### Multi-step task in private chat

The same streaming path runs the agent loop with tools enabled, so multi-step
work happens in one chat turn:

```
You:   summarize the top 5 Hacker News stories today

Bot:   👀 (reaction)
Bot:   ⚙ (reaction — running web_search)
Bot:   ✍ (reaction — writing)
Bot:   Here are today's top 5 HN stories:
       1. ...
       2. ...
Bot:   ✅ (reaction)
```

### Group chat — dispatched task

```
@alice in #general:  what time does the meeting start?

Bot (replying):  ⏳ Working on it...
Bot (replying):  ⏳ Checking the calendar
Bot (replying):  The kickoff meeting is at 3pm PT today.
```

### Clarification — Agent asks a follow-up

```
You:   deploy the latest build

Bot:   ❓ Which environment should I deploy to?
       • Staging
       • Production
       • Dev

You (reply): Staging

Bot:   Deploying to staging... done! Build v2.3.1 is live.
```

## Setup

### 1. Create a Telegram Bot

1. Open Telegram and message [@BotFather](https://t.me/BotFather)
2. Send `/newbot` and follow the prompts to choose a name and username
3. Copy the **bot token** (e.g. `123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11`)

### 2. Configure

1. Open Osaurus and go to **Agents** settings (Cmd+Shift+M)
2. Create or choose your Agent
3. Find the **Telegram** plugin (make sure it's installed)
4. Paste your bot token into the **Bot Token** field
5. The plugin will automatically validate the token and register a webhook with Telegram

### 3. Start Chatting

Send a message to your bot in Telegram. In private chats you get a streaming conversational response with full tool access. In group chats, each message is dispatched as a per-user agent task that reattaches to the same Osaurus session on subsequent messages.

## Bot Commands

| Command   | Description                                                            |
| --------- | ---------------------------------------------------------------------- |
| `/start`  | Start the bot and show a welcome message                               |
| `/clear`  | Clear conversation history and start fresh (per-user in group chats)   |
| `/status` | Show the last 5 dispatched tasks for the current chat                  |
| `/cancel` | Cancel the latest running task (or pass a task id: `/cancel <taskId>`) |

To make these appear in Telegram's command menu, send `/setcommands` to [@BotFather](https://t.me/BotFather) and enter:

```
start - Start the bot
clear - Clear conversation history
status - Show recent agent tasks
cancel - Cancel the latest running task
```

## Tools

The plugin exposes the following tools that agents can call:

| Tool                        | Description                                                                                                                                        |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `telegram_list_chats`       | List known Telegram chats the bot has interacted with. Filter by username or chat type to discover chat IDs before sending.                        |
| `telegram_get_chat_history` | Retrieve recent messages from the local message log for a given chat. Returns up to 200 messages with sender info, timestamps, and media metadata. |
| `telegram_send`             | Send a message to a Telegram chat. Supports reply threading and inline keyboard markup.                                                            |
| `telegram_send_file`        | Upload a photo or document from a `~/.osaurus/artifacts/` path to a chat, with optional caption.                                                   |
| `telegram_set_reaction`     | Add or remove an emoji reaction on a Telegram message.                                                                                             |

## Routes

| Route      | Method | Auth     | Description                                                                            |
| ---------- | ------ | -------- | -------------------------------------------------------------------------------------- |
| `/webhook` | POST   | `verify` | Telegram Bot API webhook endpoint. Validates the secret token header on every request. |
| `/health`  | GET    | `owner`  | Health check. Returns webhook registration status and bot username as JSON.            |

## Configuration

| Key                    | Type   | Default | Description                                                                                                          |
| ---------------------- | ------ | ------- | -------------------------------------------------------------------------------------------------------------------- |
| `bot_token`            | secret | —       | Telegram bot token from [@BotFather](https://t.me/BotFather). Required.                                              |
| `allowed_users`        | text   | (empty) | Comma-separated Telegram usernames (e.g. `@alice, @bob`). Leave blank to allow everyone.                             |
| `send_typing`          | toggle | on      | Show a typing indicator while the agent works in group chats.                                                        |
| `enable_tools`         | toggle | on      | Allow the agent to use tools during streaming chat.                                                                  |
| `enable_sandbox`       | toggle | on      | Allow the agent to execute code and read/write files in the sandboxed environment.                                   |
| `enable_preflight`     | toggle | off     | Run a preflight capability search before inference to auto-discover relevant tools.                                  |
| `max_iterations`       | number | 10      | Maximum agentic loop iterations for streaming chat (1–30).                                                           |
| `auto_upload_artifacts`| toggle | on      | Automatically upload files produced by the agent to the originating chat.                                            |
| `system_prompt`        | text   | (empty) | Optional extra system prompt appended to the default Telegram chat instructions.                                     |
| `tool_status_messages` | text   | (empty) | JSON object mapping tool-name prefixes to friendly status labels shown in draft updates.                             |

## License

MIT
