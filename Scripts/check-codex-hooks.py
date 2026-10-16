#!/usr/bin/env python3
"""Read-only Codex hook discovery; never invokes hooks or changes trust."""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import queue
import subprocess
import threading
import time


def inspect(binary: Path, cwd: Path) -> dict:
    version = subprocess.run([str(binary), '--version'], capture_output=True, text=True, timeout=10)
    if version.returncode != 0:
        raise RuntimeError('Codex version command failed')
    process = subprocess.Popen([str(binary), 'app-server', '--stdio'], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    replies = queue.Queue()
    def read():
        try:
            while True:
                line = process.stdout.readline(4_194_305)
                if not line:
                    replies.put(RuntimeError('App-server closed stdout')); return
                if len(line) > 4_194_304:
                    replies.put(RuntimeError('App-server frame exceeded limit')); return
                try: replies.put(json.loads(line))
                except ValueError: replies.put(RuntimeError('Invalid app-server JSON')); return
        except OSError:
            replies.put(RuntimeError('App-server read failed'))
    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    def send(packet):
        process.stdin.write(json.dumps(packet) + '\n'); process.stdin.flush()
    def request(identifier, method, params):
        send({'id': identifier, 'method': method, 'params': params})
        deadline = time.monotonic() + 15
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0: raise RuntimeError('App-server response timeout')
            try: packet = replies.get(timeout=remaining)
            except queue.Empty: raise RuntimeError('App-server response timeout') from None
            if isinstance(packet, Exception): raise packet
            if not isinstance(packet, dict): raise RuntimeError('Invalid app-server response')
            if packet.get('id') != identifier: continue
            if 'error' in packet: raise RuntimeError('App-server rejected read-only request')
            return packet['result']
    try:
        request(1, 'initialize', {'clientInfo': {'name': 'xisland-readonly-check', 'version': '1'},
                                   'capabilities': {'experimentalApi': True}})
        send({'method': 'initialized', 'params': {}})
        response = request(2, 'hooks/list', {'cwds': [str(cwd)]})
        entries = []
        for entry in response['data']:
            hooks = entry['hooks']
            owned = [h for h in hooks if 'di-bridge' in str(h.get('command', '')) or '.xisland' in str(h.get('command', ''))]
            entries.append({'totalHookCount': len(hooks), 'xIslandHooks': [
                {key: h.get(key) for key in ['eventName', 'enabled', 'trustStatus', 'timeoutSec']} for h in owned],
                'errorCount': len(entry['errors']), 'warningCount': len(entry['warnings'])})
        return {'checkedAt': datetime.now(timezone.utc).isoformat(), 'binary': str(binary),
                'version': version.stdout.strip(), 'scope': 'Read-only initialize and hooks/list; no hook execution, model turn or trust change',
                'entries': entries}
    finally:
        process.terminate()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=5)
        reader.join(timeout=1)
        process.stdin.close(); process.stdout.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--cwd', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    report = inspect(args.binary.resolve(strict=True), args.cwd.resolve(strict=True))
    output = json.dumps(report, ensure_ascii=False, indent=2) + '\n'
    if args.report: args.report.write_text(output)
    print(output, end='')
