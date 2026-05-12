import XCTest

@testable import osaurus_telegram

/// Pin the Phase 3b outbound-media tools (`reply_document`,
/// `reply_voice`, `reply_audio`, `reply_video`) and the inline keyboard
/// option on `reply`. Each handler must:
///   * reject malformed args with `invalid_request`,
///   * reject stale tokens with `stale_token`,
///   * route the success path through the right Telegram method
///     (`sendDocument` / `sendVoice` / `sendAudio` / `sendVideo`),
///   * mark the binding `has_replied=1` on success so the safety net
///     stays silent.
final class ReplyMediaTests: XCTestCase {

  private var state: AgentState!
  private let agentId = defaultTestAgentId

  override func setUp() {
    super.setUp()
    TestHost.install()
    DatabaseManager.initSchema()
    state = AgentState(agentId: agentId)
    state.botToken = "123:fake"
    setHTTPSuccess()
  }

  override func tearDown() {
    state = nil
    TestHost.uninstall()
    super.tearDown()
  }

  // MARK: - shared helpers

  @discardableResult
  private func makeBinding(
    chatId: Int64 = 700, taskId: String = "task-media"
  ) -> String {
    _ = DatabaseManager.upsertChatSession(agentId: agentId, chatId: chatId)
    let token = "TOKMEDIA"
    DatabaseManager.insertActiveDispatch(
      taskId: taskId, agentId: agentId, chatId: chatId,
      replyToken: token, sessionId: "s1",
      expiresAt: Int(Date().timeIntervalSince1970) + 600)
    return token
  }

  private func setHTTPSuccess() {
    TestHostGlobals.nextHttpResponse =
      #"{"status":200,"body":"{\"ok\":true,\"result\":{\"message_id\":1}}"}"#
  }

  private func parseEnvelope(_ s: String) -> [String: Any] {
    let data = s.data(using: .utf8) ?? Data()
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }

  private func httpURLContains(_ needle: String) -> Bool {
    TestHostGlobals.httpCalls.contains { call in
      ((call["url"] as? String) ?? "").contains(needle)
    }
  }

  // MARK: - invalid args

  func testReplyDocumentRejectsMissingURL() {
    let env = parseEnvelope(
      handleReplyDocument(
        state: state, payload: #"{"reply_token":"X"}"#))
    XCTAssertEqual(env["error"] as? String, "invalid_request")
  }

  func testReplyVoiceRejectsMissingURL() {
    let env = parseEnvelope(
      handleReplyVoice(
        state: state, payload: #"{"reply_token":"X"}"#))
    XCTAssertEqual(env["error"] as? String, "invalid_request")
  }

  func testReplyAudioRejectsMissingURL() {
    let env = parseEnvelope(
      handleReplyAudio(
        state: state, payload: #"{"reply_token":"X"}"#))
    XCTAssertEqual(env["error"] as? String, "invalid_request")
  }

  func testReplyVideoRejectsMissingURL() {
    let env = parseEnvelope(
      handleReplyVideo(
        state: state, payload: #"{"reply_token":"X"}"#))
    XCTAssertEqual(env["error"] as? String, "invalid_request")
  }

  // MARK: - stale token

  func testReplyDocumentStaleTokenWhenUnknown() {
    let env = parseEnvelope(
      handleReplyDocument(
        state: state,
        payload:
          #"{"reply_token":"NOPE","document_url":"https://x/y.pdf"}"#))
    XCTAssertEqual(env["error"] as? String, "stale_token")
    XCTAssertTrue(TestHostGlobals.httpCalls.isEmpty)
  }

  // MARK: - success paths

  func testReplyDocumentRoutesViaSendDocument() {
    let token = makeBinding(taskId: "task-doc")
    let env = parseEnvelope(
      handleReplyDocument(
        state: state,
        payload:
          #"{"reply_token":"\#(token)","document_url":"https://x/r.pdf","caption":"see"}"#))
    XCTAssertEqual(env["ok"] as? Bool, true)
    XCTAssertEqual(env["summary"] as? String, "Sent document to user.")
    XCTAssertTrue(httpURLContains("/sendDocument"))
    XCTAssertTrue(DatabaseManager.hasReplied(taskId: "task-doc"))
  }

  func testReplyVoiceRoutesViaSendVoice() {
    let token = makeBinding(taskId: "task-voice")
    let env = parseEnvelope(
      handleReplyVoice(
        state: state,
        payload:
          #"{"reply_token":"\#(token)","voice_url":"https://x/v.ogg"}"#))
    XCTAssertEqual(env["ok"] as? Bool, true)
    XCTAssertTrue(httpURLContains("/sendVoice"))
    XCTAssertTrue(DatabaseManager.hasReplied(taskId: "task-voice"))
  }

  func testReplyAudioRoutesViaSendAudio() {
    let token = makeBinding(taskId: "task-audio")
    let env = parseEnvelope(
      handleReplyAudio(
        state: state,
        payload:
          #"{"reply_token":"\#(token)","audio_url":"https://x/a.mp3"}"#))
    XCTAssertEqual(env["ok"] as? Bool, true)
    XCTAssertTrue(httpURLContains("/sendAudio"))
    XCTAssertTrue(DatabaseManager.hasReplied(taskId: "task-audio"))
  }

  func testReplyVideoRoutesViaSendVideo() {
    let token = makeBinding(taskId: "task-video")
    let env = parseEnvelope(
      handleReplyVideo(
        state: state,
        payload:
          #"{"reply_token":"\#(token)","video_url":"https://x/v.mp4"}"#))
    XCTAssertEqual(env["ok"] as? Bool, true)
    XCTAssertTrue(httpURLContains("/sendVideo"))
    XCTAssertTrue(DatabaseManager.hasReplied(taskId: "task-video"))
  }

  // MARK: - reply_to_message_id is forwarded

  func testReplyDocumentForwardsReplyToMessageId() throws {
    let token = makeBinding(taskId: "task-doc-thread")
    _ = handleReplyDocument(
      state: state,
      payload:
        #"{"reply_token":"\#(token)","document_url":"https://x/r.pdf","reply_to_message_id":42}"#)

    let body = TestHostGlobals.httpCalls.last?["body"] as? String ?? ""
    let bodyObj =
      (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
    let replyParams = bodyObj["reply_parameters"] as? [String: Any] ?? [:]
    XCTAssertEqual(replyParams["message_id"] as? Int, 42)
  }

  // MARK: - inline_keyboard on reply

  /// `reply` accepts an `inline_keyboard` (2D array of buttons) and
  /// forwards it to Telegram's `reply_markup.inline_keyboard`.
  func testReplyForwardsInlineKeyboard() throws {
    let token = makeBinding(taskId: "task-buttons")
    let payload = """
      {
        "reply_token": "\(token)",
        "text": "pick one",
        "inline_keyboard": [
          [
            {"text": "Yes", "callback_data": "yes"},
            {"text": "No",  "callback_data": "no"}
          ],
          [
            {"text": "Open docs", "url": "https://example.com/docs"}
          ]
        ]
      }
      """
    let env = parseEnvelope(handleReply(state: state, payload: payload))
    XCTAssertEqual(env["ok"] as? Bool, true)

    let body = TestHostGlobals.httpCalls.last?["body"] as? String ?? ""
    let bodyObj =
      (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
    let markup = try XCTUnwrap(bodyObj["reply_markup"] as? [String: Any])
    let keyboard = try XCTUnwrap(markup["inline_keyboard"] as? [[[String: Any]]])
    XCTAssertEqual(keyboard.count, 2)
    XCTAssertEqual(keyboard[0].count, 2)
    XCTAssertEqual(keyboard[0][0]["text"] as? String, "Yes")
    XCTAssertEqual(keyboard[0][0]["callback_data"] as? String, "yes")
    XCTAssertEqual(keyboard[1][0]["text"] as? String, "Open docs")
    XCTAssertEqual(keyboard[1][0]["url"] as? String, "https://example.com/docs")
  }
}
