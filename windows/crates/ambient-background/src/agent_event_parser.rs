use ambient_contracts::BackgroundTaskKind;
use serde_json::Value;

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct ParsedAgentEvent {
    pub activity: Option<String>,
    pub transcript: Option<String>,
    pub session_id: Option<String>,
    pub result: Option<String>,
    pub failure: Option<String>,
}

pub struct AgentEventParser;

impl AgentEventParser {
    pub fn single_line(text: &str) -> String {
        use unicode_segmentation::UnicodeSegmentation;
        let collapsed = text.split_whitespace().collect::<Vec<_>>().join(" ");
        collapsed.graphemes(true).take(240).collect()
    }

    pub fn parse(line: &str, kind: BackgroundTaskKind) -> ParsedAgentEvent {
        let Ok(event) = serde_json::from_str::<Value>(line) else {
            return ParsedAgentEvent {
                transcript: Some(line.into()),
                ..Default::default()
            };
        };
        let event_type = event["type"].as_str().unwrap_or("");
        let mut parsed = ParsedAgentEvent::default();
        if kind == BackgroundTaskKind::CodexAgent {
            match event_type {
                "thread.started" => {
                    parsed.activity = Some("Starting Codex".into());
                    parsed.session_id = string(&event["thread_id"]);
                }
                "item.started" | "item.updated" | "item.completed" => {
                    let item = &event["item"];
                    match item["type"].as_str().unwrap_or("") {
                        "agent_message" | "reasoning" => {
                            parsed.transcript = string(&item["text"]);
                            parsed.activity = parsed.transcript.as_deref().map(Self::single_line);
                            if item["type"] == "agent_message" && event_type == "item.completed" {
                                parsed.result = parsed.transcript.clone();
                            }
                        }
                        "command_execution" => {
                            let command = item["command"].as_str().unwrap_or("command");
                            parsed.activity =
                                Some(format!("Running: {}", Self::single_line(command)));
                            parsed.transcript = Some(if event_type == "item.completed" {
                                format!(
                                    "$ {command}\n{}",
                                    item["aggregated_output"].as_str().unwrap_or("")
                                )
                            } else {
                                format!("$ {command}")
                            });
                        }
                        "file_change" => {
                            let paths = item["changes"]
                                .as_array()
                                .map(|changes| {
                                    changes
                                        .iter()
                                        .filter_map(|change| change["path"].as_str())
                                        .collect::<Vec<_>>()
                                })
                                .unwrap_or_default();
                            let description = format!("Editing {}", paths.join(", "));
                            parsed.activity = Some(Self::single_line(&description));
                            parsed.transcript = Some(description);
                        }
                        "mcp_tool_call" => {
                            let description = format!(
                                "Using {}.{}",
                                item["server"].as_str().unwrap_or("tool"),
                                item["tool"].as_str().unwrap_or("")
                            );
                            parsed.activity = Some(description.clone());
                            parsed.transcript = Some(description);
                        }
                        "web_search" => {
                            parsed.activity = Some("Searching the web".into());
                            parsed.transcript = parsed.activity.clone();
                        }
                        "error" => parsed.transcript = string(&item["message"]),
                        _ => {}
                    }
                }
                "turn.failed" => {
                    let message = event["error"]["message"]
                        .as_str()
                        .unwrap_or("Codex turn failed.");
                    parsed.activity = Some(Self::single_line(message));
                    parsed.transcript = Some(message.into());
                    parsed.failure = Some(message.into());
                }
                "error" => parsed.transcript = string(&event["message"]),
                _ => {}
            }
            return parsed;
        }
        match event_type {
            "system" => {
                parsed.activity = Some("Starting Claude Code".into());
                parsed.session_id = string(&event["session_id"]);
            }
            "assistant" => {
                let mut readable = Vec::new();
                if let Some(blocks) = event["message"]["content"].as_array() {
                    for block in blocks {
                        match block["type"].as_str().unwrap_or("") {
                            "text" => {
                                if let Some(text) = block["text"].as_str() {
                                    readable.push(text.to_owned());
                                    parsed.activity = Some(Self::single_line(text));
                                }
                            }
                            "tool_use" => {
                                let detail = block["input"]["command"]
                                    .as_str()
                                    .or_else(|| block["input"]["file_path"].as_str())
                                    .unwrap_or("");
                                let description = format!(
                                    "{}: {detail}",
                                    block["name"].as_str().unwrap_or("tool")
                                );
                                parsed.activity = Some(Self::single_line(&description));
                                readable.push(description);
                            }
                            _ => {}
                        }
                    }
                }
                if !readable.is_empty() {
                    parsed.transcript = Some(readable.join("\n"));
                }
            }
            "user" => {
                if let Some(blocks) = event["message"]["content"].as_array() {
                    parsed.transcript = Some(
                        blocks
                            .iter()
                            .filter(|block| block["type"] == "tool_result")
                            .filter_map(|block| {
                                string(&block["content"]).or_else(|| {
                                    block["content"].as_array().map(|content| {
                                        content
                                            .iter()
                                            .filter_map(|item| item["text"].as_str())
                                            .collect::<Vec<_>>()
                                            .join("\n")
                                    })
                                })
                            })
                            .collect::<Vec<_>>()
                            .join("\n"),
                    );
                }
            }
            "result" => {
                let result = string(&event["result"]).or_else(|| {
                    event["errors"].as_array().map(|errors| {
                        errors
                            .iter()
                            .filter_map(Value::as_str)
                            .collect::<Vec<_>>()
                            .join("\n")
                    })
                });
                let failed = event["is_error"].as_bool() == Some(true)
                    || event["subtype"].as_str() != Some("success");
                parsed.transcript = result.clone();
                parsed.session_id = string(&event["session_id"]);
                if failed {
                    parsed.failure =
                        Some(result.unwrap_or_else(|| "Claude Code turn failed.".into()));
                } else {
                    parsed.result = result;
                }
            }
            _ => {}
        }
        parsed
    }
}

fn string(value: &Value) -> Option<String> {
    value.as_str().map(str::to_owned)
}
