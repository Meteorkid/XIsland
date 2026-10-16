#!/usr/bin/env python3
"""复用隔离设施，验证真实 Kimi 心跳、中断、恢复、模型失败与手动压缩。"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import threading
import time
import uuid

spec = importlib.util.spec_from_file_location('kimi_native_base', Path(__file__).with_name('test-kimi-native-client.py'))
assert spec is not None and spec.loader is not None
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
require = base.require
original_server = base.create_server


def lifecycle_server(evidence, port):
    server = original_server(evidence, port)
    original_handler = server.RequestHandlerClass
    evidence.model_requests = []
    evidence.cancelled = threading.Event()

    class Handler(original_handler):
        def do_POST(self):
            if self.path == '/hook-receipt':
                return super().do_POST()
            phase = evidence.phase
            try:
                require(self.path == '/v1/chat/completions', '出现非本地模型接口')
                size = int(self.headers.get('Content-Length', '0'))
                require(0 < size < 8 * 1024 * 1024, '模型请求长度异常')
                body = json.loads(self.rfile.read(size))
                require(body.get('stream') is True and body.get('model') == 'mock-model', '模型参数不符')
                require(self.headers.get('Authorization') == 'Bearer local-mock-only', '非测试密钥')
                main = bool(body.get('tools'))
                evidence.model_requests.append({'phase': phase, 'main': main, 'body': body})
                evidence.record('mock-requests', evidence.model_requests[-1])
                if phase == 'failure' and main:
                    require(evidence.gates[phase].wait(25), '失败场景没有放行')
                    payload = json.dumps({'error': {'message': evidence.failure_marker,
                        'type': 'invalid_request_error', 'code': 'xi_native_terminal'}}).encode()
                    self.send_response(400)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    return
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()
                common = {'id': 'fixture-' + uuid.uuid4().hex, 'object': 'chat.completion.chunk',
                          'created': int(time.time()), 'model': 'mock-model'}

                def chunk(delta, finish=None):
                    value = {**common, 'choices': [{'index': 0, 'delta': delta, 'finish_reason': finish}]}
                    self.wfile.write(('data: ' + json.dumps(value) + '\n\n').encode())
                    self.wfile.flush()

                if main and phase == 'interrupt':
                    chunk({'role': 'assistant', 'content': 'XI_NATIVE_HELD_PARTIAL'})
                    require(evidence.cancelled.wait(25), '中断场景没有发送取消')
                    # 已取消的流不发 finish_reason/DONE，不冒充一个完成的模型 step。
                    return
                gate = evidence.gates.get(phase) if main else None
                if gate is not None:
                    require(gate.wait(25), '模型阶段没有放行')
                chunk({'role': 'assistant', 'content': 'XI_NATIVE_SUMMARY' if phase == 'compact' else 'XI_NATIVE_REPLY'})
                chunk({}, 'stop')
                self.wfile.write(b'data: [DONE]\n\n')
                self.wfile.flush()
            except (AssertionError, OSError, ValueError) as error:
                if not evidence.closing:
                    evidence.fail(error)
                self.close_connection = True

    server.RequestHandlerClass = Handler
    return server


base.create_server = lifecycle_server


class Probe(base.NativeProbe):
    def __init__(self, args, report):
        super().__init__(args, report)
        self.users = {}
        self.turns = {}

    def check(self, stage, receipt, status):
        self.checkpoint(stage, receipt, status, pending=[])
        data = self.report['checks'][-1]['database']
        require(not data['tools'], stage + ': 不应出现工具执行')
        for sid, expected in self.users.items():
            require(data['userMessages'][sid] == expected, stage + ': 用户历史丢失或重复')
        for row in data['sessions'].values():
            observation = row['approval']
            require(not observation['pending'] and not observation['resolved'] and
                    not observation['hasUnidentifiedRequest'] and not observation['wasInterrupted'], '无审批场景产生了审批事实')

    def new(self):
        request = self.send('session/new', {'cwd': str(self.run / 'workspace'), 'mcpServers': []})
        start = self.hook('SessionStart')
        native = start['payload']['session_id']
        require(start['payload']['source'] == 'startup', '新建会话来源不符')
        require(self.response(request)['result']['sessionId'] == native, 'ACP/hook会话不同')
        self.users['kimi_code-' + native] = []
        self.turns[native] = -1
        self.check('new-session', start, 'idle')
        return native, start

    def begin(self, native, phase):
        self.evidence.phase = phase
        self.evidence.gates[phase] = threading.Event()
        text = 'XI_NATIVE_' + phase.upper() + '_' + uuid.uuid4().hex
        request = self.send('session/prompt', {'sessionId': native, 'prompt': [{'type': 'text', 'text': text}]})
        submitted = self.hook('UserPromptSubmit', native)
        require(submitted['payload']['prompt'] == [{'type': 'text', 'text': text}], '原生提示载荷不符')
        turn = self.hook('TurnStarted', native)
        require(turn['payload']['turn_id'] == self.turns[native] + 1, '原生回合计数未正确恢复')
        self.turns[native] += 1
        self.users['kimi_code-' + native].append(text)
        self.check(phase + '-started', turn, 'active')
        return request, turn

    def finish(self, native, phase, request):
        self.evidence.gates[phase].set()
        stopped = self.hook('Stop', native)
        self.check(phase + '-stopped', stopped, 'completionUnconfirmed')
        require(self.response(request)['result']['stopReason'] == 'end_turn', '普通回合没有结束')

    def close(self, native):
        request = self.send('session/close', {'sessionId': native})
        ended = self.hook('SessionEnd', native)
        require(ended['payload']['reason'] == 'exit', '关闭原因不符')
        self.check('closed', ended, 'completed')
        self.response(request)

    def restart_client(self):
        old = self.client
        os.killpg(old.pid, signal.SIGTERM)
        old.wait(timeout=5)
        self.processes.remove(old)
        self.report['retiredClient'] = {'pid': old.pid, 'returncode': old.returncode}
        self.client = self.spawn(['/usr/bin/sandbox-exec', '-f', str(self.args.sandbox_profile),
            str(self.args.node), str(self.args.bundle), 'acp'], self.client_env, 'resumed-client.stderr.log', acp=True)
        threading.Thread(target=self.read_acp, daemon=True).start()
        response = self.response(self.send('initialize', {'protocolVersion': 1, 'clientCapabilities': {},
            'clientInfo': {'name': 'xisland-lifecycle-probe', 'version': '1.0'}}))
        require(response['result']['agentInfo']['version'] == '2.1.1', '恢复客户端版本变化')
        self.report['resumedClientPID'] = self.client.pid

    def verify(self):
        native, start = self.new()
        waiting_from = time.monotonic()
        print('Waiting for the unmodified native 60-second heartbeat', flush=True)
        self.wait(lambda: any(r['payload']['hook_event_name'] == 'SessionHeartbeat' for r in self.evidence.hooks),
                  '真实60秒心跳', timeout=75)
        heartbeat = self.hook('SessionHeartbeat', native)
        require(heartbeat['payload']['uptime_ms'] >= 60_000, '心跳未达到原生周期')
        self.check('native-heartbeat-keeps-idle', heartbeat, 'idle')
        self.report['heartbeat'] = {'payload': heartbeat['payload'], 'waitSeconds': time.monotonic() - waiting_from}
        require(not any(r['main'] for r in self.evidence.model_requests), '空闲心跳触发了模型')

        interval = len(self.evidence.hooks)
        request, turn = self.begin(native, 'interrupt')
        self.wait(lambda: any(u.get('sessionId') == native and u.get('update', {}).get('content', {}).get('text') ==
                  'XI_NATIVE_HELD_PARTIAL' for u in self.evidence.updates), '原生模型部分输出')
        busy_text = 'XI_REJECTED_BUSY_' + uuid.uuid4().hex
        busy_id = self.send('session/prompt', {'sessionId': native, 'prompt': [{'type': 'text', 'text': busy_text}]})
        busy = self.wait(lambda: self.evidence.responses.get(busy_id), '忙碌请求拒绝')
        require(busy.get('error', {}).get('code') == -32600 and
                busy['error'].get('data', {}).get('code') == 'turn.agent_busy', 'ACP并未原生拒绝并发prompt')
        self.write_acp({'jsonrpc': '2.0', 'method': 'session/cancel', 'params': {'sessionId': native}})
        interrupted = self.hook('Interrupt', native)
        require(interrupted['payload']['turn_id'] == turn['payload']['turn_id'] and
                interrupted['payload']['reason'] == 'cancelled', '中断归属不符')
        require(self.response(request)['result']['stopReason'] == 'cancelled', '原生prompt没有确认取消')
        self.evidence.cancelled.set()
        self.check('cancel-is-not-session-end', interrupted, 'completionUnconfirmed')
        cancelled_events = [r['payload'] for r in self.evidence.hooks[interval:]]
        require(not any(p['hook_event_name'] in ('Stop', 'StopFailure', 'SessionEnd', 'UserPromptQueued') for p in cancelled_events),
                '取消场景被误判为正常收尾或排队')
        require(sum(p['hook_event_name'] == 'UserPromptSubmit' for p in cancelled_events) == 1, 'busy prompt进入了原生提交')
        self.report['cancelInterval'] = cancelled_events
        self.report['busyRejectedPrompt'] = busy_text

        request, _ = self.begin(native, 'after_cancel')
        self.finish(native, 'after_cancel', request)
        self.close(native)
        self.restart_client()
        params = {'sessionId': native, 'cwd': str(self.run / 'workspace'), 'mcpServers': []}
        resume = self.send('session/resume', params)
        resumed = self.hook('SessionStart', native)
        require(resumed['payload']['source'] == 'resume', '原生恢复来源不符')
        self.response(resume)
        self.check('same-session-after-client-restart', resumed, 'idle')
        before = len(self.evidence.hooks)
        replay_from = len(self.evidence.updates)
        self.response(self.send('session/load', params))
        require(not any(r['payload']['hook_event_name'] in ('SessionStart', 'UserPromptSubmit', 'TurnStarted')
                        for r in self.evidence.hooks[before:]), 'live load重放变成新活动')
        replayed = '\n'.join(u['update'].get('content', {}).get('text', '')
            for u in self.evidence.updates[replay_from:] if u.get('sessionId') == native
            and u['update'].get('sessionUpdate') == 'user_message_chunk')
        require(all(replayed.count(text) == 1 for text in self.users['kimi_code-' + native]),
                'ACP没有准确重播原有用户提示')
        self.report['replayedUserPrompts'] = self.users['kimi_code-' + native].copy()
        self.check('history-replay-does-not-duplicate-prompts', resumed, 'idle')
        request, _ = self.begin(native, 'after_resume')
        self.finish(native, 'after_resume', request)

        self.evidence.phase = 'compact'
        self.evidence.gates['compact'] = threading.Event()
        compact_from = len(self.evidence.hooks)
        compact = self.send('session/prompt', {'sessionId': native,
            'prompt': [{'type': 'text', 'text': '/compact XI_NATIVE_COMPACT'}]})
        pre = self.hook('PreCompact', native)
        require(pre['payload']['trigger'] == 'manual', '不是手动压缩')
        self.check('manual-compaction-started', pre, 'compacting')
        held_until = time.monotonic() + 3.3

        def remains_compacting():
            state = base.read_json(self.diagnostics)
            require(state['visibleSessions'][0]['status'] == 'compacting', '压缩仍未返回，状态却被计时器修改')
            return time.monotonic() >= held_until

        self.wait(remains_compacting, '慢压缩超过旧三秒计时器', timeout=6)
        self.check('slow-compaction-waits-for-native-receipt', pre, 'compacting')
        self.evidence.gates['compact'].set()
        post = self.hook('PostCompact', native)
        require(post['payload']['trigger'] == 'manual', '手动压缩结果来源不符')
        self.response(compact)
        self.wait(lambda: any(u.get('sessionId') == native and
            u.get('update', {}).get('content', {}).get('text', '').startswith('Compaction completed.')
            for u in self.evidence.updates), 'ACP原生压缩完成通知')
        wire_rows = [json.loads(line) for path in (self.run / 'kimi/sessions').rglob('wire.jsonl')
            for line in path.read_text().splitlines() if native in str(path)]
        applied = [row for row in wire_rows if row.get('type') == 'context.apply_compaction']
        require(len(applied) == 1 and applied[0].get('summary') == 'XI_NATIVE_SUMMARY', '缺少本次原生压缩应用记录')
        require(any(row.get('type') == 'full_compaction.complete' for row in wire_rows), '原生压缩未完成')
        self.report['nativeCompactionApplied'] = {k: v for k, v in applied[0].items() if k != 'contextSummary'}
        self.check('manual-compaction-does-not-create-running-turn', post, 'completionUnconfirmed')
        require(not any(r['payload']['hook_event_name'] in ('TurnStarted', 'Stop', 'UserPromptSubmit')
                        for r in self.evidence.hooks[compact_from:]), '手动压缩被当成新用户回合')
        self.close(native)

        failed_native, _ = self.new()
        self.evidence.failure_marker = 'XI_NATIVE_FAILURE_' + uuid.uuid4().hex
        request, _ = self.begin(failed_native, 'failure')
        self.evidence.gates['failure'].set()
        failed = self.hook('StopFailure', failed_native)
        require(self.evidence.failure_marker in failed['payload']['error_message'], '失败事件未包含本次错误标记')
        self.check('native-model-failure', failed, 'error')
        self.report['failedACPResponse'] = self.response(request)
        require(sum(r['phase'] == 'failure' and r['main'] for r in self.evidence.model_requests) == 1, 'HTTP400出现非预期重试')
        self.close(failed_native)
        require(not self.evidence.permissions, '无工具场景出现审批')
        require(all(r['bridge']['returncode'] == 0 and r['bridge']['stdout'] == '' for r in self.evidence.hooks), '原生hook桥接失败')
        require(base.read_json(self.diagnostics)['handledMessageCount'] == self.initial_handled + len(self.evidence.hooks), '事件和App回执不一致')
        self.report.update(passed=True, nativeHookCount=len(self.evidence.hooks),
            nativeEventTypes=sorted({r['payload']['hook_event_name'] for r in self.evidence.hooks}),
            expectedUserMessages=self.users, nativeTurnCounters=self.turns)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for flag in ('bundle', 'node', 'sandbox-profile', 'runtime', 'app', 'hooks-block', 'report'):
        parser.add_argument('--' + flag, type=Path, required=True)
    parser.add_argument('--port', type=int, required=True)
    args = parser.parse_args()
    report = {'passed': False, 'checkedAt': datetime.now(timezone.utc).isoformat(),
        'scope': 'Real Kimi Node 2.1.1 ACP, local mock, original heartbeat clock, cancel, busy rejection, restart/resume, manual compaction and HTTP400 failure',
        'realProviderVerified': False, 'approvalGrantSent': False, 'queueEventVerified': False,
        'helperSHA256': base.digest(Path(__file__).with_name('test-kimi-native-client.py'))}
    probe = None

    def deadline(_signal, _frame):
        raise TimeoutError('达到180秒固定总时限')

    previous = signal.signal(signal.SIGALRM, deadline)
    signal.alarm(180)
    try:
        for name in ('bundle', 'node', 'sandbox_profile', 'app', 'hooks_block'):
            setattr(args, name, getattr(args, name).resolve(strict=True))
        probe = Probe(args, report)
        probe.prepare()
        probe.start()
        probe.verify()
        require(base.digest(args.bundle) == report['bundleSHA256'] and base.digest(probe.binary) == report['appSHA256']
                and base.digest(probe.bridge) == report['bridgeSHA256'], '测试中产物被替换')
    except (AssertionError, OSError, ValueError, KeyError, TimeoutError, sqlite3.Error, subprocess.SubprocessError) as error:
        report.update(passed=False, error=str(error))
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)
        if probe is not None:
            report['lastDiagnostics'] = base.read_json(probe.diagnostics)
            try:
                report['lastDatabase'] = probe.stored()
            except (OSError, sqlite3.Error, subprocess.SubprocessError) as error:
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
