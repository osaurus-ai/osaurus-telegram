import Foundation
import Testing

@testable import osaurus_telegram

@Suite("Plugin Manifest Contract")
struct ManifestContractTests {

  private enum ManifestError: Error {
    case entryPointFailed
    case nilManifest
    case invalidJSON
  }

  private struct PluginAPI {
    let freeString: (@convention(c) (UnsafePointer<CChar>?) -> Void)
    let initContext: (@convention(c) () -> UnsafeMutableRawPointer?)
    let destroy: (@convention(c) (UnsafeMutableRawPointer?) -> Void)
    let getManifest: (@convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?)
  }

  private func loadAPI() throws -> PluginAPI {
    guard let apiPtr = osaurus_plugin_entry() else {
      throw ManifestError.entryPointFailed
    }

    let fnPtrSize = MemoryLayout<UnsafeRawPointer?>.stride
    return PluginAPI(
      freeString: apiPtr.load(
        fromByteOffset: 0,
        as: (@convention(c) (UnsafePointer<CChar>?) -> Void).self),
      initContext: apiPtr.load(
        fromByteOffset: fnPtrSize,
        as: (@convention(c) () -> UnsafeMutableRawPointer?).self),
      destroy: apiPtr.load(
        fromByteOffset: fnPtrSize * 2,
        as: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self),
      getManifest: apiPtr.load(
        fromByteOffset: fnPtrSize * 3,
        as: (@convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?).self)
    )
  }

  private func loadManifest() throws -> [String: Any] {
    let api = try loadAPI()
    let ctx = api.initContext()
    defer { api.destroy(ctx) }

    guard let cStr = api.getManifest(ctx) else {
      throw ManifestError.nilManifest
    }
    let jsonString = String(cString: cStr)
    api.freeString(cStr)

    guard let data = jsonString.data(using: .utf8),
      let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw ManifestError.invalidJSON
    }
    return manifest
  }

  private func capabilities(from manifest: [String: Any]) -> [String: Any] {
    manifest["capabilities"] as? [String: Any] ?? [:]
  }

  private func toolMap(from manifest: [String: Any]) -> [String: [String: Any]] {
    let tools = capabilities(from: manifest)["tools"] as? [[String: Any]] ?? []
    return Dictionary(
      uniqueKeysWithValues: tools.compactMap { tool -> (String, [String: Any])? in
        guard let id = tool["id"] as? String else { return nil }
        return (id, tool)
      })
  }

  @Test("manifest has correct plugin identity and v2 routes")
  func pluginIdentityAndRoutes() throws {
    let manifest = try loadManifest()
    #expect(manifest["plugin_id"] as? String == "osaurus.telegram")
    #expect(manifest["version"] as? String == "0.1.0")

    let routes = capabilities(from: manifest)["routes"] as? [[String: Any]] ?? []
    let routeIDs = Set(routes.compactMap { $0["id"] as? String })
    #expect(routeIDs == ["webhook", "health"])

    let byID = Dictionary(uniqueKeysWithValues: routes.map { ($0["id"] as! String, $0) })
    #expect(byID["webhook"]?["auth"] as? String == "verify")
    #expect(byID["health"]?["auth"] as? String == "owner")
  }

  @Test("manifest declares expected Telegram tools")
  func toolIDs() throws {
    let map = try toolMap(from: loadManifest())
    #expect(
      Set(map.keys) == [
        "telegram_list_chats", "telegram_get_chat_history", "telegram_send",
        "telegram_send_file", "telegram_set_reaction",
      ])
  }

  @Test("message-sending tools declare required parameters")
  func requiredParameters() throws {
    let map = try toolMap(from: loadManifest())

    let sendParams = map["telegram_send"]?["parameters"] as? [String: Any]
    let sendRequired = Set(sendParams?["required"] as? [String] ?? [])
    #expect(sendRequired == ["chat_id", "text"])

    let fileParams = map["telegram_send_file"]?["parameters"] as? [String: Any]
    let fileRequired = Set(fileParams?["required"] as? [String] ?? [])
    #expect(fileRequired == ["chat_id", "file_path"])

    let reactionParams = map["telegram_set_reaction"]?["parameters"] as? [String: Any]
    let reactionRequired = Set(reactionParams?["required"] as? [String] ?? [])
    #expect(reactionRequired == ["chat_id", "message_id"])
  }

  @Test("configuration exposes auth, agent, upload, behavior, and prompt sections")
  func configSections() throws {
    let manifest = try loadManifest()
    let config = capabilities(from: manifest)["config"] as? [String: Any]
    let sections = config?["sections"] as? [[String: Any]] ?? []
    let titles = Set(sections.compactMap { $0["title"] as? String })
    #expect(
      titles == [
        "Bot Configuration", "Agent Settings", "File Upload", "Behavior", "Prompt Customization",
      ])
  }
}
