import OsaurusPluginABI
import XCTest

@testable import osaurus_telegram

/// Pins every `OsrHostAPI` slot's offset against the host's frozen
/// layout. Since Wave 2 the mirror comes from the pinned
/// `osaurus-plugin-sdk` (which carries its own layout tests); these
/// assertions stay here as this plugin's independent check that the
/// EXACT SDK version resolved by Package.resolved still matches the
/// layout the reviewed host injects. If the SDK ever drifted (or a
/// future bump changed the layout), every later callback would dispatch
/// into the wrong host function and typically crash inside `libc free()`
/// on a non-malloc pointer.
///
/// The numbers below come from
/// `osaurus/docs/plugins/HOST_API.md` → "Pinned offsets" and the host's
/// own `PluginHostAPIStructLayoutTests`.
final class HostAPILayoutTests: XCTestCase {

  func testStructStrideMatchesHost() {
    XCTAssertEqual(
      MemoryLayout<OsrHostAPI>.stride, 200,
      """
      OsrHostAPI stride drifted from the host's frozen layout.
      Either the host appended a new slot (bump the SDK pin + this \
      test together) or a slot was reordered / dropped (which silently \
      corrupts every later callback). See HOST_API.md → Mirror Struct Audit.
      """)
  }

  func testPinnedSlotOffsets() {
    // The full slot table is documented in HOST_API.md; we pin only
    // the slots whose mis-placement was actually production-fatal in
    // the past.
    XCTAssertEqual(MemoryLayout<OsrHostAPI>.offset(of: \.version), 0)
    XCTAssertEqual(
      MemoryLayout<OsrHostAPI>.offset(of: \.get_active_agent_id), 176,
      "v4 slot offset drifted — every later callback will misroute")
    XCTAssertEqual(
      MemoryLayout<OsrHostAPI>.offset(of: \.log_structured), 184,
      "v5 slot offset drifted (THIS is the foot-gun: most plugins skip it)")
    XCTAssertEqual(
      MemoryLayout<OsrHostAPI>.offset(of: \.free_string), 192,
      "v6 slot offset drifted — host->free_string would dispatch into "
        + "log_structured and the pointer would be silently discarded")
  }

  func testMirrorIsByteIdenticalAcrossSlots() throws {
    // Defense-in-depth: if a slot were ever added in the wrong place, at
    // least one of the canonical slots before AND after the new one
    // would disagree with its pinned offset.
    let head = try XCTUnwrap(MemoryLayout<OsrHostAPI>.offset(of: \.version))
    let tail = try XCTUnwrap(MemoryLayout<OsrHostAPI>.offset(of: \.free_string))
    XCTAssertEqual(head, 0)
    XCTAssertEqual(tail, 192)
    XCTAssertEqual(MemoryLayout<OsrHostAPI>.stride - tail, 8)
  }
}
