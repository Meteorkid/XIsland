#!/usr/bin/env python3
"""离线检查终端监督器；只用 Python 标准库、临时 swiftc harness 和真实 PTY。

默认独立编译单个 Swift 源文件，不运行 SwiftPM。--harness 可复用本脚本生成的
harness；它不是 di-bridge 的生产命令行接口。所有输入均为测试数据，不调用 AI。
"""

from __future__ import annotations

import argparse
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
from typing import Any


HARNESS = r'''
import Foundation
import Darwin

func emit(_ payload: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    FileHandle.standardError.write(data + Data([10]))
}
let args = Array(CommandLine.arguments.dropFirst())
if args == ["--verify-restoration"] {
    signal(SIGINT, SIG_IGN)
    signal(SIGCHLD, SIG_IGN)
    var mask: sigset_t = 0
    sigaddset(&mask, SIGUSR1)
    pthread_sigmask(SIG_BLOCK, &mask, nil)
    func snapshot() -> [UInt64] {
        var result: [UInt64] = []
        for number in [SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGTSTP, SIGCONT, SIGWINCH, SIGCHLD] {
            var action = sigaction()
            sigaction(number, nil, &action)
            result += [UInt64(unsafeBitCast(action.__sigaction_u.__sa_handler, to: UInt.self)),
                       UInt64(action.sa_mask), UInt64(UInt32(bitPattern: action.sa_flags))]
        }
        var current: sigset_t = 0
        pthread_sigmask(SIG_BLOCK, nil, &current)
        return result + [UInt64(current)]
    }
    let before = snapshot()
    do {
        let status = try TerminalProcessSupervisor.run(executable: "/usr/bin/true", arguments: [], environment: [:]) { _ in }
        precondition(status == 0 && before == snapshot())
        do {
            _ = try TerminalProcessSupervisor.run(executable: "/not/a/real/executable", arguments: [], environment: [:]) { _ in
                preconditionFailure("failed spawn called didStart")
            }
            preconditionFailure("missing executable succeeded")
        } catch { precondition(before == snapshot()) }
        emit(["event": "restored"])
        exit(0)
    } catch { emit(["event": "error", "message": String(describing: error)]); exit(125) }
}
do {
    let status = try TerminalProcessSupervisor.run(executable: args[0], arguments: Array(args.dropFirst()),
        environment: ProcessInfo.processInfo.environment) { child in
        emit(["event": "started", "parent": getpid(), "child": child])
        usleep(30_000)
        emit(["event": "registered"])
    }
    emit(["event": "ended", "status": status, "foreground": tcgetpgrp(0), "group": getpgrp()])
    exit(status)
} catch {
    emit(["event": "error", "message": String(describing: error)])
    exit(125)
}
'''


FIXTURE = r'''
import json, os, signal, sys, time

def emit(event, **fields):
    os.write(1, (json.dumps(dict(event=event, **fields), ensure_ascii=False) + "\n").encode())

interrupts = 0
last_interrupt = None
def interrupt(signum, frame):
    global interrupts, last_interrupt
    now = time.monotonic()
    interrupts += 1
    emit("interrupt", count=interrupts)
    if last_interrupt is not None and now - last_interrupt < 2:
        sys.exit(130)
    last_interrupt = now

signal.signal(signal.SIGINT, interrupt)
signal.signal(signal.SIGWINCH, lambda s, f: emit("resize", size=list(os.get_terminal_size(0))))
signal.signal(signal.SIGCONT, lambda s, f: emit("continued"))
emit("ready", arguments=sys.argv[1:], cwd=os.getcwd(), env=os.environ.get("XI_SUPERVISOR_FIXTURE"),
     tty=[os.isatty(fd) for fd in (0, 1, 2)], pid=os.getpid(), group=os.getpgrp(),
     foreground=os.tcgetpgrp(0) if os.isatty(0) else -1)
for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith("exit="):
        sys.exit(int(line.split("=", 1)[1]))
    if line == "stderr":
        os.write(2, b"fixture-stderr\n")
    else:
        emit("input", value=line)
emit("eof")
'''


def decode_events(data: bytes) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    for line in data.decode(errors="replace").splitlines():
        # PTY 可在 JSON 前回显 ^C/^Z；测试输入本身不以 JSON 开头。
        start = line.find('{"')
        if start >= 0:
            try:
                events.append(json.loads(line[start:]))
            except json.JSONDecodeError:
                pass
    return events


def controller(command: list[str], cwd: Path, env: dict[str, str], background: bool) -> None:
    """在 PTY 会话中扮演交互 shell，真实交接前台组并处理停止/fg。"""
    signal.signal(signal.SIGTTOU, signal.SIG_IGN)
    group = os.getpgrp()
    child = os.fork()
    if child == 0:
        os.setpgid(0, 0)
        os.kill(os.getpid(), signal.SIGSTOP)
        os.chdir(cwd)
        os.execve(command[0], command, env)
    os.waitpid(child, os.WUNTRACED)
    if not background:
        os.tcsetpgrp(0, child)
    os.kill(child, signal.SIGCONT)
    while True:
        _, status = os.waitpid(child, os.WUNTRACED)
        if os.WIFSTOPPED(status):
            foreground = os.tcgetpgrp(0)
            os.tcsetpgrp(0, group)
            os.write(1, (json.dumps({"event": "stopped", "foreground": foreground,
                                   "parent": child, "controller_group": group,
                                   "signal": os.WSTOPSIG(status)}) + "\n").encode())
            if sys.stdin.readline().strip() != "fg":
                os.kill(child, signal.SIGKILL)
                os._exit(124)
            os.tcsetpgrp(0, child)
            os.killpg(child, signal.SIGCONT)
        else:
            foreground = os.tcgetpgrp(0)
            os.tcsetpgrp(0, group)
            code = os.waitstatus_to_exitcode(status)
            os.write(1, (json.dumps({"event": "controller_end", "status": code,
                                   "foreground": foreground, "parent": child}) + "\n").encode())
            os._exit(0)


class TerminalSession:
    def __init__(self, command: list[str], cwd: Path, env: dict[str, str], *, background: bool = False):
        self.pid, self.master = pty.fork()
        if self.pid == 0:
            try:
                controller(command, cwd, env, background)
            finally:
                os._exit(124)
        self.data = b""
        self.events: list[dict[str, Any]] = []
        self.closed = False

    def pump(self, duration: float = 0.05) -> None:
        if select.select([self.master], [], [], duration)[0]:
            try:
                chunk = os.read(self.master, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                chunk = b""
            self.data += chunk
            self.events = decode_events(self.data)

    def wait(self, event: str, *, timeout: float = 5, count: int = 1) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            matching = [item for item in self.events if item.get("event") == event]
            if len(matching) >= count:
                return matching[count - 1]
            self.pump()
        raise AssertionError(f"missing {event}: {self.data!r}")

    def send(self, data: bytes) -> None:
        os.write(self.master, data)

    def quiet(self, duration: float = 0.2) -> None:
        deadline = time.monotonic() + duration
        while time.monotonic() < deadline:
            self.pump(min(0.05, deadline - time.monotonic()))

    def finish(self, status: int) -> None:
        ended = self.wait("ended")
        shell = self.wait("controller_end")
        assert ended["status"] == status and shell["status"] == status, self.events
        assert ended["foreground"] == ended["group"], self.events
        assert shell["foreground"] == shell["parent"], self.events
        started = self.wait("started")
        try:
            os.kill(started["child"], 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError("direct child survived supervisor exit")

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        # 失败路径也只回收本测试明确启动的进程组，避免遗留停止作业。
        for event in self.events:
            for key in ("child", "parent"):
                if event.get("event") == "started" and key in event:
                    try:
                        os.killpg(event[key], signal.SIGKILL)
                    except ProcessLookupError:
                        pass
        try:
            os.kill(self.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.waitpid(self.pid, 0)
        os.close(self.master)

    def __enter__(self) -> TerminalSession:
        return self

    def __exit__(self, *args: Any) -> None:
        self.close()


def verify(harness: Path, fixture: Path, directory: Path) -> list[str]:
    passed: list[str] = []
    special = ["中文 空格", "'单引号'与\"双引号\"", "换\n行", "$(touch must-not-exist)", "", "--"]
    env = dict(os.environ, XI_SUPERVISOR_FIXTURE="环境\n'\"$()")
    command = [str(harness), sys.executable, str(fixture), *special]
    for code in (0, 7, 127, 255):
        result = subprocess.run(command, input=f"stderr\nexit={code}\n", text=True,
                                capture_output=True, cwd=directory, env=env, timeout=5)
        events = decode_events(result.stdout.encode())
        ready = next(event for event in events if event["event"] == "ready")
        assert result.returncode == code, (result.returncode, result.stderr)
        assert ready["arguments"] == special and ready["tty"] == [False] * 3, ready
        assert ready["cwd"] == str(directory.resolve()) and ready["env"] == env["XI_SUPERVISOR_FIXTURE"]
        assert "fixture-stderr" in result.stderr and "fixture-stderr" not in result.stdout
        assert not (directory / "must-not-exist").exists()
    passed.append("pipe: argv/env/cwd/stdin/stdout/stderr + exit 0/7/127/255")

    result = subprocess.run([str(harness), str(directory / "missing")], capture_output=True, timeout=5)
    assert result.returncode == 125 and b'"event":"started"' not in result.stderr, result
    passed.append("spawn failure: no start callback")

    result = subprocess.run([str(harness), "--verify-restoration"], capture_output=True, timeout=5)
    assert result.returncode == 0 and b'"event":"restored"' in result.stderr, result
    passed.append("normal/failed spawn: original signal dispositions and mask restored")

    with TerminalSession(command, directory, env) as session:
        ready = session.wait("ready")
        assert ready["tty"] == [True] * 3 and ready["group"] == ready["foreground"], ready
        assert ready["arguments"] == special and ready["cwd"] == str(directory.resolve()), ready
        events = [event["event"] for event in session.events]
        assert events.index("registered") < events.index("ready"), session.events
        session.send("中文终端输入\n".encode())
        assert session.wait("input")["value"] == "中文终端输入"
        session.send(b"\x03")
        assert session.wait("interrupt")["count"] == 1
        session.quiet()
        assert len([event for event in session.events if event["event"] == "interrupt"]) == 1
        assert not any(event["event"] == "ended" for event in session.events), session.events
        session.send(b"exit=7\n")
        session.finish(7)
    passed.append("PTY: real tty + registration before execution + one Ctrl-C once + restore")

    with TerminalSession(command, directory, env) as session:
        session.wait("ready")
        session.send(b"\x03")
        session.wait("interrupt")
        session.send(b"\x03")
        assert session.wait("interrupt", count=2)["count"] == 2
        session.finish(130)
    passed.append("PTY: two Ctrl-C reach child twice")

    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        with TerminalSession(command, directory, env) as session:
            session.wait("ready")
            started = session.wait("started")
            os.kill(started["parent"], number)
            if number == signal.SIGINT:
                assert session.wait("interrupt")["count"] == 1
                session.quiet()
                assert len([event for event in session.events if event["event"] == "interrupt"]) == 1
                session.send(b"exit=0\n")
                session.finish(0)
            else:
                session.finish(128 + number)
    passed.append("PTY: directed parent INT/TERM/HUP + child signal exit status")

    with TerminalSession(command, directory, env) as session:
        session.wait("ready")
        session.send(b"\x1a")
        stopped = session.wait("stopped")
        assert stopped["foreground"] == stopped["parent"], stopped
        session.send(b"fg\n")
        session.wait("continued")
        session.send(b"after-fg\n")
        assert session.wait("input")["value"] == "after-fg"
        session.quiet()
        assert len([event for event in session.events if event["event"] == "continued"]) == 1
        session.send(b"exit=0\n")
        session.finish(0)
    passed.append("PTY: Ctrl-Z + actual stopped supervisor + fg + one child continue")

    with TerminalSession(command, directory, env, background=True) as session:
        ready = session.wait("ready")
        assert ready["group"] != ready["foreground"], ready
        stopped = session.wait("stopped")
        assert stopped["foreground"] == stopped["controller_group"], stopped
        session.send(b"fg\n")
        session.wait("continued")
        session.send(b"background-to-fg\n")
        assert session.wait("input")["value"] == "background-to-fg"
        session.send(b"exit=0\n")
        session.finish(0)
    passed.append("PTY: background start does not steal tty + SIGTTIN stop + fg")

    with TerminalSession(command, directory, env) as session:
        started = session.wait("started")
        os.kill(started["parent"], signal.SIGTERM)
        session.finish(143)
    passed.append("PTY: directed termination during didStart is retained")

    with TerminalSession(command, directory, env) as session:
        session.wait("ready")
        fcntl.ioctl(session.master, termios.TIOCSWINSZ, struct.pack("HHHH", 42, 123, 0, 0))
        assert session.wait("resize")["size"] == [123, 42]
        session.send(b"\x04")
        session.wait("eof")
        session.finish(0)
    passed.append("PTY: kernel resize reaches foreground child + Ctrl-D EOF")
    return passed


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--harness", type=Path, help="复用按本文件 HARNESS 编译的可执行文件")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("该监督器使用 macOS posix_spawn/kqueue，需在 macOS 验证")
    with tempfile.TemporaryDirectory(prefix="xi-terminal-", dir="/tmp") as temporary:
        directory = Path(temporary).resolve()
        fixture = directory / "fixture.py"
        fixture.write_text(FIXTURE)
        harness = args.harness.resolve() if args.harness else directory / "harness"
        if args.harness is None:
            main_file = directory / "main.swift"
            main_file.write_text(HARNESS)
            source = Path(__file__).resolve().parents[1] / "Sources/DIBridge/TerminalProcessSupervisor.swift"
            subprocess.run(["swiftc", "-swift-version", "5", str(source), str(main_file), "-o", str(harness)],
                           check=True, timeout=60)
        for result in verify(harness, fixture, directory):
            print("PASS", result)


if __name__ == "__main__":
    main()
