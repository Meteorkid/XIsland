use serde_json::Value;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TraeClient { IdeCn, WorkCn }

/// 只读应用公开元数据；名称相似或国际版不能据此认领国内版事件。
pub fn classify_product(product: &Value) -> Option<TraeClient> {
    if product["providerCode"] != "cn" || product["dataFolderName"] != ".trae-cn" { return None; }
    match (product["packageType"].as_str(), product["applicationName"].as_str(), product["win32AppUserModelId"].as_str()) {
        (Some("TRAE_CN"), Some("trae-cn"), Some("ByteDance.TraeCN")) => Some(TraeClient::IdeCn),
        (Some("SOLO_CN"), Some("trae-solo-cn"), Some("ByteDance.TraeSoloCN"))
            if product["nameAlias"] == "TraeWork CN" => Some(TraeClient::WorkCn),
        _ => None,
    }
}

fn observation_id(message: &Value) -> Option<&str> {
    if message["agentType"] != "trae"
        || message["nativeMessageReplay"] == true
        || !matches!(message["type"].as_str(), Some("session_start" | "status_update" | "tool_start" | "tool_complete"))
        || !matches!(message["nativeEvent"].as_str(), Some("SessionStart" | "UserPromptSubmit" | "PreToolUse" | "PostToolUse" | "Stop" | "Notification"))
        || ["parentSessionId", "subagentId", "sourceInstanceId", "sourceNamespace", "nativeRequestId"].iter().any(|key| message.get(key).is_some()) {
        return None;
    }
    message["sessionId"].as_str()?.strip_prefix("trae-").filter(|id| !id.is_empty())
}

/// 只给观察事件补充来源。无法识别时原样保留，不重写任何审批通道身份。
pub fn apply_origin(message: &mut Value, origin: Option<TraeClient>) {
    let (Some(origin), Some(native_id)) = (origin, observation_id(message)) else { return; };
    let (agent, terminal) = match origin {
        TraeClient::IdeCn => ("trae_ide_cn", "Trae CN"),
        TraeClient::WorkCn => ("traework_cn", "TraeWork CN"),
    };
    let session_id = format!("{agent}-{native_id}");
    message["sessionId"] = session_id.into();
    message["agentType"] = agent.into();
    message["terminal"] = terminal.into();
}

pub fn attribute_observation(message: &mut Value) {
    if observation_id(message).is_none() { return; }
    #[cfg(windows)]
    apply_origin(message, bounded_detection(windows::detect, std::time::Duration::from_millis(250)));
}

#[cfg(any(windows, test))]
fn bounded_detection(detector: impl FnOnce() -> Option<TraeClient> + Send + 'static, budget: std::time::Duration) -> Option<TraeClient> {
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    // 单事件 bridge 进程退出时由系统回收此线程；不等待可能阻塞的映射盘/重解析点读取。
    std::thread::Builder::new().name("client-origin".into()).spawn(move || { let _ = sender.send(detector()); }).ok()?;
    receiver.recv_timeout(budget).ok().flatten()
}

#[cfg(any(windows, test))]
fn ancestor_ids(start: u32, parents: &std::collections::HashMap<u32, u32>) -> Vec<u32> {
    let mut result = Vec::new();
    let mut current = start;
    while current != 0 && result.len() < 16 && !result.contains(&current) {
        result.push(current);
        let Some(parent) = parents.get(&current) else { break; };
        current = *parent;
    }
    result
}

#[cfg(windows)]
mod windows {
    use super::*;
    use std::{collections::HashMap, io::Read, os::windows::ffi::OsStringExt, path::{Component, Path, PathBuf, Prefix}, time::{Duration, Instant}};
    use windows_sys::Win32::{Foundation::{CloseHandle, FILETIME, HANDLE, INVALID_HANDLE_VALUE}, System::{
        Diagnostics::ToolHelp::{CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS},
        Threading::{GetProcessTimes, OpenProcess, QueryFullProcessImageNameW, PROCESS_QUERY_LIMITED_INFORMATION},
    }};

    struct Handle(HANDLE);
    impl Drop for Handle { fn drop(&mut self) { unsafe { CloseHandle(self.0); } } }

    fn parents() -> Option<HashMap<u32, u32>> {
        let raw = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) };
        if raw == INVALID_HANDLE_VALUE { return None; }
        let snapshot = Handle(raw);
        let mut entry: PROCESSENTRY32W = unsafe { std::mem::zeroed() };
        entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
        let mut map = HashMap::new();
        let mut available = unsafe { Process32FirstW(snapshot.0, &mut entry) };
        while available != 0 {
            if map.len() >= 65536 { return None; }
            map.insert(entry.th32ProcessID, entry.th32ParentProcessID);
            available = unsafe { Process32NextW(snapshot.0, &mut entry) };
        }
        Some(map)
    }

    fn image_and_creation(pid: u32) -> Option<(PathBuf, u64)> {
        let raw = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
        if raw.is_null() { return None; }
        let process = Handle(raw);
        let (mut created, mut exited, mut kernel, mut user): (FILETIME, FILETIME, FILETIME, FILETIME) = unsafe { std::mem::zeroed() };
        if unsafe { GetProcessTimes(process.0, &mut created, &mut exited, &mut kernel, &mut user) } == 0 { return None; }
        let mut buffer = vec![0u16; 32768]; let mut length = buffer.len() as u32;
        if unsafe { QueryFullProcessImageNameW(process.0, 0, buffer.as_mut_ptr(), &mut length) } == 0 { return None; }
        let path = PathBuf::from(std::ffi::OsString::from_wide(&buffer[..length as usize]));
        Some((path, ((created.dwHighDateTime as u64) << 32) | created.dwLowDateTime as u64))
    }

    fn product_for_executable(executable: &Path) -> Option<TraeClient> {
        // 不从网络共享或用户配置读取产品信息，避免观察 hook 等待远程文件系统。
        if !matches!(executable.components().next(), Some(Component::Prefix(prefix))
            if matches!(prefix.kind(), Prefix::Disk(_) | Prefix::VerbatimDisk(_))) { return None; }
        let file = executable.parent()?.join("resources").join("app").join("product.json");
        let metadata = std::fs::symlink_metadata(&file).ok()?;
        const MAX_PRODUCT_BYTES: u64 = 256 * 1024;
        if !metadata.is_file() || metadata.len() > MAX_PRODUCT_BYTES { return None; }
        let mut bytes = Vec::new();
        std::fs::File::open(file).ok()?.take(MAX_PRODUCT_BYTES + 1).read_to_end(&mut bytes).ok()?;
        if bytes.len() as u64 > MAX_PRODUCT_BYTES { return None; }
        classify_product(&serde_json::from_slice(&bytes).ok()?)
    }

    pub(super) fn detect() -> Option<TraeClient> {
        let started = Instant::now();
        let chain = ancestor_ids(std::process::id(), &parents()?);
        let mut child_created = u64::MAX;
        for pid in chain {
            if started.elapsed() > Duration::from_millis(250) { break; }
            let (path, created) = image_and_creation(pid)?;
            // 父 PID 可能已被复用；新于子进程的“父进程”不可用于来源判断。
            if created > child_created { break; }
            child_created = created;
            if let Some(origin) = product_for_executable(&path) { return Some(origin); }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn distinguishes_domestic_products_and_rejects_similar_names() {
        let ide = json!({"providerCode":"cn","dataFolderName":".trae-cn","packageType":"TRAE_CN","applicationName":"trae-cn","win32AppUserModelId":"ByteDance.TraeCN"});
        // 官方 Windows 0.2.2 安装包 product.json 的身份字段摘录，完整资源摘要单独存档。
        let work: Value = serde_json::from_str(include_str!("../tests/fixtures/traework-cn-0.2.2-product.json")).unwrap();
        assert_eq!(classify_product(&ide), Some(TraeClient::IdeCn));
        assert_eq!(classify_product(&work), Some(TraeClient::WorkCn));
        for field in ["providerCode", "dataFolderName", "packageType", "applicationName", "win32AppUserModelId", "nameAlias"] {
            let mut changed = work.clone(); changed[field] = "unknown".into();
            assert_eq!(classify_product(&changed), None, "{field}");
        }
        assert_eq!(classify_product(&json!({"nameAlias":"TraeWork CN"})), None);
    }

    #[test]
    fn same_native_session_id_is_separated_by_known_product() {
        let base = json!({"agentType":"trae","sessionId":"trae-same","type":"tool_complete","nativeEvent":"PostToolUse","toolCallId":"call"});
        let mut ide = base.clone(); apply_origin(&mut ide, Some(TraeClient::IdeCn));
        let mut work = base.clone(); apply_origin(&mut work, Some(TraeClient::WorkCn));
        assert_eq!(ide["sessionId"], "trae_ide_cn-same"); assert_eq!(work["sessionId"], "traework_cn-same");
        assert_eq!(work["agentType"], "traework_cn"); assert_eq!(work["terminal"], "TraeWork CN");
        assert_eq!(work["toolCallId"], "call");
        let mut unknown = base.clone(); apply_origin(&mut unknown, None); assert_eq!(unknown, base);
    }

    #[test]
    fn never_rewrites_interactions_foreign_agents_or_unrecognized_observations() {
        let base = json!({"agentType":"trae","sessionId":"trae-same","type":"status_update","nativeEvent":"Notification"});
        for (field, value) in [("type","permission_request"),("type","question"),("agentType","workbuddy"),
            ("sessionId","other-same"),("sessionId","trae-"),("nativeEvent","unknown"),("sourceInstanceId","instance"),
            ("nativeRequestId","approval"),("parentSessionId","parent")] {
            let mut message = base.clone(); message[field] = value.into(); let original = message.clone();
            apply_origin(&mut message, Some(TraeClient::WorkCn)); assert_eq!(message, original);
        }
        let mut replay = base; replay["nativeMessageReplay"] = true.into(); let original = replay.clone();
        apply_origin(&mut replay, Some(TraeClient::WorkCn)); assert_eq!(replay, original);
    }

    #[test]
    fn ancestor_walk_is_bounded_and_stops_at_cycles_or_missing_processes() {
        use std::collections::HashMap;
        assert_eq!(ancestor_ids(5, &HashMap::from([(5,4),(4,3),(3,4)])), [5,4,3]);
        assert_eq!(ancestor_ids(5, &HashMap::new()), [5]);
        assert!(ancestor_ids(0, &HashMap::new()).is_empty());
        assert_eq!(ancestor_ids(100, &(1..=100).map(|pid| (pid,pid-1)).collect()).len(), 16);
    }

    #[test]
    fn stalled_detection_returns_unknown_without_waiting_for_worker_completion() {
        use std::{sync::mpsc, time::Duration};
        let (release, blocked) = mpsc::channel();
        let detected = bounded_detection(move || { let _ = blocked.recv(); Some(TraeClient::WorkCn) }, Duration::from_millis(10));
        assert_eq!(detected, None);
        release.send(()).unwrap();
        assert_eq!(bounded_detection(|| Some(TraeClient::IdeCn), Duration::from_secs(1)), Some(TraeClient::IdeCn));
    }
}
