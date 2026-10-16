#!/usr/bin/env python3
"""原版 Kimi Code 2.1.1 Web API 排队、取消与出队 → hooks → 隔离 App/SQLite。

调用者提供已审查的沙箱；本脚本不生成或放宽沙箱，不改用户配置或信任。
Web 仅绑定指定 loopback 端口，保留临时原生 bearer auth 和默认 manual 权限。
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import errno
import http.client
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import re
import signal
import socket
import sqlite3
import stat
import subprocess
import threading
import time
from typing import Any
from urllib.parse import quote
import uuid


spec = importlib.util.spec_from_file_location('kimi_native_base', Path(__file__).with_name('test-kimi-native-client.py'))
assert spec is not None and spec.loader is not None
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
require = base.require
original_server = base.create_server
BUNDLE_SHA256 = '2563a338c94868a34e1bfd2e5579067d5a472acf4cb0bf350a3bfe1092bbe59d'
TOTAL_TIMEOUT = 180


def texts(message: dict[str, Any]) -> list[str]:
    content = message.get('content', '')
    if isinstance(content, str):
        return [content]
    return [part['text'] for part in content if isinstance(part, dict) and part.get('type') == 'text']


def queue_server(evidence, port):
    server = original_server(evidence, port)
    original_handler = server.RequestHandlerClass

    class Handler(original_handler):
        def do_POST(self):
            if self.path == '/hook-receipt':
                return super().do_POST()
            try:
                require(self.path == '/v1/chat/completions', '出现非本地模型接口')
                size = int(self.headers.get('Content-Length', '0'))
                require(0 < size < 8 * 1024 * 1024, '模型请求长度异常')
                body = json.loads(self.rfile.read(size))
                require(body.get('stream') is True and body.get('model') == 'mock-model', '模型参数不符')
                require(self.headers.get('Authorization') == 'Bearer local-mock-only', '出现非测试模型凭据')
                evidence.record('mock-inputs', {'body': body})
                users = [text for message in body['messages'] if message.get('role') == 'user' for text in texts(message)]
                require(evidence.markers['cancelled'] not in users, '被取消的排队提示进入了模型')
                role = 'auxiliary'
                if body.get('tools'):
                    # 客户端还会用 user 角色注入日期提醒；只匹配本次实际提交的唯一提示。
                    submitted = [text for text in users if text in evidence.marker_roles]
                    require(bool(submitted), '模型请求缺少本次实际提交的唯一用户提示')
                    role = evidence.marker_roles[submitted[-1]]
                    require(role in ('first', 'second'), '意外主回合')
                with evidence.condition:
                    record = {'role': role, 'body': body}
                    evidence.model_requests.append(record)
                    evidence.record('mock-requests', record)
                if role != 'auxiliary':
                    require(evidence.gates[role].wait(45), '模型门闩超时：' + role)
                require(not evidence.closing, '测试正在退出')
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()
                common = {'id': 'queue-' + uuid.uuid4().hex, 'object': 'chat.completion.chunk',
                    'created': int(time.time()), 'model': 'mock-model'}
                for delta, finish in (({'role': 'assistant', 'content': 'XI_QUEUE_REPLY_' + role}, None), ({}, 'stop')):
                    chunk = {**common, 'choices': [{'index': 0, 'delta': delta, 'finish_reason': finish}]}
                    self.wfile.write(('data: ' + json.dumps(chunk) + '\n\n').encode())
                self.wfile.write(b'data: [DONE]\n\n')
                self.wfile.flush()
            except (AssertionError, OSError, ValueError, KeyError, TypeError) as error:
                if not evidence.closing:
                    evidence.fail(error)
                self.close_connection = True

    server.RequestHandlerClass = Handler
    return server


base.create_server = queue_server


class Probe(base.NativeProbe):
    def __init__(self, args, report):
        super().__init__(args, report)
        self.token = ''
        self.users: dict[str, list[str]] = {}
        self.log_thread = None
        self.evidence.model_requests = []
        self.evidence.markers = {role: 'XI_QUEUE_' + role.upper() + '_' + uuid.uuid4().hex
            for role in ('first', 'second', 'cancelled')}
        self.evidence.marker_roles = {text: role for role, text in self.evidence.markers.items()}
        self.prompt_ids = {role: 'xi_queue_' + uuid.uuid4().hex for role in self.evidence.markers}
        for role in ('first', 'second'):
            self.evidence.gates[role] = threading.Event()

    def prepare(self):
        super().prepare()
        config = self.run / 'kimi/config.toml'
        require('default_permission_mode = "manual"' in config.read_text() and
            'decision = "allow"' not in config.read_text(), '权限配置被放宽')
        self.report['configSHA256'] = base.digest(config)
        self.client_env.update(KIMI_CODE_MODEL_CATALOG_REFRESH_ON_START='0',
            KIMI_CODE_MODEL_CATALOG_REFRESH_INTERVAL_MS='0')
        if self.args.api_only:
            self.client_env['KIMI_CODE_DEV_SERVER'] = '1'
        self.report.update(clientEnvironment=self.client_env.copy(), webPort=self.args.web_port,
            apiOnlyRequested=self.args.api_only, bearerAuth='native fresh runtime token; never logged',
            stageGating='Two local model responses held independently; native hooks are not reordered',
            promptIDs=self.prompt_ids, promptMarkers=self.evidence.markers)

    def redact(self, text):
        if self.token:
            text = text.replace(self.token, '<redacted-local-server-token>')
        text = re.sub(r'(?i)(#token=)[^\s"\x1b]+', r'\1<redacted-local-server-token>', text)
        return re.sub(r'(?i)(\bToken:\s*)[^\s\x1b]+', r'\1<redacted-local-server-token>', text)

    def capture_client_log(self):
        try:
            require(self.client is not None and self.client.stdout is not None, 'Web 日志流不可用')
            with (self.run / 'client.redacted.log').open('w') as stream:
                for raw in self.client.stdout:
                    stream.write(self.redact(raw.decode('utf-8', errors='replace')))
                    stream.flush()
        except (OSError, AssertionError) as error:
            if not self.evidence.closing:
                self.evidence.fail(error)

    def wait(self, check, description, timeout=20):
        def guarded():
            unexpected = [r['payload'] for r in self.evidence.hooks
                if r['payload']['hook_event_name'] in ('PermissionRequest', 'PreToolUse')]
            require(not unexpected, '无工具排队场景出现工具/审批；停止测试，未发任何授权')
            return check()
        return super().wait(guarded, description, timeout)

    def api(self, method, path, body=None, *, authenticated=True, record=True, raw=False):
        require(path.startswith('/api/v1/'), '只允许固定原生 Web API 路径')
        connection = http.client.HTTPConnection('127.0.0.1', self.args.web_port, timeout=10)
        headers = {'Content-Type': 'application/json'}
        if authenticated:
            require(bool(self.token), '临时原生 token 尚未生成')
            headers['Authorization'] = 'Bearer ' + self.token
        try:
            connection.request(method, path, body=json.dumps(body).encode() if body is not None else None, headers=headers)
            response = connection.getresponse()
            payload = json.loads(response.read(8 * 1024 * 1024))
            result = {'status': response.status, 'body': payload}
            if record:
                # 请求头和 token 从不进入证据文件。
                self.evidence.record('web-api', {'method': method, 'path': path, 'body': body,
                    'authenticated': authenticated, 'response': result})
            if raw:
                return result
            require(response.status == 200 and payload.get('code') == 0, '原生 Web API 请求失败：' + json.dumps(result))
            return payload['data']
        finally:
            connection.close()

    def listener_snapshot(self):
        require(self.client is not None and self.client.poll() is None, '原生客户端不再运行')
        command = ['/usr/sbin/lsof', '-nP', '-a', '-p', str(self.client.pid), '-iTCP', '-sTCP:LISTEN', '-F', 'pftPn']
        result = subprocess.run(command, capture_output=True, text=True, timeout=5)
        receipt = {'command': command, 'returncode': result.returncode, 'stdout': result.stdout,
            'stderr': result.stderr, 'checkedAt': datetime.now(timezone.utc).isoformat()}
        self.report.setdefault('listenerSnapshots', []).append(receipt)
        require(result.returncode == 0 and not result.stderr, '无法可靠读取原生客户端的 TCP 监听地址')
        listeners, current, pid = [], None, None
        for line in result.stdout.splitlines():
            require(bool(line), 'lsof 返回空记录')
            field, value = line[0], line[1:]
            if field == 'p':
                require(pid is None and value == str(self.client.pid), 'lsof 返回了其他或重复进程')
                pid = value
            elif field == 'f':
                require(pid is not None, 'lsof 文件记录缺少进程身份')
                if current is not None:
                    listeners.append(current)
                current = {'pid': pid, 'fd': value}
            else:
                require(current is not None and field in ('t', 'P', 'n'), '无法识别 lsof 监听记录')
                current[{'t': 'type', 'P': 'protocol', 'n': 'address'}[field]] = value
        if current is not None:
            listeners.append(current)
        receipt['listeners'] = listeners
        require(len(listeners) == 1 and listeners[0].get('type') == 'IPv4' and
            listeners[0].get('protocol') == 'TCP' and listeners[0].get('address') == f'127.0.0.1:{self.args.web_port}',
            '原生客户端监听不是唯一指定 IPv4 loopback 地址，停止测试')
        receipt['passed'] = True
        return receipt

    def verify_listener_boundary(self):
        self.listener_snapshot()
        command = ['/sbin/ifconfig', '-a']
        inventory = subprocess.run(command, capture_output=True, text=True, timeout=5)
        require(inventory.returncode == 0 and not inventory.stderr, '无法验证本机接口，停止测试')
        interfaces, current = [], None
        for line in inventory.stdout.splitlines():
            if line and not line[0].isspace():
                current = {'name': line.split(':', 1)[0], 'header': line, 'addresses': [], 'status': None}
                interfaces.append(current)
            elif current is not None:
                match = re.match(r'\s+inet\s+(\S+)', line)
                if match:
                    address = ipaddress.IPv4Address(match.group(1))
                    if not (address.is_loopback or address.is_unspecified or address.is_multicast):
                        current['addresses'].append({'address': str(address), 'sourceLine': line.strip()})
                if line.strip().startswith('status:'):
                    current['status'] = line.strip().split(':', 1)[1].strip()
        candidates = [(interface, address) for interface in interfaces for address in interface['addresses']
            if not interface['name'].startswith('lo') and re.search(r'\bUP\b', interface['header'])]
        require(bool(candidates), '没有可验证的本机非 loopback IPv4 地址，停止测试')
        candidates.sort(key=lambda item: (item[0]['status'] != 'active', not item[0]['name'].startswith('en'), item[0]['name']))
        interface, selected = candidates[0]
        receipt = {'inventoryCommand': command, 'interface': interface['name'], 'interfaceHeader': interface['header'],
            'interfaceStatus': interface['status'], 'interfaceAddressEvidence': selected,
            'destination': [selected['address'], self.args.web_port], 'passed': False}
        self.report['nonLoopbackProbe'] = receipt
        # 地址只来自本机 ifconfig；此探针不发送 token，也不访问任何远端主机。
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as client:
            client.settimeout(2)
            try:
                client.connect((selected['address'], self.args.web_port))
            except OSError as error:
                receipt.update(errorType=type(error).__name__, errno=error.errno, error=str(error))
                require(error.errno == errno.ECONNREFUSED, '非 loopback 探针未获得明确连接拒绝，停止测试')
                receipt['passed'] = True
            else:
                receipt['tcpConnected'] = True
                raise AssertionError('原生客户端可通过本机非 loopback 接口连接，停止测试')
        self.listener_snapshot()
        self.report['loopbackListenerGatePassed'] = True

    def start(self):
        app_env = {key: value for key, value in os.environ.items() if not key.startswith('X_ISLAND_TEST_')}
        for key in ('DI_SESSION_ID', 'DI_BRIDGE_DEBUG_LOG', 'DI_SOCKET_PATH'):
            app_env.pop(key, None)
        app_runtime = str(self.runtime).replace('/private/tmp/', '/tmp/', 1)
        app_env.update(X_ISLAND_TEST_MODE='1', X_ISLAND_TEST_RUNTIME_DIR=app_runtime,
            X_ISLAND_TEST_DEFAULTS_SUITE=self.suite, X_ISLAND_TEST_DIAGNOSTICS_PATH=app_runtime + '/diagnostics.json',
            X_ISLAND_DISABLE_ANIMATIONS='1', DI_SOCKET_PATH=str(self.socket))
        self.app_process = self.spawn([str(self.binary), '--ui-test-mode', '--ui-test-socket',
            '--fixture-path', str(self.run / 'empty-fixture.json')], app_env, 'app.log')
        self.wait(lambda: self.socket.exists() and base.read_json(self.diagnostics), '隔离应用启动')
        state = base.read_json(self.diagnostics)
        require(state['visibleSessions'] == [] and isinstance(state.get('handledMessageCount'), int), '应用不是空隔离实例')
        self.initial_handled = state['handledMessageCount']
        command = ['/usr/bin/sandbox-exec', '-f', str(self.args.sandbox_profile), str(self.args.node),
            str(self.args.bundle), 'web', '--host', '127.0.0.1', '--port', str(self.args.web_port),
            '--no-open', '--log-level', 'info']
        self.client = subprocess.Popen(command, env=self.client_env, cwd=self.run / 'workspace',
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        self.processes.append(self.client)
        self.log_thread = threading.Thread(target=self.capture_client_log, daemon=True)
        self.log_thread.start()
        self.report.update(vendorClientLaunched=True, appProcessId=self.app_process.pid,
            clientProcessId=self.client.pid, clientCommand=command)

        def ready():
            token_path = self.run / 'kimi/server.token'
            if not token_path.exists():
                return None
            require(not token_path.is_symlink() and stat.S_IMODE(token_path.stat().st_mode) == 0o600,
                '临时服务器 token 文件权限或位置异常')
            self.token = token_path.read_text().strip()
            require(len(self.token) >= 32 and re.fullmatch(r'[A-Za-z0-9_-]+', self.token) is not None,
                '临时原生 token 格式异常')
            try:
                return self.api('GET', '/api/v1/meta', record=False)
            except (ConnectionRefusedError, ConnectionResetError, http.client.RemoteDisconnected):
                return None

        meta = self.wait(ready, '指定端口的原生 Web API 就绪')
        require(meta['server_version'] == '2.1.1' and meta['dangerous_bypass_auth'] is False, '版本或认证策略不符')
        self.report['serverMetadata'] = meta
        self.verify_listener_boundary()
        unauthorized = self.api('GET', '/api/v1/sessions', authenticated=False, raw=True)
        require(unauthorized['status'] == 401, '原生 Web API 未拒绝无 token 请求')
        self.report['unauthenticatedRequestRejected'] = True

    def stored(self):
        data = super().stored()
        if data is not None:
            with sqlite3.connect(self.history.as_uri() + '?mode=ro', uri=True, timeout=0.2) as db:
                rows = db.execute('SELECT s.ZSESSIONID,c.ZCONTENT FROM ZSTOREDCHATMESSAGE c '
                    'JOIN ZSTOREDSESSION s ON c.ZSESSION=s.Z_PK WHERE c.ZROLE=? ORDER BY c.ZTIMESTAMP,c.Z_PK', ('user',)).fetchall()
            data['userMessages'] = {sid: [text for key, text in rows if key == sid] for sid in self.expected}
        return data

    def check(self, stage, receipt, status):
        sid = 'kimi_code-' + receipt['payload']['session_id']
        self.expected[sid] = status
        self.wait(lambda: (data := self.stored()) is not None and data['userMessages'] == self.users,
            stage + ' 用户历史不提前、不重复')
        self.checkpoint(stage, receipt, status, pending=[])
        data = self.report['checks'][-1]['database']
        require(data['userMessages'] == self.users and not data['tools'], stage + ' 用户历史或工具事实不符')
        for row in data['sessions'].values():
            observation = row['approval']
            require(observation is not None and not observation['pending'] and not observation['resolved'] and
                not observation['hasUnidentifiedRequest'] and not observation['wasInterrupted'], '排队场景产生审批/中断事实')

    def wire(self, native):
        rows = []
        for path in (self.run / 'kimi/sessions').rglob('wire.jsonl'):
            if native not in path.parts:
                continue
            lines = path.read_text().splitlines(keepends=True)
            for index, line in enumerate(lines):
                if index == len(lines) - 1 and not line.endswith('\n'):
                    continue
                rows.append({'path': str(path.relative_to(self.run)), **json.loads(line)})
        return rows

    def wire_event(self, native, event, **fields):
        return self.wait(lambda: next((row for row in self.wire(native) if row.get('type') == event and
            all(row.get(key) == value for key, value in fields.items())), None), '原生 wire ' + event)

    def submit(self, native, role):
        body = {'prompt_id': self.prompt_ids[role],
            'content': [{'type': 'text', 'text': self.evidence.markers[role]}]}
        if role == 'first':
            # Web 创建会话不会选定模型；原生 prompts 路由负责绑定本轮模型与权限模式。
            body.update(model='mock', permission_mode='manual')
        data = self.api('POST', '/api/v1/sessions/' + quote(native, safe='') + '/prompts',
            body)
        require(data['prompt_id'] == self.prompt_ids[role] and data['content'] ==
            [{'type': 'text', 'text': self.evidence.markers[role]}], '服务器未保留本次唯一提示身份')
        return data

    def queue_list(self, native, active, queued):
        def matches():
            data = self.api('GET', '/api/v1/sessions/' + quote(native, safe='') + '/prompts', record=False)
            active_id = data['active']['prompt_id'] if data['active'] else None
            if active_id != (self.prompt_ids[active] if active else None):
                return None
            if [row['prompt_id'] for row in data['queued']] != [self.prompt_ids[role] for role in queued]:
                return None
            return data
        data = self.wait(matches, '原生 active/queued 身份与顺序')
        self.evidence.record('queue-snapshots', {'sessionId': native, 'expectedActive': active,
            'expectedQueued': queued, 'data': data})
        return data

    def verify(self):
        created = self.api('POST', '/api/v1/sessions', {'title': 'XIsland isolated queue probe',
            'metadata': {'cwd': str(self.run / 'workspace')}})
        native = created['id']
        start = self.hook('SessionStart', native)
        require(start['payload']['source'] == 'startup', '不是新建隔离会话')
        sid = 'kimi_code-' + native
        self.users[sid] = []
        self.check('session-created', start, 'idle')

        require(self.submit(native, 'first')['status'] == 'running', '首条提示未开始')
        first_submit = self.hook('UserPromptSubmit', native)
        require(first_submit['payload']['prompt'] == [{'type': 'text', 'text': self.evidence.markers['first']}], '首提示 hook 不符')
        first_turn = self.hook('TurnStarted', native)
        self.users[sid].append(self.evidence.markers['first'])
        self.wait(lambda: any(row['role'] == 'first' for row in self.evidence.model_requests), '首回合实际请求模型')
        self.check('first-running-model-held', first_turn, 'active')

        queue_receipts = {}
        for role, length in (('second', 1), ('cancelled', 2)):
            require(self.submit(native, role)['status'] == 'queued', '忙碌时没有真实入队')
            queued = self.hook('UserPromptQueued', native)
            payload = queued['payload']
            require(payload['prompt_id'] == self.prompt_ids[role] and payload['queue_length'] == length and
                payload['prompt'] == [{'type': 'text', 'text': self.evidence.markers[role]}], '真实排队 hook 身份或长度不符')
            queue_receipts[role] = queued
            self.queue_list(native, 'first', ['second'] if length == 1 else ['second', 'cancelled'])
            self.check(role + '-queued-not-user-history', queued, 'active')

        cancelled = self.api('POST', '/api/v1/sessions/' + quote(native, safe='') + '/prompts/' +
            quote(self.prompt_ids['cancelled'], safe='') + ':abort', {})
        require(cancelled['aborted'] is True, '取消排队提示未获确认')
        aborted = self.wire_event(native, 'prompt.aborted', promptId=self.prompt_ids['cancelled'])
        self.queue_list(native, 'first', ['second'])
        self.check('queued-prompt-cancelled-without-user-history', queue_receipts['cancelled'], 'active')

        self.evidence.gates['first'].set()
        # 原生 externalHooks 在 hasPendingRequests 时不发 Stop，必须核对实际回合记录。
        first_completed = self.wire_event(native, 'prompt.completed',
            promptId=self.prompt_ids['first'], reason='completed')
        second_submit = self.hook('UserPromptSubmit', native)
        require(second_submit['payload']['prompt'] == [{'type': 'text', 'text': self.evidence.markers['second']}], '出队不是第二条提示')
        second_turn = self.hook('TurnStarted', native)
        require(second_turn['payload']['turn_id'] == first_turn['payload']['turn_id'] + 1, '出队回合计数不连续')
        self.users[sid].append(self.evidence.markers['second'])
        self.wait(lambda: any(row['role'] == 'second' for row in self.evidence.model_requests), '出队提示实际请求模型')
        require(not any(r['payload']['hook_event_name'] == 'Stop' for r in self.evidence.hooks),
            '仍有排队请求时不应报告中间 Stop')
        self.queue_list(native, 'second', [])
        self.check('second-dequeued-recorded-once', second_turn, 'active')
        self.evidence.gates['second'].set()
        stopped = self.hook('Stop', native)
        completed = self.wire_event(native, 'prompt.completed', promptId=self.prompt_ids['second'], reason='completed')
        self.queue_list(native, None, [])
        self.check('queue-drained', stopped, 'completionUnconfirmed')

        archive = self.api('POST', '/api/v1/sessions/' + quote(native, safe='') + ':archive', {})
        require(archive['archived'] is True, '隔离会话归档失败')
        ended = self.hook('SessionEnd', native)
        require(ended['payload']['reason'] == 'archive', '缺少真实归档结束事件')
        self.check('archived', ended, 'completed')

        receipts = self.evidence.hooks
        submitted = [r['payload']['prompt'] for r in receipts if r['payload']['hook_event_name'] == 'UserPromptSubmit']
        require(submitted == [[{'type': 'text', 'text': text}] for text in self.users[sid]], '取消提示提交了或用户提交重复')
        require([r['role'] for r in self.evidence.model_requests if r['role'] != 'auxiliary'] == ['first', 'second'],
            '真实模型主回合不是恰好首条、第二条')
        require(not any(r['payload']['hook_event_name'] == 'Interrupt' for r in receipts), '取消排队项误中断运行中回合')
        require(all(r['bridge']['returncode'] == 0 and r['bridge']['stdout'] == '' for r in receipts), '原生 hook 桥接失败或输出授权')
        require(all(r['consumed'] or r['payload']['hook_event_name'] == 'SessionHeartbeat' for r in receipts), '存在未验收原生 hook')
        require(sum(r['consumed'] for r in receipts) == 9, '必要原生事件遗漏或重复')
        require(base.read_json(self.diagnostics)['handledMessageCount'] == self.initial_handled + len(receipts), 'App/原生事件数量不符')
        require(not self.canary.exists(), '意外执行了工具')
        self.report.update(passed=True, queueEventVerified=True, queuedCancellationVerified=True,
            dequeueVerified=True, nativeHookCount=len(receipts), requiredNativeHooks=9,
            nativeEventTypes=sorted({r['payload']['hook_event_name'] for r in receipts}), expectedUserMessages=self.users,
            cancelledPromptNativeEvent=aborted, firstPromptCompletedWithoutStop=first_completed,
            dequeuedPromptCompletedEvent=completed,
            modelRequestRoles=[r['role'] for r in self.evidence.model_requests], bridgeStdoutEmpty=True,
            observedLimitation='Cancelling a queued prompt emits internal prompt.aborted but no external hook; '
                'XIsland receives no immediate cancellation or corrected queue length from the 20-hook API.')

    def cleanup(self):
        try:
            super().cleanup()
        finally:
            if self.log_thread is not None:
                self.log_thread.join(timeout=5)
                require(not self.log_thread.is_alive(), 'Web 日志线程没有退出')
            if self.token:
                for path in self.run.glob('*'):
                    if path.suffix in ('.log', '.json', '.jsonl'):
                        require(self.token not in path.read_text(errors='replace'), '临时 token 泄漏到证据日志')
                require(self.token not in json.dumps(self.report), '临时 token 泄漏到报告')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for flag in ('bundle', 'node', 'sandbox-profile', 'runtime', 'app', 'hooks-block', 'report'):
        parser.add_argument('--' + flag, type=Path, required=True)
    parser.add_argument('--port', type=int, required=True, help='既有 localhost mock/hook receipt 端口')
    parser.add_argument('--web-port', type=int, required=True, help='调用者精确允许 bind/inbound 的新增 loopback 端口')
    parser.add_argument('--api-only', action='store_true', help='显式使用官方 KIMI_CODE_DEV_SERVER=1；仅缺 Web assets 时需要')
    args = parser.parse_args()
    report = {'passed': False, 'checkedAt': datetime.now(timezone.utc).isoformat(),
        'scope': 'Official Kimi Node 2.1.1 Web API queue lifecycle, local deterministic model, actual hooks, isolated App and SQLite',
        'vendorClientLaunched': False, 'queueEventVerified': False, 'fullClientVerified': False,
        'loopbackListenerGatePassed': False, 'sandboxLoopbackBindEnforced': False,
        'realProviderVerified': False, 'approvalGrantSent': False, 'nonTestCredentialsUsed': False,
        'totalTimeoutSeconds': TOTAL_TIMEOUT, 'helperSHA256': base.digest(Path(__file__).with_name('test-kimi-native-client.py')),
        'driverSHA256': base.digest(Path(__file__))}
    probe = None

    def deadline(_signal, _frame):
        raise TimeoutError('排队验证达到180秒固定总时限')

    previous = signal.signal(signal.SIGALRM, deadline)
    signal.alarm(TOTAL_TIMEOUT)
    try:
        for name in ('bundle', 'node', 'sandbox_profile', 'runtime', 'app', 'hooks_block'):
            setattr(args, name, getattr(args, name).resolve(strict=True))
        require(0 < args.port < 65536 and 0 < args.web_port < 65536 and args.port != args.web_port,
            'mock/Web 必须为不同的固定合法端口，与调用者沙箱一致')
        require(base.digest(args.bundle) == BUNDLE_SHA256, '客户端不是固定官方2.1.1发布包')
        require(os.access(args.node, os.X_OK), 'Node 不可执行')
        require(args.sandbox_profile.is_relative_to(args.runtime) and args.hooks_block == args.runtime / 'generated-hooks.toml',
            '只能使用专用 runtime 内已审查沙箱及产品 hooks')
        probe = Probe(args, report)
        probe.prepare()
        probe.start()
        probe.verify()
        for path, key in ((args.bundle, 'bundleSHA256'), (args.node, 'nodeSHA256'),
                (args.sandbox_profile, 'sandboxProfileSHA256'), (args.hooks_block, 'hooksBlockSHA256'),
                (probe.binary, 'appSHA256'), (probe.bridge, 'bridgeSHA256'),
                (probe.run / 'kimi/config.toml', 'configSHA256'), (Path(__file__), 'driverSHA256'),
                (Path(__file__).with_name('test-kimi-native-client.py'), 'helperSHA256')):
            require(base.digest(path) == report[key], '测试中源码、配置或产物被替换：' + str(path))
        report['hashesUnchanged'] = True
    except (AssertionError, OSError, ValueError, KeyError, TypeError, TimeoutError, sqlite3.Error,
            subprocess.SubprocessError, http.client.HTTPException) as error:
        report.update(passed=False, error=probe.redact(str(error)) if probe else str(error))
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)
        if probe is not None:
            try:
                report.update(lastDiagnostics=base.read_json(probe.diagnostics), lastDatabase=probe.stored(),
                    nativeHookCount=len(probe.evidence.hooks), backgroundErrors=probe.evidence.errors,
                    permissionRequests=[r['payload'] for r in probe.evidence.hooks if r['payload']['hook_event_name'] == 'PermissionRequest'])
            except (OSError, ValueError, KeyError, sqlite3.Error) as error:
                report.update(passed=False, finalReadError=probe.redact(str(error)))
            finally:
                try:
                    probe.cleanup()
                except (AssertionError, OSError, subprocess.SubprocessError) as error:
                    report.update(passed=False, cleanupError=probe.redact(str(error)))
        args.report.parent.mkdir(parents=True, exist_ok=True)
        serialized = json.dumps(report, ensure_ascii=False, indent=2)
        if probe is not None and probe.token:
            serialized = serialized.replace(probe.token, '<redacted-local-server-token>')
        args.report.write_text(serialized + '\n')
    print(json.dumps({'passed': report['passed'], 'error': report.get('error'), 'report': str(args.report)}, ensure_ascii=False))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
