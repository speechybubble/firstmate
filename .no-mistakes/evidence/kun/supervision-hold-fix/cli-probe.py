import os, pathlib, subprocess, json, time
root=pathlib.Path.cwd(); lab=root/'.test-hold-validation/cli'; home=lab/'home'; state=home/'state'; fb=lab/'fakebin'
for p in [state,home/'data',home/'config',fb]: p.mkdir(parents=True,exist_ok=True)
(home/'.tasks.toml').write_bytes((root/'.tasks.toml').read_bytes()); (home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
(state/'t1.meta').write_text('window=sess:fm-t1\nkind=ship\nharness=pi\nbackend=tmux\nproject=/synthetic/project\n')
(state/'.lock').write_text(str(os.getpid())+'\n')
(fb/'tmux').write_text('''#!/bin/bash
printf '%s\\n' "$*" >> "$FM_HOME/transport.log"
case "$1" in
 capture-pane) printf '╭────╮\\n│    │\\n╰────╯\\n';;
 display-message) printf 'fakepane\\n';;
 list-windows) printf 'fm-t1\\n';;
 send-keys)
  if [ -e "$FM_HOME/pause-send" ]; then
    touch "$FM_HOME/send-entered"
    while [ -e "$FM_HOME/pause-send" ]; do /bin/sleep 0.02; done
  fi;;
esac
exit 0
'''); (fb/'tmux').chmod(0o755)
env=os.environ.copy()
for k in ['TASKS_AXI_FILE','TASKS_AXI_BACKEND','FM_TASK_ID','FM_STATE_OVERRIDE','FM_SUPERVISION_ACTOR']: env.pop(k,None)
env.update(FM_HOME=str(home),FM_STATE_OVERRIDE=str(state),FM_ROOT_OVERRIDE=str(root),FM_GATE_REFUSE_BYPASS='1',FM_LEASE_HOLDER_PID=str(os.getpid()),PI_CODING_AGENT='true',FM_SEND_SETTLE='0',PATH=str(fb)+':'+env['PATH'])
def run(script,*args,actor='main',want=0):
 e=dict(env,FM_SUPERVISION_ACTOR=actor)
 p=subprocess.run([str(root/'bin'/script),*args],env=e,capture_output=True,text=True,timeout=60)
 print(json.dumps({'command':script+' '+' '.join(args),'actor':actor,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr}),flush=True)
 assert p.returncode==want,(script,p.returncode,want)
 return p
run('fm-lease.sh','claim','t1')
run('fm-captain-hold.sh','hold','t1','--title','Synthetic worker','--reason','Intentional stop')
run('fm-lease.sh','release','t1')
run('fm-lease.sh','claim','t1',actor='branch')
assert not (state/'t1.status').exists()
run('fm-send.sh','t1','Continue the bounded task',actor='branch',want=6)
run('fm-control.sh','t1','relaunch',actor='branch',want=6)
assert not (state/'t1.inbox/001.msg').exists()
assert not (home/'transport.log').exists()
print('Held task after main lease release: no status file, no inbox, no terminal calls.',flush=True)
run('fm-lease.sh','release','t1',actor='branch')
run('fm-send.sh','t1','--key','Escape')
print('Main stop transport: '+(home/'transport.log').read_text(),flush=True)
(home/'decision.txt').write_text('Resume the same bounded synthetic task.\n')
run('fm-captain-hold.sh','answer','t1','--release','--decision-file',str(home/'decision.txt'))
run('fm-send.sh','t1','Authorized continuation',actor='branch')
print('Released inbox record:\n'+(state/'t1.inbox/001.msg').read_text(),flush=True)
(state/'.wake-queue').write_text('1\t1\tsignal\tt1.turn-ended\tsignal: t1.turn-ended\n')
run('fm-wake-grant.sh','activate',str(os.getpid()),'live-probe')
run('fm-wake-grant.sh','publish','live-probe','--tasks','t1','--rows','1')
run('fm-captain-hold.sh','hold','t1','--reason','Stop after an eligible grant')
run('fm-send.sh','t1','Continuation using the old grant',actor='branch',want=6)
assert not (state/'t1.inbox/002.msg').exists()
print('Post-grant hold: grant row remains '+(state/'.branch-eligible-rows').read_text().strip()+'; no second inbox record.',flush=True)
(home/'data/backlog.md').chmod(0)
try:
 run('fm-send.sh','t1','Unknown is not authorization',actor='branch',want=6)
 run('fm-wake-grant.sh','publish','live-probe','--tasks','t1','--rows','1',want=1)
finally: (home/'data/backlog.md').chmod(0o600)
assert not (state/'t1.inbox/002.msg').exists()
run('fm-captain-hold.sh','answer','t1','--release','--decision-file',str(home/'decision.txt'))
# The send's real terminal transport pauses while the real hold command competes.
(home/'pause-send').touch()
send=subprocess.Popen([str(root/'bin/fm-send.sh'),'t1','Send begun before the hold'],env=dict(env,FM_SUPERVISION_ACTOR='branch'),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
for _ in range(1500):
 if (home/'send-entered').exists(): break
 time.sleep(.02)
assert (home/'send-entered').exists(),'send did not enter transport'
hold=subprocess.Popen([str(root/'bin/fm-captain-hold.sh'),'hold','t1','--reason','Concurrent stop'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
time.sleep(.3)
assert hold.poll() is None,'hold overtook in-progress delivery'
print('While terminal delivery is paused: hold process remains waiting; task-control lock exists='+str((state/'.control-t1.lock').exists()),flush=True)
(home/'pause-send').unlink()
so,se=send.communicate(timeout=60); ho,he=hold.communicate(timeout=60)
print(json.dumps({'serialized_send':{'exit':send.returncode,'stdout':so,'stderr':se},'serialized_hold':{'exit':hold.returncode,'stdout':ho,'stderr':he}}),flush=True)
assert send.returncode==0 and hold.returncode==0
run('fm-captain-hold.sh','open','t1')
run('fm-send.sh','t1','Continuation after the concurrent hold',actor='branch',want=6)
assert not (state/'t1.inbox/003.msg').exists()
print('Serialization: prior delivery completed, durable hold followed, subsequent continuation refused without a third inbox record.',flush=True)
