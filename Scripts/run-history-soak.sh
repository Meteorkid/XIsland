#!/bin/sh
# 仅运行独立SQLite长稳夹具，不启动生产App或访问客户端配置。
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output=${1:?Usage: sh Scripts/run-history-soak.sh /absolute/output/directory [seconds]}
seconds=${2:-28800}
case "$output" in /*) ;; *) echo 'Output must be an absolute path' >&2; exit 2 ;; esac
case "$seconds" in ''|*[!0-9]*|0) echo 'Duration must be a positive integer' >&2; exit 2 ;; esac
if [ -e "$output/run.json" ] || [ -e "$output/history.store" ]; then echo 'Refusing to overwrite an earlier soak run' >&2; exit 2; fi
mkdir -p "$output"
cd "$project_root"
swift test -c release list > "$output/build.log" 2>&1
# 固定本次二进制，长稳期间不占用SwiftPM锁，也不受后续构建替换影响。
ditto .build/release/XIslandTests.xctest "$output/XIslandTests.xctest"
python3 - "$project_root" "$output" "$seconds" <<'PY'
import datetime, hashlib, json, pathlib, subprocess, sys
root, output = map(pathlib.Path, sys.argv[1:3])
files = sorted(path for folder in ("Sources", "Tests") for path in (root / folder).rglob("*.swift"))
hashes = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in files}
binary = output / "XIslandTests.xctest/Contents/MacOS/XIslandTests"
(output / "run.json").write_text(json.dumps({"startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "requestedSeconds": int(sys.argv[3]), "sourceHashes": hashes,
    "testBinarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest()}, indent=2) + "\n")
# XCTest装载失败时会输出环境；只传入测试必需白名单，避免继承凭据。
import os
environment = {key: os.environ[key] for key in ("PATH", "HOME", "TMPDIR", "DEVELOPER_DIR") if key in os.environ}
environment.update(X_ISLAND_TEST_MODE="1", X_ISLAND_SOAK_DIRECTORY=str(output), X_ISLAND_SOAK_SECONDS=sys.argv[3])
with (output / "runner.log").open("w") as log:
    result = subprocess.run(["xcrun", "xctest", "-XCTest", "XIslandTests.HistoryLongRunTests/testContinuousHistoryLoad",
                             str(output / "XIslandTests.xctest")], env=environment, stdout=log, stderr=subprocess.STDOUT)
(output / "exit.json").write_text(json.dumps({"exitCode": result.returncode,
    "finishedAt": datetime.datetime.now(datetime.timezone.utc).isoformat()}) + "\n")
sys.exit(result.returncode)
PY
