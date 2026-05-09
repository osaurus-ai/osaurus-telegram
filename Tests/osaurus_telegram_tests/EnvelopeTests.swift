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

  func testErrorEnvelopeShape() throws {
    let json = toolEnvelopeError("stale_token", "Reply token expired")
    let parsed = try XCTUnwrap(jsonObject(json))
    XCTAssertEqual(parsed["ok"] as? Bool, false)
    XCTAssertEqual(parsed["error"] as? String, "stale_token")
    XCTAssertEqual(parsed["message"] as? String, "Reply token expired")
  }

  // MARK: helpers

  private func jsonObject(_ s: String) -> [String: Any]? {
    guard let data = s.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }
}
