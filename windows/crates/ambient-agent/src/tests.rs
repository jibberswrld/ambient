use crate::*;
use ambient_contracts::*;
use async_trait::async_trait;
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Arc, Mutex,
    },
    thread,
    time::{Duration, Instant},
};
use tokio::sync::{mpsc, Notify};

#[derive(Clone)]
struct FixedCredentialSource(Option<AiCredential>);
#[async_trait]
impl AiCredentialSource for FixedCredentialSource {
    async fn credential(&self) -> Option<AiCredential> {
        self.0.clone()
    }
}
struct Request {
    path: String,
    headers: HashMap<String, String>,
    body: Vec<u8>,
}
impl Request {
    fn json(&self) -> Value {
        serde_json::from_slice(&self.body).unwrap()
    }
}
struct Response {
    status: u16,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
    hangs: bool,
}
impl Response {
    fn new(status: u16, body: impl Into<Vec<u8>>) -> Self {
        Self {
            status,
            headers: vec![],
            body: body.into(),
            hangs: false,
        }
    }
    fn stream(text: String) -> Self {
        Self::new(200, format!("{text}data: [DONE]\r\n\r\n").into_bytes())
    }
    fn json(value: Value) -> Self {
        Self::new(200, value.to_string().into_bytes())
    }
    fn rate_limit(delay: &str) -> Self {
        Self {
            status: 429,
            headers: vec![("Retry-After".into(), delay.into())],
            body: b"{}".to_vec(),
            hangs: false,
        }
    }
}
struct Server {
    base_url: String,
    stop: Arc<AtomicBool>,
    listener: Option<thread::JoinHandle<()>>,
    workers: Arc<Mutex<Vec<thread::JoinHandle<()>>>>,
}
impl Server {
    fn new(handler: impl Fn(Request) -> Response + Send + Sync + 'static) -> Self {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let base_url = format!("http://{}/api/v1", listener.local_addr().unwrap());
        listener.set_nonblocking(true).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = stop.clone();
        let workers = Arc::new(Mutex::new(Vec::new()));
        let thread_workers = workers.clone();
        let handler = Arc::new(handler);
        let listener = thread::spawn(move || {
            while !thread_stop.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((socket, _)) => {
                        let handler = handler.clone();
                        thread_workers
                            .lock()
                            .unwrap()
                            .push(thread::spawn(move || serve(socket, handler.as_ref())));
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(1))
                    }
                    Err(error) => panic!("{error}"),
                }
            }
        });
        Self {
            base_url,
            stop,
            listener: Some(listener),
            workers,
        }
    }
    fn source(&self) -> Arc<dyn AiCredentialSource> {
        Arc::new(FixedCredentialSource(Some(AiCredential {
            base_url: self.base_url.clone(),
            api_key: ["local", "test", "key"].join("-"),
        })))
    }
    fn agent(&self, providers: Vec<Arc<dyn ToolProvider>>) -> AmbientAgentSession {
        AmbientAgentSession::new(self.source(), providers, None, "low")
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        self.listener.take().unwrap().join().unwrap();
        for worker in self.workers.lock().unwrap().drain(..) {
            let result = worker.join();
            if !std::thread::panicking() {
                result.unwrap();
            }
        }
    }
}
fn serve(mut socket: TcpStream, handler: &dyn Fn(Request) -> Response) {
    socket.set_nonblocking(false).unwrap();
    socket
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    let mut bytes = Vec::new();
    let mut buffer = [0; 8192];
    let header_end = loop {
        let count = socket.read(&mut buffer).unwrap_or_else(|error| {
            panic!("request read failed after {} bytes: {error}", bytes.len())
        });
        // A turn cancelled at once closes its connection before sending anything; that is not a failure.
        if count == 0 && bytes.is_empty() {
            return;
        }
        assert_ne!(count, 0);
        bytes.extend_from_slice(&buffer[..count]);
        if let Some(position) = bytes.windows(4).position(|bytes| bytes == b"\r\n\r\n") {
            break position + 4;
        }
    };
    let header = String::from_utf8(bytes[..header_end].to_vec()).unwrap();
    let mut lines = header.lines();
    let path = lines
        .next()
        .unwrap()
        .split_whitespace()
        .nth(1)
        .unwrap()
        .into();
    let headers: HashMap<_, _> = lines
        .filter_map(|line| {
            line.split_once(':')
                .map(|(name, value)| (name.to_lowercase(), value.trim().to_string()))
        })
        .collect();
    let length: usize = headers
        .get("content-length")
        .map(|value| value.parse().unwrap())
        .unwrap_or(0);
    while bytes.len() - header_end < length {
        let count = socket.read(&mut buffer).unwrap_or_else(|error| {
            panic!("request read failed after {} bytes: {error}", bytes.len())
        });
        assert_ne!(count, 0);
        bytes.extend_from_slice(&buffer[..count]);
    }
    let response = handler(Request {
        path,
        headers,
        body: bytes[header_end..header_end + length].to_vec(),
    });
    let headers = response
        .headers
        .iter()
        .map(|(name, value)| format!("{name}: {value}\r\n"))
        .collect::<String>();
    let length = if response.hangs {
        "Transfer-Encoding: chunked\r\n".into()
    } else {
        format!("Content-Length: {}\r\n", response.body.len())
    };
    if write!(
        socket,
        "HTTP/1.1 {} Test\r\n{headers}{length}Connection: close\r\n\r\n",
        response.status
    )
    .is_err()
    {
        return;
    }
    // Seven-byte writes split UTF-8, JSON and CRLF just like the Swift stub.
    for chunk in response.body.chunks(7) {
        if response.hangs && write!(socket, "{:x}\r\n", chunk.len()).is_err() {
            return;
        }
        if socket.write_all(chunk).is_err() {
            return;
        }
        if response.hangs && socket.write_all(b"\r\n").is_err() {
            return;
        }
    }
    let _ = socket.flush();
    if response.hangs {
        let _ = socket.read(&mut buffer);
    }
}
fn event(delta: Value, finish: Option<&str>) -> String {
    let mut choice = json!({"index":0, "delta":delta});
    if let Some(finish) = finish {
        choice["finish_reason"] = json!(finish);
    }
    format!("data: {}\r\n\r\n", json!({"choices":[choice]}))
}
fn tool_event(names: &[&str], arguments: &[&str]) -> String {
    event(
        json!({"tool_calls":names.iter().enumerate().map(|(index,name)| json!({"index":index,"id":format!("call_{index}"),"function":{"name":name,"arguments":arguments.get(index).unwrap_or(&"{}")}})).collect::<Vec<_>>()}),
        Some("tool_calls"),
    )
}
async fn collect(mut receiver: mpsc::UnboundedReceiver<AgentEvent>) -> Vec<AgentEvent> {
    let mut events = vec![];
    while let Some(event) = tokio::time::timeout(Duration::from_secs(10), receiver.recv())
        .await
        .expect("event stream timed out")
    {
        assert!(
            !matches!(
                events.last(),
                Some(AgentEvent::Finished { .. } | AgentEvent::Failed(_))
            ),
            "event arrived after the terminal event"
        );
        events.push(event);
    }
    events
}
fn final_text(events: &[AgentEvent]) -> Option<&str> {
    events.iter().find_map(|event| {
        if let AgentEvent::Finished { final_text } = event {
            Some(final_text.as_str())
        } else {
            None
        }
    })
}
fn agent_failure(events: &[AgentEvent]) -> Option<&AgentFailure> {
    events.iter().find_map(|event| {
        if let AgentEvent::Failed(error) = event {
            Some(error)
        } else {
            None
        }
    })
}
struct TestTool {
    name: String,
    running: Arc<AtomicUsize>,
    maximum: Arc<AtomicUsize>,
    images: bool,
    started: Option<Arc<Notify>>,
    dropped: Option<Arc<AtomicBool>>,
}
impl Default for TestTool {
    fn default() -> Self {
        Self {
            name: "echo_tool".into(),
            running: Arc::new(AtomicUsize::new(0)),
            maximum: Arc::new(AtomicUsize::new(0)),
            images: false,
            started: None,
            dropped: None,
        }
    }
}
struct Dropped(Arc<AtomicBool>);
impl Drop for Dropped {
    fn drop(&mut self) {
        self.0.store(true, Ordering::SeqCst);
    }
}
#[async_trait]
impl AmbientTool for TestTool {
    fn definition(&self) -> ToolDefinition {
        ToolDefinition {
            name: self.name.clone(),
            description: "Return the supplied value.".into(),
            parameters_json_schema: json!({"type":"object", "properties":{"value":{"type":"string"}}}),
        }
    }
    fn activity_label(&self, _: &Value) -> Option<String> {
        (self.name == "echo_tool").then(|| "Echoing value".into())
    }
    async fn run(&self, arguments: Value) -> ToolResult {
        if let Some(started) = &self.started {
            started.notify_one();
        }
        let _dropped = self
            .dropped
            .as_ref()
            .map(|dropped| Dropped(dropped.clone()));
        if self.dropped.is_some() {
            std::future::pending::<()>().await;
        }
        let running = self.running.fetch_add(1, Ordering::SeqCst) + 1;
        self.maximum.fetch_max(running, Ordering::SeqCst);
        tokio::time::sleep(Duration::from_millis(20)).await;
        self.running.fetch_sub(1, Ordering::SeqCst);
        ToolResult {
            content: arguments["value"].as_str().unwrap_or("ok").into(),
            is_error: false,
            images: if self.images {
                vec![ImageAttachment {
                    data: vec![1, 2, 3],
                    mime_type: "image/png".into(),
                    label: "Screen".into(),
                }]
            } else {
                vec![]
            },
        }
    }
}
struct TestProvider {
    tools: Vec<Arc<dyn AmbientTool>>,
    calls: AtomicUsize,
}
impl TestProvider {
    fn new(tools: Vec<Arc<dyn AmbientTool>>) -> Self {
        Self {
            tools,
            calls: AtomicUsize::new(0),
        }
    }
}
#[async_trait]
impl ToolProvider for TestProvider {
    async fn tools(&self) -> Vec<Arc<dyn AmbientTool>> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.tools.clone()
    }
    async fn system_prompt_section(&self) -> Option<String> {
        Some("Provider instructions.".into())
    }
}
fn echo_provider() -> Arc<TestProvider> {
    Arc::new(TestProvider::new(vec![Arc::new(TestTool::default())]))
}

#[tokio::test]
async fn fragmented_arguments_and_multiple_rounds() {
    let count = Arc::new(AtomicUsize::new(0));
    let requests = count.clone();
    let server = Server::new(move |request| {
        let body = request.json();
        assert_eq!(body["model"], "publik-smart");
        assert_eq!(body["reasoning_effort"], "low");
        assert!(body["messages"][0]["content"]
            .as_str()
            .unwrap()
            .contains("Provider instructions."));
        assert_eq!(request.headers["accept"], "text/event-stream");
        if requests.fetch_add(1, Ordering::SeqCst) == 0 {
            Response::stream(
                ": keepalive\r\n\r\n".to_string()
                    + &event(
                        json!({"content":"Checking… ","tool_calls":[{"index":0,"id":"call_0","function":{"name":"echo_tool","arguments":"{\"val"}}]}),
                        None,
                    )
                    + &event(
                        json!({"tool_calls":[{"index":0,"function":{"arguments":"ue\":\"hello\"}"}}]}),
                        Some("tool_calls"),
                    ),
            )
        } else {
            let last = body["messages"].as_array().unwrap().last().unwrap();
            assert_eq!(last["role"], "tool");
            assert_eq!(last["content"], "hello");
            Response::stream(event(json!({"content":"Done."}), Some("stop")))
        }
    });
    let events = collect(
        server
            .agent(vec![echo_provider()])
            .send(UserTurn::text("Use the tool")),
    )
    .await;
    assert_eq!(final_text(&events), Some("Checking… \n\nDone."));
    assert_eq!(count.load(Ordering::SeqCst), 2);
    assert!(events.iter().any(|event| matches!(event,AgentEvent::ToolStarted { activity_label,.. } if activity_label == "Echoing value")));
}
#[tokio::test]
async fn parallel_tools_and_images_follow_all_tool_messages() {
    let tool = Arc::new(TestTool {
        images: true,
        ..Default::default()
    });
    let observed = tool.clone();
    let count = AtomicUsize::new(0);
    let server = Server::new(move |request| {
        if count.fetch_add(1, Ordering::SeqCst) == 0 {
            return Response::stream(tool_event(&["echo_tool", "echo_tool"], &[]));
        }
        let body = request.json();
        let messages = body["messages"].as_array().unwrap();
        assert_eq!(
            messages[messages.len() - 3..]
                .iter()
                .map(|message| message["role"].as_str().unwrap())
                .collect::<Vec<_>>(),
            vec!["tool", "tool", "user"]
        );
        let parts = messages.last().unwrap()["content"].as_array().unwrap();
        let images: Vec<_> = parts
            .iter()
            .filter(|part| part["type"] == "image_url")
            .collect();
        assert_eq!(images.len(), 2);
        assert_eq!(images[0]["image_url"]["url"], "data:image/png;base64,AQID");
        assert!(parts.iter().any(|part| part["text"]
            .as_str()
            .is_some_and(|text| text.contains("echo_tool (call_0): Screen"))));
        Response::stream(event(json!({"content":"I see it."}), Some("stop")))
    });
    let events = collect(
        server
            .agent(vec![Arc::new(TestProvider::new(vec![tool]))])
            .send(UserTurn::text("Look twice")),
    )
    .await;
    assert_eq!(final_text(&events), Some("I see it."));
    assert_eq!(observed.maximum.load(Ordering::SeqCst), 2);
}
#[tokio::test]
async fn unknown_tools_and_invalid_arguments_are_readable() {
    let count = AtomicUsize::new(0);
    let server = Server::new(move |request| {
        if count.fetch_add(1, Ordering::SeqCst) == 0 {
            return Response::stream(tool_event(&["missing_tool", "echo_tool"], &["{}", "{bad"]));
        }
        let body = request.json();
        let messages = body["messages"].as_array().unwrap();
        assert!(messages[messages.len() - 2]["content"]
            .as_str()
            .unwrap()
            .contains("Unknown tool"));
        assert!(messages.last().unwrap()["content"]
            .as_str()
            .unwrap()
            .contains("Invalid arguments"));
        Response::stream(event(
            json!({"content":"Those calls failed."}),
            Some("stop"),
        ))
    });
    let events = collect(
        server
            .agent(vec![echo_provider()])
            .send(UserTurn::text("Try")),
    )
    .await;
    assert_eq!(final_text(&events), Some("Those calls failed."));
    assert_eq!(
        events
            .iter()
            .filter(|event| matches!(event, AgentEvent::ToolFinished { is_error: true, .. }))
            .count(),
        2
    );
}
#[tokio::test]
async fn payment_and_not_signed_in_mapping() {
    for status in [402, 401] {
        let server = Server::new(move |_| {
            Response::new(status,br#"{"error":{"message":"Top up first","top_up_url":"https://publikhq.com/wallet"}}"#.to_vec())
        });
        let events = collect(server.agent(vec![]).send(UserTurn::text("Hello"))).await;
        let expected = if status == 401 {
            AgentFailure::NotSignedIn
        } else {
            AgentFailure::PaymentRequired {
                message: "Top up first".into(),
                top_up_url: Some("https://publikhq.com/wallet".into()),
            }
        };
        assert_eq!(agent_failure(&events), Some(&expected));
    }
}
#[tokio::test]
async fn missing_credential_makes_no_request() {
    let agent = AmbientAgentSession::new(Arc::new(FixedCredentialSource(None)), vec![], None, "");
    assert_eq!(
        agent_failure(&collect(agent.send(UserTurn::text("Hello"))).await),
        Some(&AgentFailure::NotSignedIn)
    );
}
#[tokio::test]
async fn retry_after_bounded_and_honoured() {
    for (header, expected) in [("0", 3), ("3600", 1), ("NaN", 1), ("invalid", 1)] {
        let count = Arc::new(AtomicUsize::new(0));
        let requests = count.clone();
        let server = Server::new(move |_| {
            requests.fetch_add(1, Ordering::SeqCst);
            Response::rate_limit(header)
        });
        assert!(
            agent_failure(&collect(server.agent(vec![]).send(UserTurn::text("Hello"))).await)
                .is_some()
        );
        assert_eq!(count.load(Ordering::SeqCst), expected);
    }
}
#[tokio::test]
async fn retry_after_delay_before_successful_retry() {
    let first_time = Mutex::new(None);
    let count = Arc::new(AtomicUsize::new(0));
    let requests = count.clone();
    let server = Server::new(move |_| {
        if requests.fetch_add(1, Ordering::SeqCst) == 0 {
            *first_time.lock().unwrap() = Some(Instant::now());
            return Response::rate_limit("0.03");
        }
        assert!(first_time.lock().unwrap().unwrap().elapsed() >= Duration::from_millis(25));
        Response::stream(event(json!({"content":"Retried"}), Some("stop")))
    });
    assert_eq!(
        final_text(&collect(server.agent(vec![]).send(UserTurn::text("Retry"))).await),
        Some("Retried")
    );
    assert_eq!(count.load(Ordering::SeqCst), 2);
}
#[tokio::test]
async fn cancellation_stops_request_and_terminates_stream() {
    let started = Arc::new(Notify::new());
    let signal = started.clone();
    let server = Server::new(move |_| {
        signal.notify_one();
        Response {
            hangs: true,
            ..Response::new(200, vec![])
        }
    });
    let agent = server.agent(vec![]);
    let receiver = agent.send(UserTurn::text("Wait"));
    tokio::time::timeout(Duration::from_secs(2), started.notified())
        .await
        .unwrap();
    agent.cancel().await;
    assert_eq!(
        agent_failure(&collect(receiver).await),
        Some(&AgentFailure::Cancelled)
    );
}
#[tokio::test]
async fn cancellation_drops_running_tools() {
    let started = Arc::new(Notify::new());
    let dropped = Arc::new(AtomicBool::new(false));
    let tool = TestTool {
        started: Some(started.clone()),
        dropped: Some(dropped.clone()),
        ..Default::default()
    };
    let server = Server::new(|_| Response::stream(tool_event(&["echo_tool"], &[])));
    let agent = server.agent(vec![Arc::new(TestProvider::new(vec![Arc::new(tool)]))]);
    let receiver = agent.send(UserTurn::text("Wait"));
    tokio::time::timeout(Duration::from_secs(2), started.notified())
        .await
        .unwrap();
    agent.cancel().await;
    assert_eq!(
        agent_failure(&collect(receiver).await),
        Some(&AgentFailure::Cancelled)
    );
    tokio::task::yield_now().await;
    assert!(dropped.load(Ordering::SeqCst));
}
#[tokio::test]
async fn old_images_removed_providers_refreshed_and_reset_clears_history() {
    let bodies = Arc::new(Mutex::new(vec![]));
    let requests = bodies.clone();
    let server = Server::new(move |request| {
        requests.lock().unwrap().push(request.json());
        Response::stream(event(json!({"content":"Done"}), Some("stop")))
    });
    let provider = Arc::new(TestProvider::new(vec![]));
    let agent = server.agent(vec![provider.clone()]);
    collect(agent.send(UserTurn {
        text: "First".into(),
        images: vec![ImageAttachment {
            data: vec![1],
            mime_type: "image/jpeg".into(),
            label: "Screenshot".into(),
        }],
    }))
    .await;
    collect(agent.send(UserTurn::text("Second"))).await;
    {
        let bodies = bodies.lock().unwrap();
        assert!(bodies[0]["messages"][1]["content"].is_array());
        assert!(bodies[1]["messages"][1]["content"].is_string());
    }
    assert_eq!(provider.calls.load(Ordering::SeqCst), 2);
    agent.reset().await;
    collect(agent.send(UserTurn::text("Third"))).await;
    assert_eq!(
        bodies.lock().unwrap()[2]["messages"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
}
#[tokio::test]
async fn history_trims_oldest_whole_turns() {
    let bodies = Arc::new(Mutex::new(vec![]));
    let requests = bodies.clone();
    let server = Server::new(move |request| {
        assert!(request.body.len() < 4_000_000);
        requests.lock().unwrap().push(request.json());
        Response::stream(event(json!({"content":"Done"}), Some("stop")))
    });
    let agent = server.agent(vec![]);
    for (prefix, character) in [("Oldest ", 'a'), ("Middle ", 'b'), ("Newest ", 'c')] {
        let events = collect(agent.send(UserTurn::text(format!(
            "{prefix}{}",
            character.to_string().repeat(1_500_000)
        ))))
        .await;
        assert!(final_text(&events).is_some());
    }
    let bodies = bodies.lock().unwrap();
    let messages = bodies.last().unwrap()["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 4);
    assert!(messages[1]["content"]
        .as_str()
        .unwrap()
        .starts_with("Middle"));
    assert!(messages.last().unwrap()["content"]
        .as_str()
        .unwrap()
        .starts_with("Newest"));
}
#[tokio::test]
async fn oversized_newest_turn_rejected_without_network() {
    let server = Server::new(|_| panic!("oversized request reached network"));
    let events = collect(server.agent(vec![]).send(UserTurn {
        text: "Large image".into(),
        images: vec![ImageAttachment {
            data: vec![1; 3_000_000],
            mime_type: "image/jpeg".into(),
            label: "Large".into(),
        }],
    }))
    .await;
    assert!(agent_failure(&events).is_some());
}
#[tokio::test]
async fn round_limit_and_failed_turns_do_not_poison_history() {
    let count = Arc::new(AtomicUsize::new(0));
    let requests = count.clone();
    let server = Server::new(move |request| {
        if requests.fetch_add(1, Ordering::SeqCst) < 32 {
            Response::stream(tool_event(&["echo_tool"], &[]))
        } else {
            assert_eq!(request.json()["messages"].as_array().unwrap().len(), 2);
            Response::stream(event(json!({"content":"Recovered"}), Some("stop")))
        }
    });
    let agent = server.agent(vec![echo_provider()]);
    let events = collect(agent.send(UserTurn::text("Loop"))).await;
    assert_eq!(count.load(Ordering::SeqCst), 32);
    assert!(agent_failure(&events).is_some());
    assert_eq!(
        final_text(&collect(agent.send(UserTurn::text("Hello"))).await),
        Some("Recovered")
    );
}
#[tokio::test]
async fn truncated_stream_fails_instead_of_claiming_success() {
    let server =
        Server::new(|_| Response::new(200, event(json!({"content":"Partial"}), None).into_bytes()));
    let events = collect(server.agent(vec![]).send(UserTurn::text("Hello"))).await;
    assert!(final_text(&events).is_none());
    assert!(agent_failure(&events).is_some());
}
#[tokio::test]
async fn non_streaming_completion_and_http_mapping() {
    let count = AtomicUsize::new(0);
    let server = Server::new(move |request| {
        let body = request.json();
        assert_eq!(body["stream"], false);
        assert!(body.get("tools").is_none());
        assert_eq!(body["model"], "publik-balanced");
        if count.fetch_add(1, Ordering::SeqCst) == 0 {
            Response::json(json!({"choices":[{"message":{"content":"A title"}}]}))
        } else {
            Response::new(401, b"{}".to_vec())
        }
    });
    let client = PublikAiClient::new(server.source());
    assert_eq!(
        client
            .complete("Title", "A chat", ModelTier::Balanced)
            .await
            .unwrap(),
        "A title"
    );
    assert_eq!(
        client
            .complete("", "", ModelTier::Balanced)
            .await
            .unwrap_err(),
        AgentFailure::NotSignedIn
    );
}
#[tokio::test]
async fn search_tool_and_speech_payloads() {
    let routes = Arc::new(Mutex::new(vec![]));
    let requests = routes.clone();
    let wav = b"RIFFxxxxWAVEaudio".to_vec();
    let audio = wav.clone();
    let server = Server::new(move |request| {
        requests.lock().unwrap().push(request.path.clone());
        if request.path.ends_with("/search") {
            assert_eq!(request.json()["q"], "Swift");
            return Response::json(
                json!({"results":[{"url":"https://swift.org","title":"Swift","snippet":"Language","site":"swift.org"}]}),
            );
        }
        if request.path.ends_with("/speech") {
            let body = request.json();
            assert_eq!(body["model"], "tts-1");
            assert_eq!(body["voice"], "coral");
            assert_eq!(body["response_format"], "wav");
            return Response::new(200, audio.clone());
        }
        assert!(request.headers["content-type"].starts_with("multipart/form-data; boundary="));
        assert!(request
            .body
            .windows(audio.len())
            .any(|chunk| chunk == audio));
        assert!(String::from_utf8_lossy(&request.body).contains("gpt-4o-mini-transcribe"));
        Response::json(json!({"text":"Ambient ready"}))
    });
    let provider = PublikWebSearchProvider::new(server.source());
    let tools = provider.tools().await;
    let result = tools[0].run(json!({"q":"Swift"})).await;
    assert!(!result.is_error, "{}", result.content);
    assert!(result.content.contains("swift.org"));
    let speech = PublikSpeechClient::new(server.source());
    let synthesized = speech
        .synthesize("Ambient ready", DEFAULT_VOICE)
        .await
        .unwrap();
    assert_eq!(synthesized, wav);
    assert_eq!(
        speech.transcribe(synthesized).await.unwrap(),
        "Ambient ready"
    );
    assert_eq!(
        *routes.lock().unwrap(),
        vec![
            "/api/v1/search",
            "/api/v1/audio/speech",
            "/api/v1/audio/transcriptions"
        ]
    );
}
#[tokio::test]
async fn text_arrives_before_connection_closes_and_receiver_drop_cancels() {
    let server = Server::new(|_| Response {
        hangs: true,
        ..Response::new(
            200,
            event(json!({"content":"Already streaming"}), None).into_bytes(),
        )
    });
    let agent = server.agent(vec![]);
    let mut receiver = agent.send(UserTurn::text("Stream now"));
    assert_eq!(
        tokio::time::timeout(Duration::from_secs(2), receiver.recv())
            .await
            .unwrap(),
        Some(AgentEvent::TextDelta("Already streaming".into()))
    );
    agent.cancel().await;
    assert_eq!(
        agent_failure(&collect(receiver).await),
        Some(&AgentFailure::Cancelled)
    );
    let receiver = agent.send(UserTurn::text("Drop"));
    drop(receiver);
    tokio::task::yield_now().await;
}
#[tokio::test]
async fn interleaved_tool_fragments_preserve_call_order() {
    let count = AtomicUsize::new(0);
    let server = Server::new(move |request| {
        if count.fetch_add(1, Ordering::SeqCst) == 0 {
            return Response::stream(
                event(
                    json!({"tool_calls":[{"index":1,"id":"second","function":{"name":"echo_tool","arguments":"{\"value\":"}},{"index":0,"id":"first","function":{"name":"echo_tool","arguments":"{\"value\":"}}]}),
                    None,
                ) + &event(
                    json!({"tool_calls":[{"index":0,"function":{"arguments":"\"one\"}"}},{"index":1,"function":{"arguments":"\"two\"}"}}]}),
                    Some("tool_calls"),
                ),
            );
        }
        let body = request.json();
        let messages = body["messages"].as_array().unwrap();
        assert_eq!(messages[messages.len() - 2]["tool_call_id"], "first");
        assert_eq!(messages.last().unwrap()["tool_call_id"], "second");
        assert_eq!(messages[messages.len() - 2]["content"], "one");
        assert_eq!(messages.last().unwrap()["content"], "two");
        Response::stream(event(json!({"content":"Both complete"}), Some("stop")))
    });
    assert_eq!(
        final_text(
            &collect(
                server
                    .agent(vec![echo_provider()])
                    .send(UserTurn::text("Run both"))
            )
            .await
        ),
        Some("Both complete")
    );
}
#[tokio::test]
async fn new_turn_cancels_previous_without_leaking_history() {
    let started = Arc::new(Notify::new());
    let signal = started.clone();
    let count = AtomicUsize::new(0);
    let server = Server::new(move |request| {
        if count.fetch_add(1, Ordering::SeqCst) == 0 {
            signal.notify_one();
            return Response {
                hangs: true,
                ..Response::new(200, vec![])
            };
        }
        let body = request.json();
        assert_eq!(body["messages"].as_array().unwrap().len(), 2);
        assert_eq!(body["messages"][1]["content"], "Second");
        Response::stream(event(json!({"content":"Second finished"}), Some("stop")))
    });
    let agent = server.agent(vec![]);
    let first = agent.send(UserTurn::text("First"));
    tokio::time::timeout(Duration::from_secs(2), started.notified())
        .await
        .unwrap();
    let second = collect(agent.send(UserTurn::text("Second"))).await;
    assert_eq!(
        agent_failure(&collect(first).await),
        Some(&AgentFailure::Cancelled)
    );
    assert_eq!(final_text(&second), Some("Second finished"));
}
#[tokio::test]
async fn search_errors_readable_invalid_count_does_not_send() {
    for status in [401, 402] {
        let server = Server::new(move |_| {
            Response::new(status,br#"{"error":{"message":"Top up first","top_up_url":"https://publikhq.com/wallet"}}"#.to_vec())
        });
        let provider = PublikWebSearchProvider::new(server.source());
        let tool = provider.tools().await.remove(0);
        let result = tool.run(json!({"q":"Swift"})).await;
        assert!(result.is_error);
        assert!(result.content.contains(if status == 401 {
            "Sign in"
        } else {
            "https://publikhq.com/wallet"
        }));
    }
    let server = Server::new(|_| panic!("invalid search reached network"));
    let provider = PublikWebSearchProvider::new(server.source());
    let tool = provider.tools().await.remove(0);
    for count in [json!("bad"), json!(0), json!(21), json!(1.5), Value::Null] {
        assert!(tool.run(json!({"q":"Swift","count":count})).await.is_error);
    }
    assert!(tool.run(json!({"q":false})).await.is_error);
    assert!(provider.search(" ", 5).await.is_err());
}
#[tokio::test]
async fn duplicate_tool_names_fail_before_network() {
    let server = Server::new(|_| panic!("duplicate tools reached network"));
    let events = collect(
        server
            .agent(vec![echo_provider(), echo_provider()])
            .send(UserTurn::text("Try")),
    )
    .await;
    assert_eq!(
        agent_failure(&events),
        Some(&AgentFailure::Other {
            message: "More than one provider registered the tool echo_tool.".into()
        })
    );
}
#[tokio::test]
async fn invalid_sse_finish_indices_and_ids_fail() {
    for text in [
        event(json!({}), Some("length")),
        event(json!({"tool_calls":[{"index":128}]}), Some("tool_calls")),
        event(json!({"tool_calls":[{"index":-1}]}), Some("tool_calls")),
        event(json!({"tool_calls":[{"index":0.5}]}), Some("tool_calls")),
        event(
            json!({"tool_calls":[{"index":0,"function":{"name":"echo_tool"}}]}),
            Some("tool_calls"),
        ),
        event(
            json!({"tool_calls":[{"index":0,"id":"same"},{"index":1,"id":"same"}]}),
            Some("tool_calls"),
        ),
        "data: {\"error\":{\"message\":\"stream failed\"}}\n\n".into(),
    ] {
        let server = Server::new(move |_| Response::stream(text.clone()));
        let events = collect(server.agent(vec![]).send(UserTurn::text("Try"))).await;
        assert!(agent_failure(&events).is_some());
        assert!(final_text(&events).is_none());
    }
}
#[tokio::test]
async fn speech_validation_and_invalid_responses() {
    let server = Server::new(|_| Response::new(200, b"{}".to_vec()));
    let speech = PublikSpeechClient::new(server.source());
    for text in ["".to_string(), " ".into(), "a".repeat(4097)] {
        assert!(speech.synthesize(&text, DEFAULT_VOICE).await.is_err());
    }
    assert!(speech.transcribe(b"invalid".to_vec()).await.is_err());
    let mut huge = b"RIFFxxxxWAVE".to_vec();
    huge.resize(4_000_000, 0);
    assert!(speech.transcribe(huge).await.is_err());
    assert!(speech.synthesize("hello", DEFAULT_VOICE).await.is_err());
    assert!(speech
        .transcribe(b"RIFFxxxxWAVEaudio".to_vec())
        .await
        .is_err());
    assert!(PublikAiClient::new(server.source())
        .complete("", "", ModelTier::Fast)
        .await
        .is_err());
}

#[tokio::test]
async fn module_identity_provider_resolution_and_gate_without_persisting_overrides() {
    // All environment changes live in this one test; other tests use fixed, local credentials.
    struct Environment(Vec<(&'static str, Option<std::ffi::OsString>)>);
    impl Environment {
        fn set(&mut self, name: &'static str, value: impl AsRef<std::ffi::OsStr>) {
            self.0.push((name, std::env::var_os(name)));
            std::env::set_var(name, value);
        }
        fn remove(&mut self, name: &'static str) {
            self.0.push((name, std::env::var_os(name)));
            std::env::remove_var(name);
        }
    }
    impl Drop for Environment {
        fn drop(&mut self) {
            for (name, value) in self.0.drain(..).rev() {
                if let Some(value) = value {
                    std::env::set_var(name, value);
                } else {
                    std::env::remove_var(name);
                }
            }
        }
    }
    struct NoScreens;
    impl publik::GateUi for NoScreens {
        fn show(&mut self, _: &publik::Screen, _: Arc<AtomicBool>) -> Option<&'static str> {
            panic!("claimed account must not show a startup plan screen");
        }
        fn open_url(&mut self, _: &str) {
            panic!("claimed account must not open browser");
        }
    }
    let directory = tempfile::tempdir().unwrap();
    let mut environment = Environment(vec![]);
    environment.set("AMBIENT_DATA_DIR", directory.path());
    environment.remove("PUBLIK_API_KEY");
    environment.remove("PUBLIK_API_BASE_URL");
    environment.remove("PUBLIK_SELF_TEST");
    environment.set("PUBLIK_TELEMETRY", "on");
    environment.remove("DO_NOT_TRACK");
    environment.set("PUBLIK_TELEMETRY_INTERVAL_SECONDS", "86400");
    assert_eq!(publik::APP_SLUG, "ambient");
    assert_eq!(publik::APP_VERSION, env!("CARGO_PKG_VERSION"));
    assert!(publik::USES_AI);
    let own = AiCredential {
        base_url: "https://own.invalid/v1".into(),
        api_key: uuid::Uuid::new_v4().to_string(),
    };
    let source = PublikCredentialSource::new(Some(own.clone()));
    assert!(source
        .credential()
        .await
        .is_some_and(|credential| credential == own));
    assert!(PublikCredentialSource::default()
        .credential()
        .await
        .is_none());
    let path = publik::credential_path();
    assert!(path.starts_with(directory.path()));
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let stored = json!({"key":"pk_local-test","base_url":"https://stored.invalid/v1","install_id":"local-install","choice":"publik"});
    std::fs::write(&path, stored.to_string()).unwrap();
    let credential = source.credential().await.unwrap();
    assert!(credential.api_key == "pk_local-test");
    assert_eq!(credential.base_url, "https://stored.invalid/v1");
    publik::set_choice(Some("own_key"));
    assert!(source
        .credential()
        .await
        .is_some_and(|credential| credential == own));
    publik::set_choice(None);
    let before = std::fs::read(&path).unwrap();
    environment.set("PUBLIK_API_KEY", "development-only");
    environment.set("PUBLIK_API_BASE_URL", "http://127.0.0.1:1234/api/v1");
    let credential = source.credential().await.unwrap();
    assert!(credential.api_key == "development-only");
    assert_eq!(credential.base_url, "http://127.0.0.1:1234/api/v1");
    let telemetry_received = Arc::new(Notify::new());
    let telemetry_signal = telemetry_received.clone();
    let server = Server::new(move |request| {
        if request.path == "/api/v1/telemetry" {
            assert_eq!(request.json()["event"], "app_opened");
            telemetry_signal.notify_one();
            return Response::json(json!({}));
        }
        assert_eq!(request.path, "/api/v1/wallet");
        Response::json(json!({"claim_state":"claimed","plan":{"kind":"none"}}))
    });
    environment.set(
        "PUBLIK_TELEMETRY_URL",
        format!("{}/telemetry", server.base_url),
    );
    environment.set("PUBLIK_ORIGIN", server.base_url.trim_end_matches("/api/v1"));
    let (key, wallet, choice) = publik::ensure_signed_in(&mut NoScreens);
    tokio::time::timeout(Duration::from_secs(3), telemetry_received.notified())
        .await
        .unwrap();
    assert!(key == "development-only");
    assert_eq!(wallet["claim_state"], "claimed");
    assert_eq!(choice.as_deref(), Some("publik"));
    assert_eq!(std::fs::read(&path).unwrap(), before);
    environment.set("PUBLIK_API_BASE_URL", "file:///invalid");
    assert!(source.credential().await.is_none());
    environment.set("PUBLIK_API_KEY", "");
    assert!(source
        .credential()
        .await
        .is_some_and(|credential| credential == own));
    let sign_in = publik::gate_screen("sign_in", None, None, None);
    assert_eq!(sign_in.title, "Sign in with publik");
    assert_eq!(sign_in.buttons, vec![("sign_in", "Sign in with publik")]);
    let choose = publik::gate_screen(
        "choose",
        Some(&json!({"account":{"handle":"test"},"plan":{"kind":"none"}})),
        None,
        None,
    );
    assert_eq!(choose.title, "Choose how to pay for AI");
    assert!(choose.body.contains("@test"));
    let connect = publik::gate_screen(
        "choose",
        Some(&json!({"plan":{"kind":"plan","label":"Pro"}})),
        None,
        None,
    );
    assert_eq!(connect.title, "Connect your plan");
    assert_eq!(
        publik::top_up_url_from_402(&json!({})),
        ("Not enough publik API balance.".into(), None)
    );
    std::fs::write(&path, "corrupt{").unwrap();
    publik::set_choice(Some("publik"));
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "corrupt{");
    assert!(publik::read_credential().is_none());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cancellation_rejects_late_events_from_a_tool_already_polling() {
    struct FinishingTool {
        started: Arc<Notify>,
        release: Mutex<std::sync::mpsc::Receiver<()>>,
    }
    #[async_trait]
    impl AmbientTool for FinishingTool {
        fn definition(&self) -> ToolDefinition {
            TestTool::default().definition()
        }
        async fn run(&self, _: Value) -> ToolResult {
            self.started.notify_one();
            self.release
                .lock()
                .unwrap()
                .recv_timeout(Duration::from_secs(3))
                .unwrap();
            ToolResult::text("Tool finished its current poll")
        }
    }
    let started = Arc::new(Notify::new());
    let (release, wait) = std::sync::mpsc::channel();
    let provider = Arc::new(TestProvider::new(vec![Arc::new(FinishingTool {
        started: started.clone(),
        release: Mutex::new(wait),
    })]));
    let count = Arc::new(AtomicUsize::new(0));
    let requests = count.clone();
    let server = Server::new(move |_| {
        requests.fetch_add(1, Ordering::SeqCst);
        Response::stream(tool_event(&["echo_tool"], &[]))
    });
    let agent = server.agent(vec![provider]);
    let receiver = agent.send(UserTurn::text("Wait"));
    tokio::time::timeout(Duration::from_secs(2), started.notified())
        .await
        .unwrap();
    agent.cancel().await;
    release.send(()).unwrap();
    let events = collect(receiver).await;
    assert!(matches!(
        events.last(),
        Some(AgentEvent::Failed(AgentFailure::Cancelled))
    ));
    assert!(!events
        .iter()
        .any(|event| matches!(event, AgentEvent::ToolFinished { .. })));
    assert_eq!(count.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn speech_character_limit_counts_swift_style_graphemes() {
    let server = Server::new(|request| {
        assert_eq!(
            request.json()["input"].as_str().unwrap().chars().count(),
            8192
        );
        Response::new(200, b"RIFFxxxxWAVEaudio".to_vec())
    });
    let speech = PublikSpeechClient::new(server.source());
    assert!(speech
        .synthesize(&"e\u{301}".repeat(4096), DEFAULT_VOICE)
        .await
        .is_ok());
    assert!(speech
        .synthesize(&"e\u{301}".repeat(4097), DEFAULT_VOICE)
        .await
        .is_err());
}
