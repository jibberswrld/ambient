use ambient_contracts::{
    AiCredential, AiCredentialSource, AmbientTool, ConnectorApp, ConnectorService, ToolDefinition,
    ToolProvider, ToolResult,
};
use async_trait::async_trait;
use reqwest::{Client, Url};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::HashSet,
    future::Future,
    pin::Pin,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::Mutex;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AmbientConnectorError {
    NotSignedIn,
    Unavailable,
    InvalidResponse,
    Service(String),
}
impl std::fmt::Display for AmbientConnectorError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(match self {
            Self::NotSignedIn => "Sign in with publik to use app connections.",
            Self::Unavailable => {
                "App connections are unreachable. Check your connection and try again."
            }
            Self::InvalidResponse => {
                "App connections returned an unreadable response. Please try again."
            }
            Self::Service(message) => message,
        })
    }
}
impl std::error::Error for AmbientConnectorError {}

pub struct AmbientConnectorClient {
    pub origin: String,
    credential_source: Arc<dyn AiCredentialSource>,
    http: Client,
}
impl AmbientConnectorClient {
    pub fn new(credential_source: Arc<dyn AiCredentialSource>) -> Self {
        let origin = std::env::var("AMBIENT_CONNECTOR_ORIGIN")
            .ok()
            .filter(|value| Url::parse(value).is_ok())
            .unwrap_or_else(|| "http://127.0.0.1:3019".into());
        Self::with_origin(origin, credential_source)
    }
    pub fn with_origin(
        origin: impl Into<String>,
        credential_source: Arc<dyn AiCredentialSource>,
    ) -> Self {
        Self {
            origin: origin.into(),
            credential_source,
            http: Client::new(),
        }
    }
    async fn current_credential(&self) -> Result<AiCredential, AmbientConnectorError> {
        self.credential_source
            .credential()
            .await
            .filter(|credential| {
                credential.api_key.starts_with("pk_")
                    && !credential.api_key.chars().any(char::is_whitespace)
            })
            .ok_or(AmbientConnectorError::NotSignedIn)
    }
    async fn request<T: serde::de::DeserializeOwned>(
        &self,
        path: &str,
        query: &[(&str, &str)],
        body: Option<Value>,
        credential: &AiCredential,
    ) -> Result<T, AmbientConnectorError> {
        let mut url =
            Url::parse(&self.origin).map_err(|_| AmbientConnectorError::InvalidResponse)?;
        let path = format!("{}/{}", url.path().trim_end_matches('/'), path);
        url.set_path(&path);
        if !query.is_empty() {
            url.query_pairs_mut()
                .clear()
                .extend_pairs(query.iter().copied());
        }
        if !(url.scheme() == "https"
            || (url.scheme() == "http"
                && matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"))))
        {
            return Err(AmbientConnectorError::Service(
                "App connections need an HTTPS connector address, or a local development server."
                    .into(),
            ));
        }
        let mut request = if body.is_some() {
            self.http.post(url)
        } else {
            self.http.get(url)
        };
        request = request
            .bearer_auth(&credential.api_key)
            .header("Accept", "application/json")
            .timeout(Duration::from_secs(if body.is_some() { 300 } else { 45 }));
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request
            .send()
            .await
            .map_err(|_| AmbientConnectorError::Unavailable)?;
        let status = response.status();
        let data = response
            .bytes()
            .await
            .map_err(|_| AmbientConnectorError::Unavailable)?;
        if status.as_u16() == 401 {
            return Err(AmbientConnectorError::NotSignedIn);
        }
        if !status.is_success() {
            let message = serde_json::from_slice::<Value>(&data)
                .ok()
                .and_then(|value| value["error"]["message"].as_str().map(str::to_owned))
                .unwrap_or_else(|| {
                    "App connections could not complete this request. Please try again.".into()
                });
            return Err(AmbientConnectorError::Service(message));
        }
        serde_json::from_slice(&data).map_err(|_| AmbientConnectorError::InvalidResponse)
    }
}
#[derive(Deserialize)]
struct ApplicationsResponse {
    apps: Vec<Application>,
    #[serde(rename = "nextCursor")]
    next_cursor: Option<String>,
}
#[derive(Deserialize)]
struct Application {
    slug: String,
    name: String,
    #[serde(rename = "logoURL")]
    logo_url: Option<String>,
    #[serde(rename = "isConnected")]
    is_connected: bool,
}
#[derive(Clone, Deserialize)]
struct RouterSession {
    #[serde(rename = "sessionId")]
    session_id: String,
    tools: Vec<FunctionTool>,
    #[serde(rename = "systemPrompt")]
    system_prompt: Option<String>,
}
#[derive(Clone, Deserialize)]
struct FunctionTool {
    #[serde(rename = "type")]
    kind: String,
    function: Function,
}
#[derive(Clone, Deserialize)]
struct Function {
    name: String,
    description: Option<String>,
    parameters: Value,
}
#[derive(Deserialize)]
struct AuthorizationResponse {
    #[serde(rename = "authorizationURL")]
    authorization_url: String,
}
#[derive(Deserialize)]
struct DisconnectionResponse {
    ok: bool,
}
#[derive(Deserialize)]
struct ExecutionResponse {
    result: Value,
}
#[async_trait]
impl ConnectorService for AmbientConnectorClient {
    async fn apps(&self, matching_query: &str) -> Result<Vec<ConnectorApp>, String> {
        let credential = self
            .current_credential()
            .await
            .map_err(|error| error.to_string())?;
        let mut applications = Vec::new();
        let mut cursor: Option<String> = None;
        let mut visited_cursors = HashSet::new();
        loop {
            let mut query = vec![("query", matching_query)];
            if let Some(cursor) = &cursor {
                query.push(("cursor", cursor));
            }
            let page: ApplicationsResponse = self
                .request("api/apps", &query, None, &credential)
                .await
                .map_err(|error| error.to_string())?;
            applications.extend(page.apps.into_iter().map(|app| ConnectorApp {
                slug: app.slug,
                name: app.name,
                logo_url: app.logo_url,
                is_connected: app.is_connected,
            }));
            cursor = if matching_query.trim().is_empty() {
                None
            } else {
                page.next_cursor
            };
            match &cursor {
                None => break,
                Some(cursor) if !visited_cursors.insert(cursor.clone()) => {
                    return Err(AmbientConnectorError::InvalidResponse.to_string())
                }
                _ => {}
            }
        }
        Ok(applications)
    }
    async fn authorization_url(&self, app_slug: &str) -> Result<String, String> {
        let credential = self
            .current_credential()
            .await
            .map_err(|error| error.to_string())?;
        let response: AuthorizationResponse = self
            .request(
                "api/connect",
                &[],
                Some(json!({"appSlug":app_slug})),
                &credential,
            )
            .await
            .map_err(|error| error.to_string())?;
        if !Url::parse(&response.authorization_url)
            .is_ok_and(|url| url.scheme() == "https" && url.host_str().is_some())
        {
            return Err(AmbientConnectorError::InvalidResponse.to_string());
        }
        Ok(response.authorization_url)
    }
    async fn disconnect(&self, app_slug: &str) -> Result<(), String> {
        let credential = self
            .current_credential()
            .await
            .map_err(|error| error.to_string())?;
        let response: DisconnectionResponse = self
            .request(
                "api/disconnect",
                &[],
                Some(json!({"appSlug":app_slug})),
                &credential,
            )
            .await
            .map_err(|error| error.to_string())?;
        if !response.ok {
            return Err(AmbientConnectorError::InvalidResponse.to_string());
        }
        Ok(())
    }
}
type Authorize = Arc<dyn Fn(String) -> Pin<Box<dyn Future<Output = ()> + Send>> + Send + Sync>;
pub struct ComposioToolProvider {
    client: Arc<AmbientConnectorClient>,
    authorize: Authorize,
    cached_session: Mutex<Option<(RouterSession, AiCredential, Instant)>>,
}
impl ComposioToolProvider {
    pub fn new<F, Fut>(client: Arc<AmbientConnectorClient>, authorize: F) -> Self
    where
        F: Fn(String) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = ()> + Send + 'static,
    {
        Self {
            client,
            authorize: Arc::new(move |url| Box::pin(authorize(url))),
            cached_session: Mutex::new(None),
        }
    }
    async fn current_session(
        &self,
    ) -> Result<(RouterSession, AiCredential), AmbientConnectorError> {
        let credential = self.client.current_credential().await?;
        // Hold the cache lock through discovery so concurrent prompt/tool requests share one session.
        let mut cache = self.cached_session.lock().await;
        if let Some((session, cached_credential, expires)) = &*cache {
            if cached_credential == &credential && *expires > Instant::now() {
                return Ok((session.clone(), credential));
            }
        }
        let session: RouterSession = self
            .client
            .request("api/tools", &[], None, &credential)
            .await?;
        *cache = Some((
            session.clone(),
            credential.clone(),
            Instant::now() + Duration::from_secs(300),
        ));
        Ok((session, credential))
    }
}
#[async_trait]
impl ToolProvider for ComposioToolProvider {
    async fn tools(&self) -> Vec<Arc<dyn AmbientTool>> {
        match self.current_session().await {
            Ok((session, credential)) => session
                .tools
                .into_iter()
                .filter(|tool| tool.kind == "function")
                .map(|tool| {
                    Arc::new(ComposioMetaTool {
                        definition: ToolDefinition {
                            name: tool.function.name,
                            description: tool.function.description.unwrap_or_default(),
                            parameters_json_schema: tool.function.parameters,
                        },
                        session_identifier: session.session_id.clone(),
                        credential: credential.clone(),
                        client: self.client.clone(),
                        authorize: self.authorize.clone(),
                    }) as Arc<dyn AmbientTool>
                })
                .collect(),
            Err(error) => vec![Arc::new(UnavailableConnectorTool(error.to_string()))],
        }
    }
    async fn system_prompt_section(&self) -> Option<String> {
        match self.current_session().await {
            Ok((session, _)) => session.system_prompt,
            Err(error) => Some(format!(
                "App connections are currently unavailable: {error}"
            )),
        }
    }
}
struct UnavailableConnectorTool(String);
#[async_trait]
impl AmbientTool for UnavailableConnectorTool {
    fn definition(&self) -> ToolDefinition {
        ToolDefinition {name:"ambient_connections_unavailable".into(), description:"Reports why app connections are unavailable. Tell the person this error before trying connected app work.".into(), parameters_json_schema:json!({"type":"object","properties":{}})}
    }
    async fn run(&self, _: Value) -> ToolResult {
        ToolResult::error(&self.0)
    }
}
struct ComposioMetaTool {
    definition: ToolDefinition,
    session_identifier: String,
    credential: AiCredential,
    client: Arc<AmbientConnectorClient>,
    authorize: Authorize,
}
#[async_trait]
impl AmbientTool for ComposioMetaTool {
    fn definition(&self) -> ToolDefinition {
        self.definition.clone()
    }
    fn activity_label(&self, arguments: &Value) -> Option<String> {
        let subjects = argument_subjects(arguments);
        Some(if subjects.is_empty() {
            self.definition
                .name
                .replace('_', " ")
                .split(' ')
                .map(|word| {
                    let mut chars = word.chars();
                    chars
                        .next()
                        .map(|first| {
                            first.to_uppercase().collect::<String>()
                                + &chars.as_str().to_lowercase()
                        })
                        .unwrap_or_default()
                })
                .collect::<Vec<_>>()
                .join(" ")
        } else {
            subjects
                .into_iter()
                .take(3)
                .collect::<Vec<_>>()
                .join(", ")
                .chars()
                .take(100)
                .collect()
        })
    }
    async fn run(&self, arguments: Value) -> ToolResult {
        let result = async {
            if self.client.current_credential().await? != self.credential { return Err(AmbientConnectorError::Service("Your publik account changed. Retry so Ambient can refresh app connections.".into())); }
            let response: ExecutionResponse = self.client.request("api/execute", &[], Some(json!({"sessionId":self.session_identifier,"name":self.definition.name,"arguments":arguments})), &self.credential).await?;
            let result = response.result;
            let mut links = Vec::new();
            authorization_links(&result, &mut links);
            for link in &links { (self.authorize)(link.clone()).await; }
            let text = serde_json::to_string(&result).map_err(|_| AmbientConnectorError::InvalidResponse)?;
            let mut content = if text.len() > 48_000 {String::from_utf8_lossy(&text.as_bytes()[..48_000]).into_owned() + "\n[Result truncated by Ambient at 48,000 UTF-8 bytes. Use narrower queries or pagination for more.]"} else {text};
            if !links.is_empty() { content.push_str("\nThe authorization link was opened in the person's browser. Ask them to finish connecting, then retry the tool after they finish; do not repeatedly call it while they authorize."); }
            let is_error = result.get("error").is_some_and(|error| !error.is_null()) || result["successful"] == false || result["success"] == false || matches!(result["resultType"].as_str(), Some("blocked" | "failed"));
            Ok(ToolResult {content, is_error, images:vec![]})
        }.await;
        result.unwrap_or_else(|error: AmbientConnectorError| ToolResult::error(error.to_string()))
    }
}
fn argument_subjects(value: &Value) -> Vec<String> {
    match value {
        Value::Array(values) => values.iter().flat_map(argument_subjects).collect(),
        Value::Object(fields) => {
            let subjects: Vec<String> = [
                "tool_slug",
                "toolSlug",
                "tool_slugs",
                "toolSlugs",
                "use_case",
                "useCase",
                "query",
                "search",
                "search_query",
                "toolkits",
            ]
            .iter()
            .filter_map(|key| fields.get(*key))
            .flat_map(|subject| match subject {
                Value::String(text) => vec![text.clone()],
                Value::Array(values) => values
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect(),
                _ => vec![],
            })
            .collect();
            if subjects.is_empty() {
                let mut keys: Vec<_> = fields.keys().collect();
                keys.sort();
                keys.into_iter()
                    .flat_map(|key| argument_subjects(&fields[key]))
                    .collect()
            } else {
                subjects
            }
        }
        _ => vec![],
    }
}
fn authorization_links(value: &Value, links: &mut Vec<String>) {
    match value {
        Value::Object(fields) => {
            let mut keys: Vec<_> = fields.keys().collect();
            keys.sort();
            for key in keys {
                let child = &fields[key];
                let normalized = key.replace('_', "").to_lowercase();
                let link = child
                    .as_str()
                    .filter(|_| {
                        matches!(
                            normalized.as_str(),
                            "redirecturl"
                                | "authorizationurl"
                                | "authurl"
                                | "connecturl"
                                | "connectlink"
                        )
                    })
                    .filter(|text| {
                        Url::parse(text).is_ok_and(|url| {
                            url.scheme() == "https"
                                && url.host_str().is_some_and(|host| {
                                    host == "composio.dev" || host.ends_with(".composio.dev")
                                })
                        })
                    });
                if let Some(link) = link {
                    if !links.iter().any(|existing| existing == link) {
                        links.push(link.into());
                    }
                } else {
                    authorization_links(child, links);
                }
            }
        }
        Value::Array(children) => {
            for child in children {
                authorization_links(child, links);
            }
        }
        _ => {}
    }
}
#[cfg(test)]
mod tests;
