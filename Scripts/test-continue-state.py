#!/usr/bin/env python3
"""验证 Continue 观察器的真实 HTTP 传输；只启动本地离线 fixture。"""
from __future__ import annotations
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading


def verify(binary: Path) -> list[str]:
    passed = []
    for mode in ['valid', 'changed-session', 'redirect', 'oversized', 'wrong-type', 'invalid-json']:
        requests = []
        messages = []
        errors = []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_GET(self):
                requests.append(('GET', self.path))
                identifier = 'replacement' if mode == 'changed-session' and len(requests) > 1 else 'native'
                body = json.dumps({'session': {'sessionId': identifier, 'history': []}, 'isProcessing': False,
                                   'messageQueueLength': 0, 'pendingPermission': None}).encode()
                if mode == 'invalid-json':
                    body = b'{invalid'
                if mode == 'oversized':
                    body = b'x' * 2097153
                self.send_response(302 if mode == 'redirect' else 200)
                self.send_header('Content-Type', 'text/html' if mode == 'wrong-type' else 'application/json')
                if mode == 'redirect':
                    self.send_header('Location', '/must-not-follow')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass
            def do_POST(self):
                requests.append(('POST', self.path))
                self.send_error(405)
        with tempfile.TemporaryDirectory(prefix='xi-cn-', dir='/tmp') as folder:
            root = Path(folder)
            listener = socket.socket(socket.AF_UNIX)
            listener.bind(str(root / 'di.sock'))
            listener.listen(32)
            listener.settimeout(.1)
            stop = threading.Event()
            def collect():
                while not stop.is_set():
                    try:
                        connection, _ = listener.accept()
                    except socket.timeout:
                        continue
                    except OSError:
                        return
                    with connection:
                        connection.settimeout(1)
                        try:
                            with connection.makefile('rb') as stream:
                                messages.append(json.loads(stream.readline()))
                        except Exception as error:
                            errors.append(str(error))
            reader = threading.Thread(target=collect, daemon=True)
            reader.start()
            server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                result = subprocess.run([str(binary), 'continue-state', '--url', f'http://127.0.0.1:{server.server_port}',
                                         '--duration', '1', '--interval', '0.2'], capture_output=True, timeout=6,
                                        env={**os.environ, 'DI_SOCKET_PATH': str(root / 'di.sock'), 'X_ISLAND_TEST_MODE': '1',
                                             'X_ISLAND_TEST_RUNTIME_DIR': folder})
                assert result.returncode == (0 if mode == 'valid' else 1), (mode, result.stderr)
                assert not result.stdout, (mode, 'unexpected stdout')
                assert requests and all(request == ('GET', '/state') for request in requests), requests
            finally:
                server.shutdown()
                server.server_close()
                worker.join(2)
                stop.set()
                reader.join(2)
                listener.close()
            assert not errors, errors
            if mode in ['valid', 'changed-session']:
                assert len(messages) == 2, (mode, messages)
                assert messages[0]['observedState'] == 'idle', messages
                assert all(message['sessionId'] == messages[0]['sessionId'] for message in messages)
                assert all(message['type'] != 'session_end' for message in messages)
            else:
                assert not messages, (mode, messages)
            if mode == 'changed-session':
                assert len(requests) == 2, requests
            passed.append(mode)
    return passed


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--report', type=Path)
    arguments = parser.parse_args()
    binary = arguments.binary.resolve()
    result = {'binary': str(binary), 'sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
              'scenarios': verify(binary), 'realClientVerified': False}
    encoded = json.dumps(result, ensure_ascii=False, indent=2)
    if arguments.report:
        arguments.report.write_text(encoded + '\n')
    print(encoded)
