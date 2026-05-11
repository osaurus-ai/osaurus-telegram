import Foundation

// MARK: - PerChatSendActor
//
// Multiple sequential `reply` calls from the agent must arrive at Telegram in
// order. Without serialization, two HTTP POSTs are independent and can race on
// the network. This actor chains awaited sends per (agent_id, chat_id) so
// callers naturally land in FIFO.
//
// Why the composite key: Telegram chat_ids are per-user, not per-bot, so two
// agents whose bots talk to the same Telegram user share `chat_id`. Keying on
// chat_id alone would needlessly serialise unrelated sends across agents.

actor PerChatSendActor {
  static let shared = PerChatSendActor()

  struct ChatKey: Hashable, Sendable {
    let agentId: String
    let chatId: Int64
  }

  private var inflight: [ChatKey: Task<Void, Never>] = [:]

  func send<T: Sendable>(
    agentId: String,
    chatId: Int64,
    _ work: @Sendable @escaping () async -> T
  ) async -> T {
    let key = ChatKey(agentId: agentId, chatId: chatId)
    let prior = inflight[key]
    let new = Task<Void, Never> {
      if let prior { await prior.value }
    }
    inflight[key] = new
    await new.value
    return await work()
  }
}
