import {mkdirSync,writeFileSync,readFileSync,existsSync,copyFileSync,rmSync} from 'node:fs';
import {spawn,spawnSync} from 'node:child_process';
const root=process.cwd(),lab=root+'/.test-hold-validation';
const current=await import(root+'/.pi/extensions/lib/fm-branch-dispatch.ts');
const prior=await import(lab+'/prior/lib/fm-branch-dispatch.ts');
for(const mode of ['prior','current']){
 const home=lab+'/grant-'+mode,state=home+'/state';
 for(const dir of [state,home+'/data',home+'/config'])mkdirSync(dir,{recursive:true});
 copyFileSync(root+'/.tasks.toml',home+'/.tasks.toml');writeFileSync(home+'/data/backlog.md','## In flight\n\n## Queued\n\n## Done\n');
 Object.assign(process.env,{FM_HOME:home,FM_STATE_OVERRIDE:state,FM_ROOT_OVERRIDE:root,FM_GATE_REFUSE_BYPASS:'1'});
 delete process.env.TASKS_AXI_FILE;delete process.env.TASKS_AXI_BACKEND;
 const run=(script,...args)=>{const p=spawnSync('/bin/bash',[root+'/bin/'+script,...args],{encoding:'utf8'});if(p.status!==0)throw Error(p.stderr);return p.stdout;};
 for(const task of ['a','b'])writeFileSync(state+'/'+task+'.meta',`window=fm-${task}\nproject=/synthetic/${task}\n`);
 const queue='1\t1\tsignal\ta.turn-ended\tsignal: a.turn-ended\n1\t2\tsignal\tb.turn-ended\tsignal: b.turn-ended\n';writeFileSync(state+'/.wake-queue',queue);writeFileSync(state+'/.lock',process.pid+'\n');
 const lib=mode==='prior'?prior:current;
 run('fm-wake-grant.sh','activate',String(process.pid),mode);
 writeFileSync(home+'/race-armed','');
 const scope=await lib.scopeForUnreadWakeWithHolds(state,false,root,home);
 if(scope.eligibleSeqs.length!==2||!existsSync(home+'/first-read')||existsSync(home+'/race-armed'))throw Error('did not exercise stale reads');
 run('fm-captain-hold.sh','open','a');
 const result=await lib.writeEligibleRowsSnapshot(state,scope.eligibleSeqs,mode==='prior'?lab+'/prior/bin/fm-wake-grant.sh':root+'/bin/fm-wake-grant.sh',mode,scope.eligibleTasks);
 console.log(JSON.stringify({mode,staleScope:scope.eligibleSeqs,holdDurable:true,grantResult:result,publishedRows:existsSync(state+'/.branch-eligible-rows')?readFileSync(state+'/.branch-eligible-rows','utf8'):null,queueUnchanged:readFileSync(state+'/.wake-queue','utf8')===queue}));
 if(result!==(mode==='prior'?'published':'error'))throw Error('unexpected counterfactual');
 if(mode==='current'){
  writeFileSync(home+'/decision.txt','Resume synthetic task.\n');run('fm-captain-hold.sh','answer','a','--release','--decision-file',home+'/decision.txt');
  const completed=p=>new Promise((resolve,reject)=>{p.on('error',reject);p.on('close',resolve);});
  const waitFor=async test=>{for(let i=0;i<1000;i++){if(test())return;await new Promise(r=>setTimeout(r,20));}throw Error('condition timeout');};
  const blocker=spawn('/bin/bash',['-c','. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"; touch "$FM_HOME/queue-locked"; read -r release; fm_lock_release "$FM_WAKE_QUEUE_LOCK"','bash',root]);const blockerDone=completed(blocker);
  await waitFor(()=>existsSync(home+'/queue-locked'));
  const grant=lib.writeEligibleRowsSnapshot(state,['1','2'],root+'/bin/fm-wake-grant.sh',mode,['a','b']);
  await waitFor(()=>['a','b'].every(t=>existsSync(state+'/.control-'+t+'.lock')));
  const hold=spawn('/bin/bash',[root+'/bin/fm-captain-hold.sh','hold','a','--reason','Competing with final publication']);const holdDone=completed(hold);
  await new Promise(r=>setTimeout(r,300));
  if(hold.exitCode!==null||existsSync(state+'/.branch-eligible-rows'))throw Error('publication serialization broken');
  console.log(JSON.stringify({serialization:'queue locked; both task locks retained; concurrent hold waiting; no published rows'}));
  blocker.stdin.end('release\n');
  const results=await Promise.all([blockerDone,grant,holdDone]);
  run('fm-captain-hold.sh','open','a');
  console.log(JSON.stringify({serializationResults:results,publishedRows:readFileSync(state+'/.branch-eligible-rows','utf8'),holdDurable:true,taskLocksReleased:['a','b'].every(t=>!existsSync(state+'/.control-'+t+'.lock'))}));
  if(JSON.stringify(results)!=='[0,"published",0]')throw Error('serialization failed');
 }
}
