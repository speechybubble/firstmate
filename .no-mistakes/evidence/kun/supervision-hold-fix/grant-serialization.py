import os,pathlib,subprocess,time,json
r=pathlib.Path.cwd();h=r/'.hold-validation-tmp/grant-serialization'
for d in ['state','data','config']: (h/d).mkdir(parents=True,exist_ok=True)
(h/'.tasks.toml').write_bytes((r/'.tasks.toml').read_bytes());(h/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n');(h/'state/.lock').write_text(str(os.getpid())+'\n');(h/'state/.wake-queue').write_text('1\t1\tsignal\tt1.turn-ended\tsignal: t1.turn-ended\n1\t2\tsignal\tt2.turn-ended\tsignal: t2.turn-ended\n')
env={'PATH':'/home/denni/kun-validation/firstmate-hold-tools/node-v24.14.0-linux-x64/bin:'+os.environ['PATH'],'HOME':str(h),'FM_HOME':str(h),'FM_ROOT_OVERRIDE':str(r),'FM_GATE_REFUSE_BYPASS':'1','TMPDIR':str(r/'.hold-validation-tmp')}
def proc(name,*args): return subprocess.Popen([str(r/'bin'/name),*args],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
def done(p):
 out,err=p.communicate(timeout=45);print(json.dumps({'command':p.args,'exit':p.returncode,'stdout':out,'stderr':err}),flush=True);assert p.returncode==0
p=proc('fm-wake-grant.sh','activate',str(os.getpid()),'serialization');done(p)
blocker=subprocess.Popen(['bash','-c','. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"; touch "$FM_HOME/queue-locked"; read -r release; fm_lock_release "$FM_WAKE_QUEUE_LOCK"','bash',str(r)],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
def waitfor(p):
 for _ in range(2000):
  if p(): return
  time.sleep(.01)
 raise Exception('timed out')
try:
 waitfor(lambda:(h/'queue-locked').exists())
 grant=proc('fm-wake-grant.sh','publish','serialization','--tasks','t1','t2','--rows','1','2')
 waitfor(lambda:all((h/f'state/.control-{t}.lock').exists() for t in ['t1','t2']))
 hold=proc('fm-captain-hold.sh','hold','t1','--title','Synthetic task','--reason','Hold while publication waits')
 time.sleep(.5);assert hold.poll() is None and grant.poll() is None
 assert not (h/'state/.branch-eligible-rows').exists()
 print('While queue lock is held: publisher owns both task-control locks; no grant is visible; concurrent hold cannot finish.',flush=True)
 blocker.stdin.write('release\n');blocker.stdin.flush()
 done(grant);done(hold)
 print('Published grant:',(h/'state/.branch-eligible-rows').read_text(),flush=True)
 p=proc('fm-captain-hold.sh','open','t1');done(p)
 assert all(not (h/f'state/.control-{t}.lock').exists() for t in ['t1','t2'])
 print('Grant published before the concurrent hold; hold is durable; both task locks were released.',flush=True)
finally:
 if blocker.poll() is None: blocker.stdin.close();blocker.wait(timeout=10)
