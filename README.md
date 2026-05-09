# Osaurus Telegram

Conversational Telegram bot for Osaurus. Each Telegram chat becomes a continuous Osaurus session, and the agent talks to the user via reply tools — `handle_route` is just the entry point that mints a token and dispatches.

## How it works

```
User → Telegram → /webhook  (verify secret, dedup update_id, mint reply_token, dispatch)
                     ↓
                  Agent (background dispatch with deterministic session_id)
                     ↓
                  reply / reply_typing / reply_photo  →  Telegram → User
```

The plugin is **agent-driven end-to-end**. Every user-visible message flows through tools the agent calls; `handle_route` only verifies the request and starts the run. Multi-message replies, status updates, and rich content all happen because the agent calls `reply` (or `reply_typing` / `reply_photo`) one or more times in a single run.

### Why reply tokens

The agent never sees the real Telegram `chat_id`. The webhook handler mints a short opaque `reply_token` per turn, stores `(token → chat_id, task_id)` in a per-plugin SQLite row, and includes the token in the prompt header. The reply tool takes the token, the plugin's `invoke` looks up the chat. Tokens are unguessable, expire after 10 minutes, and are scoped to one chat — so prompt injection from web pages, RAG documents, or other untrusted input cannot redirect outbound messages.

### Concurrency

If a new message arrives while a task is still running for the same chat, the plugin issues `dispatch_interrupt(prev_task, new_text)` (the host appends the user's text into the live session and stops the current stream) and dispatches a fresh turn against the same `session_id`. The agent reattaches with full context; the user gets one coherent answer with no races.

## Tools (called by the agent)

| Tool | Description |
| --- | --- |
| `reply` | Send a text message. May be called multiple times per run. |
| `reply_typing` | Show the Telegram "typing…" indicator (~5s). |
| `reply_photo` | Send a photo by public URL with optional caption. |

All three take a `reply_token` (passed verbatim from the user-message header) plus their own arguments.

## Routes

| Route | Method | Auth | Notes |
| --- | --- | --- | --- |
| `/webhook` | POST | `verify` | Telegram delivery endpoint. `tunnel_exposed: true` so it's reachable from Telegram. The plugin still verifies the `X-Telegram-Bot-Api-Secret-Token` header in constant time. |

## Bot commands

| Command | Description |
| --- | --- |
| `/reset` | Bumps the chat's session salt and cancels any in-flight task. The next message lands in a fresh transcript. |

## Setup

### 1. Create a Telegram bot

1. Message [@BotFather](https://t.me/BotFather) and send `/newbot`.
2. Copy the **bot token** (e.g. `123456:ABC-DEF…`).

### 2. Configure

1. Open Osaurus → Agents settings, choose your agent, and find the Telegram plugin.
2. Paste the bot token into **Bot Token**.
3. The plugin auto-generates a `webhook_secret` on first run and registers the webhook with Telegram as soon as both `bot_token` and the agent's `tunnel_url` are available.

### 3. Chat

Send a message to your bot. The agent receives it as the next turn in a continuous session and replies via the `reply` tool.

## Storage

The plugin keeps three tables in its per-plugin SQLite DB:

- `chat_sessions` — one row per chat (session salt, blocked flag, timestamps).
- `active_dispatches` — at most one row per chat (UNIQUE chat_id) bound to a `reply_token`. Cleared on COMPLETED/FAILED.
- `seen_updates` — idempotency cache for Telegram retries, TTL-pruned to 24 hours.

## Plugin-owned vs agent-owned messages

| Message | Sent by |
| --- | --- |
| Conversational reply | Agent (`reply` tool) |
| Typing indicator | Agent (`reply_typing` tool) |
| Photo | Agent (`reply_photo` tool) |
| Rate-limit apology | Plugin (`handle_route`) |
| `/reset` confirmation | Plugin (`handle_route`) |
| Safety-net "(done)" / "Sorry, something went wrong" | Plugin (`on_task_event`, only if the agent never called `reply`) |

The agent owns content; the plugin owns meta-messages. Plugin-owned posts should be rare in healthy runs.

## Configuration

| Key | Type | Notes |
| --- | --- | --- |
| `bot_token` | secret | Telegram bot token from [@BotFather](https://t.me/BotFather). Required. |
| `webhook_secret` | secret | Generated automatically on first run. Sent back by Telegram in `X-Telegram-Bot-Api-Secret-Token`. |
| `tunnel_url` | host-managed | Pushed to the plugin by Osaurus when a tunnel is active; webhook is registered automatically once `bot_token` and `tunnel_url` are both present. |

## License

MIT
