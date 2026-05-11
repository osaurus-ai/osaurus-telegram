import CryptoKit
import Foundation

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

/// Deterministic UUID5 over `"telegram:<salt>:<chat_id>"`. Same chat + same
/// salt always produces the same UUID, so repeated webhook deliveries
/// reattach to the same Osaurus session row. Bumping the salt (via /reset)
/// produces a different UUID and starts a fresh transcript.
func sessionUUID(forChatId chatId: Int64, salt: Int) -> UUID {
  let name = "telegram:\(salt):\(chatId)"
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

// MARK: - Host string ownership

/// Frees a string allocated by the host on our behalf.
///
/// On v6+ hosts we MUST go through `host->free_string` — calling
/// `libc free()` directly is documented to keep working today, but a
/// future host allocator change would silently corrupt the heap. On
/// older hosts the v6 slot is NULL and we fall back to `libc free()`,
/// which is what every host's `free_string` does internally.
///
/// The host's `free_string` is the *opposite* direction from the
/// plugin's own `free_string`. NEVER pass a host-returned pointer to
/// `osr_plugin_api.free_string` — that one is only for strings the
/// host received from us.
func freeHostString(_ ptr: UnsafePointer<CChar>?) {
  guard let ptr else { return }
  if let host = hostAPI?.pointee, host.version >= 6, let hostFree = host.free_string {
    hostFree(ptr)
  } else {
    free(UnsafeMutableRawPointer(mutating: ptr))
  }
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

func logDebug(_ message: String) {
  printStderr("[TELEGRAM][DEBUG] \(message)")
  withCString(message) { hostAPI?.pointee.log?(0, $0) }
}

func logInfo(_ message: String) {
  printStderr("[TELEGRAM][INFO] \(message)")
  withCString(message) { hostAPI?.pointee.log?(1, $0) }
}

func logWarn(_ message: String) {
  printStderr("[TELEGRAM][WARN] \(message)")
  withCString(message) { hostAPI?.pointee.log?(2, $0) }
}

func logError(_ message: String) {
  printStderr("[TELEGRAM][ERROR] \(message)")
  withCString(message) { hostAPI?.pointee.log?(3, $0) }
}

// MARK: - Config Helpers

func configGet(_ key: String) -> String? {
  callHostString(hostAPI?.pointee.config_get, key)
}

func configSet(_ key: String, _ value: String) {
  key.withCString { k in
    value.withCString { v in
      hostAPI?.pointee.config_set?(k, v)
    }
  }
}

func configDelete(_ key: String) {
  key.withCString { hostAPI?.pointee.config_delete?($0) }
}

func listActiveTasks() -> String? {
  callHostString(hostAPI?.pointee.list_active_tasks)
}

// MARK: - Active Agent (ABI v4)

/// Returns the UUID of the agent whose callback frame we're currently inside,
/// or `nil` if the host is older than v4, the slot isn't wired, or we're
/// outside any per-agent frame (e.g. plugin init or a background thread the
/// plugin spawned). Callers MUST handle the nil case — never cache the result
/// across callbacks.
func getActiveAgentId() -> String? {
  guard let host = hostAPI?.pointee, host.version >= 4,
    let fn = host.get_active_agent_id
  else { return nil }
  guard let ptr = fn() else { return nil }
  defer { freeHostString(ptr) }
  return String(cString: ptr)
}
