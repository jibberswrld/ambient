use super::*;
use std::{
    io::{Read, Write},
    net::TcpListener,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Mutex as StdMutex,
    },
};
struct Credentials(StdMutex<Option<String>>);
#[async_trait]
impl AiCredentialSource for Credentials {
    async fn credential(&self) -> Option<AiCredential> {
        self.0.lock().unwrap().clone().map(|api_key| AiCredential {
            base_url: "https://unused.example".into(),
            api_key,
        })
    }
}
fn credentials() -> Arc<Credentials> {
    Arc::new(Credentials(StdMutex::new(Some("pk_fixture".into()))))
}
struct Request {
    target: String,
    body: Value,
    raw: String,
}
fn server(
    handler: impl Fn(Request) -> (u16, Value) + Send + 'static,
) -> (String, Arc<AtomicUsize>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    listener.set_nonblocking(true).unwrap();
    let count = Arc::new(AtomicUsize::new(0));
    let observed = Arc::downgrade(&count);
    std::thread::spawn(move || {
        while let Some(observed) = observed.upgrade() {
            let (mut stream, _) = match listener.accept() {
                Ok(connection) => connection,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    drop(observed);
                    std::thread::sleep(Duration::from_millis(2));
                    continue;
                }
                Err(error) => panic!("{error}"),
            };
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            stream.set_nonblocking(false).unwrap();
            let mut bytes = Vec::new();
            let header_end = loop {
                let mut buffer = [0; 1024];
                let length = stream.read(&mut buffer).unwrap();
                assert!(length > 0);
                bytes.extend_from_slice(&buffer[..length]);
                if let Some(position) = bytes.windows(4).position(|window| window == b"\r\n\r\n") {
                    break position + 4;
                }
            };
            let raw = String::from_utf8(bytes[..header_end].to_vec()).unwrap();
            let body_length = raw
                .lines()
                .find_map(|line| {
                    line.to_lowercase()
                        .strip_prefix("content-length:")
                        .map(|length| length.trim().parse::<usize>().unwrap())
                })
                .unwrap_or(0);
            while bytes.len() < header_end + body_length {
                let mut buffer = [0; 4096];
                let length = stream.read(&mut buffer).unwrap();
                assert!(length > 0);
                bytes.extend_from_slice(&buffer[..length]);
            }
            let target = raw.split_whitespace().nth(1).unwrap().to_owned();
            let body = serde_json::from_slice(&bytes[header_end..]).unwrap_or(Value::Null);
            observed.fetch_add(1, Ordering::SeqCst);
            let (status, value) = handler(Request { target, body, raw });
            let body = value.to_string();
            write!(stream,"HTTP/1.1 {status} Response\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()).unwrap();
        }
    });
    (origin, count)
}
fn payload() -> Value {
    json!({"sessionId":"session_fixture","systemPrompt":"Use Composio's search first.","tools":[{"type":"function","function":{"name":"COMPOSIO_SEARCH_TOOLS","description":"Search any connected app","parameters":{"type":"object","properties":{"queries":{"type":"array"}}}}}]})
}
fn provider(origin: String, credentials: Arc<Credentials>) -> ComposioToolProvider {
    ComposioToolProvider::new(
        Arc::new(AmbientConnectorClient::with_origin(origin, credentials)),
        |_| async {},
    )
}
#[tokio::test]
async fn lists_all_search_pages_and_preserves_fields() {
    let (origin, count) = server(|request| {
        assert!(request
            .raw
            .to_lowercase()
            .contains("authorization: bearer pk_fixture"));
        let url = Url::parse(&format!("http://localhost{}", request.target)).unwrap();
        assert_eq!(url.path(), "/api/apps");
        assert_eq!(
            url.query_pairs().find(|(key, _)| key == "query").unwrap().1,
            "unlisted & app"
        );
        if url
            .query_pairs()
            .any(|(key, value)| key == "cursor" && value == "next")
        {
            (
                200,
                json!({"apps":[{"slug":"other","name":"Other","isConnected":false}],"nextCursor":null}),
            )
        } else {
            (
                200,
                json!({"apps":[{"slug":"unlisted_app","name":"Unlisted App","logoURL":"https://example.com/logo.png","isConnected":true}],"nextCursor":"next"}),
            )
        }
    });
    let apps = AmbientConnectorClient::with_origin(origin, credentials())
        .apps("unlisted & app")
        .await
        .unwrap();
    assert_eq!(count.load(Ordering::SeqCst), 2);
    assert_eq!(apps.len(), 2);
    assert!(apps[0].is_connected);
    assert!(apps[0].logo_url.is_some());
    assert_eq!(apps[1].slug, "other");
    assert!(apps[1].logo_url.is_none());
}
#[tokio::test]
async fn popular_page_and_repeated_cursor() {
    let (origin, count) = server(|_| (200, json!({"apps":[],"nextCursor":"more"})));
    let client = AmbientConnectorClient::with_origin(origin, credentials());
    assert!(client.apps(" \n").await.unwrap().is_empty());
    assert_eq!(count.load(Ordering::SeqCst), 1);
    assert_eq!(
        client.apps("search").await.unwrap_err(),
        AmbientConnectorError::InvalidResponse.to_string()
    );
    assert_eq!(count.load(Ordering::SeqCst), 3);
}
#[tokio::test]
async fn connect_and_disconnect_post_slug_and_validate_response() {
    let (origin, _count) = server(|request| {
        assert!(request.raw.starts_with("POST "));
        assert_eq!(request.body, json!({"appSlug":"unlisted_app"}));
        (
            200,
            if request.target == "/api/connect" {
                json!({"authorizationURL":"https://connect.composio.dev/link/fixture"})
            } else {
                json!({"ok":true})
            },
        )
    });
    let client = AmbientConnectorClient::with_origin(origin, credentials());
    assert_eq!(
        client.authorization_url("unlisted_app").await.unwrap(),
        "https://connect.composio.dev/link/fixture"
    );
    client.disconnect("unlisted_app").await.unwrap();
    let (origin, _count) = server(|_| {
        (
            200,
            json!({"authorizationURL":"http://example.com","ok":false}),
        )
    });
    let client = AmbientConnectorClient::with_origin(origin, credentials());
    assert!(client.authorization_url("app").await.is_err());
    assert!(client.disconnect("app").await.is_err());
}
#[tokio::test]
async fn caches_coalesces_and_executes_with_session_and_arguments() {
    let fetches = Arc::new(AtomicUsize::new(0));
    let observed = fetches.clone();
    let (origin, _count) = server(move |request| {
        if request.target == "/api/tools" {
            observed.fetch_add(1, Ordering::SeqCst);
            return (200, payload());
        }
        assert_eq!(request.target, "/api/execute");
        assert_eq!(request.body["sessionId"], "session_fixture");
        assert_eq!(request.body["name"], "COMPOSIO_SEARCH_TOOLS");
        assert!(request.body["arguments"]["queries"].is_array());
        (
            200,
            json!({"result":{"resultType":"completed","data":{"tools":["DISCOVERED_TOOL"]},"error":null}}),
        )
    });
    let provider = provider(origin, credentials());
    let (tools, prompt) = tokio::join!(provider.tools(), provider.system_prompt_section());
    assert_eq!(prompt.as_deref(), Some("Use Composio's search first."));
    assert_eq!(tools.len(), 1);
    assert_eq!(
        tools[0].definition().parameters_json_schema["type"],
        "object"
    );
    provider.tools().await;
    assert_eq!(fetches.load(Ordering::SeqCst), 1);
    let arguments = json!({"queries":[{"use_case":"send an email"}]});
    assert_eq!(
        tools[0].activity_label(&arguments).as_deref(),
        Some("send an email")
    );
    let result = tools[0].run(arguments).await;
    assert!(!result.is_error);
    assert!(result.content.contains("DISCOVERED_TOOL"));
    assert_eq!(
        tools[0]
            .activity_label(&json!({"tools":[{"tool_slug":"SOME_APP_DO_WORK","arguments":{}}]}))
            .unwrap(),
        "SOME_APP_DO_WORK"
    );
    assert_eq!(
        tools[0]
            .activity_label(&json!({"query":"long ".repeat(100)}))
            .unwrap()
            .len(),
        100
    );
}
#[tokio::test]
async fn authorization_is_nested_deduplicated_trusted_and_before_truncation() {
    let (origin, _count) = server(|request| {
        if request.target == "/api/tools" {
            (200, payload())
        } else {
            (
                200,
                json!({"result":{"data":{"connections":[{"redirect_url":"https://connect.composio.dev/link/fixture"},{"redirectUrl":"https://connect.composio.dev/link/fixture"}],"auth_url":"https://untrusted.example/no","connect_url":"https://composio.dev.evil.example/no","url":"https://example.com/article","large":"🐈".repeat(30_000)}}}),
            )
        }
    });
    let recorded = Arc::new(StdMutex::new(vec![]));
    let recorder = recorded.clone();
    let provider = ComposioToolProvider::new(
        Arc::new(AmbientConnectorClient::with_origin(origin, credentials())),
        move |url| {
            let recorder = recorder.clone();
            async move {
                recorder.lock().unwrap().push(url);
            }
        },
    );
    let result = provider.tools().await[0].run(json!({})).await;
    assert_eq!(
        *recorded.lock().unwrap(),
        vec!["https://connect.composio.dev/link/fixture"]
    );
    assert!(result.content.contains("authorization link was opened"));
    assert!(result.content.contains("retry the tool after they finish"));
    assert!(result.content.contains("Result truncated"));
    assert!(result.content.len() < 49_000);
}
#[tokio::test]
async fn all_app_error_indicators_are_preserved() {
    for result in [
        json!({"resultType":"failed","error":null}),
        json!({"resultType":"blocked"}),
        json!({"error":"problem"}),
        json!({"successful":false}),
        json!({"success":false}),
    ] {
        let (origin, _count) = server(move |request| {
            if request.target == "/api/tools" {
                (200, payload())
            } else {
                (200, json!({"result":result}))
            }
        });
        assert!(
            provider(origin, credentials()).tools().await[0]
                .run(json!({}))
                .await
                .is_error
        );
    }
}
#[tokio::test]
async fn account_changes_refresh_and_invalidate_retained_tools() {
    let (origin, count) = server(|request| {
        assert_eq!(request.target, "/api/tools");
        (200, payload())
    });
    let credentials = credentials();
    let provider = provider(origin, credentials.clone());
    let previous = provider.tools().await;
    *credentials.0.lock().unwrap() = Some("pk_other".into());
    let result = previous[0].run(json!({})).await;
    assert!(result.is_error);
    assert!(result.content.contains("account changed"));
    provider.tools().await;
    assert_eq!(count.load(Ordering::SeqCst), 2);
}
#[tokio::test]
async fn missing_invalid_credentials_and_insecure_origin_never_contact_server() {
    let (origin, count) = server(|_| panic!("must not contact server"));
    for key in [None, Some("wrong".into()), Some("pk_bad key".into())] {
        let source = Arc::new(Credentials(StdMutex::new(key)));
        let tools = provider(origin.clone(), source).tools().await;
        let result = tools[0].run(json!({})).await;
        assert!(result.is_error);
        assert!(result.content.contains("Sign in with publik"));
    }
    assert_eq!(count.load(Ordering::SeqCst), 0);
    assert!(
        AmbientConnectorClient::with_origin("http://remote.example", credentials())
            .apps("")
            .await
            .unwrap_err()
            .contains("HTTPS")
    );
}
#[tokio::test]
async fn service_and_transport_errors_are_readable() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    drop(listener);
    let unavailable = provider(origin, credentials()).tools().await[0]
        .run(json!({}))
        .await;
    assert!(unavailable.is_error);
    assert!(unavailable.content.contains("unreachable"));
    for (status, body, message) in [
        (
            503,
            json!({"error":{"message":"App connections are not configured yet."}}),
            "not configured",
        ),
        (401, json!({}), "Sign in with publik"),
        (200, json!({}), "unreadable response"),
        (502, json!({}), "could not complete"),
    ] {
        let (origin, _count) = server(move |_| (status, body.clone()));
        let provider = provider(origin, credentials());
        assert!(provider
            .system_prompt_section()
            .await
            .unwrap()
            .contains(message));
        let result = provider.tools().await[0].run(json!({})).await;
        assert!(result.is_error);
        assert!(result.content.contains(message));
    }
}
#[tokio::test]
async fn execution_http_error_becomes_readable_result() {
    let (origin, _count) = server(|request| {
        if request.target == "/api/tools" {
            (200, payload())
        } else {
            (
                502,
                json!({"error":{"message":"The connected app did not answer. Please try again."}}),
            )
        }
    });
    let result = provider(origin, credentials()).tools().await[0]
        .run(json!({}))
        .await;
    assert!(result.is_error);
    assert_eq!(
        result.content,
        "The connected app did not answer. Please try again."
    );
}
