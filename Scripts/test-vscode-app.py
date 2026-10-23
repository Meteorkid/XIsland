#!/usr/bin/env python3
"""使用新构建的隔离 XIsland 验证 companion → socket → 会话状态；不启动厂商客户端。"""
from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid


def verify(repository: Path, app: Path) -> dict:
    with (app / 'Contents/Info.plist').open('rb') as file:
        binary = app / 'Contents/MacOS' / plistlib.load(file)['CFBundleExecutable']
    # 旧二进制不包含测试启动隔离修复；不自动启动过期构建。
    sources = list((repository / 'Sources/DynamicIsland').rglob('*.swift'))
    assert binary.stat().st_mtime >= max(path.stat().st_mtime for path in sources), '请先重新构建包含测试隔离修复的应用'
    bridge_binary = app / 'Contents/MacOS/di-bridge'
    assert bridge_binary.stat().st_mtime >= max(path.stat().st_mtime for path in (repository / 'Sources/DIBridge').glob('*.swift')), '请先重新构建原生观察入口'
    extension = repository / 'Sources/XIslandVSCode'
    suite = 'dev.xisland.tests.vscode-' + uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix='xi-vsc-app-', dir='/tmp') as folder:
        root = Path(folder).resolve()
        diagnostics = root / 'diagnostics.json'
        # 让 Foundation 对 runtime 和 diagnostics 都解析已存在路径，避免 /tmp 别名分歧。
        diagnostics.write_text('{}')
        bridge = root / 'bin/di-bridge'
        bridge.parent.mkdir(mode=0o700)
        shutil.copy2(bridge_binary, bridge)
        bridge.chmod(0o700)
        env = {key: value for key, value in os.environ.items() if not key.startswith('X_ISLAND_TEST_')}
        env.update({'X_ISLAND_TEST_MODE': '1', 'X_ISLAND_TEST_RUNTIME_DIR': str(root),
                    'X_ISLAND_TEST_DEFAULTS_SUITE': suite, 'X_ISLAND_TEST_ENFORCE_PEER_AUTH': '1',
                    'X_ISLAND_TEST_DIAGNOSTICS_PATH': str(diagnostics),
                    'X_ISLAND_DISABLE_ANIMATIONS': '1'})
        subprocess.run(['node', str(extension / 'node_modules/typescript/bin/tsc'), '-p', str(extension),
                        '--outDir', str(root / 'js')], check=True, timeout=30)
        namespace = 'a' * 24
        instances = {agent: str(uuid.uuid4()) for agent in ['roo_code', 'pearai']}
        def source(agent):
            return f'{agent}-{namespace}-{instances[agent]}'
        def session(agent, task):
            return source(agent) + '-' + base64.urlsafe_b64encode(task.encode()).decode().rstrip('=')
        tasks = [(session(agent, f'{agent}-socket-{index}'), agent, f'{agent}-socket-{index}')
                 for agent in instances for index in range(8)]
        sequences = {agent: 0 for agent in instances}
        timestamp = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        messages = []
        for identifier, agent, native_task in tasks:
            base = {'sessionId': identifier, 'agentType': agent, 'terminal': 'Visual Studio Code',
                    'timestamp': timestamp, 'statusIsAssistantReply': False, 'sourceNamespace': namespace,
                    'sourceInstanceId': instances[agent], 'nativeTaskId': native_task}
            for fields in [{'type': 'session_start', 'prompt': identifier},
                           {'type': 'status_update', 'observedState': 'active'},
                           {'type': 'status_update', 'observedState': 'idle'}]:
                sequences[agent] += 1
                messages.append({**base, **fields, 'observationSequence': sequences[agent]})
        (root / 'messages.json').write_text(json.dumps(messages))
        sender = root / 'sender.cjs'
        sender.write_text(r'''
const fs = require('node:fs');
const { ObservationTransport } = require('./js/transport');
const transport = new ObservationTransport(process.argv[2], () => {}, 20, undefined, process.argv[5]);
for (const message of JSON.parse(fs.readFileSync(process.argv[3], 'utf8'))) transport.send(message);
const timer = setInterval(() => {
    if (!fs.existsSync(process.argv[4])) return;
    clearInterval(timer); transport.dispose();
}, 20);
const timeout = setTimeout(() => { clearInterval(timer); transport.dispose(); process.exitCode = 1; }, 15000);
timeout.unref();
''')
        sender_process = None
        with (root / 'app.log').open('wb') as log:
            app_process = subprocess.Popen([str(binary), '--ui-test-mode', '--ui-test-socket', '--fixture-path',
                                            str(repository / 'Tests/Fixtures/app/empty-interaction.json')],
                                           env=env, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 15
                while True:
                    assert app_process.poll() is None and time.monotonic() < deadline, (
                        f'隔离应用未就绪 (exit={app_process.poll()}): ' + (root / 'app.log').read_text(errors='replace')[-6000:])
                    try:
                        initial = json.loads(diagnostics.read_text())
                    except (OSError, json.JSONDecodeError):
                        initial = {}
                    if (root / 'di.sock').exists() and isinstance(initial.get('visibleSessions'), list) and isinstance(initial.get('handledMessageCount'), int):
                        break
                    time.sleep(.05)
                assert initial['visibleSessions'] == [], '必须从空 fixture 开始'
                # 负例保持 Node 连接直至服务端关闭，不能因发送方先退出而误判身份拒绝。
                direct = {'type': 'session_start', 'sessionId': 'forbidden-direct-node', 'agentType': 'roo_code',
                          'timestamp': '2026-10-09T00:00:00Z', 'prompt': 'must not be accepted'}
                subprocess.run(['node', '-e', r'''
const net = require('node:net');
const socket = net.createConnection(process.argv[1]);
let connected = false;
const timer = setTimeout(() => { socket.destroy(); process.exitCode = 1; }, 2000);
socket.on('connect', () => { connected = true; socket.write(process.argv[2] + '\n'); });
socket.on('error', () => {});
socket.on('close', () => { clearTimeout(timer); if (!connected) process.exitCode = 1; });
''', str(root / 'di.sock'), json.dumps(direct)], check=True, timeout=3)
                negative_deadline = time.monotonic() + 0.5
                while time.monotonic() < negative_deadline:
                    assert json.loads(diagnostics.read_text())['visibleSessions'] == [], '严格 peer 检查仍接受直接 Node 连接'
                    time.sleep(.05)
                sender_process = subprocess.Popen(['node', str(sender), str(root / 'di.sock'),
                                                   str(root / 'messages.json'), str(root / 'done'), str(bridge)])
                deadline = time.monotonic() + 12
                snapshot = initial
                while time.monotonic() < deadline:
                    assert app_process.poll() is None, '隔离应用提前退出'
                    snapshot = json.loads(diagnostics.read_text())
                    rows = {item['id']: item for item in snapshot['visibleSessions']}
                    if len(rows) == len(tasks) and all(rows.get(identifier, {}).get('status') == 'idle'
                                                     and rows[identifier]['agentType'] == agent
                                                     and rows[identifier]['prompt'] == identifier
                                                     and rows[identifier]['nativeTaskId'] == native_task
                                                     for identifier, agent, native_task in tasks):
                        break
                    time.sleep(.05)
                else:
                    raise AssertionError('未收到所有任务的最终状态: ' + json.dumps(snapshot, ensure_ascii=False))
                (root / 'done').touch()
                assert sender_process.wait(timeout=3) == 0
            finally:
                for process in [sender_process, app_process]:
                    if process and process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=3)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=3)
                # 只清理本脚本随机生成的测试偏好域。
                subprocess.run(['defaults', 'delete', suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return {'sentEvents': len(messages), 'verifiedSessions': len(tasks), 'finalStatus': 'idle',
            'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'bridgeSHA256': hashlib.sha256(bridge_binary.read_bytes()).hexdigest(),
            'strictPeerAuthentication': True, 'directNodeRejected': True,
            'transportSHA256': hashlib.sha256((extension / 'src/transport.ts').read_bytes()).hexdigest(),
            'scope': 'Compiled companion transport -> native di-bridge -> strict-peer isolated app SocketServer -> SessionManager -> diagnostics',
            'realClientVerified': False, 'vendorClientLaunched': False}


if __name__ == '__main__':
    repository = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser()
    parser.add_argument('--app-path', type=Path, default=repository / '.build/X Island.app')
    parser.add_argument('--report', type=Path)
    arguments = parser.parse_args()
    try:
        result = verify(repository, arguments.app_path.resolve(strict=True))
    except Exception as error:
        if arguments.report:
            arguments.report.write_text(json.dumps({'passed': False, 'error': str(error),
                'realClientVerified': False}, ensure_ascii=False, indent=2) + '\n')
        raise
    encoded = json.dumps(result, ensure_ascii=False, indent=2)
    if arguments.report:
        arguments.report.write_text(encoded + '\n')
    print(encoded)
