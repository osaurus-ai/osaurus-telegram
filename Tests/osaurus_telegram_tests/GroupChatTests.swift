import XCTest

@testable import osaurus_telegram

/// Pin the group-chat semantics introduced in Phase 1: the bot ignores
/// chatter unless it's @-mentioned, replied-to, or addressed via a
/// `/cmd@<bot>` slash command; per-user sessions inside a group don't
/// leak each other's transcripts; `reply_to_message_id` round-trips
/// through the prompt header so the agent can thread its answer; and
/// the per-user `/clear` vs group-wide `/clearall` scopes do what they
/// say on the tin.
final class GroupChatTests: XCTestCase {

  private var state: AgentState!
  private let agentId = defaultTestAgentId
  private let secret = "super-secret"
  private let botUsername = "MyTestBot"
  private let botId: Int64 = 42_000

  override func setUp() {
    super.setUp()
    TestHost.install()
    DatabaseManager.initSchema()
    state = AgentState(agentId: agentId)
    state.botToken = "123:fake"
    state.webhookSecret = secret
    state.botUsername = botUsername
    state.botId = botId
  }

  override func tearDown() {
    state = nil
    TestHost.uninstall()
    super.tearDown()
  }

  // MARK: - shouldRespondInChat gate

  /// In a private chat the gate is a no-op — every message passes.
  func testPrivateChatAlwaysAllowed() {
    let msg = makeMessage(
      chatId: 555, chatType: "private", text: "hi", fromId: 999)
    XCTAssertTrue(
      shouldRespondInChat(message: msg, botId: botId, botUsername: botUsername),
      "DMs must always pass the mention gate")
  }

  /// A bare text in a group with no @mention / reply / command target is
  /// silently ignored.
  func testGroupChatRejectsBareTextWithoutMention() {
    let msg = makeMessage(
      chatId: -100_1, chatType: "supergroup", text: "morning everyone",
      fromId: 999)
    XCTAssertFalse(
      shouldRespondInChat(message: msg, botId: botId, botUsername: botUsername))
  }

  /// `@MyTestBot` anywhere in the text triggers a response. We exercise
  /// the entity-driven path the production code uses (offset + length
  /// over UTF-16 code units, case-insensitive).
  func testGroupChatAcceptsAtMention() {
    let body = "hey @MyTestBot what's up?"
    let mentionStart = body.range(of: "@MyTestBot")!
    let offset = body.utf16.distance(
      from: body.utf16.startIndex, to: mentionStart.lowerBound.samePosition(in: body.utf16)!)
    let length = body.utf16.distance(
      from: mentionStart.lowerBound.samePosition(in: body.utf16)!,
      to: mentionStart.upperBound.samePosition(in: body.utf16)!)
    let msg = makeMessage(
      chatId: -100_2, chatType: "group", text: body, fromId: 999,
      entities: [
        TGUpdate.MessageEntity(
          type: "mention", offset: offset, length: length, user: nil)
      ])
    XCTAssertTrue(
      shouldRespondInChat(message: msg, botId: botId, botUsername: botUsername))
  }

  /// `text_mention` entities point at a `user.id` directly — the
  /// canonical way Telegram handles bots without unique usernames.
  func testGroupChatAcceptsTextMentionByBotId() {
    let msg = makeMessage(
      chatId: -100_3, chatType: "group", text: "look here", fromId: 999,
      entities: [
        TGUpdate.MessageEntity(
          type: "text_mention", offset: 5, length: 4,
          user: TGUpdate.From(
            id: botId, username: nil, first_name: nil, is_bot: nil))
      ])
    XCTAssertTrue(
      shouldRespondInChat(message: msg, botId: botId, botUsername: botUsername))
  }

  /// Replying to one of the bot's prior messages routes through us.
  func testGroupChatAcceptsReplyToBot() {
    let msg = makeMessage(
      chatId: -100_4, chatType: "group", text: "ok thanks", fromId: 999,
      replyToBotId: botId)
    XCTAssertTrue(
      shouldRespondInChat(message: msg, botId: botId, botUsername: botUsername))
  }

  /// Replying to OTHER users in the group is not addressed to us.
  func testGroupChatRejectsReplyToOtherUser() {
    let msg = makeMessage(
      chatId: -100_5, chatType: "group", text: "agree", fromId: 999,
      replyToBotId: 12_345 /* not us */)
    XCTAssertFalse(
      shouldRespondInChat(message: msg, botId: botId, botUsername: botUsername))
  }

  /// Telegram appends `@<botname>` to slash commands in groups; the
  /// gate accepts those even without a `mention` entity.
  func testGroupChatAcceptsSlashCommandWithBotSuffix() {
    let msg = makeMessage(
      chatId: -100_6, chatType: "group", text: "/help@MyTestBot",
      fromId: 999)
    XCTAssertTrue(
      shouldRespondInChat(message: msg, botId: botId, botUsername: botUsername))
  }

  // MARK: - End-to-end webhook flow in a group

  /// A group message with no mention / reply must 200-OK silently and
  /// NEVER hit the dispatcher. The agent loop should not be paying
  /// attention to room chatter.
  func testGroupChatBareTextDoesNotDispatch() {
    let req = webhookRequest(
      secret: secret,
      update: groupTextUpdate(
        updateId: 1, chatId: -1_001, text: "what's everyone up to",
        fromId: 999))
    let response = parseRouteResponse(route(req))
    XCTAssertEqual(response.status, 200)
    XCTAssertTrue(
      TestHostGlobals.dispatchCalls.isEmpty,
      "group chatter without addressing the bot must not dispatch")
  }

  /// A `text_mention` entity targeting our bot id triggers a normal
  /// dispatch — same prompt-header invariants as a DM, plus the
  /// in-group threading hint.
  func testGroupChatTextMentionTriggersDispatch() throws {
    let body = "yo bot, count to ten"
    var update = groupTextUpdate(
      updateId: 2, chatId: -1_002, text: body, fromId: 999)
    var msg = update["message"] as! [String: Any]
    msg["entities"] = [
      [
        "type": "text_mention",
        "offset": 3, "length": 3,
        "user": ["id": botId, "username": botUsername],
      ] as [String: Any]
    ]
    update["message"] = msg

    _ = route(webhookRequest(secret: secret, update: update))
    XCTAssertEqual(TestHostGlobals.dispatchCalls.count, 1)
    let prompt = try XCTUnwrap(
      TestHostGlobals.dispatchCalls[0]["prompt"] as? String)
    XCTAssertTrue(
      prompt.contains("in_group"),
      "prompt header must announce the in_group context to the agent")
    XCTAssertTrue(
      prompt.contains("reply_to_message_id="),
      "prompt header must surface the user's message_id for threading")
  }

  // MARK: - Per-user sessions inside a group

  /// Two members of the same group must dispatch on independent
  /// `external_session_key` values. Mixing them would hand each user
  /// the other's history.
  func testTwoUsersInOneGroupGetDistinctSessions() throws {
    let chatId: Int64 = -2_001

    // Both messages address the bot via reply-to so the gate passes
    // without per-user entity offsets.
    func turn(updateId: Int, fromId: Int64, name: String) -> [String: Any] {
      var update = groupTextUpdate(
        updateId: updateId, chatId: chatId, text: "hi from \(name)",
        fromId: fromId, username: name)
      var msg = update["message"] as! [String: Any]
      msg["reply_to_message"] = [
        "message_id": 1,
        "from": ["id": botId, "username": botUsername],
      ]
      update["message"] = msg
      return update
    }

    _ = route(
      webhookRequest(
        secret: secret,
        update: turn(
          updateId: 10, fromId: 901, name: "alice")))
    TestHostGlobals.nextDispatchResponse =
      #"{"id":"task-bob","status":"running"}"#
    _ = route(
      webhookRequest(
        secret: secret,
        update: turn(
          updateId: 11, fromId: 902, name: "bob")))

    XCTAssertEqual(TestHostGlobals.dispatchCalls.count, 2)
    let aliceKey = TestHostGlobals.dispatchCalls[0]["external_session_key"] as? String
    let bobKey = TestHostGlobals.dispatchCalls[1]["external_session_key"] as? String
    XCTAssertNotEqual(
      aliceKey, bobKey,
      "two users in one group must NOT share an external_session_key")

    // Each user has their own chat_sessions row in the DB.
    let aliceRow = try XCTUnwrap(
      DatabaseManager.getChatSession(agentId: agentId, chatId: chatId, userId: 901))
    let bobRow = try XCTUnwrap(
      DatabaseManager.getChatSession(agentId: agentId, chatId: chatId, userId: 902))
    XCTAssertEqual(aliceRow.userId, 901)
    XCTAssertEqual(bobRow.userId, 902)
  }

  /// `/clear` in a group bumps only the caller's per-user salt; other
  /// participants keep their transcripts.
  func testClearScopesToCallerInGroup() throws {
    let chatId: Int64 = -2_002

    // Seed independent rows for two users.
    _ = DatabaseManager.upsertChatSession(
      agentId: agentId, chatId: chatId, userId: 801)
    _ = DatabaseManager.upsertChatSession(
      agentId: agentId, chatId: chatId, userId: 802)

    // /clear from user 801 — slash commands bypass the mention gate.
    let req = webhookRequest(
      secret: secret,
      update: groupTextUpdate(
        updateId: 30, chatId: chatId, text: "/clear", fromId: 801,
        username: "alice"))
    _ = route(req)

    let aliceAfter = try XCTUnwrap(
      DatabaseManager.getChatSession(
        agentId: agentId, chatId: chatId, userId: 801))
    let bobAfter = try XCTUnwrap(
      DatabaseManager.getChatSession(
        agentId: agentId, chatId: chatId, userId: 802))
    XCTAssertEqual(aliceAfter.sessionSalt, 1, "/clear must bump the caller's salt")
    XCTAssertEqual(
      bobAfter.sessionSalt, 0,
      "/clear must NOT touch other participants' salts")
  }

  /// `/clearall` is the explicit group-wide reset; both salts must
  /// advance and every in-flight dispatch must be cancelled.
  func testClearAllResetsEveryUserInGroup() throws {
    let chatId: Int64 = -2_003

    _ = DatabaseManager.upsertChatSession(
      agentId: agentId, chatId: chatId, userId: 901)
    _ = DatabaseManager.upsertChatSession(
      agentId: agentId, chatId: chatId, userId: 902)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-alice", agentId: agentId, chatId: chatId, userId: 901,
      replyToken: "TOKAL", sessionId: "s1",
      expiresAt: Int(Date().timeIntervalSince1970) + 600)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-bob", agentId: agentId, chatId: chatId, userId: 902,
      replyToken: "TOKBO", sessionId: "s2",
      expiresAt: Int(Date().timeIntervalSince1970) + 600)

    _ = route(
      webhookRequest(
        secret: secret,
        update: groupTextUpdate(
          updateId: 40, chatId: chatId, text: "/clearall",
          fromId: 901, username: "alice")))

    XCTAssertEqual(
      DatabaseManager.getChatSession(
        agentId: agentId, chatId: chatId, userId: 901)?.sessionSalt, 1)
    XCTAssertEqual(
      DatabaseManager.getChatSession(
        agentId: agentId, chatId: chatId, userId: 902)?.sessionSalt, 1)
    XCTAssertEqual(
      Set(TestHostGlobals.cancelCalls), Set(["task-alice", "task-bob"]),
      "/clearall must cancel every in-flight dispatch in the chat")
  }

  // MARK: - parseResetCommand scope plumbing

  func testParseResetCommandRecognisesScopes() {
    XCTAssertEqual(parseResetCommand("/clear"), .currentUser)
    XCTAssertEqual(parseResetCommand("/clear@MyTestBot"), .currentUser)
    XCTAssertEqual(parseResetCommand("/CLEARALL"), .allUsers)
    XCTAssertEqual(parseResetCommand("/clearall@MyTestBot"), .allUsers)
    XCTAssertNil(parseResetCommand("/cleared"))
    XCTAssertNil(parseResetCommand("/clear now"))
  }

  // MARK: - Helpers

  private func makeMessage(
    chatId: Int64, chatType: String, text: String, fromId: Int64,
    entities: [TGUpdate.MessageEntity]? = nil,
    replyToBotId: Int64? = nil
  ) -> TGUpdate.Message {
    let chat = TGUpdate.Chat(id: chatId, type: chatType, title: nil)
    let from = TGUpdate.From(
      id: fromId, username: "alice", first_name: "Alice", is_bot: false)
    let reply = replyToBotId.map { id in
      TGUpdate.ReplyToMessage(
        message_id: 1,
        from: TGUpdate.From(id: id, username: nil, first_name: nil, is_bot: nil))
    }
    return TGUpdate.Message(
      message_id: 1, date: nil, chat: chat, from: from,
      text: text, caption: nil, entities: entities, caption_entities: nil,
      reply_to_message: reply,
      photo: nil, document: nil, voice: nil, audio: nil,
      video: nil, animation: nil)
  }

  /// Group-shaped variant of the shared `textUpdate` helper. Forces a
  /// supergroup chat type so the production `shouldRespondInChat` gate
  /// fires its mention/reply check.
  private func groupTextUpdate(
    updateId: Int, chatId: Int64, text: String,
    fromId: Int64, username: String = "alice"
  ) -> [String: Any] {
    textUpdate(
      updateId: updateId, chatId: chatId, text: text,
      fromId: fromId, username: username,
      chatType: "supergroup", chatTitle: "Test Group")
  }

  private func route(_ requestJSON: String) -> String {
    handleRoute(state: state, agentId: agentId, requestJSON: requestJSON)
  }
}
