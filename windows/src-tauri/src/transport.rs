use crate::runtime::{self, RuntimeDescriptor};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{collections::HashMap, io, sync::{Arc, Mutex}, time::{Duration, SystemTime, UNIX_EPOCH}};
use tokio::{io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader}, sync::{oneshot, Semaphore}, time::timeout};

pub const MAX_FRAME: usize = 16 * 1024 * 1024;
const REQUEST_TTL: Duration = Duration::from_secs(120);

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EventEnvelope {
    pub message: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<u64>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientFrame {
    pub token: String,
    pub message: Value,
}

struct Pending {
    session_id: String,
    response_type: String,
    native_request_id: Option<String>,
    original: Value,
    expires_at: u64,
    sender: oneshot::Sender<(Value, oneshot::Sender<Result<(), String>>)>,
}

pub struct Bridge {
    pub descriptor: RuntimeDescriptor,
    pending: Mutex<HashMap<String, Pending>>,
    limit: Arc<Semaphore>,
}

impl Bridge {
    pub fn new(descriptor: RuntimeDescriptor) -> Self {
        Self { descriptor, pending: Mutex::new(HashMap::new()), limit: Arc::new(Semaphore::new(16)) }
    }

    pub async fn respond(&self, request_id: &str, response: Value) -> Result<(), String> {
        let receipt = self.begin_response(request_id, response)?;
        timeout(Duration::from_secs(5), receipt).await.map_err(|_| "回传确认超时")?
            .map_err(|_| "客户端已断开，回传未确认")?
    }

    fn begin_response(&self, request_id: &str, response: Value) -> Result<oneshot::Receiver<Result<(), String>>, String> {
        let mut pending = self.pending.lock().map_err(|_| "交互状态不可用")?;
        let request = pending.get(request_id).ok_or("请求已失效或已被处理")?;
        if now_ms() >= request.expires_at { return Err("请求已过期，请回原客户端处理".into()); }
        if response["sessionId"].as_str() != Some(request.session_id.as_str())
            || response["type"].as_str() != Some(request.response_type.as_str())
            || (response.get("nativeRequestId").is_some() && response["nativeRequestId"].as_str() != request.native_request_id.as_deref()) {
            return Err("响应与当前请求不匹配".into());
        }
        match request.response_type.as_str() {
            "permission_response" if !response["approved"].is_boolean() => return Err("批准结果必须是布尔值".into()),
            "plan_response" if !response["planApproved"].is_boolean() => return Err("计划结果必须是布尔值".into()),
            "question_response" => validate_answer(&request.original, &response)?,
            _ => {}
        }
        if response.get("feedback").is_some_and(|value| !value.is_string()) { return Err("反馈必须为文本".into()); }
        let (receipt, confirmation) = oneshot::channel();
        pending.remove(request_id).ok_or("请求已失效")?.sender.send((response, receipt)).map_err(|_| "客户端已断开")?;
        Ok(confirmation)
    }

    pub fn cancel(&self, request_id: &str) -> Result<(), String> {
        self.pending.lock().map_err(|_| "交互状态不可用")?.remove(request_id);
        Ok(())
    }

    pub fn cancel_all(&self) -> Result<usize, String> {
        let mut pending=self.pending.lock().map_err(|_| "交互状态不可用")?;
        let count=pending.len();
        pending.clear();
        Ok(count)
    }

    pub async fn serve(self: Arc<Self>, on_event: Arc<dyn Fn(EventEnvelope) + Send + Sync>, on_end: Arc<dyn Fn(String) + Send + Sync>) -> io::Result<()> {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let listener = tokio::net::UnixListener::bind(&self.descriptor.endpoint)?;
            std::fs::set_permissions(&self.descriptor.endpoint, std::fs::Permissions::from_mode(0o600))?;
            runtime::save_descriptor(&self.descriptor)?;
            loop {
                let (stream, _) = listener.accept().await?;
                let Ok(permit) = self.limit.clone().try_acquire_owned() else { continue };
                let (bridge, callback, ended) = (self.clone(), on_event.clone(), on_end.clone());
                tokio::spawn(async move { let _permit = permit; let _ = bridge.handle(stream, callback, ended).await; });
            }
        }
        #[cfg(windows)]
        {
            use tokio::net::windows::named_pipe::ServerOptions;
            let mut listener = ServerOptions::new().first_pipe_instance(true).reject_remote_clients(true).create(&self.descriptor.endpoint)?;
            runtime::save_descriptor(&self.descriptor)?;
            loop {
                listener.connect().await?;
                let stream = listener;
                listener = ServerOptions::new().reject_remote_clients(true).create(&self.descriptor.endpoint)?;
                let Ok(permit) = self.limit.clone().try_acquire_owned() else { continue };
                let (bridge, callback, ended) = (self.clone(), on_event.clone(), on_end.clone());
                tokio::spawn(async move { let _permit = permit; let _ = bridge.handle(stream, callback, ended).await; });
            }
        }
    }

    async fn handle<S>(&self, stream: S, on_event: Arc<dyn Fn(EventEnvelope) + Send + Sync>, on_end: Arc<dyn Fn(String) + Send + Sync>) -> io::Result<()>
    where S: AsyncRead + AsyncWrite + Unpin {
        let mut stream = BufReader::new(stream);
        let bytes = timeout(Duration::from_secs(5), read_frame(&mut stream)).await??;
        let frame: ClientFrame = serde_json::from_slice(&bytes)?;
        if frame.token != self.descriptor.token { return Err(io::Error::other("未授权的桥接请求")); }
        validate_message(&frame.message)?;
        let message = frame.message;
        let response_type = response_type(message["type"].as_str().unwrap_or(""));
        if let Some(response_type) = response_type {
            let request_id = uuid::Uuid::new_v4().to_string();
            let expires_at = now_ms() + REQUEST_TTL.as_millis() as u64;
            let (sender, receiver) = oneshot::channel();
            self.pending.lock().map_err(|_| io::Error::other("交互状态不可用"))?.insert(request_id.clone(), Pending {
                session_id: message["sessionId"].as_str().unwrap_or_default().into(), response_type: response_type.into(),
                native_request_id: message["nativeRequestId"].as_str().map(str::to_owned), original:message.clone(), expires_at, sender,
            });
            on_event(EventEnvelope { message, request_id: Some(request_id.clone()), expires_at: Some(expires_at) });
            let mut extra = [0u8; 1];
            let response = tokio::select! {
                result = timeout(REQUEST_TTL, receiver) => match result { Ok(Ok(response)) => Some(response), _ => None },
                _ = stream.read(&mut extra) => None,
            };
            self.cancel(&request_id).map_err(io::Error::other)?;
            if let Some((response, receipt)) = response {
                let delivered = write_frame(stream.get_mut(), &response).await;
                let _ = receipt.send(delivered.as_ref().map(|_| ()).map_err(|error| error.to_string()));
                if delivered.is_err() { on_end(request_id); }
                delivered?;
            } else {
                on_end(request_id);
                write_frame(stream.get_mut(), &json!({"error":"request_expired_or_disconnected"})).await?;
            }
        } else {
            on_event(EventEnvelope { message, request_id: None, expires_at: None });
            write_frame(stream.get_mut(), &json!({"ok":true})).await?;
        }
        Ok(())
    }
}

pub fn response_type(kind: &str) -> Option<&'static str> {
    match kind { "permission_request" => Some("permission_response"), "question" => Some("question_response"), "plan_review" => Some("plan_response"), _ => None }
}

pub fn validate_message(message: &Value) -> io::Result<()> {
    const EVENTS: &[&str] = &["session_start", "session_end", "tool_start", "tool_complete", "permission_request", "question", "interaction_resolved", "plan_review", "status_update", "progress", "subagent_start", "subagent_end", "context_compact", "recap", "observation_heartbeat", "observation_ended"];
    let session = message["sessionId"].as_str().filter(|s| !s.trim().is_empty() && !s.contains('\0'));
    if session.is_none() || !EVENTS.contains(&message["type"].as_str().unwrap_or("")) || !message["timestamp"].is_string() {
        return Err(io::Error::other("无效 DIMessage：检查事件类型、会话身份与时间戳"));
    }
    time::OffsetDateTime::parse(message["timestamp"].as_str().unwrap_or_default(), &time::format_description::well_known::Rfc3339)
        .map_err(|_|io::Error::other("时间戳必须是 ISO 8601 格式"))?;
    if message.get("options").is_some_and(|value| !value.as_array().is_some_and(|items| items.iter().all(Value::is_string))) {
        return Err(io::Error::other("选项必须是文本数组"));
    }
    for field in ["allowsCustomAnswer", "allowsMultipleAnswers"] {
        if message.get(field).is_some_and(|value| !value.is_boolean()) { return Err(io::Error::other("问答能力必须是布尔值")); }
    }
    Ok(())
}

fn validate_answer(request: &Value, response: &Value) -> Result<(), String> {
    let custom=request["allowsCustomAnswer"].as_bool()==Some(true);
    let multi=request["allowsMultipleAnswers"].as_bool()==Some(true);
    let options=request["options"].as_array().cloned().unwrap_or_default();
    let accepts=|answer:&str| !answer.trim().is_empty() && !answer.contains('\0') && answer.len()<=8192
        && (options.iter().any(|option|option.as_str()==Some(answer)) || custom);
    match (response.get("answer"),response.get("selectedAnswers")) {
        (Some(answer),None) if !multi && answer.as_str().is_some_and(accepts) => Ok(()),
        (None,Some(answers)) if multi => {
            let values=answers.as_array().ok_or("多选答案必须是数组")?;
            let mut seen=std::collections::HashSet::new();
            let mut total=0; let mut custom_count=0;
            if values.is_empty() || values.len()>128 { return Err("请选择有效答案".into()); }
            for value in values {
                let answer=value.as_str().filter(|answer|accepts(answer)).ok_or("答案不在允许范围内")?;
                total+=answer.len();
                if !options.iter().any(|option|option.as_str()==Some(answer)) { custom_count+=1; }
                if !seen.insert(answer) || total>8192 || custom_count>1 { return Err("答案重复或超出限制".into()); }
            }
            Ok(())
        }
        _=>Err("回答格式与当前问题不匹配".into())
    }
}

pub async fn read_frame<R: tokio::io::AsyncBufRead + Unpin>(reader: &mut R) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    let count = reader.take((MAX_FRAME + 1) as u64).read_until(b'\n', &mut bytes).await?;
    if count == 0 || count > MAX_FRAME || bytes.last() != Some(&b'\n') {
        return Err(io::Error::other("帧未完成或超过 16 MiB 上限"));
    }
    Ok(bytes)
}

pub async fn write_frame<W: AsyncWrite + Unpin, T: Serialize>(writer: &mut W, value: &T) -> io::Result<()> {
    let mut bytes = serde_json::to_vec(value)?;
    if bytes.len() >= MAX_FRAME { return Err(io::Error::other("消息超过 16 MiB 上限")); }
    bytes.push(b'\n');
    writer.write_all(&bytes).await?;
    writer.flush().await
}

pub async fn send(descriptor: &RuntimeDescriptor, message: Value) -> io::Result<Value> {
    validate_message(&message)?;
    let wait = if response_type(message["type"].as_str().unwrap_or("")).is_some() { REQUEST_TTL + Duration::from_secs(5) } else { Duration::from_secs(5) };
    #[cfg(unix)]
    let stream = timeout(Duration::from_secs(2), tokio::net::UnixStream::connect(&descriptor.endpoint)).await??;
    #[cfg(windows)]
    let stream = {
        use tokio::net::windows::named_pipe::ClientOptions;
        let started = tokio::time::Instant::now();
        loop {
            match ClientOptions::new().open(&descriptor.endpoint) {
                Ok(stream) => break stream,
                Err(error) if error.raw_os_error() == Some(231) && started.elapsed() < Duration::from_secs(2) => tokio::time::sleep(Duration::from_millis(20)).await,
                Err(error) => return Err(error),
            }
        }
    };
    let mut stream = BufReader::new(stream);
    write_frame(stream.get_mut(), &ClientFrame { token: descriptor.token.clone(), message }).await?;
    let bytes = timeout(wait, read_frame(&mut stream)).await??;
    let response: Value = serde_json::from_slice(&bytes)?;
    if response.get("error").is_some() { return Err(io::Error::other("请求超时或客户端已断开")); }
    Ok(response)
}

fn now_ms() -> u64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64 }

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn fragmented_frames_and_size_limit() {
        let mut reader = BufReader::new(&b"{\"type\":\"question\"}\nnext\n"[..]);
        assert_eq!(read_frame(&mut reader).await.unwrap(), b"{\"type\":\"question\"}\n");
        assert_eq!(read_frame(&mut reader).await.unwrap(), b"next\n");
        let oversized = vec![b'x'; MAX_FRAME + 1];
        assert!(read_frame(&mut BufReader::new(oversized.as_slice())).await.is_err());
        assert!(read_frame(&mut BufReader::new(&b"{}"[..])).await.is_err());
    }
    #[test]
    fn rejects_unknown_event_and_empty_identity() {
        assert!(validate_message(&json!({"type":"session_start","sessionId":"a","timestamp":"2026-10-13T00:00:00Z"})).is_ok());
        assert!(validate_message(&json!({"type":"permission_response","sessionId":"a","timestamp":"x"})).is_err());
        assert!(validate_message(&json!({"type":"session_start","sessionId":" ","timestamp":"x"})).is_err());
    }
    #[tokio::test]
    async fn response_is_bound_to_identity_and_one_shot() {
        let bridge = Bridge::new(runtime::create_descriptor().unwrap());
        let (tx, rx) = oneshot::channel();
        bridge.pending.lock().unwrap().insert("r".into(), Pending { session_id:"s".into(),response_type:"permission_response".into(),native_request_id:Some("n".into()),original:json!({}),expires_at:now_ms()+5000,sender:tx });
        let valid = json!({"type":"permission_response","sessionId":"s","nativeRequestId":"n","approved":false});
        let mut wrong = valid.clone(); wrong["sessionId"] = json!("other");
        assert!(bridge.begin_response("r",wrong).is_err());
        let receipt = bridge.begin_response("r",valid.clone()).unwrap();
        assert!(bridge.begin_response("r",valid).is_err());
        let (response, sender) = rx.await.unwrap();
        assert_eq!(response["approved"],false);
        sender.send(Ok(())).unwrap();
        assert!(receipt.await.unwrap().is_ok());
    }
}
