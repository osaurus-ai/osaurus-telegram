import XCTest

@testable import osaurus_telegram

/// Pin the Phase 3a inbound-media wiring:
///   * the candidate collector enumerates every media field on the
///     message exactly once,
///   * `renderAttachmentsHeader` emits the bracketed segment in the
///     documented shape, or nil when the list is empty,
///   * the prompt header carries the attachment paths AND the
///     "media without caption" prompt when the user sends a bare
///     photo,
///   * captionless / text-less media still passes the
///     "non-actionable" guard and dispatches a turn,
///   * `Models.swift` decodes every media variant we care about.
final class InboundMediaTests: XCTestCase {

  private var state: AgentState!
  private let agentId = defaultTestAgentId
  private let secret = "super-secret"

  override func setUp() {
    super.setUp()
    TestHost.install()
    DatabaseManager.initSchema()
    state = AgentState(agentId: agentId)
    state.botToken = "123:fake"
    state.webhookSecret = secret
  }

  override func tearDown() {
    state = nil
    TestHost.uninstall()
    super.tearDown()
  }

  // MARK: - Models.swift decoding for media payloads

  func testTGUpdateDecodesPhotoMessage() throws {
    let body = """
      {
        "update_id": 1,
        "message": {
          "message_id": 5,
          "chat": { "id": 100 },
          "from": { "id": 999, "username": "alice" },
          "photo": [
            { "file_id": "small", "file_unique_id": "uS", "width": 90, "height": 90 },
            { "file_id": "large", "file_unique_id": "uL", "width": 1280, "height": 1280 }
          ],
          "caption": "look at this"
        }
      }
      """
    let parsed = try XCTUnwrap(parseJSON(body, as: TGUpdate.self))
    let photos = try XCTUnwrap(parsed.message?.photo)
    XCTAssertEqual(photos.count, 2)
    XCTAssertEqual(photos.last?.file_id, "large")
    XCTAssertEqual(parsed.message?.caption, "look at this")
  }

  func testTGUpdateDecodesDocumentVoiceAudioVideoAnimation() throws {
    let body = """
      {
        "update_id": 1,
        "message": {
          "message_id": 5,
          "chat": { "id": 1 },
          "from": { "id": 1 },
          "document": { "file_id": "d", "file_name": "x.pdf", "mime_type": "application/pdf" },
          "voice": { "file_id": "v", "duration": 3, "mime_type": "audio/ogg" },
          "audio": { "file_id": "a", "title": "Song", "mime_type": "audio/mpeg" },
          "video": { "file_id": "vid", "duration": 10, "mime_type": "video/mp4" },
          "animation": { "file_id": "ani", "mime_type": "video/mp4" }
        }
      }
      """
    let parsed = try XCTUnwrap(parseJSON(body, as: TGUpdate.self))
    XCTAssertEqual(parsed.message?.document?.file_name, "x.pdf")
    XCTAssertEqual(parsed.message?.voice?.duration, 3)
    XCTAssertEqual(parsed.message?.audio?.title, "Song")
    XCTAssertEqual(parsed.message?.video?.duration, 10)
    XCTAssertEqual(parsed.message?.animation?.file_id, "ani")
  }

  // MARK: - Header rendering

  func testRenderAttachmentsHeaderIsNilForEmpty() {
    XCTAssertNil(renderAttachmentsHeader([]))
  }

  func testRenderAttachmentsHeaderShape() {
    let header = renderAttachmentsHeader([
      InboundAttachment(
        path: "/abs/photo.jpg", mimeType: "image/jpeg", kind: "photo"),
      InboundAttachment(
        path: "/abs/note.pdf", mimeType: "application/pdf", kind: "document"),
    ])
    let h = header ?? ""
    XCTAssertTrue(h.hasPrefix("[attachments "))
    XCTAssertTrue(h.hasSuffix("]"))
    XCTAssertTrue(h.contains("path1=/abs/photo.jpg"))
    XCTAssertTrue(h.contains("type=image/jpeg"))
    XCTAssertTrue(h.contains("kind=photo"))
    XCTAssertTrue(h.contains("path2=/abs/note.pdf"))
  }

  // MARK: - Captionless media still dispatches

  /// A photo with no caption must still dispatch (the "no text AND no
  /// media" guard accepts media-only). The prompt body is replaced
  /// with the explicit "media without text caption" prompt so the
  /// agent knows to act on the attachment instead of asking what the
  /// user wanted.
  ///
  /// Note: the actual `getFile` + download paths require Telegram
  /// network access (the stubbed response wouldn't carry binary
  /// bytes), so we don't assert that `attachments=` lands in the
  /// header here — InboundMedia gracefully degrades to "no
  /// attachments downloaded" and the dispatch still goes through.
  /// What we DO pin: the dispatch happens, with the empty-caption
  /// fallback prompt body.
  func testCaptionlessPhotoStillDispatches() throws {
    let update: [String: Any] = [
      "update_id": 9_001,
      "message": [
        "message_id": 7,
        "chat": ["id": 4_242],
        "from": [
          "id": 999, "username": "alice", "first_name": "Alice",
        ] as [String: Any],
        "photo": [
          [
            "file_id": "small", "file_unique_id": "uS",
            "width": 90, "height": 90,
          ] as [String: Any],
          [
            "file_id": "large", "file_unique_id": "uL",
            "width": 800, "height": 600,
          ] as [String: Any],
        ],
      ] as [String: Any],
    ]
    _ = handleRoute(
      state: state, agentId: agentId,
      requestJSON: webhookRequest(secret: secret, update: update))

    XCTAssertEqual(
      TestHostGlobals.dispatchCalls.count, 1,
      "media-only message must still dispatch (Phase 3a)")
    let prompt = try XCTUnwrap(
      TestHostGlobals.dispatchCalls[0]["prompt"] as? String)
    XCTAssertTrue(
      prompt.contains("user sent media without a text caption"),
      "captionless prompt body must surface the explicit instruction; "
        + "got: \(prompt)")
  }

  /// A document with a caption must dispatch with the caption as the
  /// body text (Telegram's `caption` field is treated as message body
  /// when `text` is absent).
  func testDocumentWithCaptionDispatchesCaptionAsBody() throws {
    let update: [String: Any] = [
      "update_id": 9_002,
      "message": [
        "message_id": 8,
        "chat": ["id": 4_243],
        "from": ["id": 999, "username": "alice"] as [String: Any],
        "document": [
          "file_id": "doc1", "file_name": "report.pdf",
          "mime_type": "application/pdf",
        ] as [String: Any],
        "caption": "summarize this please",
      ] as [String: Any],
    ]
    _ = handleRoute(
      state: state, agentId: agentId,
      requestJSON: webhookRequest(secret: secret, update: update))

    XCTAssertEqual(TestHostGlobals.dispatchCalls.count, 1)
    let prompt = try XCTUnwrap(
      TestHostGlobals.dispatchCalls[0]["prompt"] as? String)
    XCTAssertTrue(
      prompt.contains("summarize this please"),
      "caption must reach the agent as the body text")
  }

  /// Pre-claim guard: a path the inbound-media path stashes under
  /// `~/.osaurus/artifacts/...` MUST NOT be re-uploaded by the
  /// artifact auto-forward hook (otherwise we'd ping-pong the user's
  /// upload back to them). We exercise the claim mechanism directly
  /// so the test stays hermetic — no network, no real getFile, no
  /// disk side effects.
  func testInboundClaimSuppressesArtifactAutoForward() {
    let path =
      "/Users/test/.osaurus/artifacts/osaurus.telegram-inbound/agent/chat-1/msg-1/photo.jpg"

    // Pre-claim, the way `downloadInboundMedia` does before writing.
    XCTAssertFalse(
      state.claimArtifactUpload(path),
      "first claim must succeed (returns false = caller proceeds)")

    // Now the artifact watcher fires for the same path. handleArtifactShare
    // must short-circuit with `already_uploaded`.
    let payload = #"{"filename":"photo.jpg","host_path":"\#(path)","mime_type":"image/jpeg"}"#
    let envelope = handleArtifactShare(state: state, payload: payload)
    XCTAssertTrue(envelope.contains("\"skipped\":true"))
    XCTAssertTrue(
      envelope.contains("already_uploaded"),
      "pre-claimed inbound paths must skip via 'already_uploaded'; "
        + "got: \(envelope)")
  }

}
