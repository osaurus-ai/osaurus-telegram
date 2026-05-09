import XCTest

@testable import osaurus_telegram

final class ManifestTests: XCTestCase {

  private func parsed() throws -> [String: Any] {
    let data = try XCTUnwrap(pluginManifestJSON.data(using: .utf8))
    return try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func testManifestIsValidJSON() throws {
    _ = try parsed()
  }

  func testTopLevelMetadata() throws {
    let m = try parsed()
    XCTAssertEqual(m["plugin_id"] as? String, "osaurus.telegram")
    XCTAssertEqual(m["name"] as? String, "Telegram")
    XCTAssertEqual(m["version"] as? String, "1.5.0")
    XCTAssertEqual(m["license"] as? String, "MIT")
    XCTAssertNotNil(m["description"] as? String)
    XCTAssertNotNil(m["instructions"] as? String)
  }

  func testInstructionsExplainReplyTokenContract() throws {
    let m = try parsed()
    let instructions = try XCTUnwrap(m["instructions"] as? String)
    XCTAssertTrue(instructions.contains("reply_token"))
    XCTAssertTrue(instructions.contains("reply"))
    XCTAssertTrue(instructions.contains("4000"))
  }

  func testSecretsDeclaresBotTokenAndWebhookSecret() throws {
    let m = try parsed()
    let secrets = try XCTUnwrap(m["secrets"] as? [[String: Any]])
    let ids = secrets.compactMap { $0["id"] as? String }
    XCTAssertEqual(Set(ids), Set(["bot_token", "webhook_secret"]))
    for s in secrets {
      XCTAssertEqual(s["required"] as? Bool, true, "all secrets are required")
    }
  }

  func testRoutesContainsTunnelExposedWebhook() throws {
    let m = try parsed()
    let caps = try XCTUnwrap(m["capabilities"] as? [String: Any])
    let routes = try XCTUnwrap(caps["routes"] as? [[String: Any]])
    XCTAssertEqual(routes.count, 1)
    let webhook = try XCTUnwrap(routes.first)
    XCTAssertEqual(webhook["id"] as? String, "webhook")
    XCTAssertEqual(webhook["path"] as? String, "/webhook")
    XCTAssertEqual(webhook["auth"] as? String, "verify")
    XCTAssertEqual(webhook["tunnel_exposed"] as? Bool, true)
    XCTAssertEqual(webhook["methods"] as? [String], ["POST"])
  }

  func testToolsListIsExactlyReplyReplyTypingReplyPhoto() throws {
    let m = try parsed()
    let caps = try XCTUnwrap(m["capabilities"] as? [String: Any])
    let tools = try XCTUnwrap(caps["tools"] as? [[String: Any]])
    let ids = tools.compactMap { $0["id"] as? String }
    XCTAssertEqual(Set(ids), Set(["reply", "reply_typing", "reply_photo"]))
  }

  func testEachToolHasReplyTokenParameter() throws {
    let m = try parsed()
    let caps = try XCTUnwrap(m["capabilities"] as? [String: Any])
    let tools = try XCTUnwrap(caps["tools"] as? [[String: Any]])
    for tool in tools {
      let params = try XCTUnwrap(tool["parameters"] as? [String: Any])
      let properties = try XCTUnwrap(params["properties"] as? [String: Any])
      XCTAssertNotNil(
        properties["reply_token"], "\(tool["id"] ?? "?") missing reply_token")
      let required = try XCTUnwrap(params["required"] as? [String])
      XCTAssertTrue(
        required.contains("reply_token"),
        "\(tool["id"] ?? "?") must require reply_token")
    }
  }

  func testEachToolIsAutoPolicyAndNetworkRequirement() throws {
    let m = try parsed()
    let caps = try XCTUnwrap(m["capabilities"] as? [String: Any])
    let tools = try XCTUnwrap(caps["tools"] as? [[String: Any]])
    for tool in tools {
      XCTAssertEqual(
        tool["permission_policy"] as? String, "auto",
        "\(tool["id"] ?? "?") permission_policy must be auto")
      XCTAssertEqual(
        tool["requirements"] as? [String], ["network"],
        "\(tool["id"] ?? "?") must declare network requirement")
    }
  }

  func testNoLegacyConfigSectionOrArtifactHandler() throws {
    let m = try parsed()
    let caps = try XCTUnwrap(m["capabilities"] as? [String: Any])
    XCTAssertNil(caps["config"], "config section must be removed")
    XCTAssertNil(caps["artifact_handler"], "artifact_handler must be removed")
  }
}
