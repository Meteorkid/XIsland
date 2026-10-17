use crate::{desktop_sync::{self, WindowSync}, runtime};
use serde_json::{json, Value};
use std::{collections::HashMap, sync::Mutex, time::Duration};
use tauri::Emitter;
use tokio::sync::oneshot;

#[derive(Default)]
pub struct SetupSync {
    snapshot: Mutex<Option<Value>>,
    requests: Mutex<HashMap<String, oneshot::Sender<Result<(), String>>>>,
}

impl SetupSync {
    pub fn invalidate(&self, app: &tauri::AppHandle) {
        if let Ok(mut snapshot) = self.snapshot.lock() { *snapshot = None; }
        let _ = app.emit_to("preferences", "setup-snapshot", json!({"rows":[],"refreshing":true,"attentionCount":0,"needsAttention":false}));
    }
}

fn bounded_object(value: &Value) -> Result<(), String> {
    if !value.is_object() || serde_json::to_vec(value).map_err(|_| "无效接入状态")?.len() > 128 * 1024 {
        return Err("接入状态无效或超过大小限制".into());
    }
    Ok(())
}

fn validate_action(action: &Value) -> Result<(), String> {
    let fields = action.as_object().ok_or("接入操作必须是对象")?;
    match action["kind"].as_str() {
        Some("presented") if fields.len() == 1 => Ok(()),
        Some("refresh") if fields.len() == 2 && action["prepareAutomatically"].is_boolean() => Ok(()),
        Some("setEnabled") if fields.len() == 3 && action["enabled"].is_boolean()
            && matches!(action["agent"].as_str(), Some("claude_code" | "codex" | "cursor" | "gemini_cli" | "windsurf" | "trae_cn" | "qwen" | "code_buddy" | "droid" | "opencode" | "kimi_code" | "copilot_cli" | "pi")) => Ok(()),
        _ => Err("未知接入操作".into()),
    }
}

#[tauri::command]
pub fn read_setup_state() -> Result<Option<Value>, String> {
    let path = runtime::directory().map_err(|e| e.to_string())?.join("integration-setup.json");
    match std::fs::symlink_metadata(&path) {
        Ok(info) if !info.is_file() || info.file_type().is_symlink() || info.len() > 128 * 1024 => return Err("接入记录无效，已保留原文件".into()),
        Ok(_) => {},
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err("接入记录无法读取".into()),
    }
    let bytes = std::fs::read(path).map_err(|_| "接入记录无法读取")?;
    let value = serde_json::from_slice(&bytes).map_err(|_| "接入记录损坏，已保留原文件")?;
    bounded_object(&value)?;
    Ok(Some(value))
}

#[tauri::command]
pub fn save_setup_state(window: tauri::WebviewWindow, sync: tauri::State<WindowSync>, owner_token: String, state: Value) -> Result<(), String> {
    desktop_sync::owner(&window)?;
    bounded_object(&state)?;
    let path = runtime::directory().map_err(|e| e.to_string())?.join("integration-setup.json");
    sync.with_owner(&owner_token, || runtime::atomic_write(&path, &serde_json::to_vec(&state).map_err(|_| "无效接入状态")?)
        .map_err(|_| "接入记录保存失败".into()))
}

#[tauri::command]
pub fn publish_setup_snapshot(window: tauri::WebviewWindow, app: tauri::AppHandle, sync: tauri::State<WindowSync>, setup: tauri::State<SetupSync>,
    owner_token: String, snapshot: Value) -> Result<(), String> {
    desktop_sync::owner(&window)?;
    bounded_object(&snapshot)?;
    sync.with_owner(&owner_token, || {
        *setup.snapshot.lock().map_err(|_| "接入副本不可用")? = Some(snapshot.clone());
        app.emit_to("preferences", "setup-snapshot", &snapshot).map_err(|e| e.to_string())
    })
}

#[tauri::command]
pub fn read_setup_snapshot(setup: tauri::State<SetupSync>) -> Result<Option<Value>, String> {
    Ok(setup.snapshot.lock().map_err(|_| "接入副本不可用")?.clone())
}

#[tauri::command]
pub async fn setup_action(app: tauri::AppHandle, setup: tauri::State<'_, SetupSync>, action: Value) -> Result<(), String> {
    validate_action(&action)?;
    let request_id = uuid::Uuid::new_v4().to_string();
    let (sender, receiver) = oneshot::channel();
    setup.requests.lock().map_err(|_| "接入操作不可用")?.insert(request_id.clone(), sender);
    if let Err(error) = app.emit_to("main", "setup-action", json!({"requestId":request_id,"action":action})) {
        setup.requests.lock().map_err(|_| "接入操作不可用")?.remove(&request_id);
        return Err(error.to_string());
    }
    let result = tokio::time::timeout(Duration::from_secs(120), receiver).await;
    setup.requests.lock().map_err(|_| "接入操作不可用")?.remove(&request_id);
    result.map_err(|_| "接入检查尚未完成，请稍后刷新状态")?.map_err(|_| "主窗口未完成接入操作")?
}

#[tauri::command]
pub fn finish_setup_action(window: tauri::WebviewWindow, sync: tauri::State<WindowSync>, setup: tauri::State<SetupSync>,
    owner_token: String, request_id: String, error: Option<String>) -> Result<(), String> {
    desktop_sync::owner(&window)?;
    sync.with_owner(&owner_token, || {
        if let Some(sender) = setup.requests.lock().map_err(|_| "接入操作不可用")?.remove(&request_id) {
            let _ = sender.send(error.map_or(Ok(()), Err));
        }
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn setup_only_accepts_fixed_actions_and_agents() {
        for valid in [json!({"kind":"presented"}), json!({"kind":"refresh","prepareAutomatically":true}),
            json!({"kind":"setEnabled","agent":"codex","enabled":false})] { assert!(validate_action(&valid).is_ok()); }
        for invalid in [json!({"kind":"refresh"}), json!({"kind":"presented","command":"x"}),
            json!({"kind":"setEnabled","agent":"unknown","enabled":true}), json!({"kind":"setEnabled","agent":"codex","enabled":"true"})] {
            assert!(validate_action(&invalid).is_err());
        }
        assert!(bounded_object(&json!({"value":"x".repeat(128*1024)})).is_err());
    }
}
