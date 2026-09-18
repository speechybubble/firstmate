import os, pathlib, subprocess, time, json
root=pathlib.Path.cwd(); h=root/'.hold-validation-tmp/manual-cli'; h.mkdir(parents=True,exist_ok=True)
for d in ['state','config','data','fakebin','user']: (h/d).mkdir(exist_ok=True)
(h/'.tasks.toml').write_bytes((root/'.tasks.toml').read_bytes())
(h/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
(h/'state/t1.meta').write_text('window=sess:fm-t1\nkind=ship\nharness=claude\nproject=/synthetic/project\n')
(h/'state/.lock').write_text(str(os.getpid())+'\n')
(h/'decision.txt').write_text('Resume the same bounded synthetic task.\n')
(h/'fakebin/tmux').write_text('''#!/bin/bash
printf '%s\\n' "$*" >> "$FM_HOME/transport.log"
case "$1" in
 send-keys) if [ -f "$FM_HOME/block-send" ]; then touch "$FM_HOME/send-entered"; while [ -f "$FM_HOME/block-send" ]; do /bin/sleep 0.02; done; fi ;;
 display-message) printf '1\\n' ;;
 capture-pane) printf '╭────╮\\n│    │\\n╰────╯\\n' ;;
 list-windows) printf 'fm-t1\\n' ;;
esac
exit 0
'''); (h/'fakebin/tmux').chmod(0o755)
env={'PATH':str(h/'fakebin')+':/home/denni/kun-validation/firstmate-hold-tools/node-v24.14.0-linux-x64/bin:'+os.environ['PATH'],'HOME':str(h/'user'),'FM_HOME':str(h),'FM_ROOT_OVERRIDE':str(root),'FM_GATE_REFUSE_BYPASS':'1','PI_CODING_AGENT':'true','FM_LEASE_HOLDER_PID':str(os.getpid()),'TMPDIR':str(root/'.hold-validation-tmp')}
def run(script,*args,actor='main',want=0):
 p=subprocess.run([str(root/'bin'/script),*args],env={**env,'FM_SUPERVISION_ACTOR':actor},text=True,capture_output=True,timeout=45)
 print(json.dumps({'command':script+' '+' '.join(args),'actor':actor,'exit':p.returncode,'stdout':p.stdout.strip(),'stderr':p.stderr.strip()}),flush=True)
 assert p.returncode==want, (p.returncode,want)
 return p
run('fm-lease.sh','claim','t1')
run('fm-send.sh','t1','Lease must block',actor='branch',want=6)
run('fm-captain-hold.sh','hold','t1','--title','Synthetic worker','--reason','Intentional stop')
run('fm-lease.sh','release','t1')
assert not (h/'state/t1.status').exists()
run('fm-lease.sh','claim','t1',actor='branch')
run('fm-send.sh','t1','Continue after main released lease',actor='branch',want=6)
run('fm-control.sh','t1','relaunch','--note','Synthetic retry',actor='branch',want=6)
assert not (h/'state/t1.inbox').exists()
run('fm-lease.sh','release','t1',actor='branch')
run('fm-send.sh','t1','--key','Escape')
run('fm-captain-hold.sh','answer','t1','--release','--decision-file',str(h/'decision.txt'))
run('fm-send.sh','t1','Authorized continuation',actor='branch')
print('DURABLE INBOX:',(h/'state/t1.inbox/001.msg').read_text(),flush=True)
(h/'state/.wake-queue').write_text('1\t1\tsignal\tt1.turn-ended\tsignal: t1.turn-ended\n')
run('fm-wake-grant.sh','activate',str(os.getpid()),'live-probe')
run('fm-wake-grant.sh','publish','live-probe','--tasks','t1','--rows','1')
run('fm-captain-hold.sh','hold','t1','--reason','Hold created after grant')
run('fm-send.sh','t1','Old grant is not authorization',actor='branch',want=6)
assert not (h/'state/t1.inbox/002.msg').exists()
(h/'data/backlog.md').chmod(0)
try:
 run('fm-send.sh','t1','Indeterminate hold',actor='branch',want=6)
 run('fm-wake-grant.sh','publish','live-probe','--tasks','t1','--rows','1',want=1)
finally: (h/'data/backlog.md').chmod(0o600)
run('fm-captain-hold.sh','answer','t1','--release','--decision-file',str(h/'decision.txt'))
# Pause only the terminal transport after production send owns the task lock.
(h/'block-send').touch()
send=subprocess.Popen([str(root/'bin/fm-send.sh'),'t1','/synthetic-command'],env={**env,'FM_SUPERVISION_ACTOR':'branch'},stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
for _ in range(1000):
 if (h/'send-entered').exists(): break
 time.sleep(.01)
assert (h/'send-entered').exists()
hold=subprocess.Popen([str(root/'bin/fm-captain-hold.sh'),'hold','t1','--reason','Concurrent stop'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
time.sleep(.2)
assert hold.poll() is None
print('SERIALIZATION: hold remains pending while branch send owns task-control lock',flush=True)
(h/'block-send').unlink()
a=send.communicate(timeout=45); b=hold.communicate(timeout=45)
print('SEND:',send.returncode,a,'HOLD:',hold.returncode,b,flush=True)
assert send.returncode==hold.returncode==0
run('fm-send.sh','t1','Must remain stopped',actor='branch',want=6)
run('fm-captain-hold.sh','open','t1')
print('FINAL BACKLOG:',(h/'data/backlog.md').read_text())
print('TRANSPORT:',(h/'transport.log').read_text())
print('LIVE CLI SCENARIOS PASSED')
