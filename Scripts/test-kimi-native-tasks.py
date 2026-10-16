#!/usr/bin/env python3
"""隔离验证真实 Kimi Read 与后台 Agent；保留原生事实，不声称已验证完整任务树。"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import signal
import sqlite3
import subprocess
import threading
import time
from typing import Any
import uuid

spec = importlib.util.spec_from_file_location('kimi_native_base', Path(__file__).with_name('test-kimi-native-client.py'))
assert spec is not None and spec.loader is not None
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
require = base.require
original_server = base.create_server
READ_CALL = 'native_read_probe'
AGENT_CALL = 'native_background_agent_probe'


def texts(message: dict[str, Any]) -> list[str]:
    content = message.get('content', '')
    if isinstance(content, str):
        return [content]
    return [part['text'] for part in content if isinstance(part, dict) and part.get('type') == 'text']


def tasks_server(evidence, port):
    server = original_server(evidence, port)
    original_handler = server.RequestHandlerClass
    evidence.model_requests = []

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
                require(self.headers.get('Authorization') == 'Bearer local-mock-only', '出现非测试凭据')
                users = [text for message in body['messages'] if message.get('role') == 'user' for text in texts(message)]
                tool_messages = [message for message in body['messages'] if message.get('role') == 'tool']
                names = {item.get('function', {}).get('name') for item in body.get('tools', [])}
                role, call, gate = 'auxiliary', None, None
                reply = 'XI_NATIVE_AUXILIARY'
                if names and evidence.read_prompt in users:
                    results = [message for message in tool_messages if message.get('tool_call_id') == READ_CALL]
                    role = 'read-result' if results else 'read-call'
                    gate = role
                    if results:
                        require(len(results) == 1 and evidence.read_marker in ''.join(texts(results[0])), '模型未收到真实 Read marker')
                        reply = 'XI_NATIVE_READ_OK'
                    else:
                        require('Read' in names, '原生模型请求没有 Read 工具')
                        call = ('Read', READ_CALL, {'path': str(evidence.read_path), 'n_lines': 1, 'max_chars': 1024})
                elif names and evidence.child_prompt in users and evidence.parent_prompt not in users:
                    role, gate, reply = 'child', 'child', evidence.child_reply
                    require('Read' in names and not names.intersection({'Bash', 'Edit', 'Write', 'Agent'}), '子代理不是预期 plan 工具范围')
                elif names and evidence.parent_prompt in users:
                    notifications = [text for text in users if '<notification' in text and 'type="task.completed"' in text]
                    results = [message for message in tool_messages if message.get('tool_call_id') == AGENT_CALL]
                    if notifications:
                        role, gate, reply = 'task-result', 'task-result', 'XI_NATIVE_TASK_NOTICE_OK'
                        require(evidence.task_id and any('source_id="' + evidence.task_id + '"' in text for text in notifications),
                                '通知模型请求不是已记录的后台任务')
                    elif results:
                        role, gate, reply = 'parent-result', 'parent-result', 'XI_NATIVE_PARENT_OK'
                        require(len(results) == 1, '父回合工具结果重复')
                    else:
                        role, gate = 'parent-call', 'parent-call'
                        require('Agent' in names, '原生模型请求没有 Agent 工具')
                        call = ('Agent', AGENT_CALL, {'prompt': evidence.child_prompt, 'description': 'Native child probe',
                            'subagent_type': 'plan', 'run_in_background': True})
                else:
                    require(not names, '无法通过用户消息识别原生模型请求')
                record = {'phase': evidence.phase, 'role': role, 'body': body}
                with evidence.condition:
                    evidence.model_requests.append(record)
                    evidence.record('mock-requests', record)
                if gate:
                    require(evidence.gates[gate].wait(45), '模型门闩超时：' + gate)
                require(not evidence.closing, '测试正在退出')
                delta = {'role': 'assistant', 'content': reply}
                if call:
                    name, call_id, arguments = call
                    delta = {'tool_calls': [{'index': 0, 'id': call_id, 'type': 'function',
                        'function': {'name': name, 'arguments': json.dumps(arguments)}}]}
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()
                common = {'id': 'fixture-' + uuid.uuid4().hex, 'object': 'chat.completion.chunk',
                    'created': int(time.time()), 'model': 'mock-model'}
                for change, finish in ((delta, None), ({}, 'tool_calls' if call else 'stop')):
                    chunk = {**common, 'choices': [{'index': 0, 'delta': change, 'finish_reason': finish}]}
                    self.wfile.write(('data: ' + json.dumps(chunk) + '\n\n').encode())
                self.wfile.write(b'data: [DONE]\n\n')
                self.wfile.flush()
            except (AssertionError, OSError, ValueError, KeyError, TypeError) as error:
                if not evidence.closing:
                    evidence.fail(error)
                self.close_connection = True

    server.RequestHandlerClass = Handler
    return server


base.create_server = tasks_server


class Probe(base.NativeProbe):
    def __init__(self, args, report):
        super().__init__(args, report)
        self.rejected_permissions = set()
        evidence = self.evidence
        evidence.read_prompt = 'XI_NATIVE_READ_PROMPT_' + uuid.uuid4().hex
        evidence.read_marker = 'XI_NATIVE_READ_CONTENT_' + uuid.uuid4().hex
        evidence.parent_prompt = 'XI_NATIVE_PARENT_PROMPT_' + uuid.uuid4().hex
        evidence.child_prompt = 'XI_NATIVE_CHILD_PROMPT_' + uuid.uuid4().hex
        evidence.child_reply = 'XI_NATIVE_CHILD_REPLY_' + uuid.uuid4().hex
        evidence.read_path = self.run / 'workspace/read-probe.txt'
        evidence.task_id = None
        for gate in ('read-call', 'read-result', 'parent-call', 'parent-result', 'child', 'task-result'):
            evidence.gates[gate] = threading.Event()

    def prepare(self):
        super().prepare()
        self.evidence.read_path.write_text(self.evidence.read_marker + '\n')
        self.report['readFile'] = {'path': str(self.evidence.read_path), 'sha256': base.digest(self.evidence.read_path),
            'marker': self.evidence.read_marker}
        config = self.run / 'kimi/config.toml'
        require('default_permission_mode = "manual"' in config.read_text() and 'decision = "allow"' not in config.read_text(),
                '权限配置被放宽')
        self.report['configSHA256'] = base.digest(config)

    def wait(self, check, description, timeout=20):
        def guarded():
            for request in self.evidence.permissions:
                if request['id'] not in self.rejected_permissions:
                    options = request['params']['options']
                    require(any(option.get('optionId') == 'reject' and option.get('kind') == 'reject_once' for option in options),
                            '原生审批没有明确 reject 选项')
                    self.write_acp({'jsonrpc': '2.0', 'id': request['id'],
                        'result': {'outcome': {'outcome': 'selected', 'optionId': 'reject'}}})
                    self.rejected_permissions.add(request['id'])
                    self.report['scenarios'][self.evidence.phase] = {'verified': False, 'reason': 'unexpected permission request explicitly rejected'}
            require(not self.rejected_permissions, '默认 manual 场景出现审批，已显式拒绝，场景未验收')
            return check()
        return super().wait(guarded, description, timeout)

    def snapshot(self, stage, receipt=None, status=None):
        # 子代理 hooks 共用 session_id；只检查当前真实快照，不假定交错事件的全局顺序。
        def settled():
            state = base.read_json(self.diagnostics)
            if state is None or state.get('handledMessageCount', -1) < self.initial_handled + len(self.evidence.hooks):
                return None
            data = self.stored()
            if data is None:
                return None
            visible = {row['id']: row for row in state['visibleSessions']}
            if {sid: row['status'] for sid, row in visible.items()} != {sid: row['status'] for sid, row in data['sessions'].items()}:
                return None
            require(set(visible) == set(self.expected), stage + ': 会话集合异常')
            require(state.get('pendingInteraction') is None, stage + ': 观察事件变成 App 审批')
            for sid, prompt in self.prompts.items():
                if data['userMessages'].get(sid) != [prompt]:
                    return None
            for sid, row in visible.items():
                require(row['agentType'] == 'kimi' and row.get('pendingInteraction') is None, '会话来源或交互异常')
                require((row.get('completedAt') is not None) == (row['status'] == 'completed'), 'App 完成时间不符')
                stored = data['sessions'][sid]
                require(stored['agent'] == 'kimi' and (stored['completedAt'] is not None) == (stored['status'] == 'completed'),
                        'SQLite 来源或完成时间不符')
                approval = stored.get('approval')
                require(approval is None or (not approval['pending'] and not approval['resolved'] and
                    not approval['hasUnidentifiedRequest'] and not approval['wasInterrupted']), '无审批场景产生审批事实')
            if status is not None and visible['kimi_code-' + receipt['payload']['session_id']]['status'] != status:
                return None
            return {'stage': stage, 'diagnostics': state, 'database': data,
                'nativePayload': receipt['payload'] if receipt else None, 'nativeHookCount': len(self.evidence.hooks)}
        result = self.wait(settled, 'App/SQLite阶段：' + stage)
        self.report['checks'].append(result)
        self.evidence.record('checkpoints', result)
        return result

    def new(self, phase, prompt):
        self.evidence.phase = phase
        request = self.send('session/new', {'cwd': str(self.run / 'workspace'), 'mcpServers': []})
        start = self.hook('SessionStart')
        native = start['payload']['session_id']
        created = self.response(request)['result']
        require(start['payload']['source'] == 'startup' and created['sessionId'] == native and
                created['modes']['currentModeId'] == 'default', '会话来源或默认 manual 模式不符')
        self.expected['kimi_code-' + native] = 'idle'
        self.snapshot(phase + '-new', start, 'idle')
        request = self.send('session/prompt', {'sessionId': native, 'prompt': [{'type': 'text', 'text': prompt}]})
        submitted = self.hook('UserPromptSubmit', native)
        require(submitted['payload']['prompt'] == [{'type': 'text', 'text': prompt}], '原生用户提示不符')
        self.prompts['kimi_code-' + native] = prompt
        turn = self.hook('TurnStarted', native)
        self.snapshot(phase + '-turn-start', turn, 'active')
        return native, request, turn

    def close(self, native, phase):
        request = self.send('session/close', {'sessionId': native})
        ended = self.hook('SessionEnd', native)
        require(ended['payload']['reason'] == 'exit', '原生关闭原因不符')
        self.response(request)
        self.snapshot(phase + '-session-end', ended, 'completed')

    def wire(self, native):
        rows = []
        for path in (self.run / 'kimi/sessions').rglob('wire.jsonl'):
            if native not in path.parts:
                continue
            for line in path.read_text().splitlines():
                try:
                    rows.append({'path': str(path.relative_to(self.run)), **json.loads(line)})
                except json.JSONDecodeError:
                    # 追加中的最后一行留给下一轮；原始文件始终保留。
                    continue
        return rows

    def model(self, role):
        return self.wait(lambda: next((row for row in self.evidence.model_requests if row['role'] == role), None),
                         '真实模型请求 ' + role)

    def verify_read(self):
        evidence = self.evidence
        native, request, turn = self.new('read', evidence.read_prompt)
        evidence.gates['read-call'].set()
        before = self.hook('PreToolUse', native)
        after = self.hook('PostToolUse', native)
        for receipt in (before, after):
            payload = receipt['payload']
            require(payload['tool_name'] == 'Read' and payload['tool_call_id'] == READ_CALL and
                    payload['tool_input'] == {'path': str(evidence.read_path), 'n_lines': 1, 'max_chars': 1024}, 'Read 身份或输入不符')
        require(evidence.read_marker in after['payload']['tool_output'], '真实 Read 输出缺少 marker')
        self.model('read-result')
        snapshot = self.snapshot('read-post-tool', after)
        rows = [row for row in snapshot['database']['tools'] if row['sessionId'] == 'kimi_code-' + native]
        require(len(rows) == 1 and rows[0]['tool'] == 'Read' and rows[0]['toolCallId'] == READ_CALL and
                rows[0]['isComplete'] and evidence.read_marker in rows[0]['result'], 'SQLite 未唯一完成 Read 记录')
        require(base.digest(evidence.read_path) == self.report['readFile']['sha256'], 'Read 修改了预置文件')
        evidence.gates['read-result'].set()
        stopped = self.hook('Stop', native)
        require(self.response(request)['result']['stopReason'] == 'end_turn', 'Read 回合没有正常结束')
        self.snapshot('read-stopped', stopped, 'completionUnconfirmed')
        self.close(native, 'read')
        self.report['scenarios']['read'] = {'verified': True, 'sessionId': native, 'toolCallId': READ_CALL,
            'fileUnchanged': True, 'realToolOutputAndModelResultVerified': True, 'uniqueCompletedSQLiteToolVerified': True}

    def verify_background(self):
        evidence = self.evidence
        native, request, parent_turn = self.new('background', evidence.parent_prompt)
        first = len(evidence.hooks)
        evidence.gates['parent-call'].set()
        before = self.hook('PreToolUse', native)
        require(before['payload']['tool_name'] == 'Agent' and before['payload']['tool_call_id'] == AGENT_CALL,
                '后台工具身份不符')
        task = self.hook('TaskStarted', native)
        payload = task['payload']
        require(payload['kind'] == 'agent' and payload['status'] == 'running' and payload['detached'] is True,
                '不是原生后台 Agent 任务')
        evidence.task_id = payload['task_id']
        child_start = self.hook('SubagentStart', native)
        require(child_start['payload']['agent_name'] == 'plan' and child_start['payload']['prompt'] == evidence.child_prompt,
                'SubagentStart 不是本次子代理')
        after = self.hook('PostToolUse', native)
        require(after['payload']['tool_name'] == 'Agent' and after['payload']['tool_call_id'] == AGENT_CALL,
                'Agent 前后事件不匹配')
        self.model('child')
        self.model('parent-result')
        spawned = self.wait(lambda: next((row for row in self.wire(native) if row.get('type') == 'subagent.spawned'
            and row.get('parentToolCallId') == AGENT_CALL and row.get('taskId') == evidence.task_id), None), '原生父子 wire 关联')
        require(spawned['parentAgentId'] == 'main' and spawned['runInBackground'] is True, '原生父子关系不符')
        self.snapshot('background-child-held', task)
        evidence.gates['parent-result'].set()
        parent_stop = self.hook('Stop', native)
        require(self.response(request)['result']['stopReason'] == 'end_turn', '父初始回合未正常结束')
        self.wait(lambda: any(row.get('type') == 'turn.ended' and row.get('agentId') == 'main' and
            row.get('turnId') == parent_turn['payload']['turn_id'] and row.get('reason') == 'completed'
            for row in self.wire(native)), '父初始 wire 回合完成')
        held_snapshot = self.snapshot('parent-stopped-child-still-held', parent_stop, 'completionUnconfirmed')
        sid = 'kimi_code-' + native
        held_tasks = [row for row in held_snapshot['database']['tools'] if row['sessionId'] == sid and row['tool'] == 'Subagent']
        require(len(held_tasks) == 1 and not held_tasks[0]['isComplete'] and held_tasks[0]['toolCallId'] is None,
                '父回合停止后没有独立的运行中后台任务记录')
        require(next(row for row in held_snapshot['diagnostics']['visibleSessions'] if row['id'] == sid)['runningSubagentCount'] == 1,
                '实际App没有将后台任务计入活动')
        require(held_snapshot['database']['sessions'][sid]['approval']['backgroundTasks'][evidence.task_id]['status'] == 'running',
                '原生任务ID未保存为运行中')
        require(not evidence.gates['child'].is_set(), '子代理过早释放')
        released_at = len(evidence.hooks)
        evidence.gates['child'].set()
        child_stop = self.hook('SubagentStop', native)
        require(child_stop['payload']['agent_name'] == 'plan' and evidence.child_reply in child_stop['payload']['response'],
                '子代理没有返回真实短回答')
        notification = self.hook('Notification', native)
        notice = notification['payload']
        require(notice['sink'] == 'context' and notice['notification_type'] == 'task.completed' and
                notice['source_kind'] == 'background_task' and notice['source_id'] == evidence.task_id,
                '任务完成通知身份不符')
        self.model('task-result')
        task_turn = self.wait(lambda: next((receipt for receipt in evidence.hooks[released_at:]
            if receipt['payload'].get('session_id') == native and receipt['payload'].get('hook_event_name') == 'TurnStarted'
            and receipt['payload'].get('origin_kind') == 'task'), None), '真实任务来源后续回合')
        self.wait(lambda: any(row.get('type') == 'turn.ended' and row.get('agentId') == spawned['subagentId']
            and row.get('reason') == 'completed' for row in self.wire(native)), '子代理原生 wire 完成')
        self.snapshot('task-notification-model-held', notification)
        before_task_finish = len(evidence.hooks)
        evidence.gates['task-result'].set()
        self.wait(lambda: any(row.get('type') == 'turn.ended' and row.get('agentId') == 'main' and
            row.get('turnId') == task_turn['payload']['turn_id'] and row.get('reason') == 'completed'
            for row in self.wire(native)), '任务通知来源的父 wire 回合完成')
        self.wait(lambda: any(receipt['payload'].get('session_id') == native and receipt['payload'].get('hook_event_name') == 'Stop'
            for receipt in evidence.hooks[before_task_finish:]), '任务通知回合真实 Stop')
        finished_snapshot = self.snapshot('background-turns-finished')
        finished_tasks = [row for row in finished_snapshot['database']['tools'] if row['sessionId'] == sid and row['tool'] == 'Subagent']
        require(len(finished_tasks) == 1 and finished_tasks[0]['isComplete'] and
                finished_tasks[0]['toolCallId'] is None and
                finished_tasks[0]['result'] == '\n'.join(value for value in (notice['title'], notice['body']) if value),
                '后台任务没有按原生结果唯一收尾')
        require(next(row for row in finished_snapshot['diagnostics']['visibleSessions'] if row['id'] == sid)['runningSubagentCount'] == 0,
                '后台结果后仍残留运行中计数')
        require(finished_snapshot['database']['sessions'][sid]['approval']['backgroundTasks'][evidence.task_id]['status'] == 'completed',
                '原生任务终态未持久化')
        self.close(native, 'background')
        self.report['scenarios']['background'] = {'verified': True, 'sessionId': native, 'taskId': evidence.task_id,
            'spawned': spawned, 'notification': notice, 'taskTurn': task_turn['payload'],
            'parentStoppedWhileChildHeld': held_snapshot, 'nativePayloads': [r['payload'] for r in evidence.hooks[first:]],
            'fullTaskTreeVerified': False,
            'flatBackgroundAgentTrackingVerified': True,
            'observedLimitation': 'Task ID verifies a session-local background agent record; hooks do not provide a complete parent-child agent tree.'}

    def verify(self):
        initialized = self.evidence.responses[1]['result']
        require(initialized['agentInfo']['version'] == '2.1.1', '不是固定 Kimi Code 2.1.1')
        self.verify_read()
        self.verify_background()
        require(not self.evidence.permissions, '出现非预期审批')
        require(all(receipt['bridge']['returncode'] == 0 and receipt['bridge']['stdout'] == '' for receipt in self.evidence.hooks),
                '原生 hook bridge 失败或产生审批输出')
        require(base.read_json(self.diagnostics)['handledMessageCount'] == self.initial_handled + len(self.evidence.hooks),
                'App 处理计数与原生 hook 不同')
        require(base.digest(self.evidence.read_path) == self.report['readFile']['sha256'], 'Read 文件最终 hash 变化')
        self.report.update(passed=True, nativeHookCount=len(self.evidence.hooks),
            nativeEventTypes=sorted({r['payload']['hook_event_name'] for r in self.evidence.hooks}),
            modelRequestRoles=[row['role'] for row in self.evidence.model_requests], bridgeStdoutEmpty=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for flag in ('bundle', 'node', 'sandbox-profile', 'runtime', 'app', 'hooks-block', 'report'):
        parser.add_argument('--' + flag, type=Path, required=True)
    parser.add_argument('--port', type=int, required=True)
    args = parser.parse_args()
    report = {'passed': False, 'checkedAt': datetime.now(timezone.utc).isoformat(),
        'scope': 'Real Kimi Node 2.1.1 ACP, local mock, actual Read and background Agent hooks, App and SQLite observations',
        'realProviderVerified': False, 'fullTaskTreeVerified': False, 'approvalGrantSent': False,
        'nonTestCredentialsUsed': False, 'scenarios': {'read': {'verified': False}, 'background': {'verified': False}},
        'helperSHA256': base.digest(Path(__file__).with_name('test-kimi-native-client.py')), 'driverSHA256': base.digest(Path(__file__))}
    probe = None

    def deadline(_signal, _frame):
        raise TimeoutError('达到180秒固定总时限')

    previous = signal.signal(signal.SIGALRM, deadline)
    signal.alarm(180)
    try:
        for name in ('bundle', 'node', 'sandbox_profile', 'runtime', 'app', 'hooks_block'):
            setattr(args, name, getattr(args, name).resolve(strict=True))
        require(0 < args.port < 65536, '端口必须与调用者审查过的本地沙箱一致')
        require(base.digest(args.bundle) == '2563a338c94868a34e1bfd2e5579067d5a472acf4cb0bf350a3bfe1092bbe59d',
                '客户端不是已核验的官方2.1.1发布包')
        require(args.sandbox_profile == args.runtime / 'client.sb' and args.hooks_block == args.runtime / 'generated-hooks.toml',
                '必须复用现有沙箱及产品生成 hooks')
        probe = Probe(args, report)
        probe.prepare()
        probe.start()
        probe.verify()
        for path, key in ((args.bundle, 'bundleSHA256'), (args.node, 'nodeSHA256'), (args.sandbox_profile, 'sandboxProfileSHA256'),
                (args.hooks_block, 'hooksBlockSHA256'), (probe.binary, 'appSHA256'), (probe.bridge, 'bridgeSHA256'),
                (probe.run / 'kimi/config.toml', 'configSHA256'), (Path(__file__), 'driverSHA256'),
                (Path(__file__).with_name('test-kimi-native-client.py'), 'helperSHA256')):
            require(base.digest(path) == report[key], '测试中源码、配置或产物被替换：' + str(path))
        report['hashesUnchanged'] = True
    except (AssertionError, OSError, ValueError, KeyError, TypeError, TimeoutError, sqlite3.Error, subprocess.SubprocessError) as error:
        report.update(passed=False, error=str(error))
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)
        if probe is not None:
            try:
                report['lastDiagnostics'] = base.read_json(probe.diagnostics)
                report['lastDatabase'] = probe.stored()
                report['nativeHookCount'] = len(probe.evidence.hooks)
                report['nativeEventTypes'] = sorted({r['payload']['hook_event_name'] for r in probe.evidence.hooks})
                report['bridgeStdoutEmpty'] = all(r['bridge']['stdout'] == '' for r in probe.evidence.hooks)
                report['permissionRequests'] = probe.evidence.permissions
                report['explicitlyRejectedPermissionIds'] = sorted(probe.rejected_permissions)
                report['backgroundErrors'] = probe.evidence.errors
            except (OSError, ValueError, KeyError, sqlite3.Error, subprocess.SubprocessError) as error:
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
