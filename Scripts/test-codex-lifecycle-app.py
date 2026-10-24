#!/usr/bin/env python3
"""Codex 合成生命周期 hooks → 包内桥接 → 隔离 App/只读 SQLite；不启动 Codex。"""
from __future__ import annotations

import argparse
from contextlib import closing
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import sqlite3
import subprocess
import sys
import tempfile
import time
from typing import Any, Callable
import uuid


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def verify(repository: Path, app: Path, report: dict[str, Any]) -> None:
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location(
        'xisland_finality_helpers', repository / 'Scripts/test-main-finality-app.py')
    require(spec is not None and spec.loader is not None, '缺少已有构建新鲜度核对器')
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    with (app / 'Contents/Info.plist').open('rb') as stream:
        executable = plistlib.load(stream).get('CFBundleExecutable')
    require(isinstance(executable, str) and bool(executable) and Path(executable).name == executable,
            '非法 App 主程序名')
    binary, bridge = app / 'Contents/MacOS' / executable, app / 'Contents/MacOS/di-bridge'
    report.update(appPath=str(app), bridgePath=str(bridge), appSHA256=helper.sha256(binary),
                  bridgeSHA256=helper.sha256(bridge))
    report['freshness'] = {'app': helper.verify_freshness(repository, binary, 'DynamicIsland'),
                           'bridge': helper.verify_freshness(repository, bridge, 'DIBridge')}

    runtime = Path(tempfile.mkdtemp(prefix='xi-codex-life-', dir='/tmp')).resolve()
    suite = 'dev.xisland.tests.codex-lifecycle-' + uuid.uuid4().hex
    diagnostics, history = runtime / 'diagnostics.json', runtime / 'history.store'
    project = runtime / 'project'
    project.mkdir()
    env = {key: value for key, value in os.environ.items()
           if not key.startswith('X_ISLAND_TEST_')}
    for key in ('DI_SESSION_ID', 'DI_SOCKET_PATH', 'DI_BRIDGE_DEBUG_LOG'):
        env.pop(key, None)
    # 与现有 Kimi 驱动一致，避免 Foundation 对未创建文件的 /private/tmp 解析差异。
    app_runtime = str(runtime).replace('/private/tmp/', '/tmp/', 1)
    env.update(X_ISLAND_TEST_MODE='1', X_ISLAND_TEST_RUNTIME_DIR=app_runtime,
               X_ISLAND_TEST_DEFAULTS_SUITE=suite, X_ISLAND_TEST_DIAGNOSTICS_PATH=app_runtime + '/diagnostics.json',
               X_ISLAND_DISABLE_ANIMATIONS='1', DI_SOCKET_PATH=str(runtime / 'di.sock'))
    native_ids = {name: 'synthetic-' + name + '-' + uuid.uuid4().hex for name in ('manual', 'auto')}
    session_ids = {name: 'codex-' + value for name, value in native_ids.items()}
    report.update(runtimeDirectory=str(runtime), defaultsSuite=suite, sessionIds=session_ids,
                  deadlineSeconds=120, messageReceipts=[], checks=[], appProcesses=[], bridgeProcesses=[])
    expected: dict[str, str] = {}
    prompts: dict[str, list[str]] = {}
    completed: dict[str, float] = {}
    start_times: dict[str, float] = {}
    deadline = time.monotonic() + report['deadlineSeconds']
    process: subprocess.Popen | None = None
    initial_handled = 0
    run_receipts = 0

    def remaining(cap: float) -> float:
        value = min(cap, deadline - time.monotonic())
        require(value > 0, '生命周期验证超过总截止时间')
        return value

    def record(name: str, value: Any) -> None:
        with (runtime / (name + '.jsonl')).open('a') as stream:
            stream.write(json.dumps(value, ensure_ascii=False, allow_nan=False) + '\n')

    def snapshot() -> dict[str, Any]:
        state = json.loads(diagnostics.read_text())
        rows = state.get('visibleSessions')
        require(isinstance(rows, list) and all(isinstance(row, dict) for row in rows),
                '诊断缺少会话数组')
        require(isinstance(state.get('handledMessageCount'), int), '诊断缺少消息处理完成计数')
        return state

    def wait(check: Callable[[], Any], description: str, timeout: float = 15) -> Any:
        local_deadline = time.monotonic() + remaining(timeout)
        while time.monotonic() < local_deadline:
            require(process is not None and process.poll() is None, '隔离 App 已退出：' + description)
            value = check()
            if value is not None and value is not False:
                return value
            time.sleep(min(0.05, remaining(0.05)))
        raise AssertionError('等待超时：' + description + '；现场：' + str(runtime))

    def stored() -> dict[str, Any] | None:
        if not history.exists():
            return None
        try:
            with closing(sqlite3.connect(history.as_uri() + '?mode=ro', uri=True, timeout=0.2)) as db:
                db.execute('PRAGMA query_only=ON')
                db.execute('BEGIN')
                columns = {row[1] for row in db.execute('PRAGMA table_info(ZSTOREDSESSION)')}
                require({'ZSESSIONID', 'ZAGENTTYPERAW', 'ZSTATUSRAW', 'ZCOMPLETEDAT', 'ZOBSERVATIONENDEDAT',
                         'ZSTARTTIME', 'ZHISTORYDATE', 'ZPROMPT', 'ZWORKINGDIRECTORY'} <= columns,
                        '历史 schema 已改变，不能继续声称通过')
                sessions = db.execute('SELECT ZSESSIONID,ZAGENTTYPERAW,ZSTATUSRAW,ZCOMPLETEDAT,'
                    'ZOBSERVATIONENDEDAT,ZSTARTTIME,ZHISTORYDATE,ZPROMPT,ZWORKINGDIRECTORY '
                    'FROM ZSTOREDSESSION ORDER BY ZSESSIONID').fetchall()
                messages = db.execute('SELECT s.ZSESSIONID,c.ZROLE,c.ZCONTENT,hex(c.ZMESSAGEID),c.ZTIMESTAMP '
                    'FROM ZSTOREDCHATMESSAGE c LEFT JOIN ZSTOREDSESSION s ON c.ZSESSION=s.Z_PK '
                    'ORDER BY s.ZSESSIONID,c.ZTIMESTAMP,c.Z_PK').fetchall()
                tools = db.execute('SELECT COUNT(*) FROM ZSTOREDTOOLEVENT').fetchone()[0]
            require(len({row[0] for row in sessions}) == len(sessions), '历史库出现重复会话')
            require(all(row[0] is not None for row in messages), '历史库出现失联聊天记录')
            return {'sessions': {row[0]: dict(zip(
                ('agent', 'status', 'completedAt', 'observationEndedAt', 'startTime', 'historyDate',
                 'prompt', 'workingDirectory'), row[1:])) for row in sessions},
                'messages': [{'sessionId': row[0], 'role': row[1], 'content': row[2],
                              'messageIdHex': row[3], 'timestamp': row[4]} for row in messages],
                'toolCount': tools}
        except sqlite3.OperationalError as error:
            if 'locked' in str(error).lower():
                return None
            raise

    def inspect(visible: dict[str, str] | None = None) -> dict[str, Any] | None:
        state = snapshot()
        if state['handledMessageCount'] != initial_handled + run_receipts:
            return None
        wanted = expected if visible is None else visible
        rows = {row.get('id'): row for row in state['visibleSessions']}
        if {key: row.get('status') for key, row in rows.items()} != wanted:
            return None
        require(len(rows) == len(state['visibleSessions']), '诊断出现重复会话')
        require(state.get('pendingInteraction') is None, '生命周期事件产生了全局审批/问答')
        database = stored()
        if database is None or {key: row['status'] for key, row in database['sessions'].items()} != expected:
            return None
        require(database['toolCount'] == 0, '生命周期事件伪造了工具记录')
        require(all(message['role'] == 'user' for message in database['messages']),
                '压缩/中断状态污染了助手聊天历史')
        for sid, status in expected.items():
            saved = database['sessions'][sid]
            require(saved['agent'] == 'codex', '历史来源身份不符')
            require(saved['workingDirectory'] == str(project), '历史工作目录逸出隔离项目')
            require(saved['observationEndedAt'] is None, '普通原生 hook 产生了观察来源结束时间')
            require((saved['completedAt'] is not None) == (status == 'completed'), '历史完成时间与状态不符')
            require(saved['historyDate'] == (saved['completedAt'] if status == 'completed' else saved['startTime']),
                    '历史日期不符合实际生命周期')
            if sid in start_times:
                require(saved['startTime'] == start_times[sid], '同会话原始开始时间发生改变')
            actual_prompts = [message['content'] for message in database['messages'] if message['sessionId'] == sid]
            if actual_prompts != prompts[sid] or saved['prompt'] != (prompts[sid][-1] if prompts[sid] else ''):
                return None
            require(all(message['messageIdHex'] for message in database['messages'] if message['sessionId'] == sid),
                    '用户历史缺少持久化身份')
            if sid in completed:
                require(saved['completedAt'] == completed[sid], '迟到生命周期事件改写了完成时间')
            if sid in rows:
                row = rows[sid]
                require(row.get('agentType') == 'codex' and row.get('pendingInteraction') is None,
                        '诊断来源/交互不符')
                require(row.get('runningSubagentCount') == 0, '生命周期事件伪造了运行子代理')
                require(row.get('workingDirectory') == str(project) and row.get('prompt') == saved['prompt'],
                        'App 与历史库的工作目录/用户提示不同步')
                require(row.get('completedAt') == saved['completedAt'], 'App 与历史库完成时间不同步')
                require(row.get('observationEndedAt') is None, 'App 产生了意外观察结束时间')
        return {'diagnostics': state, 'database': database}

    def checkpoint(stage: str, visible: dict[str, str] | None = None) -> dict[str, Any]:
        result = wait(lambda: inspect(visible), 'App/SQLite：' + stage)
        result = {'stage': stage, 'processId': process.pid, 'monotonicTime': time.monotonic(), **result}
        for sid, row in result['database']['sessions'].items():
            start_times.setdefault(sid, row['startTime'])
            if row['status'] == 'completed':
                completed.setdefault(sid, row['completedAt'])
        report['checks'].append(result)
        record('checkpoints', result)
        return result

    def send(name: str, event: str, fields: dict[str, Any] | None = None) -> None:
        nonlocal run_receipts
        previous = snapshot()['handledMessageCount']
        require(previous == initial_handled + run_receipts, '发出 hook 前发现额外消息')
        payload = {'session_id': native_ids[name], 'cwd': str(project), 'hook_event_name': event,
                   'timestamp': datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z'),
                   **(fields or {})}
        command = [str(bridge), '--agent', 'codex', '--hook', event]
        child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True, env=env, cwd=project)
        child_record = {'pid': child.pid, 'event': event}
        report['bridgeProcesses'].append(child_record)
        try:
            stdout, stderr = child.communicate(json.dumps(payload), timeout=remaining(8))
        except BaseException:
            child.kill()
            stdout, stderr = child.communicate(timeout=3)
            record('bridge-events', {'payload': payload, 'pid': child.pid, 'returncode': child.returncode,
                                     'stdout': stdout, 'stderr': stderr, 'interrupted': True})
            raise
        finally:
            child_record['returncode'] = child.poll()
            child_record['exited'] = child.poll() is not None
        receipt = {'payload': payload, 'bridgePID': child.pid, 'appPID': process.pid,
                   'returncode': child.returncode, 'stdout': stdout, 'stderr': stderr}
        record('bridge-events', receipt)
        report['messageReceipts'].append(receipt)
        require(child.returncode == 0 and stdout.strip() == '{}' and not stderr,
                f'{event} Bridge 失败或产生非中性输出：{stdout!r} {stderr!r}')
        run_receipts += 1
        state = wait(lambda: snapshot() if snapshot()['handledMessageCount'] > previous else None,
                     event + ' 实际处理完成')
        require(state['handledMessageCount'] == previous + 1, '隔离 App 收到了额外消息')
        receipt['handledMessageCount'] = state['handledMessageCount']
        record('message-receipts', receipt)

    def launch(log) -> None:
        nonlocal process, initial_handled, run_receipts
        process = subprocess.Popen([str(binary), '--ui-test-mode', '--ui-test-socket', '--fixture-path',
            str(repository / 'Tests/Fixtures/app/empty-interaction.json')], env=env, cwd=project,
            stdout=log, stderr=log)
        report['appProcesses'].append({'pid': process.pid})
        wait(lambda: diagnostics.exists() and (runtime / 'di.sock').exists(), '隔离 App 启动')
        state = snapshot()
        require(state['visibleSessions'] == [] and state.get('pendingInteraction') is None, '空 fixture 非空')
        initial_handled, run_receipts = state['handledMessageCount'], 0
        require(initial_handled == 0, '隔离 App 初始消息计数非零')

    def stop_app() -> None:
        if process is None:
            return
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
        report['appProcesses'][-1].update(returncode=process.returncode, exited=process.poll() is not None)

    try:
        with (runtime / 'app.log').open('wb') as log:
            launch(log)
            manual, automatic = session_ids['manual'], session_ids['auto']
            send('manual', 'SessionStart', {'source': 'startup'})
            expected[manual], prompts[manual] = 'active', []
            checkpoint('manual-session-start')
            first_prompt = 'synthetic Codex first user turn'
            send('manual', 'UserPromptSubmit', {'turn_id': 'turn-1', 'prompt': first_prompt})
            prompts[manual].append(first_prompt)
            checkpoint('manual-first-user-prompt')
            answers = ['设置已打开，可以继续', '请先检查任务标题']
            reply = '<send_user_message_question_reply>\n' + json.dumps([
                {'questionItemId': f'synthetic-{index}', 'question': '合成标题检查', 'answer': answer}
                for index, answer in enumerate(answers)
            ], ensure_ascii=False) + '\n</send_user_message_question_reply>'
            send('manual', 'UserPromptSubmit', {'turn_id': 'turn-title-reply', 'prompt': reply})
            prompts[manual].append('\n'.join(answers))
            checkpoint('structured-question-reply-normalized-before-persistence')
            send('manual', 'UserPromptSubmit', {'turn_id': 'turn-title-invalid',
                 'prompt': '<send_user_message_question_reply>broken'})
            checkpoint('malformed-question-reply-preserves-previous-prompt')
            # 合同没有保证压缩前必有同 ID 的用户提示；验证独立 turn_id 的输入边界。
            compact_turn = 'manual-compact-turn'
            send('manual', 'PreCompact', {'turn_id': compact_turn, 'trigger': 'manual'})
            expected[manual] = 'compacting'
            before_hold = checkpoint('manual-pre-compact-new-turn')
            held_at = time.monotonic()
            samples = 0
            while time.monotonic() - held_at < 3.3:
                remaining(0.1)
                require(process.poll() is None, '3.3 秒压缩保持期间 App 退出')
                require(inspect() is not None, 'PreCompact 在没有 PostCompact 时被计时器恢复或历史不同步')
                samples += 1
                time.sleep(0.05)
            after_hold = checkpoint('manual-compacting-after-3.3-seconds')
            require(after_hold['database'] == before_hold['database'], '等待期间压缩历史意外改写')
            report['manualHold'] = {'seconds': time.monotonic() - held_at, 'samples': samples}
            send('manual', 'PostCompact', {'turn_id': compact_turn, 'trigger': 'manual'})
            expected[manual] = 'completionUnconfirmed'
            checkpoint('manual-post-compact-unconfirmed')

            second_prompt = 'synthetic Codex second user turn'
            send('manual', 'UserPromptSubmit', {'turn_id': 'turn-2', 'prompt': second_prompt})
            prompts[manual].append(second_prompt)
            expected[manual] = 'active'
            new_turn = checkpoint('manual-second-user-prompt')
            for old_turn in ('turn-1', compact_turn):
                for event in ('Interrupt', 'PreCompact', 'PostCompact'):
                    fields = {'turn_id': old_turn}
                    if event != 'Interrupt':
                        fields['trigger'] = 'manual'
                    send('manual', event, fields)
                    stale = checkpoint('stale-' + old_turn + '-' + event)
                    require(stale['database'] == new_turn['database'], '旧回合事件改写了新回合历史')
            send('manual', 'Interrupt', {'turn_id': 'turn-2'})
            expected[manual] = 'completionUnconfirmed'
            checkpoint('current-interrupt-is-not-session-end')
            send('manual', 'SessionEnd', {'reason': 'fixture explicitly ended'})
            expected[manual] = 'completed'
            ended = checkpoint('manual-explicit-session-end')
            send('manual', 'PreCompact', {'turn_id': 'unknown-after-close', 'trigger': 'manual'})
            late = checkpoint('closed-session-late-pre-compact')
            require(late['database'] == ended['database'], '关闭后迟到 PreCompact 改写了历史')

            send('auto', 'SessionStart', {'source': 'startup'})
            expected[automatic], prompts[automatic] = 'active', []
            checkpoint('auto-session-start')
            auto_prompt = 'synthetic Codex automatic compaction user turn'
            send('auto', 'UserPromptSubmit', {'turn_id': 'auto-turn', 'prompt': auto_prompt})
            prompts[automatic].append(auto_prompt)
            checkpoint('auto-user-prompt')
            send('auto', 'PreCompact', {'turn_id': 'auto-turn', 'trigger': 'auto'})
            expected[automatic] = 'compacting'
            checkpoint('auto-pre-compact-current-turn')
            send('auto', 'PostCompact', {'turn_id': 'auto-turn', 'trigger': 'auto'})
            expected[automatic] = 'completionUnconfirmed'
            checkpoint('auto-post-compact-unconfirmed')
            send('auto', 'SessionEnd', {'reason': 'fixture explicitly ended'})
            expected[automatic] = 'completed'
            before_restart = checkpoint('both-sessions-explicitly-ended')

            stop_app()
            diagnostics.unlink()
            (runtime / 'di.sock').unlink(missing_ok=True)
            launch(log)
            checkpoint('restart-keeps-closed-history-hidden', {})
            for name in ('manual', 'auto'):
                send(name, 'PreCompact', {'turn_id': 'late-after-restart', 'trigger': name})
                archived = checkpoint('archived-' + name + '-pre-compact-does-not-revive', {})
                require(archived['database'] == before_restart['database'], '迟到事件覆盖了归档历史')

            report['finalDatabase'] = stored()
            require(report['finalDatabase'] == before_restart['database'], '最后一次只读核对失败')
            helper.verify_freshness(repository, binary, 'DynamicIsland')
            helper.verify_freshness(repository, bridge, 'DIBridge')
            require(helper.sha256(binary) == report['appSHA256'] and helper.sha256(bridge) == report['bridgeSHA256'],
                    '验证过程中 App 或 Bridge 被替换')
            report.update(passed=True, hookCount=len(report['messageReceipts']), checkpointCount=len(report['checks']))
    finally:
        # 即使最后读取 SQLite/诊断失败，也必须退出本次自建 App；失败现场始终保留。
        try:
            stop_app()
        finally:
            try:
                cleaned = subprocess.run(['/usr/bin/defaults', 'delete', suite], capture_output=True, timeout=5)
                report['defaultsCleanupExit'] = cleaned.returncode
            except (OSError, subprocess.SubprocessError) as error:
                report['defaultsCleanupError'] = str(error)
                report['passed'] = False
            report['cleanup'] = {'appProcessesExited': all(row.get('exited') for row in report['appProcesses']),
                                 'bridgeProcessesExited': all(row.get('exited') for row in report['bridgeProcesses']),
                                 'runtimeRetainedForAudit': True}
            if not report['passed']:
                report['failureArtifacts'] = str(runtime)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True, help='已构建 App 的绝对路径')
    parser.add_argument('--report', type=Path, required=True, help='JSON 验证报告的绝对路径')
    arguments = parser.parse_args()
    report: dict[str, Any] = {
        'passed': False, 'checkedAt': datetime.now(timezone.utc).isoformat(),
        'scope': 'Synthetic vendor payloads -> bundled di-bridge -> isolated XIsland -> diagnostics and read-only SQLite',
        'realClientVerified': False, 'nativeCodexVerified': False, 'vendorClientLaunched': False,
        'modelOrToolExecuted': False, 'approvalDecisionSent': False, 'userTrustChanged': False,
        'historyOpenMode': 'mode=ro + query_only + read transaction',
        'chatVerification': 'Persisted user-only history plus App diagnostics prompt; no rendered transcript claim',
    }
    try:
        require(arguments.app.is_absolute() and arguments.report.is_absolute(), '--app 与 --report 必须使用绝对路径')
        verify(Path(__file__).resolve().parent.parent, arguments.app.resolve(strict=True), report)
    except (Exception, KeyboardInterrupt) as error:
        report.update(passed=False, error=f'{type(error).__name__}: {error}')
    encoded = json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False)
    # 参数非法时不意外写入相对路径。
    if arguments.report.is_absolute():
        arguments.report.parent.mkdir(parents=True, exist_ok=True)
        arguments.report.write_text(encoded + '\n')
    print(encoded)
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
