#!/usr/bin/env python3
"""原生 Claude 权限请求 → 隔离 XIsland 的拒绝按钮 → 原生未执行结果。

使用已有辅助功能权限，按测试 PID、应用路径和原生会话核对后只点击拒绝。
stdio 权限宿主只保持连接和记录请求，绝不自行返回允许或拒绝来冒充岛上决定。
"""
from __future__ import annotations

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import threading
from urllib.parse import urlsplit
import uuid

spec = importlib.util.spec_from_file_location('claude_read', Path(__file__).with_name('test-claude-native-read.py'))
assert spec and spec.loader
read = importlib.util.module_from_spec(spec)
spec.loader.exec_module(read)
base, require, digest = read.base, read.require, read.digest

read.RECORDER = r'''import fs from 'node:fs';
import {spawnSync} from 'node:child_process';
const rawPayload=fs.readFileSync(0,'utf8');
const payload=JSON.parse(rawPayload), argv=process.argv.slice(2);
const forbidden=['PreToolUse','PostToolUse','PostToolUseFailure','PermissionRequest'].includes(payload.hook_event_name) &&
  (payload.tool_name!=='Write' || payload.tool_input?.file_path!==process.env.XI_NATIVE_CANARY);
async function receipt(value) {
 const r=await fetch(process.env.XI_NATIVE_RECEIPT_URL,{method:'POST',headers:{'Content-Type':'application/json'},
  body:JSON.stringify({rawPayload,argv,pid:process.pid,forbidden,...value}),signal:AbortSignal.timeout(2000)});
 if(!r.ok) throw new Error('Receipt rejected');
}
await receipt({stage:'input'});
if(forbidden) process.exitCode=1;
else {
 const r=spawnSync(process.env.XI_NATIVE_BRIDGE,argv,{input:rawPayload,encoding:'utf8',
  timeout:payload.hook_event_name==='PermissionRequest'?25000:2500,maxBuffer:4194304,env:process.env});
 const bridge={returncode:r.status,signal:r.signal,stdout:r.stdout||'',stderr:r.stderr||'',error:r.error?.message};
 await receipt({stage:'forwarded',bridge});
 process.stdout.write(bridge.stdout);
 if(r.status!==0) process.exitCode=1;
}
'''


class RejectProbe(read.Probe):
    def __init__(self, args, report):
        super().__init__(args, report)
        self.prompt = 'XI_CLAUDE_REJECT_' + uuid.uuid4().hex
        self.reply = 'XI_CLAUDE_REJECTION_CONFIRMED_' + uuid.uuid4().hex
        self.tool_id = 'toolu_xisland_native_write'
        self.write_text = 'MUST_NOT_BE_WRITTEN_' + uuid.uuid4().hex
        self.canary = self.run / 'workspace/rejected-write.txt'
        self.inputs = []
        self.stdin_packets = []
        report.pop('expectedFileContent', None)
        report.update(prompt=self.prompt, expectedReply=self.reply, expectedWriteContent=self.write_text,
            entrypointSHA256=digest(Path(__file__)), entrypoint='test-claude-native-reject.py',
            nativeApprovalVerified=False, xIslandDenialVerified=False, humanApprovalVerified=False,
            scope='Real Claude SDK stdio permission request; deny through matching isolated XIsland AX button; local model; no SDK permission decision or approval grant')

    def prepare(self):
        super().prepare()
        self.report.pop('readFileSHA256', None)
        self.client_env['XI_NATIVE_CANARY'] = str(self.canary)
        self.report['clientEnvironment'] = self.client_env.copy()
        self.deny_helper = self.runtime / 'deny-helper/deny-helper'
        metadata = base.read_json(self.runtime / 'deny-helper/receipt.json')
        require(metadata and digest(self.deny_helper) == metadata['helperSHA256'] and
            metadata['permissionProbe']['trusted'] and not metadata['permissionProbe']['promptRequested'],
            '拒绝助手或已有辅助功能权限未核对')
        self.report['denyHelperSHA256'] = digest(self.deny_helper)
        require(not self.canary.exists(), '拒绝测试的目标文件已存在')

    def create_server(self):
        probe = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                try:
                    size = int(self.headers.get('Content-Length', '0'))
                    require(0 < size < 8 * 1024 * 1024, '请求长度不符')
                    body = json.loads(self.rfile.read(size))
                    if self.path == '/hook-receipt':
                        body['payload'] = json.loads(body['rawPayload'])
                        body['consumed'] = False
                        with probe.evidence.condition:
                            if body['stage'] == 'input':
                                probe.inputs.append(body)
                                probe.evidence.record('native-inputs', body)
                            else:
                                require(body['stage'] == 'forwarded', '未知回执阶段')
                                probe.evidence.hooks.append(body)
                                probe.evidence.record('native-hooks', body)
                        if body['forbidden']:
                            probe.evidence.fail(AssertionError('出现非指定 Write 请求，未发授权'))
                        self.send_response(200)
                        self.send_header('Content-Length', '2')
                        self.end_headers()
                        self.wfile.write(b'{}')
                        return
                    require(urlsplit(self.path).path == '/v1/messages' and urlsplit(self.path).query in ('', 'beta=true'),
                        '出现未预期模型接口：' + self.path)
                    require(self.headers.get('x-api-key') == read.FAKE_KEY and not self.headers.get('Authorization'),
                        '出现非测试认证')
                    require(body.get('stream') is True and body.get('model') == 'claude-sonnet-4-6' and
                        {t['name'] for t in body['tools']} == {'Write'}, '模型或工具集合不符')
                    with probe.evidence.condition:
                        index = len(probe.model_requests) + 1
                        row = {'index': index, 'path': self.path, 'headers': dict(self.headers), 'body': body}
                        probe.model_requests.append(row)
                        probe.evidence.record('model-requests', row)
                    require(index in (1, 2), '出现额外模型请求')
                    if index == 2:
                        results = [p for m in body['messages'] if m['role'] == 'user' and isinstance(m.get('content'), list)
                            for p in m['content'] if p.get('type') == 'tool_result' and p.get('tool_use_id') == probe.tool_id]
                        require(len(results) == 1 and results[0].get('is_error') is True and
                            'denied' in json.dumps(results[0]).lower(), '模型未收到对应的原生拒绝结果')
                        require(not probe.canary.exists(), '拒绝前已经发生写入')
                    require(probe.evidence.gates['first' if index == 1 else 'second'].wait(45), '模型门闩超时')
                    require(not probe.evidence.closing, '测试正在退出')
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/event-stream')
                    self.end_headers()

                    def send(event, value):
                        self.wfile.write(('event: ' + event + '\ndata: ' + json.dumps(value) + '\n\n').encode())
                        self.wfile.flush()

                    send('message_start', {'type': 'message_start', 'message': {'id': 'msg_reject_' + str(index),
                        'type': 'message', 'role': 'assistant', 'model': body['model'], 'content': [],
                        'stop_reason': None, 'stop_sequence': None, 'usage': {'input_tokens': 20, 'output_tokens': 1,
                            'cache_creation_input_tokens': 0, 'cache_read_input_tokens': 0}}})
                    block = {'type': 'tool_use', 'id': probe.tool_id, 'name': 'Write', 'input': {}} if index == 1 else {'type': 'text', 'text': ''}
                    send('content_block_start', {'type': 'content_block_start', 'index': 0, 'content_block': block})
                    delta = {'type': 'input_json_delta', 'partial_json': json.dumps({'file_path': str(probe.canary),
                        'content': probe.write_text})} if index == 1 else {'type': 'text_delta', 'text': probe.reply}
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
                probe.evidence.fail(AssertionError('未预期 GET：' + self.path))
                self.send_error(400)

        server = ThreadingHTTPServer(('127.0.0.1', self.args.port), Handler)
        server.daemon_threads = True
        return server

    def write_packet(self, packet):
        # 此驱动不提供权限决定；只有初始化和用户提示能够写入 stdin。
        require(packet['type'] == 'user' or (packet['type'] == 'control_request' and
            packet['request']['subtype'] == 'initialize'), '禁止伪造 SDK 权限决定')
        self.stdin_packets.append(packet)
        self.evidence.record('client-input', packet)
        self.client.stdin.write((json.dumps(packet) + '\n').encode())
        self.client.stdin.flush()

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
        state = base.read_json(self.diagnostics)
        require(state['visibleSessions'] == [], '测试 App 不是空会话')
        self.initial_handled = state['handledMessageCount']
        command = ['/usr/bin/sandbox-exec', '-f', str(self.args.sandbox_profile), str(self.args.client), '-p',
            '--input-format', 'stream-json', '--permission-prompt-tool', 'stdio', '--permission-mode', 'manual',
            '--tools', 'Write', '--model', 'claude-sonnet-4-6', '--thinking', 'disabled', '--max-turns', '2',
            '--output-format', 'stream-json', '--verbose', '--include-hook-events', '--setting-sources', '',
            '--settings', str(self.run / 'settings.json'), '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}',
            '--disable-slash-commands', '--no-chrome']
        log = (self.run / 'client.stderr.log').open('wb')
        self.logs.append(log)
        self.client = subprocess.Popen(command, cwd=self.run / 'workspace', env=self.client_env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, start_new_session=True)
        self.processes.append(self.client)
        self.report.update(nativeClientLaunched=True, appProcessId=self.app_process.pid,
            clientProcessId=self.client.pid, clientCommand=command)

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
        self.write_packet({'type': 'control_request', 'request_id': 'xi-initialize', 'request': {'subtype': 'initialize'}})
        initialized = self.wait(lambda: next((x for x in self.client_events if x.get('type') == 'control_response' and
            x.get('response', {}).get('request_id') == 'xi-initialize'), None), '原生 stdio 初始化')
        require(initialized['response']['subtype'] == 'success', '原生 stdio 初始化失败')
        self.write_packet({'type': 'user', 'message': {'role': 'user', 'content': self.prompt},
            'parent_tool_use_id': None, 'session_id': ''})

    def approval_state(self):
        state = base.read_json(self.diagnostics)
        if not state or state.get('pendingInteraction') != 'permission':
            return None
        rows = state['visibleSessions']
        if len(rows) != 1 or rows[0]['id'] != self.session_id or rows[0]['status'] != 'waitingPermission':
            return None
        return state

    def stored(self):
        data = super().stored()
        if data is not None:
            with sqlite3.connect(self.history.as_uri() + '?mode=ro', uri=True, timeout=.2) as db:
                rows = db.execute('SELECT s.ZSESSIONID,t.ZTOOLCALLID,t.ZCOMPLETIONUNCONFIRMED '
                    'FROM ZSTOREDTOOLEVENT t JOIN ZSTOREDSESSION s ON t.ZSESSION=s.Z_PK').fetchall()
            markers = {(sid, call): bool(value) for sid, call, value in rows}
            for tool in data['tools']:
                tool['completionUnconfirmed'] = markers[(tool['sessionId'], tool['toolCallId'])]
        return data

    def verify(self):
        start = self.hook('SessionStart')
        native = start['payload']['session_id']
        self.session_id = 'claude_code-' + native
        self.expected[self.session_id] = 'active'
        submitted = self.hook('UserPromptSubmit', native)
        require(submitted['payload']['prompt'] == self.prompt, '原生用户提示不符')
        self.wait(lambda: len(self.model_requests) == 1, '首个模型请求')
        self.evidence.gates['first'].set()
        pre = self.hook('PreToolUse', native)
        require(pre['payload']['tool_name'] == 'Write' and pre['payload']['tool_use_id'] == self.tool_id,
            '原生工具身份不符')
        asked = self.wait(lambda: next((x for x in self.inputs if x['payload']['hook_event_name'] == 'PermissionRequest'), None),
            '真实 PermissionRequest 输入')
        require(asked['payload']['session_id'] == native and asked['payload']['tool_input'] ==
            {'file_path': str(self.canary), 'content': self.write_text}, '原生审批内容不符')
        control = self.wait(lambda: next((x for x in self.client_events if x.get('type') == 'control_request' and
            x.get('request', {}).get('subtype') == 'can_use_tool'), None), '真实 stdio 权限请求')
        require(control['request']['tool_name'] == 'Write' and control['request']['tool_use_id'] == self.tool_id and
            control['request']['input'] == asked['payload']['tool_input'], 'stdio 与原生 hook 工具不对应')
        before = self.wait(self.approval_state, '实际 App 等待原生权限')
        self.report['checks'].append({'stage': 'native-permission-waiting', 'diagnostics': before, 'database': self.stored()})
        action = subprocess.run([str(self.deny_helper), '--deny', str(self.app_process.pid),
            str(self.binary.parent.parent.parent), str(self.runtime), str(self.diagnostics), self.session_id],
            capture_output=True, text=True, timeout=10)
        self.report['denyAction'] = {'returncode': action.returncode, 'stdout': action.stdout, 'stderr': action.stderr}
        self.evidence.record('deny-action', self.report['denyAction'])
        require(action.returncode == 0 and json.loads(action.stdout).get('pressed') is True, '隔离 App 拒绝按钮未成功操作')
        forwarded = self.wait(lambda: next((x for x in self.evidence.hooks if x['payload']['hook_event_name'] == 'PermissionRequest'), None),
            '岛上拒绝回传原生 hook')
        forwarded['consumed'] = True
        decision = json.loads(forwarded['bridge']['stdout'])
        require(forwarded['bridge']['returncode'] == 0 and decision['hookSpecificOutput']['hookEventName'] == 'PermissionRequest' and
            decision['hookSpecificOutput']['decision']['behavior'] == 'deny', '桥接没有回传原生拒绝')
        self.wait(lambda: len(self.model_requests) == 2, '拒绝结果到达模型')
        denied = self.wait(lambda: next((x for x in self.client_events if x.get('type') == 'user' and
            any(m.get('id') == self.tool_id and m.get('non_execution_kind') == 'permission-rule'
                for m in x.get('tool_result_meta', []))), None), '原生未执行结果')
        require('Permission denied by PermissionRequest hook' in json.dumps(denied), '未确认是原生 hook 拒绝')
        cancelled = self.wait(lambda: next((x for x in self.client_events if x.get('type') == 'control_cancel_request' and
            x.get('request_id') == control['request_id']), None), '原生 hook 结果取消备用 stdio 权限请求')
        self.report.update(nativeDenialResultSeen=True, nativeNonExecutionResult=denied, sdkRequestCancelled=cancelled)
        # 此版本拒绝发生在工具执行前，没有 PostToolUseFailure；不能伪造对应的工具终态。
        require(not any(x['payload']['hook_event_name'] in ('PostToolUse', 'PostToolUseFailure')
            for x in self.inputs), '原生拒绝场景出现了不应发生的工具执行后事件')
        state = base.read_json(self.diagnostics)
        require(not state.get('pendingInteraction') and not self.canary.exists(), '拒绝后仍在等待或已经写入')
        self.report['checks'].append({'stage': 'native-denial-observed', 'diagnostics': state, 'database': self.stored()})
        self.evidence.gates['second'].set()
        self.hook('Stop', native)
        result = self.wait(lambda: next((x for x in self.client_events if x.get('type') == 'result'), None), '原生回合结果')
        require(result.get('is_error') is False and result.get('result') == self.reply, '原生回合没有明确收尾')
        self.client.stdin.close()
        self.hook('SessionEnd', native)
        self.wait(lambda: self.client.poll() is not None, '原生客户端自然退出')

        def final_state():
            state = base.read_json(self.diagnostics)
            database = self.stored()
            if not state or not database or database['sessions'].get(self.session_id, {}).get('status') != 'completed':
                return None
            rows = state['visibleSessions']
            if len(rows) != 1 or rows[0]['id'] != self.session_id or rows[0]['status'] != 'completed':
                return None
            require(not state.get('pendingInteraction') and database['userMessages'][self.session_id] == [self.prompt], '结束交互或用户历史异常')
            tools = database['tools']
            require(len(tools) == 1 and tools[0]['tool'] == 'Write' and tools[0]['toolCallId'] == self.tool_id and
                not tools[0]['isComplete'] and tools[0]['result'] is None and tools[0]['completionUnconfirmed'],
                '会话结束后缺失终态的工具仍被标为运行中或被伪造成成功')
            return {'stage': 'native-session-ended', 'diagnostics': state, 'database': database}

        self.report['checks'].append(self.wait(final_state, '拒绝历史持久化'))
        require(not self.canary.exists(), '目标文件被创建')
        require(len(self.evidence.hooks) == 6 and all(r['consumed'] for r in self.evidence.hooks), '原生事件缺失或重复')
        require(sum(x.get('type') == 'control_request' and x.get('request', {}).get('subtype') == 'can_use_tool'
            for x in self.client_events) == 1, 'stdio 权限请求不是恰好一次')
        require(len(self.stdin_packets) == 2 and all(x['type'] != 'control_response' for x in self.stdin_packets),
            '驱动替代了岛上决定')
        require(digest(self.deny_helper) == self.report['denyHelperSHA256'] and digest(Path(__file__)) == self.report['entrypointSHA256'],
            '拒绝工具或脚本在执行中变化')
        self.report.update(passed=True, nativeApprovalVerified=False, nativePermissionRequestAndDenialVerified=True,
            xIslandDenialVerified=True, fullApprovalControlVerified=False,
            approvalGranted=False, nativeHookCount=6, permissionRequests=1, clientExit=self.client.returncode,
            targetFileAbsent=True, sdkPermissionDecisionSent=False,
            toolHistoryOutcome='unconfirmed: native permission hook omits call ID and denial emits no post-tool hook',
            nativeEventTypes=[x['payload']['hook_event_name'] for x in self.evidence.hooks])


if __name__ == '__main__':
    read.Probe = RejectProbe
    read.__doc__ = __doc__
    raise SystemExit(read.main())
