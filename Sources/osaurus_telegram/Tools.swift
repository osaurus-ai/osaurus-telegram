import Foundation

// MARK: - telegram_list_chats Tool

struct TelegramListChatsTool {
  let name = "telegram_list_chats"

  struct Args: Decodable {
    let username: String?
    let chat_type: String?
  }

  func run(args: String) -> String {
    logDebug("telegram_list_chats: args=\(String(args.prefix(200)))")
    let input = parseJSON(args, as: Args.self)

    let chats = DatabaseManager.getChats(
      username: input?.username, chatType: input?.chat_type)
    logDebug("telegram_list_chats: found \(chats.count) chats")

    var result: [String: Any] = ["chats": chats]

    if chats.isEmpty, let username = input?.username, !username.isEmpty {
      if let user = DatabaseManager.getUserByUsername(username) {
        var resolved = user
        resolved["note"] =
          "No active chat found. You can try using this user_id as chat_id -- it will work if the user has previously started a conversation with the bot."
        result["resolved_user"] = resolved
        logDebug("telegram_list_chats: resolved user fallback for @\(username)")
      }
    }

    guard let data = try? JSONSerialization.data(withJSONObject: result),
      let json = String(data: data, encoding: .utf8)
    else {
      return "{\"chats\":[]}"
    }
    return json
  }
}

// MARK: - telegram_get_chat_history Tool

struct TelegramGetChatHistoryTool {
  let name = "telegram_get_chat_history"

  struct Args: Decodable {
    let chat_id: String
    let limit: Int?
  }

  func run(args: String) -> String {
    logDebug("telegram_get_chat_history: args=\(String(args.prefix(200)))")
    guard let input = parseJSON(args, as: Args.self) else {
      logWarn("telegram_get_chat_history: failed to parse args")
      return "{\"error\":\"Invalid arguments\"}"
    }

    let limit = input.limit ?? 50
    logDebug("telegram_get_chat_history: chat_id=\(input.chat_id) limit=\(limit)")
    let result = DatabaseManager.getMessages(chatId: input.chat_id, limit: limit)
    logDebug("telegram_get_chat_history: returned \(result.count) chars")
    return result
  }
}

// MARK: - telegram_send Tool

struct TelegramSendTool {
  let name = "telegram_send"

  struct Args: Decodable {
    let chat_id: String
    let text: String
    let reply_to_message_id: Int?
    let reply_markup: AnyCodable?
  }

  func run(args: String) -> String {
    logDebug("telegram_send: args=\(String(args.prefix(200)))")
    guard let input = parseJSON(args, as: Args.self) else {
      logWarn("telegram_send: failed to parse args")
      return "{\"error\":\"Invalid arguments\"}"
    }

    logDebug(
      "telegram_send: chat_id=\(input.chat_id) text=\(input.text.count) chars replyTo=\(input.reply_to_message_id.map { "\($0)" } ?? "nil")"
    )

    guard let token = configGet("bot_token"), !token.isEmpty else {
      logWarn("telegram_send: no bot token configured")
      return "{\"error\":\"Bot token not configured\"}"
    }

    guard
      let msgId = telegramSendLongMessage(
        token: token,
        chatId: input.chat_id,
        text: input.text,
        replyTo: input.reply_to_message_id
      )
    else {
      logError("telegram_send: failed to send message to chat \(input.chat_id)")
      return "{\"error\":\"Failed to send message\"}"
    }

    DatabaseManager.insertMessage(
      chatId: input.chat_id,
      messageId: msgId,
      direction: "out",
      senderId: nil,
      senderName: "Agent",
      text: input.text,
      mediaType: nil,
      mediaFileId: nil,
      taskId: nil
    )

    logDebug("telegram_send: sent message_id=\(msgId) to chat \(input.chat_id)")
    return "{\"message_id\":\(msgId)}"
  }
}

// MARK: - telegram_send_file Tool

struct TelegramSendFileTool {
  let name = "telegram_send_file"

  struct Args: Decodable {
    let chat_id: String
    let file_path: String
    let caption: String?
    let reply_to_message_id: Int?
  }

  func run(args: String) -> String {
    logDebug("telegram_send_file: args=\(String(args.prefix(200)))")
    guard let input = parseJSON(args, as: Args.self) else {
      logWarn("telegram_send_file: failed to parse args")
      return "{\"error\":\"Invalid arguments\"}"
    }

    guard let token = configGet("bot_token"), !token.isEmpty else {
      logWarn("telegram_send_file: no bot token configured")
      return "{\"error\":\"Bot token not configured\"}"
    }

    let file: HostFileResult
    switch readHostFile(path: input.file_path) {
    case .success(let f):
      file = f
    case .failure(let error):
      logError("telegram_send_file: \(error)")
      return "{\"error\":\"Failed to read file\"}"
    }

    let filename = (input.file_path as NSString).lastPathComponent
    logDebug(
      "telegram_send_file: read \(file.data.count) bytes, mime=\(file.mimeType), filename=\(filename)"
    )

    guard
      let result = uploadFileToTelegram(
        token: token, chatId: input.chat_id,
        fileData: file.data, filename: filename, mimeType: file.mimeType,
        caption: input.caption, replyTo: input.reply_to_message_id)
    else {
      logError("telegram_send_file: failed to upload to chat \(input.chat_id)")
      return "{\"error\":\"Failed to upload file\"}"
    }

    DatabaseManager.insertMessage(
      chatId: input.chat_id,
      messageId: result.messageId,
      direction: "out",
      senderId: nil,
      senderName: "Agent",
      text: input.caption,
      mediaType: result.isPhoto ? "photo" : "document",
      mediaFileId: nil,
      taskId: nil
    )

    logDebug(
      "telegram_send_file: uploaded message_id=\(result.messageId) to chat \(input.chat_id)")
    return "{\"message_id\":\(result.messageId)}"
  }
}

// MARK: - AnyCodable Helper

/// A type-erased Codable wrapper for handling arbitrary JSON (e.g. reply_markup).
struct AnyCodable: Decodable {
  let value: Any

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()

    if container.decodeNil() {
      value = NSNull()
    } else if let b = try? container.decode(Bool.self) {
      value = b
    } else if let i = try? container.decode(Int.self) {
      value = i
    } else if let d = try? container.decode(Double.self) {
      value = d
    } else if let s = try? container.decode(String.self) {
      value = s
    } else if let arr = try? container.decode([AnyCodable].self) {
      value = arr.map { $0.value }
    } else if let dict = try? container.decode([String: AnyCodable].self) {
      value = dict.mapValues { $0.value }
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Unsupported JSON value")
    }
  }
}
