import Foundation
import Testing

@testable import osaurus_telegram

// MARK: - escapeHTML

@Suite("HTML Escaping")
struct EscapeHTMLTests {

  @Test("Escapes ampersand, angle brackets")
  func escapesSpecialChars() {
    #expect(escapeHTML("a & b") == "a &amp; b")
    #expect(escapeHTML("<tag>") == "&lt;tag&gt;")
    #expect(escapeHTML("1 < 2 & 3 > 1") == "1 &lt; 2 &amp; 3 &gt; 1")
  }

  @Test("Leaves plain text unchanged")
  func plainText() {
    #expect(escapeHTML("Hello world") == "Hello world")
  }

  @Test("Handles empty string")
  func emptyString() {
    #expect(escapeHTML("") == "")
  }
}

// MARK: - formatInlineMarkdown

@Suite("Inline Markdown Formatting")
struct FormatInlineMarkdownTests {

  @Test("Converts bold syntax")
  func bold() {
    #expect(formatInlineMarkdown("**hello**") == "<b>hello</b>")
    #expect(formatInlineMarkdown("__hello__") == "<b>hello</b>")
  }

  @Test("Converts italic syntax")
  func italic() {
    #expect(formatInlineMarkdown("*hello*") == "<i>hello</i>")
    #expect(formatInlineMarkdown("_hello_") == "<i>hello</i>")
  }

  @Test("Converts strikethrough syntax")
  func strikethrough() {
    #expect(formatInlineMarkdown("~~hello~~") == "<s>hello</s>")
  }

  @Test("Converts link syntax")
  func links() {
    #expect(
      formatInlineMarkdown("[text](https://example.com)")
        == "<a href=\"https://example.com\">text</a>")
  }

  @Test("Preserves inline code spans")
  func inlineCode() {
    let result = formatInlineMarkdown("Use `**not bold**` here")
    #expect(result.contains("<code>**not bold**</code>"))
    #expect(!result.contains("<b>"))
  }
}

// MARK: - markdownToTelegramHTML

@Suite("Markdown to Telegram HTML")
struct MarkdownToTelegramHTMLTests {

  @Test("Converts headings to bold")
  func headings() {
    #expect(markdownToTelegramHTML("# Title").contains("<b>Title</b>"))
    #expect(markdownToTelegramHTML("## Subtitle").contains("<b>Subtitle</b>"))
    #expect(markdownToTelegramHTML("### Section").contains("<b>Section</b>"))
  }

  @Test("Converts fenced code blocks")
  func codeBlocks() {
    let input = "```swift\nlet x = 1\n```"
    let result = markdownToTelegramHTML(input)
    #expect(result.contains("<pre><code class=\"language-swift\">"))
    #expect(result.contains("let x = 1"))
    #expect(result.contains("</code></pre>"))
  }

  @Test("Converts plain fenced code blocks")
  func plainCodeBlocks() {
    let input = "```\nfoo\n```"
    let result = markdownToTelegramHTML(input)
    #expect(result.contains("<pre>foo</pre>"))
  }

  @Test("Converts bullet lists")
  func bulletLists() {
    #expect(markdownToTelegramHTML("- item one").contains("• item one"))
    #expect(markdownToTelegramHTML("* item two").contains("• item two"))
  }

  @Test("Converts blockquotes")
  func blockquotes() {
    let result = markdownToTelegramHTML("> quoted text")
    #expect(result.contains("<blockquote>quoted text</blockquote>"))
  }

  @Test("Strips horizontal rules")
  func horizontalRules() {
    #expect(!markdownToTelegramHTML("---").contains("---"))
    #expect(!markdownToTelegramHTML("***").contains("***"))
  }

  @Test("Escapes HTML in regular text")
  func escapesHTML() {
    let result = markdownToTelegramHTML("a < b & c > d")
    #expect(result.contains("&lt;"))
    #expect(result.contains("&amp;"))
    #expect(result.contains("&gt;"))
  }

  @Test("Collapses multiple blank lines")
  func collapsesBlankLines() {
    let input = "line1\n\n\n\nline2"
    let result = markdownToTelegramHTML(input)
    #expect(!result.contains("\n\n\n"))
  }

  @Test("Handles empty string")
  func emptyString() {
    #expect(markdownToTelegramHTML("") == "")
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
