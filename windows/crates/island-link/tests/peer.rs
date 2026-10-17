use island_link::{Callbacks, Identity, Link};
use std::{io::{self,BufRead,Write},path::PathBuf,sync::{Arc,atomic::{AtomicBool,Ordering}},time::Duration};
fn main() {
    let detached=std::env::args().nth(1).is_none();
    let root=std::env::args().nth(1).map(PathBuf::from).unwrap_or_else(||std::env::current_exe().unwrap().parent().unwrap().to_path_buf());
    let detached_root=root.clone();
    let show_root=root.clone();let hide_root=root.clone();
    let identity=if std::env::current_exe().unwrap().file_stem().unwrap()=="xnook" {Identity::XNook} else {Identity::XIsland};
    if detached && identity==Identity::XIsland {
        while root.join("hold-peer-startup").exists() { std::thread::sleep(Duration::from_millis(20)); }
    }
    let link=Link::open_at(root,identity).unwrap();
    let visible=Arc::new(AtomicBool::new(false));
    let delay=std::env::var("ISLAND_TEST_SHOW_DELAY").ok().and_then(|s|s.parse().ok()).unwrap_or(0u64);
    let fail=std::env::var("ISLAND_TEST_SHOW_FAIL").is_ok();
    let show_visible=visible.clone(); let hide_visible=visible.clone();
    link.start(Callbacks {show:Arc::new(move || {std::thread::sleep(Duration::from_millis(delay));if fail {return Err("test show failure".into())}show_visible.store(true,Ordering::SeqCst);if show_root.join("fail-ready-write").exists() && identity==Identity::XIsland {break_state_file(&show_root);}Ok(())}),hide:Arc::new(move || {if identity==Identity::XNook { if let Ok(delay)=std::fs::read_to_string(hide_root.join("source-hide-delay")) {std::fs::write(hide_root.join("source-hide-started"),"").unwrap();std::thread::sleep(Duration::from_millis(delay.parse().unwrap()));} }if hide_root.join("fail-source-hide").exists() && identity==Identity::XNook {return Err("test hide failure".into())}hide_visible.store(false,Ordering::SeqCst);if hide_root.join("fail-commit-write").exists() && identity==Identity::XNook {break_state_file(&hide_root);}Ok(())}),on_error:Arc::new(|_|{})}).unwrap();
    if detached {
        std::fs::write(detached_root.join("launched.pid"),std::process::id().to_string()).unwrap();
        while !detached_root.join("stop-launched").exists() {
            std::fs::write(detached_root.join("launched.visible"),visible.load(Ordering::SeqCst).to_string()).unwrap();
            std::thread::sleep(Duration::from_millis(30));
        }
        link.shutdown();return;
    }
    println!("ready"); io::stdout().flush().unwrap();
    for line in io::stdin().lock().lines() {
        let line=line.unwrap(); let mut pieces=line.split_whitespace();
        let action=pieces.next().unwrap_or("");
        if let Some(json) = line.strip_prefix("preferences ") {
            let preferences = serde_json::from_str(json).unwrap();
            let result = link.set_preferences(preferences).map(|value|serde_json::to_value(value).unwrap());
            println!("{}",serde_json::json!({"preferences":result.as_ref().ok(),"error":result.err()}));io::stdout().flush().unwrap();continue;
        }
        let timeout=Duration::from_millis(pieces.next().and_then(|s|s.parse().ok()).unwrap_or(1200));
        let result=match action {
            "switch"=>serde_json::json!({"result":link.switch_to_peer(timeout).err()}),
            "show"=>serde_json::json!({"result":link.request_show(timeout).err()}),
            "state"=>serde_json::json!({"owns":link.owns_display(),"visible":visible.load(Ordering::SeqCst)}),
            "status"=>serde_json::to_value(link.peer_status().unwrap()).unwrap(),
            "preferences"=>serde_json::to_value(link.preferences().unwrap()).unwrap(),
            "exit"=>break,
            _=>panic!("unknown test command")
        };
        println!("{result}"); io::stdout().flush().unwrap();
    }
    link.shutdown();
}

fn break_state_file(root: &std::path::Path) {
    if root.join("state.json").is_file() {std::fs::rename(root.join("state.json"),root.join("saved-state.json")).unwrap();std::fs::create_dir(root.join("state.json")).unwrap();}
}
