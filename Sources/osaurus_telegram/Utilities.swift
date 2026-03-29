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

// MARK: - Host File Read

struct HostFileResult {
  let data: Data
  let mimeType: String
}

enum HostFileError: Error {
  case unavailable
  case readFailed(String)
}

/// Reads a file via host->file_read and returns decoded data + MIME type.
func readHostFile(path: String) -> Result<HostFileResult, HostFileError> {
  guard let fileRead = hostAPI?.pointee.file_read else {
    return .failure(.unavailable)
  }

  guard let readReq = makeJSONString(["path": path]) else {
    return .failure(.readFailed("Internal error"))
  }

  let readResultStr: String? = readReq.withCString { ptr in
    guard let resultPtr = fileRead(ptr) else { return nil }
    return String(cString: resultPtr)
  }
  guard let readResultStr,
    let readData = readResultStr.data(using: .utf8),
    let readResult = try? JSONSerialization.jsonObject(with: readData) as? [String: Any]
  else {
    return .failure(.readFailed("Invalid response"))
  }

  if let error = readResult["error"] as? String {
    return .failure(.readFailed(error))
  }

  guard let base64Data = readResult["data"] as? String,
    let fileData = Data(base64Encoded: base64Data)
  else {
    return .failure(.readFailed("Failed to decode file data"))
  }

  let mimeType = readResult["mime_type"] as? String ?? "application/octet-stream"
  return .success(HostFileResult(data: fileData, mimeType: mimeType))
}

/// Uploads a file to Telegram, choosing sendPhoto or sendDocument based on MIME type.
func uploadFileToTelegram(
  token: String,
  chatId: String,
  fileData: Data,
  filename: String,
  mimeType: String,
  caption: String? = nil,
  replyTo: Int? = nil
) -> (messageId: Int, isPhoto: Bool)? {
  let isPhoto = mimeType.hasPrefix("image/") && !mimeType.contains("svg")

  let msgId: Int?
  if isPhoto {
    msgId = telegramSendPhoto(
      token: token, chatId: chatId,
      fileData: fileData, filename: filename,
      caption: caption, replyTo: replyTo)
  } else {
    msgId = telegramSendDocument(
      token: token, chatId: chatId,
      fileData: fileData, filename: filename, mimeType: mimeType,
      caption: caption, replyTo: replyTo)
  }

  guard let msgId else { return nil }
  return (messageId: msgId, isPhoto: isPhoto)
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
