#!/usr/bin/env python3
"""包内 di-bridge 合成载荷 → 隔离 XIsland → diagnostics 与只读历史库；不启动厂商客户端。"""
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
import sqlite3
import subprocess
import sys
import tempfile
import time
from typing import Any, Callable
import uuid


# 每个来源独立核对；同名事件不代表不同厂商具有相同的原生协议。
SOURCES = (
    ('claude_code', None, 'Stop'),
    ('codex', None, 'Stop'),
    ('qwen', None, 'Stop'),
    ('qoder', None, 'Stop'),
    ('droid', None, 'Stop'),
    ('gemini_cli', None, 'AfterAgent'),
    ('tabnine', None, 'AfterAgent'),
    ('kimi', None, 'Stop'),
    ('code_buddy', None, 'Stop'),
    ('trae', 'trae_cn', 'Stop'),
    ('copilot', 'vscode_local', 'Stop'),
    ('copilot_cli', None, 'agentStop'),
    ('workbuddy', 'workbuddy_5_7_6', 'Stop'),
)


def require(condition: bool, message: str) -> None:
    # 即使调用者使用 python -O，验收断言也不能被关闭。
    if not condition:
        raise AssertionError(message)


def sha256(path: Path) -> str:
    with path.open('rb') as source:
        digest = hashlib.sha256()
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def verify_freshness(repository: Path, binary: Path, target: str) -> dict[str, Any]:
    require(binary.is_file() and os.access(binary, os.X_OK), f'缺少可执行文件：{binary}')
    sources = [repository / 'Package.swift']
    for folder in (target, 'DIShared'):
        files = list((repository / 'Sources' / folder).rglob('*.swift'))
        require(bool(files), f'找不到源码目录：Sources/{folder}')
        sources.extend(files)
    newest = max(sources, key=lambda path: path.stat().st_mtime_ns)
    require(binary.stat().st_mtime_ns >= newest.stat().st_mtime_ns,
            f'拒绝过期二进制 {binary}；请先构建，较新源码为 {newest}')
    return {'newestSource': str(newest.relative_to(repository)),
            'newestSourceMtimeNs': newest.stat().st_mtime_ns,
            'binaryMtimeNs': binary.stat().st_mtime_ns}


def verify(repository: Path, app: Path, report: dict[str, Any]) -> None:
    with (app / 'Contents/Info.plist').open('rb') as source:
        name = plistlib.load(source).get('CFBundleExecutable')
    require(isinstance(name, str) and bool(name) and Path(name).name == name,
            '应用包缺少合法的 CFBundleExecutable')
    binary = app / 'Contents/MacOS' / name
    bridge = app / 'Contents/MacOS/di-bridge'
    report.update(appPath=str(app), bridgePath=str(bridge))
    require(binary.is_file() and bridge.is_file(), '应用包缺少主程序或 di-bridge')
    report.update(appSHA256=sha256(binary), bridgeSHA256=sha256(bridge))
    report['freshness'] = {
        'app': verify_freshness(repository, binary, 'DynamicIsland'),
        'bridge': verify_freshness(repository, bridge, 'DIBridge'),
    }

    root = Path(tempfile.mkdtemp(prefix='xi-finality-', dir='/tmp'))
    suite = 'dev.xisland.tests.finality-' + uuid.uuid4().hex
    diagnostics = root / 'diagnostics.json'
    history = root / 'history.store'
    project = root / 'project'
    project.mkdir()
    app_process: subprocess.Popen | None = None
    succeeded = False
    native_ids = {agent: f'fixture-{agent}-{uuid.uuid4().hex}' for agent, _, _ in SOURCES}
    session_ids = {
        agent: ('workbuddy-' + base64.b64encode(native_ids[agent].encode()).decode()
                if agent == 'workbuddy' else
                ('copilot-local-' if agent == 'copilot' else agent + '-') + native_ids[agent])
        for agent, _, _ in SOURCES
    }
    agents_by_session = {session_ids[agent]: agent for agent, _, _ in SOURCES}
    adapters = {agent: adapter for agent, adapter, _ in SOURCES}
    report.update(runtimeDirectory=str(root), defaultsSuite=suite, sourceCount=len(SOURCES),
                  nativeSessionIds=native_ids, sessionIds=session_ids)
    report['messageReceipts'] = []

    env = {key: value for key, value in os.environ.items() if not key.startswith('X_ISLAND_TEST_')}
    for key in ('DI_SESSION_ID', 'DI_BRIDGE_DEBUG_LOG', 'DI_SOCKET_PATH'):
        env.pop(key, None)
    env.update({'X_ISLAND_TEST_MODE': '1', 'X_ISLAND_TEST_RUNTIME_DIR': str(root),
                'X_ISLAND_TEST_DEFAULTS_SUITE': suite,
                'X_ISLAND_TEST_DIAGNOSTICS_PATH': str(diagnostics),
                'X_ISLAND_DISABLE_ANIMATIONS': '1', 'DI_SOCKET_PATH': str(root / 'di.sock')})

    def wait_for(check: Callable[[], Any], description: str, timeout: float = 15) -> Any:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            require(app_process is not None and app_process.poll() is None,
                    f'隔离应用已退出：{description}')
            value = check()
            if value:
                return value
            time.sleep(0.05)
        state = diagnostics.read_text() if diagnostics.exists() else 'no diagnostics'
        raise AssertionError(f'等待超时：{description}；{root}\n{state}')

    def snapshot() -> dict[str, Any]:
        state = json.loads(diagnostics.read_text())
        require(isinstance(state.get('visibleSessions'), list), 'diagnostics 缺少 visibleSessions')
        require(all(isinstance(row, dict) and all(isinstance(row.get(key), str)
                    for key in ('id', 'status', 'agentType')) for row in state['visibleSessions']),
                'diagnostics 会话字段格式已改变')
        return state

    def wait_states(expected: dict[str, str], description: str) -> dict[str, Any]:
        def matches() -> dict[str, Any] | None:
            state = snapshot()
            rows = {row['id']: row for row in state['visibleSessions']}
            if set(rows) != set(expected) or any(rows[key]['status'] != value for key, value in expected.items()):
                return None
            require(len(state['visibleSessions']) == len(expected), 'diagnostics 出现重复会话 ID')
            require(state.get('pendingInteraction') is None, '出现了不应存在的全局交互')
            for key, row in rows.items():
                require(row['agentType'] == agents_by_session[key], f'来源身份不符：{key}')
                require((row.get('completedAt') is not None) == (expected[key] == 'completed'),
                        f'会话完成时间与状态不符：{key}')
                require(row.get('observationEndedAt') is None, f'出现了旧的观察终止时间：{key}')
                require(row.get('pendingInteraction') is None, f'出现了不应存在的会话交互：{key}')
            return state
        return wait_for(matches, description)

    def send(agent: str, event: str, fields: dict[str, Any] | None = None) -> None:
        previous_count = snapshot().get('handledMessageCount')
        require(isinstance(previous_count, int), '应用缺少消息处理完成计数')
        if agent == 'copilot_cli':
            payload: dict[str, Any] = {'sessionId': native_ids[agent], 'cwd': str(project),
                                       'timestamp': int(time.time() * 1000)}
        else:
            payload = {'session_id': native_ids[agent], 'cwd': str(project), 'hook_event_name': event,
                       'timestamp': datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')}
        payload.update(fields or {})
        command = [str(bridge), '--agent', agent, '--hook', event]
        if adapters[agent]:
            command += ['--adapter', adapters[agent]]
        # 这里只把载荷交给 Bridge；tool_input 也是数据，不执行其中描述的工具。
        result = subprocess.run(command, input=json.dumps(payload), text=True, capture_output=True,
                                env=env, cwd=project, timeout=8)
        with (root / 'bridge-events.jsonl').open('a') as log:
            log.write(json.dumps({'agent': agent, 'event': event, 'payload': payload,
                                  'returncode': result.returncode, 'stdout': result.stdout,
                                  'stderr': result.stderr}, ensure_ascii=False) + '\n')
        require(result.returncode == 0, f'Bridge 失败：{agent}/{event}: {result.stderr.strip()}')
        wait_for(lambda: snapshot().get('handledMessageCount', -1) > previous_count, f'{agent}/{event} 处理完成')
        handled = snapshot()['handledMessageCount']
        require(handled == previous_count + 1, '隔离服务收到本次调用以外的消息')
        report['messageReceipts'].append({'agent': agent, 'event': event, 'processId': app_process.pid,
                                         'handledMessageCount': handled})

    def stop(agent: str, event: str) -> None:
        fields: dict[str, Any] = {}
        if event == 'AfterAgent':
            fields = {'prompt': 'fixture only', 'prompt_response': 'Fixture response', 'stop_hook_active': False}
        elif event == 'agentStop':
            fields = {'stopReason': 'end_turn'}
        else:
            fields = {'stop_hook_active': False}
            if agent in ('claude_code', 'codex', 'qwen', 'qoder', 'trae', 'workbuddy'):
                fields['last_assistant_message'] = 'Fixture response'
        send(agent, event, fields)

    def stored_states(expected: dict[str, str]) -> list[dict[str, Any]] | None:
        if not history.exists():
            return None
        # 不调用应用保存接口，直接独立读取正在使用的 SQLite/WAL。
        with sqlite3.connect(history.as_uri() + '?mode=ro', uri=True, timeout=1) as database:
            columns = {row[1] for row in database.execute('PRAGMA table_info(ZSTOREDSESSION)')}
            required = {'ZSESSIONID', 'ZAGENTTYPERAW', 'ZSTATUSRAW', 'ZCOMPLETEDAT',
                        'ZOBSERVATIONENDEDAT', 'ZHISTORYDATE', 'ZSTARTTIME'}
            require(required <= columns, '实际历史 schema 已改变，需更新独立核对器')
            rows = database.execute('SELECT ZSESSIONID, ZAGENTTYPERAW, ZSTATUSRAW, ZCOMPLETEDAT, '
                                    'ZOBSERVATIONENDEDAT, ZHISTORYDATE, ZSTARTTIME '
                                    'FROM ZSTOREDSESSION').fetchall()
        if len(rows) != len(SOURCES) or {row[0] for row in rows} != set(session_ids.values()):
            return None
        require(all(row[1] == agents_by_session[row[0]] for row in rows), '历史库来源身份不符')
        if any(row[2] != expected[row[0]] for row in rows):
            return None
        require(all((row[3] is not None) == (row[2] == 'completed') for row in rows),
                f'历史库完成时间与状态不符：{rows}')
        require(all(row[4] is None for row in rows), f'历史库出现旧的观察终止时间：{rows}')
        require(all(row[5] == (row[3] if row[3] is not None else row[6]) for row in rows),
                f'历史日期与实际生命周期不符：{rows}')
        return [{'sessionId': row[0], 'agent': row[1], 'status': row[2], 'completedAt': row[3],
                 'observationEndedAt': row[4], 'historyDate': row[5], 'startTime': row[6]}
                for row in sorted(rows)]

    try:
        with (root / 'app.log').open('wb') as log:
            app_process = subprocess.Popen([str(binary), '--ui-test-mode', '--ui-test-socket', '--fixture-path',
                str(repository / 'Tests/Fixtures/app/empty-interaction.json')], env=env, stdout=log, stderr=log)
            wait_for(lambda: (root / 'di.sock').exists() and diagnostics.exists(), '隔离 socket 与 diagnostics 就绪')
            require(snapshot()['visibleSessions'] == [], '隔离应用未从空 fixture 启动')
            for agent, _, _ in SOURCES:
                event = 'sessionStart' if agent == 'copilot_cli' else 'SessionStart'
                fields = {'initialPrompt': 'fixture only'} if agent == 'copilot_cli' else {'source': 'startup'}
                send(agent, event, fields)
            expected = {session_id: 'active' for session_id in session_ids.values()}
            expected[session_ids['workbuddy']] = 'idle'
            wait_states(expected, '13 个独立来源的开始事件')
            # WorkBuddy SessionStart 仅连接；提交合成提示才是其运行开始事件。
            send('workbuddy', 'UserPromptSubmit', {'prompt': 'fixture only'})
            expected[session_ids['workbuddy']] = 'active'
            wait_states(expected, '13 个来源均已进入活动状态')
            for agent, _, event in SOURCES:
                stop(agent, event)
            expected = {session_id: 'completionUnconfirmed' for session_id in session_ids.values()}
            pending = wait_states(expected, '13 个来源均完成未确认，且无完成时间或交互')
            report['pendingDiagnostics'] = pending['visibleSessions']
            report['persistedPendingRows'] = wait_for(lambda: stored_states(expected), '13 行未确认历史记录自动保存')

            fresh_tool_id = 'fixture-resume-' + uuid.uuid4().hex
            send('codex', 'PreToolUse', {'tool_name': 'Read', 'tool_use_id': fresh_tool_id,
                'tool_input': {'file_path': str(project / 'not-executed.txt')}})
            expected[session_ids['codex']] = 'active'
            wait_states(expected, 'Codex 新工具观察恢复 active')
            report['persistedToolResumeRows'] = wait_for(lambda: stored_states(expected),
                'Codex 新工具恢复立即更新历史检查点')
            stop('codex', 'Stop')
            expected[session_ids['codex']] = 'completionUnconfirmed'
            wait_states(expected, 'Codex 再次 Stop 回到完成未确认')
            send('workbuddy', 'FinalStop', {'final_stop_reason': 'completed'})
            expected[session_ids['workbuddy']] = 'idle'
            final_idle = wait_states(expected, 'WorkBuddy FinalStop 仅进入 idle')
            report['finalIdleDiagnostics'] = final_idle['visibleSessions']
            report['persistedFinalIdleRows'] = wait_for(lambda: stored_states(expected), '最终空闲回执同步到历史库')
            report['codexFreshToolRestoredActive'] = True
            report['codexStopReturnedToUnconfirmed'] = True
            report['workbuddyFinalStopReachedIdleWithoutCompletion'] = True

            send('codex', 'SessionEnd', {'reason': 'fixture end'})
            expected[session_ids['codex']] = 'completed'
            ended = wait_states(expected, 'Codex 显式 SessionEnd 写入完成时间')
            ended_row = next(row for row in ended['visibleSessions'] if row['id'] == session_ids['codex'])
            report['completedDiagnostics'] = ended['visibleSessions']
            report['persistedCompletedRows'] = wait_for(lambda: stored_states(expected), '显式结束自动保存')
            stop('codex', 'Stop')
            # send 已等待本条消息处理完成，不能用旧快照的同一状态代替回执。
            late_stop = wait_states(expected, '迟到 Stop 不恢复已结束会话')
            late_row = next(row for row in late_stop['visibleSessions'] if row['id'] == session_ids['codex'])
            require(late_row['completedAt'] == ended_row['completedAt'], '迟到 Stop 改写了结束时间')
            report['lateStopDiagnostics'] = late_stop['visibleSessions']
            report['persistedLateStopRows'] = wait_for(lambda: stored_states(expected), '迟到 Stop 保留结束历史')

            resumed_prompt = 'new fixture turn after explicit end'
            send('codex', 'UserPromptSubmit', {'prompt': resumed_prompt})
            expected[session_ids['codex']] = 'active'
            resumed = wait_states(expected, '同 ID 新提示恢复 active 且清除旧结束时间')
            resumed_row = next(row for row in resumed['visibleSessions'] if row['id'] == session_ids['codex'])
            require(resumed_row['prompt'] == resumed_prompt, '新轮次提示未进入实际应用')
            report['resumedDiagnostics'] = resumed['visibleSessions']
            report['persistedResumeRows'] = wait_for(lambda: stored_states(expected), '恢复时即刷新历史日期与结束时间')
            stop('codex', 'Stop')
            expected[session_ids['codex']] = 'completionUnconfirmed'
            final = wait_states(expected, '恢复后的 Stop 保持完成未确认且无旧结束时间')
            report['finalDiagnostics'] = final['visibleSessions']
            report['persistedFinalRows'] = wait_for(lambda: stored_states(expected), '恢复后的未确认历史自动保存')
            report['codexExplicitEndLateStopAndPromptResumePassed'] = True
            report['observationEndResetScope'] = 'This app scenario asserts nil only; nonnil observationEndedAt reset is covered by unit tests'

            send('codex', 'SessionEnd', {'reason': 'fixture end before app restart'})
            expected[session_ids['codex']] = 'completed'
            wait_states(expected, '重启前 Codex 明确结束')
            closed_rows = wait_for(lambda: stored_states(expected), '重启前保存结束历史')
            report['persistedBeforeRestartRows'] = closed_rows
            app_process.terminate()
            app_process.wait(timeout=5)
            diagnostics.unlink()
            (root / 'di.sock').unlink(missing_ok=True)
            app_process = subprocess.Popen([str(binary), '--ui-test-mode', '--ui-test-socket', '--fixture-path',
                str(repository / 'Tests/Fixtures/app/empty-interaction.json')], env=env, stdout=log, stderr=log)
            wait_for(lambda: (root / 'di.sock').exists() and diagnostics.exists(), '原临时历史库上的隔离应用重启')
            wait_states({}, '重启不自动加载历史到界面')
            for event, fields in [
                ('Stop', {'stop_hook_active': False, 'last_assistant_message': 'Late archived reply'}),
                ('PreToolUse', {'tool_name': 'Read', 'tool_use_id': fresh_tool_id, 'tool_input': {}}),
                ('PostToolUse', {'tool_name': 'Read', 'tool_use_id': fresh_tool_id, 'tool_response': 'Late result'}),
            ]:
                send('codex', event, fields)
                wait_states({}, f'迟到 {event} 不重建已归档会话')
                require(stored_states(expected) == closed_rows, f'迟到 {event} 覆盖了关闭历史')
            report['restartLateEventsKeptHistoryAndUIClosed'] = True
            send('codex', 'UserPromptSubmit', {'prompt': 'fresh work after app restart'})
            restarted = wait_states({session_ids['codex']: 'active'}, '重启后同 ID 新提示合法恢复')
            report['restartResumedDiagnostics'] = restarted['visibleSessions']
            expected[session_ids['codex']] = 'active'
            resumed_rows = wait_for(lambda: stored_states(expected), '重启恢复自动更新原历史记录')
            report['persistedRestartResumeRows'] = resumed_rows
            require([row['startTime'] for row in resumed_rows] == [row['startTime'] for row in closed_rows],
                    '重启恢复改写了原始开始时间')
            stop('codex', 'Stop')
            expected[session_ids['codex']] = 'completionUnconfirmed'
            wait_states({session_ids['codex']: 'completionUnconfirmed'}, '重启恢复后的停止状态正确')
            report['persistedRestartFinalRows'] = wait_for(lambda: stored_states(expected), '重启后的未确认历史保存')
            report['restartFreshPromptPreservedStartAndClearedEnd'] = True

            verify_freshness(repository, binary, 'DynamicIsland')
            verify_freshness(repository, bridge, 'DIBridge')
            require(sha256(binary) == report['appSHA256'] and sha256(bridge) == report['bridgeSHA256'],
                    '测试过程中 App 或 Bridge 被替换')
        succeeded = True
        report['passed'] = True
    finally:
        if app_process is not None and app_process.poll() is None:
            app_process.terminate()
            try:
                app_process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                app_process.kill()
                app_process.wait(timeout=3)
        # 只删除本次新建的 UUID 偏好域，不触碰常驻 App 或真实用户偏好。
        subprocess.run(['/usr/bin/defaults', 'delete', suite], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=5)
        if succeeded:
            shutil.rmtree(root)
        else:
            report['failureArtifacts'] = str(root)
            print(f'失败现场保留：{root}', file=sys.stderr)


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app-path', type=Path, default=repository / '.build/X Island.app')
    parser.add_argument('--report', type=Path)
    arguments = parser.parse_args()
    report: dict[str, Any] = {
        'passed': False, 'checkedAt': datetime.now(timezone.utc).isoformat(),
        'scope': 'Bundled di-bridge processes -> isolated XIsland app -> diagnostics and read-only SQLite; synthetic vendor payloads',
        'realClientVerified': False, 'vendorClientLaunched': False, 'modelOrToolExecuted': False,
        'runningCountVerification': 'Not measured: diagnostics has no activeCount; unit/render evidence is separate',
    }
    try:
        verify(repository, arguments.app_path.resolve(strict=True), report)
    except (AssertionError, OSError, ValueError, sqlite3.Error, subprocess.SubprocessError) as error:
        report.update(passed=False, error=f'{type(error).__name__}: {error}')
    encoded = json.dumps(report, ensure_ascii=False, indent=2)
    if arguments.report:
        arguments.report.parent.mkdir(parents=True, exist_ok=True)
        arguments.report.write_text(encoded + '\n')
    print(encoded)
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
