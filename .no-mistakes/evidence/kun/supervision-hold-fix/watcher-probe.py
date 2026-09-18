import os,pathlib,subprocess,json,time,select
root=pathlib.Path.cwd();lab=root/'.test-hold-validation'
for kind in ['signal']:
 home=lab/('watch-final-'+kind);state=home/'state';fb=home/'fakebin';agent=home/'agent'
 for p in [state,home/'config',home/'data',fb,agent]:p.mkdir(parents=True,exist_ok=True)
 (home/'.tasks.toml').write_bytes((root/'.tasks.toml').read_bytes());(home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
 (state/'a.meta').write_text('window=firstmate:fm-a\nkind=ship\nharness=pi\nbackend=tmux\nproject=/synthetic/a\n')
 (fb/'tmux').write_text('#!/bin/bash\ncase "$1" in\n list-windows) echo fm-a;;\n capture-pane) echo "idle prompt";;\n display-message) echo pi;;\nesac\nexit 0\n');(fb/'tmux').chmod(0o755)
 env=os.environ.copy()
 for k in list(env):
  if k.endswith('API_KEY') or k in ['TASKS_AXI_FILE','TASKS_AXI_BACKEND','FM_TASK_ID','FM_SUPERVISION_ACTOR']:env.pop(k,None)
 env.update(FM_HOME=str(home),FM_STATE_OVERRIDE=str(state),FM_ROOT_OVERRIDE=str(root),PI_CODING_AGENT_DIR=str(agent),PI_OFFLINE='1',FM_GATE_REFUSE_BYPASS='1',PROBE_KIND=kind,FM_POLL='1',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_HOME_SUMMARY_INTERVAL='999999',PATH=str(fb)+':'+str(lab/'node-v24.13.0-linux-x64/bin')+':'+env['PATH'])
 subprocess.run([str(root/'bin/fm-captain-hold.sh'),'hold','a','--title','Synthetic A','--reason','Backlog-only stop'],env=env,check=True,stdout=subprocess.DEVNULL)
 if kind=='signal':(state/'a.turn-ended').touch()
 args=['pi','--offline','--approve','--no-extensions','--no-skills','--no-prompt-templates','--no-themes','--no-context-files','--mode','rpc','--no-session','--provider','openai-codex','--model','gpt-6-astra','--thinking','high','-e',str(lab/'watcher-probe.ts'),'-e',str(root/'.pi/extensions/fm-branch-supervision.ts'),'-e',str(root/'.pi/extensions/fm-primary-pi-watch.ts')]
 p=subprocess.Popen(args,cwd=lab,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
 deadline=time.monotonic()+90
 offers=[];main_attempts=0
 try:
  while time.monotonic()<deadline and p.poll() is None:
   if select.select([p.stdout],[],[],.2)[0]:
    line=p.stdout.readline();print(line,end='',flush=True)
    if line.startswith('WATCH_PROBE {'):
     data=json.loads(line[len('WATCH_PROBE '):])
     if 'offer' in data:offers.append(data['offer'])
    if line.startswith('{'):
     data=json.loads(line)
     if data.get('event')=='send_user_message' and 'No API key found for openai-codex' in data.get('error',''):main_attempts+=1
   if main_attempts>=2 and any(o['message'].startswith('signal:') for o in offers) and any(o['message'].startswith('stale:') for o in offers):break
  assert main_attempts>=2 and len(offers)>=2,'routing evidence timeout'
  assert all(not o['eligible'] and not o['accepted'] for o in offers),offers
  assert not (state/'a.status').exists()
  print('WATCHER_RESULT '+json.dumps({'heldSignalAndStaleOfferedToBranch':False,'mainNotificationAttempts':main_attempts,'modelTurns':'not exercised: isolated Pi has no credentials','queue':(state/'.wake-queue').read_text(),'statusFileExists':False}),flush=True)
 finally:
  if p.poll() is None:p.terminate();p.wait(timeout=15)
