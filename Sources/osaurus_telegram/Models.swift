import Foundation

// MARK: - Telegram Types

struct TelegramUpdate: Decodable {
  let update_id: Int
  let message: TelegramMessage?
  let edited_message: TelegramMessage?
  let callback_query: TelegramCallbackQuery?
  let message_reaction: TelegramMessageReactionUpdated?
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
  let reply_to_message: TelegramReplyMessage?
}

struct TelegramChat: Decodable {
  let id: Int64
  let type: String
  let title: String?
  let username: String?
  let first_name: String?
}

struct TelegramReplyMessage: Decodable {
  let message_id: Int
}

struct TelegramUser: Decodable {
  let id: Int64
  let is_bot: Bool
  let first_name: String
  let last_name: String?
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

struct TelegramReactionType: Decodable {
  let type: String
  let emoji: String?
  let custom_emoji_id: String?
}

struct TelegramMessageReactionUpdated: Decodable {
  let chat: TelegramChat
  let message_id: Int
  let user: TelegramUser?
  let actor_chat: TelegramChat?
  let date: Int
  let old_reaction: [TelegramReactionType]
  let new_reaction: [TelegramReactionType]
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

// MARK: - Task Event Payloads

struct TaskActivityEvent: Decodable {
  let kind: String?
  let title: String?
  let detail: String?
  let timestamp: String?
  let metadata: [String: String]?
}

struct TaskProgressEvent: Decodable {
  let progress: Double?
  let current_step: String?
  let title: String?
}

struct TaskClarificationEvent: Decodable {
  let question: String?
  let options: [String]?
}

struct TaskCompletedEvent: Decodable {
  let success: Bool?
  let summary: String?
  let session_id: String?
  let output: String?
  let title: String?
}

struct TaskFailedEvent: Decodable {
  let success: Bool?
  let summary: String?
  let title: String?
}

struct TaskOutputEvent: Decodable {
  let text: String?
  let title: String?
}

/// Payload for `OSR_TASK_EVENT_DRAFT`. The host nests `text` and `parse_mode`
/// under a `draft` object (see Osaurus PLUGIN_AUTHORING.md, Draft section).
struct TaskDraftPayload: Decodable {
  let text: String?
  let parse_mode: String?
}

struct TaskDraftEvent: Decodable {
  let title: String?
  let draft: TaskDraftPayload?
}

/// Single artifact entry in `complete` / `complete_stream` `shared_artifacts` array.
struct SharedArtifact: Decodable {
  let filename: String
  let host_path: String?
  let mime_type: String?
  let size: Int?
  let is_directory: Bool?
  let description: String?
}

struct CompletionResultEnvelope: Decodable {
  let shared_artifacts: [SharedArtifact]?
  let error: String?
}

// MARK: - Artifact Payload

struct ArtifactPayload: Decodable {
  let filename: String
  let host_path: String
  let mime_type: String?
  let size: Int?
  let is_directory: Bool?
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
  let clarificationOptions: String?
  let userId: String?
}

// MARK: - Streaming Chunk (OpenAI-compatible, agentic)

struct StreamToolCallFunction: Decodable {
  let name: String?
  let arguments: String?
}

struct StreamToolCall: Decodable {
  let id: String?
  let function: StreamToolCallFunction?
}

struct StreamChunkDelta: Decodable {
  let content: String?
  let tool_calls: [StreamToolCall]?
  let role: String?
  let tool_call_id: String?
}

struct StreamChunkChoice: Decodable {
  let delta: StreamChunkDelta?
  let finish_reason: String?
}

struct StreamChunk: Decodable {
  let choices: [StreamChunkChoice]?
}
