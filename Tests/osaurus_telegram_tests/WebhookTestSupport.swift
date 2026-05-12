import Foundation

@testable import osaurus_telegram

// MARK: - Shared webhook test helpers
//
// Every webhook integration test needs to (a) wrap an update dict in the
// host's RouteRequest envelope, (b) parse the RouteResponse envelope
// `handleRoute` returns, and (c) construct a minimal Telegram Update
// for a plain text message. Duplicating these inside each test class
// produced ~100 lines of boilerplate per file with subtle drift between
// copies; this file pins the canonical shape.

/// Wraps the supplied Telegram `update` dict in the same JSON envelope
/// the host passes to `handle_route`. The optional `secret` populates
/// the `X-Telegram-Bot-Api-Secret-Token` header — pass nil to simulate
/// a forged caller.
func webhookRequest(
  secret: String?, update: [String: Any], method: String = "POST"
) -> String {
  let body = String(
    data: try! JSONSerialization.data(withJSONObject: update),
    encoding: .utf8)!
  var headers: [String: String] = [:]
  if let secret { headers["x-telegram-bot-api-secret-token"] = secret }
  let req: [String: Any] = [
    "route_id": "webhook",
    "method": method,
    "path": "/webhook",
    "headers": headers,
    "body": body,
  ]
  return String(
    data: try! JSONSerialization.data(withJSONObject: req),
    encoding: .utf8)!
}

/// Parses the JSON envelope `handleRoute` returns into the two fields
/// every test cares about. Missing fields collapse to (0, "") so test
/// assertions surface the missing field rather than throwing.
func parseRouteResponse(_ s: String) -> (status: Int, body: String) {
  let data = s.data(using: .utf8) ?? Data()
  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
  return (obj["status"] as? Int ?? 0, obj["body"] as? String ?? "")
}

/// Minimal text-message update suitable for almost every webhook test.
/// Each parameter has a sensible default so a test that only cares about
/// `text` can pass `text: "hello"` and leave everything else implicit.
///
/// `fromId` is intentionally optional. Leaving it nil omits `from.id`
/// from the payload, which causes `effectiveUserId` to fall back to
/// `chatId` — i.e. the "DM" shape several legacy tests rely on. Pass
/// an explicit `fromId` to exercise per-user semantics in a group.
///
/// To exercise group-chat behaviour, set `chatType: "supergroup"` (or
/// `"group"`); leaving it nil produces the DM-shaped chat object the
/// production code treats as a private chat.
func textUpdate(
  updateId: Int,
  chatId: Int64,
  text: String,
  messageId: Int64 = 1,
  fromId: Int64? = nil,
  username: String = "alice",
  firstName: String = "Alice",
  isBot: Bool = false,
  chatType: String? = nil,
  chatTitle: String? = nil
) -> [String: Any] {
  var chat: [String: Any] = ["id": chatId]
  if let chatType { chat["type"] = chatType }
  if let chatTitle { chat["title"] = chatTitle }
  var from: [String: Any] = [
    "username": username, "first_name": firstName, "is_bot": isBot,
  ]
  if let fromId { from["id"] = fromId }
  return [
    "update_id": updateId,
    "message": [
      "message_id": messageId,
      "chat": chat,
      "from": from,
      "text": text,
    ] as [String: Any],
  ]
}
