import os,pathlib,subprocess,json
root=pathlib.Path.cwd();home=root/'.test-hold-validation/cli/home';state=home/'state'
env=os.environ.copy()
for k in ['TASKS_AXI_FILE','TASKS_AXI_BACKEND','FM_TASK_ID']:env.pop(k,None)
env.update(FM_HOME=str(home),FM_STATE_OVERRIDE=str(state),FM_ROOT_OVERRIDE=str(root),FM_GATE_REFUSE_BYPASS='1',FM_LEASE_HOLDER_PID=str(os.getpid()),PI_CODING_AGENT='true',FM_SEND_SETTLE='0',PATH=str(home.parent/'fakebin')+':'+env['PATH'])
(state/'.lock').write_text(str(os.getpid())+'\n');(state/'t2.meta').write_text('window=sess:fm-t2\nkind=ship\nharness=pi\nbackend=tmux\nproject=/synthetic/two\n')
def run(script,*args,actor='main',want=0):
 p=subprocess.run([str(root/'bin'/script),*args],env=dict(env,FM_SUPERVISION_ACTOR=actor),capture_output=True,text=True,timeout=60)
 print(json.dumps({'command':script+' '+' '.join(args),'actor':actor,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr}),flush=True)
 assert p.returncode==want
run('fm-lease.sh','claim','t2')
run('fm-send.sh','t2','Blocked by main lease',actor='branch',want=6)
assert not (state/'t2.inbox/001.msg').exists()
run('fm-lease.sh','release','t2')
run('fm-send.sh','t2','Independent unheld task continuation',actor='branch')
print('Nonheld task inbox: '+(state/'t2.inbox/001.msg').read_text(),flush=True)
(state/'.wake-queue').write_text('1\t2\tsignal\tt2.turn-ended\tsignal: t2.turn-ended\n')
run('fm-wake-grant.sh','activate',str(os.getpid()),'new-generation')
run('fm-wake-grant.sh','publish','old-generation','--tasks','t2','--rows','2',want=1)
assert not (state/'.branch-eligible-rows').exists()
run('fm-wake-grant.sh','publish','new-generation','--tasks','t2','--rows','2')
run('fm-wake-grant.sh','release','old-generation',want=1)
assert (state/'.branch-eligible-rows').read_text()=='2\n'
print('Obsolete generation cannot publish or remove current rows; current generation retains row 2.',flush=True)
run('fm-wake-grant.sh','deactivate',str(os.getpid()),'new-generation')
