#!/usr/bin/env python3
"""旧 Q 包装器离线往返；不执行 Q 客户端。"""
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
import time

parser = argparse.ArgumentParser()
parser.add_argument('--binary', type=Path, default=Path('.build/debug/DIBridge'))
parser.add_argument('--report', type=Path)
args = parser.parse_args()
binary = args.binary.resolve()
with tempfile.TemporaryDirectory(prefix='xi-q-flow-', dir='/tmp') as folder:
    root = Path(folder)
    child = root / 'fixture.py'
    child.write_text('#!' + sys.executable + '\n' + '''import json, os, pathlib, subprocess, sys
if sys.argv[1:] == ['--version']:
 mode=os.environ.get('XI_Q_VERSION_MODE','valid')
 if os.environ.get('XI_Q_PROBE_PID'): pathlib.Path(os.environ['XI_Q_PROBE_PID']).write_text(str(os.getpid()))
 if mode=='wrong': print('kiro-cli 1.19.7');sys.exit(0)
 if mode=='failed': print('qchat 1.19.7');sys.exit(1)
 if mode=='oversized': os.write(1,b'x'*1000000);sys.exit(0)
 if mode=='hang':
  import signal,time
  signal.signal(signal.SIGTERM,signal.SIG_IGN)
  time.sleep(30)
 print('qchat 1.19.7');sys.exit(0)
bridge, marker = sys.argv[1:]
pathlib.Path(marker).write_text(os.environ['X_ISLAND_AMAZONQ_LEASE'])
for event in ['agentSpawn', 'userPromptSubmit', 'preToolUse', 'postToolUse', 'stop']:
 payload={'hook_event_name':event,'cwd':'/tmp/same-project','prompt':'fixture',
          'tool_name':'read','tool_input':{'path':'fixture'},'tool_response':{'success':False,'error':['fixture']}}
 p=subprocess.run([bridge,'amazonq-hook-1-19-7',event],input=json.dumps(payload).encode(),capture_output=True,timeout=5)
 assert p.returncode==0 and not p.stdout and not p.stderr,(event,p.returncode,p.stdout,p.stderr)
print('original-output')
sys.stderr.write('original-error\\n')
sys.exit(17)
''')
    child.chmod(0o700)
    server = socket.socket(socket.AF_UNIX)
    server.bind(str(root / 'di.sock'))
    server.listen(32)
    server.settimeout(.1)
    messages, errors = [], []
    stopped = threading.Event()
    changed = threading.Condition()
    def collect():
        while not stopped.is_set():
            try: connection, _ = server.accept()
            except socket.timeout: continue
            with connection:
                connection.settimeout(1)
                try:
                    with connection.makefile('rb') as stream: message = json.loads(stream.readline())
                    with changed:
                        messages.append(message)
                        changed.notify_all()
                except Exception as error: errors.append(str(error))
    worker = threading.Thread(target=collect, daemon=True)
    worker.start()
    env = {**os.environ, 'DI_SOCKET_PATH': str(root / 'di.sock'), 'X_ISLAND_TEST_MODE':'1', 'X_ISLAND_TEST_RUNTIME_DIR':folder}
    env.pop('X_ISLAND_AMAZONQ_LEASE', None)
    try:
        for run in range(2):
            marker = root / f'lease-{run}'
            result = subprocess.run([str(binary), 'amazonq-1-19-7', '--', str(child), str(binary), str(marker)],
                                    capture_output=True, timeout=15, env=env)
            assert (result.returncode,result.stdout,result.stderr)==(17,b'original-output\n',b'original-error\n'),result
            with changed:
                assert changed.wait_for(lambda: len(messages) >= (run+1)*7,timeout=3), messages
            path = marker.read_text()
            assert not Path(path).exists(), path
            late = subprocess.run([str(binary),'amazonq-hook-1-19-7','userPromptSubmit'],
                                  input=b'{"hook_event_name":"userPromptSubmit","cwd":"/tmp","prompt":"late"}',
                                  capture_output=True,timeout=5,env={**env,'X_ISLAND_AMAZONQ_LEASE':path})
            assert late.returncode==0 and not late.stdout and late.stderr,late
        assert not errors,errors
        assert len(messages)==14,messages
        expected=['status_update','status_update','session_start','status_update','tool_complete','status_update','session_end']
        for start in [0,7]:
            batch=messages[start:start+7]
            assert [m['type'] for m in batch]==expected,batch
            assert len({m['sessionId'] for m in batch})==1
            assert all(m['agentType']=='amazon_q' for m in batch)
            assert batch[4]['observedState']=='error'
            assert batch[5]['observedState']=='idle'
        assert messages[0]['sessionId']!=messages[7]['sessionId']
        for mode in ['wrong','failed','oversized','hang']:
            marker=root / ('must-not-start-'+mode)
            pid_file=root / ('probe-pid-'+mode)
            started=time.monotonic()
            rejected=subprocess.run([str(binary),'amazonq-1-19-7','--',str(child),str(binary),str(marker)],
                capture_output=True,timeout=5,env={**env,'XI_Q_VERSION_MODE':mode,'XI_Q_PROBE_PID':str(pid_file)})
            assert rejected.returncode==126 and not rejected.stdout,(mode,rejected)
            assert not marker.exists(),mode
            assert time.monotonic()-started<4,mode
            assert pid_file.exists(),mode
            try: os.kill(int(pid_file.read_text()),0)
            except ProcessLookupError: pass
            else: raise AssertionError('version probe survived: '+mode)
        assert len(messages)==14,messages
    finally:
        stopped.set();worker.join(2);server.close()
report={'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),
        'passed':['five-hook-roundtrip','stdout-stderr-exit-preserved','late-hook-rejected','same-cwd-wrapper-isolation','lease-cleanup',
                  'wrong-version-rejected','failed-probe-rejected','oversized-probe-rejected','hung-probe-killed'],
        'realClientVerified':False}
if args.report: args.report.write_text(json.dumps(report,indent=2)+'\n')
print('Amazon Q wrapper: 9 offline checks passed')
