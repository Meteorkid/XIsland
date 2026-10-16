#!/usr/bin/env python3
"""Cody 透明转发离线检查，不执行厂商程序。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading

parser = argparse.ArgumentParser()
parser.add_argument('--binary', type=Path, default=Path('.build/debug/DIBridge'))
parser.add_argument('--report', type=Path)
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='xi-cody-', dir='/tmp') as folder:
    root = Path(folder)
    child = root / 'fixture.py'
    child.write_text('''import os, sys
while True:
 data=os.read(0,16384)
 if not data:break
 os.write(1,data)
sys.stderr.write('fixture-stderr\\n')
sys.exit(17)
''')
    server = socket.socket(socket.AF_UNIX)
    server.bind(str(root / 'di.sock'))
    server.listen(8)
    server.settimeout(.1)
    messages, errors = [], []
    stop = threading.Event()
    def collect():
        while not stop.is_set():
            try: conn, _ = server.accept()
            except socket.timeout: continue
            with conn:
                conn.settimeout(1)
                try:
                    with conn.makefile('rb') as stream: messages.append(json.loads(stream.readline()))
                except Exception as error: errors.append(str(error))
    worker = threading.Thread(target=collect, daemon=True)
    worker.start()
    def frame(processing):
        body = json.dumps({'jsonrpc': '2.0', 'method': 'webview/postMessage', 'params': {'id': 'panel', 'message':
            {'type': 'transcript', 'chatID': 'native', 'isMessageInProgress': processing, 'messages': []}}}).encode()
        return f'Content-Length: {len(body)}\r\n\r\n'.encode() + body
    payload = frame(True) + frame(False) + b'opaque-trailing-bytes'
    env = {**os.environ, 'DI_SOCKET_PATH': str(root / 'di.sock'), 'X_ISLAND_TEST_MODE': '1', 'X_ISLAND_TEST_RUNTIME_DIR': folder}
    env.pop('X_ISLAND_ACP_WRAPPER_ACTIVE', None)
    try:
        result = subprocess.run([str(args.binary.resolve()), 'cody-agent', '--source', 'fixture', '--', sys.executable, str(child)],
                                input=payload, capture_output=True, timeout=10, env=env)
    finally:
        stop.set()
        worker.join(2)
        server.close()
    assert result.returncode == 17, result
    assert result.stdout == payload, result.stdout
    assert result.stderr == b'fixture-stderr\n', result.stderr
    assert not errors, errors
    assert [message['observedState'] for message in messages if 'observedState' in message] == ['active', 'idle'], messages
    assert len(messages) == 3 and messages[-1]['nativeEvent'] == 'cody_observation_ended', messages
    assert 'observedState' not in messages[-1] and '可能已过期' in messages[-1]['status'], messages
    assert len({message['sessionId'] for message in messages}) == 1
    assert all(message['agentType'] == 'cody' for message in messages)
print('Cody process passthrough, observation, stderr and exit code passed')
if args.report:
    args.report.write_text(json.dumps({'binary': str(args.binary.resolve()),
        'binarySHA256': hashlib.sha256(args.binary.read_bytes()).hexdigest(),
        'passed': ['raw-byte-transparency', 'stderr-preserved', 'exit-code-preserved',
                   'native-chat-observation', 'truncated-frame-observation-stopped'],
        'realClientVerified': False}, indent=2) + '\n')
