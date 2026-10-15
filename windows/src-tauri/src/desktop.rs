use crate::{runtime, desktop_sync::{self, WindowSync}, transport::{Bridge, EventEnvelope}, windowing::{WindowController, WindowReport}};
use serde::Serialize;
use serde_json::Value;
use std::sync::{Arc, Mutex};
use tauri::{Emitter, Manager};
use tauri_plugin_dialog::DialogExt;

#[derive(Default)]
struct FrontendQueue {
    ready: bool,
    events: Vec<EventEnvelope>,
    error: Option<String>,
    ended: Vec<String>,
}

struct DesktopState {
    bridge: Arc<Bridge>,
    queue: Mutex<FrontendQueue>,
    window: Mutex<WindowController>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ConnectionSnapshot {
    events: Vec<EventEnvelope>,
    error: Option<String>,
    ended_request_ids: Vec<String>,
    owner_token: String,
}

#[tauri::command]
fn frontend_ready(window: tauri::WebviewWindow, state: tauri::State<DesktopState>, sync: tauri::State<WindowSync>) -> Result<ConnectionSnapshot, String> {
    desktop_sync::owner(&window)?;
    let mut queue = state.queue.lock().map_err(|_| "前端队列不可用")?;
    queue.ready = true;
    Ok(ConnectionSnapshot { events: std::mem::take(&mut queue.events), error: queue.error.clone(), ended_request_ids: std::mem::take(&mut queue.ended), owner_token: sync.register_owner()? })
}

#[tauri::command]
async fn respond(window: tauri::WebviewWindow, request_id: String, response: Value, state: tauri::State<'_, DesktopState>) -> Result<(), String> {
    desktop_sync::owner(&window)?;
    state.bridge.respond(&request_id, response).await
}

#[tauri::command]
fn cancel_request(window: tauri::WebviewWindow, request_id: String, state: tauri::State<DesktopState>) -> Result<(), String> {
    desktop_sync::owner(&window)?;
    state.bridge.cancel(&request_id)
}

#[tauri::command]
fn resize_island(window: tauri::WebviewWindow, state: tauri::State<DesktopState>, width: f64, height: f64, expanded: bool) -> Result<WindowReport, String> {
    desktop_sync::owner(&window)?;
    if !width.is_finite() || !height.is_finite() || !(180.0..=1200.0).contains(&width) || !(24.0..=1200.0).contains(&height) {
        return Err("无效窗口尺寸".into());
    }
    if !expanded { window.set_focusable(false).map_err(|e|e.to_string())?; }
    state.window.lock().map_err(|_| "窗口状态不可用")?.resize(&window, width, height, expanded)
}

#[tauri::command]
fn platform_info() -> Value {
    serde_json::json!({ "os":std::env::consts::OS, "nativeAutoplayAudio":cfg!(windows), "capabilities": {"monitorFollowing":true,"fullscreenHiding":cfg!(windows),"horizontalDragging":true} })
}

#[tauri::command]
fn protect_interaction(window: tauri::WebviewWindow, state: tauri::State<DesktopState>, protected: bool) -> Result<WindowReport, String> {
    state.window.lock().map_err(|_| "窗口状态不可用")?.set_interaction(&window, protected)
}

#[tauri::command]
fn drag_island(window: tauri::WebviewWindow, state: tauri::State<DesktopState>, phase: String) -> Result<WindowReport, String> {
    let mut controller=state.window.lock().map_err(|_| "窗口状态不可用")?;
    match phase.as_str() {
        "begin"=>controller.begin_drag(&window),
        "update"=>controller.update_drag(&window),
        "end"=>controller.end_drag(&window),
        _=>Err("未知拖动阶段".into())
    }
}

#[tauri::command]
fn focus_input(window: tauri::WebviewWindow) -> Result<(), String> {
    window.set_focusable(true).map_err(|e|e.to_string())?;
    window.set_focus().map_err(|e|e.to_string())
}

#[tauri::command]
fn load_history() -> Result<Option<String>, String> {
    let path = runtime::directory().map_err(|e|e.to_string())?.join("history.json");
    match std::fs::read_to_string(path) {
        Ok(value) => Ok(Some(value)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!("历史读取失败：{error}")),
    }
}

#[tauri::command]
fn save_history(window: tauri::WebviewWindow, sync: tauri::State<WindowSync>, owner_token: String, content: String) -> Result<(), String> {
    desktop_sync::owner(&window)?;
    if content.len() > 16*1024*1024 { return Err("历史数据超过 16 MiB 上限".into()); }
    serde_json::from_str::<Value>(&content).map_err(|_| "历史数据不是有效 JSON")?;
    let path = runtime::directory().map_err(|e|e.to_string())?.join("history.json");
    sync.with_owner(&owner_token, || runtime::atomic_write(&path,content.as_bytes()).map_err(|e|format!("历史保存失败：{e}")))
}

#[tauri::command]
fn save_preferences(app: tauri::AppHandle, settings: Value) -> Result<(), String> {
    desktop_sync::validate_preferences(&settings)?;
    if let Some(window)=app.get_webview_window("main") {
        app.state::<DesktopState>().window.lock().map_err(|_| "窗口状态不可用")?
            .configure(&window,settings["followPointer"].as_bool().unwrap_or(true),settings["hideInFullscreen"].as_bool().unwrap_or(false))?;
    }
    let path = runtime::directory().map_err(|e| e.to_string())?.join("settings.json");
    runtime::atomic_write(&path, &serde_json::to_vec(&settings).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    app.emit("preferences-changed", settings).map_err(|e| e.to_string())
}

#[tauri::command]
async fn export_history(app: tauri::AppHandle, content: String) -> Result<(), String> {
    if content.len() > 16*1024*1024 { return Err("导出内容过大".into()); }
    serde_json::from_str::<Value>(&content).map_err(|_| "无效导出数据")?;
    tauri::async_runtime::spawn_blocking(move || {
        let destination = app.dialog().file().add_filter("JSON", &["json"]).set_file_name("XIsland-history.json").blocking_save_file();
        let Some(destination) = destination else { return Err("已取消导出".to_string()); };
        let path = destination.into_path().map_err(|_| "请选择本地文件")?;
        runtime::atomic_write(&path,content.as_bytes()).map_err(|e|format!("导出失败：{e}"))
    }).await.map_err(|e| e.to_string())?
}

#[tauri::command]
fn jump_to_session(title: String) -> Result<(), String> {
    if title.trim().is_empty() || title.len() > 512 { return Err("会话没有可用于定位的窗口标题".into()); }
    #[cfg(windows)]
    {
        use windows_sys::{core::BOOL, Win32::{Foundation::{HWND, LPARAM}, UI::WindowsAndMessaging::*}};
        struct Search { title: String, matches: Vec<HWND> }
        unsafe extern "system" fn visit(hwnd: HWND, pointer: LPARAM) -> BOOL {
            let search = &mut *(pointer as *mut Search);
            if IsWindowVisible(hwnd) == 0 { return 1; }
            let length = GetWindowTextLengthW(hwnd);
            if length <= 0 || length > 8192 { return 1; }
            let mut buffer = vec![0u16;length as usize+1];
            let copied = GetWindowTextW(hwnd,buffer.as_mut_ptr(),buffer.len() as i32);
            let title = String::from_utf16_lossy(&buffer[..copied as usize]);
            if title.contains(&search.title) { search.matches.push(hwnd); }
            1
        }
        let mut search = Search {title, matches:Vec::new()};
        unsafe { EnumWindows(Some(visit), &mut search as *mut Search as LPARAM); }
        if search.matches.len() != 1 { return Err("无法唯一定位终端窗口，请回原客户端选择；精确标签跳转待适配".into()); }
        unsafe {
            ShowWindow(search.matches[0],SW_RESTORE);
            if SetForegroundWindow(search.matches[0]) == 0 { return Err("系统未允许切换前台窗口".into()); }
        }
        Ok(())
    }
    #[cfg(not(windows))]
    { Err("Windows 终端跳转需在 Windows 客户端验证".into()) }
}

pub fn run() {
    let descriptor = match runtime::create_descriptor() {
        Ok(value) => value,
        Err(error) => { eprintln!("XIsland 初始化失败：{error}"); return; }
    };
    let state = DesktopState { bridge: Arc::new(Bridge::new(descriptor)), queue: Mutex::new(FrontendQueue::default()), window: Mutex::new(WindowController::default()) };
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app,_,_| { if let Some(window)=app.get_webview_window("main") { let _=window.show(); } }))
        .plugin(tauri_plugin_dialog::init())
        .manage(state)
        .manage(WindowSync::default())
        .on_page_load(|webview,payload| {
            if webview.label()=="main" && payload.event()==tauri::webview::PageLoadEvent::Started {
                if let Some(state)=webview.app_handle().try_state::<DesktopState>() {
                    let was_ready=if let Ok(mut queue)=state.queue.lock() { let previous=queue.ready; queue.ready=false; previous } else {false};
                    if was_ready { let _=state.bridge.cancel_all(); }
                }
                if let Some(sync)=webview.app_handle().try_state::<WindowSync>() { sync.invalidate_owner(); }
            }
        })
        .invoke_handler(tauri::generate_handler![frontend_ready,respond,cancel_request,resize_island,focus_input,load_history,save_history,export_history,jump_to_session,save_preferences,
            desktop_sync::publish_snapshot,desktop_sync::read_snapshot,desktop_sync::history_action,desktop_sync::finish_history_action,
            desktop_sync::open_preferences,desktop_sync::close_preferences,desktop_sync::read_preferences,platform_info,protect_interaction,drag_island,
            crate::integrations::integration_command,desktop_sync::preview_sound,desktop_sync::finish_sound_preview])
        .on_window_event(|window,event| {
            if window.label() == "main" && matches!(event,tauri::WindowEvent::Focused(false)) { let _=window.set_focusable(false); }
        })
        .setup(|app| {
            use tauri::{menu::{Menu,MenuItem},tray::TrayIconBuilder};
            let show=MenuItem::with_id(app,"show","显示 X Island",true,None::<&str>)?;
            let preferences=MenuItem::with_id(app,"preferences","设置…",true,None::<&str>)?;
            let quit=MenuItem::with_id(app,"quit","退出",true,None::<&str>)?;
            let menu=Menu::with_items(app,&[&show,&preferences,&quit])?;
            let mut tray=TrayIconBuilder::new().menu(&menu).tooltip("X Island").on_menu_event(|app,event| {
                match event.id.as_ref() { "show" => { if let Some(window)=app.get_webview_window("main") { let _=window.show(); } }, "preferences"=> { let _=desktop_sync::open_preferences(app.clone(),"general".into()); }, "quit"=>app.exit(0), _=>{} }
            });
            if let Some(icon)=app.default_window_icon() { tray=tray.icon(icon.clone()); }
            tray.build(app)?;
            let handle=app.handle().clone();
            if let (Ok(Some(settings)),Some(window))=(desktop_sync::read_preferences_file(),app.get_webview_window("main")) {
                if let Ok(mut controller)=app.state::<DesktopState>().window.lock() {
                    controller.configure(&window,settings["followPointer"].as_bool().unwrap_or(true),settings["hideInFullscreen"].as_bool().unwrap_or(false)).map_err(std::io::Error::other)?;
                }
            }
            let poll_handle=handle.clone();
            tauri::async_runtime::spawn(async move {
                let mut wait=std::time::Duration::from_millis(500);
                let mut last_error=String::new();
                loop {
                    tokio::time::sleep(wait).await;
                    // Wry 的显示器/位置 getter 会同步等待 UI 线程；不能在后台持有窗口锁再调用。
                    let (sender,receiver)=tokio::sync::oneshot::channel::<Option<Result<WindowReport,String>>>();
                    let task_handle=poll_handle.clone();
                    if poll_handle.run_on_main_thread(move || {
                        let Some(window)=task_handle.get_webview_window("main") else { let _=sender.send(None); return; };
                        let state=task_handle.state::<DesktopState>();
                        let result=state.window.lock().map_err(|_| "窗口状态不可用".to_string()).and_then(|mut controller|controller.poll(&window));
                        let _=sender.send(Some(result));
                    }).is_err() { break; }
                    let Ok(Some(result))=receiver.await else { break; };
                    match result {
                        Ok(report)=>{ wait=std::time::Duration::from_millis(if report.dragging {16} else {500}); last_error.clear(); }
                        Err(error)=>{ if error!=last_error { let _=poll_handle.emit_to("main","di-error",&error); last_error=error; } }
                    }
                }
            });
            let event_handle=handle.clone();
            let ended_handle=handle.clone();
            let on_event=Arc::new(move |event:EventEnvelope| {
                let state=event_handle.state::<DesktopState>();
                if let Ok(mut queue)=state.queue.lock() {
                    if queue.ready {
                        if event_handle.emit_to("main","di-message",&event).is_err() { queue.error=Some("事件投递失败，请重新打开客户端".into()); }
                    } else if queue.events.len()<512 { queue.events.push(event); }
                    else { queue.error=Some("启动事件队列已满，请重新连接 Agent".into()); }
                };
            });
            let on_end=Arc::new(move |request_id:String| {
                let state=ended_handle.state::<DesktopState>();
                if let Ok(mut queue)=state.queue.lock() {
                    if queue.ready { let _=ended_handle.emit_to("main","di-request-ended",request_id); }
                    else if queue.ended.len()<512 { queue.ended.push(request_id); }
                };
            });
            let bridge=handle.state::<DesktopState>().bridge.clone();
            tauri::async_runtime::spawn(async move {
                if let Err(error)=bridge.serve(on_event,on_end).await {
                    let message=format!("本地桥接启动失败：{error}");
                    if let Ok(mut queue)=handle.state::<DesktopState>().queue.lock() { queue.error=Some(message.clone()); }
                    let _=handle.emit("di-error",message);
                }
            });
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("XIsland 桌面运行时初始化失败")
        .run(|app,event| {
            if matches!(event,tauri::RunEvent::Exit) {
                let state=app.state::<DesktopState>();
                if let Ok(descriptor)=runtime::read_descriptor() {
                    if descriptor.token==state.bridge.descriptor.token {
                        if let Ok(root)=runtime::directory() { let _=std::fs::remove_file(root.join("runtime.json")); }
                    }
                }
                #[cfg(unix)]
                let _=std::fs::remove_file(&state.bridge.descriptor.endpoint);
            }
        });
}
