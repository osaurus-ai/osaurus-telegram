import Foundation

// MARK: - Inbound media handling
//
// When a user sends a photo / document / voice / audio / video / GIF, the
// webhook handler resolves the largest variant via Telegram's `getFile`,
// downloads the bytes, and stashes them into `~/.osaurus/artifacts/` so the
// agent can read them through its sandbox tools.
//
// We pre-claim each downloaded path via `state.claimArtifactUpload(path)`
// BEFORE the file lands on disk. The host's artifact watcher fires
// `invoke(type: "artifact", id: "share", ...)` for every new file under
// `~/.osaurus/artifacts/`, which would otherwise auto-forward our just-
// downloaded inbound media right back to the user. The pre-claim makes
// `handleArtifactShare` short-circuit ("already_uploaded") instead of
// ping-ponging the bytes.

/// One downloaded inbound attachment: an absolute on-disk path inside
/// the host's `~/.osaurus/artifacts/` tree, plus the MIME type the
/// agent's prompt header advertises.
struct InboundAttachment {
  let path: String
  let mimeType: String
  /// Telegram-side category label surfaced to the agent
  /// (`photo`, `document`, `voice`, `audio`, `video`, `animation`).
  /// Distinct from `mimeType` because Telegram users distinguish
  /// "voice note" from "audio file" semantically even when both arrive
  /// as `audio/ogg`.
  let kind: String
}

/// Root directory for inbound media. We sit under `~/.osaurus/artifacts/`
/// (so `file_read` can reach the file from inside the agent sandbox) but
/// inside our own `osaurus.telegram-inbound` subtree so the path is
/// distinguishable from agent-generated artifacts at a glance.
private func inboundRootDir() -> URL? {
  let home = FileManager.default.homeDirectoryForCurrentUser
  return
    home
    .appendingPathComponent(".osaurus", isDirectory: true)
    .appendingPathComponent("artifacts", isDirectory: true)
    .appendingPathComponent("osaurus.telegram-inbound", isDirectory: true)
}

/// Per-(agent, chat, message) directory. Keeps inbound media partitioned
/// so two agents in the same chat don't write to the same path, and so
/// retries for the same `message_id` are obviously idempotent (same
/// directory, same filenames).
private func inboundMessageDir(
  agentId: String, chatId: Int64, messageId: Int64
) -> URL? {
  guard let root = inboundRootDir() else { return nil }
  return
    root
    .appendingPathComponent(agentId, isDirectory: true)
    .appendingPathComponent("chat-\(chatId)", isDirectory: true)
    .appendingPathComponent("msg-\(messageId)", isDirectory: true)
}

/// Strips path separators from a Telegram-supplied filename so a
/// malicious sender can't escape the per-message directory.
/// Returns "file" for empty / nil inputs so the caller always has
/// something to write to.
private func sanitizeFilename(_ raw: String?) -> String {
  let candidate = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  if candidate.isEmpty { return "file" }
  // Replace anything that isn't a "safe" filename character with `_`.
  // Conservative on purpose — Telegram filenames can carry arbitrary
  // unicode but the OS-level filesystem and agent prompt header both
  // benefit from a small alphabet.
  let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-+ "))
  let scalars = candidate.unicodeScalars.map { scalar -> Character in
    allowed.contains(scalar) ? Character(scalar) : Character("_")
  }
  let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
  return cleaned.isEmpty ? "file" : String(cleaned.prefix(120))
}

/// Picks a default filename when Telegram's payload doesn't carry one
/// (photos, voice notes, sometimes audio/video). Uses the
/// `file_unique_id` so two distinct uploads don't collide on disk even
/// when they share the same kind.
private func defaultFilename(
  kind: String, fileUniqueId: String?, mimeType: String
) -> String {
  let suffix: String
  switch mimeType.lowercased() {
  case "image/jpeg", "image/jpg": suffix = "jpg"
  case "image/png": suffix = "png"
  case "image/gif": suffix = "gif"
  case "image/webp": suffix = "webp"
  case "audio/ogg": suffix = "ogg"
  case "audio/mpeg": suffix = "mp3"
  case "audio/mp4", "audio/m4a": suffix = "m4a"
  case "video/mp4": suffix = "mp4"
  case "video/quicktime": suffix = "mov"
  case "application/pdf": suffix = "pdf"
  default: suffix = "bin"
  }
  let stem = (fileUniqueId.flatMap { sanitizeFilename($0) } ?? "media")
  return "\(kind)-\(stem).\(suffix)"
}

/// Best-effort MIME inference from a filename extension when Telegram
/// doesn't declare one. Mirrors the table in `defaultFilename`.
private func mimeFromExtension(_ filename: String) -> String {
  let ext = (filename as NSString).pathExtension.lowercased()
  switch ext {
  case "jpg", "jpeg": return "image/jpeg"
  case "png": return "image/png"
  case "gif": return "image/gif"
  case "webp": return "image/webp"
  case "ogg": return "audio/ogg"
  case "mp3": return "audio/mpeg"
  case "m4a", "mp4a": return "audio/mp4"
  case "mp4": return "video/mp4"
  case "mov": return "video/quicktime"
  case "pdf": return "application/pdf"
  case "txt": return "text/plain"
  default: return "application/octet-stream"
  }
}

// MARK: - Per-attachment download

/// One thing-to-fetch resolved off the message. Internal scaffolding
/// for `downloadInboundMedia`; not surfaced to callers.
private struct InboundCandidate {
  let kind: String
  let fileId: String
  let fileUniqueId: String?
  let suggestedName: String?
  let suggestedMime: String?
}

/// Walks the message and produces the candidate file list the downloader
/// will try to fetch. For photos we always pick the LAST (largest) size —
/// Telegram returns sizes in ascending resolution order.
private func collectCandidates(_ message: TGUpdate.Message) -> [InboundCandidate] {
  var out: [InboundCandidate] = []

  if let photos = message.photo, let largest = photos.last {
    out.append(
      InboundCandidate(
        kind: "photo", fileId: largest.file_id,
        fileUniqueId: largest.file_unique_id,
        suggestedName: nil, suggestedMime: "image/jpeg"))
  }
  if let doc = message.document {
    out.append(
      InboundCandidate(
        kind: "document", fileId: doc.file_id,
        fileUniqueId: doc.file_unique_id,
        suggestedName: doc.file_name, suggestedMime: doc.mime_type))
  }
  if let voice = message.voice {
    out.append(
      InboundCandidate(
        kind: "voice", fileId: voice.file_id,
        fileUniqueId: voice.file_unique_id,
        suggestedName: nil, suggestedMime: voice.mime_type ?? "audio/ogg"))
  }
  if let audio = message.audio {
    out.append(
      InboundCandidate(
        kind: "audio", fileId: audio.file_id,
        fileUniqueId: audio.file_unique_id,
        suggestedName: audio.file_name, suggestedMime: audio.mime_type))
  }
  if let video = message.video {
    out.append(
      InboundCandidate(
        kind: "video", fileId: video.file_id,
        fileUniqueId: video.file_unique_id,
        suggestedName: video.file_name, suggestedMime: video.mime_type))
  }
  if let animation = message.animation {
    out.append(
      InboundCandidate(
        kind: "animation", fileId: animation.file_id,
        fileUniqueId: animation.file_unique_id,
        suggestedName: animation.file_name,
        suggestedMime: animation.mime_type ?? "video/mp4"))
  }
  return out
}

/// Telegram caps `getFile` at 20 MB downloads. Anything bigger is rejected
/// upstream; we mirror that limit so a misconfigured client doesn't make
/// us spend network bandwidth before discovering the file is too large.
private let maxDownloadBytes: Int64 = 20 * 1024 * 1024

/// Cumulative byte budget across every attachment of one update. The
/// download happens synchronously on the webhook path, so the budget
/// exists to bound how long a single (possibly hostile) update can hold
/// the response open. 20 MB total: one max-size file, or several small
/// ones.
let maxCumulativeDownloadBytes: Int64 = 20 * 1024 * 1024

/// Wall-clock budget for the whole download batch, checked between
/// files. Telegram redelivers updates it considers unacknowledged, so
/// the synchronous path must stay comfortably below Telegram's patience
/// (and our own claim lease).
let maxDownloadWallClockSeconds: TimeInterval = 30

/// Per-file HTTP timeout for the bytes download. Files under the 20 MB
/// cap complete in single-digit seconds on any sane link; 15 s is the
/// "something is wrong, give up on this file" threshold.
let perFileDownloadTimeoutMs = 15_000

/// Outcome of the inbound media pass: attachments that landed on disk,
/// plus human-readable failure notes (surfaced to the agent in the
/// prompt header so a lost attachment is explicit, never silent).
struct InboundMediaResult {
  var attachments: [InboundAttachment] = []
  var failures: [String] = []
}

/// Downloads every media attachment on `message` for `agentId`, bounded
/// by per-file size (20 MB, Telegram's own getFile cap), a cumulative
/// per-update byte budget, a per-file HTTP timeout, and a wall-clock
/// budget across the batch. Failures don't abort the rest of the batch
/// (one bad file shouldn't drop the whole user turn); each one is
/// recorded in `failures` so the agent hears about it.
///
/// Pre-claims each path via `state.claimArtifactUpload(_:)` BEFORE the
/// file lands so the host's artifact watcher's `invoke(type: "artifact")`
/// fire short-circuits in `handleArtifactShare` — otherwise we'd ping-
/// pong the user's own upload back to them.
func downloadInboundMedia(
  state: AgentState, agentId: String, message: TGUpdate.Message
) -> InboundMediaResult {
  let candidates = collectCandidates(message)
  if candidates.isEmpty { return InboundMediaResult() }

  guard let token = state.botToken, !token.isEmpty else {
    logWarn("inbound media: no bot_token configured; skipping \(candidates.count) attachment(s)")
    return InboundMediaResult(
      failures: candidates.map { "\($0.kind): skipped (bot token unavailable)" })
  }

  let chatId = message.chat.id
  let messageId = message.message_id
  guard
    let dir = inboundMessageDir(
      agentId: agentId, chatId: chatId, messageId: messageId)
  else {
    logWarn("inbound media: cannot resolve artifact directory; skipping")
    return InboundMediaResult(
      failures: candidates.map { "\($0.kind): skipped (no artifact directory)" })
  }

  do {
    try FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true, attributes: nil)
  } catch {
    logWarn(
      "inbound media: failed to mkdir \(dir.path): \(error.localizedDescription) — skipping")
    return InboundMediaResult(
      failures: candidates.map { "\($0.kind): skipped (artifact directory unavailable)" })
  }

  var result = InboundMediaResult()
  var remainingBudget = maxCumulativeDownloadBytes
  let deadline = Date().addingTimeInterval(maxDownloadWallClockSeconds)
  for candidate in candidates {
    if Date() > deadline {
      logWarn("inbound media: wall-clock budget exhausted; skipping \(candidate.kind)")
      result.failures.append("\(candidate.kind): skipped (download time budget exhausted)")
      continue
    }
    switch downloadOne(
      token: token, candidate: candidate, dir: dir, state: state,
      byteBudget: remainingBudget)
    {
    case .downloaded(let attachment, let bytes):
      remainingBudget -= bytes
      result.attachments.append(attachment)
    case .failed(let reason):
      result.failures.append("\(candidate.kind): \(reason)")
    }
  }
  return result
}

/// Result of one candidate download. `bytes` feeds the cumulative
/// budget; cached files count too (they occupied the budget when first
/// fetched, and counting them keeps retry behaviour identical to the
/// first delivery).
private enum DownloadOutcome {
  case downloaded(InboundAttachment, bytes: Int64)
  case failed(reason: String)
}

/// Downloads one candidate file. Centralises the size check, file naming,
/// pre-claim, and on-disk write.
private func downloadOne(
  token: String, candidate: InboundCandidate, dir: URL, state: AgentState,
  byteBudget: Int64
) -> DownloadOutcome {
  guard let descriptor = telegramGetFile(token: token, fileId: candidate.fileId) else {
    logWarn(
      "inbound media: getFile failed for kind=\(candidate.kind) "
        + "file_id=\(String(candidate.fileId.prefix(16)))…")
    return .failed(reason: "download failed (could not resolve file)")
  }

  if descriptor.fileSize > maxDownloadBytes {
    logWarn(
      "inbound media: skipping \(candidate.kind) (\(descriptor.fileSize) bytes > "
        + "\(maxDownloadBytes) byte cap)")
    return .failed(reason: "skipped (file exceeds \(maxDownloadBytes / (1024 * 1024)) MB limit)")
  }

  if descriptor.fileSize > byteBudget {
    logWarn(
      "inbound media: skipping \(candidate.kind) (\(descriptor.fileSize) bytes exceeds "
        + "remaining per-update budget \(byteBudget))")
    return .failed(reason: "skipped (per-message download budget exhausted)")
  }

  // Resolve final filename + MIME. Telegram-supplied filename wins when
  // present; otherwise fall back to a synthesised name keyed on the
  // file's globally unique id so retries / duplicates collide
  // deterministically.
  let mime =
    candidate.suggestedMime
    ?? (candidate.suggestedName.map(mimeFromExtension) ?? "application/octet-stream")
  let filename: String
  if let raw = candidate.suggestedName, !raw.isEmpty {
    filename = sanitizeFilename(raw)
  } else {
    filename = defaultFilename(
      kind: candidate.kind, fileUniqueId: candidate.fileUniqueId, mimeType: mime)
  }

  let destination = dir.appendingPathComponent(filename, isDirectory: false)

  // Pre-claim BEFORE write. The host's artifact watcher races us and
  // fires `invoke(type: "artifact")` the instant the file appears under
  // `~/.osaurus/artifacts/`. If the watcher beats this method to the
  // claim it would auto-forward the file back to the sender.
  _ = state.claimArtifactUpload(destination.path)

  // Idempotent on the wire: a Telegram retry of the same update won't
  // re-download (the file already exists). We still pre-claim above so
  // a second-pass retry doesn't accidentally trigger the auto-forward.
  if FileManager.default.fileExists(atPath: destination.path) {
    let size =
      (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64)
      .flatMap { $0 } ?? 0
    return .downloaded(
      InboundAttachment(path: destination.path, mimeType: mime, kind: candidate.kind),
      bytes: size)
  }

  guard
    let bytes = telegramDownloadFile(
      token: token, filePath: descriptor.filePath,
      timeoutMs: perFileDownloadTimeoutMs)
  else {
    logWarn(
      "inbound media: download failed for kind=\(candidate.kind) "
        + "telegram_path=\(descriptor.filePath)")
    return .failed(reason: "download failed (transfer error or timeout)")
  }

  do {
    try bytes.write(to: destination, options: .atomic)
  } catch {
    logWarn(
      "inbound media: write failed at \(destination.path): \(error.localizedDescription)")
    return .failed(reason: "download failed (could not write file)")
  }

  logDebug(
    "inbound media: stashed kind=\(candidate.kind) bytes=\(bytes.count) "
      + "mime=\(mime) path=\(destination.path)")
  return .downloaded(
    InboundAttachment(path: destination.path, mimeType: mime, kind: candidate.kind),
    bytes: Int64(bytes.count))
}

// MARK: - Prompt header rendering

/// Renders the attachment list into a single bracketed segment for the
/// prompt header, e.g.
///
///   [attachments path1=/abs/path.jpg type=image/jpeg kind=photo, path2=...]
///
/// Returns nil when the list is empty so the caller can omit the
/// segment entirely. Each path is exposed verbatim so the agent can
/// hand it straight to its sandbox file tools.
func renderAttachmentsHeader(_ attachments: [InboundAttachment]) -> String? {
  guard !attachments.isEmpty else { return nil }
  let parts = attachments.enumerated().map { index, a -> String in
    "path\(index + 1)=\(a.path) type=\(a.mimeType) kind=\(a.kind)"
  }
  return "[attachments \(parts.joined(separator: ", "))]"
}

/// Renders download failures into an explicit header segment so the agent
/// (and, through it, the user) learns an attachment was lost rather than
/// silently answering as if it never existed. Returns nil when empty.
func renderAttachmentFailuresHeader(_ failures: [String]) -> String? {
  guard !failures.isEmpty else { return nil }
  return "[attachment_errors \(failures.joined(separator: "; "))]"
}
