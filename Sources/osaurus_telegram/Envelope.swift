import Foundation
import OsaurusPluginKit

// MARK: - Canonical tool-result envelope
//
// Rendering now delegates to the pinned `osaurus-plugin-sdk`
// (`OsaurusPluginKit.Envelope`). The Osaurus host AUTO-WRAPS any
// non-envelope TOOL (`invoke`) output as a SUCCESS, so every TOOL error
// path MUST return the canonical failure envelope:
//
//   failure: {"ok":false,"kind":"<kind>","message":"...","retryable":<bool>}
//   success: {"ok":true,"result":<any>}
//
// NOTE: This envelope is for the `invoke` (tool) contract ONLY. HTTP route
// handlers (`handle_route`) and the config-change hooks speak a different
// contract and must keep their existing response shapes.
//
// This thin local shim exists for one wire-shape divergence: this plugin's
// failure kind set includes `unavailable` (default retryable), which
// predates the SDK and is asserted by wave-1 tests. The SDK's canonical
// kind set has no `unavailable`, so the local `Kind` keeps it and
// delegates every shared kind (and all JSON escaping) to the SDK builders.
enum Envelope {
  enum Kind: String {
    case invalidArgs = "invalid_args"
    case executionError = "execution_error"
    case notFound = "not_found"
    case unavailable = "unavailable"

    /// SDK equivalent, nil for the plugin-local `unavailable` kind.
    fileprivate var sdkKind: OsaurusPluginKit.Envelope.Kind? {
      switch self {
      case .invalidArgs: return .invalidArgs
      case .executionError: return .executionError
      case .notFound: return .notFound
      case .unavailable: return nil
      }
    }
  }

  /// `data` carries machine-readable failure context (e.g.
  /// `{"retry_after": 7}` on a Telegram 429) alongside the human-readable
  /// message. Omitted from the envelope when nil/empty. `retryable`
  /// defaults per kind (`unavailable` defaults to retryable, matching
  /// wave-1 behavior).
  static func failure(
    _ kind: Kind, _ message: String, retryable: Bool? = nil, data: [String: Any]? = nil
  ) -> String {
    let dataJSON: String? = {
      guard let data, !data.isEmpty else { return nil }
      return makeJSONString(data)
    }()
    guard let sdkKind = kind.sdkKind else {
      let retry = retryable ?? true
      var envelope =
        "{\"ok\":false,\"kind\":\"\(kind.rawValue)\",\"message\":\"\(escape(message))\",\"retryable\":\(retry)"
      if let dataJSON { envelope += ",\"data\":\(dataJSON)" }
      return envelope + "}"
    }
    return OsaurusPluginKit.Envelope.failure(
      sdkKind, message, retryable: retryable, dataJSON: dataJSON)
  }

  static func successRaw(_ jsonPayload: String) -> String {
    OsaurusPluginKit.Envelope.success(raw: jsonPayload)
  }

  static func escape(_ s: String) -> String {
    OsaurusPluginKit.Envelope.escape(s)
  }
}
