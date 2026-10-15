use serde_json::{json, Value};
use tauri::AppHandle;

#[cfg(windows)]
use {
    std::{collections::HashSet, path::{Path, PathBuf}, process::{ExitStatus, Stdio}, time::Duration},
    tauri::Manager,
    tokio::{io::AsyncReadExt, process::Command, time::timeout},
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Action { Status, Plan, Apply, Export }

#[derive(Debug)]
struct Request {
    agent: String,
    action: Action,
    #[cfg_attr(not(windows), allow(dead_code))]
    operation: String,
    #[cfg_attr(not(windows), allow(dead_code))]
    revision: Option<String>,
}

fn valid_revision(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn validate_request(agent: String, action: String, operation: Option<String>, revision: Option<String>) -> Result<Request, String> {
    if agent == "workbuddy" {
        if action != "export" || operation.is_some() || revision.is_some() {
            return Err("WorkBuddy 仅支持导出观察插件；安装与启用请在原客户端完成。".into());
        }
        return Ok(Request { agent, action: Action::Export, operation: "export".into(), revision: None });
    }
    if !["claude_code", "codex", "cursor", "gemini_cli", "windsurf", "trae_cn"].contains(&agent.as_str()) {
        return Err("不支持的客户端；目前可配置 Claude、Codex、Cursor、Gemini CLI、Windsurf 和 Trae CN。".into());
    }
    let action = match action.as_str() {
        "status" => Action::Status,
        "plan" => Action::Plan,
        "apply" => Action::Apply,
        _ => return Err("未知接入操作。".into()),
    };
    let operation = operation.unwrap_or_else(|| "install".into());
    if !["install", "uninstall"].contains(&operation.as_str()) { return Err("仅支持安装或卸载接入。".into()); }
    if action == Action::Apply {
        if !revision.as_deref().is_some_and(valid_revision) {
            return Err("确认写入前必须提供有效的配置版本，请重新查看计划。".into());
        }
    } else if revision.is_some() { return Err("只有确认写入操作可以携带配置版本。".into()); }
    Ok(Request { agent, action, operation, revision })
}

#[cfg(any(windows, test))]
fn cli_arguments(request: &Request) -> Vec<String> {
    let flag = match request.action { Action::Status => "--integration-status", Action::Plan => "--integration-plan", Action::Apply => "--integration-apply", Action::Export => "--workbuddy-export" };
    let mut arguments = vec![flag.into(), "--agent".into(), request.agent.clone()];
    if matches!(request.action, Action::Plan | Action::Apply) {
        arguments.extend(["--operation".into(), request.operation.clone()]);
    }
    if let Some(revision) = &request.revision { arguments.extend(["--expected-revision".into(), revision.clone()]); }
    arguments
}

#[cfg(any(windows, test))]
fn supported_node_version(bytes: &[u8]) -> Option<String> {
    let version = std::str::from_utf8(bytes).ok()?.trim();
    let parts: Vec<&str> = version.strip_prefix('v')?.split('.').collect();
    if parts.len() != 3 || !parts.iter().all(|part| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit())) { return None; }
    if parts[0].parse::<u32>().ok()? < 20 { return None; }
    Some(version.into())
}

#[cfg(any(windows, test))]
fn service_error(value: &Value) -> String {
    // 不转印进程 stderr 或任意 JSON 字符串，避免配置正文出现在应用错误提示中。
    match value["error"]["code"].as_str() {
        Some("revision_conflict") => "配置已被其他程序修改，请重新查看计划后确认。",
        Some("revision_required") => "缺少已确认计划的版本，未写入配置。",
        Some("invalid_json") => "现有配置不是有效 UTF-8 JSON，已保留原文件。",
        Some("config_too_large") => "配置超过 1 MiB 安全上限，未写入。",
        Some("runtime_missing") => "Node、hook 或 bridge 资源缺失，无法安装接入。",
        Some("installation_busy") => "另一个安装操作持有配置锁，请稍后重试。",
        Some("unsafe_path") | Some("invalid_backup") => "配置路径或备份引用不安全，操作已停止。",
        Some("unsupported_platform") => "接入安装仅在 Windows 客户端执行。",
        _ => "接入服务未完成操作；请刷新状态后重试。",
    }.into()
}

#[cfg(any(windows, test))]
fn validate_summary(value: Value, request: &Request) -> Result<Value, String> {
    if value.get("error").is_some() { return Err(service_error(&value)); }
    let summary = value.as_object().ok_or("接入服务没有返回有效摘要。")?;
    if request.action == Action::Export {
        const EXPORT_FIELDS: &[&str] = &["agent", "exportedPath", "eventCount", "observationOnly", "clientVerified", "runtimeReady"];
        if summary.len() != EXPORT_FIELDS.len() || summary.keys().any(|key| !EXPORT_FIELDS.contains(&key.as_str()))
            || value["agent"] != "workbuddy" || value["eventCount"] != 11
            || value["observationOnly"] != true || value["clientVerified"] != false || value["runtimeReady"] != true
            || value["exportedPath"].as_str().is_none_or(|path| path.is_empty() || path.len() > 4096 || path.contains('\0')) {
            return Err("WorkBuddy 插件导出摘要无效。".into());
        }
        return Ok(value);
    }
    const ALLOWED: &[&str] = &["agent", "operation", "configPath", "changed", "addedHandlers", "removedHandlers", "backup", "warnings", "sources", "revision", "runtimeReady", "applied", "backupId", "platformSupported", "installed", "managedHandlers"];
    if summary.keys().any(|key| !ALLOWED.contains(&key.as_str())) || value["agent"].as_str() != Some(request.agent.as_str()) {
        return Err("接入服务返回了不匹配的摘要。".into());
    }
    if let Some(operation) = summary.get("operation") {
        if operation.as_str() != Some(request.operation.as_str()) { return Err("接入服务返回了不同操作的摘要。".into()); }
    }
    if !value["runtimeReady"].is_boolean() { return Err("接入摘要缺少运行时状态。".into()); }
    if request.action != Action::Status && !value["revision"].as_str().is_some_and(valid_revision) {
        return Err("接入摘要缺少有效配置版本。".into());
    }
    for key in ["changed", "applied", "platformSupported", "installed"] {
        if summary.get(key).is_some_and(|field| !field.is_boolean()) { return Err("接入摘要状态字段无效。".into()); }
    }
    for key in ["addedHandlers", "removedHandlers", "managedHandlers"] {
        if summary.get(key).is_some_and(|field| field.as_u64().is_none()) { return Err("接入摘要计数无效。".into()); }
    }
    for key in ["configPath", "backupId", "revision"] {
        if summary.get(key).is_some_and(|field| field.as_str().is_none_or(|text| text.len() > 4096 || text.contains('\0'))) {
            return Err("接入摘要文本字段无效。".into());
        }
    }
    for key in ["warnings", "sources"] {
        if let Some(field) = summary.get(key) {
            let list = field.as_array().ok_or("接入摘要列表无效。")?;
            if list.len() > 16 || list.iter().any(|entry| entry.as_str().is_none_or(|text| text.len() > 2048 || text.contains('\0'))) {
                return Err("接入摘要列表过大或无效。".into());
            }
        }
    }
    if let Some(field) = summary.get("backup") {
        let backup = field.as_object().ok_or("备份摘要无效。")?;
        if backup.keys().any(|key| !["required", "directory", "filenamePrefix", "exclusive"].contains(&key.as_str()))
            || !field["required"].is_boolean() || field["exclusive"] != true
            || field["directory"].as_str().is_none_or(|text| text.len() > 4096 || text.contains('\0'))
            || field["filenamePrefix"].as_str().is_none_or(|text| text.len() > 512 || text.contains('\0')) {
            return Err("备份摘要字段无效。".into());
        }
    }
    Ok(value)
}

#[cfg(windows)]
async fn resource_script(app: &AppHandle) -> Result<PathBuf, String> {
    let mut candidates = Vec::new();
    if let Ok(root) = app.path().resource_dir() { candidates.push(root.join("resources").join("xisland-hook.cjs")); }
    #[cfg(debug_assertions)]
    candidates.push(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("resources").join("xisland-hook.cjs"));
    for path in candidates {
        if tokio::fs::metadata(&path).await.is_ok_and(|metadata| metadata.is_file()) { return Ok(path); }
    }
    Err("缺少 resources/xisland-hook.cjs；请重新构建 hook 资源或修复应用安装。".into())
}

#[cfg(windows)]
fn node_candidates() -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(path) = std::env::var_os("PATH") {
        candidates.extend(std::env::split_paths(&path).filter(|directory| directory.is_absolute()).map(|directory| directory.join("node.exe")));
    }
    for name in ["ProgramFiles", "ProgramFiles(x86)"] {
        if let Some(directory) = std::env::var_os(name) { candidates.push(PathBuf::from(directory).join("nodejs").join("node.exe")); }
    }
    if let Some(directory) = std::env::var_os("LOCALAPPDATA") {
        let root = PathBuf::from(directory);
        for relative in ["Programs/nodejs/node.exe", "nodejs/node.exe", "Volta/bin/node.exe", "Microsoft/WinGet/Links/node.exe"] {
            candidates.push(root.join(relative));
        }
    }
    let mut seen = HashSet::new();
    candidates.into_iter().filter(|path| path.is_absolute()
        && seen.insert(path.to_string_lossy().to_lowercase())).take(256).collect()
}

#[cfg(windows)]
async fn capture(executable: &Path, arguments: &[std::ffi::OsString], limit: usize) -> Result<(ExitStatus, Vec<u8>), String> {
    let mut command = Command::new(executable);
    command.args(arguments).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null())
        .env_remove("NODE_OPTIONS").kill_on_drop(true).creation_flags(0x0800_0000);
    let mut child = command.spawn().map_err(|_| "无法启动接入运行时。")?;
    let stdout = child.stdout.take().ok_or("无法读取接入服务输出。")?;
    let mut bytes = Vec::new();
    stdout.take((limit + 1) as u64).read_to_end(&mut bytes).await.map_err(|_| "接入服务输出读取失败。")?;
    if bytes.len() > limit { return Err("接入服务输出超过摘要大小上限。".into()); }
    let status = child.wait().await.map_err(|_| "接入服务没有正常退出。")?;
    Ok((status, bytes))
}

#[cfg(windows)]
async fn discover_node(bundled: &Path) -> Result<(PathBuf, String), String> {
    let candidates=std::iter::once(bundled.to_path_buf()).chain(node_candidates());
    for candidate in candidates {
        if !matches!(timeout(Duration::from_secs(1), tokio::fs::metadata(&candidate)).await,
            Ok(Ok(metadata)) if metadata.is_file() && metadata.len() > 0) { continue; }
        let arguments = vec![std::ffi::OsString::from("--version")];
        if let Ok(Ok((status, bytes))) = timeout(Duration::from_secs(2), capture(&candidate, &arguments, 1024)).await {
            if status.success() {
                if let Some(version) = supported_node_version(&bytes) { return Ok((candidate, version)); }
            }
        }
    }
    Err("未找到可运行的 Node.js 20 或更高版本。请安装 Node.js 后重新打开 XIsland；应用不会自动安装或修改 PATH。".into())
}

#[cfg(windows)]
fn unavailable(request: &Request, reason: &str, warning: String) -> Value {
    json!({"agent":request.agent,"platformSupported":true,"runtimeReady":false,"configurationKnown":false,
        "installed":null,"managedHandlers":null,"reason":reason,"warnings":[warning]})
}

#[cfg(windows)]
async fn execute(app: &AppHandle, request: &Request) -> Result<Value, String> {
    let script = match resource_script(app).await {
        Ok(script) => script,
        Err(error) if request.action == Action::Status => return Ok(unavailable(request, "hook_missing", error)),
        Err(error) => return Err(error),
    };
    let bridge = script.parent().ok_or("hook 资源路径无效。")?.join("xisland-bridge.exe");
    let bridge_exists = tokio::fs::metadata(&bridge).await.is_ok_and(|metadata| metadata.is_file());
    if !bridge_exists && !(request.action != Action::Status && request.operation == "uninstall") {
        let message = "缺少同目录的 xisland-bridge.exe；请修复应用安装后再接入客户端。".to_owned();
        if request.action == Action::Status { return Ok(unavailable(request, "bridge_missing", message)); }
        return Err(message);
    }
    let bundled_node=script.parent().ok_or("hook 资源路径无效。")?.join("node.exe");
    let (node, version) = match discover_node(&bundled_node).await {
        Ok(found) => found,
        Err(error) if request.action == Action::Status => return Ok(unavailable(request, "node_missing_or_unsupported", error)),
        Err(error) => return Err(error),
    };
    let mut arguments = vec![script.into_os_string()];
    arguments.extend(cli_arguments(request).into_iter().map(std::ffi::OsString::from));
    let (status, output) = capture(&node, &arguments, 64 * 1024).await?;
    let value: Value = serde_json::from_slice(&output).map_err(|_| "接入服务没有返回有效 JSON 摘要；请修复应用资源。")?;
    if !status.success() { return Err(service_error(&value)); }
    let mut summary = validate_summary(value, request)?;
    summary["nodeVersion"] = json!(version);
    summary["nodeExecutable"] = json!(node.to_string_lossy());
    Ok(summary)
}

#[tauri::command]
pub async fn integration_command(app: AppHandle, agent: String, action: String, operation: Option<String>, revision: Option<String>) -> Result<Value, String> {
    let request = validate_request(agent, action, operation, revision)?;
    #[cfg(not(windows))]
    {
        let _ = app;
        if request.action == Action::Status {
            return Ok(json!({"agent":request.agent,"platformSupported":false,"runtimeReady":false,"installed":false,
                "managedHandlers":0,"warnings":["接入安装仅在 Windows 客户端执行；当前平台没有读取用户配置。"]}));
        }
        Err("接入安装仅在 Windows 客户端执行；当前平台不会读取或修改用户配置。".into())
    }
    #[cfg(windows)]
    {
        timeout(Duration::from_secs(20), execute(&app, &request)).await
            .map_err(|_| "接入操作在 20 秒内未完成。已停止子进程，请刷新状态后重新查看计划。".to_owned())?
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request(action: &str) -> Request {
        validate_request("claude_code".into(), action.into(), Some("install".into()),
            (action == "apply").then(|| "a".repeat(64))).unwrap()
    }
    #[test]
    fn rejects_unrecognized_agents_actions_and_operations() {
        for agent in ["Claude", "claude_code; echo unsafe", "unknown"] {
            assert!(validate_request(agent.into(), "status".into(), None, None).is_err());
        }
        assert!(validate_request("cursor".into(), "exec".into(), None, None).is_err());
        assert!(validate_request("cursor".into(), "plan".into(), Some("shell".into()), None).is_err());
    }
    #[test]
    fn apply_requires_exact_revision_and_other_actions_reject_it() {
        for revision in [None, Some("".into()), Some("a".repeat(63)), Some("g".repeat(64)), Some("A".repeat(64))] {
            assert!(validate_request("codex".into(), "apply".into(), None, revision).is_err());
        }
        assert!(validate_request("codex".into(), "status".into(), None, Some("a".repeat(64))).is_err());
        assert!(validate_request("codex".into(), "apply".into(), Some("uninstall".into()), Some("a".repeat(64))).is_ok());
    }
    #[test]
    fn builds_only_fixed_cli_flags_without_shell_text() {
        assert_eq!(cli_arguments(&request("status")), ["--integration-status", "--agent", "claude_code"]);
        assert_eq!(cli_arguments(&request("plan")), ["--integration-plan", "--agent", "claude_code", "--operation", "install"]);
        let arguments = cli_arguments(&request("apply"));
        assert_eq!(arguments[0], "--integration-apply");
        assert_eq!(arguments[5], "--expected-revision"); assert_eq!(arguments[6], "a".repeat(64));
    }
    #[test]
    fn node_must_report_a_stable_version_twenty_or_newer() {
        for version in ["v20.0.0\r\n", "v22.12.0", "v24.1.2"] { assert!(supported_node_version(version.as_bytes()).is_some()); }
        for version in ["v18.20.0", "v19.9.9", "20.0.0", "v20.0.0-nightly", "v20.0.0\nsecret", "v20.x.1"] {
            assert!(supported_node_version(version.as_bytes()).is_none());
        }
    }
    #[test]
    fn rejects_configuration_payloads_and_wrong_agent_in_summary() {
        let valid = json!({"agent":"claude_code","operation":"install","runtimeReady":true,"revision":"a".repeat(64),"changed":true});
        assert!(validate_summary(valid.clone(), &request("plan")).is_ok());
        let mut wrong = valid.clone(); wrong["nextConfig"] = json!({"apiKey":"never-display"});
        assert!(validate_summary(wrong, &request("plan")).is_err());
        let mut wrong = valid; wrong["agent"] = json!("cursor");
        assert!(validate_summary(wrong, &request("plan")).is_err());
    }
    #[test]
    fn service_errors_do_not_echo_arbitrary_process_content() {
        let error = service_error(&json!({"error":{"code":"invalid_json","message":"secret-config-content"}}));
        assert!(error.contains("JSON")); assert!(!error.contains("secret-config-content"));
    }
    #[test]
    fn workbuddy_only_exports_and_cannot_claim_native_acceptance() {
        let request = validate_request("workbuddy".into(), "export".into(), None, None).unwrap();
        assert_eq!(cli_arguments(&request), ["--workbuddy-export", "--agent", "workbuddy"]);
        assert!(validate_request("workbuddy".into(), "apply".into(), None, None).is_err());
        assert!(validate_request("workbuddy".into(), "export".into(), Some("install".into()), None).is_err());
        let mut summary = json!({"agent":"workbuddy","exportedPath":"C:\\Users\\test\\XIsland-Plugins\\workbuddy-test",
            "eventCount":11,"observationOnly":true,"clientVerified":false,"runtimeReady":true});
        assert!(validate_summary(summary.clone(), &request).is_ok());
        summary["clientVerified"] = json!(true);
        assert!(validate_summary(summary, &request).is_err());
    }
}
