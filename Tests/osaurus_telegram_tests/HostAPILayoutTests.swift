import XCTest

@testable import osaurus_telegram

/// Pins every `osr_host_api` slot's offset against the host's frozen
/// layout. The host injects the struct byte-for-byte; if our mirror
/// drops or reorders a slot, every later callback dispatches into the
/// wrong host function and typically crashes inside `libc free()` on a
/// non-malloc pointer (`pointer being freed was not allocated`).
///
/// The numbers below come from
/// `osaurus/docs/plugins/HOST_API.md` → "Pinned offsets" and the host's
/// own `PluginHostAPIStructLayoutTests`. They MUST stay in sync; if the
/// host appends a new slot in v7+, the mirror is updated and the new
/// offset is added here.
final class HostAPILayoutTests: XCTestCase {

  func testStructStrideMatchesHost() {
    XCTAssertEqual(
      MemoryLayout<osr_host_api>.stride, 200,
      """
      osr_host_api stride drifted from the host's frozen layout.
      Either the host appended a new slot (update the mirror + this \
      test together) or a slot was reordered / dropped (which silently \
      corrupts every later callback). See HOST_API.md → Mirror Struct Audit.
      """)
  }

  func testPinnedSlotOffsets() {
    // The full slot table is documented in HOST_API.md; we pin only
    // the slots whose mis-placement was actually production-fatal in
    // the past. If you find yourself adding a row here, also add the
    // canonical entry to the host's own layout test.
    XCTAssertEqual(MemoryLayout<osr_host_api>.offset(of: \.version), 0)
    XCTAssertEqual(
      MemoryLayout<osr_host_api>.offset(of: \.get_active_agent_id), 176,
      "v4 slot offset drifted — every later callback will misroute")
    XCTAssertEqual(
      MemoryLayout<osr_host_api>.offset(of: \.log_structured), 184,
      "v5 slot offset drifted (THIS is the foot-gun: most plugins skip it)")
    XCTAssertEqual(
      MemoryLayout<osr_host_api>.offset(of: \.free_string), 192,
      "v6 slot offset drifted — host->free_string would dispatch into "
        + "log_structured and the pointer would be silently discarded")
  }

  func testMirrorIsByteIdenticalAcrossSlots() throws {
    // Defense-in-depth: if anyone adds a slot in the wrong place, at
    // least one of the canonical slots before AND after the new one
    // will disagree with its pinned offset. This is implicit from the
    // table above, but having it as a single explicit invariant makes
    // bisecting a future regression faster.
    let head = try XCTUnwrap(MemoryLayout<osr_host_api>.offset(of: \.version))
    let tail = try XCTUnwrap(MemoryLayout<osr_host_api>.offset(of: \.free_string))
    XCTAssertEqual(head, 0)
    XCTAssertEqual(tail, 192)
    XCTAssertEqual(MemoryLayout<osr_host_api>.stride - tail, 8)
  }
}
