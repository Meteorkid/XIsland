#!/usr/bin/env python3
"""实际TS观察器/传输 → 隔离XIsland：双窗口、重载、正常退出与崩溃租约。"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import subprocess
import tempfile
import time
import uuid


def verify(repository: Path, app: Path) -> dict:
    with (app / 'Contents/Info.plist').open('rb') as file:
        binary = app / 'Contents/MacOS' / plistlib.load(file)['CFBundleExecutable']
    assert binary.stat().st_mtime >= max(p.stat().st_mtime for p in (repository / 'Sources/DynamicIsland').rglob('*.swift')), '请先构建最新隔离应用'
    root = Path(tempfile.mkdtemp(prefix='xi-observe-', dir='/tmp'))
    suite = 'dev.xisland.tests.observe-' + uuid.uuid4().hex
    processes: list[subprocess.Popen] = []
    succeeded = False
    try:
        extension = repository / 'Sources/XIslandVSCode'
        subprocess.run(['node', str(extension / 'node_modules/typescript/bin/tsc'), '-p', str(extension),
                        '--outDir', str(root / 'js')], check=True, timeout=30)
        sender = root / 'sender.cjs'
        sender.write_text(r'''
const fs = require('node:fs');
const { EventEmitter } = require('node:events');
const { observeTasks } = require('./js/task-observer');
const { ObservationTransport } = require('./js/transport');
const root = process.argv[2], mode = process.argv[3], sources = [], manifest = {};
for (const [label, agent] of mode === 'first' ? [['a', 'roo_code'], ['b', 'roo_code'], ['pear', 'pearai']] : [['reload', 'roo_code']]) {
    const api = new EventEmitter();
    const transport = new ObservationTransport(root + '/di.sock', () => {}, 20);
    const observer = observeTasks(api, agent, 'a'.repeat(24), message => {
        fs.appendFileSync(root + '/events-' + mode + '.jsonl', JSON.stringify(message) + '\n');
        if (message.type === 'session_start') manifest[label] = message.sessionId;
        transport.send({ ...message, terminal: 'Visual Studio Code' });
    });
    sources.push({ label, agent, transport, observer, closed: false });
    api.emit('taskStarted', '共享任务🙂');
}
fs.writeFileSync(root + '/manifest-' + mode + '.json', JSON.stringify(manifest));
const timer = setInterval(() => {
    for (const source of sources) {
        if (source.closed || !fs.existsSync(root + '/close-' + source.label)) continue;
        source.closed = true;
        source.transport.discard(source.agent);
        source.observer.dispose();
        source.transport.drain(500).then(() => fs.writeFileSync(root + '/closed-' + source.label, 'done'));
    }
}, 20);
setTimeout(() => { clearInterval(timer); for (const source of sources) { source.observer.dispose(); source.transport.dispose(); } }, 90000);
''')
        env = {key: value for key, value in os.environ.items() if not key.startswith('X_ISLAND_TEST_')}
        env.update({'X_ISLAND_TEST_MODE': '1', 'X_ISLAND_TEST_RUNTIME_DIR': str(root),
                    'X_ISLAND_TEST_DEFAULTS_SUITE': suite,
                    'X_ISLAND_TEST_DIAGNOSTICS_PATH': str(root / 'diagnostics.json'), 'X_ISLAND_DISABLE_ANIMATIONS': '1'})
        with (root / 'app.log').open('wb') as log:
            app_process = subprocess.Popen([str(binary), '--ui-test-mode', '--ui-test-socket', '--fixture-path',
                                            str(repository / 'Tests/Fixtures/app/empty-interaction.json')],
                                           env=env, stdout=log, stderr=log)
            processes.append(app_process)

            def wait_for(check, timeout=15):
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    assert app_process.poll() is None, f'应用退出；诊断保留于 {root}'
                    value = check()
                    if value:
                        return value
                    time.sleep(.05)
                state = (root / 'diagnostics.json').read_text() if (root / 'diagnostics.json').exists() else 'no diagnostics'
                raise AssertionError(f'等待条件超时；{root}: {state}')

            def rows():
                return {row['id']: row for row in json.loads((root / 'diagnostics.json').read_text())['visibleSessions']}

            def wait_states(expected, timeout=15):
                def matches():
                    current = rows()
                    return current if all(current.get(key, {}).get('status') == state
                        for key, state in expected.items()) else None
                return wait_for(matches, timeout)

            wait_for(lambda: (root / 'di.sock').exists() and (root / 'diagnostics.json').exists())
            assert rows() == {}
            first = subprocess.Popen(['node', str(sender), str(root), 'first'])
            processes.append(first)
            wait_for(lambda: (root / 'manifest-first.json').exists())
            identities = json.loads((root / 'manifest-first.json').read_text())
            initial = wait_states({key: 'active' for key in identities.values()})
            assert len(initial) == 3 and len({row['sourceInstanceId'] for row in initial.values()}) == 3
            assert all(row['nativeTaskId'] == '共享任务🙂' for row in initial.values())
            (root / 'close-a').touch()
            after_close = wait_states({identities['a']: 'observationUnavailable', identities['b']: 'active', identities['pear']: 'active'})
            assert after_close[identities['a']].get('completedAt') is None
            assert after_close[identities['a']]['observationEndedAt'] is not None
            # 不运行dispose，模拟扩展宿主崩溃；仅终止本脚本创建的进程。
            first.kill(); first.wait(timeout=3)
            crashed_at = time.monotonic()
            reloaded = subprocess.Popen(['node', str(sender), str(root), 'reload'])
            processes.append(reloaded)
            wait_for(lambda: (root / 'manifest-reload.json').exists())
            reload_id = json.loads((root / 'manifest-reload.json').read_text())['reload']
            assert reload_id not in identities.values()
            after_reload = wait_states({reload_id: 'active'})
            assert after_reload[reload_id]['nativeTaskId'] == initial[identities['a']]['nativeTaskId']
            assert after_reload[reload_id]['sourceNamespace'] == initial[identities['a']]['sourceNamespace']
            interrupted = wait_states({identities['b']: 'observationUnavailable', identities['pear']: 'observationUnavailable',
                                       reload_id: 'active'}, timeout=45)
            expiry_seconds = time.monotonic() - crashed_at
            assert all(interrupted[key].get('completedAt') is None for key in identities.values())
            (root / 'close-reload').touch()
            final = wait_states({reload_id: 'observationUnavailable'})
            assert len(final) == 4 and all(row.get('completedAt') is None for row in final.values())
            captured = [json.loads(line) for path in root.glob('events-*.jsonl') for line in path.read_text().splitlines()]
            # 独立读取实际临时历史库，不能仅凭内存状态宣称观察记录已保存。
            with sqlite3.connect((root / 'history.store').as_uri() + '?mode=ro', uri=True) as database:
                columns = {row[1] for row in database.execute('PRAGMA table_info(ZSTOREDSESSION)')}
                required = {'ZSESSIONID', 'ZSOURCEINSTANCEID', 'ZNATIVETASKID', 'ZOBSERVATIONENDEDAT', 'ZCOMPLETEDAT'}
                assert required <= columns, '实际历史schema已变，需更新独立核对器'
                stored = database.execute('SELECT ZSESSIONID, ZSOURCEINSTANCEID, ZNATIVETASKID, '
                    'ZOBSERVATIONENDEDAT, ZCOMPLETEDAT FROM ZSTOREDSESSION').fetchall()
            assert {row[0] for row in stored} == set(final)
            assert len({row[1] for row in stored}) == 4
            assert all(row[2] == '共享任务🙂' and row[3] is not None and row[4] is None for row in stored)
        succeeded = True
        return {'passed': True, 'observationRecords': 4, 'nativeTaskIdPreserved': True,
                'normalExitObserved': True, 'crashLeaseExpired': True, 'expirySeconds': round(expiry_seconds, 2),
                'reloadedInstanceStayedActive': True, 'noTaskMarkedCompleted': True,
                'persistedObservationRecords': len(stored),
                'heartbeatsSent': sum(frame['type'] == 'observation_heartbeat' for frame in captured),
                'appSHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                'sourceSHA256': {str(path.relative_to(repository)): hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in [extension / 'src/task-observer.ts', extension / 'src/transport.ts',
                                 repository / 'Sources/DynamicIsland/Models/ObservationLease.swift',
                                 repository / 'Sources/DynamicIsland/Managers/SessionManager.swift']},
                'scope': 'Compiled TS observer and transport -> isolated XIsland app; synthetic vendor events',
                'realClientVerified': False, 'vendorClientLaunched': False}
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait(timeout=3)
        subprocess.run(['defaults', 'delete', suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if succeeded:
            shutil.rmtree(root)
        else:
            print(f'失败现场保留：{root}')


if __name__ == '__main__':
    repository = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser()
    parser.add_argument('--app-path', type=Path, default=repository / '.build/X Island.app')
    parser.add_argument('--report', type=Path)
    arguments = parser.parse_args()
    result = verify(repository, arguments.app_path.resolve(strict=True))
    encoded = json.dumps(result, ensure_ascii=False, indent=2)
    if arguments.report:
        arguments.report.write_text(encoded + '\n')
    print(encoded)
