#!/usr/bin/env python3
"""隔离验证 Aider 包装器；PATH 中只放离线替身，不调用真实 Aider 或模型。"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shlex
import socket
import subprocess
import sys
import tempfile
import threading
import time


def verify(binary: Path) -> list[str]:
    passed: list[str] = []
    with tempfile.TemporaryDirectory(prefix="xi-aider-", dir="/tmp") as temporary:
        root = Path(temporary)
        mock = root / "aider"
        mock.write_text(f"#!{sys.executable}\n" + '''import json, os, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
Path(os.environ["XI_AIDER_ARGV"]).write_text(json.dumps(args, ensure_ascii=False))
command = args[args.index("--notifications-command") + 1]
Path(os.environ["XI_AIDER_CALLBACK"]).write_text(command)
subprocess.run(command, shell=True, check=True, timeout=2)
print("mock-aider-output", flush=True)
print("mock-aider-error", file=sys.stderr, flush=True)
raise SystemExit(int(os.environ.get("XI_AIDER_EXIT", "0")))
''')
        mock.chmod(0o700)
        messages: list[dict] = []
        errors: list[str] = []
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(root / "di.sock"))
        server.listen(8)
        server.settimeout(0.1)
        stop = threading.Event()

        def receive() -> None:
            while not stop.is_set():
                try:
                    connection, _ = server.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                with connection:
                    connection.settimeout(1)
                    try:
                        with connection.makefile("rb") as stream:
                            messages.append(json.loads(stream.readline()))
                    except Exception as error:
                        errors.append(str(error))

        worker = threading.Thread(target=receive, daemon=True)
        worker.start()
        env = dict(os.environ)
        for key in ["X_ISLAND_AIDER_WRAPPER_ACTIVE", "DI_SESSION_ID", "DI_SOCKET_PATH", "DI_BRIDGE_DEBUG_LOG"]:
            env.pop(key, None)
        env.update(PATH=str(root) + ":/usr/bin:/bin", X_ISLAND_TEST_MODE="1", X_ISLAND_TEST_RUNTIME_DIR=str(root),
                   XI_AIDER_ARGV=str(root / "argv.json"), XI_AIDER_CALLBACK=str(root / "callback.txt"))

        def caught(count: int) -> None:
            deadline = time.monotonic() + 2
            while len(messages) < count and time.monotonic() < deadline:
                time.sleep(0.01)
            assert len(messages) == count and not errors, (messages, errors)

        try:
            arguments = ["--message", "中文\n'quoted' $(touch forbidden)", "--notifications-command", "user command", "--", "file name"]
            process = subprocess.run([str(binary), "aider", *arguments], env={**env, "XI_AIDER_EXIT": "7"}, cwd=root,
                                     input="unconsumed input", text=True, capture_output=True, timeout=5)
            assert process.returncode == 7, process.stderr
            assert process.stdout == "mock-aider-output\n" and "mock-aider-error" in process.stderr
            assert json.loads((root / "argv.json").read_text())[3:] == arguments
            assert not (root / "forbidden").exists()
            caught(3)
            start, notice, end = messages
            assert [m["type"] for m in messages] == ["session_start", "status_update", "session_end"]
            identity = start["sessionId"]
            assert identity.startswith("aider-wrapper-") and all(m["sessionId"] == identity for m in messages)
            assert all(m["agentType"] == "aider" and m["statusIsAssistantReply"] is False for m in messages)
            assert start.get("prompt") is None and notice.get("observedState") is None
            assert end["observedState"] == "completed" and "7" in end["status"]
            assert "轮次状态不可用" in start["status"]
            passed.append("argv-exit-stdio-and-scoped-lifecycle")

            callback = (root / "callback.txt").read_text()
            state_path = Path(shlex.split(callback)[2])
            assert not state_path.exists()
            late = subprocess.run(callback, shell=True, env=env, capture_output=True, timeout=1)
            assert late.returncode == 0
            time.sleep(0.12)
            assert len(messages) == 3
            passed.append("late-callback-does-not-reopen-ended-process")

            # stdin 保持打开，回调也必须及时退出，不能等待读取 JSON EOF。
            dangling = subprocess.Popen([str(binary), "aider-notify", str(root / "missing")], env=env,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            assert dangling.wait(timeout=1) == 0
            dangling.communicate()
            passed.append("callback-does-not-read-stdin")

            children = []
            for index in range(2):
                child_env = {**env, "XI_AIDER_ARGV": str(root / f"argv-{index}.json"), "XI_AIDER_CALLBACK": str(root / f"callback-{index}.txt")}
                children.append(subprocess.Popen([str(binary), "aider"], env=child_env, cwd=root,
                                                  stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE))
            for child in children:
                child.communicate(timeout=5)
                assert child.returncode == 0
            caught(9)
            identities = {m["sessionId"] for m in messages}
            assert len(identities) == 3
            for identity in identities:
                assert [m["type"] for m in messages if m["sessionId"] == identity] == ["session_start", "status_update", "session_end"]
            passed.append("concurrent-same-directory-processes-remain-distinct")

            before = len(messages)
            for state in [
                {"version": 99, "active": True}, {"version": 1, "active": False},
                {"version": 1, "active": True, "ownerPID": 0},
                {"version": 1, "active": True, "id": "aider-cwd-hash"},
            ]:
                payload = {"version": 1, "id": start["sessionId"], "active": True, "ownerPID": os.getpid(),
                           "workingDirectory": str(root), "socketPath": str(root / "di.sock"), **state}
                state_file = root / "invalid.json"
                state_file.write_text(json.dumps(payload))
                state_file.chmod(0o600)
                result = subprocess.run([str(binary), "aider-notify", str(state_file)], env=env, timeout=1, capture_output=True)
                assert result.returncode == 0
            time.sleep(0.12)
            assert len(messages) == before
            passed.append("invalid-inactive-and-unscoped-callbacks-ignored")

            for extra, code in [({"PATH": str(root / "absent")}, 127), ({"X_ISLAND_AIDER_WRAPPER_ACTIVE": "1"}, 126)]:
                result = subprocess.run([str(binary), "aider"], env={**env, **extra}, capture_output=True, timeout=2)
                assert result.returncode == code
            assert len(messages) == before
            passed.append("missing-executable-and-recursion-do-not-create-sessions")

            disconnected = subprocess.run([str(binary), "aider"], env={**env, "DI_SOCKET_PATH": str(root / "absent.sock")},
                                          stdin=subprocess.DEVNULL, capture_output=True, timeout=3)
            assert disconnected.returncode == 0
            passed.append("missing-island-does-not-block-aider")
        finally:
            stop.set()
            server.close()
            worker.join(timeout=2)
    return passed


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=Path(__file__).resolve().parents[1] / ".build/debug/DIBridge")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    passed = verify(binary)
    report = {"checkedAt": datetime.now(timezone.utc).isoformat(), "scope": "Compiled wrapper with offline Aider substitute and temporary socket, not vendor client acceptance.",
              "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(), "count": len(passed), "passed": passed, "realClientVerified": False}
    if args.report:
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"Aider wrapper: {len(passed)} scenarios passed")


if __name__ == "__main__":
    main()
