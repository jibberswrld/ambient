use std::{collections::BTreeMap, sync::Arc, time::Duration};

use ambient_contracts::{
    AgentFailure, AiCredential, AiCredentialSource, ImageAttachment, ModelTier,
    TextCompletionService, ToolDefinition,
};
use async_trait::async_trait;
use base64::{engine::general_purpose::STANDARD, Engine};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::publik;

pub(crate) fn failure(message: impl Into<String>) -> AgentFailure {
    AgentFailure::Other {
        message: message.into(),
    }
}
fn transport_failure(error: reqwest::Error) -> AgentFailure {
    // Request URLs may contain private query parameters; retain only the transport explanation.
    failure(error.without_url().to_string())
}
pub(crate) fn decode_json(data: &[u8]) -> Result<Value, AgentFailure> {
    serde_json::from_slice(data).map_err(|error| failure(error.to_string()))
}

#[derive(Default)]
pub struct PublikCredentialSource {
    user_credential: Option<AiCredential>,
}
impl PublikCredentialSource {
    pub fn new(user_credential: Option<AiCredential>) -> Self {
        Self { user_credential }
    }
}
#[async_trait]
impl AiCredentialSource for PublikCredentialSource {
    async fn credential(&self) -> Option<AiCredential> {
        let user_key = self
            .user_credential
            .as_ref()
            .map(|credential| (credential.base_url.clone(), credential.api_key.clone()));
        let (base_url, api_key) = match publik::resolve_provider(user_key) {
            publik::Provider::Own { base_url, api_key }
            | publik::Provider::Publik { base_url, api_key } => (base_url, api_key),
            publik::Provider::NeedsOwnKey => return None,
        };
        let url = reqwest::Url::parse(&base_url).ok()?;
        if !matches!(url.scheme(), "http" | "https") {
            return None;
        }
        Some(AiCredential { base_url, api_key })
    }
}

#[derive(Clone, Serialize, Deserialize, Default)]
pub(crate) struct ChatFunction {
    pub name: String,
    pub arguments: String,
}
#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct ChatToolCall {
    pub id: String,
    pub r#type: String,
    pub function: ChatFunction,
}
#[derive(Clone, Serialize)]
pub(crate) struct ChatMessage {
    pub role: String,
    pub content: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_calls: Option<Vec<ChatToolCall>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
}
impl ChatMessage {
    pub fn new(role: &str, content: Value) -> Self {
        Self {
            role: role.into(),
            content,
            tool_calls: None,
            tool_call_id: None,
        }
    }
    pub fn user(text: &str, images: &[ImageAttachment]) -> Self {
        if images.is_empty() {
            return Self::new("user", json!(text));
        }
        let mut parts = vec![json!({"type":"text", "text":text})];
        for image in images {
            if !image.label.is_empty() {
                parts.push(json!({"type":"text", "text":image.label}));
            }
            parts.push(json!({"type":"image_url", "image_url":{"url":format!("data:{};base64,{}",image.mime_type,STANDARD.encode(&image.data))}}));
        }
        Self::new("user", json!(parts))
    }
    pub fn removing_images(&self) -> Self {
        let mut message = self.clone();
        if let Some(parts) = self.content.as_array() {
            message.content = json!(parts
                .iter()
                .filter_map(|part| part["text"].as_str())
                .collect::<Vec<_>>()
                .join("\n"));
        }
        message
    }
}
#[derive(Default)]
pub(crate) struct ChatReply {
    pub text: String,
    pub tool_calls: Vec<ChatToolCall>,
}

#[derive(Clone)]
pub struct PublikAiClient {
    pub(crate) credential_source: Arc<dyn AiCredentialSource>,
    http_client: reqwest::Client,
}
impl PublikAiClient {
    pub const MAXIMUM_REQUEST_BYTES: usize = 4_000_000;
    pub const HISTORY_REQUEST_BUDGET: usize = 3_800_000;

    pub fn new(credential_source: Arc<dyn AiCredentialSource>) -> Self {
        Self {
            credential_source,
            http_client: reqwest::Client::new(),
        }
    }
    pub(crate) fn chat_body(
        &self,
        messages: &[ChatMessage],
        tools: &[ToolDefinition],
        tier: ModelTier,
        reasoning_effort: Option<&str>,
        streaming: bool,
    ) -> Result<Vec<u8>, AgentFailure> {
        let mut body = json!({"model":tier.model_name(), "messages":messages, "stream":streaming});
        if !tools.is_empty() {
            body["tools"] = json!(tools.iter().map(|tool| json!({"type":"function", "function":{"name":tool.name, "description":tool.description, "parameters":tool.parameters_json_schema}})).collect::<Vec<_>>());
        }
        if let Some(reasoning_effort) = reasoning_effort {
            body["reasoning_effort"] = json!(reasoning_effort);
        }
        serde_json::to_vec(&body).map_err(|error| failure(error.to_string()))
    }
    async fn request(
        &self,
        path: &str,
        body: Vec<u8>,
        content_type: &str,
    ) -> Result<reqwest::RequestBuilder, AgentFailure> {
        if body.len() >= Self::MAXIMUM_REQUEST_BYTES {
            return Err(failure(
                "This request is too large. Use fewer or smaller images, audio, or text.",
            ));
        }
        let credential = self
            .credential_source
            .credential()
            .await
            .filter(|credential| !credential.api_key.is_empty())
            .ok_or(AgentFailure::NotSignedIn)?;
        Ok(self
            .http_client
            .post(format!(
                "{}/{}",
                credential.base_url.trim_end_matches('/'),
                path
            ))
            .timeout(Duration::from_secs(120))
            .bearer_auth(&credential.api_key)
            .header("Content-Type", content_type)
            .body(body))
    }
    pub(crate) async fn post(
        &self,
        path: &str,
        body: Vec<u8>,
        content_type: &str,
    ) -> Result<Vec<u8>, AgentFailure> {
        let request = self.request(path, body, content_type).await?;
        for attempt in 0..=2 {
            let response = request
                .try_clone()
                .expect("byte bodies can be cloned")
                .send()
                .await
                .map_err(transport_failure)?;
            if retry_rate_limit(&response, attempt).await {
                continue;
            }
            let status = response.status().as_u16();
            let data = response.bytes().await.map_err(transport_failure)?;
            validate(status, &data)?;
            return Ok(data.to_vec());
        }
        Err(failure("publik is rate limited. Try again shortly."))
    }
    pub(crate) async fn stream(
        &self,
        body: Vec<u8>,
        on_text: impl Fn(String),
    ) -> Result<ChatReply, AgentFailure> {
        let request = self
            .request("chat/completions", body, "application/json")
            .await?
            .header("Accept", "text/event-stream");
        for attempt in 0..=2 {
            let response = request
                .try_clone()
                .expect("byte bodies can be cloned")
                .send()
                .await
                .map_err(transport_failure)?;
            if !response.status().is_success() {
                let retry_delay = rate_limit_delay(&response, attempt);
                let status = response.status().as_u16();
                let mut bytes = response.bytes_stream();
                let mut data = Vec::new();
                while let Some(chunk) = bytes.next().await {
                    let chunk = chunk.map_err(transport_failure)?;
                    data.extend_from_slice(&chunk[..chunk.len().min(65_536 - data.len())]);
                    if data.len() >= 65_536 {
                        break;
                    }
                }
                if let Some(delay) = retry_delay {
                    tokio::time::sleep(delay).await;
                    continue;
                }
                validate(status, &data)?;
                unreachable!("non-success status always fails validation");
            }
            let mut parser = ChatEventParser::default();
            let mut lines = ServerSentEventLineParser::default();
            let mut event_lines = Vec::new();
            let mut bytes = response.bytes_stream();
            while let Some(chunk) = bytes.next().await {
                for byte in chunk.map_err(transport_failure)? {
                    let Some(line) = lines.append(byte) else {
                        continue;
                    };
                    if line.is_empty() {
                        if parser.consume(&event_lines.join("\n"), &on_text)? {
                            return parser.reply();
                        }
                        event_lines.clear();
                    } else if let Some(value) = line.strip_prefix("data:") {
                        event_lines.push(value.strip_prefix(' ').unwrap_or(value).to_string());
                    }
                }
            }
            if !event_lines.is_empty() {
                parser.consume(&event_lines.join("\n"), &on_text)?;
            }
            if !parser.received_finish {
                return Err(failure(
                    "The model's response ended unexpectedly. Try again.",
                ));
            }
            return parser.reply();
        }
        Err(failure("publik is rate limited. Try again shortly."))
    }
}
#[async_trait]
impl TextCompletionService for PublikAiClient {
    async fn complete(
        &self,
        system_prompt: &str,
        user_prompt: &str,
        tier: ModelTier,
    ) -> Result<String, AgentFailure> {
        let messages = [
            ChatMessage::new("system", json!(system_prompt)),
            ChatMessage::user(user_prompt, &[]),
        ];
        let body = self.chat_body(&messages, &[], tier, None, false)?;
        let response = decode_json(
            &self
                .post("chat/completions", body, "application/json")
                .await?,
        )?;
        response["choices"][0]["message"]["content"]
            .as_str()
            .map(String::from)
            .ok_or_else(|| failure("publik returned no completion text."))
    }
}
fn validate(status: u16, data: &[u8]) -> Result<(), AgentFailure> {
    if (200..300).contains(&status) {
        return Ok(());
    }
    let body = serde_json::from_slice::<Value>(data).unwrap_or(Value::Null);
    let error = &body["error"];
    let message = error["message"]
        .as_str()
        .map(String::from)
        .unwrap_or_else(|| format!("publik API answered {status}."));
    Err(match status {
        401 => AgentFailure::NotSignedIn,
        402 => AgentFailure::PaymentRequired {
            message,
            top_up_url: error["top_up_url"].as_str().map(String::from),
        },
        _ => failure(message),
    })
}
fn rate_limit_delay(response: &reqwest::Response, attempt: usize) -> Option<Duration> {
    if response.status() != 429 || attempt >= 2 {
        return None;
    }
    let delay = match response.headers().get("Retry-After") {
        None => 1.0,
        Some(header) => {
            let header = header.to_str().ok()?;
            if let Ok(seconds) = header.parse::<f64>() {
                if !seconds.is_finite() {
                    return None;
                }
                seconds.max(0.0)
            } else {
                let date = chrono::DateTime::parse_from_rfc2822(header).ok()?;
                (date
                    .signed_duration_since(chrono::Utc::now())
                    .num_milliseconds() as f64
                    / 1000.0)
                    .max(0.0)
            }
        }
    };
    if delay > 5.0 {
        None
    } else {
        Some(Duration::from_secs_f64(delay))
    }
}
async fn retry_rate_limit(response: &reqwest::Response, attempt: usize) -> bool {
    if let Some(delay) = rate_limit_delay(response, attempt) {
        tokio::time::sleep(delay).await;
        true
    } else {
        false
    }
}
#[derive(Default)]
struct ChatEventParser {
    text: String,
    calls: BTreeMap<usize, ChatToolCall>,
    received_finish: bool,
}
impl ChatEventParser {
    fn consume(&mut self, event: &str, on_text: &impl Fn(String)) -> Result<bool, AgentFailure> {
        if event.is_empty() {
            return Ok(false);
        }
        if event == "[DONE]" {
            self.received_finish = true;
            return Ok(true);
        }
        let chunk = decode_json(event.as_bytes())?;
        if let Some(error) = chunk.get("error") {
            return Err(failure(
                error["message"]
                    .as_str()
                    .unwrap_or("The model stream failed."),
            ));
        }
        for choice in chunk["choices"].as_array().into_iter().flatten() {
            if choice["index"].as_f64().unwrap_or(0.0) != 0.0 {
                continue;
            }
            if let Some(reason) = choice["finish_reason"].as_str() {
                if !["stop", "tool_calls", "function_call"].contains(&reason) {
                    return Err(failure(format!(
                        "The model stopped before completing its reply ({reason})."
                    )));
                }
                self.received_finish = true;
            }
            let delta = &choice["delta"];
            if let Some(fragment) = delta["content"].as_str() {
                self.text.push_str(fragment);
                on_text(fragment.into());
            }
            for fragment in delta["tool_calls"].as_array().into_iter().flatten() {
                let index = fragment["index"]
                    .as_f64()
                    .filter(|index| *index >= 0.0 && *index < 128.0 && index.fract() == 0.0)
                    .ok_or_else(|| failure("The model returned an invalid tool-call index."))?
                    as usize;
                let call = self.calls.entry(index).or_insert_with(|| ChatToolCall {
                    id: String::new(),
                    r#type: "function".into(),
                    function: ChatFunction::default(),
                });
                if let Some(id) = fragment["id"].as_str() {
                    call.id.push_str(id);
                }
                if let Some(name) = fragment["function"]["name"].as_str() {
                    call.function.name.push_str(name);
                }
                if let Some(arguments) = fragment["function"]["arguments"].as_str() {
                    call.function.arguments.push_str(arguments);
                }
            }
        }
        Ok(false)
    }
    fn reply(self) -> Result<ChatReply, AgentFailure> {
        let calls: Vec<_> = self.calls.into_values().collect();
        let identifiers: std::collections::HashSet<_> = calls.iter().map(|call| &call.id).collect();
        if calls.iter().any(|call| call.id.is_empty()) || identifiers.len() != calls.len() {
            return Err(failure("The model returned tool calls without unique IDs."));
        }
        Ok(ChatReply {
            text: self.text,
            tool_calls: calls,
        })
    }
}
#[derive(Default)]
struct ServerSentEventLineParser {
    buffer: Vec<u8>,
    previous_was_carriage_return: bool,
}
impl ServerSentEventLineParser {
    fn append(&mut self, byte: u8) -> Option<String> {
        if byte == b'\n' && self.previous_was_carriage_return {
            self.previous_was_carriage_return = false;
            return None;
        }
        self.previous_was_carriage_return = byte == b'\r';
        if byte == b'\n' || byte == b'\r' {
            let line = String::from_utf8_lossy(&self.buffer).into_owned();
            self.buffer.clear();
            Some(line)
        } else {
            self.buffer.push(byte);
            None
        }
    }
}
