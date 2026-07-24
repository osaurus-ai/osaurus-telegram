import Foundation

// MARK: - Database Manager
//
// Three tables in a per-plugin SQLite DB. All tables are partitioned by
// `agent_id` (schema v2 / ABI v4) because Telegram chat_ids are user-
// scoped, not bot-scoped — the same chat_id can mean different things to
// two agents sharing the plugin.
//
//   * chat_sessions      — (agent_id, chat_id, user_id) PK (schema v4).
//                          session_salt + blocked are tracked PER USER
//                          inside a chat so /clear in a group only wipes
//                          the caller's transcript, not everyone else's.
//                          For DMs `user_id == chat_id` so the row count
//                          and behaviour are identical to the v3 schema.
//   * active_dispatches  — reply_token PK (schema v3). Pre-inserted BEFORE
//                          `dispatch` so a fast agent can't race past us
//                          and hit `stale_token`. The placeholder task_id
//                          is patched by `updateTaskId` once dispatch
//                          returns. Multiple in-flight rows per
//                          (agent_id, chat_id, user_id) coexist and age
//                          out under the 10-minute TTL sweep.
//   * seen_updates       — (agent_id, update_id) PK; Telegram-retry
//                          idempotency cache, pruned to 24h.

struct ChatSessionRow {
  let chatId: Int64
  let userId: Int64
  let sessionSalt: Int
  let blocked: Int
}

struct ActiveDispatchRow {
  let taskId: String
  let agentId: String
  let chatId: Int64
  /// Telegram user_id of the user that triggered this dispatch. Used to
  /// scope per-user soft-interrupts and per-user session lookups inside
  /// group chats. 0 is the "unknown user" sentinel (older rows / synthetic
  /// test seeds); behaves exactly like a single-user chat in DMs.
  let userId: Int64
  let replyToken: String
  let sessionId: String
  let expiresAt: Int
  let hasReplied: Int
  /// Telegram message_id of the user message that triggered this dispatch.
  /// Used to set/clear the "loading" 👀 reaction. 0 means "unknown" (older
  /// rows / synthetic test rows without a real Telegram source).
  let incomingMessageId: Int64
}

enum DatabaseManager {

  // MARK: - Schema

  static func initSchema() {
    // Migrations are drop-and-rebuild. Every table is short-lived
    // (10-min dispatches, 24h dedup, salts default to zero) so losing
    // rows is harmless.

    // Pre-v2 (no agent_id column) — drop everything.
    if tableExists("chat_sessions"), !columnExists(table: "chat_sessions", column: "agent_id") {
      logInfo("Database: detected pre-ABI-v4 schema; dropping legacy tables")
      for sql in [
        "DROP TABLE IF EXISTS chat_sessions",
        "DROP TABLE IF EXISTS active_dispatches",
        "DROP TABLE IF EXISTS seen_updates",
      ] {
        dbExec(sql, params: "[]")
      }
    }

    // v3 chat_sessions ((agent_id, chat_id) PK) → v4 ((agent_id, chat_id,
    // user_id) PK). Per-user salts let `/clear` in a group affect only
    // the caller. Detect by the missing `user_id` column. Data is
    // transient (salts default back to zero) so a drop is harmless.
    if tableExists("chat_sessions"),
      !columnExists(table: "chat_sessions", column: "user_id")
    {
      logInfo("Database: detected v3 chat_sessions (no user_id); rebuilding for per-user sessions")
      dbExec("DROP TABLE IF EXISTS chat_sessions", params: "[]")
    }

    // v2 active_dispatches (task_id PK) → v3 (reply_token PK).
    if tableExists("active_dispatches"),
      primaryKeyColumn(table: "active_dispatches") != "reply_token"
    {
      logInfo("Database: detected v2 active_dispatches; rebuilding with reply_token PK")
      dbExec("DROP TABLE IF EXISTS active_dispatches", params: "[]")
    }

    // v3 → v3.1: incoming_message_id column added so the loading-eye
    // reaction can address the user's original Telegram message at
    // terminal/clear time. The row data is transient (10-min TTL) so
    // dropping is harmless.
    if tableExists("active_dispatches"),
      !columnExists(table: "active_dispatches", column: "incoming_message_id")
    {
      logInfo("Database: detected pre-reaction active_dispatches; rebuilding")
      dbExec("DROP TABLE IF EXISTS active_dispatches", params: "[]")
    }

    // v3.1 → v3.2: user_id column added so per-user soft-interrupts in
    // group chats target only the calling user's prior task. Transient.
    if tableExists("active_dispatches"),
      !columnExists(table: "active_dispatches", column: "user_id")
    {
      logInfo("Database: detected pre-user_id active_dispatches; rebuilding")
      dbExec("DROP TABLE IF EXISTS active_dispatches", params: "[]")
    }

    let statements = [
      """
      CREATE TABLE IF NOT EXISTS chat_sessions (
        agent_id       TEXT    NOT NULL,
        chat_id        INTEGER NOT NULL,
        user_id        INTEGER NOT NULL,
        session_salt   INTEGER NOT NULL DEFAULT 0,
        blocked        INTEGER NOT NULL DEFAULT 0,
        last_msg_at    INTEGER NOT NULL,
        created_at     INTEGER NOT NULL,
        PRIMARY KEY (agent_id, chat_id, user_id)
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS active_dispatches (
        reply_token         TEXT PRIMARY KEY,
        task_id             TEXT NOT NULL,
        agent_id            TEXT NOT NULL,
        chat_id             INTEGER NOT NULL,
        user_id             INTEGER NOT NULL DEFAULT 0,
        session_id          TEXT NOT NULL,
        started_at          INTEGER NOT NULL,
        expires_at          INTEGER NOT NULL,
        has_replied         INTEGER NOT NULL DEFAULT 0,
        incoming_message_id INTEGER NOT NULL DEFAULT 0
      )
      """,
      "CREATE INDEX IF NOT EXISTS idx_dispatches_task ON active_dispatches(task_id)",
      "CREATE INDEX IF NOT EXISTS idx_dispatches_chat "
        + "ON active_dispatches(agent_id, chat_id, started_at)",
      "CREATE INDEX IF NOT EXISTS idx_dispatches_user "
        + "ON active_dispatches(agent_id, chat_id, user_id, started_at)",
      """
      CREATE TABLE IF NOT EXISTS seen_updates (
        agent_id       TEXT NOT NULL,
        update_id      INTEGER NOT NULL,
        seen_at        INTEGER NOT NULL,
        completed      INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY (agent_id, update_id)
      )
      """,
    ]

    for sql in statements {
      dbExec(sql, params: "[]")
    }

    // v4 → v4.1: seen_updates gains `completed` so the inbox is a durable
    // claim (claim-then-complete) instead of mark-before-processing. Legacy
    // rows were only ever written by fully-acked updates, so backfilling
    // them as completed (the column default) is correct and avoids a
    // reprocessing storm on upgrade.
    if tableExists("seen_updates"),
      !columnExists(table: "seen_updates", column: "completed")
    {
      logInfo("Database: adding seen_updates.completed for claim-then-complete inbox")
      dbExec(
        "ALTER TABLE seen_updates ADD COLUMN completed INTEGER NOT NULL DEFAULT 1",
        params: "[]")
    }

    // v4.1 → v4.2 (Wave 2 async drain): seen_updates gains `payload`, the
    // raw Telegram Update JSON persisted atomically WITH the claim. The
    // webhook handler responds 200 the moment the claim+payload row is
    // durable; a background worker drains it. Wave-1 rows have no payload
    // (NULL) — they were processed synchronously, so reconciliation skips
    // them and they age out via the 24h prune.
    if tableExists("seen_updates"),
      !columnExists(table: "seen_updates", column: "payload")
    {
      logInfo("Database: adding seen_updates.payload for durable async drain")
      dbExec("ALTER TABLE seen_updates ADD COLUMN payload TEXT", params: "[]")
    }
  }

  // MARK: - Schema introspection

  /// True if a table with `name` exists in the current SQLite database.
  private static func tableExists(_ name: String) -> Bool {
    let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1 LIMIT 1"
    guard let resultStr = dbQuery(sql, params: serializeParams([name])),
      let rows = extractRows(resultStr)
    else { return false }
    return !rows.isEmpty
  }

  /// True if `table` has a column named `column`. Uses `PRAGMA table_info`,
  /// which returns one row per column — column name is the second field.
  private static func columnExists(table: String, column: String) -> Bool {
    // PRAGMA can't be parameterised in SQLite; the table name is a literal
    // we control so injection isn't a concern.
    let sql = "PRAGMA table_info(\(table))"
    guard let resultStr = dbQuery(sql, params: "[]"),
      let rows = extractRows(resultStr)
    else { return false }
    for row in rows where row.count >= 2 {
      if let name = row[1] as? String, name == column { return true }
    }
    return false
  }

  /// Returns the name of the single-column primary key for `table`, or nil
  /// if the table doesn't exist or has a composite / no PK. `PRAGMA
  /// table_info` row layout is `(cid, name, type, notnull, dflt_value, pk)`
  /// where `pk` is 0 for non-key columns and 1+ for key columns (the value
  /// is the position within a composite PK). For a single-column PK,
  /// exactly one row has pk=1.
  private static func primaryKeyColumn(table: String) -> String? {
    let sql = "PRAGMA table_info(\(table))"
    guard let resultStr = dbQuery(sql, params: "[]"),
      let rows = extractRows(resultStr)
    else { return nil }
    var pkColumns: [String] = []
    for row in rows where row.count >= 6 {
      if let pk = intFromAny(row[5]), pk > 0, let name = row[1] as? String {
        pkColumns.append(name)
      }
    }
    return pkColumns.count == 1 ? pkColumns.first : nil
  }

  // MARK: - chat_sessions
  //
  // All accessors are scoped by `(agent_id, chat_id, user_id)` (schema v4).
  // For DMs the caller passes `user_id == chat_id` so behaviour is
  // identical to the v3 schema — there's only one user per DM. For groups
  // each member has its own row, so `/clear` only wipes the caller's
  // transcript and `blocked` (set by Telegram on user-side block in DMs)
  // doesn't accidentally silence everyone.

  /// Inserts or refreshes the chat row, returning the post-upsert state. Always
  /// preserves `session_salt` and `blocked`.
  @discardableResult
  static func upsertChatSession(
    agentId: String, chatId: Int64, userId: Int64
  ) -> ChatSessionRow {
    let now = Int(Date().timeIntervalSince1970)
    let upsert = """
      INSERT INTO chat_sessions
        (agent_id, chat_id, user_id, session_salt, blocked, last_msg_at, created_at)
      VALUES (?1, ?2, ?3, 0, 0, ?4, ?4)
      ON CONFLICT(agent_id, chat_id, user_id) DO UPDATE SET last_msg_at = ?4
      """
    dbExec(upsert, params: serializeParams([agentId, chatId, userId, now]))
    return getChatSession(agentId: agentId, chatId: chatId, userId: userId)
      ?? ChatSessionRow(chatId: chatId, userId: userId, sessionSalt: 0, blocked: 0)
  }

  /// Convenience overload for DM-style call sites where `user_id == chat_id`.
  /// Existing tests rely on this single-arg shape; production code paths
  /// resolve the real user_id via `effectiveUserId(chatId:fromId:)`.
  @discardableResult
  static func upsertChatSession(agentId: String, chatId: Int64) -> ChatSessionRow {
    upsertChatSession(agentId: agentId, chatId: chatId, userId: chatId)
  }

  static func getChatSession(
    agentId: String, chatId: Int64, userId: Int64
  ) -> ChatSessionRow? {
    let sql = """
      SELECT chat_id, user_id, session_salt, blocked
      FROM chat_sessions
      WHERE agent_id = ?1 AND chat_id = ?2 AND user_id = ?3
      LIMIT 1
      """
    guard let resultStr = dbQuery(sql, params: serializeParams([agentId, chatId, userId])),
      let rows = extractRows(resultStr),
      let row = rows.first, row.count >= 4
    else { return nil }
    return ChatSessionRow(
      chatId: int64FromAny(row[0]) ?? chatId,
      userId: int64FromAny(row[1]) ?? userId,
      sessionSalt: intFromAny(row[2]) ?? 0,
      blocked: intFromAny(row[3]) ?? 0
    )
  }

  /// DM convenience: looks up the row keyed by `(agent_id, chat_id, chat_id)`.
  /// Used by tests and any call site that doesn't resolve a per-user id.
  static func getChatSession(agentId: String, chatId: Int64) -> ChatSessionRow? {
    getChatSession(agentId: agentId, chatId: chatId, userId: chatId)
  }

  /// Bumps the per-user salt for one (chat, user) pair. Used by `/clear`
  /// in groups to start a fresh transcript for the calling user only.
  static func bumpSessionSalt(agentId: String, chatId: Int64, userId: Int64) {
    let sql = """
      UPDATE chat_sessions SET session_salt = session_salt + 1
      WHERE agent_id = ?1 AND chat_id = ?2 AND user_id = ?3
      """
    dbExec(sql, params: serializeParams([agentId, chatId, userId]))
  }

  /// DM convenience.
  static func bumpSessionSalt(agentId: String, chatId: Int64) {
    bumpSessionSalt(agentId: agentId, chatId: chatId, userId: chatId)
  }

  /// Bumps the salt for EVERY user inside the chat. Used by `/clearall`
  /// in groups to wipe all transcripts at once. In DMs there's only one
  /// row, so this behaves identically to `bumpSessionSalt`.
  static func bumpAllSessionSalts(agentId: String, chatId: Int64) {
    let sql = """
      UPDATE chat_sessions SET session_salt = session_salt + 1
      WHERE agent_id = ?1 AND chat_id = ?2
      """
    dbExec(sql, params: serializeParams([agentId, chatId]))
  }

  /// Marks every user row in the chat as blocked. The "bot was blocked"
  /// signal from Telegram only ever fires in DMs (there's no concept of
  /// a group-wide block at the bot level); we keep the per-user partition
  /// for forward compat but always update every row in the chat.
  static func markChatBlocked(agentId: String, chatId: Int64) {
    let sql =
      "UPDATE chat_sessions SET blocked = 1 WHERE agent_id = ?1 AND chat_id = ?2"
    dbExec(sql, params: serializeParams([agentId, chatId]))
  }

  /// True when ANY user row in the chat is blocked. We treat the chat as
  /// blocked if Telegram has signalled it for any participant — for DMs
  /// that's the only user, for groups we'd never normally hit this path
  /// (no group-wide block) but the behaviour stays defensive.
  static func isChatBlocked(agentId: String, chatId: Int64) -> Bool {
    let sql = """
      SELECT 1 FROM chat_sessions
      WHERE agent_id = ?1 AND chat_id = ?2 AND blocked = 1
      LIMIT 1
      """
    guard let resultStr = dbQuery(sql, params: serializeParams([agentId, chatId])),
      let rows = extractRows(resultStr)
    else { return false }
    return !rows.isEmpty
  }

  // MARK: - active_dispatches

  /// Column list shared by every dispatch SELECT. Centralised so the
  /// `parseDispatchRow` field offsets stay in sync with the columns we
  /// actually pull (otherwise adding a new column means hunting through
  /// every SELECT).
  private static let dispatchSelectColumns =
    "task_id, agent_id, chat_id, user_id, reply_token, session_id, "
    + "expires_at, has_replied, incoming_message_id"

  static func insertActiveDispatch(
    taskId: String, agentId: String, chatId: Int64, userId: Int64 = 0,
    replyToken: String, sessionId: String, expiresAt: Int,
    incomingMessageId: Int64 = 0
  ) {
    // started_at is an ordering key (not a wall-clock); milliseconds give
    // rapid-fire turns and unit tests strict ordering. expires_at stays
    // in seconds — they're never compared.
    let nowMillis = Int(Date().timeIntervalSince1970 * 1000)
    let sql = """
      INSERT INTO active_dispatches
        (task_id, agent_id, chat_id, user_id, reply_token, session_id,
         started_at, expires_at, has_replied, incoming_message_id)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 0, ?9)
      """
    dbExec(
      sql,
      params: serializeParams(
        [
          taskId, agentId, chatId, userId, replyToken, sessionId,
          nowMillis, expiresAt, incomingMessageId,
        ]))
  }

  /// Returns the most recently dispatched row for `(agentId, chatId)` or nil
  /// if no dispatches are in flight. Multiple rows can coexist for the same
  /// chat (each turn pre-inserts before `dispatch`); only the latest matters
  /// for the soft-interrupt branch in `handleWebhook`.
  static func activeDispatch(agentId: String, forChat chatId: Int64) -> ActiveDispatchRow? {
    let sql = """
      SELECT \(dispatchSelectColumns)
      FROM active_dispatches
      WHERE agent_id = ?1 AND chat_id = ?2
      ORDER BY started_at DESC
      LIMIT 1
      """
    guard let resultStr = dbQuery(sql, params: serializeParams([agentId, chatId])) else {
      return nil
    }
    return parseDispatchRow(resultStr)
  }

  /// Returns the most recently dispatched in-flight row for `agentId` across
  /// all chats. Used by the artifact auto-forward hook because the host's
  /// `invoke(type: "artifact", ...)` payload doesn't carry chat context — the
  /// only sane heuristic is "the chat the agent is currently working on,"
  /// which translates to the latest pre-inserted dispatch row for the agent.
  static func latestActiveDispatch(agentId: String) -> ActiveDispatchRow? {
    let sql = """
      SELECT \(dispatchSelectColumns)
      FROM active_dispatches
      WHERE agent_id = ?1
      ORDER BY started_at DESC
      LIMIT 1
      """
    guard let resultStr = dbQuery(sql, params: serializeParams([agentId])) else {
      return nil
    }
    return parseDispatchRow(resultStr)
  }

  /// Returns the most recently dispatched in-flight row across ALL agents,
  /// constrained to agents that have rows in flight. With exactly one
  /// in-flight agent the result is unambiguous (single-agent install or
  /// only one agent currently working). With multiple in-flight agents
  /// the routing is ambiguous so the artifact fallback in `Plugin.swift`
  /// declines to guess; callers must check `inFlightAgentCount()` first.
  static func latestActiveDispatchAcrossAgents() -> ActiveDispatchRow? {
    let sql = """
      SELECT \(dispatchSelectColumns)
      FROM active_dispatches
      ORDER BY started_at DESC
      LIMIT 1
      """
    guard let resultStr = dbQuery(sql, params: "[]") else {
      return nil
    }
    return parseDispatchRow(resultStr)
  }

  /// Returns the count of distinct agents that have at least one in-flight
  /// dispatch row. Used by `routeArtifactWithoutFrame` to decide whether
  /// the cross-agent fallback is unambiguous (1) or ambiguous (>1).
  static func inFlightAgentCount() -> Int {
    let sql =
      "SELECT COUNT(DISTINCT agent_id) FROM active_dispatches"
    guard let resultStr = dbQuery(sql, params: "[]"),
      let rows = extractRows(resultStr),
      let row = rows.first, !row.isEmpty
    else { return 0 }
    return intFromAny(row[0]) ?? 0
  }

  /// Like `activeDispatch`, but skips a specific `reply_token` AND scopes
  /// to a specific user. Used by the soft-interrupt branch in
  /// `handleWebhook` AFTER it has pre-inserted the current turn's row —
  /// we want the *prior* in-flight task FOR THE SAME USER to interrupt,
  /// not ourselves and not someone else's parallel turn in the same group.
  static func priorActiveDispatch(
    agentId: String, forChat chatId: Int64, userId: Int64,
    excluding replyToken: String
  ) -> ActiveDispatchRow? {
    let sql = """
      SELECT \(dispatchSelectColumns)
      FROM active_dispatches
      WHERE agent_id = ?1 AND chat_id = ?2 AND user_id = ?3 AND reply_token != ?4
      ORDER BY started_at DESC
      LIMIT 1
      """
    guard
      let resultStr = dbQuery(
        sql, params: serializeParams([agentId, chatId, userId, replyToken]))
    else { return nil }
    return parseDispatchRow(resultStr)
  }

  /// DM-style overload retained for tests that don't care about user
  /// scoping. In production the per-user variant is what `handleWebhook`
  /// invokes — group chats need to interrupt only the calling user's
  /// prior task, not random other participants'.
  static func priorActiveDispatch(
    agentId: String, forChat chatId: Int64, excluding replyToken: String
  ) -> ActiveDispatchRow? {
    let sql = """
      SELECT \(dispatchSelectColumns)
      FROM active_dispatches
      WHERE agent_id = ?1 AND chat_id = ?2 AND reply_token != ?3
      ORDER BY started_at DESC
      LIMIT 1
      """
    guard
      let resultStr = dbQuery(
        sql, params: serializeParams([agentId, chatId, replyToken]))
    else { return nil }
    return parseDispatchRow(resultStr)
  }

  /// Returns every in-flight dispatch row for `(agentId, chatId)`. Used by
  /// `/reset` and `/clearall` so we can hard-cancel every concurrent turn
  /// for a chat in one pass, not just the latest one.
  static func allActiveDispatches(agentId: String, forChat chatId: Int64)
    -> [ActiveDispatchRow]
  {
    let sql = """
      SELECT \(dispatchSelectColumns)
      FROM active_dispatches
      WHERE agent_id = ?1 AND chat_id = ?2
      ORDER BY started_at DESC
      """
    guard let resultStr = dbQuery(sql, params: serializeParams([agentId, chatId]))
    else { return [] }
    return parseDispatchRows(resultStr)
  }

  /// Per-user variant: every in-flight row for one user inside one chat.
  /// Used by `/clear` (per-user) so we cancel only the caller's tasks
  /// without disturbing other group members.
  static func allActiveDispatches(
    agentId: String, forChat chatId: Int64, userId: Int64
  ) -> [ActiveDispatchRow] {
    let sql = """
      SELECT \(dispatchSelectColumns)
      FROM active_dispatches
      WHERE agent_id = ?1 AND chat_id = ?2 AND user_id = ?3
      ORDER BY started_at DESC
      """
    guard
      let resultStr = dbQuery(sql, params: serializeParams([agentId, chatId, userId]))
    else { return [] }
    return parseDispatchRows(resultStr)
  }

  /// Looks up a dispatch by reply_token. reply_token is globally unique so
  /// no agent_id is required here — callers can read `row.agentId` from the
  /// returned row to verify the binding belongs to the agent that owns the
  /// current callback frame.
  static func lookupBinding(token: String) -> ActiveDispatchRow? {
    let sql = """
      SELECT \(dispatchSelectColumns)
      FROM active_dispatches
      WHERE reply_token = ?1
      LIMIT 1
      """
    guard let resultStr = dbQuery(sql, params: serializeParams([token])) else { return nil }
    return parseDispatchRow(resultStr)
  }

  static func lookupBindingByTask(taskId: String) -> ActiveDispatchRow? {
    let sql = """
      SELECT \(dispatchSelectColumns)
      FROM active_dispatches
      WHERE task_id = ?1
      LIMIT 1
      """
    guard let resultStr = dbQuery(sql, params: serializeParams([taskId])) else { return nil }
    return parseDispatchRow(resultStr)
  }

  static func deleteActiveDispatch(taskId: String) {
    let sql = "DELETE FROM active_dispatches WHERE task_id = ?1"
    dbExec(sql, params: serializeParams([taskId]))
  }

  /// Removes a row by reply_token. Used by the webhook handler to unwind
  /// a pre-inserted binding when the subsequent `dispatch` call failed
  /// (no real task_id to delete by yet).
  static func deleteActiveDispatch(replyToken: String) {
    let sql = "DELETE FROM active_dispatches WHERE reply_token = ?1"
    dbExec(sql, params: serializeParams([replyToken]))
  }

  /// Patches the placeholder task_id on a pre-inserted row to the real
  /// one returned by `dispatch`.
  static func updateTaskId(replyToken: String, newTaskId: String) {
    let sql = "UPDATE active_dispatches SET task_id = ?1 WHERE reply_token = ?2"
    dbExec(sql, params: serializeParams([newTaskId, replyToken]))
  }

  static func markReplied(taskId: String) {
    let sql = "UPDATE active_dispatches SET has_replied = 1 WHERE task_id = ?1"
    dbExec(sql, params: serializeParams([taskId]))
  }

  /// Pushes `expires_at` forward to `newExpiresAt` IF the new value is
  /// later. Used by the activity-keepalive path: every OUTPUT/ACTIVITY
  /// event from a long-running agent extends the TTL so a 12-minute
  /// research turn doesn't lose its reply binding mid-run. Idempotent
  /// and safe to call from any thread.
  static func bumpExpiry(taskId: String, newExpiresAt: Int) {
    let sql = """
      UPDATE active_dispatches
      SET expires_at = ?1
      WHERE task_id = ?2 AND expires_at < ?1
      """
    dbExec(sql, params: serializeParams([newExpiresAt, taskId]))
  }

  static func hasReplied(taskId: String) -> Bool {
    let sql = "SELECT has_replied FROM active_dispatches WHERE task_id = ?1 LIMIT 1"
    guard let resultStr = dbQuery(sql, params: serializeParams([taskId])),
      let rows = extractRows(resultStr),
      let row = rows.first, !row.isEmpty
    else { return false }
    return (intFromAny(row[0]) ?? 0) == 1
  }

  /// Removes bindings whose expires_at has passed. Run periodically as a
  /// safety net for cases where the host crashed before delivering the
  /// terminal task event.
  static func sweepExpiredDispatches() {
    let now = Int(Date().timeIntervalSince1970)
    dbExec(
      "DELETE FROM active_dispatches WHERE expires_at < ?1",
      params: serializeParams([now])
    )
  }

  // MARK: - seen_updates (claim-then-complete inbox)

  enum UpdateClaim {
    /// This delivery is ours to process (fresh id, or takeover of a stale
    /// claim left behind by a crashed/hung run).
    case claimed
    /// A previous delivery was fully processed; ack with 200 and skip.
    case alreadyCompleted
    /// Another delivery of the same update is still inside its lease (or
    /// awaiting reconciliation). Since Wave 2 the payload is durably
    /// stored with the claim, so retries are acked 200 without enqueueing.
    case inFlight
    /// The claim could not be durably recorded (host DB unavailable).
    /// Durable-first: the webhook must answer 5xx so the provider's retry
    /// remains the recovery path for the enqueue step itself.
    case storeUnavailable
  }

  /// An incomplete claim older than this is treated as abandoned (the
  /// process crashed or hung mid-processing) and may be taken over by a
  /// Telegram retry. Comfortably above the bounded media-download window.
  static let updateClaimLeaseSeconds = 120

  /// Atomically claims `update_id` for processing: a single INSERT with an
  /// affected-row check. Fresh ids insert an incomplete row; stale
  /// incomplete rows (lease expired) are re-claimed; completed rows and
  /// in-lease claims leave 0 rows affected.
  ///
  /// `payload` (Wave 2) is the raw Telegram Update JSON, persisted in the
  /// SAME statement as the claim so "claimed" always implies "durably
  /// enqueued" — there is no window where a crash loses the update after
  /// the 200 went out. Pass nil to preserve whatever payload the row
  /// already carries (lease takeover keeps the original delivery's body).
  static func claimUpdate(
    agentId: String, updateId: Int, payload: String? = nil
  ) -> UpdateClaim {
    let now = Int(Date().timeIntervalSince1970)
    let sql = """
      INSERT INTO seen_updates (agent_id, update_id, seen_at, completed, payload)
      VALUES (?1, ?2, ?3, 0, ?4)
      ON CONFLICT(agent_id, update_id) DO UPDATE SET
          seen_at = ?3,
          payload = COALESCE(?4, seen_updates.payload)
        WHERE seen_updates.completed = 0
          AND seen_updates.seen_at < (?3 - \(updateClaimLeaseSeconds))
      """
    let params = serializeParams([agentId, updateId, now, payload ?? NSNull()])
    if dbExec(sql, params: params) > 0 {
      return .claimed
    }
    let probe =
      "SELECT completed FROM seen_updates WHERE agent_id = ?1 AND update_id = ?2 LIMIT 1"
    guard let resultStr = dbQuery(probe, params: serializeParams([agentId, updateId])),
      let rows = extractRows(resultStr)
    else { return .storeUnavailable }
    guard let row = rows.first, !row.isEmpty else {
      // INSERT affected nothing AND no row exists — the write itself
      // failed (DB unavailable / error), not a claim conflict.
      return .storeUnavailable
    }
    return (intFromAny(row[0]) ?? 0) == 1 ? .alreadyCompleted : .inFlight
  }

  /// One resumable inbox row: an incomplete claim whose lease has expired
  /// and whose raw payload is still available for reprocessing.
  struct StaleClaimRow {
    let updateId: Int
    let payload: String
  }

  /// Incomplete claims older than the lease that still carry a payload —
  /// i.e. updates a crashed/failed worker left behind. Ordered oldest
  /// first so reconciliation drains in arrival order. Rows without a
  /// payload (pre-Wave-2, or synthetic test claims) are skipped: there is
  /// nothing to reprocess, and they age out via the 24h prune.
  static func staleIncompleteUpdates(agentId: String, limit: Int = 16) -> [StaleClaimRow] {
    let cutoff = Int(Date().timeIntervalSince1970) - updateClaimLeaseSeconds
    let sql = """
      SELECT update_id, payload FROM seen_updates
      WHERE agent_id = ?1 AND completed = 0 AND payload IS NOT NULL
        AND seen_at < ?2
      ORDER BY seen_at ASC
      LIMIT ?3
      """
    guard let resultStr = dbQuery(sql, params: serializeParams([agentId, cutoff, limit])),
      let rows = extractRows(resultStr)
    else { return [] }
    return rows.compactMap { row -> StaleClaimRow? in
      guard row.count >= 2, let updateId = intFromAny(row[0]),
        let payload = row[1] as? String
      else { return nil }
      return StaleClaimRow(updateId: updateId, payload: payload)
    }
  }

  /// Marks a claimed update as fully processed. Only after this call do
  /// duplicate Telegram deliveries get skipped.
  static func completeUpdate(agentId: String, updateId: Int) {
    dbExec(
      "UPDATE seen_updates SET completed = 1 WHERE agent_id = ?1 AND update_id = ?2",
      params: serializeParams([agentId, updateId]))
  }

  // NOTE: Wave 1's `releaseUpdate` (DELETE on transient failure so Telegram's
  // retry re-claims immediately) was removed in Wave 2: the 200 already went
  // out at enqueue time, so deleting the row would orphan the update if
  // Telegram never redelivers. Failed claims now stay incomplete and are
  // reprocessed from the stored payload once the lease expires.

  static func isUpdateAlreadySeen(agentId: String, updateId: Int) -> Bool {
    let sql =
      "SELECT 1 FROM seen_updates WHERE agent_id = ?1 AND update_id = ?2 LIMIT 1"
    guard let resultStr = dbQuery(sql, params: serializeParams([agentId, updateId])),
      let rows = extractRows(resultStr)
    else { return false }
    return !rows.isEmpty
  }

  /// Records an update as fully processed in one step. Convenience for
  /// deterministic-drop paths and tests; equivalent to claim + complete.
  static func markUpdateSeen(agentId: String, updateId: Int) {
    let now = Int(Date().timeIntervalSince1970)
    let sql = """
      INSERT INTO seen_updates (agent_id, update_id, seen_at, completed)
      VALUES (?1, ?2, ?3, 1)
      ON CONFLICT(agent_id, update_id) DO UPDATE SET completed = 1
      """
    dbExec(sql, params: serializeParams([agentId, updateId, now]))
  }

  /// Drops idempotency rows older than 24h. Cheap; called inline from the
  /// webhook hot path after marking a new update.
  static func pruneOldSeenUpdates() {
    let cutoff = Int(Date().timeIntervalSince1970) - 86_400
    dbExec(
      "DELETE FROM seen_updates WHERE seen_at < ?1",
      params: serializeParams([cutoff])
    )
  }

  // MARK: - Row helpers

  /// Number of columns the shared `dispatchSelectColumns` SELECT pulls.
  /// Bump this when you add a column there; the per-row offsets in
  /// `dispatchRow(from:)` must move in lockstep.
  private static let dispatchColumnCount = 9

  private static func parseDispatchRow(_ resultStr: String) -> ActiveDispatchRow? {
    guard let rows = extractRows(resultStr),
      let row = rows.first, row.count >= dispatchColumnCount
    else { return nil }
    return dispatchRow(from: row)
  }

  /// Multi-row variant for callers that want every match (e.g. `/reset`
  /// cancels every in-flight turn for a chat). Skips malformed rows but
  /// otherwise preserves the SELECT order.
  private static func parseDispatchRows(_ resultStr: String) -> [ActiveDispatchRow] {
    guard let rows = extractRows(resultStr) else { return [] }
    return rows.compactMap { row -> ActiveDispatchRow? in
      guard row.count >= dispatchColumnCount else { return nil }
      return dispatchRow(from: row)
    }
  }

  private static func dispatchRow(from row: [Any]) -> ActiveDispatchRow {
    ActiveDispatchRow(
      taskId: "\(row[0])",
      agentId: "\(row[1])",
      chatId: int64FromAny(row[2]) ?? 0,
      userId: int64FromAny(row[3]) ?? 0,
      replyToken: "\(row[4])",
      sessionId: "\(row[5])",
      expiresAt: intFromAny(row[6]) ?? 0,
      hasReplied: intFromAny(row[7]) ?? 0,
      incomingMessageId: int64FromAny(row[8]) ?? 0
    )
  }

  private static func intFromAny(_ value: Any) -> Int? {
    if let i = value as? Int { return i }
    if let i = value as? Int64 { return Int(i) }
    if let d = value as? Double { return Int(d) }
    if let s = value as? String { return Int(s) }
    return nil
  }

  private static func int64FromAny(_ value: Any) -> Int64? {
    if let i = value as? Int64 { return i }
    if let i = value as? Int { return Int64(i) }
    if let d = value as? Double { return Int64(d) }
    if let s = value as? String { return Int64(s) }
    return nil
  }

  // MARK: - Generic Helpers

  /// Extracts row arrays from a db_query result string.
  /// Handles both `{"rows": [[...]]}` (host format) and bare `[[...]]`.
  static func extractRows(_ resultStr: String) -> [[Any]]? {
    guard let data = resultStr.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data)
    else {
      logDebug(
        "extractRows: failed to parse JSON (\(resultStr.count) chars): \(String(resultStr.prefix(200)))"
      )
      return nil
    }

    if let dict = json as? [String: Any],
      let rows = dict["rows"] as? [[Any]]
    {
      return rows
    }

    if let rows = json as? [[Any]] {
      return rows
    }

    logDebug("extractRows: JSON parsed but no rows found in result")
    return nil
  }

  /// Executes a statement and returns the number of affected rows (the
  /// host replies `{"changes":N,"last_insert_rowid":N}`). 0 on any failure.
  @discardableResult
  static func dbExec(_ sql: String, params: String) -> Int {
    guard let exec = hostAPI?.pointee.db_exec else {
      logError("db_exec not available")
      return 0
    }
    let result = sql.withCString { sqlPtr in
      params.withCString { paramsPtr in
        exec(sqlPtr, paramsPtr)
      }
    }
    guard let result else { return 0 }
    let str = String(cString: result)
    if str.contains("\"error\"") {
      logWarn("DB exec error: \(str)")
      return 0
    }
    guard let data = str.data(using: .utf8),
      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return 0 }
    return intFromAny(dict["changes"] ?? 0) ?? 0
  }

  static func dbQuery(_ sql: String, params: String) -> String? {
    guard let query = hostAPI?.pointee.db_query else {
      logDebug("dbQuery: db_query not available")
      return nil
    }
    let result: String? = sql.withCString { sqlPtr in
      params.withCString { paramsPtr in
        guard let resultPtr = query(sqlPtr, paramsPtr) else { return nil }
        return String(cString: resultPtr)
      }
    }
    if result == nil {
      logDebug("dbQuery: query returned nil for sql=\(String(sql.prefix(100)))")
    }
    return result
  }

  /// Serializes an array of mixed values to a JSON array string for SQLite params.
  static func serializeParams(_ values: [Any]) -> String {
    let normalized = values.map { value -> Any in
      if let i64 = value as? Int64 { return NSNumber(value: i64) }
      return value
    }
    guard let data = try? JSONSerialization.data(withJSONObject: normalized),
      let str = String(data: data, encoding: .utf8)
    else {
      logWarn("serializeParams: failed to serialize \(values.count) values, returning empty array")
      return "[]"
    }
    return str
  }
}
