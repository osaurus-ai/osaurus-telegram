import Foundation

// MARK: - Telegram Types

struct TelegramUpdate: Decodable {
  let update_id: Int
  let message: TelegramMessage?
  let edited_message: TelegramMessage?
  let callback_query: TelegramCallbackQuery?
}

struct TelegramMessage: Decodable {
  let message_id: Int
  let from: TelegramUser?
  let chat: TelegramChat
  let date: Int
  let text: String?
  let caption: String?
  let photo: [TelegramPhotoSize]?
  let document: TelegramDocument?
  let voice: TelegramVoice?
}

struct TelegramChat: Decodable {
  let id: Int64
  let type: String
  let title: String?
  let username: String?
  let first_name: String?
}

struct TelegramUser: Decodable {
  let id: Int64
  let is_bot: Bool
  let first_name: String
  let username: String?
}

struct TelegramPhotoSize: Decodable {
  let file_id: String
  let file_unique_id: String
  let width: Int
  let height: Int
  let file_size: Int?
}

struct TelegramDocument: Decodable {
  let file_id: String
  let file_unique_id: String
  let file_name: String?
  let mime_type: String?
  let file_size: Int?
}

struct TelegramVoice: Decodable {
  let file_id: String
  let file_unique_id: String
  let duration: Int
  let mime_type: String?
  let file_size: Int?
}

struct TelegramCallbackQuery: Decodable {
  let id: String
  let from: TelegramUser
  let message: TelegramMessage?
  let data: String?
}

// MARK: - Route Request/Response

struct RouteRequest: Decodable {
  let route_id: String
  let method: String
  let path: String
  let query: [String: String]?
  let headers: [String: String]?
  let body: String?
  let plugin_id: String?
}

// MARK: - Task Event Payloads

struct TaskActivityEvent: Decodable {
  let kind: String?
  let title: String?
  let detail: String?
  let timestamp: String?
}

struct TaskProgressEvent: Decodable {
  let progress: Double?
  let current_step: String?
}

struct TaskClarificationEvent: Decodable {
  let question: String?
  let options: [String]?
}

struct TaskCompletedEvent: Decodable {
  let success: Bool?
  let summary: String?
  let session_id: String?
}

struct TaskFailedEvent: Decodable {
  let success: Bool?
  let summary: String?
}

// MARK: - Dispatch Response

struct DispatchResponse: Decodable {
  let id: String?
  let status: String?
}

// MARK: - DB Row Helpers

struct TaskRow {
  let taskId: String
  let chatId: String
  let messageId: Int?
  let status: String
  let statusMsgId: Int?
  let summary: String?
  let chatType: String
}

// MARK: - Streaming Chunk (OpenAI-compatible)

struct StreamChunkDelta: Decodable {
  let content: String?
}

struct StreamChunkChoice: Decodable {
  let delta: StreamChunkDelta?
}

struct StreamChunk: Decodable {
  let choices: [StreamChunkChoice]?
}
