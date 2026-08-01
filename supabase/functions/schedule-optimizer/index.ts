import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.57.4";

type J = Record<string, any>;
type Slot = {id:string,date:string,shiftCode:string,startsAt:string,endsAt:string,locationId:string,locationCode:string,role:string,fn?:string};
type Gene = string|null;
type Candidate = {genes:Gene[]; score:number; hard:number; metrics:J; unfilled:Slot[]};

function rng(seed:number){let x=seed|0;return()=>{x^=x<<13;x^=x>>>17;x^=x<<5;return (x>>>0)/4294967296}}
function shuffle<T>(a:T[],r:()=>number){for(let i=a.length-1;i>0;i--){const j=Math.floor(r()*(i+1));[a[i],a[j]]=[a[j],a[i]]}return a}
function minutes(a:string,b:string){return Math.max(0,(Date.parse(b)-Date.parse(a))/60000)}
function weekKey(d:string){const x=new Date(d+"T12:00:00Z"),day=(x.getUTCDay()+6)%7;x.setUTCDate(x.getUTCDate()-day);return x.toISOString().slice(0,10)}
function isWeekend(d:string){const x=new Date(d+"T12:00:00Z").getUTCDay();return x===0||x===6}
function zoned(date:string,time:string,zone:string){const base=Date.parse(`${date}T${time}Z`),fmt=new Intl.DateTimeFormat('en-CA',{timeZone:zone,year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23'}),parts=Object.fromEntries(fmt.formatToParts(new Date(base)).filter(p=>p.type!=='literal').map(p=>[p.type,p.value])),shown=Date.UTC(+parts.year,+parts.month-1,+parts.day,+parts.hour,+parts.minute,+parts.second),offset=shown-base;return new Date(base-offset).toISOString()}

function buildSlots(input:J):Slot[]{
  const month=input.month.slice(0,7), end=new Date(`${month}-01T12:00:00Z`);end.setUTCMonth(end.getUTCMonth()+1);
  const templates=new Map(input.templates.map((t:J)=>[t.id,t])); const slots:Slot[]=[];
  for(let d=new Date(`${month}-01T12:00:00Z`);d<end;d.setUTCDate(d.getUTCDate()+1)){
    const date=d.toISOString().slice(0,10), iso=d.getUTCDay()===0?7:d.getUTCDay();
    for(const dem of input.demand){const t:any=templates.get(dem.templateId);if(!t||!t.days.includes(iso)||!(dem.scenario==='BASE'||dem.scenario===input.scenario))continue;
      const next=t.end<=t.start; const endDate=new Date(`${date}T12:00:00Z`);if(next)endDate.setUTCDate(endDate.getUTCDate()+1);const endDay=endDate.toISOString().slice(0,10);
      for(let n=0;n<dem.count;n++)slots.push({id:`${date}|${t.id}|${dem.role}|${dem.function||''}|${n}`,date,shiftCode:t.code,startsAt:zoned(date,t.start,t.timezone),endsAt:zoned(endDay,t.end,t.timezone),locationId:t.locationId,locationCode:t.locationCode,role:dem.role,fn:dem.function||undefined});
    }
  }
  return slots.sort((a,b)=>(!!b.fn as any)-(!!a.fn as any)||a.startsAt.localeCompare(b.startsAt));
}

function solve(input:J){
  input.scenario=input.scenario||input.scenarioCode||'BASE'; const slots=buildSlots(input), employees=input.employees as J[], emp=new Map(employees.map(e=>[e.id,e]));
  const av=new Map<string,J>();for(const a of input.availability)av.set(`${a.employeeId}|${a.date}`,a);
  const prefs=input.preferences as J[], rand=rng(input.seed), weights=input.profile.weights;
  const locationOK=(e:J,s:Slot)=>e.locations.some((l:J)=>l.id===s.locationId);
  const roleOK=(e:J,s:Slot)=>e.roles.includes(s.role)||e.role===s.role;
  const capabilityOK=(e:J,s:Slot)=>!s.fn||e.capabilities.some((c:J)=>c.code===s.fn&&(!c.role||c.role===s.role)&&(!c.location||c.location===s.locationCode));
  function feasible(e:J,s:Slot,state:J){
    if(!locationOK(e,s)||!roleOK(e,s)||!capabilityOK(e,s))return false;
    if(e.employmentStart&&s.date<e.employmentStart||e.employmentEnd&&s.date>e.employmentEnd)return false;
    if(e.noWeekends&&isWeekend(s.date)||e.onlyMorning&&new Date(s.startsAt).getUTCHours()>=15||e.onlyEvening&&new Date(s.startsAt).getUTCHours()<14)return false;
    const a=av.get(`${e.id}|${s.date}`);if(a&&(!a.available||(a.earliestStart&&s.startsAt.slice(11,19)<a.earliestStart)||(a.latestEnd&&s.endsAt.slice(11,19)>a.latestEnd)))return false;
    const list=state.byEmp.get(e.id)||[]; const rest=(e.minimumRest||660)*60000;
    for(const x of list){if(Date.parse(s.startsAt)<Date.parse(x.endsAt)+rest&&Date.parse(s.endsAt)>Date.parse(x.startsAt)-rest)return false}
    const m=minutes(s.startsAt,s.endsAt);if((state.month.get(e.id)||0)+m>e.maxMonthly)return false;
    if((state.week.get(`${e.id}|${weekKey(s.date)}`)||0)+m>e.maxWeekly)return false;
    const days=new Set(list.map((x:Slot)=>x.date));days.add(s.date);const sorted=[...days].sort();let streak=1,max=1;for(let i=1;i<sorted.length;i++){const a=Date.parse(sorted[i-1]+"T12:00:00Z"),b=Date.parse(sorted[i]+"T12:00:00Z");streak=b-a===86400000?streak+1:1;max=Math.max(max,streak)}if(max>e.maxConsecutiveDays)return false;
    return true;
  }
  function stateFor(genes:Gene[]){const st:J={byEmp:new Map(),month:new Map(),week:new Map()};genes.forEach((id,i)=>{if(!id)return;const s=slots[i],m=minutes(s.startsAt,s.endsAt);if(!st.byEmp.has(id))st.byEmp.set(id,[]);st.byEmp.get(id).push(s);st.month.set(id,(st.month.get(id)||0)+m);const k=`${id}|${weekKey(s.date)}`;st.week.set(k,(st.week.get(k)||0)+m)});return st}
  function incremental(e:J,s:Slot,st:J){let p=e.rate*minutes(s.startsAt,s.endsAt)/60*weights.cost;const ps=prefs.filter(x=>x.employeeId===e.id&&x.from<=s.date&&x.to>=s.date);for(const q of ps){if(q.type==='PREFERRED_SHIFT'&&q.value?.code!==s.shiftCode)p+=weights.preference;if(q.type==='PREFERRED_LOCATION'&&q.value?.code!==s.locationCode)p+=weights.preference;if(q.type==='OTHER'&&q.value?.dayOff)p+=weights.preference}if(e.preferredShift&&e.preferredShift!==s.shiftCode)p+=weights.preference;if(!e.locations.some((l:J)=>l.id===s.locationId&&l.home))p+=weights.homeLocation;p+=((st.month.get(e.id)||0)/Math.max(1,e.nominal))*weights.fairness;return p}
  function repair(source:Gene[]){const genes:Array<Gene>=Array(slots.length).fill(null), order=shuffle([...slots.keys()],rand),st=stateFor(genes);for(const i of order){const requested=source[i], pool=shuffle(employees.filter(e=>feasible(e,slots[i],st)),rand).sort((a,b)=>incremental(a,slots[i],st)-incremental(b,slots[i],st));const chosen=requested&&pool.some(e=>e.id===requested)?emp.get(requested):pool[0];if(chosen){genes[i]=chosen.id;const s=slots[i],m=minutes(s.startsAt,s.endsAt);if(!st.byEmp.has(chosen.id))st.byEmp.set(chosen.id,[]);st.byEmp.get(chosen.id).push(s);st.month.set(chosen.id,(st.month.get(chosen.id)||0)+m);const k=`${chosen.id}|${weekKey(s.date)}`;st.week.set(k,(st.week.get(k)||0)+m)}}return evaluate(genes)}
  function evaluate(genes:Gene[]):Candidate{const st=stateFor(genes),unfilled=slots.filter((_,i)=>!genes[i]);let cost=0,pref=0,nominal=0,weekends:number[]=[];for(const e of employees){const mins=st.month.get(e.id)||0;cost+=mins/60*e.rate;nominal+=Math.abs(mins-e.nominal);weekends.push((st.byEmp.get(e.id)||[]).filter((s:Slot)=>isWeekend(s.date)).length)}genes.forEach((id,i)=>{if(!id)return;const e=emp.get(id)!;if(e.preferredShift&&e.preferredShift!==slots[i].shiftCode)pref++});const avg=weekends.reduce((a,b)=>a+b,0)/Math.max(1,weekends.length),variance=weekends.reduce((a,b)=>a+(b-avg)**2,0);const score=unfilled.length*weights.shortage+cost*weights.cost+pref*weights.preference+nominal/60*weights.nominal+variance*weights.weekendFairness;return{genes,score,hard:0,metrics:{unfilled:unfilled.length,cost,preferenceViolations:pref,nominalDeviationHours:nominal/60,weekendVariance:variance},unfilled}}
  let pop:Candidate[]=[];for(let i=0;i<input.profile.populationSize;i++)pop.push(repair(Array(slots.length).fill(null)));
  for(let g=0;g<input.profile.generations;g++){pop.sort((a,b)=>a.score-b.score);const next=pop.slice(0,input.profile.eliteCount);while(next.length<input.profile.populationSize){const a=pop[Math.floor(rand()*Math.min(pop.length,16))],b=pop[Math.floor(rand()*Math.min(pop.length,16))];const genes=a.genes.map((x,i)=>rand()<.5?x:b.genes[i]);for(let i=0;i<genes.length;i++)if(rand()<input.profile.mutationRate)genes[i]=rand()<.2?null:employees[Math.floor(rand()*employees.length)].id;next.push(repair(genes))}pop=next}
  pop.sort((a,b)=>a.score-b.score);const unique:Candidate[]=[];const seen=new Set<string>();for(const c of pop){const k=c.genes.join('|');if(!seen.has(k)){seen.add(k);unique.push(c)}if(unique.length>=input.profile.alternativesCount)break}
  return unique.map((c,rank)=>({rank:rank+1,score:c.score,hardViolations:c.hard,metrics:c.metrics,unfilled:c.unfilled,assignments:c.genes.flatMap((id,i)=>id?[{slotId:slots[i].id,employeeId:id,date:slots[i].date,shiftCode:slots[i].shiftCode,startsAt:slots[i].startsAt,endsAt:slots[i].endsAt,locationId:slots[i].locationId,role:slots[i].role,function:slots[i].fn||null}]:[])}));
}

Deno.serve(async(req:Request)=>{try{
  if(req.method!=="POST")return new Response("Method not allowed",{status:405});const auth=req.headers.get("Authorization");if(!auth)return new Response(JSON.stringify({error:"UNAUTHORIZED"}),{status:401});
  const client=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_ANON_KEY")!,{global:{headers:{Authorization:auth}}});
  const body=await req.json();const {data:input,error}=await client.rpc("optimizer_prepare",{p_month:body.month,p_profile_code:body.profile||"BALANCED",p_scenario_code:body.scenario||"BASE",p_seed:body.seed||null});if(error)throw error;
  const candidates=solve(input);const {data,error:commitError}=await client.rpc("optimizer_commit",{p_run_id:input.runId,p_name:body.name,p_candidates:candidates});if(commitError)throw commitError;
  return new Response(JSON.stringify(data),{headers:{"content-type":"application/json"}});
}catch(e){return new Response(JSON.stringify({error:e instanceof Error?e.message:String(e)}),{status:400,headers:{"content-type":"application/json"}})}});
