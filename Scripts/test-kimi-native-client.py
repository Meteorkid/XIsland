#!/usr/bin/env python3
"""隔离 Kimi Code 2.1.1 ACP → 原生 hooks → 包内 bridge → XIsland/只读 SQLite。

只连接 127.0.0.1 mock；审批仅返回 reject。调用者必须提供已审查的 sandbox
profile 和本次专用 runtime；本脚本不会生成信任记录、放宽沙箱或安装依赖。
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import signal
import sqlite3
import subprocess
import sys
import threading
import time
from typing import Any, Callable
import uuid


TOTAL_TIMEOUT = 180
REJECTION_TEXT = 'was not run because the user rejected the approval request'


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def digest(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else hashlib.sha256(stream.read()).hexdigest()


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None


class Evidence:
    def __init__(self, directory: Path) -> None:
        self.directory = directory
        self.condition = threading.Condition()
        self.hooks: list[dict[str, Any]] = []
        self.responses: dict[int, dict[str, Any]] = {}
        self.permissions: list[dict[str, Any]] = []
        self.updates: list[dict[str, Any]] = []
        self.errors: list[str] = []
        self.phase = ''
        self.main_requests: dict[str, int] = {}
        self.tool_command = ''
        self.gates: dict[str, threading.Event] = {}
        self.closing = False

    def record(self, name: str, value: dict[str, Any]) -> None:
        with self.condition:
            with (self.directory / (name + '.jsonl')).open('a') as stream:
                stream.write(json.dumps({'time': time.time(), **value}, ensure_ascii=False) + '\n')
            self.condition.notify_all()

    def fail(self, error: BaseException) -> None:
        with self.condition:
            self.errors.append(str(error))
            self.condition.notify_all()


def create_server(evidence: Evidence, port: int) -> ThreadingHTTPServer:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args: Any) -> None:
            pass

        def do_POST(self) -> None:
            try:
                size = int(self.headers.get('Content-Length', '0'))
                require(0 < size <= 8 * 1024 * 1024, '本地请求大小异常')
                body = json.loads(self.rfile.read(size))
                if self.path == '/hook-receipt':
                    require(isinstance(body, dict) and isinstance(body.get('rawPayload'), str), 'hook receipt 格式异常')
                    body['payload'] = json.loads(body['rawPayload'])
                    with evidence.condition:
                        receipt = {**body, 'consumed': False}
                        evidence.hooks.append(receipt)
                        evidence.record('native-hooks', body)
                    output = b'{}'
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', str(len(output)))
                    self.end_headers()
                    self.wfile.write(output)
                    return
                require(self.path == '/v1/chat/completions', 'mock 不支持路径：' + self.path)
                require(body.get('stream') is True and body.get('model') == 'mock-model', '模型请求契约异常')
                require(self.headers.get('Authorization') == 'Bearer local-mock-only', '出现非测试凭据')
                with evidence.condition:
                    phase = evidence.phase
                    # 标题生成等内部请求没有工具，不参与主回合的放行时序。
                    main = bool(body.get('tools'))
                    index = evidence.main_requests.get(phase, 0) + 1 if main else 0
                    if main:
                        evidence.main_requests[phase] = index
                    evidence.record('mock-requests', {'path': self.path, 'phase': phase,
                        'mainRequest': main, 'index': index, 'body': body})
                    gate = evidence.gates.get(phase + (':turn' if index == 1 else ':result')) if main else None
                if gate is not None:
                    require(gate.wait(30), 'mock 等待真实 hook 检查超时')
                require(not evidence.closing, '测试正在退出')
                tool_call = main and phase == 'reject' and index == 1
                if tool_call:
                    names = {item.get('function', {}).get('name') for item in body['tools']}
                    require('Bash' in names, '原生请求未提供 Bash 工具')
                    delta = {'tool_calls': [{'index': 0, 'id': 'native_reject_probe', 'type': 'function',
                        'function': {'name': 'Bash', 'arguments': json.dumps({'command': evidence.tool_command})}}]}
                else:
                    delta = {'role': 'assistant', 'content': 'KIMI_NATIVE_HOOK_OK'}
                if main and phase == 'reject' and index > 1:
                    require(index == 2, '拒绝测试出现额外模型回合')
                    tool_messages = [item for item in body['messages'] if item.get('role') == 'tool']
                    require(len(tool_messages) == 1 and tool_messages[0].get('tool_call_id') == 'native_reject_probe',
                            '拒绝后模型请求缺少对应的唯一原生工具结果')
                    require(REJECTION_TEXT in str(tool_messages[0].get('content')), '模型收到的不是明确未执行的拒绝结果')
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Cache-Control', 'no-cache')
                self.end_headers()
                common = {'id': 'mock-' + uuid.uuid4().hex, 'object': 'chat.completion.chunk',
                          'created': int(time.time()), 'model': 'mock-model'}
                chunks = [
                    {**common, 'choices': [{'index': 0, 'delta': delta, 'finish_reason': None}]},
                    {**common, 'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'tool_calls' if tool_call else 'stop'}]},
                    {**common, 'choices': [], 'usage': {'prompt_tokens': 32, 'completion_tokens': 8, 'total_tokens': 40}},
                ]
                for chunk in chunks:
                    self.wfile.write(('data: ' + json.dumps(chunk) + '\n\n').encode())
                self.wfile.write(b'data: [DONE]\n\n')
                self.wfile.flush()
            except (AssertionError, OSError, ValueError, KeyError) as error:
                if not evidence.closing:
                    evidence.fail(error)
                self.close_connection = True
                try:
                    self.send_error(500, 'local mock failed')
                except OSError:
                    pass

    server = ThreadingHTTPServer(('127.0.0.1', port), Handler)
    server.daemon_threads = True
    return server


HOOK_RECORDER = r'''import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
const rawPayload = fs.readFileSync(0, 'utf8');
const payload = JSON.parse(rawPayload);
const argv = process.argv.slice(2);
const expected = ['--agent', 'kimi', '--adapter', 'kimi_code', '--hook', payload.hook_event_name];
if (JSON.stringify(argv) !== JSON.stringify(expected)) throw new Error('generated hook argv mismatch');
const result = spawnSync(process.env.XI_NATIVE_BRIDGE,
  argv, { input: rawPayload, encoding: 'utf8', timeout: 2500, env: process.env });
const receipt = { rawPayload, argv, pid: process.pid, parentPid: process.ppid,
  bridge: { returncode: result.status, signal: result.signal, stdout: result.stdout || '',
    stderr: result.stderr || '', error: result.error?.message } };
const response = await fetch(process.env.XI_NATIVE_RECEIPT_URL, { method: 'POST',
  headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(receipt),
  signal: AbortSignal.timeout(1500) });
if (!response.ok || result.status !== 0 || result.stdout !== '') process.exitCode = 1;
'''


class NativeProbe:
    def __init__(self, args: argparse.Namespace, report: dict[str, Any]) -> None:
        self.args, self.report = args, report
        self.root = Path(__file__).resolve().parent.parent
        self.runtime = args.runtime.resolve(strict=True)
        require(self.runtime.is_dir() and not args.runtime.is_symlink(), 'runtime 必须是已有真实目录')
        require(self.runtime.stat().st_uid == os.getuid(), 'runtime 不属于当前测试用户')
        self.run = self.runtime / ('native-' + uuid.uuid4().hex[:10])
        self.run.mkdir(mode=0o700)
        self.evidence = Evidence(self.run)
        self.processes: list[subprocess.Popen] = []
        self.logs: list[Any] = []
        self.app_process: subprocess.Popen | None = None
        self.client: subprocess.Popen | None = None
        self.server: ThreadingHTTPServer | None = None
        self.sequence = 0
        self.initial_handled = 0
        self.expected: dict[str, str] = {}
        self.prompts: dict[str, str] = {}
        self.suite = 'dev.xisland.tests.kimi-native-' + uuid.uuid4().hex
        self.diagnostics = self.runtime / 'diagnostics.json'
        self.history = self.runtime / 'history.store'
        require(not self.diagnostics.exists() and not self.history.exists(), 'runtime 已有应用测试数据')
        self.socket = self.runtime / 'di.sock'
        require(not self.socket.exists(), 'runtime/di.sock 已被占用，请使用专用空闲 runtime')
        require(len(os.fsencode(self.socket)) < 104, 'runtime 路径过长，Unix socket 无法绑定')
        report.update(runtimeDirectory=str(self.runtime), evidenceDirectory=str(self.run),
                      defaultsSuite=self.suite, checks=[])

    def wait(self, check: Callable[[], Any], description: str, timeout: float = 20) -> Any:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            require(not self.evidence.errors, '后台验证失败：' + '; '.join(self.evidence.errors))
            for process in self.processes:
                require(process.poll() is None, f'测试进程已退出 ({process.pid})：{description}')
            result = check()
            if result:
                return result
            with self.evidence.condition:
                self.evidence.condition.wait(min(0.05, max(0, deadline - time.monotonic())))
        raise AssertionError('等待超时：' + description)

    def spawn(self, command: list[str], env: dict[str, str], log_name: str, acp: bool = False) -> subprocess.Popen:
        log = (self.run / log_name).open('wb')
        self.logs.append(log)
        process = subprocess.Popen(command, env=env, cwd=self.run / 'workspace',
            stdin=subprocess.PIPE if acp else subprocess.DEVNULL,
            stdout=subprocess.PIPE if acp else log, stderr=log, start_new_session=True)
        self.processes.append(process)
        return process

    def prepare(self) -> None:
        args = self.args
        for name in ('workspace', 'home', 'kimi', 'share', 'tmp', 'xdg-config', 'xdg-cache', 'xdg-data', 'xdg-state', 'xdg-runtime'):
            (self.run / name).mkdir(mode=0o700)
        spec = importlib.util.spec_from_file_location('xisland_finality_helpers', self.root / 'Scripts/test-main-finality-app.py')
        require(spec is not None and spec.loader is not None, '无法加载现有构建新鲜度检查器')
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        original = args.app.resolve(strict=True)
        with (original / 'Contents/Info.plist').open('rb') as stream:
            executable = plistlib.load(stream)['CFBundleExecutable']
        require(isinstance(executable, str) and Path(executable).name == executable, '非法应用主程序名')
        self.report['freshness'] = {
            'app': helper.verify_freshness(self.root, original / 'Contents/MacOS' / executable, 'DynamicIsland'),
            'bridge': helper.verify_freshness(self.root, original / 'Contents/MacOS/di-bridge', 'DIBridge')}
        if original.is_relative_to(self.runtime):
            app = original
        else:
            app = self.run / original.name
            shutil.copytree(original, app, symlinks=True)
        self.binary = app / 'Contents/MacOS' / executable
        self.bridge = app / 'Contents/MacOS/di-bridge'
        for path in (self.binary, self.bridge):
            require(path.resolve().is_relative_to(self.runtime), '运行的应用/桥接不能指向 runtime 外部')
        self.report.update(appPath=str(app), appSHA256=digest(self.binary), bridgeSHA256=digest(self.bridge),
            bundlePath=str(args.bundle), bundleSHA256=digest(args.bundle), nodePath=str(args.node),
            nodeSHA256=digest(args.node), sandboxProfile=str(args.sandbox_profile),
            sandboxProfileSHA256=digest(args.sandbox_profile))
        shutil.copyfile(self.root / 'Tests/Fixtures/app/empty-interaction.json', self.run / 'empty-fixture.json')
        self.server = create_server(self.evidence, args.port)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        port = self.server.server_address[1]
        self.report['mockPort'] = port
        recorder = self.run / 'hook-recorder.mjs'
        recorder.write_text(HOOK_RECORDER)
        wrapper = self.runtime / 'hook-recorder'
        wrapper.write_text('#!/bin/sh\nexec ' + shlex.join([str(args.node), str(recorder)]) + ' "$@"\n')
        wrapper.chmod(0o700)
        block = args.hooks_block.read_text()
        events = re.findall(r'^event = "([A-Za-z]+)"$', block, re.MULTILINE)
        require(len(events) == 20 and len(set(events)) == 20, '必须提供产品生成的20-hook区块')
        require(block.count('timeout = 5') == 20 and str(wrapper) in block, '产品区块timeout或recorder路径不符')
        self.report.update(hooksBlockPath=str(args.hooks_block), hooksBlockSHA256=digest(args.hooks_block),
            configuredHookEvents=events, configurationSource='caller-generated KimiHookConfiguration.Runtime.node block',
            hookInstrumentation='Only generated bridge executable path points to an argv-preserving recorder',
            stageGating='Mock responses and ACP reject are gated; native hook delivery is not reordered; production concurrency is not verified')
        config = '\n'.join([
            'default_model = "mock"', 'default_permission_mode = "manual"', 'telemetry = false',
            '[providers.local_mock]', 'type = "openai"', 'model_source = "static"',
            f'base_url = "http://127.0.0.1:{port}/v1"', 'api_key = "local-mock-only"',
            '[models.mock]', 'provider = "local_mock"', 'model = "mock-model"',
            'max_context_size = 32768', 'capabilities = ["tool_use"]',
            '[[permission.rules]]', 'decision = "ask"', 'scope = "user"', 'pattern = "Bash"',
        ])
        (self.run / 'kimi/config.toml').write_text(config + '\n' + block)
        self.canary = self.run / 'tool-must-not-execute'
        self.evidence.tool_command = 'printf KIMI_NATIVE_APPROVAL_PROBE > ' + shlex.quote(str(self.canary))
        self.client_env = {
            'PATH': str(args.node.parent) + ':/usr/bin:/bin:/usr/sbin:/sbin',
            'HOME': str(self.run / 'home'), 'KIMI_CODE_HOME': str(self.run / 'kimi'),
            'KIMI_SHARE_DIR': str(self.run / 'share'), 'TMPDIR': str(self.run / 'tmp') + '/',
            'XDG_CONFIG_HOME': str(self.run / 'xdg-config'), 'XDG_CACHE_HOME': str(self.run / 'xdg-cache'),
            'XDG_DATA_HOME': str(self.run / 'xdg-data'), 'XDG_STATE_HOME': str(self.run / 'xdg-state'),
            'XDG_RUNTIME_DIR': str(self.run / 'xdg-runtime'), 'SHELL': '/bin/sh',
            'LANG': 'en_US.UTF-8', 'TERM': 'dumb', 'NO_COLOR': '1',
            'KIMI_CODE_NO_AUTO_UPDATE': '1', 'KIMI_DISABLE_TELEMETRY': '1', 'KIMI_DISABLE_CRON': '1',
            'KIMI_CODE_SEARCH_WORKER': '0', 'KIMI_CODE_PERSISTENCE_MINIDB_READMODEL': '0',
            'DI_SOCKET_PATH': str(self.socket), 'XI_NATIVE_BRIDGE': str(self.bridge),
            'XI_NATIVE_RECEIPT_URL': f'http://127.0.0.1:{port}/hook-receipt',
        }
        self.report['clientEnvironment'] = self.client_env.copy()

    def start(self) -> None:
        app_env = {key: value for key, value in os.environ.items() if not key.startswith('X_ISLAND_TEST_')}
        for key in ('DI_SESSION_ID', 'DI_BRIDGE_DEBUG_LOG', 'DI_SOCKET_PATH'):
            app_env.pop(key, None)
        # Foundation 对已有 /private/tmp 目录与尚未创建的文件解析不同；统一使用 /tmp 别名。
        app_runtime = str(self.runtime).replace('/private/tmp/', '/tmp/', 1)
        app_env.update(X_ISLAND_TEST_MODE='1', X_ISLAND_TEST_RUNTIME_DIR=app_runtime,
            X_ISLAND_TEST_DEFAULTS_SUITE=self.suite, X_ISLAND_TEST_DIAGNOSTICS_PATH=app_runtime + '/diagnostics.json',
            X_ISLAND_DISABLE_ANIMATIONS='1', DI_SOCKET_PATH=str(self.socket))
        self.app_process = self.spawn([str(self.binary), '--ui-test-mode', '--ui-test-socket',
            '--fixture-path', str(self.run / 'empty-fixture.json')], app_env, 'app.log')
        self.wait(lambda: self.socket.exists() and read_json(self.diagnostics), '隔离应用启动')
        state = read_json(self.diagnostics)
        require(state['visibleSessions'] == [], '隔离应用不是空会话')
        require(isinstance(state.get('handledMessageCount'), int), '缺少应用处理完成计数')
        self.initial_handled = state['handledMessageCount']
        self.client = self.spawn(['/usr/bin/sandbox-exec', '-f', str(self.args.sandbox_profile),
            str(self.args.node), str(self.args.bundle), 'acp'], self.client_env, 'client.stderr.log', acp=True)
        self.report.update(vendorClientLaunched=True, appProcessId=self.app_process.pid, clientProcessId=self.client.pid)
        threading.Thread(target=self.read_acp, daemon=True).start()
        response = self.response(self.send('initialize', {'protocolVersion': 1,
            'clientInfo': {'name': 'xisland-native-probe', 'version': '1.0'}, 'clientCapabilities': {}}))
        require(response['result'].get('protocolVersion') == 1, 'ACP 协议版本不符')

    def read_acp(self) -> None:
        try:
            require(self.client is not None and self.client.stdout is not None, '客户端 stdout 不可用')
            for raw in self.client.stdout:
                message = json.loads(raw)
                self.evidence.record('acp', {'direction': 'client-to-driver', 'raw': raw.decode(), 'message': message})
                with self.evidence.condition:
                    if 'method' in message and 'id' in message:
                        require(message['method'] == 'session/request_permission', '出现未支持的原生请求：' + message['method'])
                        self.evidence.permissions.append(message)
                    elif 'id' in message:
                        self.evidence.responses[message['id']] = message
                    elif message.get('method') == 'session/update':
                        self.evidence.updates.append(message['params'])
                    self.evidence.condition.notify_all()
        except (AssertionError, OSError, ValueError) as error:
            if not self.evidence.closing:
                self.evidence.fail(error)

    def write_acp(self, message: dict[str, Any]) -> None:
        require(self.client is not None and self.client.stdin is not None, '客户端 stdin 不可用')
        self.evidence.record('acp', {'direction': 'driver-to-client', 'message': message})
        self.client.stdin.write((json.dumps(message) + '\n').encode())
        self.client.stdin.flush()

    def send(self, method: str, params: dict[str, Any]) -> int:
        self.sequence += 1
        self.write_acp({'jsonrpc': '2.0', 'id': self.sequence, 'method': method, 'params': params})
        return self.sequence

    def response(self, request_id: int) -> dict[str, Any]:
        result = self.wait(lambda: self.evidence.responses.get(request_id), f'ACP response {request_id}')
        require('error' not in result, 'ACP 请求失败：' + json.dumps(result, ensure_ascii=False))
        return result

    def hook(self, event: str, native_id: str | None = None) -> dict[str, Any]:
        def find() -> dict[str, Any] | None:
            with self.evidence.condition:
                for receipt in self.evidence.hooks:
                    payload = receipt['payload']
                    if not receipt['consumed'] and payload.get('hook_event_name') == event and (native_id is None or payload.get('session_id') == native_id):
                        receipt['consumed'] = True
                        return receipt
            return None
        receipt = self.wait(find, '真实 hook ' + event)
        require(receipt['bridge']['returncode'] == 0 and receipt['bridge']['stdout'] == '', 'bridge 失败或产生审批输出')
        payload = receipt['payload']
        require(payload.get('client_type') == 'kimi_code_cli', '原生客户端来源字段不符')
        require(payload.get('cwd') == str(self.run / 'workspace'), '原生工作目录逸出隔离空间')
        return receipt

    def stored(self) -> dict[str, Any] | None:
        if not self.history.exists():
            return None
        try:
            with sqlite3.connect(self.history.as_uri() + '?mode=ro', uri=True, timeout=0.2) as db:
                columns = {row[1] for row in db.execute('PRAGMA table_info(ZSTOREDSESSION)')}
                require({'ZSESSIONID', 'ZAGENTTYPERAW', 'ZSTATUSRAW', 'ZCOMPLETEDAT', 'ZKIMICODEAPPROVALOBSERVATIONDATA'} <= columns,
                        '历史 schema 已改变')
                rows = db.execute('SELECT ZSESSIONID,ZAGENTTYPERAW,ZSTATUSRAW,ZCOMPLETEDAT,ZKIMICODEAPPROVALOBSERVATIONDATA FROM ZSTOREDSESSION').fetchall()
                messages = db.execute('SELECT s.ZSESSIONID,c.ZCONTENT FROM ZSTOREDCHATMESSAGE c JOIN ZSTOREDSESSION s ON c.ZSESSION=s.Z_PK WHERE c.ZROLE=?', ('user',)).fetchall()
                tools = db.execute('SELECT s.ZSESSIONID,t.ZTOOL,t.ZTOOLCALLID,t.ZISCOMPLETE,t.ZRESULT FROM ZSTOREDTOOLEVENT t JOIN ZSTOREDSESSION s ON t.ZSESSION=s.Z_PK').fetchall()
            return {'sessions': {row[0]: {'agent': row[1], 'status': row[2], 'completedAt': row[3],
                'approval': json.loads(row[4]) if row[4] is not None else None} for row in rows},
                'userMessages': {sid: [content for key, content in messages if key == sid] for sid in self.expected},
                'tools': [{'sessionId': row[0], 'tool': row[1], 'toolCallId': row[2], 'isComplete': bool(row[3]), 'result': row[4]} for row in tools]}
        except sqlite3.OperationalError as error:
            if 'locked' in str(error):
                return None
            raise

    def checkpoint(self, stage: str, receipt: dict[str, Any], status: str, pending: list[str] | None = None) -> None:
        sid = 'kimi_code-' + receipt['payload']['session_id']
        self.expected[sid] = status

        def matches() -> dict[str, Any] | None:
            state = read_json(self.diagnostics)
            if state is None or state.get('handledMessageCount', -1) < self.initial_handled + len(self.evidence.hooks):
                return None
            rows = {row['id']: row for row in state['visibleSessions']}
            if {key: row['status'] for key, row in rows.items()} != self.expected:
                return None
            require(len(rows) == len(state['visibleSessions']), '重复会话')
            require(state.get('pendingInteraction') is None, '原生审批观察被误报为 App 可操作交互')
            for key, row in rows.items():
                require(row['agentType'] == 'kimi' and row.get('pendingInteraction') is None, '来源或交互异常')
                require((row.get('completedAt') is not None) == (self.expected[key] == 'completed'), '完成时间不符')
            stored = self.stored()
            if stored is None or {key: row['status'] for key, row in stored['sessions'].items()} != self.expected:
                return None
            for key, row in stored['sessions'].items():
                require(row['agent'] == 'kimi', '历史来源不符')
                require((row['completedAt'] is not None) == (self.expected[key] == 'completed'), '历史完成时间不符')
            for key, prompt in self.prompts.items():
                if stored['userMessages'].get(key) != [prompt]:
                    return None
            if pending is not None:
                observation = stored['sessions'][sid]['approval']
                if observation is None or set(observation['pending']) != set(pending):
                    return None
                if not pending and stage == 'reject-result':
                    require(receipt['payload']['id'] in observation['resolved'], '数据库丢失已拒绝的原生请求')
            return {'stage': stage, 'diagnostics': state, 'database': stored,
                    'nativePayload': receipt['payload'], 'handledMessageCount': state['handledMessageCount']}

        snapshot = self.wait(matches, 'App/数据库检查：' + stage)
        self.report['checks'].append(snapshot)
        self.evidence.record('checkpoints', snapshot)

    def phase(self, phase: str) -> None:
        self.evidence.phase = phase
        self.evidence.gates[phase + ':turn'] = threading.Event()
        self.evidence.gates[phase + ':result'] = threading.Event()
        request = self.send('session/new', {'cwd': str(self.run / 'workspace'), 'mcpServers': []})
        started = self.hook('SessionStart')
        native = started['payload']['session_id']
        require(started['payload'].get('source') == 'startup', '未创建全新原生会话')
        self.checkpoint(phase + '-session-start', started, 'idle')
        created = self.response(request)['result']
        require(created['sessionId'] == native and created['modes']['currentModeId'] == 'default', '原生会话/默认人工权限不符')
        self.response(self.send('session/set_mode', {'sessionId': native, 'modeId': 'default'}))
        prompt = 'XI_NATIVE_' + phase.upper() + '_' + uuid.uuid4().hex
        request = self.send('session/prompt', {'sessionId': native, 'prompt': [{'type': 'text', 'text': prompt}]})
        submitted = self.hook('UserPromptSubmit', native)
        submitted_text = ''.join(item.get('text', '') for item in submitted['payload'].get('prompt', []) if item.get('type') == 'text')
        require(submitted_text == prompt, '原生提交载荷不是本次唯一提示')
        self.prompts['kimi_code-' + native] = prompt
        turn = self.hook('TurnStarted', native)
        self.checkpoint(phase + '-turn-start', turn, 'active')
        self.evidence.gates[phase + ':turn'].set()
        if phase == 'reject':
            before = self.hook('PreToolUse', native)
            asked = self.hook('PermissionRequest', native)
            payload = asked['payload']
            require(payload.get('tool_name') == 'Bash' and payload.get('tool_input', {}).get('command') == self.evidence.tool_command,
                    '审批不是指定的隔离canary命令')
            require(payload.get('turn_id') == turn['payload']['turn_id'] and payload.get('tool_call_id') == 'native_reject_probe', '原生审批回合/调用ID不符')
            require(before['payload'].get('tool_call_id') == payload['tool_call_id'], 'PreToolUse与审批调用不同')
            self.checkpoint('reject-request', asked, 'waitingPermission', pending=[payload['id']])
            permission = self.wait(lambda: self.evidence.permissions[0] if self.evidence.permissions else None, '原生 ACP 审批请求')
            require(permission['params']['sessionId'] == native, 'ACP 审批归属错误')
            require(permission['params']['toolCall']['title'] == 'Bash' and
                    permission['params']['toolCall']['toolCallId'] == f"{payload['turn_id']}:{payload['tool_call_id']}", 'ACP与native hook工具身份不符')
            options = permission['params']['options']
            require(any(item['optionId'] == 'reject' and item['kind'] == 'reject_once' for item in options), '原生审批未提供拒绝选项')
            self.write_acp({'jsonrpc': '2.0', 'id': permission['id'], 'result': {'outcome': {'outcome': 'selected', 'optionId': 'reject'}}})
            result = self.hook('PermissionResult', native)
            for key in ('session_id', 'id', 'agent_id', 'turn_id', 'tool_call_id', 'tool_name', 'tool_input'):
                require(result['payload'].get(key) == payload.get(key), '原生拒绝完整身份不匹配：' + key)
            require(result['payload'].get('decision') == 'rejected' and result['payload'].get('selected_label') == 'Reject',
                    '并非客户端成功选择Reject的原生结果，可能是RPC错误回退')
            failure = self.hook('PostToolUseFailure', native)
            require(failure['payload'].get('tool_call_id') == payload['tool_call_id'] and failure['payload'].get('tool_name') == 'Bash', '失败事件不是同一Bash')
            require(isinstance(failure['payload'].get('error'), dict) and
                    REJECTION_TEXT in str(failure['payload']['error'].get('message')), '失败hook缺少明确未执行的拒绝错误')
            require(not self.canary.exists(), '拒绝后实际执行了canary命令')
            self.checkpoint('reject-result', result, 'error', pending=[])
            self.evidence.gates[phase + ':result'].set()
        stopped = self.hook('Stop', native)
        # Stop 不覆盖已有工具错误；只有明确 SessionEnd 才结束整个会话。
        self.checkpoint(phase + '-stop', stopped, 'error' if phase == 'reject' else 'completionUnconfirmed',
                        pending=[] if phase == 'reject' else None)
        require(self.response(request)['result']['stopReason'] == 'end_turn', '回合没有正常结束')
        texts = [item['update'].get('content', {}).get('text', '') for item in self.evidence.updates
                 if item.get('sessionId') == native and item['update'].get('sessionUpdate') == 'agent_message_chunk']
        require('KIMI_NATIVE_HOOK_OK' in ''.join(texts), 'ACP没有收到mock短回答')
        close = self.send('session/close', {'sessionId': native})
        ended = self.hook('SessionEnd', native)
        require(ended['payload'].get('reason') == 'exit', '原生结束原因不是 exit')
        self.checkpoint(phase + '-session-end', ended, 'completed')
        self.response(close)
        stored = self.stored()
        require(stored is not None, '结束后历史库丢失')
        tool_rows = [row for row in stored['tools'] if row['sessionId'] == 'kimi_code-' + native]
        if phase == 'lifecycle':
            require(tool_rows == [], '无工具阶段出现工具历史')
        else:
            require(len(tool_rows) == 1 and tool_rows[0]['tool'] == 'Bash' and
                    tool_rows[0]['toolCallId'] == 'native_reject_probe' and tool_rows[0]['isComplete'] and
                    REJECTION_TEXT in str(tool_rows[0]['result']), '拒绝工具历史未完整持久化')
            require(not self.canary.exists(), 'canary表明工具曾执行')
            self.report['nativeRejectionPreventedExecutionVerified'] = True

    def cleanup(self) -> None:
        self.evidence.closing = True
        for gate in self.evidence.gates.values():
            gate.set()
        for process in reversed(self.processes):
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=3)
                except (ProcessLookupError, subprocess.TimeoutExpired):
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait(timeout=3)
        if self.server is not None:
            self.server.shutdown()
            self.server.server_close()
        for stream in self.logs:
            stream.close()
        self.socket.unlink(missing_ok=True)
        retained = []
        for name in ('diagnostics.json', 'history.store', 'history.store-wal', 'history.store-shm'):
            source = self.runtime / name
            if source.exists():
                destination = self.run / name
                source.rename(destination)
                retained.append(str(destination))
        result = subprocess.run(['/usr/bin/defaults', 'delete', self.suite],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        self.report['cleanup'] = {'processReturnCodes': [p.returncode for p in self.processes],
                                  'defaultsDeleteReturnCode': result.returncode, 'evidenceRetained': True,
                                  'retainedAppFiles': retained}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('bundle', 'node', 'sandbox-profile', 'runtime', 'app', 'report', 'hooks-block'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--port', type=int, default=18765)
    args = parser.parse_args()
    report: dict[str, Any] = {'passed': False, 'checkedAt': datetime.now(timezone.utc).isoformat(),
        'vendorClientLaunched': False, 'realClientVerified': False, 'humanApprovalVerified': False,
        'realProviderVerified': False, 'modelBackend': 'local deterministic SSE mock',
        'nativeRejectionPreventedExecutionVerified': False, 'approvalDecision': 'reject', 'totalTimeoutSeconds': TOTAL_TIMEOUT,
        'scope': 'Mock-gated native Kimi Code ACP lifecycle and rejection through isolated XIsland; not production concurrency or real provider acceptance'}
    probe = None

    def deadline(_signum: int, _frame: Any) -> None:
        raise TimeoutError('原生客户端测试达到固定总超时')

    previous = signal.signal(signal.SIGALRM, deadline)
    signal.alarm(TOTAL_TIMEOUT)
    try:
        for name in ('bundle', 'node', 'sandbox_profile', 'app', 'hooks_block'):
            setattr(args, name, getattr(args, name).resolve(strict=True))
        require(0 < args.port < 65536, '端口必须与调用者沙箱配置一致')
        require(os.access(args.node, os.X_OK), 'Node 路径不可执行')
        probe = NativeProbe(args, report)
        probe.prepare()
        probe.start()
        probe.phase('lifecycle')
        probe.phase('reject')
        require(probe.evidence.main_requests == {'lifecycle': 1, 'reject': 2}, '主回合模型请求次数不符')
        require(len(probe.evidence.permissions) == 1, '原生审批请求不是恰好一次')
        for receipt in probe.evidence.hooks:
            require(receipt['bridge']['returncode'] == 0 and receipt['bridge']['stdout'] == '', '附加hook桥接失败')
            if not receipt['consumed']:
                require(receipt['payload']['hook_event_name'] in ('UserPromptQueued', 'SessionHeartbeat'), '出现未验收的附加原生hook')
        require(not any(item['payload']['hook_event_name'] == 'PostToolUse' for item in probe.evidence.hooks), '拒绝路径产生成功工具结果')
        require(sum(item['consumed'] for item in probe.evidence.hooks) == 14, '必要原生hook遗漏或重复')
        state = read_json(probe.diagnostics)
        require(state['handledMessageCount'] == probe.initial_handled + len(probe.evidence.hooks), 'App消息数与全部原生receipt不一致')
        require(digest(args.bundle) == report['bundleSHA256'] and digest(probe.bridge) == report['bridgeSHA256']
                and digest(probe.binary) == report['appSHA256'], '测试期间产物被替换')
        report.update(passed=True, realClientVerified=True, nativeRejectVerified=True,
                      requiredNativeHooks=14, nativeHookCount=len(probe.evidence.hooks),
                      mainModelRequests=probe.evidence.main_requests)
    except (AssertionError, OSError, ValueError, KeyError, TimeoutError, sqlite3.Error, subprocess.SubprocessError) as error:
        report['error'] = str(error)
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)
        if probe is not None:
            try:
                probe.cleanup()
            except (OSError, subprocess.SubprocessError) as error:
                report.update(passed=False, cleanupError=str(error))
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'passed': report['passed'], 'report': str(args.report), 'error': report.get('error')}, ensure_ascii=False))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
