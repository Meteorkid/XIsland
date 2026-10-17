use serde_json::Value;
use std::{fs,io::{BufRead,BufReader,Write},path::PathBuf,process::{Child,ChildStdin,ChildStdout,Command,Stdio},thread,time::Duration};
use uuid::Uuid;
struct Peer { child:Child, input:ChildStdin, output:BufReader<ChildStdout> }
impl Peer {
    fn start(root:&PathBuf,name:&str,delay:u64,fail:bool)->Self {
        let exe=root.join(if cfg!(windows) {format!("{name}.exe")} else {name.into()});
        fs::copy(env!("CARGO_BIN_EXE_link-test-peer"),&exe).unwrap();
        let mut command=Command::new(exe); command.arg(root).env("ISLAND_TEST_SHOW_DELAY",delay.to_string()).stdin(Stdio::piped()).stdout(Stdio::piped());
        if fail {command.env("ISLAND_TEST_SHOW_FAIL","1");}
        let mut child=command.spawn().unwrap(); let input=child.stdin.take().unwrap();let mut output=BufReader::new(child.stdout.take().unwrap());
        let mut line=String::new();output.read_line(&mut line).unwrap();assert_eq!(line.trim(),"ready");
        Self {child,input,output}
    }
    fn send(&mut self,s:&str){writeln!(self.input,"{s}").unwrap();self.input.flush().unwrap();}
    fn read(&mut self)->Value{let mut s=String::new();self.output.read_line(&mut s).unwrap();serde_json::from_str(&s).unwrap()}
    fn call(&mut self,s:&str)->Value{self.send(s);self.read()}
}
impl Drop for Peer {fn drop(&mut self){let _=self.child.kill();let _=self.child.wait();}}
struct Fixture(PathBuf);
impl Fixture {fn new()->Self {let root=std::env::temp_dir().join(format!("island-link-test-{}",Uuid::new_v4()));fs::create_dir_all(&root).unwrap();Self(root)}}
impl Drop for Fixture {fn drop(&mut self){let _=fs::remove_dir_all(&self.0);}}
fn settle(){thread::sleep(Duration::from_millis(220));}
fn wait_until(mut condition:impl FnMut()->bool){for _ in 0..100{if condition(){return;}thread::sleep(Duration::from_millis(30));}panic!("condition did not become true");}
fn assert_owner(nook:&mut Peer,island:&mut Peer,nook_visible:bool){settle();assert_eq!(nook.call("state")["visible"],nook_visible);assert_eq!(island.call("state")["visible"],!nook_visible);assert_eq!(nook.call("state")["owns"],nook_visible);assert_eq!(island.call("state")["owns"],!nook_visible);}
#[test]
fn independent_processes_switch_both_ways_and_tray_show_uses_same_owner(){
    let f=Fixture::new();let mut n=Peer::start(&f.0,"xnook",0,false);settle();let mut i=Peer::start(&f.0,"xisland",0,false);
    assert_owner(&mut n,&mut i,true);assert!(n.call("switch")["result"].is_null());assert_owner(&mut n,&mut i,false);
    assert!(i.call("switch")["result"].is_null());assert_owner(&mut n,&mut i,true);
    assert!(i.call("show")["result"].is_null());assert_owner(&mut n,&mut i,false);
    drop(i);settle();assert_eq!(n.call("state")["visible"],true);
}

#[test]
fn integration_preferences_are_shared_and_do_not_switch_the_current_owner(){
    let f=Fixture::new();let mut n=Peer::start(&f.0,"xnook",0,false);settle();let mut i=Peer::start(&f.0,"xisland",0,false);settle();
    let response=n.call(r#"preferences {"swipeEnabled":false,"sensitivity":"high","startupDisplay":"xisland"}"#);
    assert!(response["error"].is_null());let prefs=i.call("preferences");
    assert_eq!(prefs["swipeEnabled"],false);assert_eq!(prefs["sensitivity"],"high");assert_eq!(prefs["startupDisplay"],"xisland");
    assert_owner(&mut n,&mut i,true);
    // 手势开关只控制手势，显式按钮仍可切换。
    assert!(n.call("switch")["result"].is_null());assert_owner(&mut n,&mut i,false);
}

#[test]
fn preferred_startup_launches_registered_peer_and_last_used_survives_restart(){
    for mode in ["xisland","lastUsed"] {
        let f=Fixture::new();let mut n=Peer::start(&f.0,"xnook",0,false);settle();let mut i=Peer::start(&f.0,"xisland",0,false);settle();
        n.call(&format!(r#"preferences {{"swipeEnabled":true,"sensitivity":"medium","startupDisplay":"{mode}"}}"#));
        assert!(n.call("switch")["result"].is_null());assert_owner(&mut n,&mut i,false);
        drop(n);drop(i);
        let mut n=Peer::start(&f.0,"xnook",0,false);
        wait_until(||fs::read_to_string(f.0.join("launched.visible")).is_ok_and(|v|v=="true"));
        assert_eq!(n.call("state")["visible"],false);
        fs::write(f.0.join("stop-launched"),"").unwrap();
        wait_until(||n.call("state")["visible"]==true);
    }
}

#[test]
fn missing_startup_peer_falls_back_without_losing_current_window(){
    let f=Fixture::new();
    fs::write(f.0.join("preferences.json"),r#"{"preferences":{"swipeEnabled":true,"sensitivity":"low","startupDisplay":"xisland"},"lastShown":null}"#).unwrap();
    let mut n=Peer::start(&f.0,"xnook",0,false);
    wait_until(||n.call("state")["visible"]==true);
    assert_eq!(n.call("state")["owns"],true);
}

#[test]
fn explicit_tray_show_cancels_slow_startup_and_late_peer_cannot_steal_owner(){
    let f=Fixture::new();let mut n=Peer::start(&f.0,"xnook",0,false);settle();let i=Peer::start(&f.0,"xisland",0,false);settle();
    n.call(r#"preferences {"swipeEnabled":true,"sensitivity":"medium","startupDisplay":"xisland"}"#);
    drop(i);drop(n);fs::write(f.0.join("hold-peer-startup"),"").unwrap();
    let mut n=Peer::start(&f.0,"xnook",0,false);
    wait_until(|| fs::read(f.0.join("state.json")).ok().and_then(|bytes|serde_json::from_slice::<Value>(&bytes).ok()).is_some_and(|state|state["request"]["target"]=="xisland"));
    assert!(n.call("show")["result"].is_null());assert_eq!(n.call("state")["visible"],true);
    fs::remove_file(f.0.join("hold-peer-startup")).unwrap();
    wait_until(||f.0.join("launched.visible").exists());settle();
    assert_eq!(fs::read_to_string(f.0.join("launched.visible")).unwrap(),"false");assert_eq!(n.call("state")["owns"],true);
    fs::write(f.0.join("stop-launched"),"").unwrap();settle();
}
#[test]
fn missing_peer_and_failed_show_keep_source_visible(){
    let f=Fixture::new();let mut n=Peer::start(&f.0,"xnook",0,false);settle();assert!(!n.call("switch")["result"].is_null());assert_eq!(n.call("state")["visible"],true);
    let mut i=Peer::start(&f.0,"xisland",0,true);settle();assert!(!n.call("switch")["result"].is_null());assert_owner(&mut n,&mut i,true);
}
#[test]
fn late_show_ack_is_rolled_back_and_never_hides_source(){
    let f=Fixture::new();let mut n=Peer::start(&f.0,"xnook",0,false);settle();let mut i=Peer::start(&f.0,"xisland",450,false);settle();
    assert!(!n.call("switch 150")["result"].is_null());thread::sleep(Duration::from_millis(500));assert_owner(&mut n,&mut i,true);
}
#[test]
fn concurrent_start_and_switch_have_one_owner(){
    let f=Fixture::new();let mut n=Peer::start(&f.0,"xnook",0,false);let mut i=Peer::start(&f.0,"xisland",0,false);settle();
    let before=n.call("state")["visible"].as_bool().unwrap();assert_owner(&mut n,&mut i,before);
    n.send("switch");i.send("switch");let a=n.read();let b=i.read();
    assert_ne!(a["result"].is_null(),b["result"].is_null());assert_owner(&mut n,&mut i,!before);
}
#[test]
fn registered_but_stopped_peer_is_started_without_arguments(){
    let f=Fixture::new();let mut n=Peer::start(&f.0,"xnook",0,false);settle();let i=Peer::start(&f.0,"xisland",0,false);drop(i);settle();
    assert!(n.call("switch")["result"].is_null());settle();assert_eq!(n.call("state")["visible"],false);
    assert_eq!(fs::read_to_string(f.0.join("launched.visible")).unwrap(),"true");
    fs::write(f.0.join("stop-launched"),"").unwrap();settle();assert_eq!(n.call("state")["visible"],true);
}

#[test]
fn source_hide_failure_restores_source_and_rolls_back_target(){
    let f=Fixture::new();let mut n=Peer::start(&f.0,"xnook",0,false);settle();let mut i=Peer::start(&f.0,"xisland",0,false);settle();
    fs::write(f.0.join("fail-source-hide"),"").unwrap();
    assert!(!n.call("switch")["result"].is_null());assert_owner(&mut n,&mut i,true);
    fs::remove_file(f.0.join("fail-source-hide")).unwrap();
    assert!(n.call("switch")["result"].is_null());assert_owner(&mut n,&mut i,false);
}
#[test]
fn failed_ready_or_commit_write_never_loses_the_source(){
    for marker in ["fail-ready-write","fail-commit-write"] {
        let f=Fixture::new();let mut n=Peer::start(&f.0,"xnook",0,false);settle();let mut i=Peer::start(&f.0,"xisland",0,false);settle();
        fs::write(f.0.join(marker),"").unwrap();
        assert!(!n.call("switch 500")["result"].is_null());assert_eq!(n.call("state")["visible"],true);
        fs::remove_file(f.0.join(marker)).unwrap();fs::remove_dir(f.0.join("state.json")).unwrap();fs::rename(f.0.join("saved-state.json"),f.0.join("state.json")).unwrap();
        thread::sleep(Duration::from_millis(650));assert_owner(&mut n,&mut i,true);
    }
}
#[test]
fn independent_user_directories_cannot_see_or_switch_each_other(){
    let a=Fixture::new();let b=Fixture::new();let mut n=Peer::start(&a.0,"xnook",0,false);let mut i=Peer::start(&b.0,"xisland",0,false);settle();
    assert_eq!(n.call("status")["installed"],false);assert_eq!(i.call("status")["installed"],false);
    assert!(!n.call("switch")["result"].is_null());assert_eq!(n.call("state")["visible"],true);assert_eq!(i.call("state")["visible"],true);
}

#[test]
fn target_exit_during_source_hide_restores_source(){
    let f=Fixture::new();let mut n=Peer::start(&f.0,"xnook",0,false);settle();let mut i=Peer::start(&f.0,"xisland",0,false);settle();
    fs::write(f.0.join("source-hide-delay"),"350").unwrap();n.send("switch");
    let mut ready=false;
    for _ in 0..100 {
        let state:Value=serde_json::from_slice(&fs::read(f.0.join("state.json")).unwrap()).unwrap();
        if state["request"]["ready"]==true {ready=true;break;}
        thread::sleep(Duration::from_millis(10));
    }
    assert!(ready);i.child.kill().unwrap();i.child.wait().unwrap();
    assert!(!n.read()["result"].is_null());settle();assert_eq!(n.call("state")["visible"],true);
}

#[test]
fn restart_of_previous_owner_does_not_leave_an_invisible_owner(){
    let f=Fixture::new();let n=Peer::start(&f.0,"xnook",0,false);settle();drop(n);
    let mut n=Peer::start(&f.0,"xnook",0,false);settle();assert_eq!(n.call("state")["visible"],true);
}

#[test]
fn restarted_target_cannot_reuse_the_previous_instances_ready(){
    let f=Fixture::new();let mut n=Peer::start(&f.0,"xnook",0,false);settle();let mut i=Peer::start(&f.0,"xisland",0,false);settle();
    fs::write(f.0.join("source-hide-delay"),"500").unwrap();n.send("switch");
    let mut ready=false;
    for _ in 0..100 {
        let state:Value=serde_json::from_slice(&fs::read(f.0.join("state.json")).unwrap()).unwrap();
        if state["request"]["ready"]==true {ready=true;break;}
        thread::sleep(Duration::from_millis(10));
    }
    assert!(ready);i.child.kill().unwrap();i.child.wait().unwrap();
    let mut replacement=Peer::start(&f.0,"xisland",0,false);
    assert!(!n.read()["result"].is_null());assert_owner(&mut n,&mut replacement,true);
}

#[test]
fn lease_io_failure_after_source_hide_restores_source(){
    let f=Fixture::new();let mut n=Peer::start(&f.0,"xnook",0,false);settle();let mut i=Peer::start(&f.0,"xisland",0,false);settle();
    fs::write(f.0.join("source-hide-delay"),"1000").unwrap();n.send("switch 2000");
    let mut ready=None;
    for _ in 0..150 {
        let state:Value=serde_json::from_slice(&fs::read(f.0.join("state.json")).unwrap()).unwrap();
        if state["request"]["ready"]==true && f.0.join("source-hide-started").exists() {ready=Some(state["request"].clone());break;}
        thread::sleep(Duration::from_millis(10));
    }
    let request=ready.expect("source must enter hide after target is ready");
    let lease=f.0.join(format!("xisland.{}.lease",request["target_instance"].as_str().unwrap()));
    let saved=f.0.join("saved-target-lease");
    fs::rename(&lease,&saved).unwrap();fs::create_dir(&lease).unwrap();
    assert!(!n.read()["result"].is_null());thread::sleep(Duration::from_millis(300));
    fs::remove_dir(&lease).unwrap();fs::rename(saved,&lease).unwrap();fs::remove_file(f.0.join("source-hide-delay")).unwrap();
    assert_owner(&mut n,&mut i,true);
    let state:Value=serde_json::from_slice(&fs::read(f.0.join("state.json")).unwrap()).unwrap();
    assert_eq!(state["owner"],"xnook");assert!(state["request"].is_null());
}
