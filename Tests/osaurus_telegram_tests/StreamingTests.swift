import Foundation
import Testing

@testable import osaurus_telegram

// MARK: - draftId

@Suite("Draft ID Generation")
struct DraftIdTests {

  @Test("Produces non-zero values")
  func nonZero() {
    #expect(draftId(for: "task-123") != 0)
    #expect(draftId(for: "") != 0)
    #expect(draftId(for: "a") != 0)
  }

  @Test("Produces positive values")
  func positive() {
    #expect(draftId(for: "task-abc") > 0)
    #expect(draftId(for: "task-xyz-long-id-12345") > 0)
  }

  @Test("Produces stable values for the same input")
  func stable() {
    let a = draftId(for: "task-abc")
    let b = draftId(for: "task-abc")
    #expect(a == b)
  }

  @Test("Produces different values for different inputs")
  func different() {
    let a = draftId(for: "task-abc")
    let b = draftId(for: "task-def")
    #expect(a != b)
  }
}

// MARK: - extractStreamContent

@Suite("Stream Content Extraction")
struct ExtractStreamContentTests {

  @Test("Extracts content from OpenAI-compatible chunk")
  func extractsContent() {
    let chunk = "{\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}"
    #expect(extractStreamContent(chunk) == "Hello")
  }

  @Test("Extracts multi-word content")
  func multiWord() {
    let chunk = "{\"choices\":[{\"delta\":{\"content\":\" world\"}}]}"
    #expect(extractStreamContent(chunk) == " world")
  }

  @Test("Returns nil for chunk with no content")
  func noContent() {
    let chunk = "{\"choices\":[{\"delta\":{}}]}"
    #expect(extractStreamContent(chunk) == nil)
  }

  @Test("Returns nil for empty choices")
  func emptyChoices() {
    let chunk = "{\"choices\":[]}"
    #expect(extractStreamContent(chunk) == nil)
  }

  @Test("Returns nil for non-JSON input")
  func nonJSON() {
    #expect(extractStreamContent("not json") == nil)
  }

  @Test("Returns nil for empty string")
  func emptyString() {
    #expect(extractStreamContent("") == nil)
  }

  @Test("Returns nil for plain text that isn't JSON")
  func plainText() {
    #expect(extractStreamContent("Hello world") == nil)
  }
}

// MARK: - buildCompletionMessages

@Suite("Completion Messages Builder")
struct BuildCompletionMessagesTests {

  @Test("Includes system prompt and current message")
  func basicMessages() {
    let messages = buildCompletionMessages(historyJSON: "[]", currentPrompt: "Hello")
    #expect(messages.count == 2)
    #expect(messages[0]["role"] as? String == "system")
    #expect(messages[1]["role"] as? String == "user")
    #expect(messages[1]["content"] as? String == "Hello")
  }

  @Test("Incorporates chat history in chronological order")
  func withHistory() {
    let history = """
      [
        {"direction":"in","text":"First message","sender_name":"Alice"},
        {"direction":"out","text":"Response","sender_name":"Agent"}
      ]
      """
    let messages = buildCompletionMessages(historyJSON: history, currentPrompt: "Follow up")
    // system + 2 history (reversed) + current = 4
    #expect(messages.count == 4)
    #expect(messages[0]["role"] as? String == "system")
    // History is DESC in DB, reversed to chronological: out first, then in
    #expect(messages[1]["role"] as? String == "assistant")
    #expect(messages[1]["content"] as? String == "Response")
    #expect(messages[2]["role"] as? String == "user")
    #expect(messages[2]["content"] as? String == "First message")
    #expect(messages[3]["content"] as? String == "Follow up")
  }

  @Test("Skips empty text entries in history")
  func skipsEmpty() {
    let history = """
      [
        {"direction":"in","text":""},
        {"direction":"in","text":"Real message"}
      ]
      """
    let messages = buildCompletionMessages(historyJSON: history, currentPrompt: "Hi")
    // system + 1 non-empty history + current = 3
    #expect(messages.count == 3)
  }

  @Test("Handles invalid history JSON gracefully")
  func invalidHistory() {
    let messages = buildCompletionMessages(historyJSON: "not json", currentPrompt: "Hi")
    #expect(messages.count == 2)
  }
}

// MARK: - ChatStreamState

@Suite("Chat Stream State")
struct ChatStreamStateTests {

  @Test("Initializes with empty accumulated text")
  func initialState() {
    let state = ChatStreamState(token: "tok", chatId: "123", draftId: 1)
    #expect(state.accumulated == "")
    #expect(state.lastFlushLength == 0)
  }

  @Test("Accumulates text")
  func accumulates() {
    let state = ChatStreamState(token: "tok", chatId: "123", draftId: 1)
    state.accumulated += "Hello"
    state.accumulated += " world"
    #expect(state.accumulated == "Hello world")
  }

  @Test("Flush threshold is reasonable")
  func threshold() {
    #expect(ChatStreamState.flushThreshold > 0)
    #expect(ChatStreamState.flushThreshold <= 500)
  }
}
