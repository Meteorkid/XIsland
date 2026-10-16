#!/usr/bin/env python3
"""隔离 Claude Code 2.1.234 → 本地模型 → 实际 Read/hooks/桥接/App/历史。

只读成功不代表审批验收。调用者必须先完成系统隔离正负对照；本脚本不放宽
沙箱、不写信任记录、不使用真实凭据，也不安装任何配置或程序。
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import signal
import sqlite3
import subprocess
import threading
import time
from urllib.parse import urlsplit
import uuid

spec = importlib.util.spec_from_file_location('native_helpers', Path(__file__).with_name('test-kimi-native-client.py'))
assert spec and spec.loader
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
require, digest = base.require, base.digest
CLIENT_SHA = '08d8700313697cbe730a25420c908a299ce52d56f0eb2cf4fac94cab5109bc57'
FAKE_KEY = 'sk-ant-xisland-isolated-test-only'

RECORDER = r'''import fs from 'node:fs';
import {spawnSync} from 'node:child_process';
const rawPayload = fs.readFileSync(0, 'utf8');
const payload = JSON.parse(rawPayload);
const argv = process.argv.slice(2);
const forbidden = payload.hook_event_name === 'PermissionRequest' ||
  (['PreToolUse','PostToolUse'].includes(payload.hook_event_name) && payload.tool_name !== 'Read');
let bridge = null;
if (!forbidden) {
  const r = spawnSync(process.env.XI_NATIVE_BRIDGE, argv,
    {input: rawPayload, encoding:'utf8', timeout:2500, maxBuffer:4194304, env:process.env});
  bridge = {returncode:r.status, signal:r.signal, stdout:r.stdout || '', stderr:r.stderr || '', error:r.error?.message};
}
const response = await fetch(process.env.XI_NATIVE_RECEIPT_URL, {method:'POST',
  headers:{'Content-Type':'application/json'}, body:JSON.stringify({rawPayload,argv,pid:process.pid,bridge,forbidden}),
  signal:AbortSignal.timeout(2000)});
if (bridge) process.stdout.write(bridge.stdout);
if (!response.ok || forbidden || bridge?.returncode !== 0) process.exitCode=1;
'''


class Probe(base.NativeProbe):
    def __init__(self, args, report):
        super().__init__(args, report)
        self.suite = 'dev.xisland.tests.claude-native-' + uuid.uuid4().hex
        report['defaultsSuite'] = self.suite
        self.model_requests = []
        self.client_events = []
        self.prompt = 'XI_CLAUDE_READ_' + uuid.uuid4().hex
        self.file_text = 'Native Read fixture 中文 ' + uuid.uuid4().hex + '\n'
        self.reply = 'XI_CLAUDE_READ_CONFIRMED_' + uuid.uuid4().hex
        self.tool_id = 'toolu_xisland_native_read'
        self.evidence.gates = {'first': threading.Event(), 'second': threading.Event()}
        self.report.update(prompt=self.prompt, expectedFileContent=self.file_text, expectedReply=self.reply)

    def wait(self, check, description, timeout=20):
        until = time.monotonic() + timeout
        while time.monotonic() < until:
            require(not self.evidence.errors, '后台验证失败：' + '; '.join(self.evidence.errors))
            if self.app_process:
                require(self.app_process.poll() is None, '隔离 App 已退出：' + description)
            if self.client and self.client.poll() is not None:
                require(self.client.returncode == 0, '原生客户端异常退出：' + str(self.client.returncode))
            value = check()
            if value:
                return value
            with self.evidence.condition:
                self.evidence.condition.wait(.05)
        raise AssertionError('等待超时：' + description)

    def prepare(self):
        a = self.args
        boundary = base.read_json(self.runtime / 'boundary-report.json')
        preparation = base.read_json(self.runtime / 'preparation.json')
        require(boundary and boundary['passed'] and preparation, '缺少已通过的系统隔离证据')
        require(boundary['profileSHA256'] == preparation['profileSHA256'] == digest(a.sandbox_profile), '沙箱与预检不一致')
        require(digest(a.client) == CLIENT_SHA == preparation['claudeSHA256'], '客户端不是已核实的固定版本')
        require(a.port == 60266 and a.sandbox_profile == self.runtime / 'client.sb', '仅允许已验证的隔离端口/profile')
        require(a.client.is_relative_to(self.runtime), '必须运行隔离目录内的客户端副本')
        for name in ('workspace', 'home', 'config', 'anthropic', 'xdg', 'tmp'):
            (self.run / name).mkdir(mode=0o700)
        self.read_file = self.run / 'workspace/native-read.txt'
        self.read_file.write_text(self.file_text)
        self.report['readFileSHA256'] = digest(self.read_file)
        helper_spec = importlib.util.spec_from_file_location('freshness', self.root / 'Scripts/test-main-finality-app.py')
        helper = importlib.util.module_from_spec(helper_spec)
        helper_spec.loader.exec_module(helper)
        with (a.app / 'Contents/Info.plist').open('rb') as f:
            name = plistlib.load(f)['CFBundleExecutable']
        require(Path(name).name == name, '非法 App 主程序名')
        self.report['freshness'] = {
            'app': helper.verify_freshness(self.root, a.app / 'Contents/MacOS' / name, 'DynamicIsland'),
            'bridge': helper.verify_freshness(self.root, a.app / 'Contents/MacOS/di-bridge', 'DIBridge')}
        copied = self.run / a.app.name
        shutil.copytree(a.app, copied, symlinks=True)
        self.binary, self.bridge = copied / 'Contents/MacOS' / name, copied / 'Contents/MacOS/di-bridge'
        self.report.update(appSHA256=digest(self.binary), bridgeSHA256=digest(self.bridge),
            clientSHA256=digest(a.client), profileSHA256=digest(a.sandbox_profile),
            nodeSHA256=digest(a.node), hooksSHA256=digest(a.hooks_config), appPath=str(copied))
        settings = base.read_json(a.hooks_config)
        generation = base.read_json(self.runtime / 'configuration-generation.json')
        require(generation['generatedConfigurationSHA256'] == digest(a.hooks_config) and
            generation['profileSourceSHA256'] == digest(self.root / 'Sources/DynamicIsland/Models/NativeHookProfile.swift'),
            'hooks 不再对应当前产品生成器')
        commands = [hook['command'] for groups in settings['hooks'].values() for group in groups for hook in group['hooks']]
        require(len(settings['hooks']) == len(commands) == 12 and
            all(str(self.runtime / 'hook-recorder') in command for command in commands),
            '没有使用产品生成的12事件配置')
        shutil.copyfile(a.hooks_config, self.run / 'settings.json')
        recorder = self.run / 'recorder.mjs'
        recorder.write_text(RECORDER)
        wrapper = self.runtime / 'hook-recorder'
        wrapper.write_text('#!/bin/sh\nexec ' + shlex.join([str(a.node), str(recorder)]) + ' "$@"\n')
        wrapper.chmod(0o700)
        self.client_env = {
            'PATH': str(a.node.parent) + ':/usr/bin:/bin:/usr/sbin:/sbin',
            'HOME': str(self.run / 'home'), 'CLAUDE_CONFIG_DIR': str(self.run / 'config'),
            'ANTHROPIC_CONFIG_DIR': str(self.run / 'anthropic'), 'XDG_CONFIG_HOME': str(self.run / 'xdg'),
            'CLAUDE_CODE_TMPDIR': str(self.run / 'tmp'), 'XDG_RUNTIME_DIR': str(self.run / 'tmp'),
            'TMPDIR': str(self.run / 'tmp') + '/', 'LANG': 'en_US.UTF-8', 'TERM': 'dumb', 'NO_COLOR': '1',
            'ANTHROPIC_API_KEY': FAKE_KEY, 'ANTHROPIC_BASE_URL': f'http://127.0.0.1:{a.port}',
            'DISABLE_TELEMETRY': '1', 'DISABLE_ERROR_REPORTING': '1', 'DISABLE_AUTOUPDATER': '1',
            'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1',
            'X_ISLAND_TEST_MODE': '1', 'X_ISLAND_TEST_RUNTIME_DIR': str(self.runtime),
            'DI_SOCKET_PATH': str(self.socket), 'XI_NATIVE_BRIDGE': str(self.bridge),
            'XI_NATIVE_RECEIPT_URL': f'http://127.0.0.1:{a.port}/hook-receipt',
        }
        self.report['clientEnvironment'] = self.client_env.copy()
        self.server = self.create_server()
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def create_server(self):
        probe = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                try:
                    size = int(self.headers.get('Content-Length', '0'))
                    require(0 < size < 8 * 1024 * 1024, '本地 HTTP 请求大小异常')
                    body = json.loads(self.rfile.read(size))
                    if self.path == '/hook-receipt':
                        body['payload'] = json.loads(body['rawPayload'])
                        body['consumed'] = False
                        with probe.evidence.condition:
                            probe.evidence.hooks.append(body)
                            probe.evidence.record('native-hooks', body)
                        if body['forbidden']:
                            probe.evidence.fail(AssertionError('只读场景出现权限请求或其他工具；没有发出授权'))
                        self.send_response(200)
                        self.send_header('Content-Length', '2')
                        self.end_headers()
                        self.wfile.write(b'{}')
                        return
                    require(urlsplit(self.path).path == '/v1/messages' and
                        urlsplit(self.path).query in ('', 'beta=true'), '未预期的模型接口：' + self.path)
                    require(self.headers.get('x-api-key') == FAKE_KEY and not self.headers.get('Authorization'), '出现非测试认证')
                    require(body.get('stream') is True and body.get('model') == 'claude-sonnet-4-6', '主模型合同不符')
                    require({t['name'] for t in body['tools']} == {'Read'}, '模型获得了非只读工具')
                    with probe.evidence.condition:
                        index = len(probe.model_requests) + 1
                        record = {'index': index, 'path': self.path, 'headers': dict(self.headers), 'body': body}
                        probe.model_requests.append(record)
                        probe.evidence.record('model-requests', record)
                    require(index in (1, 2), '出现额外模型回合')
                    require(probe.prompt in json.dumps(body['messages']), '模型请求丢失本次用户提示')
                    if index == 2:
                        results = [p for m in body['messages'] if m['role'] == 'user'
                            for p in m['content'] if isinstance(m['content'], list) and p.get('type') == 'tool_result']
                        matching = [p for p in results if p.get('tool_use_id') == probe.tool_id]
                        require(len(matching) == 1 and not matching[0].get('is_error') and
                            probe.file_text.strip() in json.dumps(matching[0], ensure_ascii=False), '模型未收到对应的真实 Read 结果')
                    require(probe.evidence.gates['first' if index == 1 else 'second'].wait(45), '模型门闩超时')
                    require(not probe.evidence.closing, '测试正在结束')
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/event-stream')
                    self.send_header('request-id', 'xisland-native-' + str(index))
                    self.end_headers()

                    def send(event, value):
                        self.wfile.write(('event: ' + event + '\ndata: ' + json.dumps(value, ensure_ascii=False) + '\n\n').encode())
                        self.wfile.flush()

                    send('message_start', {'type': 'message_start', 'message': {'id': 'msg_xisland_' + str(index),
                        'type': 'message', 'role': 'assistant', 'model': body['model'], 'content': [],
                        'stop_reason': None, 'stop_sequence': None, 'usage': {'input_tokens': 20, 'output_tokens': 1,
                            'cache_creation_input_tokens': 0, 'cache_read_input_tokens': 0}}})
                    block = {'type': 'tool_use', 'id': probe.tool_id, 'name': 'Read', 'input': {}} if index == 1 else {'type': 'text', 'text': ''}
                    send('content_block_start', {'type': 'content_block_start', 'index': 0, 'content_block': block})
                    delta = {'type': 'input_json_delta', 'partial_json': json.dumps({'file_path': str(probe.read_file)})} if index == 1 else {'type': 'text_delta', 'text': probe.reply}
                    send('content_block_delta', {'type': 'content_block_delta', 'index': 0, 'delta': delta})
                    send('content_block_stop', {'type': 'content_block_stop', 'index': 0})
                    send('message_delta', {'type': 'message_delta', 'delta': {'stop_reason': 'tool_use' if index == 1 else 'end_turn',
                        'stop_sequence': None}, 'usage': {'output_tokens': 10}})
                    send('message_stop', {'type': 'message_stop'})
                except (AssertionError, OSError, ValueError, KeyError, TypeError) as error:
                    if not probe.evidence.closing:
                        probe.evidence.fail(error)
                    self.close_connection = True

            def do_GET(self):
                probe.evidence.record('unexpected-http', {'method': 'GET', 'path': self.path})
                probe.evidence.fail(AssertionError('未预期 GET 请求：' + self.path))
                self.send_error(400)

        server = ThreadingHTTPServer(('127.0.0.1', self.args.port), Handler)
        server.daemon_threads = True
        return server

    def start(self):
        app_runtime = str(self.runtime).replace('/private/tmp/', '/tmp/', 1)
        env = {k: v for k, v in os.environ.items() if not k.startswith('X_ISLAND_TEST_') and
               k not in ('DI_SESSION_ID', 'DI_SOCKET_PATH', 'DI_BRIDGE_DEBUG_LOG')}
        env.update(X_ISLAND_TEST_MODE='1', X_ISLAND_TEST_RUNTIME_DIR=app_runtime,
            X_ISLAND_TEST_DEFAULTS_SUITE=self.suite, X_ISLAND_TEST_DIAGNOSTICS_PATH=app_runtime + '/diagnostics.json',
            X_ISLAND_DISABLE_ANIMATIONS='1', DI_SOCKET_PATH=str(self.socket))
        self.app_process = self.spawn([str(self.binary), '--ui-test-mode', '--ui-test-socket', '--fixture-path',
            str(self.root / 'Tests/Fixtures/app/empty-interaction.json')], env, 'app.log')
        self.wait(lambda: self.socket.exists() and base.read_json(self.diagnostics), '隔离 App 启动')
        require(base.read_json(self.diagnostics)['visibleSessions'] == [], '隔离 App 不是空会话')
        self.initial_handled = base.read_json(self.diagnostics)['handledMessageCount']
        command = ['/usr/bin/sandbox-exec', '-f', str(self.args.sandbox_profile), str(self.args.client), '-p', self.prompt,
            '--permission-mode', 'manual', '--tools', 'Read', '--model', 'claude-sonnet-4-6', '--thinking', 'disabled',
            '--max-turns', '2', '--output-format', 'stream-json', '--verbose', '--include-hook-events',
            '--setting-sources', '', '--settings', str(self.run / 'settings.json'), '--strict-mcp-config',
            '--mcp-config', '{"mcpServers":{}}', '--disable-slash-commands', '--no-chrome']
        log = (self.run / 'client.stderr.log').open('wb')
        self.logs.append(log)
        self.client = subprocess.Popen(command, cwd=self.run / 'workspace', env=self.client_env,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=log, start_new_session=True)
        self.processes.append(self.client)
        self.report.update(nativeClientLaunched=True, appProcessId=self.app_process.pid, clientProcessId=self.client.pid,
            clientCommand=command)

        def read_client():
            try:
                for raw in self.client.stdout:
                    with (self.run / 'client.stdout.log').open('ab') as output:
                        output.write(raw)
                    value = json.loads(raw)
                    self.client_events.append(value)
                    self.evidence.record('client-stream', value)
            except (OSError, ValueError) as error:
                if not self.evidence.closing:
                    self.evidence.fail(error)
        threading.Thread(target=read_client, daemon=True).start()

    def hook(self, event, native_id=None):
        def find():
            for receipt in self.evidence.hooks:
                if not receipt['consumed'] and receipt['payload']['hook_event_name'] == event:
                    receipt['consumed'] = True
                    return receipt
            return None
        receipt = self.wait(find, '真实 hook ' + event)
        require(not receipt['forbidden'] and receipt['bridge']['returncode'] == 0 and
            json.loads(receipt['bridge']['stdout']) == {}, 'bridge 未中性转发原生事件')
        require(receipt['payload']['cwd'] == str(self.run / 'workspace'), '原生 cwd 逸出测试空间')
        if native_id:
            require(receipt['payload']['session_id'] == native_id, '原生会话身份发生改变')
        return receipt

    def check(self, stage, status, *, durable=False, tool_completed=False, prompt_history=False):
        def snapshot():
            state = base.read_json(self.diagnostics)
            if state is None or state['handledMessageCount'] < self.initial_handled + len(self.evidence.hooks):
                return None
            rows = state['visibleSessions']
            if len(rows) != 1 or rows[0]['id'] != self.session_id or rows[0]['status'] != status:
                return None
            require(rows[0]['agentType'] == 'claude_code' and not state.get('pendingInteraction'), '出现其他来源或可操作审批')
            require((rows[0].get('completedAt') is not None) == (status == 'completed'), '完成时间错误')
            database = self.stored()
            if prompt_history:
                require(database is not None and
                    database['sessions'].get(self.session_id, {}).get('status') == 'active' and
                    database['userMessages'].get(self.session_id) == [self.prompt],
                    '首条真实用户提示必须在模型返回和 Stop 之前保存')
            if durable:
                if database is None or database['sessions'].get(self.session_id, {}).get('status') != status:
                    return None
                require(database['userMessages'][self.session_id] == [self.prompt], '用户历史缺失或重复')
                tools = database['tools']
                require(len(tools) == 1 and tools[0]['tool'] == 'Read' and tools[0]['toolCallId'] == self.tool_id and
                    tools[0]['isComplete'] == tool_completed and self.file_text.strip() in (tools[0]['result'] or ''), '真实 Read 工具历史不符')
            return {'stage': stage, 'diagnostics': state, 'database': database,
                'durableCheckpointRequired': durable, 'promptHistoryCheckpointRequired': prompt_history}
        value = self.wait(snapshot, 'App/历史检查：' + stage)
        self.report['checks'].append(value)
        self.evidence.record('checkpoints', value)

    def verify(self):
        start = self.hook('SessionStart')
        native = start['payload']['session_id']
        self.session_id = 'claude_code-' + native
        self.expected[self.session_id] = 'active'
        submitted = self.hook('UserPromptSubmit', native)
        require(submitted['payload']['prompt'] == self.prompt, '原生用户提示不符')
        self.wait(lambda: len(self.model_requests) == 1, '真实首轮模型请求')
        self.check('prompt-active-before-model-reply', 'active', prompt_history=True)
        self.report['promptHistoryBeforeModelReplyVerified'] = True
        self.evidence.gates['first'].set()
        pre = self.hook('PreToolUse', native)
        post = self.hook('PostToolUse', native)
        for receipt in (pre, post):
            p = receipt['payload']
            require(p['tool_name'] == 'Read' and p['tool_use_id'] == self.tool_id and
                p['tool_input']['file_path'] == str(self.read_file), '真实 Read 调用身份或路径不符')
        require(self.file_text.strip() in json.dumps(post['payload']['tool_response'], ensure_ascii=False), '原生后置结果没有实际文件内容')
        self.wait(lambda: len(self.model_requests) == 2, '工具结果进入真实后续模型请求')
        self.check('read-forwarded-before-final-model-reply', 'active')
        self.evidence.gates['second'].set()
        stopped = self.hook('Stop', native)
        require(stopped['payload'].get('last_assistant_message') == self.reply, '原生 Stop 没有对应助手回复')
        # SessionEnd 紧随 Stop 时，不能用已经结束的会话倒推中间 UI 状态。
        self.hook('SessionEnd', native)
        self.check('native-session-ended', 'completed', durable=True, tool_completed=True)
        self.wait(lambda: self.client.poll() is not None, '原生客户端自然退出')
        result = [r for r in self.client_events if r.get('type') == 'result']
        require(len(result) == 1 and result[0].get('is_error') is False and result[0].get('result') == self.reply,
            '原生客户端没有明确成功结果')
        require(len(self.model_requests) == 2 and len(self.evidence.hooks) == 6 and
            all(r['consumed'] for r in self.evidence.hooks), '出现额外或缺少的原生事件/模型回合')
        require(digest(self.read_file) == self.report['readFileSHA256'], '只读场景改写了文件')
        self.report.update(passed=True, nativeReadVerified=True, nativeHookCount=len(self.evidence.hooks),
            nativeEventTypes=[r['payload']['hook_event_name'] for r in self.evidence.hooks],
            modelRequests=len(self.model_requests), clientExit=self.client.returncode,
            liveHistoryPersistedBeforeStop=all(c['database'] and self.session_id in c['database']['sessions']
                for c in self.report['checks'][:-1]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('runtime', 'client', 'sandbox-profile', 'hooks-config', 'app', 'node', 'report'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--port', type=int, required=True)
    args = parser.parse_args()
    report = {'checkedAt': datetime.now(timezone.utc).isoformat(), 'passed': False, 'nativeClientLaunched': False,
        'clientVersion': '2.1.234', 'modelBackend': 'local deterministic Anthropic SSE mock',
        'nativeApprovalVerified': False, 'approvalGranted': False, 'fullClientVerified': False,
        'scope': 'Real Read/tool-result/native hooks through isolated App; prompt history required before model reply and full history at final checkpoint; no approval or real-provider acceptance',
        'driverSHA256': digest(Path(__file__))}
    probe = None

    def deadline(*_):
        raise TimeoutError('原生只读验证达到180秒总时限')
    previous = signal.signal(signal.SIGALRM, deadline)
    signal.alarm(180)
    try:
        for name in ('runtime', 'client', 'sandbox_profile', 'hooks_config', 'app', 'node'):
            setattr(args, name, getattr(args, name).resolve(strict=True))
        probe = Probe(args, report)
        probe.prepare()
        probe.start()
        probe.verify()
        require(digest(args.client) == report['clientSHA256'] and digest(args.sandbox_profile) == report['profileSHA256'] and
            digest(probe.binary) == report['appSHA256'] and digest(probe.bridge) == report['bridgeSHA256'] and
            digest(args.hooks_config) == report['hooksSHA256'] and digest(Path(__file__)) == report['driverSHA256'],
            '验证中产物或输入发生变化')
    except (AssertionError, OSError, ValueError, KeyError, TypeError, TimeoutError, sqlite3.Error, subprocess.SubprocessError) as error:
        report.update(passed=False, error=str(error))
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)
        if probe:
            try:
                report.update(lastDiagnostics=base.read_json(probe.diagnostics), lastDatabase=probe.stored(),
                    nativeHookCount=len(probe.evidence.hooks), modelRequests=len(probe.model_requests),
                    backgroundErrors=probe.evidence.errors)
            except (OSError, ValueError, sqlite3.Error) as error:
                report.update(passed=False, finalReadError=str(error))
            finally:
                try:
                    probe.cleanup()
                except (OSError, subprocess.SubprocessError) as error:
                    report.update(passed=False, cleanupError=str(error))
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'passed': report['passed'], 'error': report.get('error'), 'report': str(args.report)}, ensure_ascii=False))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
