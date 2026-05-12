import Foundation

// MARK: - Telegram Update (minimal)
//
// Fields we actually consume — decoder is forgiving so unknown keys are
// silently dropped (Telegram's payload is huge and most fields are
// irrelevant to a chat-bridge plugin). Decode failures here are fatal:
// the webhook handler treats them as "non-actionable" and 200-OKs so
// Telegram doesn't retry.

struct TGUpdate: Decodable {
  /// Message entity. Telegram annotates `text` / `caption` ranges with
  /// these; we only care about the `mention` / `text_mention` types so
  /// the group-chat gate can detect when the bot is being addressed.
  struct MessageEntity: Decodable {
    let type: String
    let offset: Int
    let length: Int
    let user: From?
  }

  /// User reference. `id` is the canonical identifier (numeric, never
  /// changes). `username` is the handle without `@` and CAN change /
  /// be deleted, so the allowlist matches case-insensitively and the
  /// per-user session keying always prefers `id`.
  struct From: Decodable {
    let id: Int64?
    let username: String?
    let first_name: String?
    let is_bot: Bool?
  }

  /// Chat reference. `type` is "private" / "group" / "supergroup" /
  /// "channel"; we treat group + supergroup identically and drop
  /// channel posts entirely (we don't subscribe to them anyway).
  struct Chat: Decodable {
    let id: Int64
    let type: String?
    let title: String?
  }

  /// Reply target reference — only the `from.id` is needed so the
  /// mention/reply gate can recognise replies-to-the-bot. We decode the
  /// full nested message just enough to reach `from.id`.
  struct ReplyToMessage: Decodable {
    let message_id: Int64?
    let from: From?
  }

  /// Photo size variant. Telegram returns an array of progressively
  /// larger sizes for each photo; we always take the largest one (last
  /// in the array) and pull its bytes via getFile.
  struct PhotoSize: Decodable {
    let file_id: String
    let file_unique_id: String?
    let width: Int?
    let height: Int?
    let file_size: Int?
  }

  /// Document attachment (catch-all for non-image/audio uploads).
  struct Document: Decodable {
    let file_id: String
    let file_unique_id: String?
    let file_name: String?
    let mime_type: String?
    let file_size: Int?
  }

  /// Voice note (always ogg/opus per Telegram spec).
  struct Voice: Decodable {
    let file_id: String
    let file_unique_id: String?
    let duration: Int?
    let mime_type: String?
    let file_size: Int?
  }

  /// Audio (music) attachment.
  struct Audio: Decodable {
    let file_id: String
    let file_unique_id: String?
    let duration: Int?
    let performer: String?
    let title: String?
    let file_name: String?
    let mime_type: String?
    let file_size: Int?
  }

  /// Video attachment.
  struct Video: Decodable {
    let file_id: String
    let file_unique_id: String?
    let width: Int?
    let height: Int?
    let duration: Int?
    let mime_type: String?
    let file_name: String?
    let file_size: Int?
  }

  /// Animation (GIF / silent video). Telegram delivers GIFs via this
  /// field, not `video`.
  struct Animation: Decodable {
    let file_id: String
    let file_unique_id: String?
    let mime_type: String?
    let file_name: String?
    let duration: Int?
    let file_size: Int?
  }

  struct Message: Decodable {
    let message_id: Int64
    let date: Int?
    let chat: Chat
    let from: From?
    let text: String?
    let caption: String?
    let entities: [MessageEntity]?
    let caption_entities: [MessageEntity]?
    let reply_to_message: ReplyToMessage?
    // Media — at most one of these is set per message.
    let photo: [PhotoSize]?
    let document: Document?
    let voice: Voice?
    let audio: Audio?
    let video: Video?
    let animation: Animation?
  }

  /// Inline keyboard button press. Telegram delivers this on a separate
  /// update field (`callback_query`); we synthesize a user turn so the
  /// agent can react via the same reply pipeline.
  struct CallbackQuery: Decodable {
    let id: String
    let from: From?
    let message: Message?
    let data: String?
    let chat_instance: String?
  }

  let update_id: Int
  let message: Message?
  let edited_message: Message?
  let callback_query: CallbackQuery?
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
