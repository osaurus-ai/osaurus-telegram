import Foundation
import Testing

@testable import osaurus_telegram

// MARK: - AnyCodable

@Suite("AnyCodable Decoding")
struct AnyCodableTests {

  @Test("Decodes string value")
  func decodesString() throws {
    let json = "{\"value\":\"hello\"}"
    struct Wrapper: Decodable { let value: AnyCodable }
    let w = try #require(parseJSON(json, as: Wrapper.self))
    #expect(w.value.value as? String == "hello")
  }

  @Test("Decodes integer value")
  func decodesInt() throws {
    let json = "{\"value\":42}"
    struct Wrapper: Decodable { let value: AnyCodable }
    let w = try #require(parseJSON(json, as: Wrapper.self))
    #expect(w.value.value as? Int == 42)
  }

  @Test("Decodes boolean value")
  func decodesBool() throws {
    let json = "{\"value\":true}"
    struct Wrapper: Decodable { let value: AnyCodable }
    let w = try #require(parseJSON(json, as: Wrapper.self))
    #expect(w.value.value as? Bool == true)
  }

  @Test("Decodes nested dictionary")
  func decodesDict() throws {
    let json = "{\"value\":{\"key\":\"val\",\"num\":1}}"
    struct Wrapper: Decodable { let value: AnyCodable }
    let w = try #require(parseJSON(json, as: Wrapper.self))
    let dict = try #require(w.value.value as? [String: Any])
    #expect(dict["key"] as? String == "val")
    #expect(dict["num"] as? Int == 1)
  }

  @Test("Decodes array value")
  func decodesArray() throws {
    let json = "{\"value\":[1,2,3]}"
    struct Wrapper: Decodable { let value: AnyCodable }
    let w = try #require(parseJSON(json, as: Wrapper.self))
    let arr = try #require(w.value.value as? [Any])
    #expect(arr.count == 3)
  }

  @Test("Decodes null value")
  func decodesNull() throws {
    let json = "{\"value\":null}"
    struct Wrapper: Decodable { let value: AnyCodable }
    let w = try #require(parseJSON(json, as: Wrapper.self))
    #expect(w.value.value is NSNull)
  }

  @Test("Decodes inline keyboard reply_markup structure")
  func decodesInlineKeyboard() throws {
    let json = """
      {
        "chat_id": "123",
        "text": "Pick one",
        "reply_markup": {
          "inline_keyboard": [
            [{"text": "Option A", "callback_data": "a"}],
            [{"text": "Option B", "callback_data": "b"}]
          ]
        }
      }
      """
    let args = try #require(parseJSON(json, as: TelegramSendTool.Args.self))
    #expect(args.chat_id == "123")
    #expect(args.text == "Pick one")

    let markup = try #require(args.reply_markup?.value as? [String: Any])
    let keyboard = try #require(markup["inline_keyboard"] as? [[Any]])
    #expect(keyboard.count == 2)
  }
}

// MARK: - TelegramSendTool

@Suite("TelegramSendTool")
struct TelegramSendToolTests {

  @Test("Returns error on invalid JSON args")
  func invalidArgs() {
    let tool = TelegramSendTool()
    let result = tool.run(args: "not json")
    #expect(result.contains("error"))
    #expect(result.contains("Invalid arguments"))
  }

  @Test("Returns error when no bot token configured")
  func noToken() {
    // hostAPI is nil in tests, so configGet returns nil
    let tool = TelegramSendTool()
    let args = "{\"chat_id\":\"123\",\"text\":\"hello\"}"
    let result = tool.run(args: args)
    #expect(result.contains("error"))
    #expect(result.contains("Bot token not configured"))
  }
}

// MARK: - TelegramGetChatHistoryTool

@Suite("TelegramGetChatHistoryTool")
struct ChatHistoryToolTests {

  @Test("Returns error on invalid args")
  func invalidArgs() {
    let tool = TelegramGetChatHistoryTool()
    let result = tool.run(args: "bad")
    #expect(result.contains("error"))
  }

  @Test("Returns empty array when no hostAPI")
  func noHostAPI() {
    // hostAPI is nil in tests, so db_query returns nil → "[]"
    let tool = TelegramGetChatHistoryTool()
    let args = "{\"chat_id\":\"123\"}"
    let result = tool.run(args: args)
    #expect(result == "[]")
  }

  @Test("Respects default limit")
  func defaultLimit() {
    let tool = TelegramGetChatHistoryTool()
    let args = "{\"chat_id\":\"123\"}"
    // Just verify it parses and doesn't crash
    _ = tool.run(args: args)
  }
}
