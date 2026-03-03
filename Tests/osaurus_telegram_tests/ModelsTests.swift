import Foundation
import Testing

@testable import osaurus_telegram

// MARK: - TelegramUpdate Decoding

@Suite("Telegram Update Decoding")
struct TelegramUpdateTests {

  @Test("Decodes a text message update")
  func textMessageUpdate() throws {
    let json = """
      {
        "update_id": 100,
        "message": {
          "message_id": 1,
          "from": { "id": 42, "is_bot": false, "first_name": "Alice", "username": "alice" },
          "chat": { "id": 42, "type": "private", "first_name": "Alice", "username": "alice" },
          "date": 1700000000,
          "text": "Hello bot"
        }
      }
      """
    let update = try #require(parseJSON(json, as: TelegramUpdate.self))
    #expect(update.update_id == 100)
    #expect(update.callback_query == nil)

    let msg = try #require(update.message)
    #expect(msg.message_id == 1)
    #expect(msg.text == "Hello bot")
    #expect(msg.chat.id == 42)
    #expect(msg.chat.type == "private")
    #expect(msg.from?.first_name == "Alice")
    #expect(msg.from?.username == "alice")
    #expect(msg.from?.is_bot == false)
  }

  @Test("Decodes a callback query update")
  func callbackQueryUpdate() throws {
    let json = """
      {
        "update_id": 200,
        "callback_query": {
          "id": "cb123",
          "from": { "id": 42, "is_bot": false, "first_name": "Alice" },
          "message": {
            "message_id": 10,
            "chat": { "id": 42, "type": "private" },
            "date": 1700000000,
            "text": "Pick one"
          },
          "data": "clarify:task-abc:0"
        }
      }
      """
    let update = try #require(parseJSON(json, as: TelegramUpdate.self))
    #expect(update.message == nil)

    let cb = try #require(update.callback_query)
    #expect(cb.id == "cb123")
    #expect(cb.data == "clarify:task-abc:0")
    #expect(cb.from.id == 42)
    #expect(cb.message?.message_id == 10)
  }

  @Test("Decodes an update with no message or callback")
  func emptyUpdate() throws {
    let json = """
      { "update_id": 300 }
      """
    let update = try #require(parseJSON(json, as: TelegramUpdate.self))
    #expect(update.message == nil)
    #expect(update.callback_query == nil)
  }
}

// MARK: - TelegramMessage Decoding

@Suite("Telegram Message Decoding")
struct TelegramMessageTests {

  @Test("Decodes a photo message")
  func photoMessage() throws {
    let json = """
      {
        "message_id": 5,
        "chat": { "id": -100123, "type": "supergroup", "title": "My Group" },
        "date": 1700000000,
        "photo": [
          { "file_id": "small", "file_unique_id": "s1", "width": 90, "height": 90 },
          { "file_id": "large", "file_unique_id": "l1", "width": 800, "height": 600, "file_size": 50000 }
        ],
        "caption": "Check this out"
      }
      """
    let msg = try #require(parseJSON(json, as: TelegramMessage.self))
    #expect(msg.message_id == 5)
    #expect(msg.text == nil)
    #expect(msg.caption == "Check this out")
    #expect(msg.chat.type == "supergroup")
    #expect(msg.chat.title == "My Group")
    #expect(msg.chat.id == -100123)

    let photos = try #require(msg.photo)
    #expect(photos.count == 2)
    #expect(photos.last?.file_id == "large")
    #expect(photos.last?.width == 800)
  }

  @Test("Decodes a document message")
  func documentMessage() throws {
    let json = """
      {
        "message_id": 6,
        "chat": { "id": 42, "type": "private" },
        "date": 1700000000,
        "document": {
          "file_id": "doc123",
          "file_unique_id": "du123",
          "file_name": "report.pdf",
          "mime_type": "application/pdf",
          "file_size": 12345
        }
      }
      """
    let msg = try #require(parseJSON(json, as: TelegramMessage.self))
    let doc = try #require(msg.document)
    #expect(doc.file_id == "doc123")
    #expect(doc.file_name == "report.pdf")
    #expect(doc.mime_type == "application/pdf")
  }

  @Test("Decodes a voice message")
  func voiceMessage() throws {
    let json = """
      {
        "message_id": 7,
        "chat": { "id": 42, "type": "private" },
        "date": 1700000000,
        "voice": {
          "file_id": "voice123",
          "file_unique_id": "vu123",
          "duration": 15,
          "mime_type": "audio/ogg"
        }
      }
      """
    let msg = try #require(parseJSON(json, as: TelegramMessage.self))
    let voice = try #require(msg.voice)
    #expect(voice.file_id == "voice123")
    #expect(voice.duration == 15)
  }

  @Test("Decodes a group chat message")
  func groupChat() throws {
    let json = """
      {
        "message_id": 8,
        "from": { "id": 42, "is_bot": false, "first_name": "Bob" },
        "chat": { "id": -1001234567, "type": "supergroup", "title": "Dev Team" },
        "date": 1700000000,
        "text": "Hello group"
      }
      """
    let msg = try #require(parseJSON(json, as: TelegramMessage.self))
    #expect(msg.chat.id == -1_001_234_567)
    #expect(msg.chat.type == "supergroup")
    #expect(msg.chat.title == "Dev Team")
    #expect(msg.from?.first_name == "Bob")
  }
}

// MARK: - Task Event Payloads

@Suite("Task Event Payload Decoding")
struct TaskEventPayloadTests {

  @Test("Decodes TaskCompletedEvent")
  func completedEvent() throws {
    let json = "{\"success\":true,\"summary\":\"Done!\",\"session_id\":\"sess-1\"}"
    let event = try #require(parseJSON(json, as: TaskCompletedEvent.self))
    #expect(event.success == true)
    #expect(event.summary == "Done!")
    #expect(event.session_id == "sess-1")
  }

  @Test("Decodes TaskFailedEvent")
  func failedEvent() throws {
    let json = "{\"success\":false,\"summary\":\"Something went wrong\"}"
    let event = try #require(parseJSON(json, as: TaskFailedEvent.self))
    #expect(event.success == false)
    #expect(event.summary == "Something went wrong")
  }

  @Test("Decodes TaskProgressEvent")
  func progressEvent() throws {
    let json = "{\"progress\":0.75,\"current_step\":\"Analyzing files\"}"
    let event = try #require(parseJSON(json, as: TaskProgressEvent.self))
    #expect(event.progress == 0.75)
    #expect(event.current_step == "Analyzing files")
  }

  @Test("Decodes TaskClarificationEvent")
  func clarificationEvent() throws {
    let json = "{\"question\":\"Which option?\",\"options\":[\"A\",\"B\",\"C\"]}"
    let event = try #require(parseJSON(json, as: TaskClarificationEvent.self))
    #expect(event.question == "Which option?")
    #expect(event.options?.count == 3)
    #expect(event.options?[0] == "A")
  }

  @Test("Decodes TaskActivityEvent")
  func activityEvent() throws {
    let json = "{\"kind\":\"tool_call\",\"title\":\"Reading file\",\"detail\":\"src/main.swift\"}"
    let event = try #require(parseJSON(json, as: TaskActivityEvent.self))
    #expect(event.kind == "tool_call")
    #expect(event.title == "Reading file")
    #expect(event.detail == "src/main.swift")
  }

  @Test("Decodes TaskOutputEvent")
  func outputEvent() throws {
    let json = "{\"text\":\"Here are the results:\\n\\n1. First item\"}"
    let event = try #require(parseJSON(json, as: TaskOutputEvent.self))
    #expect(event.text == "Here are the results:\n\n1. First item")
  }

  @Test("Decodes TaskOutputEvent with null text")
  func outputEventNullText() throws {
    let event = try #require(parseJSON("{}", as: TaskOutputEvent.self))
    #expect(event.text == nil)
  }

  @Test("Handles missing optional fields gracefully")
  func missingOptionals() throws {
    let event = try #require(parseJSON("{}", as: TaskCompletedEvent.self))
    #expect(event.success == nil)
    #expect(event.summary == nil)
  }
}

// MARK: - RouteRequest Decoding

@Suite("Route Request Decoding")
struct RouteRequestTests {

  @Test("Decodes a full webhook route request")
  func webhookRouteRequest() throws {
    let json = """
      {
        "route_id": "webhook",
        "method": "POST",
        "path": "/webhook",
        "headers": {
          "x-telegram-bot-api-secret-token": "abc123",
          "content-type": "application/json"
        },
        "body": "{\\"update_id\\":1}",
        "plugin_id": "osaurus.telegram"
      }
      """
    let req = try #require(parseJSON(json, as: RouteRequest.self))
    #expect(req.route_id == "webhook")
    #expect(req.method == "POST")
    #expect(req.headers?["x-telegram-bot-api-secret-token"] == "abc123")
    #expect(req.body != nil)
    #expect(req.plugin_id == "osaurus.telegram")
  }

  @Test("Decodes a health check request with minimal fields")
  func healthRequest() throws {
    let json = """
      { "route_id": "health", "method": "GET", "path": "/health" }
      """
    let req = try #require(parseJSON(json, as: RouteRequest.self))
    #expect(req.route_id == "health")
    #expect(req.headers == nil)
    #expect(req.body == nil)
  }
}

// MARK: - StreamChunk Decoding

@Suite("Stream Chunk Decoding")
struct StreamChunkTests {

  @Test("Decodes an OpenAI-compatible streaming chunk")
  func decodesChunk() throws {
    let json = "{\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}"
    let chunk = try #require(parseJSON(json, as: StreamChunk.self))
    #expect(chunk.choices?.count == 1)
    #expect(chunk.choices?.first?.delta?.content == "Hello")
  }

  @Test("Handles chunk with empty content")
  func emptyContent() throws {
    let json = "{\"choices\":[{\"delta\":{\"content\":\"\"}}]}"
    let chunk = try #require(parseJSON(json, as: StreamChunk.self))
    #expect(chunk.choices?.first?.delta?.content == "")
  }

  @Test("Handles chunk with no delta content (role-only)")
  func roleDelta() throws {
    let json = "{\"choices\":[{\"delta\":{}}]}"
    let chunk = try #require(parseJSON(json, as: StreamChunk.self))
    #expect(chunk.choices?.first?.delta?.content == nil)
  }

  @Test("Handles chunk with no choices")
  func noChoices() throws {
    let json = "{}"
    let chunk = try #require(parseJSON(json, as: StreamChunk.self))
    #expect(chunk.choices == nil)
  }

  @Test("Decodes a tool call chunk")
  func toolCallChunk() throws {
    let json = """
      {"choices":[{"delta":{"tool_calls":[{"id":"call_abc","function":{"name":"file_read","arguments":"{\\"path\\":\\"main.swift\\"}"}}]},"finish_reason":"tool_calls"}]}
      """
    let chunk = try #require(parseJSON(json, as: StreamChunk.self))
    let choice = try #require(chunk.choices?.first)
    #expect(choice.finish_reason == "tool_calls")
    let toolCall = try #require(choice.delta?.tool_calls?.first)
    #expect(toolCall.id == "call_abc")
    #expect(toolCall.function?.name == "file_read")
    #expect(toolCall.function?.arguments?.contains("main.swift") == true)
    #expect(choice.delta?.content == nil)
  }

  @Test("Decodes a tool result chunk")
  func toolResultChunk() throws {
    let json = """
      {"choices":[{"delta":{"role":"tool","tool_call_id":"call_abc","content":"file contents here"}}]}
      """
    let chunk = try #require(parseJSON(json, as: StreamChunk.self))
    let delta = try #require(chunk.choices?.first?.delta)
    #expect(delta.role == "tool")
    #expect(delta.tool_call_id == "call_abc")
    #expect(delta.content == "file contents here")
  }

  @Test("Decodes a final stop chunk with finish_reason")
  func stopChunk() throws {
    let json = "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}"
    let chunk = try #require(parseJSON(json, as: StreamChunk.self))
    let choice = try #require(chunk.choices?.first)
    #expect(choice.finish_reason == "stop")
    #expect(choice.delta?.content == nil)
    #expect(choice.delta?.tool_calls == nil)
  }

  @Test("Content chunk has nil tool fields")
  func contentChunkNilTools() throws {
    let json = "{\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}"
    let chunk = try #require(parseJSON(json, as: StreamChunk.self))
    let delta = try #require(chunk.choices?.first?.delta)
    #expect(delta.content == "Hello")
    #expect(delta.tool_calls == nil)
    #expect(delta.role == nil)
    #expect(delta.tool_call_id == nil)
  }
}

// MARK: - DispatchResponse Decoding

@Suite("Dispatch Response Decoding")
struct DispatchResponseTests {

  @Test("Decodes a dispatch result")
  func decodeResult() throws {
    let json = "{\"id\":\"task-uuid-123\",\"status\":\"running\"}"
    let resp = try #require(parseJSON(json, as: DispatchResponse.self))
    #expect(resp.id == "task-uuid-123")
    #expect(resp.status == "running")
  }

  @Test("Handles missing fields")
  func missingFields() throws {
    let resp = try #require(parseJSON("{}", as: DispatchResponse.self))
    #expect(resp.id == nil)
    #expect(resp.status == nil)
  }
}
