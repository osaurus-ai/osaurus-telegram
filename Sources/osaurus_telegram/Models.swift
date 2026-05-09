import Foundation

// MARK: - Telegram Update (minimal)

struct TGUpdate: Decodable {
  struct Message: Decodable {
    struct Chat: Decodable {
      let id: Int64
    }
    struct From: Decodable {
      let username: String?
      let first_name: String?
    }
    let chat: Chat
    let from: From?
    let text: String?
    let message_id: Int64
  }
  let update_id: Int
  let message: Message?
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

// MARK: - Dispatch Response

struct DispatchResponse: Decodable {
  let id: String?
  let status: String?
  let error: String?
}
