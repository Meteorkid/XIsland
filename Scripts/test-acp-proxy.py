#!/usr/bin/env python3
"""用离线 ACP Agent 与临时 Unix socket 验证原始字节透传；不调用模型。"""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time


def verify(binary: Path) -> list[str]:
    results: list[str] = []
    with tempfile.TemporaryDirectory(prefix='xi-acp-', dir='/tmp') as temporary:
        root = Path(temporary)
        agent = root / "agent 'quoted'.py"
        agent.write_text('''import json, os, sys
mode=sys.argv[1]
if mode == 'echo':
 while True:
  data=os.read(0,16384)
  if not data:break
  os.write(1,data)
 sys.stderr.write('agent-stderr\\n');sys.exit(17)
if mode == 'wait':
 print(json.dumps({'pid':os.getpid()}),flush=True)
 import time
 while True:time.sleep(1)
version=int(mode)
session='native-session'
def emit(packet):
 raw=('  '+json.dumps(packet,ensure_ascii=False)+'  \\r\\n').encode()
 with open(os.environ['XI_AGENT_OUTPUT'],'ab') as out:out.write(raw)
 os.write(1,raw)
def response(identifier,result):emit({'jsonrpc':'2.0','id':identifier,'result':result})
for raw in sys.stdin.buffer:
 with open(os.environ['XI_AGENT_INPUT'],'ab') as out:out.write(raw)
 p=json.loads(raw)
 m=p.get('method')
 if m=='initialize':response(p['id'],{'protocolVersion':version})
 elif m=='session/new':response(p['id'],{'sessionId':session})
 elif m=='session/prompt':
  if version==2:response(p['id'],{'messageId':'native-user'})
  emit({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':session,'update':{'sessionUpdate':'agent_message_chunk','messageId':'reply','content':{'type':'text','text':'中文 reply'}}}})
  permission={'sessionId':session,'options':[{'optionId':'deny','name':'Deny','kind':'reject_once'}]}
  if version==1:permission['toolCall']={'toolCallId':'call','title':'Test'}
  else:permission['title']='Test'
  emit({'jsonrpc':'2.0','id':p['id'],'method':'session/request_permission','params':permission})
 elif 'result' in p:
  if version==1:response(p['id'],{'stopReason':'cancelled'})
  else:emit({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':session,'update':{'sessionUpdate':'state_update','state':'idle','stopReason':'cancelled'}}})
''')
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(root / 'di.sock')); server.listen(32); server.settimeout(.1)
        messages: list[dict] = []
        errors: list[str] = []
        stop = threading.Event()
        def collect() -> None:
            while not stop.is_set():
                try: connection, _ = server.accept()
                except socket.timeout: continue
                except OSError: return
                with connection:
                    connection.settimeout(1)
                    try:
                        with connection.makefile('rb') as stream: messages.append(json.loads(stream.readline()))
                    except Exception as error: errors.append(str(error))
        worker = threading.Thread(target=collect, daemon=True); worker.start()
        env = dict(os.environ)
        env.pop('X_ISLAND_ACP_WRAPPER_ACTIVE', None)
        env.update(X_ISLAND_TEST_MODE='1', X_ISLAND_TEST_RUNTIME_DIR=str(root), DI_SOCKET_PATH=str(root / 'di.sock'))
        def command(host: str, mode: str) -> list[str]:
            return [str(binary), 'acp', '--host', host, '--source', 'test registration', '--', sys.executable, str(agent), mode]
        def line(process: subprocess.Popen) -> bytes:
            # 无缓冲 stdout，select 不会错过 Python 文件对象私有缓冲内的下一行。
            value = bytearray(); deadline = time.monotonic() + 5
            while not value.endswith(b'\n'):
                assert time.monotonic() < deadline, 'proxy response timeout'
                if select.select([process.stdout], [], [], .05)[0]:
                    part = os.read(process.stdout.fileno(), 1)
                    assert part, 'unexpected EOF'
                    value.extend(part)
            return bytes(value)
        try:
            for host, version in [('zed', 1), ('jetbrains_ai', 2)]:
                base = len(messages)
                incoming = root / f'input-{version}'; outgoing = root / f'output-{version}'
                process = subprocess.Popen(command(host, str(version)), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, bufsize=0,
                                           env={**env, 'XI_AGENT_INPUT': str(incoming), 'XI_AGENT_OUTPUT': str(outgoing)})
                sent = bytearray(); received = bytearray()
                def send(packet: dict) -> None:
                    raw=(' '+json.dumps(packet,ensure_ascii=False)+' \n').encode();sent.extend(raw)
                    process.stdin.write(raw); process.stdin.flush()
                try:
                    send({'jsonrpc':'2.0','id':0,'method':'initialize','params':{'protocolVersion':version}})
                    received.extend(line(process))
                    send({'jsonrpc':'2.0','id':1,'method':'session/new','params':{'cwd':'/tmp/project','mcpServers':[{'env':[{'name':'TOKEN','value':'DO-NOT-OBSERVE'}]}]}})
                    received.extend(line(process))
                    send({'jsonrpc':'2.0','id':7,'method':'session/prompt','params':{'sessionId':'native-session','prompt':[{'type':'text','text':'Fixture'}]}})
                    if version==2:received.extend(line(process))
                    received.extend(line(process)); received.extend(line(process))
                    send({'jsonrpc':'2.0','id':7,'result':{'outcome':{'outcome':'cancelled'}}})
                    received.extend(line(process)); process.stdin.close()
                    assert process.wait(timeout=5)==0
                    assert process.stdout.read()==b''
                    assert process.stderr.read()==b''
                    assert incoming.read_bytes()==bytes(sent)
                    assert outgoing.read_bytes()==bytes(received)
                    deadline=time.monotonic()+2
                    while len(messages)==base and time.monotonic()<deadline:time.sleep(.01)
                    observed=messages[base:]
                    assert observed and all(m['agentType']==host for m in observed), observed
                    assert any(m.get('observedState')=='waitingPermission' for m in observed), observed
                    assert not any(m['type'] in ['permission_request','permission_response','question'] for m in observed)
                    assert 'DO-NOT-OBSERVE' not in json.dumps(observed)
                    assert not errors, errors
                    results.append(f'{host}:v{version}-bidirectional-ids-permission-and-byte-preservation')
                finally:
                    if process.poll() is None:process.kill();process.wait(timeout=2)
                    for stream in [process.stdin,process.stdout,process.stderr]:stream.close()
            data=(b'raw\x00\xff\r\n'+b'x'*1_048_600+b'\n')*2
            echo=subprocess.run(command('zed','echo'),input=data,capture_output=True,env=env,timeout=8)
            assert echo.returncode==17 and echo.stdout==data and echo.stderr==b'agent-stderr\n'
            results.append('opaque-oversized-and-non-json-bytes-stderr-exit-preserved')
            waiting=subprocess.Popen(command('zed','wait'),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,bufsize=0)
            try:
                pid=json.loads(line(waiting))['pid']
                waiting.send_signal(signal.SIGTERM)
                assert waiting.wait(timeout=3)==143
                try:os.kill(pid,0)
                except ProcessLookupError:pass
                else:raise AssertionError('agent remains after wrapper termination')
                results.append('directed-termination-reaches-agent-process-group')
            finally:
                if waiting.poll() is None:waiting.kill();waiting.wait(timeout=2)
                for stream in [waiting.stdin,waiting.stdout,waiting.stderr]:stream.close()
            original={'type':'custom','command':'agent','args':['--flag','quoted value'],'env':{'TOKEN':'fixture-only'}}
            settings=subprocess.run([str(binary),'acp-config','--host','zed','--source','fixture'],input=json.dumps(original).encode(),capture_output=True,env=env,timeout=2)
            assert settings.returncode==0 and settings.stderr==b''
            wrapped=json.loads(settings.stdout)
            assert wrapped['env']==original['env'] and wrapped['args'][-3:]==['agent','--flag','quoted value']
            restored=subprocess.run([str(binary),'acp-config','--unwrap','--host','zed','--source','fixture'],input=settings.stdout,capture_output=True,env=env,timeout=2)
            assert restored.returncode==0 and json.loads(restored.stdout)==original
            results.append('configuration-entry-wrap-unwrap-without-file-mutation')
            missing=subprocess.run([str(binary),'acp','--host','zed','--source','fixture','--',str(root/'absent')],capture_output=True,env=env,timeout=2)
            assert missing.returncode!=0 and missing.stdout==b''
            results.append('startup-failure-never-corrupts-protocol-stdout')
        finally:
            stop.set();server.close();worker.join(timeout=2)
    return results

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',type=Path,default=Path(__file__).resolve().parents[1]/'.build/debug/DIBridge')
    parser.add_argument('--report',type=Path)
    args=parser.parse_args();binary=args.binary.resolve(strict=True)
    passed=verify(binary)
    result={'checkedAt':datetime.now(timezone.utc).isoformat(),'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),'passed':passed,'count':len(passed),'scope':'Compiled transparent proxy, offline ACP agent, temporary Unix socket; not editor/vendor acceptance.','realClientVerified':False}
    if args.report:args.report.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(f'ACP proxy: {len(passed)} scenarios passed')
