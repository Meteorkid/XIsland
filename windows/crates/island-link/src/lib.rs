//! 两个固定浮岛的当前用户本地协调。锁由内核释放；确认必须晚于原生显示成功。
use serde::{Deserialize, Serialize};
use std::{fs::{self, File, OpenOptions}, path::{Path, PathBuf}, process::Command,
    sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}}, thread, time::{Duration, Instant, SystemTime, UNIX_EPOCH}};
use uuid::Uuid;
mod preferences;
pub use preferences::{IntegrationPreferences, StartupDisplay, SwitchSensitivity};
use preferences::PreferenceRecord;

pub const PROTOCOL_VERSION: u32 = 1;
const POLL: Duration = Duration::from_millis(40);

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Identity { XNook, XIsland }
impl Identity {
    pub fn peer(self) -> Self { match self { Self::XNook => Self::XIsland, Self::XIsland => Self::XNook } }
    fn name(self) -> &'static str { match self { Self::XNook => "xnook", Self::XIsland => "xisland" } }
}

#[derive(Clone, Debug, Serialize)]
pub struct PeerStatus { pub installed: bool, pub running: bool, pub compatible: bool, pub detail: String }

pub type WindowAction = Arc<dyn Fn() -> Result<(), String> + Send + Sync>;
#[derive(Clone)]
pub struct Callbacks { pub show: WindowAction, pub hide: WindowAction, pub on_error: Arc<dyn Fn(String) + Send + Sync> }

#[derive(Clone, Serialize, Deserialize)]
struct Registration { protocol: u32, identity: Identity, executable: PathBuf, instance: String }
#[derive(Clone, Serialize, Deserialize)]
struct Request { id: String, source: Identity, target: Identity, deadline: u64, ready: bool, target_instance: Option<String> }
#[derive(Clone, Serialize, Deserialize)]
struct Acknowledgement { id: String, target: Identity, error: Option<String> }
#[derive(Serialize, Deserialize)]
struct State { protocol: u32, owner: Option<Identity>, request: Option<Request>, acknowledgement: Option<Acknowledgement> }
impl Default for State { fn default() -> Self { Self { protocol: PROTOCOL_VERSION, owner: None, request: None, acknowledgement: None } } }

pub struct Link {
    root: PathBuf, identity: Identity, instance: String, _running: File, _instance_running: File,
    owns: AtomicBool, stopped: AtomicBool, started: AtomicBool, callbacks: Mutex<Option<Callbacks>>,
    startup_pending: AtomicBool, previous_owner: Mutex<Option<Identity>>,
}

impl Link {
    pub fn open(identity: Identity) -> Result<Arc<Self>, String> { Self::open_at(default_directory()?, identity) }

    /// 测试使用独立目录；生产宿主必须使用 open，不能接受前端提供的目录或可执行路径。
    pub fn open_at(root: PathBuf, identity: Identity) -> Result<Arc<Self>, String> {
        if !root.is_absolute() { return Err("联动目录必须为绝对路径".into()); }
        fs::create_dir_all(&root).map_err(io_error)?;
        if fs::symlink_metadata(&root).map_err(io_error)?.file_type().is_symlink() { return Err("联动目录不能是符号链接".into()); }
        #[cfg(unix)] { use std::os::unix::fs::PermissionsExt; fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).map_err(io_error)?; }
        let executable = std::env::current_exe().map_err(io_error)?.canonicalize().map_err(io_error)?;
        validate_executable(identity, &executable)?;
        let running = open_lock(&root.join(format!("{}.running",identity.name())))?;
        running.try_lock().map_err(|_| "当前应用已有联动实例".to_string())?;
        let instance = Uuid::new_v4().to_string();
        let instance_running = open_lock(&root.join(format!("{}.{}.lease",identity.name(),instance)))?;
        instance_running.try_lock().map_err(|error|format!("实例租约失败：{error}"))?;
        let link = Arc::new(Self { root, identity, instance, _running: running, _instance_running: instance_running, owns: AtomicBool::new(false), stopped: AtomicBool::new(false), started: AtomicBool::new(false), callbacks: Mutex::new(None), startup_pending: AtomicBool::new(false), previous_owner: Mutex::new(None) });
        let _guard = link.lock(Duration::from_secs(3))?;
        write_json(&link.registration_path(identity), &Registration { protocol: PROTOCOL_VERSION, identity, executable, instance: link.instance.clone() })?;
        // 启动时窗口仍隐藏；只在 show 回调真正成功后记录 owner。
        let mut state = link.read_state()?;
        *link.previous_owner.lock().map_err(|_| "启动状态不可用")? = state.owner;
        // 成功取得本身份实例锁，说明同名旧进程已退出；旧 owner/ready 不能继承到新进程。
        let mut changed = false;
        if state.owner == Some(identity) { state.owner = None; changed = true; }
        if state.request.as_ref().is_some_and(|r|r.source == identity || (r.target == identity && r.ready)) {
            let request = state.request.take().unwrap();
            state.acknowledgement = Some(Acknowledgement { id: request.id, target: request.target, error: Some("参与切换的应用已重启，请重试".into()) });
            changed = true;
        }
        if changed { link.write_state(&state)?; }
        Ok(link)
    }

    pub fn start(self: &Arc<Self>, callbacks: Callbacks) -> Result<(), String> {
        if self.started.swap(true, Ordering::SeqCst) { return Err("联动监听已经启动".into()); }
        *self.callbacks.lock().map_err(|_| "联动回调不可用")? = Some(callbacks.clone());
        let startup_target = match self.startup_target() {
            Ok(target) => target,
            Err(error) => { (callbacks.on_error)(error); None }
        };
        self.startup_pending.store(startup_target.is_some(), Ordering::SeqCst);
        let startup_callbacks = callbacks.clone();
        let link = self.clone();
        thread::Builder::new().name("island-link".into()).spawn(move || {
            let mut last_error = String::new();
            while !link.stopped.load(Ordering::SeqCst) {
                match link.tick(&callbacks) {
                    Ok(()) => last_error.clear(),
                    Err(error) => { if error != last_error { (callbacks.on_error)(error.clone()); last_error = error; } }
                }
                thread::sleep(POLL);
            }
        }).map_err(io_error)?;
        if let Some(target) = startup_target {
            let link = self.clone();
            if let Err(error) = thread::Builder::new().name("island-startup".into()).spawn(move || {
                let result = link.transfer(target, Duration::from_secs(8), false, true);
                let still_pending = link.startup_pending.swap(false, Ordering::SeqCst);
                if still_pending { if let Err(error) = result { (startup_callbacks.on_error)(format!("首选应用未能显示，已回到当前应用：{error}")); } }
            }) {
                self.startup_pending.store(false, Ordering::SeqCst);
                return Err(io_error(error));
            }
        }
        Ok(())
    }

    pub fn preferences(&self) -> Result<IntegrationPreferences, String> {
        let _guard = self.lock(Duration::from_secs(2))?;
        Ok(self.read_preferences()?.preferences)
    }

    pub fn set_preferences(&self, preferences: IntegrationPreferences) -> Result<IntegrationPreferences, String> {
        let _guard = self.lock(Duration::from_secs(2))?;
        let mut record = self.read_preferences()?;
        record.preferences = preferences.clone();
        write_json(&self.root.join("preferences.json"), &record)?;
        Ok(preferences)
    }

    fn read_preferences(&self) -> Result<PreferenceRecord, String> {
        Ok(read_json(&self.root.join("preferences.json"))?.unwrap_or_default())
    }

    fn startup_target(&self) -> Result<Option<Identity>, String> {
        let _guard = self.lock(Duration::from_secs(2))?;
        let state = self.read_state()?;
        if state.request.as_ref().is_some_and(|request| request.deadline > now()) || state.owner.is_some_and(|owner| self.is_running(owner).unwrap_or(true)) { return Ok(None); }
        let previous = *self.previous_owner.lock().map_err(|_| "启动状态不可用")?;
        let preferred = self.read_preferences()?.preferred(previous, self.identity);
        Ok((preferred != self.identity).then_some(preferred))
    }

    pub fn owns_display(&self) -> bool { self.owns.load(Ordering::SeqCst) && !self.stopped.load(Ordering::SeqCst) }
    pub fn shutdown(&self) { self.stopped.store(true, Ordering::SeqCst); self.owns.store(false, Ordering::SeqCst); }

    pub fn peer_status(&self) -> Result<PeerStatus, String> {
        let peer = self.identity.peer();
        let registration = self.registration(peer)?;
        let running = self.is_running(peer)?;
        let Some(registration) = registration else { return Ok(PeerStatus { installed: false, running, compatible: false, detail: "请先启动新版对方应用一次，登记本机安装位置（XNook 0.1.0 / XIsland 0.1.4 起）".into() }); };
        let installed = validate_executable(peer, &registration.executable).is_ok();
        let compatible = registration.protocol == PROTOCOL_VERSION && registration.identity == peer;
        Ok(PeerStatus { installed, running, compatible, detail: if !compatible { "对方联动协议版本不兼容，请更新两个应用" } else if !installed { "已登记的对方程序不存在，请重新安装并启动一次" } else if running { "对方正在运行，可切换" } else { "切换时将启动对方" }.into() })
    }

    pub fn switch_to_peer(&self, timeout: Duration) -> Result<(), String> { self.transfer(self.identity.peer(), timeout, true, false) }
    pub fn request_show(&self, timeout: Duration) -> Result<(), String> {
        let until = Instant::now() + timeout;
        loop {
            if Instant::now() >= until { return Err("显式显示等待超时，请重试".into()); }
            let was_startup = self.startup_pending.load(Ordering::SeqCst);
            let result = self.transfer(self.identity, until.saturating_duration_since(Instant::now()), false, false);
            // 目标已经 ready 时先让该事务收口，再优先执行用户的显式显示。
            if was_startup && result.as_ref().err().is_some_and(|error| error == "已有切换正在进行，请稍后重试") { thread::sleep(POLL); continue; }
            return result;
        }
    }

    fn transfer(&self, target: Identity, timeout: Duration, require_owner: bool, startup: bool) -> Result<(), String> {
        if !self.started.load(Ordering::SeqCst) || self.stopped.load(Ordering::SeqCst) { return Err("联动服务尚未就绪".into()); }
        let timeout = timeout.clamp(Duration::from_millis(100), Duration::from_secs(15));
        let until = Instant::now() + timeout;
        let id = Uuid::new_v4().to_string();
        {
            let _guard = self.lock(timeout)?;
            let mut state = self.read_state()?;
            if startup && !self.startup_pending.load(Ordering::SeqCst) { return Err("启动偏好已由显式显示取消".into()); }
            // 崩溃或正常退出都会留下最后 owner；冷启动不能把它当成仍在显示。
            if let Some(owner) = state.owner { if !self.is_running(owner)? { state.owner = None; } }
            if !startup && target == self.identity && self.startup_pending.load(Ordering::SeqCst)
                && state.request.as_ref().is_none_or(|request| request.source == self.identity && request.target == self.identity.peer() && !request.ready) {
                state.request = None;
                state.acknowledgement = None;
                self.write_state(&state)?;
                self.startup_pending.store(false, Ordering::SeqCst);
            }
            if state.request.as_ref().is_some_and(|r|r.deadline > now()) { return Err("已有切换正在进行，请稍后重试".into()); }
            if require_owner && state.owner != Some(self.identity) { return Err("当前窗口已让位，不能重复切换".into()); }
            if target == self.identity && state.owner.is_none() {
                let callbacks = self.callbacks.lock().map_err(|_| "联动回调不可用")?.clone().ok_or("联动服务尚未就绪")?;
                self.owns.store(true, Ordering::SeqCst);
                if let Err(error) = (callbacks.show)() { self.owns.store(false, Ordering::SeqCst); (callbacks.hide)()?; return Err(error); }
                state.owner = Some(self.identity);
                if let Err(error) = self.write_state(&state) { self.owns.store(false, Ordering::SeqCst); (callbacks.hide)()?; return Err(error); }
                return Ok(());
            }
            if state.owner == Some(target) {
                drop(_guard);
                if target == self.identity {
                    let callbacks = self.callbacks.lock().map_err(|_| "联动回调不可用")?.clone().ok_or("联动服务尚未就绪")?;
                    // 该操作也必须受全局锁保护，防止同时发生的让位被旧 show 撤销。
                    let _guard = self.lock(until.saturating_duration_since(Instant::now()))?;
                    if self.read_state()?.owner != Some(target) { return Err("显示权刚刚变化，请重试".into()); }
                    self.owns.store(true, Ordering::SeqCst);
                    return (callbacks.show)();
                }
                return Err("对方已经持有显示权".into());
            }
            if target != self.identity {
                let status = self.peer_status()?;
                if !status.installed || !status.compatible { return Err(status.detail); }
                if !status.running {
                    let registration = self.registration(target)?.ok_or("对方尚未登记")?;
                    validate_executable(target, &registration.executable)?;
                    // 仅执行固定身份自行登记的绝对路径，不接收命令、URL、参数或外部路径。
                    Command::new(&registration.executable).spawn().map_err(|e|format!("无法启动对方：{e}"))?;
                }
            }
            let source = state.owner.unwrap_or(target.peer());
            state.request = Some(Request { id: id.clone(), source, target, deadline: now() + until.saturating_duration_since(Instant::now()).as_millis() as u64, ready: false, target_instance: None });
            state.acknowledgement = None;
            self.write_state(&state)?;
        }
        loop {
            if startup && !self.startup_pending.load(Ordering::SeqCst) { return Err("启动偏好已由显式显示取消".into()); }
            if Instant::now() >= until { return Err("切换超时，当前窗口保留；请检查对方是否能正常启动".into()); }
            let _guard = self.lock(until.saturating_duration_since(Instant::now()))?;
            let state = match self.read_state() {
                Ok(state) => state,
                // 暂时的落盘故障不提前退出仍在执行的请求；等待原截止时间，防止迟到提交。
                Err(_) => { drop(_guard); thread::sleep(POLL); continue; }
            };
            if let Some(ack) = state.acknowledgement.as_ref().filter(|ack|ack.id == id && ack.target == target) {
                if let Some(error) = &ack.error { return Err(error.clone()); }
                if state.owner != Some(target) { return Err("显示权已被后续操作变更，请重试".into()); }
                return Ok(());
            }
            drop(_guard);
            thread::sleep(POLL);
        }
    }

    fn tick(&self, callbacks: &Callbacks) -> Result<(), String> {
        let _guard = self.lock(Duration::from_millis(250))?;
        if self.stopped.load(Ordering::SeqCst) { return Ok(()); }
        let mut state = self.read_state()?;
        if let Some(request) = state.request.clone() {
            if request.deadline <= now() {
                state.request = None;
                state.acknowledgement = Some(Acknowledgement { id: request.id, target: request.target, error: Some("切换超时，未改变显示权".into()) });
                self.write_state(&state)?;
            } else if !request.ready && request.target == self.identity {
                self.owns.store(true, Ordering::SeqCst);
                let mut result = (callbacks.show)();
                if result.is_ok() && now() >= request.deadline { result = Err("对方显示确认已超时，保留原窗口".into()); }
                if result.is_ok() && state.owner.is_some() && state.owner != Some(request.source) { result = Err("原窗口显示权已变化".into()); }
                if result.is_ok() { let pending = state.request.as_mut().unwrap(); pending.ready = true; pending.target_instance = Some(self.instance.clone()); }
                else {
                    self.owns.store(false, Ordering::SeqCst); (callbacks.hide)()?;
                    state.request = None;
                    state.acknowledgement = Some(Acknowledgement { id: request.id, target: self.identity, error: result.err() });
                }
                if let Err(error) = self.write_state(&state) {
                    self.owns.store(false, Ordering::SeqCst); (callbacks.hide)()?; return Err(error);
                }
            } else if request.ready && (request.source == self.identity || !self.is_running(request.source)?) {
                // 对方已经显示。源窗口成功隐藏后才提交最终 ACK；失败仍保留原 owner。
                let mut result = self.target_is_ready(&request).and_then(|ready| {
                    if ready { Ok(()) } else { Err("对方在切换完成前退出，保留原窗口".into()) }
                });
                if request.source == self.identity && result.is_ok() {
                    self.owns.store(false, Ordering::SeqCst);
                    result = (callbacks.hide)();
                    if result.is_ok() && now() >= request.deadline { result = Err("隐藏原窗口超时，已恢复原窗口".into()); }
                    if result.is_ok() {
                        // 隐藏后任何确认错误都必须进入恢复分支，不能用 ? 跳过回滚。
                        result = self.target_is_ready(&request).and_then(|ready| {
                            if ready { Ok(()) } else { Err("对方在切换完成前退出，已恢复原窗口".into()) }
                        });
                    }
                }
                if result.is_ok() { state.owner = Some(request.target); }
                else if request.source == self.identity { self.owns.store(true, Ordering::SeqCst); (callbacks.show)()?; }
                state.request = None;
                state.acknowledgement = Some(Acknowledgement { id: request.id, target: request.target, error: result.err() });
                if let Err(error) = self.write_state(&state) {
                    if request.source == self.identity { self.owns.store(true, Ordering::SeqCst); (callbacks.show)()?; }
                    return Err(error);
                }
            }
        }
        // 进程退出后由唯一存活者接位；同启使用同一内核锁，不会各自判定空位。
        if !self.startup_pending.load(Ordering::SeqCst) && state.request.is_none() && (state.owner.is_none() || state.owner.is_some_and(|owner| !self.is_running(owner).unwrap_or(true))) {
            self.owns.store(true, Ordering::SeqCst);
            match (callbacks.show)() {
                Ok(()) => { state.owner = Some(self.identity); if let Err(error)=self.write_state(&state) {self.owns.store(false, Ordering::SeqCst); (callbacks.hide)()?; return Err(error)} }
                Err(error) => { self.owns.store(false, Ordering::SeqCst); (callbacks.hide)()?; return Err(error); }
            }
        }
        let waiting_for_source_hide = state.request.as_ref().is_some_and(|r|r.ready && r.target == self.identity && r.deadline > now());
        if state.owner != Some(self.identity) && !waiting_for_source_hide && self.owns.swap(false, Ordering::SeqCst) { (callbacks.hide)()?; }
        Ok(())
    }

    fn target_is_ready(&self, request: &Request) -> Result<bool, String> {
        let Some(instance) = request.target_instance.as_deref() else { return Ok(false); };
        if Uuid::parse_str(instance).is_err() { return Err("无效联动实例标识".into()); }
        // 身份锁可能已被快速重启的新进程取得，必须检查 ready 对应实例自己的内核租约。
        let path = self.root.join(format!("{}.{}.lease",request.target.name(),instance));
        let file = match OpenOptions::new().read(true).write(true).open(path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
            Err(error) => return Err(io_error(error)),
        };
        match file.try_lock() { Ok(()) => Ok(false), Err(std::fs::TryLockError::WouldBlock) => Ok(true), Err(error) => Err(format!("无法检查目标实例：{error}")) }
    }

    fn registration_path(&self, identity: Identity) -> PathBuf { self.root.join(format!("{}.json", identity.name())) }
    fn registration(&self, identity: Identity) -> Result<Option<Registration>, String> { read_json(&self.registration_path(identity)) }
    fn is_running(&self, identity: Identity) -> Result<bool, String> {
        if identity == self.identity { return Ok(!self.stopped.load(Ordering::SeqCst)); }
        let file = open_lock(&self.root.join(format!("{}.running", identity.name())))?;
        match file.try_lock() { Ok(()) => Ok(false), Err(std::fs::TryLockError::WouldBlock) => Ok(true), Err(error) => Err(format!("无法检查对方运行状态：{error}")) }
    }
    fn lock(&self, timeout: Duration) -> Result<File, String> {
        let file = open_lock(&self.root.join("coordinator.lock"))?;
        let until = Instant::now() + timeout;
        loop {
            match file.try_lock() { Ok(()) => return Ok(file), Err(std::fs::TryLockError::WouldBlock) => {}, Err(error) => return Err(format!("联动锁失败：{error}")) }
            if Instant::now() >= until { return Err("联动正在处理其他请求，请稍后重试".into()); }
            thread::sleep(Duration::from_millis(10));
        }
    }
    fn read_state(&self) -> Result<State, String> {
        let state: State = read_json(&self.root.join("state.json"))?.unwrap_or_default();
        if state.protocol != PROTOCOL_VERSION { return Err("联动状态协议不兼容，请更新两个应用".into()); }
        Ok(state)
    }
    fn write_state(&self, state: &State) -> Result<(), String> {
        write_json(&self.root.join("state.json"), state)?;
        if let Some(owner) = state.owner {
            let remembered = (|| {
                let mut record = self.read_preferences()?;
                if record.last_shown != Some(owner) {
                    record.last_shown = Some(owner);
                    write_json(&self.root.join("preferences.json"), &record)?;
                }
                Ok::<(), String>(())
            })();
            // 偏好落盘失败不能撤销已成功的窗口交接；保留原件并单独报告。
            if let Err(error) = remembered {
                if let Ok(callbacks) = self.callbacks.lock() { if let Some(callbacks) = callbacks.as_ref() { (callbacks.on_error)(error); } }
            }
        }
        Ok(())
    }
}

fn default_directory() -> Result<PathBuf, String> {
    #[cfg(windows)] { std::env::var_os("LOCALAPPDATA").map(PathBuf::from).filter(|p|p.is_absolute()).map(|p|p.join("Islands").join("link-v1")).ok_or("缺少当前用户 LOCALAPPDATA".into()) }
    #[cfg(not(windows))] { Err("双应用联动仅在 Windows 客户端启用".into()) }
}
fn validate_executable(identity: Identity, path: &Path) -> Result<(), String> {
    let expected = if cfg!(windows) { format!("{}.exe",identity.name()) } else { identity.name().into() };
    if !path.is_absolute() || path.file_name().and_then(|v|v.to_str()).is_none_or(|v|!v.eq_ignore_ascii_case(&expected)) || !path.is_file() { return Err("对方程序路径无效，请启动正式客户端重新登记".into()); }
    Ok(())
}
fn open_lock(path: &Path) -> Result<File, String> {
    if fs::symlink_metadata(path).is_ok_and(|m|m.file_type().is_symlink()) { return Err("联动锁不能是符号链接".into()); }
    OpenOptions::new().read(true).write(true).create(true).truncate(false).open(path).map_err(io_error)
}
fn read_json<T: for<'de> Deserialize<'de>>(path: &Path) -> Result<Option<T>, String> {
    match fs::read(path) {
        Ok(data) => { if data.len() > 64 * 1024 { return Err("联动记录过大".into()); } serde_json::from_slice(&data).map(Some).map_err(|e|format!("联动记录损坏：{e}")) },
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(io_error(error)),
    }
}
fn write_json(path: &Path, value: &impl Serialize) -> Result<(), String> {
    let temp = path.with_extension(format!("{}.tmp", Uuid::new_v4()));
    let bytes = serde_json::to_vec(value).map_err(|e|e.to_string())?;
    fs::write(&temp, bytes).map_err(io_error)?;
    let result = fs::rename(&temp, path).map_err(io_error);
    if result.is_err() { let _ = fs::remove_file(temp); }
    result
}
fn now() -> u64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis().min(u64::MAX as u128) as u64 }
fn io_error(error: std::io::Error) -> String { error.to_string() }
