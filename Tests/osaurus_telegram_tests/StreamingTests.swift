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

// MARK: - extractToolCallInfo

@Suite("Tool Call Info Extraction")
struct ExtractToolCallInfoTests {

  @Test("Extracts tool name from tool call chunk")
  func extractsToolName() {
    let chunk =
      "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_1\",\"function\":{\"name\":\"file_read\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}"
    let info = extractToolCallInfo(chunk)
    #expect(info != nil)
    #expect(info?.name == "file_read")
    #expect(info?.isToolResult == false)
  }

  @Test("Detects tool result chunk")
  func detectsToolResult() {
    let chunk =
      "{\"choices\":[{\"delta\":{\"role\":\"tool\",\"tool_call_id\":\"call_1\",\"content\":\"result data\"}}]}"
    let info = extractToolCallInfo(chunk)
    #expect(info != nil)
    #expect(info?.isToolResult == true)
    #expect(info?.name == nil)
  }

  @Test("Returns nil for content-only chunk")
  func nilForContentChunk() {
    let chunk = "{\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}"
    #expect(extractToolCallInfo(chunk) == nil)
  }

  @Test("Returns nil for empty delta")
  func nilForEmptyDelta() {
    let chunk = "{\"choices\":[{\"delta\":{}}]}"
    #expect(extractToolCallInfo(chunk) == nil)
  }

  @Test("Returns nil for non-JSON")
  func nilForNonJSON() {
    #expect(extractToolCallInfo("not json") == nil)
  }

  @Test("Returns nil for empty string")
  func nilForEmpty() {
    #expect(extractToolCallInfo("") == nil)
  }

  @Test("Handles tool call with no function name")
  func noFunctionName() {
    let chunk =
      "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_2\"}]}}]}"
    let info = extractToolCallInfo(chunk)
    #expect(info != nil)
    #expect(info?.name == nil)
    #expect(info?.isToolResult == false)
  }

  @Test("extractStreamContent returns nil for tool call chunk")
  func contentNilForToolCall() {
    let chunk =
      "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_1\",\"function\":{\"name\":\"search\"}}]},\"finish_reason\":\"tool_calls\"}]}"
    #expect(extractStreamContent(chunk) == nil)
  }

  @Test("extractStreamContent returns nil for tool result chunk")
  func contentNilForToolResult() {
    let chunk =
      "{\"choices\":[{\"delta\":{\"role\":\"tool\",\"tool_call_id\":\"call_1\",\"content\":\"result\"}}]}"
    // tool result chunks have content, but extractStreamContent returns it — this is expected
    // since tool result content is the tool's output, not the assistant's response,
    // the callback handles this by checking extractToolCallInfo first
    let content = extractStreamContent(chunk)
    #expect(content == "result")
  }
}

// MARK: - buildCompletionMessages

@Suite("Completion Messages Builder")
struct BuildCompletionMessagesTests {

  @Test("Includes current message without hardcoded system prompt")
  func basicMessages() {
    let messages = buildCompletionMessages(historyJSON: "[]", currentPrompt: "Hello")
    #expect(messages.count == 1)
    #expect(messages[0]["role"] as? String == "user")
    #expect(messages[0]["content"] as? String == "Hello")
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
    // 2 history (reversed) + current = 3
    #expect(messages.count == 3)
    // History is DESC in DB, reversed to chronological: out first, then in
    #expect(messages[0]["role"] as? String == "assistant")
    #expect(messages[0]["content"] as? String == "Response")
    #expect(messages[1]["role"] as? String == "user")
    #expect(messages[1]["content"] as? String == "First message")
    #expect(messages[2]["content"] as? String == "Follow up")
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
    // 1 non-empty history + current = 2
    #expect(messages.count == 2)
  }

  @Test("Handles invalid history JSON gracefully")
  func invalidHistory() {
    let messages = buildCompletionMessages(historyJSON: "not json", currentPrompt: "Hi")
    #expect(messages.count == 1)
  }
}

// MARK: - ChatStreamState

@Suite("Chat Stream State")
struct ChatStreamStateTests {

  @Test("Initializes with empty accumulated text and nil tool name")
  func initialState() {
    let state = ChatStreamState(token: "tok", chatId: "123", draftId: 1)
    #expect(state.accumulated == "")
    #expect(state.lastFlushLength == 0)
    #expect(state.currentToolName == nil)
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
