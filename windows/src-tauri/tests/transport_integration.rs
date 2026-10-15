use serde_json::{json, Value};
use std::{env, ffi::OsString, fs, path::{Path, PathBuf}, process::{Child, Command, Stdio}, sync::Arc, time::Duration};
use tokio::{sync::mpsc, time::{sleep, timeout, Instant}};
use xisland_windows::{runtime, transport::{self, Bridge, ClientFrame, EventEnvelope}};

const DEADLINE: Duration = Duration::from_secs(8);

// 此测试二进制只含一个普通测试；环境设置发生在 Tokio 运行时启动之前。
struct IsolatedRuntime {
    root: PathBuf,
    previous: [(String, Option<OsString>); 2],
    endpoint: Option<String>,
}

impl IsolatedRuntime {
    fn new() -> Self {
        let root = env::temp_dir().join(format!("xisland-ipc-test-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let previous = [
            ("XISLAND_TEST_MODE".to_owned(), env::var_os("XISLAND_TEST_MODE")),
            ("XISLAND_RUNTIME_DIR".to_owned(), env::var_os("XISLAND_RUNTIME_DIR")),
        ];
        unsafe {
            env::set_var("XISLAND_TEST_MODE", "1");
            env::set_var("XISLAND_RUNTIME_DIR", &root);
        }
        Self { root, previous, endpoint: None }
    }
}

impl Drop for IsolatedRuntime {
    fn drop(&mut self) {
        for (key, value) in &self.previous {
            unsafe {
                match value { Some(value) => env::set_var(key, value), None => env::remove_var(key) }
            }
        }
        if let Some(endpoint) = &self.endpoint {
            #[cfg(unix)]
            let _ = fs::remove_file(endpoint);
            #[cfg(windows)]
            let _ = endpoint;
        }
        let _ = fs::remove_dir_all(&self.root);
    }
}

struct ClientProcess { child: Child, result_path: PathBuf }

impl ClientProcess {
    fn start(root: &Path, mode: &str, message: Value) -> Self {
        let result_path = root.join(format!("result-{}.json", uuid::Uuid::new_v4()));
        let child = Command::new(env::current_exe().unwrap())
            .args(["--exact", "transport_client_process", "--ignored", "--nocapture"])
            .env("XISLAND_TEST_MODE", "1")
            .env("XISLAND_RUNTIME_DIR", root)
            .env("XISLAND_IPC_TEST_MODE", mode)
            .env("XISLAND_IPC_TEST_MESSAGE", serde_json::to_string(&message).unwrap())
            .env("XISLAND_IPC_TEST_RESULT", &result_path)
            .stdout(Stdio::null()).stderr(Stdio::inherit())
            .spawn().unwrap();
        Self { child, result_path }
    }

    async fn finish(&mut self) -> Value {
        let started = Instant::now();
        loop {
            if let Some(status) = self.child.try_wait().unwrap() {
                assert!(status.success(), "transport client process failed: {status}");
                return serde_json::from_slice(&fs::read(&self.result_path).unwrap()).unwrap();
            }
            assert!(started.elapsed() < DEADLINE, "transport client process did not finish");
            sleep(Duration::from_millis(10)).await;
        }
    }
}

impl Drop for ClientProcess {
    fn drop(&mut self) {
        if self.child.try_wait().ok().flatten().is_none() {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}

fn message(kind: &str) -> Value {
    json!({"type":kind,"sessionId":"claude_code-isolated","agentType":"claude_code","timestamp":"2026-10-13T00:00:00Z"})
}

fn response(event: &EventEnvelope, kind: &str, fields: Value) -> Value {
    let mut response = json!({
        "type":kind,"sessionId":event.message["sessionId"],
        "timestamp":"2026-10-13T00:00:01Z",
    });
    if let Some(id) = event.message["nativeRequestId"].as_str() { response["nativeRequestId"] = json!(id); }
    response.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
    response
}

async fn next_event(receiver: &mut mpsc::UnboundedReceiver<EventEnvelope>) -> EventEnvelope {
    timeout(DEADLINE, receiver.recv()).await.expect("bridge did not publish an event").unwrap()
}

#[test]
fn isolated_subprocess_transport_round_trips_and_rejects_invalid_decisions() {
    let mut isolated = IsolatedRuntime::new();
    let descriptor = runtime::create_descriptor().unwrap();
    isolated.endpoint = Some(descriptor.endpoint.clone());
    let executor = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    executor.block_on(async {
        let bridge = Arc::new(Bridge::new(descriptor));
        let (event_tx, mut events) = mpsc::unbounded_channel();
        let (end_tx, mut ended) = mpsc::unbounded_channel();
        let server = tokio::spawn(bridge.clone().serve(
            Arc::new(move |event| { let _ = event_tx.send(event); }),
            Arc::new(move |request_id| { let _ = end_tx.send(request_id); }),
        ));
        let started = Instant::now();
        while !isolated.root.join("runtime.json").exists() {
            assert!(!server.is_finished(), "bridge exited before saving its descriptor");
            assert!(started.elapsed() < DEADLINE, "bridge did not become ready");
            sleep(Duration::from_millis(10)).await;
        }

        // 不同 token 的独立进程不能投递消息，也不能创建待审批项。
        let mut unauthorized = ClientProcess::start(&isolated.root, "bad-token", message("permission_request"));
        assert_eq!(unauthorized.finish().await["ok"], false);
        assert!(events.try_recv().is_err());

        let mut observation = ClientProcess::start(&isolated.root, "send", message("session_start"));
        let event = next_event(&mut events).await;
        assert!(event.request_id.is_none());
        assert_eq!(observation.finish().await["value"]["ok"], true);

        let mut approval = ClientProcess::start(&isolated.root, "send", message("permission_request"));
        let event = next_event(&mut events).await;
        let request_id = event.request_id.as_ref().unwrap();
        let valid = response(&event, "permission_response", json!({"approved":false}));
        assert!(bridge.respond("unknown-request", valid.clone()).await.is_err());
        for (field, wrong_value) in [("sessionId", json!("wrong")), ("type", json!("question_response")), ("approved", json!(1))] {
            let mut wrong = valid.clone(); wrong[field] = wrong_value;
            assert!(bridge.respond(request_id, wrong).await.is_err(), "accepted invalid {field}");
        }
        bridge.respond(request_id, valid.clone()).await.unwrap();
        let result = approval.finish().await;
        assert_eq!(result["ok"], true);
        assert_eq!(result["value"]["approved"], false);
        assert_eq!(result["value"]["nativeRequestId"], event.message["nativeRequestId"]);
        assert!(bridge.respond(request_id, valid).await.is_err());

        // 同会话并发请求按 transport request ID 绑定；响应携带原生 ID 时额外核对。
        let mut first_message = message("permission_request"); first_message["nativeRequestId"] = json!("native-first");
        let mut second_message = message("permission_request"); second_message["nativeRequestId"] = json!("native-second");
        let mut first = ClientProcess::start(&isolated.root, "send", first_message);
        let first_event = next_event(&mut events).await;
        let mut second = ClientProcess::start(&isolated.root, "send", second_message);
        let second_event = next_event(&mut events).await;
        let first_response = response(&first_event, "permission_response", json!({"approved":true}));
        assert!(bridge.respond(second_event.request_id.as_ref().unwrap(), first_response.clone()).await.is_err());
        bridge.respond(first_event.request_id.as_ref().unwrap(), first_response).await.unwrap();
        bridge.respond(second_event.request_id.as_ref().unwrap(), response(&second_event, "permission_response", json!({"approved":false}))).await.unwrap();
        assert_eq!(first.finish().await["value"]["approved"], true);
        assert_eq!(second.finish().await["value"]["approved"], false);

        let mut question = message("question");
        question["questionText"] = json!("Choose"); question["options"] = json!(["A", "B"]);
        question["allowsCustomAnswer"] = json!(false); question["allowsMultipleAnswers"] = json!(false);
        let mut single = ClientProcess::start(&isolated.root, "send", question.clone());
        let event = next_event(&mut events).await;
        for bad in [json!({"answer":""}), json!({"answer":" "}), json!({"answer":"not-an-option"}),
            json!({"selectedAnswers":["A"]}), json!({"selectedAnswers":[7]}), json!({"answer":"A","selectedAnswers":["B"]})] {
            assert!(bridge.respond(event.request_id.as_ref().unwrap(), response(&event, "question_response", bad)).await.is_err());
        }
        bridge.respond(event.request_id.as_ref().unwrap(), response(&event, "question_response", json!({"answer":"B"}))).await.unwrap();
        assert_eq!(single.finish().await["value"]["answer"], "B");

        question["allowsMultipleAnswers"] = json!(true);
        let mut multiple = ClientProcess::start(&isolated.root, "send", question);
        let event = next_event(&mut events).await;
        for bad in [json!({"answer":"A"}), json!({"selectedAnswers":[]}), json!({"selectedAnswers":["A","A"]}),
            json!({"selectedAnswers":["A",7]}), json!({"selectedAnswers":["C"]})] {
            assert!(bridge.respond(event.request_id.as_ref().unwrap(), response(&event, "question_response", bad)).await.is_err());
        }
        bridge.respond(event.request_id.as_ref().unwrap(), response(&event, "question_response", json!({"selectedAnswers":["A","B"]}))).await.unwrap();
        assert_eq!(multiple.finish().await["value"]["selectedAnswers"], json!(["A","B"]));

        let mut cancelled = ClientProcess::start(&isolated.root, "send", message("permission_request"));
        let event = next_event(&mut events).await;
        let request_id = event.request_id.unwrap();
        bridge.cancel(&request_id).unwrap();
        assert_eq!(timeout(DEADLINE, ended.recv()).await.unwrap().unwrap(), request_id);
        assert_eq!(cancelled.finish().await["ok"], false);

        // 子进程退出使写回可能失败；仍必须发出 on_end 清除 UI 待审批状态。
        let mut disconnected = ClientProcess::start(&isolated.root, "disconnect", message("permission_request"));
        let event = next_event(&mut events).await;
        assert_eq!(disconnected.finish().await["ok"], true);
        assert_eq!(timeout(DEADLINE, ended.recv()).await.expect("disconnect did not invalidate UI request").unwrap(), *event.request_id.as_ref().unwrap());
        assert!(bridge.respond(event.request_id.as_ref().unwrap(), response(&event, "permission_response", json!({"approved":true}))).await.is_err());
        server.abort();
        let _ = server.await;
    });
    // 先关闭运行时及所有连接，再恢复环境和删除隔离数据。
    drop(executor);
}

#[test]
#[ignore = "仅由真实 IPC 集成测试作为独立客户端进程启动"]
fn transport_client_process() {
    let mode = env::var("XISLAND_IPC_TEST_MODE").expect("isolated worker mode");
    let message: Value = serde_json::from_str(&env::var("XISLAND_IPC_TEST_MESSAGE").unwrap()).unwrap();
    let mut descriptor = runtime::read_descriptor().unwrap();
    if mode == "bad-token" { descriptor.token = "wrong-test-token".into(); }
    let executor = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let result = executor.block_on(async {
        if mode == "disconnect" {
            #[cfg(unix)]
            let mut stream = tokio::net::UnixStream::connect(&descriptor.endpoint).await.unwrap();
            #[cfg(windows)]
            let mut stream = {
                let started = Instant::now();
                loop {
                    match tokio::net::windows::named_pipe::ClientOptions::new().open(&descriptor.endpoint) {
                        Ok(stream) => break stream,
                        Err(error) if error.raw_os_error() == Some(231) && started.elapsed() < DEADLINE => sleep(Duration::from_millis(10)).await,
                        Err(error) => panic!("test client cannot connect: {error}"),
                    }
                }
            };
            transport::write_frame(&mut stream, &ClientFrame { token: descriptor.token, message }).await.unwrap();
            drop(stream);
            return json!({"ok":true});
        }
        match transport::send(&descriptor, message).await {
            Ok(value) => json!({"ok":true,"value":value}),
            Err(_) => json!({"ok":false}),
        }
    });
    fs::write(env::var_os("XISLAND_IPC_TEST_RESULT").unwrap(), serde_json::to_vec(&result).unwrap()).unwrap();
}
