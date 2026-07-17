import Foundation
import OsaurusPluginABI
import OsaurusPluginTestSupport
import XCTest

@testable import osaurus_telegram

/// SDK-provided conformance checks (replaces hand-rolled equivalents):
/// manifest registry rules, ABI table completeness through the plugin's
/// REAL entry points, and the canonical failure envelope shape.
final class SDKConformanceTests: XCTestCase {

  override func setUp() {
    super.setUp()
    TestHost.install()
  }

  override func tearDown() {
    TestHost.uninstall()
    super.tearDown()
  }

  func testManifestPassesSDKRegistryConformance() throws {
    try ManifestConformance.assertConformant(pluginManifestJSON)
  }

  func testV2EntryPointReturnsConformantABITable() throws {
    let entry = withUnsafePointer(to: &TestHostGlobals.apiTable) { ptr in
      osaurus_plugin_entry_v2(UnsafeRawPointer(ptr))
    }
    try ABIConformance.assertEntryConformance(entry, manifestJSON: pluginManifestJSON)
    // The manifest declares the webhook route; the v2 table must expose
    // handle_route + the lifecycle callbacks this plugin relies on.
    let api = try XCTUnwrap(entry).assumingMemoryBound(to: OsrPluginAPI.self).pointee
    XCTAssertEqual(api.version, OsrABIVersion.v2)
    XCTAssertNotNil(api.handle_route)
    XCTAssertNotNil(api.on_config_changed)
    XCTAssertNotNil(api.on_task_event)
    // Entry must reinstall the bridge for the injected host.
    XCTAssertTrue(HostBridge.shared.isInstalled)
  }

  func testV1EntryPointReturnsSameConformantTable() throws {
    try ABIConformance.assertEntryConformance(
      osaurus_plugin_entry(), manifestJSON: pluginManifestJSON)
  }

  func testToolFailuresRenderCanonicalEnvelope() throws {
    let json = Envelope.failure(.notFound, "Unknown tool: nope")
    try assertCanonicalFailure(json, kind: .notFound)
  }
}
