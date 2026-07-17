import Foundation

// MARK: - Canonical tool-result envelope
//
// The Osaurus host AUTO-WRAPS any non-envelope TOOL (`invoke`) output as a
// SUCCESS. That means a tool error returned as `{"error":...}`, an
// `{"ok":false}` body that omits `kind`/`retryable`, or a bare string is
// silently misclassified as a successful tool call. To make tool failures
// legible to the host (and to the agent's retry policy), every TOOL error
// path MUST return the canonical failure envelope:
//
//   failure: {"ok":false,"kind":"<kind>","message":"...","retryable":<bool>}
//   success: {"ok":true,"result":<any>}
//
// NOTE: This envelope is for the `invoke` (tool) contract ONLY. HTTP route
// handlers (`handle_route`) and the config-change hooks speak a different
// contract and must keep their existing response shapes.
enum Envelope {
  enum Kind: String {
    case invalidArgs = "invalid_args"
    case executionError = "execution_error"
    case notFound = "not_found"
    case unavailable = "unavailable"
  }

  /// `data` carries machine-readable failure context (e.g.
  /// `{"retry_after": 7}` on a Telegram 429) alongside the human-readable
  /// message. Omitted from the envelope when nil/empty.
  static func failure(
    _ kind: Kind, _ message: String, retryable: Bool? = nil, data: [String: Any]? = nil
  ) -> String {
    let retry = retryable ?? defaultRetryable(for: kind)
    var envelope =
      "{\"ok\":false,\"kind\":\"\(kind.rawValue)\",\"message\":\"\(escape(message))\",\"retryable\":\(retry)"
    if let data, !data.isEmpty, let dataJSON = makeJSONString(data) {
      envelope += ",\"data\":\(dataJSON)"
    }
    return envelope + "}"
  }

  static func successRaw(_ jsonPayload: String) -> String { "{\"ok\":true,\"result\":\(jsonPayload)}" }

  private static func defaultRetryable(for kind: Kind) -> Bool {
    switch kind {
    // Retrying identical invalid arguments can never succeed; a fresh
    // lookup of a missing resource likewise. Only transient conditions
    // default to retryable.
    case .invalidArgs, .notFound: return false
    case .executionError, .unavailable: return true
    }
  }

  static func escape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count + 2)
    for ch in s {
      switch ch {
      case "\\": out += "\\\\"
      case "\"": out += "\\\""
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      default:
        if let a = ch.asciiValue, a < 0x20 { out += String(format: "\\u%04x", a) } else { out.append(ch) }
      }
    }
    return out
  }
}
