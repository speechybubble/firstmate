import {mkdirSync,writeFileSync,readFileSync,existsSync,cpSync,symlinkSync,rmSync,chmodSync} from 'node:fs';
import {execFileSync,spawnSync} from 'node:child_process';
const root=process.cwd(), home=process.env.FM_HOME, pkg='/home/denni/.local/lib/node_modules/@earendil-works/pi-coding-agent';
for(const d of ['state','data','config','agent','sessions','extensions/lib','node_modules/@earendil-works','fakebin']) mkdirSync(`${home}/${d}`,{recursive:true});
cpSync(`${root}/.tasks.toml`,`${home}/.tasks.toml`);
cpSync(`${root}/.pi/extensions/lib`,`${home}/extensions/lib`,{recursive:true});
for(const n of ['fm-branch-supervision.ts','fm-primary-pi-watch.ts']) cpSync(`${root}/.pi/extensions/${n}`,`${home}/extensions/${n}`);
for(const [n,p] of [['@earendil-works/pi-coding-agent',pkg],['@earendil-works/pi-ai',`${pkg}/node_modules/@earendil-works/pi-ai`],['@earendil-works/pi-tui',`${pkg}/node_modules/@earendil-works/pi-tui`],['typebox',`${pkg}/node_modules/typebox`]]) symlinkSync(p,`${home}/node_modules/${n}`);
writeFileSync(`${home}/data/backlog.md`,'## In flight\n\n## Queued\n\n## Done\n');
writeFileSync(`${home}/state/.lock`,`${process.pid}\n`);
writeFileSync(`${home}/decision.txt`,'Resume the synthetic task.\n');
for(const task of ['task-a','task-b']) writeFileSync(`${home}/state/${task}.meta`,`project=/synthetic/${task}\nwindow=fm-${task}\nkind=ship\nharness=pi\n`);
const run=(name,...args)=> {const r=spawnSync(`${root}/bin/${name}`,args,{encoding:'utf8'}); console.log(JSON.stringify({command:name,args,exit:r.status,out:r.stdout,err:r.stderr}));if(r.status!==0)throw Error(`CLI failed: ${name}`);return r;};
const check=(x,m)=>{if(!x)throw Error(m);};
const wait=async(p,label)=>{for(let i=0;i<1000;i++){if(p())return;await new Promise(r=>setTimeout(r,20));}throw Error(`timeout ${label}`);};
globalThis.fetch=()=>{throw Error('Network prohibited in this probe');};
const {DefaultResourceLoader,SettingsManager,SessionManager,createAgentSession}=await import(`${pkg}/dist/index.js`);
const {createBranchDispatchOffer,scopeForUnreadWakeWithHolds,isNeedsDecisionTrigger}=await import(`${root}/.pi/extensions/lib/fm-branch-dispatch.ts`);
let api;const offers=[],inputs=[];
const settings=SettingsManager.create(home,`${home}/agent`);
const loader=new DefaultResourceLoader({cwd:home,agentDir:`${home}/agent`,settingsManager:settings,noExtensions:true,noSkills:true,noPromptTemplates:true,noThemes:true,noContextFiles:true,extensionFactories:[
{name:'branch',factory:(await import(`${home}/extensions/fm-branch-supervision.ts`)).default},

{name:'observe',factory:p=>{api=p;p.events.on('fm-branch-supervision:dispatch',o=>{offers.push(o);console.log('DISPATCH',JSON.stringify({message:o.message,eligible:o.eligible,accepted:o.accepted}));});p.on('input',e=>{inputs.push(e.text);console.log('MAIN INPUT',e.text);return {action:'handled'};});}}
]});
await loader.reload(); console.log("LOADER ERRORS",JSON.stringify(loader.getExtensions().errors));
const {session}=await createAgentSession({cwd:home,agentDir:`${home}/agent`,sessionManager:SessionManager.create(home,`${home}/sessions`),settingsManager:settings,resourceLoader:loader,noTools:"builtin"});
await session.bindExtensions({onError:e=>console.log('EXTENSION ERROR',e)});
const queue=(kind)=>{const key=kind==='signal'?'task-a.turn-ended':'fm-task-a';const q=`1\t1\t${kind}\t${key}\t${kind}: ${key}\n1\t2\tsignal\ttask-b.turn-ended\tsignal: task-b.turn-ended\n`;writeFileSync(`${home}/state/.wake-queue`,q);return {message:`${kind}: ${key}`,q};};
try{
run('fm-captain-hold.sh','hold','task-a','--title','Synthetic A','--reason','Intentional stop without status');
for(const kind of ['signal','stale']){
 const {message}=queue(kind);const scope=await scopeForUnreadWakeWithHolds(`${home}/state`,false,root,home);
 console.log('HELD MIXED SCOPE',JSON.stringify(scope));check(scope.eligibleSeqs.join(',')==='2'&&isNeedsDecisionTrigger(message,scope),'held trigger routing');
}
run('fm-captain-hold.sh','answer','task-a','--release','--decision-file',`${home}/decision.txt`);
// Synchronous event listener places a real durable hold after actual branch acceptance.
let late=false;
api.events.on('fm-branch-supervision:dispatch',o=>{if(late&&o.accepted){late=false;run('fm-captain-hold.sh','hold','task-a','--reason','After acceptance');}});
for(const kind of ['signal','stale']){
 const {message,q}=queue(kind);const scope=await scopeForUnreadWakeWithHolds(`${home}/state`,false,root,home);late=true;
 const o=createBranchDispatchOffer(message,scope.projects,false,true);api.events.emit('fm-branch-supervision:dispatch',o);check(o.accepted,'offer not accepted');
 const err=await o.settlement.then(()=>null,e=>e);console.log('POST ACCEPTANCE REJECTION',kind,String(err));
 check(err?.message.includes('captain decision'),'wrong rejection');check(readFileSync(`${home}/state/.wake-queue`,'utf8')===q,'queue consumed');
 check(!existsSync(`${home}/state/.branch-eligible-rows`),'grant leaked');
 run('fm-captain-hold.sh','answer','task-a','--release','--decision-file',`${home}/decision.txt`);
}
// Delay B's real read until A has returned unheld, then use the real hold command.
writeFileSync(`${home}/fakebin/bash`,`#!/bin/bash\nif [[ \${1:-} = */fm-captain-hold.sh && \${2:-} = open && -e "$FM_HOME/race" ]]; then\n if [ "$3" = task-a ]; then /bin/bash "$@"; rc=$?; touch "$FM_HOME/a-read"; exit "$rc"; fi\n if [ "$3" = task-b ]; then while [ ! -e "$FM_HOME/a-read" ]; do /bin/sleep 0.01; done; rm "$FM_HOME/race"; /bin/bash "$FM_ROOT_OVERRIDE/bin/fm-captain-hold.sh" hold task-a --reason 'During B asynchronous read' >/dev/null || exit 2; fi\nfi\nexec /bin/bash "$@"\n`);chmodSync(`${home}/fakebin/bash`,0o755);process.env.PATH=`${home}/fakebin:${process.env.PATH}`;
for(const kind of ['signal','stale']){
 const {message,q}=queue(kind);const scope=await scopeForUnreadWakeWithHolds(`${home}/state`,false,root,home);writeFileSync(`${home}/race`,'');
 const o=createBranchDispatchOffer(message,scope.projects,false,true);api.events.emit('fm-branch-supervision:dispatch',o);check(o.accepted,'race offer not accepted');
 const err=await o.settlement.then(()=>null,e=>e);console.log('ASYNC TWO TASK REJECTION',kind,String(err));
 check(err?.message.includes('eligible row snapshot'),'final locked grant did not reject');check(existsSync(`${home}/a-read`)&&!existsSync(`${home}/race`),'race ordering missing');
 check(readFileSync(`${home}/state/.wake-queue`,'utf8')===q,'race consumed unread rows');check(!existsSync(`${home}/state/.branch-eligible-rows`),'race grant leaked');
 run('fm-wake-drain.sh');run('fm-captain-hold.sh','answer','task-a','--release','--decision-file',`${home}/decision.txt`);rmSync(`${home}/a-read`);
}
console.log('REAL PI SDK HOLD SCENARIOS PASSED');
} finally {await session.dispose();}
process.exit(0);
