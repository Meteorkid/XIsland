#!/usr/bin/env python3
"""Node Kimi 合成 hooks → 包内桥接 → 隔离应用/重启/只读 SQLite；不启动 Kimi。"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def verify(root: Path, app: Path, report: dict) -> None:
    spec = importlib.util.spec_from_file_location('xisland_finality_helpers', root / 'Scripts/test-main-finality-app.py')
    require(spec is not None and spec.loader is not None, '缺少应用验证辅助函数')
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    with (app / 'Contents/Info.plist').open('rb') as stream:
        name = plistlib.load(stream)['CFBundleExecutable']
    binary, bridge = app / 'Contents/MacOS' / name, app / 'Contents/MacOS/di-bridge'
    helper.verify_freshness(root, binary, 'DynamicIsland')
    helper.verify_freshness(root, bridge, 'DIBridge')
    report.update(appSHA256=helper.sha256(binary), bridgeSHA256=helper.sha256(bridge), appPath=str(app))
    fixtures = json.loads((root / 'Tests/Fixtures/companion/kimi-code-hooks.json').read_text())
    inputs = {row['event']: row['input'] for row in fixtures['cases']}
    native = 'node-' + uuid.uuid4().hex
    orphan_native = 'orphan-' + uuid.uuid4().hex
    sid, legacy_sid, orphan_sid = 'kimi_code-' + native, 'kimi-' + native, 'kimi_code-' + orphan_native
    runtime = Path(tempfile.mkdtemp(prefix='xi-kimi-', dir='/tmp'))
    suite = 'dev.xisland.tests.kimi-' + uuid.uuid4().hex
    diagnostics, history = runtime / 'diagnostics.json', runtime / 'history.store'
    env = {key: value for key, value in os.environ.items() if not key.startswith('X_ISLAND_TEST_')}
    for key in ('DI_SESSION_ID', 'DI_BRIDGE_DEBUG_LOG', 'DI_SOCKET_PATH'):
        env.pop(key, None)
    env.update(X_ISLAND_TEST_MODE='1', X_ISLAND_TEST_RUNTIME_DIR=str(runtime),
               X_ISLAND_TEST_DEFAULTS_SUITE=suite, X_ISLAND_TEST_DIAGNOSTICS_PATH=str(diagnostics),
               X_ISLAND_DISABLE_ANIMATIONS='1', DI_SOCKET_PATH=str(runtime / 'di.sock'))
    report.update(runtimeDirectory=str(runtime), sessionIds={'node': sid, 'legacy': legacy_sid, 'orphan': orphan_sid})
    report['checks'] = []
    report['messageReceipts'] = []
    process = None
    succeeded = False

    def wait(check, description, timeout=12):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            require(process is not None and process.poll() is None, '隔离应用已退出：' + description)
            result = check()
            if result:
                return result
            time.sleep(0.05)
        state = diagnostics.read_text() if diagnostics.exists() else 'no diagnostics'
        raise AssertionError(description + '\n' + state)

    def states(expected):
        value = json.loads(diagnostics.read_text())
        rows = value['visibleSessions']
        if {row['id']: row['status'] for row in rows} != expected:
            return None
        require(len(rows) == len(expected), '重复会话 ID')
        require(value.get('pendingInteraction') is None, '诊断把观察事件误报为可操作交互')
        for row in rows:
            require(row['agentType'] == 'kimi' and row.get('pendingInteraction') is None, '来源或交互不符')
            require((row.get('completedAt') is not None) == (row['status'] == 'completed'), '伪造或遗漏完成时间')
        return value

    def stored():
        if not history.exists():
            return None
        with sqlite3.connect(history.as_uri() + '?mode=ro', uri=True, timeout=1) as database:
            columns = {row[1] for row in database.execute('PRAGMA table_info(ZSTOREDSESSION)')}
            require({'ZSESSIONID', 'ZSTATUSRAW', 'ZCOMPLETEDAT', 'ZKIMICODEAPPROVALOBSERVATIONDATA'} <= columns,
                    '历史 schema 已改变，需核对独立读取器')
            rows = database.execute('SELECT ZSESSIONID,ZSTATUSRAW,ZCOMPLETEDAT,ZSTARTTIME,'
                                    'ZKIMICODEAPPROVALOBSERVATIONDATA FROM ZSTOREDSESSION').fetchall()
            orphan_rows = database.execute('SELECT ZSESSIONID,ZOBSERVATIONDATA FROM ZSTOREDKIMICODEAPPROVALORPHAN').fetchall()
            user_messages = database.execute('SELECT c.ZCONTENT FROM ZSTOREDCHATMESSAGE c '
                'JOIN ZSTOREDSESSION s ON c.ZSESSION=s.Z_PK WHERE s.ZSESSIONID=? AND c.ZROLE=?', (sid, 'user')).fetchall()
        return {'sessions': {row[0]: {'status': row[1], 'completedAt': row[2], 'startTime': row[3],
                    'approval': json.loads(row[4]) if row[4] is not None else None} for row in rows},
                'orphans': {row[0]: json.loads(row[1]) for row in orphan_rows},
                'nodeUserMessages': [row[0] for row in user_messages]}

    def check(stage, expected, pending=None, orphan_count=None):
        snapshot = wait(lambda: states(expected), stage)
        database = stored()
        require(database is not None, '历史库缺失')
        if pending is not None:
            require(set(database['sessions'][sid]['approval']['pending']) == set(pending), stage + '：审批集合不符')
            require(database['sessions'][sid]['status'] == expected.get(sid, database['sessions'][sid]['status']), stage + '：界面与数据库不同步')
        if orphan_count is not None:
            require(len(database['orphans']) == orphan_count, stage + '：独立结果集合不符')
        report['checks'].append({'stage': stage, 'visible': expected.copy(), 'diagnostics': snapshot, 'database': database})
        return database

    def send(event, fields=None, native_id=native, legacy=False):
        payload = dict(inputs[event])
        payload.update(session_id=native_id, cwd=str(runtime))
        payload.update(fields or {})
        if legacy:
            payload = {'session_id': native_id, 'hook_event_name': event, 'cwd': str(runtime), **(fields or {})}
        command = [str(bridge), '--agent', 'kimi', '--hook', event]
        if not legacy:
            command += ['--adapter', 'kimi_code']
        previous_count = json.loads(diagnostics.read_text()).get('handledMessageCount')
        require(isinstance(previous_count, int), '应用缺少消息处理完成计数')
        result = subprocess.run(command, input=json.dumps(payload), text=True, capture_output=True, env=env, timeout=8)
        require(result.returncode == 0, f'{event} bridge失败：{result.stderr}')
        require(result.stdout.strip() == ('{}' if legacy else ''), f'{event} 出现非中性stdout')
        wait(lambda: json.loads(diagnostics.read_text()).get('handledMessageCount', -1) > previous_count,
             event + '已被实际应用处理')
        handled = json.loads(diagnostics.read_text())['handledMessageCount']
        require(handled == previous_count + 1, '隔离服务收到本次调用以外的消息')
        report['messageReceipts'].append({'event': event, 'nativeSessionId': native_id, 'legacy': legacy,
                                         'processId': process.pid, 'handledMessageCount': handled})

    def approval(event, request, agent='main', turn=0, native_id=native):
        send(event, {'id': request, 'agent_id': agent, 'turn_id': turn, 'tool_call_id': 'call-' + request}, native_id)

    def start(log):
        nonlocal process
        process = subprocess.Popen([str(binary), '--ui-test-mode', '--ui-test-socket', '--fixture-path',
            str(root / 'Tests/Fixtures/app/empty-interaction.json')], env=env, stdout=log, stderr=log)
        wait(lambda: diagnostics.exists() and (runtime / 'di.sock').exists(), '隔离应用启动')
        wait(lambda: states({}), '空界面启动')

    def restart(log):
        process.terminate()
        process.wait(timeout=5)
        diagnostics.unlink()
        (runtime / 'di.sock').unlink(missing_ok=True)
        start(log)

    try:
        with (runtime / 'app.log').open('wb') as log:
            start(log)
            send('SessionStart', {'source': 'startup'}, legacy=True)
            send('Stop', legacy=True)
            send('SessionStart')
            expected = {legacy_sid: 'completionUnconfirmed', sid: 'idle'}
            check('separate-runtime-identities', expected)
            send('UserPromptSubmit')
            check('submitted-prompt-is-not-execution', expected)
            send('TurnStarted')
            expected[sid] = 'active'
            initial = check('turn-start-does-not-duplicate-user-chat', expected)
            require(initial['nodeUserMessages'] == ['Inspect fixture'], '重复或丢失用户文本')
            approval('PermissionRequest', 'a')
            approval('PermissionRequest', 'b', agent='other-agent')
            expected[sid] = 'waitingPermission'
            check('parallel-native-approvals', expected, pending=['a', 'b'])
            send('PreToolUse', {'tool_call_id': 'concurrent-tool'})
            send('SessionHeartbeat')
            check('other-work-and-heartbeat-do-not-clear-approvals', expected, pending=['a', 'b'])
            approval('PermissionResult', 'a')
            approval('PermissionRequest', 'a')
            check('result-and-late-duplicate-preserve-other-agent', expected, pending=['b'])
            restart(log)
            approval('PermissionResult', 'b', agent='other-agent')
            after_result = check('result-after-restart-updates-history-without-ui', {}, pending=[])
            require(after_result['sessions'][sid]['status'] == 'active', '最后一项审批未恢复基础状态')
            approval('PermissionRequest', 'a')
            check('resolved-request-after-restart-does-not-create-wait', {}, pending=[])
            send('TurnStarted', {'turn_id': 1, 'origin_kind': 'task'})
            expected = {sid: 'active'}
            check('fresh-work-restores-session', expected, pending=[])
            approval('PermissionRequest', 'c', turn=1)
            send('Interrupt', {'turn_id': 1})
            expected[sid] = 'completionUnconfirmed'
            check('interrupt-retains-unconfirmed-approval', expected, pending=['c'])
            send('PermissionResult', {'id': 'c', 'agent_id': 'main', 'turn_id': 1, 'tool_call_id': 'call-c', 'decision': 'cancelled'})
            check('cancel-result-does-not-claim-session-complete', expected, pending=[])

            approval('PermissionResult', 'first-result', native_id=orphan_native)
            before_restart = check('result-before-session-is-durable-without-history-shell', expected, orphan_count=1)
            require(orphan_sid not in before_restart['sessions'], '独立结果制造了历史空壳')
            restart(log)
            approval('PermissionRequest', 'first-result', native_id=orphan_native)
            check('orphan-result-survives-restart-before-request', {}, orphan_count=1)
            send('SessionEnd', native_id=orphan_native)
            approval('PermissionRequest', 'late-after-close', native_id=orphan_native)
            check('close-before-session-rejects-late-request', {}, orphan_count=1)
            send('TurnStarted', {'turn_id': 2, 'origin_kind': 'task'}, native_id=orphan_native)
            expected = {orphan_sid: 'active'}
            transferred = check('fresh-turn-transfers-orphan-facts', expected, orphan_count=0)
            require('first-result' in transferred['sessions'][orphan_sid]['approval']['resolved'], '转移丢失已结束请求')
            send('SessionEnd')
            closed = check('archived-session-end-remains-hidden', expected)
            require(closed['sessions'][sid]['status'] == 'completed' and closed['sessions'][sid]['completedAt'] is not None,
                    '明确结束未保存')
            approval('PermissionRequest', 'after-end')
            check('late-request-does-not-reopen-closed-history', expected)
            require(stored()['sessions'][sid] == closed['sessions'][sid], '迟到请求覆盖关闭历史')
            report['passed'] = True
            report['nodeUserChatNotDuplicated'] = True
            report['isolatedAppRestarts'] = 2
            helper.verify_freshness(root, binary, 'DynamicIsland')
            helper.verify_freshness(root, bridge, 'DIBridge')
            require(helper.sha256(binary) == report['appSHA256'] and helper.sha256(bridge) == report['bridgeSHA256'], '测试中产物被替换')
        succeeded = True
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
        subprocess.run(['/usr/bin/defaults', 'delete', suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        if succeeded:
            shutil.rmtree(runtime)
        else:
            report['failureArtifacts'] = str(runtime)


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app-path', type=Path, default=root / '.build/X Island.app')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    report = {'passed': False, 'checkedAt': datetime.now(timezone.utc).isoformat(), 'realClientVerified': False,
              'vendorClientLaunched': False, 'modelOrToolExecuted': False,
              'scope': 'Synthetic Kimi Node 2.1.1 events through bundled bridge and isolated app; read-only SQLite and restarts'}
    try:
        verify(root, args.app_path.resolve(strict=True), report)
    except (AssertionError, OSError, ValueError, KeyError, sqlite3.Error, subprocess.SubprocessError) as error:
        report.update(passed=False, error=f'{type(error).__name__}: {error}')
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'passed': report['passed'], 'checks': len(report.get('checks', [])),
                      'error': report.get('error'), 'failureArtifacts': report.get('failureArtifacts')}, ensure_ascii=False))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
