import XCTest

@testable import osaurus_telegram

final class TokenTests: XCTestCase {

  func testReplyTokenLengthAndCharset() {
    let allowed = Set("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    for _ in 0..<100 {
      let token = mintReplyToken()
      XCTAssertEqual(token.count, 8, "reply token should be 8 characters")
      for ch in token {
        XCTAssertTrue(allowed.contains(ch), "unexpected char \(ch) in token \(token)")
      }
    }
  }

  func testReplyTokensAreUniqueEnough() {
    var seen = Set<String>()
    for _ in 0..<1_000 {
      seen.insert(mintReplyToken())
    }
    // 1000 of 31^8 (~852 billion) tokens — collisions essentially impossible.
    XCTAssertEqual(seen.count, 1_000, "tokens should not collide in this run")
  }

  func testConstantTimeEqualsHandlesEqualAndUnequal() {
    XCTAssertTrue(constantTimeEquals("abc123", "abc123"))
    XCTAssertFalse(constantTimeEquals("abc123", "abc124"))
    XCTAssertFalse(constantTimeEquals("abc", "abcd"))
    XCTAssertTrue(constantTimeEquals("", ""))
    XCTAssertFalse(constantTimeEquals("a", ""))
  }
}
