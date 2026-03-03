import Foundation

// MARK: - MarkdownV2 Escaping

/// Escapes special characters for Telegram MarkdownV2 format.
/// Characters inside ``` code blocks are left untouched.
func escapeMarkdownV2(_ text: String) -> String {
  let specialChars: Set<Character> = [
    "_", "*", "[", "]", "(", ")", "~", "`", ">", "#", "+", "-", "=", "|", "{", "}", ".", "!",
  ]

  var result = ""
  var i = text.startIndex

  while i < text.endIndex {
    // Check for ``` code block — pass through verbatim
    if text[i] == "`" && text[i...].hasPrefix("```") {
      if let closeRange = text[text.index(i, offsetBy: 3)...].range(of: "```") {
        let blockEnd = closeRange.upperBound
        result.append(contentsOf: text[i..<blockEnd])
        i = blockEnd
        continue
      }
    }

    // Check for inline ` code span — pass through verbatim
    if text[i] == "`" {
      if let closeIdx = text[text.index(after: i)...].firstIndex(of: "`") {
        let blockEnd = text.index(after: closeIdx)
        result.append(contentsOf: text[i..<blockEnd])
        i = blockEnd
        continue
      }
    }

    if specialChars.contains(text[i]) {
      result.append("\\")
    }
    result.append(text[i])
    i = text.index(after: i)
  }

  return result
}

// MARK: - Message Splitting

/// Splits a long message into chunks respecting Telegram's 4096-char limit.
/// Tries to split at paragraph boundaries (double newline), then single newlines,
/// then at the hard limit.
func splitMessage(_ text: String, maxLength: Int = 4096) -> [String] {
  guard text.count > maxLength else { return [text] }

  var chunks: [String] = []
  var remaining = text

  while remaining.count > maxLength {
    let searchRange = remaining.prefix(maxLength)

    // Try to split at paragraph boundary
    if let splitIdx = searchRange.range(of: "\n\n", options: .backwards)?.lowerBound {
      let chunk = String(remaining[remaining.startIndex..<splitIdx])
      chunks.append(chunk)
      remaining = String(remaining[remaining.index(splitIdx, offsetBy: 2)...])
      continue
    }

    // Try to split at newline
    if let splitIdx = searchRange.range(of: "\n", options: .backwards)?.lowerBound {
      let chunk = String(remaining[remaining.startIndex..<splitIdx])
      chunks.append(chunk)
      remaining = String(remaining[remaining.index(after: splitIdx)...])
      continue
    }

    // Hard split at limit
    let splitIdx = remaining.index(remaining.startIndex, offsetBy: maxLength)
    chunks.append(String(remaining[remaining.startIndex..<splitIdx]))
    remaining = String(remaining[splitIdx...])
  }

  if !remaining.isEmpty {
    chunks.append(remaining)
  }

  return chunks
}

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

// MARK: - Random Hex

/// Generates a random hex string of the given byte length (output is 2x bytes in chars).
func randomHexString(bytes: Int = 32) -> String {
  var data = [UInt8](repeating: 0, count: bytes)
  _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &data)
  return data.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Logging Helpers

private func withCString(_ s: String, _ body: (UnsafePointer<CChar>) -> Void) {
  s.withCString { body($0) }
}

func logDebug(_ message: String) {
  print("[TELEGRAM][DEBUG] \(message)")
  withCString(message) { hostAPI?.pointee.log?(0, $0) }
}

func logInfo(_ message: String) {
  print("[TELEGRAM][INFO] \(message)")
  withCString(message) { hostAPI?.pointee.log?(1, $0) }
}

func logWarn(_ message: String) {
  print("[TELEGRAM][WARN] \(message)")
  withCString(message) { hostAPI?.pointee.log?(2, $0) }
}

func logError(_ message: String) {
  print("[TELEGRAM][ERROR] \(message)")
  withCString(message) { hostAPI?.pointee.log?(3, $0) }
}

// MARK: - Config Helpers

func configGet(_ key: String) -> String? {
  guard let getValue = hostAPI?.pointee.config_get else { return nil }
  return key.withCString { keyPtr in
    guard let result = getValue(keyPtr) else { return nil }
    let str = String(cString: result)
    free(UnsafeMutableRawPointer(mutating: result))
    return str
  }
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
