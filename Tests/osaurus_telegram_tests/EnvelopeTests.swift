import XCTest

@testable import osaurus_telegram

final class EnvelopeTests: XCTestCase {

  func testSuccessEnvelopeShape() throws {
    let json = toolEnvelopeSuccess(["sent": true], summary: "ok")
    let parsed = try XCTUnwrap(jsonObject(json))
    XCTAssertEqual(parsed["ok"] as? Bool, true)
    XCTAssertEqual(parsed["summary"] as? String, "ok")
    let data = try XCTUnwrap(parsed["data"] as? [String: Any])
    XCTAssertEqual(data["sent"] as? Bool, true)
  }

  func testSuccessEnvelopeOmitsSummaryWhenAbsent() throws {
    let json = toolEnvelopeSuccess()
    let parsed = try XCTUnwrap(jsonObject(json))
    XCTAssertEqual(parsed["ok"] as? Bool, true)
    XCTAssertNil(parsed["summary"])
    XCTAssertNotNil(parsed["data"])
  }

  // MARK: - canonical failure envelope

  func testFailureEnvelopeShapeUsesKindAndRetryable() throws {
    let json = Envelope.failure(.executionError, "boom")
    let parsed = try XCTUnwrap(jsonObject(json))
    XCTAssertEqual(parsed["ok"] as? Bool, false)
    XCTAssertEqual(parsed["kind"] as? String, "execution_error")
    XCTAssertEqual(parsed["message"] as? String, "boom")
    XCTAssertEqual(parsed["retryable"] as? Bool, true)
    // The canonical failure envelope must NOT carry the legacy `error` key.
    XCTAssertNil(parsed["error"])
  }

  func testFailureEnvelopeDefaultRetryablePerKind() throws {
    // invalid_args / not_found are deterministic: retrying the identical
    // call can never succeed, so they must NOT default to retryable.
    XCTAssertEqual(
      try XCTUnwrap(jsonObject(Envelope.failure(.invalidArgs, "x")))["retryable"] as? Bool, false)
    XCTAssertEqual(
      try XCTUnwrap(jsonObject(Envelope.failure(.executionError, "x")))["retryable"] as? Bool, true)
    XCTAssertEqual(
      try XCTUnwrap(jsonObject(Envelope.failure(.unavailable, "x")))["retryable"] as? Bool, true)
    XCTAssertEqual(
      try XCTUnwrap(jsonObject(Envelope.failure(.notFound, "x")))["retryable"] as? Bool, false)
  }

  func testFailureEnvelopeCarriesDataPayload() throws {
    let parsed = try XCTUnwrap(
      jsonObject(Envelope.failure(.executionError, "rate limited", data: ["retry_after": 7])))
    let data = try XCTUnwrap(parsed["data"] as? [String: Any])
    XCTAssertEqual(data["retry_after"] as? Int, 7)
  }

  func testFailureEnvelopeOmitsDataWhenAbsent() throws {
    let parsed = try XCTUnwrap(jsonObject(Envelope.failure(.executionError, "boom")))
    XCTAssertNil(parsed["data"])
  }

  func testFailureEnvelopeRetryableOverride() throws {
    let parsed = try XCTUnwrap(
      jsonObject(Envelope.failure(.executionError, "blocked", retryable: false)))
    XCTAssertEqual(parsed["kind"] as? String, "execution_error")
    XCTAssertEqual(parsed["retryable"] as? Bool, false)
  }

  /// Round-trip: a failure with control characters / quotes in the message
  /// must escape into valid JSON that parses back to the same message.
  func testFailureEnvelopeRoundTripEscapesMessage() throws {
    let message = "line1\nwith \"quotes\", a tab\t and a backslash \\ end"
    let parsed = try XCTUnwrap(jsonObject(Envelope.failure(.invalidArgs, message)))
    XCTAssertEqual(parsed["ok"] as? Bool, false)
    XCTAssertEqual(parsed["kind"] as? String, "invalid_args")
    XCTAssertEqual(parsed["message"] as? String, message)
    XCTAssertEqual(parsed["retryable"] as? Bool, false)
  }

  // MARK: helpers

  private func jsonObject(_ s: String) -> [String: Any]? {
    guard let data = s.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }
}
