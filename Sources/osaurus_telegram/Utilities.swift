import CryptoKit
import Foundation
import OsaurusPluginABI

// MARK: - JSON Helpers

/// Serializes a dictionary to a JSON string.
func makeJSONString(_ dict: [String: Any]) -> String? {
  guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
    let str = String(data: data, encoding: .utf8)
  else {
    return nil
  }
  return str
}

/// Decodes a JSON string into a Decodable type.
func parseJSON<T: Decodable>(_ jsonString: String, as type: T.Type) -> T? {
  guard let data = jsonString.data(using: .utf8) else { return nil }
  return try? JSONDecoder().decode(type, from: data)
}

/// Parses a JSON string to `[String: Any]`. Used when the shape isn't
/// statically known (e.g. dispatch responses with optional `error`).
func parseJSONObject(_ jsonString: String) -> [String: Any]? {
  guard let data = jsonString.data(using: .utf8),
    let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  else { return nil }
  return obj
}

// MARK: - Random / Token Helpers

/// Generates a random hex string of the given byte length (output is 2x bytes in chars).
func randomHexString(bytes: Int = 32) -> String {
  var data = [UInt8](repeating: 0, count: bytes)
  _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &data)
  return data.map { String(format: "%02x", $0) }.joined()
}

/// Mints a short opaque reply token (8 chars, RFC 4648 base32 alphabet,
/// ~40 bits of entropy). Tokens are unguessable, scoped per-turn, and short
/// to keep prompt overhead minimal. Crockford-friendly: O/I/L are omitted.
func mintReplyToken() -> String {
  let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")  // 31 chars, O/I/L/0/1 dropped
  let length = 8
  var bytes = [UInt8](repeating: 0, count: length)
  _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
  let modulus = UInt8(alphabet.count)
  return String(bytes.map { alphabet[Int($0 % modulus)] })
}

/// Constant-time string equality. Used to compare the webhook secret against
/// the request header so attackers can't time-side-channel the value.
func constantTimeEquals(_ a: String, _ b: String) -> Bool {
  let aBytes = Array(a.utf8)
  let bBytes = Array(b.utf8)
  guard aBytes.count == bBytes.count else { return false }
  var diff: UInt8 = 0
  for i in 0..<aBytes.count {
    diff |= aBytes[i] ^ bBytes[i]
  }
  return diff == 0
}

// MARK: - Session UUID

/// RFC 4122 namespace UUID (the well-known DNS namespace; we just need a
/// stable 16-byte salt for the UUID5 derivation).
private let sessionNamespaceUUID: [UInt8] = [
  0x6b, 0xa7, 0xb8, 0x10, 0x9d, 0xad, 0x11, 0xd1,
  0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8,
]

/// Deterministic UUID5 over `"telegram:<salt>:<chat_id>:<user_id>"`. Same
/// chat + same user + same salt always produces the same UUID, so repeated
/// webhook deliveries reattach to the same Osaurus session row. Bumping
/// the salt (via /clear or /reset) produces a different UUID and starts
/// a fresh transcript.
///
/// In DMs `user_id == chat_id` so the UUID is per-chat (single user). In
/// groups every member gets their own UUID (and their own session) so the
/// agent's memory doesn't mix everyone's conversations together.
func sessionUUID(forChatId chatId: Int64, userId: Int64, salt: Int) -> UUID {
  let name = "telegram:\(salt):\(chatId):\(userId)"
  var input = Data(sessionNamespaceUUID)
  input.append(contentsOf: name.utf8)

  let digest = Insecure.SHA1.hash(data: input)
  var bytes = Array(digest.prefix(16))

  // Set version (5) and RFC 4122 variant bits.
  bytes[6] = (bytes[6] & 0x0F) | 0x50
  bytes[8] = (bytes[8] & 0x3F) | 0x80

  return UUID(
    uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3],
      bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11],
      bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

/// DM-style overload: `user_id == chat_id`. Existing tests and any
/// caller that doesn't care about per-user partitioning use this one.
func sessionUUID(forChatId chatId: Int64, salt: Int) -> UUID {
  sessionUUID(forChatId: chatId, userId: chatId, salt: salt)
}

// MARK: - Allowlist parsing
//
// Two flavours of allowlist live in `capabilities.config`:
//   * allowed_users    — CSV mixing numeric Telegram user IDs and
//                        `@usernames` (e.g. `123, @alice, @bob`).
//   * allowed_chat_ids — CSV of numeric chat IDs (negative for groups).
//
// Both are optional; an empty / nil / missing value means "no
// restriction" and the webhook handler skips the corresponding gate.
//
// The parser is forgiving: extra whitespace, empty entries (e.g.
// trailing commas) are ignored, and the @ on usernames is stripped so
// the comparison is just a lowercase string equality. Anything that
// looks like neither a numeric ID nor a `@username` produces a
// warn-level log and is skipped — the alternative would be silently
// allowing everyone if the user typo'd their list, which is exactly
// the wrong default for an allowlist.

/// Parsed shape for `allowed_users`. `usernames` carries lowercase
/// strings without the leading `@` so the gate can do a single
/// case-folded membership check on each side.
struct AllowedUsers: Equatable {
  let ids: Set<Int64>
  let usernames: Set<String>
  var isEmpty: Bool { ids.isEmpty && usernames.isEmpty }
}

func parseAllowedUsers(_ csv: String?) -> AllowedUsers {
  guard let csv else { return AllowedUsers(ids: [], usernames: []) }
  var ids: Set<Int64> = []
  var usernames: Set<String> = []
  for raw in csv.split(separator: ",") {
    let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if token.isEmpty { continue }
    if token.hasPrefix("@") {
      let name = String(token.dropFirst()).lowercased()
      if name.isEmpty {
        logWarn("allowlist: skipping bare '@' in allowed_users")
        continue
      }
      usernames.insert(name)
      continue
    }
    if let id = Int64(token) {
      ids.insert(id)
      continue
    }
    // Bare alphanumeric (no @): treat as a username for forgiveness — most
    // users will type "alice" and forget the @ even though Telegram
    // requires it. Only do this when the token is otherwise a plausible
    // username; reject anything containing whitespace or punctuation.
    let alphanumericOK = token.allSatisfy { ch in
      ch.isLetter || ch.isNumber || ch == "_"
    }
    if alphanumericOK, !token.isEmpty {
      usernames.insert(token.lowercased())
      continue
    }
    logWarn("allowlist: skipping unrecognised token '\(token)' in allowed_users")
  }
  return AllowedUsers(ids: ids, usernames: usernames)
}

func parseAllowedChatIds(_ csv: String?) -> Set<Int64> {
  guard let csv else { return [] }
  var ids: Set<Int64> = []
  for raw in csv.split(separator: ",") {
    let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if token.isEmpty { continue }
    if let id = Int64(token) {
      ids.insert(id)
    } else {
      logWarn("allowlist: skipping non-numeric token '\(token)' in allowed_chat_ids")
    }
  }
  return ids
}

// MARK: - Host string ownership

/// Frees a string allocated by the host on our behalf, via
/// `HostBridge.hostFree` (host `free_string` on v6+ hosts, libc `free()`
/// on older ones).
///
/// The host's `free_string` is the *opposite* direction from the
/// plugin's own `free_string`. NEVER pass a host-returned pointer to
/// `osr_plugin_api.free_string` — that one is only for strings the
/// host received from us.
func freeHostString(_ ptr: UnsafePointer<CChar>?) {
  HostBridge.shared.hostFree(ptr)
}

/// Calls a `(C-string in) -> C-string out` host function with a Swift
/// String, copies the response into a Swift String, and frees the host
/// allocation. Returns nil if either the host pointer is missing or the
/// call returned nil.
func callHostString(
  _ fn: ((UnsafePointer<CChar>?) -> UnsafePointer<CChar>?)?,
  _ input: String
) -> String? {
  guard let fn else { return nil }
  return input.withCString { ptr in
    guard let resultPtr = fn(ptr) else { return nil }
    let s = String(cString: resultPtr)
    freeHostString(resultPtr)
    return s
  }
}

/// Calls a `() -> C-string out` host function and returns a Swift String.
func callHostString(_ fn: (() -> UnsafePointer<CChar>?)?) -> String? {
  guard let fn, let resultPtr = fn() else { return nil }
  let s = String(cString: resultPtr)
  freeHostString(resultPtr)
  return s
}

// MARK: - Logging Helpers

private func withCString(_ s: String, _ body: (UnsafePointer<CChar>) -> Void) {
  s.withCString { body($0) }
}

private func printStderr(_ message: String) {
  fputs(message + "\n", Darwin.stderr)
}

// Host logging goes through `HostBridge` using the header's canonical
// `OsrLogLevel` scale (0=trace ... 4=error). The pre-SDK code passed a
// shifted 0..3 scale (debug logged as trace, error logged as warn); Wave 2
// fixed the mapping. The stderr echo is kept for local debugging.

func logDebug(_ message: String) {
  printStderr("[TELEGRAM][DEBUG] \(message)")
  HostBridge.shared.log(OsrLogLevel.debug, message)
}

func logInfo(_ message: String) {
  printStderr("[TELEGRAM][INFO] \(message)")
  HostBridge.shared.log(OsrLogLevel.info, message)
}

func logWarn(_ message: String) {
  printStderr("[TELEGRAM][WARN] \(message)")
  HostBridge.shared.log(OsrLogLevel.warn, message)
}

func logError(_ message: String) {
  printStderr("[TELEGRAM][ERROR] \(message)")
  HostBridge.shared.log(OsrLogLevel.error, message)
}

// MARK: - Config Helpers

func configGet(_ key: String) -> String? {
  HostBridge.shared.configGet(key)
}

func configSet(_ key: String, _ value: String) {
  HostBridge.shared.configSet(key, value)
}

func configDelete(_ key: String) {
  HostBridge.shared.configDelete(key)
}

func listActiveTasks() -> String? {
  callHostString(hostAPI?.pointee.list_active_tasks)
}

// MARK: - Host file read

/// Decoded result of `readHostFile`: raw bytes plus the host's MIME guess.
struct HostFileResult {
  let data: Data
  let mimeType: String
}

enum HostFileError: Error, CustomStringConvertible {
  case unavailable
  case readFailed(String)

  var description: String {
    switch self {
    case .unavailable: return "file_read host capability unavailable"
    case .readFailed(let msg): return "file_read failed: \(msg)"
    }
  }
}

/// Reads a file via `host->file_read`. The host returns a JSON envelope
/// with base64 `data` and a `mime_type` hint; we decode and surface both
/// to the caller. Used by `handleArtifactShare` (the auto-forward hook)
/// to grab sandbox-generated artifacts (`~/.osaurus/artifacts/...`)
/// before forwarding them to Telegram as multipart uploads.
func readHostFile(path: String) -> Result<HostFileResult, HostFileError> {
  guard let fileRead = hostAPI?.pointee.file_read else {
    return .failure(.unavailable)
  }
  guard let req = makeJSONString(["path": path]) else {
    return .failure(.readFailed("internal: request serialize failed"))
  }
  guard let responseStr = callHostString(fileRead, req) else {
    return .failure(.readFailed("no response from file_read"))
  }
  guard let envelope = parseJSONObject(responseStr) else {
    return .failure(.readFailed("malformed file_read response"))
  }
  if let error = envelope["error"] as? String {
    return .failure(.readFailed(error))
  }
  guard let base64 = envelope["data"] as? String,
    let bytes = Data(base64Encoded: base64)
  else {
    return .failure(.readFailed("missing or invalid base64 data"))
  }
  let mimeType = envelope["mime_type"] as? String ?? "application/octet-stream"
  return .success(HostFileResult(data: bytes, mimeType: mimeType))
}

// MARK: - Active Agent (ABI v4)

/// Returns the UUID of the agent whose callback frame we're currently inside,
/// or `nil` if the host is older than v4, the slot isn't wired, or we're
/// outside any per-agent frame (e.g. plugin init or a background thread the
/// plugin spawned). Callers MUST handle the nil case — never cache the result
/// across callbacks.
func getActiveAgentId() -> String? {
  HostBridge.shared.activeAgentId()
}
