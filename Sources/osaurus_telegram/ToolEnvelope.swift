import Foundation

// MARK: - Tool Envelope (success)
//
// The success wire format the agent reads back from each `invoke` result:
//   success: { "ok": true, "data": {...}, "summary": "..." }
//
// Tool FAILURES use the canonical envelope produced by `Envelope.failure`
// (see Envelope.swift): { "ok": false, "kind": "<kind>", "message": "...",
// "retryable": <bool> }. The host auto-wraps any non-envelope tool output
// as a success, so error paths must never return an ad-hoc shape.

func toolEnvelopeSuccess(
  _ data: [String: Any] = [:],
  summary: String? = nil
) -> String {
  var envelope: [String: Any] = ["ok": true, "data": data]
  if let summary { envelope["summary"] = summary }
  return makeJSONString(envelope) ?? #"{"ok":true,"data":{}}"#
}
