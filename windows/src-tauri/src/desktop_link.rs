//! XNook 联动宿主。阻塞协调只在后台运行，所有窗口动作在主线程完成。
use island_link::{Callbacks, Identity, Link, PeerStatus, IntegrationPreferences};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::{Emitter, Manager};

#[derive(Default)]
pub struct LinkState(Mutex<Option<Arc<Link>>>);
impl LinkState {
    fn link(&self) -> Result<Arc<Link>, String> { self.0.lock().map_err(|_| "联动状态不可用")?.clone().ok_or("双应用切换仅在 Windows 客户端提供".into()) }
    pub fn owns_display(&self) -> bool { self.0.lock().map(|link|link.as_ref().is_none_or(|link|link.owns_display())).unwrap_or(false) }
    pub fn shutdown(&self) { if let Ok(Some(link)) = self.0.lock().map(|link|link.clone()) { link.shutdown(); } }
}

pub fn setup(app: &tauri::AppHandle) -> Result<(), String> {
    if !cfg!(windows) { return Ok(()); }
    let link = Link::open(Identity::XIsland)?;
    *app.state::<LinkState>().0.lock().map_err(|_| "联动状态不可用")? = Some(link.clone());
    let show_app = app.clone(); let hide_app = app.clone(); let error_app = app.clone();
    link.start(Callbacks {
        show: Arc::new(move || window_action(&show_app, true)),
        hide: Arc::new(move || window_action(&hide_app, false)),
        on_error: Arc::new(move |error| { let _ = error_app.emit_to("main", "island-link-error", error); }),
    })
}

fn window_action(app: &tauri::AppHandle, show: bool) -> Result<(), String> {
    let (sender, receiver) = std::sync::mpsc::channel();
    let task = app.clone();
    app.run_on_main_thread(move || {
        let result = (|| {
            let window = task.get_webview_window("main").ok_or("主窗口尚未就绪")?;
            if show {
                task.state::<super::desktop::DesktopState>().window.lock().map_err(|_| "窗口状态不可用")?.show_owned(&window)?;
                if !window.is_visible().map_err(|error|error.to_string())? { return Err("当前全屏状态阻止浮岛显示，请退出全屏后重试".into()); }
            } else {
                window.hide().map_err(|error|error.to_string())?;
                if window.is_visible().map_err(|error|error.to_string())? { return Err("系统未能隐藏原浮岛窗口".into()); }
            }
            Ok(())
        })();
        let _ = sender.send(result);
    }).map_err(|error|error.to_string())?;
    // 不能超时后仍让排队的 show 执行；协调器在动作完成后再次检查请求期限并回滚迟到动作。
    receiver.recv().map_err(|_| "主窗口已关闭".to_string())?
}

pub fn show_from_native(app: &tauri::AppHandle) {
    let app = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let result = app.state::<LinkState>().link().and_then(|link|link.request_show(Duration::from_secs(6)));
        if let Err(error) = result { let _ = app.emit_to("main", "island-link-error", error); }
    });
}

#[tauri::command]
pub async fn island_peer_status(app: tauri::AppHandle) -> Result<PeerStatus, String> {
    let link = app.state::<LinkState>().link()?;
    tauri::async_runtime::spawn_blocking(move || link.peer_status()).await.map_err(|error|error.to_string())?
}

#[tauri::command]
pub async fn switch_island(window: tauri::WebviewWindow, app: tauri::AppHandle) -> Result<(), String> {
    if window.label() != "main" { return Err("只能从主浮岛切换应用".into()); }
    let link = app.state::<LinkState>().link()?;
    tauri::async_runtime::spawn_blocking(move || link.switch_to_peer(Duration::from_secs(6))).await.map_err(|error|error.to_string())?
}

#[tauri::command]
pub async fn island_get_preferences(app: tauri::AppHandle) -> Result<IntegrationPreferences, String> {
    let link = app.state::<LinkState>().link()?;
    tauri::async_runtime::spawn_blocking(move || link.preferences()).await.map_err(|error|error.to_string())?
}

#[tauri::command]
pub async fn island_set_preferences(window: tauri::WebviewWindow, app: tauri::AppHandle, preferences: IntegrationPreferences) -> Result<IntegrationPreferences, String> {
    if !matches!(window.label(), "main" | "preferences") { return Err("不能从此窗口修改联动设置".into()); }
    let link = app.state::<LinkState>().link()?;
    tauri::async_runtime::spawn_blocking(move || link.set_preferences(preferences)).await.map_err(|error|error.to_string())?
}
