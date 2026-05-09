import Foundation

// MARK: - Tool Envelope
//
// The tool wire format the agent reads back from each `invoke` result:
//   success: { "ok": true, "data": {...}, "summary": "..." }
//   error:   { "ok": false, "error": "<code>", "message": "..." }
// See Osaurus TOOL_CONTRACT for the canonical schema.

func toolEnvelopeSuccess(
  _ data: [String: Any] = [:],
  summary: String? = nil
) -> String {
  var envelope: [String: Any] = ["ok": true, "data": data]
  if let summary { envelope["summary"] = summary }
  return makeJSONString(envelope) ?? #"{"ok":true,"data":{}}"#
}

func toolEnvelopeError(_ code: String, _ message: String) -> String {
  let envelope: [String: Any] = [
    "ok": false,
    "error": code,
    "message": message,
  ]
  return makeJSONString(envelope)
    ?? #"{"ok":false,"error":"internal","message":"envelope serialize failed"}"#
}
