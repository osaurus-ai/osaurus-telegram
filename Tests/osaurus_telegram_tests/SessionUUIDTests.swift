import XCTest

@testable import osaurus_telegram

final class SessionUUIDTests: XCTestCase {

  func testSameChatAndSaltProduceSameUUID() {
    let a = sessionUUID(forChatId: 12345, salt: 0)
    let b = sessionUUID(forChatId: 12345, salt: 0)
    XCTAssertEqual(a, b, "deterministic UUID5 should be stable across calls")
  }

  func testDifferentSaltProducesDifferentUUID() {
    let a = sessionUUID(forChatId: 12345, salt: 0)
    let b = sessionUUID(forChatId: 12345, salt: 1)
    XCTAssertNotEqual(a, b, "salt bump should land in a fresh transcript")
  }

  func testDifferentChatProducesDifferentUUID() {
    let a = sessionUUID(forChatId: 1, salt: 0)
    let b = sessionUUID(forChatId: 2, salt: 0)
    XCTAssertNotEqual(a, b, "different chats should have different sessions")
  }

  func testUUIDIsRFC4122Version5() {
    let id = sessionUUID(forChatId: 99, salt: 7)
    let bytes = id.uuid
    let versionNibble = (bytes.6 & 0xF0) >> 4
    let variantNibble = (bytes.8 & 0xC0) >> 6
    XCTAssertEqual(versionNibble, 5, "version nibble should be 5")
    XCTAssertEqual(variantNibble, 0b10, "variant should be RFC 4122")
  }
}
