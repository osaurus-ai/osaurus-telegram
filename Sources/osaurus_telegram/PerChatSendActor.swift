import Foundation

// MARK: - PerChatSendActor
//
// Multiple sequential `reply` calls from the agent must arrive at Telegram in
// order. Without serialization, two HTTP POSTs are independent and can race on
// the network. This actor chains awaited sends per chat_id so callers
// naturally land in FIFO.

actor PerChatSendActor {
  static let shared = PerChatSendActor()

  private var inflight: [Int64: Task<Void, Never>] = [:]

  func send<T: Sendable>(
    chatId: Int64,
    _ work: @Sendable @escaping () async -> T
  ) async -> T {
    let prior = inflight[chatId]
    let new = Task<Void, Never> {
      if let prior { await prior.value }
    }
    inflight[chatId] = new
    await new.value
    return await work()
  }
}
