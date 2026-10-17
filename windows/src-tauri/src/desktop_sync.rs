use crate::runtime;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{collections::HashMap, sync::Mutex, time::Duration};
use tauri::{Emitter, Manager};
use tokio::sync::oneshot;

#[derive(Default)]
pub struct WindowSync {
    owner_token: Mutex<Option<String>>,
    snapshot: Mutex<Option<Value>>,
    actions: Mutex<HashMap<String, oneshot::Sender<Result<(), String>>>>,
}

impl WindowSync {
    pub fn register_owner(&self) -> Result<String, String> {
        let mut owner=self.owner_token.lock().map_err(|_| "主窗口身份不可用")?;
        let token=uuid::Uuid::new_v4().to_string();
        *owner=Some(token.clone());
        *self.snapshot.lock().map_err(|_| "会话副本不可用")?=None;
        Ok(token)
    }

    pub fn invalidate_owner(&self) {
        if let Ok(mut owner)=self.owner_token.lock() { *owner=None; }
    }

    pub fn with_owner<T>(&self, token: &str, action: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
        let owner=self.owner_token.lock().map_err(|_| "主窗口身份不可用")?;
        if owner.as_deref()!=Some(token) { return Err("已失效的主窗口不能写入当前历史".into()); }
        action()
    }
}

pub fn owner(window: &tauri::WebviewWindow) -> Result<(), String> {
    if window.label() != "main" { return Err("此操作仅能由主灵动岛执行".into()); }
    Ok(())
}

#[tauri::command]
pub fn publish_snapshot(window: tauri::WebviewWindow, app: tauri::AppHandle, state: tauri::State<WindowSync>, owner_token: String, mut snapshot: Value) -> Result<(), String> {
    owner(&window)?;
    let current_owner=state.owner_token.lock().map_err(|_| "主窗口身份不可用")?;
    if current_owner.as_deref()!=Some(owner_token.as_str()) { return Err("已失效的主窗口不能覆盖会话副本".into()); }
    if snapshot["revision"].as_u64().is_none() || !snapshot["sessions"].is_array() { return Err("无效会话快照".into()); }
    if serde_json::to_vec(&snapshot).map_err(|e| e.to_string())?.len() > 16*1024*1024 { return Err("会话快照超过大小上限".into()); }
    if let Some(sessions) = snapshot["sessions"].as_array_mut() {
        for session in sessions {
            if let Some(requests) = session["pendingInteractions"].as_array_mut() {
                for request in requests { if let Some(request) = request.as_object_mut() { request.remove("transportRequestId"); } }
            }
        }
    }
    *state.snapshot.lock().map_err(|_| "会话副本不可用")? = Some(snapshot.clone());
    drop(current_owner);
    app.emit_to("preferences", "session-snapshot", snapshot).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn read_snapshot(state: tauri::State<WindowSync>) -> Result<Option<Value>, String> {
    Ok(state.snapshot.lock().map_err(|_| "会话副本不可用")?.clone())
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum HistoryAction { Dismiss { #[serde(rename = "sessionId")] session_id: String }, Clear }

const SOUND_EVENTS: &[&str] = &["session_start","session_end","permission_request","question","plan_review",
    "approved","denied","answered","tool_start","context_compacting","error"];

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct SoundPreview { request_id: String, event: String }

#[tauri::command]
pub async fn preview_sound(app: tauri::AppHandle, state: tauri::State<'_, WindowSync>, event: String) -> Result<(), String> {
    if !SOUND_EVENTS.contains(&event.as_str()) { return Err("未知声音事件".into()); }
    let request_id=uuid::Uuid::new_v4().to_string();
    let (sender,receiver)=oneshot::channel();
    state.actions.lock().map_err(|_|"操作队列不可用")?.insert(request_id.clone(),sender);
    if let Err(error)=app.emit_to("main","preview-sound",SoundPreview{request_id:request_id.clone(),event}) {
        state.actions.lock().map_err(|_|"操作队列不可用")?.remove(&request_id);
        return Err(error.to_string());
    }
    let result=tokio::time::timeout(Duration::from_secs(5),receiver).await;
    state.actions.lock().map_err(|_|"操作队列不可用")?.remove(&request_id);
    result.map_err(|_|"声音试听确认超时")?.map_err(|_|"声音试听未完成")?
}

#[tauri::command]
pub fn finish_sound_preview(window: tauri::WebviewWindow, state: tauri::State<WindowSync>, request_id: String, error: Option<String>) -> Result<(), String> {
    finish_history_action(window,state,request_id,error)
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct OwnerAction { request_id: String, action: HistoryAction }

#[tauri::command]
pub async fn history_action(app: tauri::AppHandle, state: tauri::State<'_, WindowSync>, action: HistoryAction) -> Result<(), String> {
    if let HistoryAction::Dismiss { session_id } = &action {
        if session_id.is_empty() || session_id.len() > 65536 { return Err("无效会话 ID".into()); }
    }
    let request_id = uuid::Uuid::new_v4().to_string();
    let (sender, receiver) = oneshot::channel();
    state.actions.lock().map_err(|_| "操作队列不可用")?.insert(request_id.clone(), sender);
    if let Err(error) = app.emit_to("main", "history-action", OwnerAction { request_id: request_id.clone(), action }) {
        state.actions.lock().map_err(|_| "操作队列不可用")?.remove(&request_id);
        return Err(error.to_string());
    }
    let result = tokio::time::timeout(Duration::from_secs(10), receiver).await;
    state.actions.lock().map_err(|_| "操作队列不可用")?.remove(&request_id);
    result.map_err(|_| "历史操作确认超时")?.map_err(|_| "主窗口未完成历史操作")?
}

#[tauri::command]
pub fn finish_history_action(window: tauri::WebviewWindow, state: tauri::State<WindowSync>, request_id: String, error: Option<String>) -> Result<(), String> {
    owner(&window)?;
    if let Some(sender) = state.actions.lock().map_err(|_| "操作队列不可用")?.remove(&request_id) {
        let _ = sender.send(error.map_or(Ok(()), Err));
    }
    Ok(())
}

#[tauri::command]
pub fn open_preferences(app: tauri::AppHandle, pane: String) -> Result<(), String> {
    const PANES: &[&str] = &["general", "display", "integration", "agents", "sound", "history", "statistics", "about"];
    if !PANES.contains(&pane.as_str()) { return Err("未知设置页面".into()); }
    if let Some(window) = app.get_webview_window("preferences") {
        app.emit_to("preferences", "settings-pane", pane).map_err(|e| e.to_string())?;
        window.show().map_err(|e| e.to_string())?;
        return window.set_focus().map_err(|e| e.to_string());
    }
    let monitor=app.get_webview_window("main").and_then(|window|window.current_monitor().ok().flatten());
    let (width,height)=monitor.map(|monitor| {
        ((monitor.size().width as f64/monitor.scale_factor()-32.0).clamp(320.0,760.0),
         (monitor.size().height as f64/monitor.scale_factor()-80.0).clamp(300.0,520.0))
    }).unwrap_or((760.0,520.0));
    tauri::WebviewWindowBuilder::new(&app, "preferences", tauri::WebviewUrl::App(format!("index.html?window=settings&pane={pane}").into()))
        .additional_browser_args("--autoplay-policy=no-user-gesture-required")
        .title("X Island").inner_size(width, height).min_inner_size(320.0, 300.0)
        .resizable(true).center().focused(true).build().map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
pub fn close_preferences(window: tauri::WebviewWindow) -> Result<(), String> {
    if window.label() != "preferences" { return Err("当前不是设置窗口".into()); }
    window.app_handle().emit_to("main", "setup-dismissed", ()).map_err(|e| e.to_string())?;
    window.close().map_err(|e| e.to_string())
}

pub fn read_preferences_file() -> Result<Option<Value>, String> {
    let path = runtime::directory().map_err(|e| e.to_string())?.join("settings.json");
    match std::fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes).map(Some).map_err(|_| "设置文件损坏，原文件已保留".into()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!("无法读取设置：{error}")),
    }
}

#[tauri::command]
pub fn read_preferences() -> Result<Option<Value>, String> { read_preferences_file() }

pub fn validate_preferences(settings: &Value) -> Result<(), String> {
    let object = settings.as_object().ok_or("设置必须是对象")?;
    if serde_json::to_vec(settings).map_err(|e| e.to_string())?.len() > 65536 { return Err("设置过大".into()); }
    for field in ["soundEnabled", "quietHours", "hoverToExpand", "showTicker", "reduceMotion", "hideInFullscreen", "followPointer", "disableAnimations"] {
        if object.get(field).is_some_and(|value| !value.is_boolean()) { return Err(format!("无效布尔设置：{field}")); }
    }
    for (field, min, max) in [("collapsedWidth", 200.0, 400.0), ("collapsedHeight", 30.0, 60.0), ("panelWidth", 320.0, 600.0), ("autoHideSeconds", 0.0, 300.0)] {
        if object.get(field).is_some_and(|value| !value.as_f64().is_some_and(|number| number.is_finite() && number >= min && number <= max)) { return Err(format!("无效数值设置：{field}")); }
    }
    for (field, choices) in [("theme", &["dark", "light", "system"][..]), ("language", &["system", "zh", "en", "ja", "ko", "fr"][..])] {
        if object.get(field).is_some_and(|value| !value.as_str().is_some_and(|text| choices.contains(&text))) { return Err(format!("无效设置：{field}")); }
    }
    if object.get("soundVolume").is_some_and(|value| !value.as_f64().is_some_and(|value| (0.0..=1.0).contains(&value))) { return Err("音量必须介于0和1之间".into()); }
    if let Some(events)=object.get("eventSounds") {
        let events=events.as_object().ok_or("声音事件必须是对象")?;
        if events.iter().any(|(event,value)|!SOUND_EVENTS.contains(&event.as_str())||!value.is_boolean()) { return Err("声音事件设置无效".into()); }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retired_owner_cannot_commit_writes_after_reload() {
        let sync=WindowSync::default();
        let first=sync.register_owner().unwrap();
        assert_eq!(sync.with_owner(&first,||Ok(7)).unwrap(),7);
        sync.invalidate_owner();
        assert!(sync.with_owner::<()>(&first,||panic!("stale writer executed")).is_err());
        let second=sync.register_owner().unwrap();
        assert_ne!(first,second);
        assert!(sync.with_owner::<()>(&first,||panic!("previous generation executed")).is_err());
        assert_eq!(sync.with_owner(&second,||Ok(9)).unwrap(),9);
    }

    #[test]
    fn audio_settings_validate_volume_and_each_known_event() {
        assert!(validate_preferences(&serde_json::json!({"soundVolume":0,"eventSounds":{"approved":true,"tool_start":false}})).is_ok());
        for value in [serde_json::json!({"soundVolume":-0.1}),serde_json::json!({"soundVolume":2}),
            serde_json::json!({"eventSounds":{"made_up":true}}),serde_json::json!({"eventSounds":{"approved":"true"}})] {
            assert!(validate_preferences(&value).is_err());
        }
    }
}
