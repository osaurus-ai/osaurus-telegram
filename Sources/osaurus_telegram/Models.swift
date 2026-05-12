import Foundation

// MARK: - Telegram Update (minimal)

struct TGUpdate: Decodable {
  struct Message: Decodable {
    struct Chat: Decodable {
      let id: Int64
    }
    struct From: Decodable {
      let username: String?
      let first_name: String?
    }
    let chat: Chat
    let from: From?
    let text: String?
    let message_id: Int64
  }
  let update_id: Int
  let message: Message?
}

// MARK: - Route Request/Response

struct OsaurusRequestContext: Decodable {
  let base_url: String?
  let plugin_url: String?
  let agent_address: String?
}

struct RouteRequest: Decodable {
  let route_id: String
  let method: String
  let path: String
  let query: [String: String]?
  let headers: [String: String]?
  let body: String?
  let plugin_id: String?
  let osaurus: OsaurusRequestContext?
}

// MARK: - Dispatch Response

struct DispatchResponse: Decodable {
  let id: String?
  let status: String?
  let error: String?
}

// MARK: - Artifact Share Payload

/// Payload the host hands us via `invoke(type: "artifact", id: "share", ...)`
/// when an agent writes a file into `~/.osaurus/artifacts/`. There is no
/// chat or task identifier in this payload — routing back to a Telegram
/// chat is the plugin's responsibility (we use the most recent in-flight
/// dispatch for the agent).
///
/// The host's exact field names for this payload are not pinned anywhere
/// we control; in practice we've seen both `host_path` and `hostPath`
/// (and similar variants for `mime_type` / `is_directory`). Tolerate the
/// common casings via a custom `init(from:)` so a casing change in the
/// host doesn't silently kill artifact auto-forwarding for every user.
struct ArtifactPayload: Decodable {
  let filename: String
  let host_path: String
  let mime_type: String?
  let size: Int?
  let is_directory: Bool?

  private enum CodingKeys: String, CodingKey {
    case filename
    case host_path
    case hostPath
    case mime_type
    case mimeType
    case size
    case is_directory
    case isDirectory
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.filename = try c.decode(String.self, forKey: .filename)
    if let hp = try c.decodeIfPresent(String.self, forKey: .host_path) {
      self.host_path = hp
    } else if let hp = try c.decodeIfPresent(String.self, forKey: .hostPath) {
      self.host_path = hp
    } else {
      throw DecodingError.keyNotFound(
        CodingKeys.host_path,
        .init(
          codingPath: c.codingPath,
          debugDescription: "Missing host_path / hostPath"))
    }
    let mimeSnake = try c.decodeIfPresent(String.self, forKey: .mime_type)
    let mimeCamel = try c.decodeIfPresent(String.self, forKey: .mimeType)
    self.mime_type = mimeSnake ?? mimeCamel
    self.size = try c.decodeIfPresent(Int.self, forKey: .size)
    let dirSnake = try c.decodeIfPresent(Bool.self, forKey: .is_directory)
    let dirCamel = try c.decodeIfPresent(Bool.self, forKey: .isDirectory)
    self.is_directory = dirSnake ?? dirCamel
  }
}
