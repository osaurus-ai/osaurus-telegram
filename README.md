# Osaurus Telegram

Conversational Telegram bot for Osaurus. Each Telegram chat becomes a continuous Osaurus session, and the agent talks to the user via reply tools — `handle_route` is just the entry point that mints a token and dispatches.

## How it works

```
User → Telegram → /webhook  (verify secret, dedup update_id, mint reply_token,
                              dispatch, react 👀 on the user's message)
                     ↓
                  Agent (background dispatch with deterministic session_id)
                     ↓
                  reply / reply_typing / reply_photo  →  Telegram → User
                     ↓
                  (👀 cleared on the first content-bearing reply)
```

The plugin is **agent-driven end-to-end**. Every user-visible message flows through tools the agent calls; `handle_route` only verifies the request and starts the run. Multi-message replies, status updates, and rich content all happen because the agent calls `reply` (or `reply_typing` / `reply_photo`) one or more times in a single run. Files the agent writes into the sandbox are auto-forwarded to the user by the plugin via the host's `invoke(type: "artifact")` hook — there's no agent-facing tool for sandbox attachments.

The plugin's only piece of plugin-owned UI is the loading-eye reaction: as soon as the dispatch is in flight, we react with 👀 on the user's incoming message so they see "I'm working on it" within a heartbeat. The reaction is cleared by the first content-bearing reply (or by the safety net if the agent never replies).

When the agent uses the host's clarify tool, the host fires a `CLARIFICATION` task event (`{"question":"…","options":[…],"allow_multiple":…}`) and suppresses the trailing `COMPLETED` for the pause. The plugin surfaces the question as a Telegram message — question first, then options as a numbered list (`1. …`, `2. …`) so the user can reply by index, and an optional "(reply with one)" / "(reply with one or more)" hint when `allow_multiple` is specified — marks the turn replied so the safety net stays silent, and clears the 👀. The same `(task_id, reply_token)` binding is retained so the paused task can `reply` once it resumes; the user's next chat message lands on the same `external_session_key` and continues the conversation naturally.

### Why reply tokens

The agent never sees the real Telegram `chat_id`. The webhook handler mints a short opaque `reply_token` per turn, stores `(token → chat_id, task_id)` in a per-plugin SQLite row, and includes the token in the prompt header. The reply tool takes the token, the plugin's `invoke` looks up the chat. Tokens are unguessable, expire after 10 minutes, and are scoped to one chat — so prompt injection from web pages, RAG documents, or other untrusted input cannot redirect outbound messages.

### Concurrency

Each user turn gets its own `reply_token` and its own row in `active_dispatches`. When a new message arrives while a previous task is still running for the same chat, the plugin soft-stops the prior task (`dispatch_interrupt(prev_task, new_text)` — the host appends the user's text into the live session and stops the current stream) and dispatches a fresh turn against the same `session_id`. The prior row is **not** deleted; it lives until its own terminal event (`COMPLETED`/`CANCELLED`) fires or the 10-minute TTL sweep reaps it. Multiple in-flight rows per chat are normal and expected — they only matter to the agent loop, never to the user's view.

To make the reply contract race-free, the plugin pre-inserts the row in `active_dispatches` **before** calling `dispatch`. That way the agent can never beat us to `reply` and observe a `stale_token`: by the time the host has scheduled the agent, the `reply_token` binding is already pinned. The row carries a placeholder `task_id` until `dispatch` returns the real one.

## Tools (called by the agent)

| Tool           | Description                                                                                                                                                            |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `reply`        | Send a text message. May be called multiple times per run.                                                                                                             |
| `reply_typing` | Show the Telegram "typing…" indicator (~5s).                                                                                                                           |
| `reply_photo`  | Send a photo by public URL with optional caption.                                                                                                                      |

All three take a `reply_token` (passed verbatim from the user-message header) plus their own arguments. Sandbox-generated files (images, PDFs, transcripts, etc.) are auto-forwarded by the plugin via the host's `invoke(type: "artifact")` hook — the agent doesn't need a tool call for them.

## Routes

| Route      | Method | Auth     | Notes                                                                                                                                                                        |
| ---------- | ------ | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/webhook` | POST   | `verify` | Telegram delivery endpoint. `tunnel_exposed: true` so it's reachable from Telegram. The plugin still verifies the `X-Telegram-Bot-Api-Secret-Token` header in constant time. |

## Bot commands

| Command                                | Description                                                                                                                                                                                                                                           |
| -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/clear`, `/reset`, `/new`, `/restart` | All aliases for the same action: bump the chat's session salt and cancel any in-flight task. The next message lands in a fresh transcript. Match is case-insensitive and tolerates Telegram's `@botname` suffix in group chats (e.g. `/clear@MyBot`). |

## Setup

The plugin is **per-agent**: each agent in Osaurus has its own bot token, its own webhook secret, and its own tunnel URL — so one Osaurus install can run as many independent Telegram bots as you have agents.

### 1. Create a Telegram bot

1. Message [@BotFather](https://t.me/BotFather) and send `/newbot`.
2. Copy the **bot token** (e.g. `123456:ABC-DEF…`).

### 2. Configure for the agent

1. Open Osaurus → Agents settings, choose the agent you want to expose, and find the Telegram plugin under that agent.
2. Paste the bot token into **Bot Token**.
3. That's it. The plugin handles the rest:
   - Generates a `webhook_secret` on first run (stored in the macOS Keychain, scoped to `(plugin_id, agent_id)`).
   - Receives the agent's tunnel URL automatically from Osaurus via `on_config_changed("tunnel_url", ...)` once the tunnel is up.
   - Calls Telegram's `setWebhook` as soon as both signals are available.
   - Drives the **Webhook** status indicator next to the bot token field via the `webhook_registered` config flag.

### 3. Chat

Send a message to your bot. The agent receives it as the next turn in a continuous session (`session_id` is a deterministic UUID5 of the chat id, so repeated messages reattach to the same Osaurus session row in the sidebar) and replies via the `reply` tool.

## Storage

The plugin keeps three tables in its per-plugin SQLite DB:

- `chat_sessions` — one row per `(agent_id, chat_id)` (session salt, blocked flag, timestamps).
- `active_dispatches` — one row per in-flight turn, keyed on `reply_token`. Multiple concurrent rows per `(agent_id, chat_id)` are allowed: each is created when the webhook handler dispatches that turn and cleared by its own terminal event (COMPLETED/FAILED/CANCELLED) or the 10-minute TTL sweep.
- `seen_updates` — idempotency cache for Telegram retries, keyed `(agent_id, update_id)`, TTL-pruned to 24 hours.

### Multi-agent isolation (ABI v4)

A single plugin instance is loaded once but can be wired into many agents. The host exposes `get_active_agent_id()` (ABI v4) so every per-agent callback (`handle_route`, `invoke`, `on_config_changed`, `on_task_event`) can resolve who is calling. The plugin uses that to:

- Hold per-agent in-memory state (`AgentState`) in a registry keyed by agent UUID — bot token, webhook secret, tunnel URL, and bot identity never bleed across agents.
- Partition all SQLite tables by `agent_id`, so two agents whose Telegram bots happen to see the same `chat_id` (very common — chat_id is per Telegram user, not per bot) cannot trample each other's rows.
- Use a deterministic per-chat `session_id` (UUID5 of `(salt, chat_id)`) so repeated deliveries reattach to the same Osaurus session. The host treats `session_id` as the external grouping key as of v3.
- Reject reply tokens minted by a different agent's binding (`stale_token`).
- Pass `tools: ["reply", "reply_typing", "reply_photo"]` on every `dispatch()` so the agent's loop has the reply surface loaded regardless of its own auto/manual tool-selection mode.

On first launch after the ABI v4 upgrade, the plugin detects the legacy schema (no `agent_id` column) and rebuilds the three tables. Existing rows are dropped — the data is transient (10-minute dispatch TTL, 24-hour dedup TTL, chat session salts default back to zero), so nothing user-facing is lost. The same drop-and-rebuild path also runs when the plugin detects the v2 `active_dispatches` schema (where `task_id` was the primary key); the v3 schema keys on `reply_token` instead so multiple in-flight turns per chat can coexist.

If the host is older than ABI v4 (`get_active_agent_id` unavailable), per-agent callbacks are refused (`handle_route` returns 503; `invoke` returns a `no_agent_context` error envelope). Upgrade Osaurus.

## Plugin-owned vs agent-owned messages

| Message                                             | Sent by                                                                                          |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Conversational reply                                | Agent (`reply` tool)                                                                             |
| Typing indicator                                    | Agent (`reply_typing` tool)                                                                      |
| Photo (public URL)                                  | Agent (`reply_photo` tool)                                                                       |
| File / image attachment (auto-forwarded artifact)   | Plugin (`invoke(type: "artifact")` hook, multipart upload via `host->file_read`; routed to the agent's most recent in-flight chat, deduped per `host_path`) |
| Loading 👀 reaction set on the user's message       | Plugin (`handle_route`, after dispatch succeeds)                                                 |
| Loading 👀 reaction cleared                         | Plugin (`Tools.swift` on first content-bearing reply, or `on_task_event` safety net)             |
| Clarification question (host CLARIFICATION event)   | Plugin (`on_task_event`, posts `question` + numbered `options` + optional `allow_multiple` hint; marks turn replied) |
| Rate-limit apology                                  | Plugin (`handle_route`)                                                                          |
| `/clear` (and aliases) confirmation                 | Plugin (`handle_route`)                                                                          |
| Safety-net "(done)" / "Sorry, something went wrong" | Plugin (`on_task_event`, only if the agent never called `reply`)                                 |

The agent owns content; the plugin owns meta-messages and the single 👀 loading indicator. Plugin-owned posts should be rare in healthy runs.

## Configuration

All keys live in the per-agent (`plugin_id, agent_id`) Keychain scope. You only ever set `bot_token`; everything else is automatic.

| Key                  | Type                            | Notes                                                                                                                                                                                                                                                                                                                                                                                                                    |
| -------------------- | ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `bot_token`          | secret (user-set)               | Telegram bot token from [@BotFather](https://t.me/BotFather). Required.                                                                                                                                                                                                                                                                                                                                                  |
| `webhook_secret`     | secret (auto-generated)         | 32-byte hex string created on first run. Sent back by Telegram in `X-Telegram-Bot-Api-Secret-Token` and verified in constant time on every webhook delivery.                                                                                                                                                                                                                                                             |
| `tunnel_url`         | host-managed                    | Pushed to the plugin by Osaurus when the agent's tunnel is up. The `webhook_url` field in the plugin's config (templated as `{{plugin_url}}/webhook`) is what tells Osaurus this plugin needs the resolved URL.                                                                                                                                                                                                          |
| `webhook_registered` | host-managed (status indicator) | Set to `"true"` only after Telegram itself confirms (via `getWebhookInfo`) that our URL is registered AND there's no recent delivery error. Cleared eagerly at the start of any state change that invalidates the previous registration (bot-token swap, tunnel URL change, teardown). The plugin's `webhook_status` config field (`connected_when: "webhook_registered"`) reads this to drive the green/grey indicator. |

### What "Webhook: connected" means

The indicator is grounded in Telegram's view, not just the optimistic acknowledgement of `setWebhook`. After every registration the plugin calls `getWebhookInfo` and only flips the indicator green if:

1. Telegram reports the URL it has matches the URL we just set, AND
2. there is no `last_error_date` within the last 5 minutes.

If either check fails (e.g. tunnel went down between requests, Telegram is failing to deliver), the indicator stays grey and the plugin's Insights log explains why (`verifyWebhook: ...`).

The flag also flips grey **eagerly** at the start of bot-token swaps and tunnel-URL changes — so you never see a stale-green indicator while a transition is in flight.

### What if the indicator stays grey after I save the bot token?

The plugin needs both `bot_token` AND `tunnel_url`. `tunnel_url` is pushed by Osaurus once your agent's tunnel comes up. Look at the plugin's Insights log for one of:

- `Saved bot_token; waiting for tunnel_url before registering webhook.` — the tunnel hasn't connected yet for this agent. Open the agent's tunnel page or restart Osaurus.
- `Got tunnel_url; waiting for bot_token before registering webhook.` — paste the bot token.
- `verifyWebhook: Telegram has url="..." but we expected "..."` — Telegram has a stale URL registered (e.g. from a previous tunnel). Save your bot token again or wait for the next tunnel push to re-register.
- `verifyWebhook: Telegram reports recent delivery error: ...` — Telegram can reach us (the URL matches) but a recent delivery failed. Usually transient.
- `Webhook registered at https://...` — done. Send a message to your bot.

## License

MIT
