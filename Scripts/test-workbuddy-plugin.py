#!/usr/bin/env python3
"""Exercise exported WorkBuddy hook commands against an isolated socket, without running WorkBuddy."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading


def verify(binary: Path) -> dict:
    with tempfile.TemporaryDirectory(prefix='xi-wb-', dir='/tmp') as folder:
        root = Path(folder)
        plugin = root / 'exported-plugin'
        exported = subprocess.run([str(binary), 'workbuddy-plugin', str(plugin)], capture_output=True, timeout=5)
        assert exported.returncode == 0 and not exported.stdout, exported
        config_file = plugin / 'hooks/hooks.json'
        original = config_file.read_bytes()
        duplicate = subprocess.run([str(binary), 'workbuddy-plugin', str(plugin)], capture_output=True, timeout=5)
        assert duplicate.returncode == 65 and config_file.read_bytes() == original, duplicate
        manifest = json.loads((plugin / '.codebuddy-plugin/plugin.json').read_text())
        assert manifest['name'] == 'xisland-workbuddy-observer'
        marketplace = json.loads((plugin / '.codebuddy-plugin/marketplace.json').read_text())
        assert marketplace['name'] == 'xisland-workbuddy-local'
        assert marketplace['plugins'][0]['name'] == manifest['name']
        assert (plugin / marketplace['plugins'][0]['source']).resolve() == plugin.resolve()
        assert sorted(str(path.relative_to(plugin)) for path in plugin.rglob('*') if path.is_file()) == [
            '.codebuddy-plugin/marketplace.json', '.codebuddy-plugin/plugin.json', 'hooks/hooks.json']
        hooks = json.loads(original)['hooks']
        assert len(hooks) == 11 and 'PermissionRequest' not in hooks
        server = socket.socket(socket.AF_UNIX)
        server.bind(str(root / 'di.sock')); server.listen(32); server.settimeout(.1)
        messages, errors = [], []
        stopped = threading.Event()
        changed = threading.Condition()
        def collect():
            while not stopped.is_set():
                try: connection, _ = server.accept()
                except socket.timeout: continue
                with connection:
                    connection.settimeout(2)
                    try:
                        with connection.makefile('rb') as stream: message = json.loads(stream.readline())
                        with changed:
                            messages.append(message); changed.notify_all()
                    except Exception as error: errors.append(str(error))
        worker = threading.Thread(target=collect, daemon=True); worker.start()
        env = {**os.environ, 'DI_SOCKET_PATH': str(root / 'di.sock'), 'X_ISLAND_TEST_MODE': '1', 'X_ISLAND_TEST_RUNTIME_DIR': folder}
        env.pop('DI_BRIDGE_DEBUG_LOG', None)
        try:
            for event, groups in hooks.items():
                command = groups[0]['hooks'][0]['command']
                payload = {'hook_event_name': event, 'session_id': 'parent', 'cwd': '/tmp/project', 'source': 'startup',
                           'prompt': 'fixture', 'tool_name': 'Read', 'tool_input': {'path': 'fixture'},
                           'call_id': 'call-1', 'tool_use_id': 'call-1', 'tool_response': 'result', 'error': 'fixture failure',
                           'last_assistant_message': '中文 reply', 'final_stop_reason': 'completed',
                           'agent_id': 'child', 'message': 'permission', 'notification_type': 'permission_prompt'}
                result = subprocess.run(command, shell=True, executable='/bin/bash', input=json.dumps(payload).encode(),
                                        capture_output=True, timeout=5, env=env)
                assert result.returncode == 0 and result.stdout == b'' and not result.stderr, (event, result)
            with changed: assert changed.wait_for(lambda: len(messages) == 11, timeout=3), messages
            command = hooks['PreToolUse'][0]['hooks'][0]['command']
            malformed = subprocess.run(command, shell=True, executable='/bin/bash', input=b'{}', capture_output=True, timeout=5, env=env)
            assert malformed.returncode == 0 and not malformed.stdout and malformed.stderr
            assert not errors, errors
            by_event = {m['nativeEvent'].split(':', 1)[1]: m for m in messages}
            assert all(m['agentType'] == 'workbuddy' and m['sessionId'].startswith('workbuddy-') for m in messages)
            assert all(m['type'] not in ['permission_request', 'session_end'] for m in messages)
            assert by_event['Stop']['observedState'] == 'completionUnconfirmed' and by_event['Stop']['status'] == '中文 reply'
            assert by_event['FinalStop']['observedState'] == 'idle'
            assert 'observedState' not in by_event['SessionEnd'] and 'observedState' not in by_event['SubagentStop']
            assert by_event['PostToolUse']['toolCallId'] == 'call-1'
        finally:
            stopped.set(); worker.join(2); server.close()
    return {'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'hookEvents': 11,
            'localMarketplaceManifestVerified': True, 'exportedFiles': 3,
            'exportOverwriteRejected': True, 'stdoutNeutral': True, 'malformedObserverDidNotBlock': True,
            'scope': 'Exported commands, compiled bridge and isolated socket; synthetic vendor payloads',
            'realClientVerified': False, 'installed': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=Path('.build/debug/DIBridge'))
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    report = verify(args.binary.resolve(strict=True))
    output = json.dumps(report, ensure_ascii=False, indent=2) + '\n'
    if args.report: args.report.write_text(output)
    print(output, end='')
