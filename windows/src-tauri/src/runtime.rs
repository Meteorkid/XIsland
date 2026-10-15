use serde::{Deserialize, Serialize};
use std::{env, fs, io, path::PathBuf};

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeDescriptor {
    pub protocol_version: u32,
    pub endpoint: String,
    pub token: String,
    pub pid: u32,
}

pub fn directory() -> io::Result<PathBuf> {
    if env::var("XISLAND_TEST_MODE").as_deref() == Ok("1") {
        let root = env::var_os("XISLAND_RUNTIME_DIR")
            .ok_or_else(|| io::Error::other("测试模式必须指定 XISLAND_RUNTIME_DIR"))?;
        let root = PathBuf::from(root);
        if !root.is_absolute() || root.components().any(|part| matches!(part, std::path::Component::ParentDir)) {
            return Err(io::Error::other("测试目录必须是无父级跳转的绝对路径"));
        }
        let temporary = env::temp_dir().canonicalize()?;
        let existing = root.ancestors().find(|ancestor| ancestor.exists())
            .ok_or_else(|| io::Error::other("测试目录缺少有效父目录"))?.canonicalize()?;
        if !existing.starts_with(&temporary) || (root.exists() && existing == temporary) {
            return Err(io::Error::other("测试运行时必须位于临时目录的独立子目录"));
        }
        fs::create_dir_all(&root)?;
        let root = root.canonicalize()?;
        if !root.starts_with(&temporary) || root == temporary {
            return Err(io::Error::other("测试运行时必须位于临时目录的独立子目录"));
        }
        return Ok(root);
    }
    #[cfg(windows)]
    let root = PathBuf::from(env::var_os("LOCALAPPDATA").ok_or_else(|| io::Error::other("缺少 LOCALAPPDATA"))?)
        .join("XIsland");
    #[cfg(not(windows))]
    let root = PathBuf::from(env::var_os("HOME").ok_or_else(|| io::Error::other("缺少 HOME"))?)
        .join("Library/Application Support/XIsland-Windows-Dev");
    fs::create_dir_all(&root)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700))?;
    }
    Ok(root)
}

pub fn create_descriptor() -> io::Result<RuntimeDescriptor> {
    let id = uuid::Uuid::new_v4().simple().to_string();
    #[cfg(windows)]
    let endpoint = format!(r"\\.\pipe\xisland-{id}");
    #[cfg(unix)]
    let endpoint = env::temp_dir().join(format!("xisland-{id}.sock")).to_string_lossy().into_owned();
    Ok(RuntimeDescriptor { protocol_version: 1, endpoint, token: uuid::Uuid::new_v4().to_string(), pid: std::process::id() })
}

pub fn save_descriptor(descriptor: &RuntimeDescriptor) -> io::Result<()> {
    atomic_write(&directory()?.join("runtime.json"), &serde_json::to_vec(descriptor)?)
}

pub fn read_descriptor() -> io::Result<RuntimeDescriptor> {
    let descriptor: RuntimeDescriptor = serde_json::from_slice(&fs::read(directory()?.join("runtime.json"))?)?;
    if descriptor.protocol_version != 1 || descriptor.token.is_empty() {
        return Err(io::Error::other("不支持的运行时协议"));
    }
    Ok(descriptor)
}

pub fn atomic_write(path: &std::path::Path, content: &[u8]) -> io::Result<()> {
    use std::io::Write;
    let temporary = path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let result = (|| {
        let mut file = options.open(&temporary)?;
        file.write_all(content)?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temporary, path)
    })();
    if result.is_err() { let _ = fs::remove_file(&temporary); }
    result
}
