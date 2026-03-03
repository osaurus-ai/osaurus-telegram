import Foundation
import Testing

@testable import osaurus_telegram

// MARK: - escapeMarkdownV2

@Suite("MarkdownV2 Escaping")
struct EscapeMarkdownV2Tests {

  @Test("Escapes all special characters")
  func escapesSpecialChars() {
    let input =
      "Hello_world *bold* [link](url) ~strike~ `code` >quote #tag +plus -minus =eq |pipe {brace} .dot !bang"
    let escaped = escapeMarkdownV2(input)
    #expect(escaped.contains("\\_"))
    #expect(escaped.contains("\\*"))
    #expect(escaped.contains("\\["))
    #expect(escaped.contains("\\]"))
    #expect(escaped.contains("\\("))
    #expect(escaped.contains("\\)"))
    #expect(escaped.contains("\\~"))
    #expect(escaped.contains("\\>"))
    #expect(escaped.contains("\\#"))
    #expect(escaped.contains("\\+"))
    #expect(escaped.contains("\\-"))
    #expect(escaped.contains("\\="))
    #expect(escaped.contains("\\|"))
    #expect(escaped.contains("\\{"))
    #expect(escaped.contains("\\}"))
    #expect(escaped.contains("\\."))
    #expect(escaped.contains("\\!"))
  }

  @Test("Preserves text without special characters")
  func noSpecialChars() {
    let input = "Hello world 123"
    #expect(escapeMarkdownV2(input) == "Hello world 123")
  }

  @Test("Preserves inline code spans")
  func preservesInlineCode() {
    let input = "Use `foo_bar` here"
    let escaped = escapeMarkdownV2(input)
    #expect(escaped.contains("`foo_bar`"))
    #expect(!escaped.contains("`foo\\_bar`"))
  }

  @Test("Preserves fenced code blocks")
  func preservesCodeBlocks() {
    let input = "Before ```let x = 1 + 2``` after"
    let escaped = escapeMarkdownV2(input)
    // The code block content is passed through verbatim (no escaping of +)
    #expect(escaped.contains("```let x = 1 + 2```"))
    // Text outside the code block IS escaped
    #expect(!escaped.contains("\\+"))  // no + outside the code block
  }

  @Test("Handles empty string")
  func emptyString() {
    #expect(escapeMarkdownV2("") == "")
  }

  @Test("Handles string of only special chars")
  func onlySpecial() {
    let escaped = escapeMarkdownV2("_*")
    #expect(escaped == "\\_\\*")
  }
}

// MARK: - splitMessage

@Suite("Message Splitting")
struct SplitMessageTests {

  @Test("Returns single chunk for short text")
  func shortText() {
    let text = "Hello world"
    let chunks = splitMessage(text, maxLength: 100)
    #expect(chunks.count == 1)
    #expect(chunks[0] == "Hello world")
  }

  @Test("Splits at paragraph boundary")
  func splitAtParagraph() {
    let para1 = String(repeating: "a", count: 50)
    let para2 = String(repeating: "b", count: 50)
    let text = "\(para1)\n\n\(para2)"
    let chunks = splitMessage(text, maxLength: 60)
    #expect(chunks.count == 2)
    #expect(chunks[0] == para1)
    #expect(chunks[1] == para2)
  }

  @Test("Splits at single newline when no paragraph break")
  func splitAtNewline() {
    let line1 = String(repeating: "a", count: 50)
    let line2 = String(repeating: "b", count: 50)
    let text = "\(line1)\n\(line2)"
    let chunks = splitMessage(text, maxLength: 60)
    #expect(chunks.count == 2)
    #expect(chunks[0] == line1)
    #expect(chunks[1] == line2)
  }

  @Test("Hard splits when no newline available")
  func hardSplit() {
    let text = String(repeating: "x", count: 200)
    let chunks = splitMessage(text, maxLength: 100)
    #expect(chunks.count == 2)
    #expect(chunks[0].count == 100)
    #expect(chunks[1].count == 100)
  }

  @Test("Handles exactly max length")
  func exactMaxLength() {
    let text = String(repeating: "a", count: 100)
    let chunks = splitMessage(text, maxLength: 100)
    #expect(chunks.count == 1)
  }

  @Test("Does not produce empty trailing chunks")
  func noEmptyChunks() {
    let text = String(repeating: "a", count: 150)
    let chunks = splitMessage(text, maxLength: 100)
    for chunk in chunks {
      #expect(!chunk.isEmpty)
    }
  }
}

// MARK: - JSON Helpers

@Suite("JSON Helpers")
struct JSONHelperTests {

  @Test("makeJSONString produces valid JSON")
  func makeJSONStringBasic() {
    let dict: [String: Any] = ["key": "value", "num": 42]
    let json = makeJSONString(dict)
    #expect(json != nil)
    let parsed =
      try? JSONSerialization.jsonObject(with: json!.data(using: .utf8)!) as? [String: Any]
    #expect(parsed?["key"] as? String == "value")
    #expect(parsed?["num"] as? Int == 42)
  }

  @Test("parseJSON decodes a simple struct")
  func parseJSONSimple() {
    let json = "{\"id\":\"abc\",\"status\":\"running\"}"
    let result = parseJSON(json, as: DispatchResponse.self)
    #expect(result != nil)
    #expect(result?.id == "abc")
    #expect(result?.status == "running")
  }

  @Test("parseJSON returns nil for invalid JSON")
  func parseJSONInvalid() {
    let result = parseJSON("not json", as: DispatchResponse.self)
    #expect(result == nil)
  }

  @Test("parseJSON returns nil for empty string")
  func parseJSONEmpty() {
    let result = parseJSON("", as: DispatchResponse.self)
    #expect(result == nil)
  }

}

// MARK: - randomHexString

@Suite("Random Hex String")
struct RandomHexTests {

  @Test("Produces correct length")
  func correctLength() {
    let hex = randomHexString(bytes: 16)
    #expect(hex.count == 32)

    let hex32 = randomHexString(bytes: 32)
    #expect(hex32.count == 64)
  }

  @Test("Contains only hex characters")
  func onlyHexChars() {
    let hex = randomHexString(bytes: 32)
    let valid = CharacterSet(charactersIn: "0123456789abcdef")
    for scalar in hex.unicodeScalars {
      #expect(valid.contains(scalar))
    }
  }

  @Test("Produces different values each call")
  func uniqueness() {
    let a = randomHexString(bytes: 32)
    let b = randomHexString(bytes: 32)
    #expect(a != b)
  }
}

// MARK: - makeRouteResponse

@Suite("Route Response Builder")
struct RouteResponseTests {

  @Test("Builds a 200 JSON response")
  func response200() {
    let resp = makeRouteResponse(status: 200, body: "ok")
    let parsed = try? JSONSerialization.jsonObject(with: resp.data(using: .utf8)!) as? [String: Any]
    #expect(parsed?["status"] as? Int == 200)
    #expect(parsed?["body"] as? String == "ok")
    let headers = parsed?["headers"] as? [String: String]
    #expect(headers?["Content-Type"] == "text/plain")
  }

  @Test("Builds a 404 response")
  func response404() {
    let resp = makeRouteResponse(status: 404, body: "{\"error\":\"Not found\"}")
    let parsed = try? JSONSerialization.jsonObject(with: resp.data(using: .utf8)!) as? [String: Any]
    #expect(parsed?["status"] as? Int == 404)
  }

  @Test("Custom content type")
  func customContentType() {
    let resp = makeRouteResponse(status: 200, body: "{}", contentType: "application/json")
    let parsed = try? JSONSerialization.jsonObject(with: resp.data(using: .utf8)!) as? [String: Any]
    let headers = parsed?["headers"] as? [String: String]
    #expect(headers?["Content-Type"] == "application/json")
  }
}
