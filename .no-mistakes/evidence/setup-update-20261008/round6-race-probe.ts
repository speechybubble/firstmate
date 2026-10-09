import {readFileSync,existsSync,appendFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
export default function(pi:any){
 let armed=true;
 const h=process.env.FM_HOME!, out=process.env.E+'/round6-race.jsonl';
 const record=(x:any)=>appendFileSync(out,JSON.stringify({time:Date.now(),...x})+'\n');
 pi.registerCommand('race-away',{description:'Arm isolated posture-change experiment',handler:async()=>{armed=true;record({armed:true});}});
 pi.events.on('fm-branch-supervision:dispatch',(offer:any)=>{
  record({offered:offer.message,eligible:offer.eligible,awayOnly:offer.awayOnly,alreadyAccepted:offer.accepted});
  if(!armed||!offer.awayOnly)return;
  const accept=offer.accept.bind(offer);
  offer.accept=(settlement:any)=>{
   accept(settlement);armed=false;
   record({accepted:offer.accepted,message:offer.message,queue:readFileSync(h+'/state/.wake-queue','utf8')});
   execFileSync('bash',[process.cwd()+'/bin/fm-afk-contract.sh','archive']);
   settlement.then(()=>record({settled:'resolved'}), (err:any)=>record({settled:'rejected',error:String(err),queue:readFileSync(h+'/state/.wake-queue','utf8'),grant:existsSync(h+'/state/.branch-eligible-rows')}));
  };
 });
}
