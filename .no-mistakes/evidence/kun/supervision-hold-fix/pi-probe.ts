import {writeFileSync, readFileSync, existsSync, mkdirSync, chmodSync, rmSync} from 'node:fs';
import {execFileSync, spawnSync} from 'node:child_process';
import {createBranchDispatchOffer, scopeForUnreadWakeWithHolds, isNeedsDecisionTrigger} from '../.pi/extensions/lib/fm-branch-dispatch.ts';
export default function(pi:any){
 const home=process.env.FM_HOME!, root=process.env.FM_ROOT_OVERRIDE!, state=home+'/state';
 const log=(value:any)=>{console.log('HOLD_PROBE '+JSON.stringify(value));};
 const run=(script:string,...args:string[])=>execFileSync('/bin/bash',[root+'/bin/'+script,...args],{encoding:'utf8'});
 pi.on('session_start',()=>{writeFileSync(state+'/.lock',process.pid+'\n');log({ready:true,pid:process.pid});});
 pi.registerCommand('hold-validation',{description:'Synthetic hold validation without model calls',handler:async(_args:any,ctx:any)=>{
 try {
  writeFileSync(home+'/decision.txt','Resume this synthetic task.\n');
  for(const task of ['a','b']) writeFileSync(state+'/'+task+'.meta',`window=fm-${task}\nproject=/synthetic/${task}\n`);
  let seq=0;
  for(const mode of ['post-acceptance','async-two-task']) for(const kind of ['signal','stale']){
   const key=kind==='signal'?'a.turn-ended':'fm-a'; const message=kind+': '+key;
   const first=++seq,last=++seq;
   const queue=`1\t${first}\t${kind}\t${key}\t${message}\n1\t${last}\tsignal\tb.turn-ended\tsignal: b.turn-ended\n`;
   writeFileSync(state+'/.wake-queue',queue);
   const scope=await scopeForUnreadWakeWithHolds(state,false,root,home);
   if(scope.eligibleSeqs.length!==2)throw Error('initial scope not eligible');
   if(mode==='async-two-task')writeFileSync(home+'/race-armed','');
   const offer=createBranchDispatchOffer(message,scope.projects,false,true);
   pi.events.emit('fm-branch-supervision:dispatch',offer);
   if(!offer.accepted)throw Error('wake was not accepted');
   const settled=offer.settlement.then(()=>null,(err:any)=>String(err));
   if(mode==='post-acceptance')run('fm-captain-hold.sh','hold','a','--title','Synthetic A','--reason','Hold after acceptance');
   const failure=await settled;
   if(!failure || !/captain decision|eligible row snapshot/.test(failure))throw Error('unexpected settlement: '+failure);
   if(mode==='async-two-task'&&(!existsSync(home+'/first-read')||existsSync(home+'/race-armed')))throw Error('race not driven');
   if(readFileSync(state+'/.wake-queue','utf8')!==queue||existsSync(state+'/.branch-eligible-rows'))throw Error('lost queue or retained grant');
   const drain=spawnSync('/bin/bash',[root+'/bin/fm-wake-drain.sh'],{encoding:'utf8'});
   if(drain.status!==0||!drain.stdout.includes(key)||!drain.stdout.includes('b.turn-ended'))throw Error('main drain lost rows');
   log({mode,kind,accepted:offer.accepted,rejection:failure,statusFileExists:existsSync(state+'/a.status'),queuePreserved:true,mainDrain:drain.stdout,ack:drain.stderr});
   const generation=drain.stderr.match(/--recovery-generation (\S+)/)?.[1];
   if(!generation)throw Error('missing ack generation');
   run('fm-wake-drain.sh','--ack-through',String(last),'--recovery-generation',generation);
   run('fm-captain-hold.sh','answer','a','--release','--decision-file',home+'/decision.txt');
   rmSync(home+'/first-read',{force:true});
  }
  run('fm-captain-hold.sh','hold','a','--reason','Backlog-only routing');
  writeFileSync(state+'/.wake-queue',`1\t${++seq}\tsignal\ta.turn-ended\tsignal: a.turn-ended\n1\t${++seq}\tstale\tfm-a\tstale: fm-a\n1\t${++seq}\tsignal\tb.turn-ended\tsignal: b.turn-ended\n`);
  const scope=await scopeForUnreadWakeWithHolds(state,false,root,home);
  if(scope.eligibleSeqs.length!==1||!isNeedsDecisionTrigger('signal: a.turn-ended',scope)||!isNeedsDecisionTrigger('stale: fm-a',scope))throw Error('routing failed');
  log({backlogOnlyRouting:scope});
  chmodSync(home+'/data/backlog.md',0);
  try{const unknown=await scopeForUnreadWakeWithHolds(state,false,root,home);if(!unknown.corrupted||unknown.eligible)throw Error('unknown authority eligible');log({unreadableHold:unknown});}finally{chmodSync(home+'/data/backlog.md',0o600);}
  run('fm-captain-hold.sh','answer','a','--release','--decision-file',home+'/decision.txt');
  const released=await scopeForUnreadWakeWithHolds(state,false,root,home); if(released.eligibleSeqs.length!==3)throw Error('release failed');log({releasedRouting:released});
  writeFileSync(home+'/result.json',JSON.stringify({pass:true}));
 }catch(error){log({failure:String(error),stack:(error as Error).stack});writeFileSync(home+'/result.json',JSON.stringify({pass:false,error:String(error)}));}
 ctx.shutdown();
 }});
}
