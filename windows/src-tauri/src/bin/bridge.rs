use std::{io::{self, Read}, process::ExitCode};
use xisland_windows::{client_origin, runtime, transport};

#[tokio::main]
async fn main() -> ExitCode {
    let mut input = Vec::new();
    let read = io::stdin().take((transport::MAX_FRAME + 1) as u64).read_to_end(&mut input);
    if read.is_err() || input.len() > transport::MAX_FRAME {
        eprintln!("XIsland: 输入读取失败或超过大小限制");
        return ExitCode::FAILURE;
    }
    let result = async {
        let mut message = serde_json::from_slice(&input).map_err(io::Error::other)?;
        client_origin::attribute_observation(&mut message);
        let descriptor = runtime::read_descriptor()?;
        transport::send(&descriptor, message).await
    }.await;
    match result {
        Ok(response) => { println!("{response}"); ExitCode::SUCCESS }
        Err(error) => { eprintln!("XIsland bridge: {error}"); ExitCode::FAILURE }
    }
}
