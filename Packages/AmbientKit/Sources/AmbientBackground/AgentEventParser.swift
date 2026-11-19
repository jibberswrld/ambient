import Foundation
import AmbientContracts

struct ParsedAgentEvent {
    var activity: String?
    var transcript: String?
    var sessionID: String?
    var result: String?
    var failure: String?
}

struct AgentEventParser {
    static func parse(_ line: String, kind: BackgroundTask.Kind) -> ParsedAgentEvent {
        guard let data = line.data(using: .utf8),
              let event = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return ParsedAgentEvent(transcript: line)
        }
        let type = event["type"]?.stringValue ?? ""
        if kind == .codexAgent {
            switch type {
            case "thread.started":
                return ParsedAgentEvent(activity: "Starting Codex", sessionID: event["thread_id"]?.stringValue)
            case "item.started", "item.updated", "item.completed":
                guard let item = event["item"] else { return ParsedAgentEvent() }
                switch item["type"]?.stringValue {
                case "agent_message":
                    let text = item["text"]?.stringValue
                    return ParsedAgentEvent(activity: text.map(singleLine), transcript: text,
                                            result: type == "item.completed" ? text : nil)
                case "reasoning":
                    let text = item["text"]?.stringValue
                    return ParsedAgentEvent(activity: text.map(singleLine), transcript: text)
                case "command_execution":
                    let command = item["command"]?.stringValue ?? "command"
                    let output = item["aggregated_output"]?.stringValue ?? ""
                    return ParsedAgentEvent(activity: "Running: \(singleLine(command))",
                        transcript: type == "item.completed" ? "$ \(command)\n\(output)" : "$ \(command)")
                case "file_change":
                    let paths = item["changes"]?.arrayValue?.compactMap { $0["path"]?.stringValue } ?? []
                    let description = "Editing \(paths.joined(separator: ", "))"
                    return ParsedAgentEvent(activity: singleLine(description), transcript: description)
                case "mcp_tool_call":
                    let description = "Using \(item["server"]?.stringValue ?? "tool").\(item["tool"]?.stringValue ?? "")"
                    return ParsedAgentEvent(activity: description, transcript: description)
                case "web_search": return ParsedAgentEvent(activity: "Searching the web", transcript: "Searching the web")
                case "error": return ParsedAgentEvent(transcript: item["message"]?.stringValue)
                default: return ParsedAgentEvent()
                }
            case "turn.failed":
                let message = event["error"]?["message"]?.stringValue ?? "Codex turn failed."
                return ParsedAgentEvent(activity: singleLine(message), transcript: message, failure: message)
            case "error": return ParsedAgentEvent(transcript: event["message"]?.stringValue)
            default: return ParsedAgentEvent()
            }
        }
        switch type {
        case "system":
            return ParsedAgentEvent(activity: "Starting Claude Code", sessionID: event["session_id"]?.stringValue)
        case "assistant":
            let blocks = event["message"]?["content"]?.arrayValue ?? []
            var readable: [String] = []
            var activity: String?
            for block in blocks {
                switch block["type"]?.stringValue {
                case "text":
                    if let text = block["text"]?.stringValue { readable.append(text); activity = singleLine(text) }
                case "tool_use":
                    let input = block["input"]
                    let name = block["name"]?.stringValue ?? "tool"
                    let detail = input?["command"]?.stringValue ?? input?["file_path"]?.stringValue ?? ""
                    let description = "\(name): \(detail)"
                    readable.append(description)
                    activity = singleLine(description)
                default: break
                }
            }
            return ParsedAgentEvent(activity: activity, transcript: readable.isEmpty ? nil : readable.joined(separator: "\n"))
        case "user":
            let output = event["message"]?["content"]?.arrayValue?.compactMap { block -> String? in
                guard block["type"]?.stringValue == "tool_result" else { return nil }
                if let text = block["content"]?.stringValue { return text }
                return block["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
            }.joined(separator: "\n")
            return ParsedAgentEvent(transcript: output)
        case "result":
            let result = event["result"]?.stringValue ?? event["errors"]?.arrayValue?.compactMap(\.stringValue).joined(separator: "\n")
            let failed = event["is_error"]?.boolValue == true || event["subtype"]?.stringValue != "success"
            return ParsedAgentEvent(transcript: result, sessionID: event["session_id"]?.stringValue,
                                    result: failed ? nil : result, failure: failed ? (result ?? "Claude Code turn failed.") : nil)
        default: return ParsedAgentEvent()
        }
    }

    static func singleLine(_ text: String) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(240))
    }
}
