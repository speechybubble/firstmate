import {writeFileSync,existsSync,readFileSync} from 'node:fs';
export default function(pi:any){
 const home=process.env.FM_HOME!,state=home+'/state';let offers:any[]=[];
 pi.events.on('fm-branch-supervision:dispatch',(offer:any)=>{offers.push({message:offer.message,eligible:offer.eligible,accepted:offer.accepted});console.log('WATCH_PROBE '+JSON.stringify({offer:offers.at(-1)}));});
 pi.on('session_start',()=>{writeFileSync(state+'/.lock',process.pid+'\n');console.log('WATCH_PROBE ready');});
 pi.on('message_start',async(event:any,ctx:any)=>{
  if(event.message.role!=='user')return;
  const text=JSON.stringify(event.message.content);
  if(!text.includes('FIRSTMATE WATCHER WAKE:'))return;
  const ok=text.includes(process.env.PROBE_KIND+':')&&offers.length>0&&offers.every(o=>!o.eligible&&!o.accepted)&&!existsSync(state+'/a.status');
  console.log('WATCH_PROBE '+JSON.stringify({mainReceived:text,offers,statusFileExists:existsSync(state+'/a.status'),queue:readFileSync(state+'/.wake-queue','utf8'),ok}));
  writeFileSync(home+'/result.json',JSON.stringify({pass:ok}));
  await ctx.abort();ctx.shutdown();
 });
}
