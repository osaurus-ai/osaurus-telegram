import Foundation
import Testing

@testable import osaurus_telegram

// MARK: - PluginContext

@Suite("Plugin Context")
struct PluginContextTests {

  @Test("Initial state has nil fields")
  func initialState() {
    let ctx = PluginContext()
    #expect(ctx.botToken == nil)
    #expect(ctx.botId == nil)
    #expect(ctx.botUsername == nil)
    #expect(ctx.webhookSecret == nil)
  }

  @Test("Tool instances are initialized")
  func toolsExist() {
    let ctx = PluginContext()
    #expect(ctx.telegramSendTool.name == "telegram_send")
    #expect(ctx.chatHistoryTool.name == "telegram_get_chat_history")
  }

  @Test("onConfigChanged clears state when token removed")
  func configChangedClearsState() {
    let ctx = PluginContext()
    ctx.botToken = "old-token"
    ctx.botId = "123"
    ctx.botUsername = "old_bot"
    ctx.webhookSecret = "secret"

    // hostAPI is nil so telegramDeleteWebhook is a no-op
    onConfigChanged(ctx: ctx, key: "bot_token", value: nil)

    #expect(ctx.botToken == nil)
    #expect(ctx.botId == nil)
    #expect(ctx.botUsername == nil)
    #expect(ctx.webhookSecret == nil)
  }

  @Test("onConfigChanged ignores non-bot_token keys")
  func configChangedIgnoresOtherKeys() {
    let ctx = PluginContext()
    ctx.botToken = "existing"

    onConfigChanged(ctx: ctx, key: "allowed_users", value: "alice")

    #expect(ctx.botToken == "existing")
  }

  @Test("onConfigChanged sets new token")
  func configChangedNewToken() {
    let ctx = PluginContext()

    // hostAPI is nil so telegramGetMe returns nil, setupWebhook will fail gracefully
    onConfigChanged(ctx: ctx, key: "bot_token", value: "new-token")

    #expect(ctx.botToken == "new-token")
  }

  @Test("destroyPlugin clears state gracefully with nil hostAPI")
  func destroyGraceful() {
    let ctx = PluginContext()
    ctx.botToken = "token"
    // Should not crash even though hostAPI is nil
    destroyPlugin(ctx)
  }
}

// MARK: - TaskRow

@Suite("TaskRow")
struct TaskRowTests {

  @Test("TaskRow stores all fields")
  func storesFields() {
    let row = TaskRow(
      taskId: "t1",
      chatId: "c1",
      messageId: 42,
      status: "running",
      statusMsgId: 99,
      summary: nil,
      chatType: "private",
      clarificationOptions: nil
    )
    #expect(row.taskId == "t1")
    #expect(row.chatId == "c1")
    #expect(row.messageId == 42)
    #expect(row.status == "running")
    #expect(row.statusMsgId == 99)
    #expect(row.summary == nil)
    #expect(row.chatType == "private")
  }

  @Test("TaskRow handles nil optional fields")
  func nilFields() {
    let row = TaskRow(
      taskId: "t2",
      chatId: "c2",
      messageId: nil,
      status: "completed",
      statusMsgId: nil,
      summary: "All done",
      chatType: "supergroup",
      clarificationOptions: nil
    )
    #expect(row.messageId == nil)
    #expect(row.statusMsgId == nil)
    #expect(row.summary == "All done")
    #expect(row.chatType == "supergroup")
  }
}
