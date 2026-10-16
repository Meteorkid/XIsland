#!/usr/bin/env python3
"""只读旧库 → SQLite backup 副本 → 隔离真实 App；核对 v4 迁移和升级前备份。"""
from __future__ import annotations

import argparse
from contextlib import closing, contextmanager
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import pty
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from typing import Any, Iterator
import uuid


TABLES = {'ZSTOREDSESSION': 'ZSESSIONID', 'ZSTOREDTOOLEVENT': 'ZEVENTID',
          'ZSTOREDCHATMESSAGE': 'ZMESSAGEID'}
PHYSICAL_COLUMNS = {'Z_PK', 'Z_ENT', 'Z_OPT'}
APPROVAL_COLUMN = 'ZKIMICODEAPPROVALOBSERVATIONDATA'
ORPHAN_TABLE = 'ZSTOREDKIMICODEAPPROVALORPHAN'


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def canonical(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False)


def digest(value: Any) -> str:
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def encoded(value: Any) -> Any:
    return {'sqliteBlobHex': value.hex()} if isinstance(value, bytes) else value


def quote(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


@contextmanager
def read_only(path: Path) -> Iterator[sqlite3.Connection]:
    # 绝不以默认可写模式打开来源、App 库或 App 自行生成的备份。
    connection = sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=2)
    try:
        connection.execute('PRAGMA query_only=ON')
        yield connection
    finally:
        connection.close()


def schema(connection: sqlite3.Connection) -> dict[str, list[list[Any]]]:
    names = [row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
    return {name: [list(row) for row in connection.execute('PRAGMA table_info(' + quote(name) + ')')]
            for name in names}


def business_snapshot(connection: sqlite3.Connection, old_columns: dict[str, list[str]]) -> dict[str, Any]:
    result = {}
    for table, columns in old_columns.items():
        actual = {row[1] for row in connection.execute('PRAGMA table_info(' + quote(table) + ')')}
        require(set(columns) <= actual, f'{table} 丢失旧业务列')
        child = table != 'ZSTOREDSESSION'
        selected = [f'c.{quote(column)}' for column in columns if column != 'ZSESSION']
        labels = [column for column in columns if column != 'ZSESSION']
        if child:
            selected.append('s.ZSESSIONID')
            labels.append('PARENT_SESSION_ID')
        query = 'SELECT ' + ','.join(selected) + ' FROM ' + quote(table) + ' c'
        if child:
            query += ' LEFT JOIN ZSTOREDSESSION s ON c.ZSESSION=s.Z_PK'
        rows = [dict(zip(labels, map(encoded, row))) for row in connection.execute(query)]
        require(len(rows) == connection.execute('SELECT COUNT(*) FROM ' + quote(table)).fetchone()[0],
                f'{table} JOIN 改变了记录数')
        if child:
            require(all(row['PARENT_SESSION_ID'] is not None for row in rows), f'{table} 存在失联子记录')
        stable = TABLES[table]
        require(all(row[stable] is not None for row in rows), f'{table} 缺少稳定 ID，不能声称保持不变')
        identities = [(row.get('PARENT_SESSION_ID'), canonical(row[stable])) for row in rows]
        require(len(identities) == len(set(identities)), f'{table} 存在重复稳定 ID')
        result[table] = sorted(rows, key=canonical)
    return result


def summary(snapshot: dict[str, Any], old_columns: dict[str, list[str]]) -> dict[str, Any]:
    tables = {}
    for table, rows in snapshot.items():
        identity_fields = {TABLES[table], 'PARENT_SESSION_ID', 'ZSTARTTIME', 'ZCOMPLETEDAT',
                           'ZOBSERVATIONENDEDAT', 'ZHISTORYDATE', 'ZTIMESTAMP'}
        tables[table] = {'count': len(rows), 'sha256': digest(rows), 'comparedOldColumns': old_columns[table],
                         'identitiesAndTimes': [{key: value for key, value in row.items() if key in identity_fields}
                                                for row in rows]}
    return {'businessSHA256': digest(snapshot), 'tables': tables}


def verify(repository: Path, app: Path, legacy: Path, report: dict[str, Any]) -> None:
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location('xisland_finality_helpers', repository / 'Scripts/test-main-finality-app.py')
    require(spec is not None and spec.loader is not None, '缺少应用验证辅助函数')
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    with (app / 'Contents/Info.plist').open('rb') as stream:
        name = plistlib.load(stream).get('CFBundleExecutable')
    require(isinstance(name, str) and bool(name) and Path(name).name == name, '非法 App 主程序名')
    binary, bridge = app / 'Contents/MacOS' / name, app / 'Contents/MacOS/di-bridge'
    report.update(appPath=str(app), bridgePath=str(bridge), appSHA256=helper.sha256(binary),
                  bridgeSHA256=helper.sha256(bridge), legacyStorePath=str(legacy),
                  legacyStoreSHA256Before=helper.sha256(legacy))
    report['freshness'] = {'app': helper.verify_freshness(repository, binary, 'DynamicIsland'),
                           'bridge': helper.verify_freshness(repository, bridge, 'DIBridge')}

    runtime = Path(tempfile.mkdtemp(prefix='xi-mig-', dir='/tmp'))
    suite = 'dev.xisland.tests.migration-' + uuid.uuid4().hex
    history, diagnostics = runtime / 'history.store', runtime / 'diagnostics.json'
    backup = runtime / 'HistoryBackups/history.store.pre-tool-completion-status-v5.sqlite'
    report.update(runtimeDirectory=str(runtime), defaultsSuite=suite, backupPath=str(backup),
                  sourceOpenMode='mode=ro + query_only', copyMethod='sqlite3.Connection.backup')
    process = None
    master = slave = None
    succeeded = False
    env = {key: value for key, value in os.environ.items() if not key.startswith('X_ISLAND_TEST_')}
    for key in ('DI_SESSION_ID', 'DI_BRIDGE_DEBUG_LOG', 'DI_SOCKET_PATH'):
        env.pop(key, None)
    env.update(X_ISLAND_TEST_MODE='1', X_ISLAND_TEST_RUNTIME_DIR=str(runtime),
               X_ISLAND_TEST_DEFAULTS_SUITE=suite, X_ISLAND_TEST_DIAGNOSTICS_PATH=str(diagnostics),
               X_ISLAND_DISABLE_ANIMATIONS='1', DI_SOCKET_PATH=str(runtime / 'di.sock'))
    log_bytes = bytearray()

    def collect_log() -> None:
        if master is None:
            return
        while True:
            try:
                data = os.read(master, 65536)
            except BlockingIOError:
                break
            except OSError as error:
                if error.errno != 5:  # PTY 在子进程退出后返回 EIO。
                    raise
                break
            if not data:
                break
            log_bytes.extend(data)
        (runtime / 'app.log').write_bytes(log_bytes)

    def wait(check, description: str) -> Any:
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            collect_log()
            require(process is not None and process.poll() is None, '隔离 App 已退出：' + description)
            result = check()
            if result:
                return result
            time.sleep(0.05)
        raise AssertionError('等待超时：' + description + '；现场：' + str(runtime))

    try:
        require(history.resolve() != legacy and not history.exists(), '拒绝覆盖来源或已有目标库')
        with read_only(legacy) as source:
            source.execute('BEGIN')
            require(source.execute('PRAGMA integrity_check').fetchall() == [('ok',)], '旧库完整性失败')
            old_schema = schema(source)
            require(set(TABLES) <= set(old_schema), '旧库缺少会话、工具或聊天表')
            require(APPROVAL_COLUMN not in {row[1] for row in old_schema['ZSTOREDSESSION']}
                    and ORPHAN_TABLE not in old_schema, '来源已经包含 v4 schema，拒绝伪迁移验证')
            old_columns = {table: sorted(row[1] for row in old_schema[table] if row[1] not in PHYSICAL_COLUMNS)
                           for table in TABLES}
            original = business_snapshot(source, old_columns)
            require(len(original['ZSTOREDSESSION']) == 13, '此验收要求已知的 13 会话旧测试库')
            require(original['ZSTOREDTOOLEVENT'] and original['ZSTOREDCHATMESSAGE'], '缺少非空子记录覆盖')
            report['source'] = summary(original, old_columns)
            report['sourceSchemaSHA256'] = digest(old_schema)
            # 唯一可写 SQLite 连接指向刚创建的隔离副本，源连接始终只读。
            with closing(sqlite3.connect(history)) as destination:
                source.backup(destination)
                # 副本脱离旧 WAL/SHM 后应可单独只读打开；这里只更改新副本的日志模式。
                require(destination.execute('PRAGMA journal_mode=DELETE').fetchone() == ('delete',),
                        'SQLite backup 副本未完成独立文件收尾')
        with read_only(history) as copied:
            require(schema(copied) == old_schema and canonical(business_snapshot(copied, old_columns)) == canonical(original),
                    'SQLite backup 副本未完整保留旧库')
        report['copyEqualsSourceBeforeLaunch'] = True

        # PTY 使真实主程序的启动回执即时刷新，仍仅启动自己的单个隔离进程。
        master, slave = pty.openpty()
        os.set_blocking(master, False)
        process = subprocess.Popen([str(binary), '--ui-test-mode', '--ui-test-socket', '--fixture-path',
            str(repository / 'Tests/Fixtures/app/empty-interaction.json')], env=env, stdout=slave, stderr=slave)
        os.close(slave)
        slave = None
        report['isolatedAppPID'] = process.pid
        wait(lambda: diagnostics.exists() and (runtime / 'di.sock').exists() and backup.exists()
             and b'[Persistence] Container setup complete' in log_bytes, 'App 已打开历史库、完成迁移并启动隔离服务')
        state = json.loads(diagnostics.read_text())
        require(state.get('visibleSessions') == [] and state.get('pendingInteraction') is None,
                '空 fixture 产生了意外活动会话或交互')
        require(state.get('handledMessageCount') == 0, '迁移验证期间出现了额外 hook 消息')
        report['diagnostics'] = state
        report['appContainerSetupComplete'] = True

        with read_only(backup) as saved:
            require(saved.execute('PRAGMA integrity_check').fetchall() == [('ok',)], '升级前备份完整性失败')
            saved_schema = schema(saved)
            saved_snapshot = business_snapshot(saved, old_columns)
            require(saved_schema == old_schema, 'App 备份不是迁移前 v3 schema')
            require(canonical(saved_snapshot) == canonical(original), 'App 备份业务字段、稳定 ID、归属或时间改变')
            report['backup'] = summary(saved_snapshot, old_columns)
            report.update(backupSchemaSHA256=digest(saved_schema), backupSHA256=helper.sha256(backup),
                          backupRetainsV3Schema=True)
        with read_only(history) as migrated:
            require(migrated.execute('PRAGMA integrity_check').fetchall() == [('ok',)], '迁移库完整性失败')
            new_schema = schema(migrated)
            approval = next((row for row in new_schema['ZSTOREDSESSION'] if row[1] == APPROVAL_COLUMN), None)
            require(approval is not None and approval[2] == 'BLOB' and approval[3] == 0, '缺少可选 Data 列')
            require(ORPHAN_TABLE in new_schema, '缺少孤立审批结果表')
            require({'ZSESSIONID', 'ZOBSERVATIONDATA', 'ZUPDATEDAT'} <= {row[1] for row in new_schema[ORPHAN_TABLE]},
                    '孤立审批结果表结构不符')
            orphan_count = migrated.execute('SELECT COUNT(*) FROM ' + ORPHAN_TABLE).fetchone()[0]
            approval_count = migrated.execute('SELECT COUNT(*) FROM ZSTOREDSESSION WHERE ' + APPROVAL_COLUMN + ' IS NOT NULL').fetchone()[0]
            require(orphan_count == 0 and approval_count == 0, '迁移凭空产生了审批事实')
            outcome = next((row for row in new_schema['ZSTOREDTOOLEVENT'] if row[1] == 'ZNATIVECOMPLETIONSTATUS'), None)
            require(outcome is not None and outcome[2] == 'VARCHAR' and outcome[3] == 0,
                    '缺少可选工具原生终态列')
            outcome_count = migrated.execute('SELECT COUNT(*) FROM ZSTOREDTOOLEVENT WHERE ZNATIVECOMPLETIONSTATUS IS NOT NULL').fetchone()[0]
            require(outcome_count == 0, '迁移凭空产生了工具终态')
            report.update(nativeCompletionStatusColumn=outcome, nonNullNativeCompletionStatusCount=outcome_count)
            migrated_snapshot = business_snapshot(migrated, old_columns)
            require(canonical(migrated_snapshot) == canonical(original), '迁移改变了旧业务字段、稳定 ID、归属或原时间')
            report['migrated'] = summary(migrated_snapshot, old_columns)
            report.update(migratedSchemaSHA256=digest(new_schema), approvalColumn=approval,
                          orphanTableSchema=new_schema[ORPHAN_TABLE], orphanCount=orphan_count,
                          nonNullApprovalDataCount=approval_count)
        with read_only(legacy) as source:
            require(schema(source) == old_schema and canonical(business_snapshot(source, old_columns)) == canonical(original),
                    '验证期间来源 schema 或业务数据改变')
        helper.verify_freshness(repository, binary, 'DynamicIsland')
        helper.verify_freshness(repository, bridge, 'DIBridge')
        require(helper.sha256(binary) == report['appSHA256'] and helper.sha256(bridge) == report['bridgeSHA256'],
                '验证期间 App 或 bridge 被替换')
        require(process.poll() is None, '隔离 App 在迁移核对期间退出')
        report['allBusinessFieldsStableIdsOwnershipAndTimesEqual'] = True
        succeeded = True
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
        collect_log()
        for descriptor in (master, slave):
            if descriptor is not None:
                os.close(descriptor)
        subprocess.run(['/usr/bin/defaults', 'delete', suite], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=5)
        defaults = subprocess.run(['/usr/bin/defaults', 'read', suite], stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL, timeout=5)
        report['defaultsCleaned'] = defaults.returncode != 0
        report['legacyStoreSHA256After'] = helper.sha256(legacy)
        report['legacyMainFileUnchanged'] = report['legacyStoreSHA256After'] == report['legacyStoreSHA256Before']
        report['isolatedProcessStopped'] = process is None or process.poll() is not None
        if succeeded and report['legacyMainFileUnchanged'] and report['defaultsCleaned']:
            shutil.rmtree(runtime)
            report['runtimeCleaned'] = not runtime.exists()
        else:
            report['failureArtifacts'] = str(runtime)
        require(report['legacyMainFileUnchanged'], '原库主文件 SHA 改变，现场已保留')
        require(report['defaultsCleaned'], '隔离 defaults 未清理，现场已保留')
    report['passed'] = True


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--legacy-store', type=Path, required=True)
    parser.add_argument('--app-path', type=Path, default=repository / '.build/X Island.app')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    legacy = args.legacy_store.resolve(strict=True)
    require(legacy.is_file(), '旧库必须是现有文件')
    if args.report:
        output = args.report.resolve()
        require(output != legacy and legacy.parent not in output.parents,
                '报告不能写入来源现场，拒绝覆盖原库或其旁文件')
        require(not output.exists() or not os.path.samefile(output, legacy), '报告不能覆盖原库硬链接')
    report = {'passed': False, 'checkedAt': datetime.now(timezone.utc).isoformat(),
              'realClientVerified': False, 'vendorClientLaunched': False, 'modelOrToolExecuted': False,
              'userDataMigrated': False, 'productionStartupSideEffectsEnabled': False,
              'scope': 'Known synthetic v3 test store copied with read-only SQLite backup, migrated by the current isolated real App; all legacy business values compared independently'}
    try:
        verify(repository, args.app_path.resolve(strict=True), legacy, report)
    except (AssertionError, OSError, ValueError, KeyError, sqlite3.Error, subprocess.SubprocessError) as error:
        report.update(passed=False, error=f'{type(error).__name__}: {error}')
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'passed': report['passed'], 'businessSHA256': report.get('source', {}).get('businessSHA256'),
                      'error': report.get('error'), 'failureArtifacts': report.get('failureArtifacts')}, ensure_ascii=False))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
