import Foundation

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
