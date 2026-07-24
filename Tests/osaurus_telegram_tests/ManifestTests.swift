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
    XCTAssertEqual(m["version"] as? String, telegramPluginVersion)
    XCTAssertEqual(m["version"] as? String, "1.5.1")
    XCTAssertEqual(m["license"] as? String, "MIT")
    XCTAssertNotNil(m["description"] as? String)
    XCTAssertNotNil(m["instructions"] as? String)
  }

  /// The manifest version and `osaurus-plugin.json` must stay in
  /// lockstep — the repo-root JSON is what the packaging pipeline reads.
  func testVersionMatchesPluginJSON() throws {
    let jsonURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // osaurus_telegram_tests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
      .appendingPathComponent("osaurus-plugin.json")
    let data = try Data(contentsOf: jsonURL)
    let obj = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(obj["version"] as? String, telegramPluginVersion)
  }

  /// Every per-agent callback requires host ABI v4 (`get_active_agent_id`),
  /// so the manifest must not admit hosts older than the v4 floor.
  func testMinOsaurusGuaranteesABIv4() throws {
    let m = try parsed()
    XCTAssertEqual(m["min_osaurus"] as? String, telegramMinOsaurusVersion)
    XCTAssertEqual(m["min_osaurus"] as? String, "0.18.14")
  }

  func testInstructionsExplainReplyTokenContract() throws {
    let m = try parsed()
    let instructions = try XCTUnwrap(m["instructions"] as? String)
    XCTAssertTrue(instructions.contains("reply_token"))
    XCTAssertTrue(instructions.contains("reply"))
    XCTAssertTrue(instructions.contains("4000"))
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

  func testToolsListIsExactlyTheReplySurface() throws {
    let m = try parsed()
    let caps = try XCTUnwrap(m["capabilities"] as? [String: Any])
    let tools = try XCTUnwrap(caps["tools"] as? [[String: Any]])
    let ids = tools.compactMap { $0["id"] as? String }
    XCTAssertEqual(
      Set(ids), Set(dispatchToolNames),
      "manifest tools list must mirror dispatchToolNames; "
        + "files reach the user via the artifact auto-forward hook, "
        + "not a tool")
    XCTAssertEqual(
      Set(ids),
      Set([
        "reply", "reply_typing", "reply_photo",
        "reply_document", "reply_voice", "reply_audio", "reply_video",
      ]),
      "Phase 3b expects the full media reply surface (document/voice/audio/video)")
  }

  /// Telegram has no native clarification UI, so the host `clarify` tool
  /// lands silently for our users. The agent must be told explicitly to
  /// use `reply` for any clarifying question instead — otherwise the
  /// turn ends with the user staring at the safety-net fallback.
  func testInstructionsForbidClarifyTool() throws {
    let m = try parsed()
    let instructions = try XCTUnwrap(m["instructions"] as? String)
    XCTAssertTrue(
      instructions.contains("clarify"),
      "instructions must explicitly address the clarify tool so the agent doesn't call it")
    XCTAssertTrue(
      instructions.lowercased().contains("do not call the `clarify`")
        || instructions.lowercased().contains("not call the `clarify`"),
      "instructions must forbid the clarify tool by name")
  }

  /// The agent only ever has the sandbox path of the files it generates
  /// (host->file_read is restricted to ~/.osaurus/artifacts/), so the
  /// instructions must teach that the host auto-forwards files instead
  /// of pointing the agent at a tool that wouldn't work.
  func testInstructionsExplainArtifactAutoForward() throws {
    let m = try parsed()
    let instructions = try XCTUnwrap(m["instructions"] as? String)
    XCTAssertTrue(
      instructions.contains("auto-forwarded"),
      "instructions must explain that files are auto-forwarded by the host")
    XCTAssertFalse(
      instructions.contains("reply_file"),
      "reply_file is gone; instructions must not advertise it")
  }

  /// Host contract: every tool entry needs a non-empty `id` (the host
  /// dispatches `invoke` on it) and a non-empty `description` (shown to the
  /// agent). Also re-pins `plugin_id` here so the contract is asserted in
  /// one focused place alongside the tool shape.
  func testEachToolHasNonEmptyIdAndDescriptionAndPluginId() throws {
    let m = try parsed()
    XCTAssertEqual(m["plugin_id"] as? String, "osaurus.telegram")
    let caps = try XCTUnwrap(m["capabilities"] as? [String: Any])
    let tools = try XCTUnwrap(caps["tools"] as? [[String: Any]])
    XCTAssertFalse(tools.isEmpty, "manifest must declare at least one tool")
    for tool in tools {
      let id = try XCTUnwrap(tool["id"] as? String, "every tool must declare an id")
      XCTAssertFalse(id.isEmpty, "tool id must be non-empty")
      let description = try XCTUnwrap(
        tool["description"] as? String, "tool \(id) must declare a description")
      XCTAssertFalse(description.isEmpty, "tool \(id) description must be non-empty")
    }
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

  // MARK: - capabilities.config shape (the per-agent autoconfig signal)

  func testConfigDeclaresBotTokenAsSecret() throws {
    let field = try botConfigField(key: "bot_token")
    XCTAssertEqual(field["type"] as? String, "secret")
    let validation = try XCTUnwrap(field["validation"] as? [String: Any])
    XCTAssertEqual(validation["required"] as? Bool, true)
  }

  /// `value_template: "{{plugin_url}}/webhook"` is what tells Osaurus this
  /// plugin needs the resolved tunnel URL pushed via on_config_changed.
  /// Without this field the per-agent autoconfig flow does not fire.
  func testConfigExposesWebhookURLWithPluginURLTemplate() throws {
    let field = try botConfigField(key: "webhook_url")
    XCTAssertEqual(field["type"] as? String, "readonly")
    XCTAssertEqual(
      field["value_template"] as? String, "{{plugin_url}}/webhook",
      "the {{plugin_url}} template is what triggers tunnel_url to be pushed to this plugin")
    XCTAssertEqual(field["copyable"] as? Bool, true)
  }

  /// The status indicator reads `webhook_registered` from config; the plugin
  /// writes `"true"` after a successful setWebhook and clears it on teardown.
  func testConfigExposesWebhookStatusBoundToWebhookRegistered() throws {
    let field = try botConfigField(key: "webhook_status")
    XCTAssertEqual(field["type"] as? String, "status")
    XCTAssertEqual(field["connected_when"] as? String, "webhook_registered")
  }

  func testManifestDeclaresArtifactHandler() throws {
    let m = try parsed()
    let caps = try XCTUnwrap(m["capabilities"] as? [String: Any])
    // Without this flag the host won't fire invoke(type: "artifact"), so
    // sandbox files would never auto-forward to Telegram even though the
    // hook is implemented.
    XCTAssertEqual(
      caps["artifact_handler"] as? Bool, true,
      "artifact_handler must be true so host fires invoke(type: artifact)")
  }

  func testOnlyBotConfigurationSectionRemains() throws {
    let m = try parsed()
    let caps = try XCTUnwrap(m["capabilities"] as? [String: Any])
    // Only the Bot Configuration section should remain; the agent / file /
    // behavior / prompt-customisation sections were intentionally dropped
    // by the rewrite.
    let config = try XCTUnwrap(caps["config"] as? [String: Any])
    let sections = try XCTUnwrap(config["sections"] as? [[String: Any]])
    XCTAssertEqual(sections.count, 1)
    XCTAssertEqual(sections.first?["title"] as? String, "Bot Configuration")
  }

  func testNoTopLevelSecretsArray() throws {
    // We deliberately use capabilities.config (with type:"secret") instead
    // of the top-level secrets array, because the latter isn't what
    // signals tunnel_url to be pushed.
    let m = try parsed()
    XCTAssertNil(m["secrets"], "secrets must live under capabilities.config")
  }

  // MARK: helpers

  private func botConfigField(key: String) throws -> [String: Any] {
    let m = try parsed()
    let caps = try XCTUnwrap(m["capabilities"] as? [String: Any])
    let config = try XCTUnwrap(caps["config"] as? [String: Any])
    let sections = try XCTUnwrap(config["sections"] as? [[String: Any]])
    let bot = try XCTUnwrap(sections.first { $0["title"] as? String == "Bot Configuration" })
    let fields = try XCTUnwrap(bot["fields"] as? [[String: Any]])
    return try XCTUnwrap(fields.first { $0["key"] as? String == key })
  }
}
