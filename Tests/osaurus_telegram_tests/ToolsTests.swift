import XCTest

@testable import osaurus_telegram

final class ToolsTests: XCTestCase {

  private var state: AgentState!
  private let agentId = defaultTestAgentId

  override func setUp() {
    super.setUp()
    TestHost.install()
    DatabaseManager.initSchema()
    state = AgentState(agentId: agentId)
    state.botToken = "123:fake"
  }

  override func tearDown() {
    state = nil
    TestHost.uninstall()
    super.tearDown()
  }

  // MARK: helpers

  private func parseEnvelope(_ s: String) -> [String: Any] {
    let data = s.data(using: .utf8) ?? Data()
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }

  /// Inserts an active dispatch row for a fresh chat and returns the token.
  @discardableResult
  private func makeBinding(
    chatId: Int64 = 100,
    taskId: String = "task-1",
    expiresInSeconds: Int = 600,
    incomingMessageId: Int64 = 0
  ) -> String {
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: chatId)
    let token = "TOKABC12"
    DatabaseManager.insertActiveDispatch(
      taskId: taskId, agentId: agentId, chatId: chatId, replyToken: token,
      sessionId: "session-1",
      expiresAt: Int(Date().timeIntervalSince1970) + expiresInSeconds,
      incomingMessageId: incomingMessageId)
    return token
  }

  private func setHTTPSuccess(messageId: Int = 1) {
    TestHostGlobals.nextHttpResponse =
      #"{"status":200,"body":"{\"ok\":true,\"result\":{\"message_id\":\#(messageId)}}"}"#
  }

  private func setHTTPBotWasBlocked() {
    TestHostGlobals.nextHttpResponse =
      #"{"status":403,"body":"{\"ok\":false,\"description\":\"Forbidden: bot was blocked by the user\"}"}"#
  }

  private func setHTTPGenericError() {
    TestHostGlobals.nextHttpResponse =
      #"{"status":400,"body":"{\"ok\":false,\"description\":\"Bad Request: chat not found\"}"}"#
  }

  // MARK: invalid args

  func testReplyRejectsInvalidJSON() {
    let env = parseEnvelope(handleReply(state: state, payload: "not-json"))
    XCTAssertEqual(env["ok"] as? Bool, false)
    XCTAssertEqual(env["kind"] as? String, "invalid_args")
    // Deterministic failure: resending the identical bad payload can
    // never succeed, so invalid_args must not invite a retry.
    XCTAssertEqual(env["retryable"] as? Bool, false)
  }

  func testReplyTypingRejectsMissingToken() {
    let env = parseEnvelope(handleReplyTyping(state: state, payload: "{}"))
    XCTAssertEqual(env["kind"] as? String, "invalid_args")
  }

  func testReplyPhotoRejectsMissingURL() {
    let env = parseEnvelope(
      handleReplyPhoto(state: state, payload: #"{"reply_token":"TOK"}"#))
    XCTAssertEqual(env["kind"] as? String, "invalid_args")
  }

  // MARK: stale token

  func testReplyStaleTokenWhenUnknown() {
    let env = parseEnvelope(
      handleReply(
        state: state,
        payload: #"{"reply_token":"NOPE","text":"hi"}"#))
    XCTAssertEqual(env["kind"] as? String, "not_found")
    XCTAssertEqual(env["retryable"] as? Bool, false)
  }

  func testReplyStaleTokenWhenExpired() {
    let token = makeBinding(expiresInSeconds: -10)
    let env = parseEnvelope(
      handleReply(
        state: state,
        payload: #"{"reply_token":"\#(token)","text":"hi"}"#))
    XCTAssertEqual(env["kind"] as? String, "not_found")
    XCTAssertTrue(TestHostGlobals.httpCalls.isEmpty, "no HTTP call on stale token")
  }

  // MARK: chat blocked (already flagged)

  func testReplyChatBlockedWhenChatPreviouslyBlocked() {
    let token = makeBinding(chatId: 200)
    DatabaseManager.markChatBlocked(agentId: agentId, chatId: 200)
    let env = parseEnvelope(
      handleReply(
        state: state,
        payload: #"{"reply_token":"\#(token)","text":"hi"}"#))
    XCTAssertEqual(env["kind"] as? String, "execution_error")
    XCTAssertEqual(
      env["retryable"] as? Bool, false, "a blocked chat is permanent — don't ask to retry")
    XCTAssertTrue((env["message"] as? String ?? "").lowercased().contains("blocked"))
    XCTAssertTrue(TestHostGlobals.httpCalls.isEmpty)
  }

  // MARK: not configured

  func testReplyFailsWhenBotTokenMissing() {
    let token = makeBinding()
    state.botToken = nil
    let env = parseEnvelope(
      handleReply(
        state: state,
        payload: #"{"reply_token":"\#(token)","text":"hi"}"#))
    XCTAssertEqual(env["kind"] as? String, "unavailable")
  }

  // MARK: success paths

  func testReplySuccessSendsHTTPCallAndMarksReplied() {
    let token = makeBinding(taskId: "task-success")
    setHTTPSuccess()

    let env = parseEnvelope(
      handleReply(
        state: state,
        payload: #"{"reply_token":"\#(token)","text":"hello world"}"#))

    XCTAssertEqual(env["ok"] as? Bool, true)
    XCTAssertEqual((env["data"] as? [String: Any])?["sent"] as? Bool, true)
    XCTAssertEqual(env["summary"] as? String, "Sent message to user.")
    XCTAssertTrue(DatabaseManager.hasReplied(taskId: "task-success"))
    XCTAssertEqual(TestHostGlobals.httpCalls.count, 1)
    let call = TestHostGlobals.httpCalls[0]
    XCTAssertEqual(call["method"] as? String, "POST")
    XCTAssertTrue((call["url"] as? String ?? "").contains("/sendMessage"))
  }

  func testReplyTypingSuccessDoesNotMarkReplied() {
    let token = makeBinding(taskId: "task-typing")
    setHTTPSuccess()

    let env = parseEnvelope(
      handleReplyTyping(
        state: state, payload: #"{"reply_token":"\#(token)"}"#))

    XCTAssertEqual(env["ok"] as? Bool, true)
    XCTAssertFalse(
      DatabaseManager.hasReplied(taskId: "task-typing"),
      "typing-only must not flip the safety-net flag")
    XCTAssertEqual(TestHostGlobals.httpCalls.count, 1)
    let call = TestHostGlobals.httpCalls[0]
    XCTAssertTrue((call["url"] as? String ?? "").contains("/sendChatAction"))
  }

  func testReplyPhotoSuccess() {
    let token = makeBinding(taskId: "task-photo")
    setHTTPSuccess()

    let env = parseEnvelope(
      handleReplyPhoto(
        state: state,
        payload:
          #"{"reply_token":"\#(token)","photo_url":"https://example.com/p.jpg","caption":"cap"}"#))

    XCTAssertEqual(env["ok"] as? Bool, true)
    XCTAssertTrue(DatabaseManager.hasReplied(taskId: "task-photo"))
    let call = TestHostGlobals.httpCalls[0]
    XCTAssertTrue((call["url"] as? String ?? "").contains("/sendPhoto"))
  }

  func testReplyClampsLongTextToFourThousandChars() {
    let token = makeBinding(taskId: "task-long")
    setHTTPSuccess()

    let longText = String(repeating: "x", count: 5_000)
    let payload: [String: Any] = ["reply_token": token, "text": longText]
    let payloadJSON =
      String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!

    _ = handleReply(state: state, payload: payloadJSON)

    let body = TestHostGlobals.httpCalls[0]["body"] as? String ?? ""
    let bodyObj = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
    let sentText = bodyObj?["text"] as? String ?? ""
    XCTAssertEqual(sentText.count, 4_000, "text must be clamped to 4000 chars")
  }

  // MARK: failure mapping

  func testReplyMapsBotWasBlockedAndCancelsTask() {
    let token = makeBinding(chatId: 300, taskId: "task-blocked")
    setHTTPBotWasBlocked()

    let env = parseEnvelope(
      handleReply(
        state: state,
        payload: #"{"reply_token":"\#(token)","text":"hi"}"#))

    XCTAssertEqual(env["kind"] as? String, "execution_error")
    XCTAssertEqual(env["retryable"] as? Bool, false)
    XCTAssertTrue(DatabaseManager.isChatBlocked(agentId: agentId, chatId: 300))
    XCTAssertEqual(TestHostGlobals.cancelCalls, ["task-blocked"])
    XCTAssertFalse(
      DatabaseManager.hasReplied(taskId: "task-blocked"),
      "failed reply must not flip has_replied")
  }

  func testReplyMapsGenericTelegramError() {
    let token = makeBinding(chatId: 400, taskId: "task-err")
    setHTTPGenericError()

    let env = parseEnvelope(
      handleReply(
        state: state,
        payload: #"{"reply_token":"\#(token)","text":"hi"}"#))

    XCTAssertEqual(env["kind"] as? String, "execution_error")
    XCTAssertEqual(
      env["retryable"] as? Bool, true, "a generic Telegram error is retryable by default")
    XCTAssertTrue(
      (env["message"] as? String ?? "").contains("chat not found"),
      "telegram description should propagate")
    XCTAssertFalse(DatabaseManager.isChatBlocked(agentId: agentId, chatId: 400))
    XCTAssertTrue(TestHostGlobals.cancelCalls.isEmpty)
  }

  // MARK: invoke dispatcher (smoke)

  func testHandleReplyPassesParseModeThrough() {
    let token = makeBinding(taskId: "task-pm")
    setHTTPSuccess()

    _ = handleReply(
      state: state,
      payload: #"{"reply_token":"\#(token)","text":"<b>hi</b>","parse_mode":"HTML"}"#)

    let body = TestHostGlobals.httpCalls[0]["body"] as? String ?? ""
    let bodyObj = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
    XCTAssertEqual(bodyObj?["parse_mode"] as? String, "HTML")
  }

  // MARK: - loading-eye clearing

  /// Helper: only the setMessageReaction calls captured by the http stub.
  private func reactionCalls() -> [[String: Any]] {
    TestHostGlobals.httpCalls.filter {
      ($0["url"] as? String ?? "").contains("/setMessageReaction")
    }
  }

  /// First content-bearing reply must clear the loading 👀 reaction.
  /// Without this clearance the eye lingers indefinitely after the agent
  /// has already responded, which is the regression we're guarding.
  func testReplySuccessClearsLoadingReaction() {
    let token = makeBinding(
      chatId: 500, taskId: "task-eye-clear", incomingMessageId: 99)
    setHTTPSuccess()

    _ = handleReply(
      state: state,
      payload: #"{"reply_token":"\#(token)","text":"hi"}"#)

    let calls = reactionCalls()
    XCTAssertEqual(calls.count, 1, "first reply must emit exactly one clear")
    let body = calls[0]["body"] as? String ?? ""
    let bodyObj =
      (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
    XCTAssertEqual(bodyObj["chat_id"] as? Int, 500)
    XCTAssertEqual(bodyObj["message_id"] as? Int, 99)
    let reaction = bodyObj["reaction"] as? [[String: Any]] ?? [["sentinel": "x"]]
    XCTAssertTrue(
      reaction.isEmpty,
      "clearing the eye means an empty reaction array; got: \(reaction)")
  }

  /// The clear is debounced: a second reply on the same binding must not
  /// re-issue setMessageReaction (the eye is already gone, and Telegram
  /// would just no-op anyway).
  func testSecondReplyDoesNotResendClear() {
    let token = makeBinding(
      chatId: 501, taskId: "task-double-reply", incomingMessageId: 12)
    setHTTPSuccess()

    _ = handleReply(state: state, payload: #"{"reply_token":"\#(token)","text":"a"}"#)
    _ = handleReply(state: state, payload: #"{"reply_token":"\#(token)","text":"b"}"#)

    XCTAssertEqual(
      reactionCalls().count, 1,
      "only the first content-bearing reply should clear the eye")
  }

  /// `reply_typing` doesn't carry user-visible content, so it must not
  /// flip has_replied AND must not clear the loading eye — the work is
  /// still in progress.
  func testReplyTypingDoesNotClearLoadingReaction() {
    let token = makeBinding(
      chatId: 502, taskId: "task-typing-no-clear", incomingMessageId: 21)
    setHTTPSuccess()

    _ = handleReplyTyping(state: state, payload: #"{"reply_token":"\#(token)"}"#)

    XCTAssertTrue(
      reactionCalls().isEmpty,
      "typing-only must leave the loading eye in place")
  }

  /// When the binding has no `incoming_message_id` (synthetic seeds /
  /// older rows), there's nothing to clear; we must short-circuit
  /// silently so we don't earn a Telegram 400 on message_id=0.
  func testReplyWithMissingIncomingMessageIdSkipsReactionCall() {
    let token = makeBinding(
      chatId: 503, taskId: "task-no-msgid", incomingMessageId: 0)
    setHTTPSuccess()

    _ = handleReply(state: state, payload: #"{"reply_token":"\#(token)","text":"hi"}"#)

    XCTAssertTrue(
      reactionCalls().isEmpty,
      "no setMessageReaction must fire when we never recorded a source message")
  }

  /// A failed send must NOT clear the eye — the user is still waiting and
  /// the safety net still needs a chance to surface something.
  func testReplyFailureLeavesLoadingReactionIntact() {
    let token = makeBinding(
      chatId: 504, taskId: "task-eye-fail", incomingMessageId: 88)
    setHTTPGenericError()

    _ = handleReply(state: state, payload: #"{"reply_token":"\#(token)","text":"hi"}"#)

    XCTAssertTrue(
      reactionCalls().isEmpty,
      "failed send must not clear the eye — the user is still waiting")
  }

  // MARK: - artifact share (auto-forward hook)

  /// Helper: build a minimal artifact payload string the host would hand
  /// us via invoke(type: "artifact", id: "share", payload).
  private func artifactPayload(
    filename: String, hostPath: String,
    mimeType: String? = nil, isDirectory: Bool = false
  ) -> String {
    var dict: [String: Any] = [
      "filename": filename,
      "host_path": hostPath,
      "is_directory": isDirectory,
    ]
    if let mimeType { dict["mime_type"] = mimeType }
    return makeJSONString(dict) ?? "{}"
  }

  /// The host's artifact payload carries no chat info, so the hook must
  /// resolve "which chat?" by picking the most recent in-flight dispatch
  /// for the agent across all chats. Verify the upload lands there and
  /// the loading eye is cleared.
  func testArtifactShareUploadsImageToLatestChat() throws {
    let chatA: Int64 = 700
    let chatB: Int64 = 701
    _ = makeBinding(chatId: chatA, taskId: "task-old", incomingMessageId: 0)
    Thread.sleep(forTimeInterval: 0.002)
    // Reuse the helper but change the token by inserting a second row
    // explicitly — the helper hardcodes "TOKABC12" so we go direct.
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: chatB)
    DatabaseManager.insertActiveDispatch(
      taskId: "task-latest", agentId: agentId, chatId: chatB, replyToken: "TOKLATEST",
      sessionId: "session-2",
      expiresAt: Int(Date().timeIntervalSince1970) + 600,
      incomingMessageId: 55)

    let path = "/tmp/mandelbrot-share.png"
    TestHostGlobals.fileReadStore[path] = (
      mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47])
    )
    setHTTPSuccess()

    let response = handleArtifactShare(
      state: state,
      payload: artifactPayload(
        filename: "mandelbrot.png", hostPath: path, mimeType: "image/png"))
    let envelope = parseEnvelope(response)
    XCTAssertEqual(envelope["uploaded"] as? Bool, true)

    let sendCall = try XCTUnwrap(
      TestHostGlobals.httpCalls.first {
        ($0["url"] as? String ?? "").contains("/sendPhoto")
      })
    XCTAssertEqual(sendCall["body_encoding"] as? String, "base64")
    let bodyB64 = sendCall["body"] as? String ?? ""
    // Multipart bodies sandwich raw PNG bytes between ASCII headers, so
    // a strict UTF-8 decode fails on the binary chunk. Latin-1 accepts
    // every byte without translation, which is enough to grep for the
    // (ASCII) chat_id field.
    let decoded =
      String(
        data: Data(base64Encoded: bodyB64) ?? Data(),
        encoding: .isoLatin1) ?? ""
    XCTAssertTrue(
      decoded.contains("name=\"chat_id\"")
        && decoded.contains("\(chatB)"),
      "upload must target the latest chat (\(chatB))")
    XCTAssertTrue(
      DatabaseManager.hasReplied(taskId: "task-latest"),
      "auto-forward IS the reply; safety net must not double-post")
    XCTAssertFalse(
      reactionCalls().isEmpty,
      "first content-bearing artifact must clear the loading eye")
  }

  /// Directory payloads aren't real files — the host fires the hook for
  /// them too (e.g. when the agent created a folder). Skip cleanly so we
  /// don't ask `file_read` for a directory and earn an error.
  func testArtifactShareSkipsDirectoryPayloads() {
    _ = makeBinding(chatId: 710, taskId: "task-dir", incomingMessageId: 7)

    let response = handleArtifactShare(
      state: state,
      payload: artifactPayload(
        filename: "build", hostPath: "/tmp/build", isDirectory: true))
    let envelope = parseEnvelope(response)
    XCTAssertEqual(envelope["skipped"] as? Bool, true)
    XCTAssertEqual(envelope["reason"] as? String, "directory")
    XCTAssertTrue(
      TestHostGlobals.fileReadCalls.isEmpty,
      "directory payloads must not trigger file_read")
    XCTAssertTrue(
      TestHostGlobals.httpCalls.isEmpty,
      "directory payloads must not trigger any upload")
  }

  /// When the agent has no in-flight dispatch, there's no obvious chat to
  /// route the file to — the hook must skip rather than guessing.
  func testArtifactShareSkipsWhenNoActiveDispatch() {
    let path = "/tmp/orphan.png"
    TestHostGlobals.fileReadStore[path] = (
      mimeType: "image/png", data: Data([0x89])
    )

    let response = handleArtifactShare(
      state: state,
      payload: artifactPayload(
        filename: "orphan.png", hostPath: path, mimeType: "image/png"))
    let envelope = parseEnvelope(response)
    XCTAssertEqual(envelope["skipped"] as? Bool, true)
    XCTAssertEqual(envelope["reason"] as? String, "no_active_chat")
    XCTAssertTrue(
      TestHostGlobals.httpCalls.isEmpty,
      "no in-flight dispatch must mean no upload")
  }

  /// The host's payload field names aren't pinned anywhere we control.
  /// In production we've seen both snake_case (`host_path`) and
  /// camelCase (`hostPath`). The auto-forward must work either way —
  /// otherwise a casing change in the host silently kills file delivery
  /// for every user.
  func testArtifactShareAcceptsAlternateFieldNames() throws {
    _ = makeBinding(chatId: 740, taskId: "task-camel", incomingMessageId: 33)
    let path = "/tmp/camel.png"
    TestHostGlobals.fileReadStore[path] = (
      mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47])
    )
    setHTTPSuccess()

    let camelPayload = #"""
      {"filename":"camel.png","hostPath":"\#(path)","mimeType":"image/png","isDirectory":false}
      """#
    let response = handleArtifactShare(state: state, payload: camelPayload)
    let envelope = parseEnvelope(response)
    XCTAssertEqual(
      envelope["uploaded"] as? Bool, true,
      "camelCase field names must still be accepted")
    XCTAssertNotNil(
      TestHostGlobals.httpCalls.first {
        ($0["url"] as? String ?? "").contains("/sendPhoto")
      },
      "auto-forward must fire on camelCase payload")
  }

  /// When the host fires `invoke(type: "artifact")` from a thread that
  /// doesn't bind a per-agent frame, we still need the file to reach the
  /// user. The trampoline in Plugin.swift falls back to the most recent
  /// in-flight dispatch in the DB. Verify the cross-agent lookup itself
  /// returns the right row.
  func testLatestActiveDispatchAcrossAgentsRoutesToInFlightTask() {
    _ = makeBinding(chatId: 750, taskId: "task-anyone", incomingMessageId: 0)
    let row = DatabaseManager.latestActiveDispatchAcrossAgents()
    XCTAssertEqual(row?.taskId, "task-anyone")
    XCTAssertEqual(row?.chatId, 750)
    XCTAssertEqual(row?.agentId, agentId)
  }
}
