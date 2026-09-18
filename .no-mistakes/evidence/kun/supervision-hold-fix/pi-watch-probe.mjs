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
writeFileSync(`${home}/fakebin/tmux`,`#!/bin/bash
case "$1" in
list-windows) [ ! -e "$FM_HOME/stale-enabled" ] || printf 'fm-task-a\\n' ;;
capture-pane) printf 'Synthetic worker waiting\\n' ;;
display-message) printf '1\\n' ;;
esac
exit 0
`);chmodSync(`${home}/fakebin/tmux`,0o755);process.env.PATH=`${home}/fakebin:${process.env.PATH}`;
let api;const offers=[],inputs=[];
const settings=SettingsManager.create(home,`${home}/agent`);
const loader=new DefaultResourceLoader({cwd:home,agentDir:`${home}/agent`,settingsManager:settings,noExtensions:true,noSkills:true,noPromptTemplates:true,noThemes:true,noContextFiles:true,extensionFactories:[
{name:'watch',factory:(await import(`${home}/extensions/fm-primary-pi-watch.ts`)).default},
{name:'branch',factory:(await import(`${home}/extensions/fm-branch-supervision.ts`)).default},

{name:'observe',factory:p=>{api=p;p.events.on('fm-branch-supervision:dispatch',o=>{offers.push(o);console.log('DISPATCH',JSON.stringify({message:o.message,eligible:o.eligible,accepted:o.accepted}));});p.on('input',e=>{inputs.push(e.text);console.log('MAIN INPUT',e.text);return {action:'handled'};});}}
]});
await loader.reload(); console.log("LOADER ERRORS",JSON.stringify(loader.getExtensions().errors));
const {session}=await createAgentSession({cwd:home,agentDir:`${home}/agent`,sessionManager:SessionManager.create(home,`${home}/sessions`),settingsManager:settings,resourceLoader:loader,noTools:"builtin"});
await session.bindExtensions({onError:e=>console.log('EXTENSION ERROR',e)});
try {
run('fm-captain-hold.sh','hold','task-a','--title','Synthetic A','--reason','Intentional stop with no worker status');
writeFileSync(`${home}/state/task-a.turn-ended`,'');
await wait(()=>inputs.some(x=>x.includes('FIRSTMATE WATCHER WAKE: signal:')),'held signal arrives at main');
check(offers.some(o=>o.message.includes('signal:')&&!o.accepted),'held signal was offered to branch');
check(!existsSync(`${home}/state/task-a.status`),'must have no worker status');
console.log('BACKLOG ONLY HELD SIGNAL DELIVERED TO MAIN BY REAL WATCHER AND PI SDK');
writeFileSync(`${home}/stale-enabled`,'');
await wait(()=>inputs.some(x=>x.includes('FIRSTMATE WATCHER WAKE: stale:')),'held stale arrives at main');
check(offers.some(o=>o.message.startsWith('stale:')&&!o.accepted),'held stale reached branch');
console.log('BACKLOG ONLY HELD STALE DELIVERED TO MAIN');
rmSync(`${home}/stale-enabled`);
const drain=run('fm-wake-drain.sh');const recovery=drain.stderr.match(/--recovery-generation (\S+)/)?.[1];
const maxSeq=Math.max(...drain.stdout.trim().split('\n').map(x=>Number(x.split('\t')[1])));
run('fm-wake-drain.sh','--ack-through',String(maxSeq),'--recovery-generation',recovery);
run('fm-captain-hold.sh','answer','task-a','--release','--decision-file',`${home}/decision.txt`);
let raced=false;const before=inputs.length;
api.events.on('fm-branch-supervision:dispatch',o=>{if(o.accepted&&!raced){raced=true;
 execFileSync('bash',['-c','. "$1/bin/fm-wake-lib.sh"; fm_wake_append signal task-b.turn-ended "signal: task-b.turn-ended"','bash',root]);
 run('fm-captain-hold.sh','hold','task-a','--reason','After primary accepts signal');
}});
writeFileSync(`${home}/state/task-a.turn-ended`,'new synthetic turn');
await wait(()=>raced&&inputs.length>before,'late hold fallback arrives at main');
const raceOffer=offers.findLast(o=>o.accepted);const error=await raceOffer.settlement.then(()=>null,e=>e);
console.log('LATE HOLD PRIMARY FALLBACK',String(error));check(error?.message.includes('captain decision'),'wrong fallback error');
const remaining=run('fm-wake-drain.sh');check(remaining.stdout.includes('task-a.turn-ended')&&remaining.stdout.includes('task-b.turn-ended'),'fallback lost unrelated or trigger row');
console.log('PRIMARY ACCEPTANCE HOLD FALLBACK PRESERVED BOTH ROWS');
} finally {await session.dispose();}
process.exit(0);
