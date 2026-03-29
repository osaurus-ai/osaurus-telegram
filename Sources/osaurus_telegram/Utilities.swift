import Foundation

// MARK: - Markdown → Telegram HTML

func escapeHTML(_ text: String) -> String {
  text.replacingOccurrences(of: "&", with: "&amp;")
    .replacingOccurrences(of: "<", with: "&lt;")
    .replacingOccurrences(of: ">", with: "&gt;")
}

private func stripHeadingPrefix(_ line: String) -> String? {
  for prefix in ["#### ", "### ", "## ", "# "] {
    if line.hasPrefix(prefix) {
      return String(line.dropFirst(prefix.count))
    }
  }
  return nil
}

func formatInlineMarkdown(_ text: String) -> String {
  var codeSpans: [String] = []
  var processed = text

  while let startIdx = processed.firstIndex(of: "`") {
    let afterStart = processed.index(after: startIdx)
    guard afterStart < processed.endIndex,
      let endIdx = processed[afterStart...].firstIndex(of: "`")
    else { break }

    let codeContent = String(processed[afterStart..<endIdx])
    let placeholder = "\u{FFFD}\(codeSpans.count)\u{FFFD}"
    codeSpans.append("<code>\(codeContent)</code>")
    processed =
      String(processed[..<startIdx]) + placeholder
      + String(processed[processed.index(after: endIdx)...])
  }

  processed = processed.replacingOccurrences(
    of: "\\[([^\\]]+)\\]\\(([^)]+)\\)", with: "<a href=\"$2\">$1</a>",
    options: .regularExpression)

  processed = processed.replacingOccurrences(
    of: "\\*\\*(.+?)\\*\\*", with: "<b>$1</b>",
    options: .regularExpression)

  processed = processed.replacingOccurrences(
    of: "__(.+?)__", with: "<b>$1</b>",
    options: .regularExpression)

  processed = processed.replacingOccurrences(
    of: "~~(.+?)~~", with: "<s>$1</s>",
    options: .regularExpression)

  processed = processed.replacingOccurrences(
    of: "(?<!\\w)\\*(.+?)\\*(?!\\w)", with: "<i>$1</i>",
    options: .regularExpression)

  processed = processed.replacingOccurrences(
    of: "(?<!\\w)_(.+?)_(?!\\w)", with: "<i>$1</i>",
    options: .regularExpression)

  for (idx, span) in codeSpans.enumerated() {
    processed = processed.replacingOccurrences(of: "\u{FFFD}\(idx)\u{FFFD}", with: span)
  }

  return processed
}

func markdownToTelegramHTML(_ text: String) -> String {
  let lines = text.components(separatedBy: "\n")
  var result: [String] = []
  var i = 0

  while i < lines.count {
    let line = lines[i]
    let trimmed = line.trimmingCharacters(in: .whitespaces)

    if trimmed.hasPrefix("```") {
      let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
      var codeLines: [String] = []
      i += 1
      while i < lines.count
        && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```")
      {
        codeLines.append(lines[i])
        i += 1
      }
      if i < lines.count { i += 1 }
      let code = escapeHTML(codeLines.joined(separator: "\n"))
      if !lang.isEmpty {
        result.append(
          "<pre><code class=\"language-\(escapeHTML(lang))\">\(code)</code></pre>")
      } else {
        result.append("<pre>\(code)</pre>")
      }
      continue
    }

    if let heading = stripHeadingPrefix(trimmed) {
      let formatted = formatInlineMarkdown(escapeHTML(heading))
      if !result.isEmpty && result.last != "" {
        result.append("")
      }
      result.append("<b>\(formatted)</b>")
      i += 1
      continue
    }

    if trimmed.hasPrefix("> ") || trimmed == ">" {
      var quoteLines: [String] = []
      while i < lines.count {
        let ql = lines[i].trimmingCharacters(in: .whitespaces)
        if ql.hasPrefix("> ") {
          quoteLines.append(String(ql.dropFirst(2)))
        } else if ql == ">" {
          quoteLines.append("")
        } else {
          break
        }
        i += 1
      }
      let quoteText = formatInlineMarkdown(
        escapeHTML(quoteLines.joined(separator: "\n")))
      result.append("<blockquote>\(quoteText)</blockquote>")
      continue
    }

    if (trimmed.hasPrefix("- ") || trimmed.hasPrefix("* "))
      && trimmed != "---" && trimmed != "***"
    {
      let content = String(trimmed.dropFirst(2))
      result.append("• \(formatInlineMarkdown(escapeHTML(content)))")
      i += 1
      continue
    }

    if trimmed == "---" || trimmed == "***" || trimmed == "___" {
      i += 1
      continue
    }

    if trimmed.isEmpty {
      result.append("")
      i += 1
      continue
    }

    result.append(formatInlineMarkdown(escapeHTML(line)))
    i += 1
  }

  var output = result.joined(separator: "\n")
  while output.contains("\n\n\n") {
    output = output.replacingOccurrences(of: "\n\n\n", with: "\n\n")
  }
  return output.trimmingCharacters(in: .whitespacesAndNewlines)
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
