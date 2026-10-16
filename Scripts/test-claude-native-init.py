#!/usr/bin/env python3
"""Native Claude init-only fixture; never starts a model conversation."""
import os,json,pathlib,tempfile,subprocess,socket,threading,shlex,hashlib
import argparse
from datetime import datetime, timezone
repo=pathlib.Path(__file__).resolve().parents[1];bridge=repo/'.build/X Island.app/Contents/MacOS/di-bridge'
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--report', type=pathlib.Path)
arguments=parser.parse_args()
checked_at=datetime.now(timezone.utc)
report_path=arguments.report or repo/f'docs/compatibility/verification/{checked_at.date().isoformat()}-claude-native-lifecycle.json'
import shutil
claude=shutil.which('claude')
assert claude, 'Claude CLI not found'
version=subprocess.run([claude,'--version'],capture_output=True,text=True,timeout=10)
assert version.returncode==0 and version.stdout.strip()=='2.1.234 (Claude Code)', 'This native fixture is pinned to Claude Code 2.1.234'
with tempfile.TemporaryDirectory(prefix='xi-claude-',dir='/tmp') as d:
 root=pathlib.Path(d);(root/'config').mkdir();(root/'project').mkdir()
 hook=root/'hook.py'
 hook.write_text('''import sys,json,subprocess,pathlib
raw=sys.stdin.buffer.read()
pathlib.Path(sys.argv[2],sys.argv[3]+'-native.json').write_bytes(raw)
p=subprocess.run([sys.argv[1],'--agent','claude_code','--hook',sys.argv[3]],input=raw,capture_output=True,timeout=5)
pathlib.Path(sys.argv[2],sys.argv[3]+'-bridge.json').write_text(json.dumps({'code':p.returncode,'stdout':p.stdout.decode(),'stderr':p.stderr.decode()}))
sys.stdout.buffer.write(p.stdout);sys.exit(p.returncode)
''')
 hooks={}
 for event in ['SessionStart','SessionEnd']:
  command=shlex.join(['/opt/homebrew/bin/python3.12',str(hook),str(bridge),str(root),event])
  entry={'hooks':[{'type':'command','command':command,'timeout':5}]}
  if event=='SessionStart':entry['matcher']='startup'
  hooks[event]=[entry]
 settings=root/'settings.json';settings.write_text(json.dumps({'hooks':hooks}))
 server=socket.socket(socket.AF_UNIX);server.bind(str(root/'di.sock'));server.listen(4);server.settimeout(.2)
 messages=[];errors=[];stop=threading.Event()
 def receive():
  while not stop.is_set():
   try:c,_=server.accept()
   except socket.timeout:continue
   with c:
    c.settimeout(2)
    try:
     with c.makefile('rb') as f:messages.append(json.loads(f.readline()))
    except Exception as error: errors.append(str(error))
 thread=threading.Thread(target=receive,daemon=True);thread.start()
 env=dict(os.environ)
 for key in list(env):
  if any(x in key.upper() for x in ['API_KEY','AUTH_TOKEN','ACCESS_TOKEN']) or key in ['CLAUDECODE','DI_SESSION_ID']:env.pop(key,None)
 env.update(CLAUDE_CONFIG_DIR=str(root/'config'),DISABLE_TELEMETRY='1',DISABLE_ERROR_REPORTING='1',DISABLE_AUTOUPDATER='1',X_ISLAND_TEST_MODE='1',X_ISLAND_TEST_RUNTIME_DIR=d,DI_SOCKET_PATH=str(root/'di.sock'))
 try:
  result=subprocess.run([claude,'--init-only','--settings',str(settings),'--setting-sources','','--strict-mcp-config','--mcp-config','{"mcpServers":{}}'],cwd=root/'project',env=env,capture_output=True,timeout=40)
 finally:stop.set();thread.join(2);server.close()
 native={event:json.loads((root/(event+'-native.json')).read_text()) for event in hooks if (root/(event+'-native.json')).exists()}
 outcomes={event:json.loads((root/(event+'-bridge.json')).read_text()) for event in hooks if (root/(event+'-bridge.json')).exists()}
 session=native.get('SessionStart',{}).get('session_id')
 matched=bool(messages) and bool(session) and all(m.get('sessionId')=='claude_code-'+session for m in messages)
 report={'checkedAt':checked_at.isoformat(),'clientVersion':'2.1.234','mode':'--init-only','clientExit':result.returncode,'stdoutBytes':len(result.stdout),'stderrBytes':len(result.stderr),
         'nativeEvents':{k:{'fields':sorted(v),'event':v.get('hook_event_name'),'reason':v.get('reason')} for k,v in native.items()},
         'bridgeResults':outcomes,'socketMessageTypes':[m.get('type') for m in messages],'socketErrors':errors,'sessionIdentityMatches':matched,
         'modelConversationStarted':False,'scope':'Native init-only lifecycle; no tool/approval acceptance','complete':False,'bridgeSHA256':hashlib.sha256(bridge.read_bytes()).hexdigest()}
 report_path.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
 print(json.dumps(report,ensure_ascii=False,indent=2))
 assert result.returncode==0 and not result.stdout and not result.stderr, 'Native init failed'
 assert not errors and matched and native.get('SessionStart',{}).get('hook_event_name')=='SessionStart'
 assert messages[0]['type']=='session_start' and all(v['code']==0 and not v['stderr'] for v in outcomes.values())
 assert set(native)=={'SessionStart','SessionEnd'} and set(outcomes)==set(native), 'Missing lifecycle hook'
 assert native['SessionEnd']['session_id']==session
 assert [m['type'] for m in messages]==['session_start','session_end']
