import assert from 'node:assert/strict';
import {readFile,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
const [localPath,outputPath]=process.argv.slice(2);
assert.ok(localPath && outputPath);
const source=JSON.parse(await readFile('supabase/baseline/aud003/uat-catalog-2026-09-03.json','utf8'));
const local=JSON.parse(await readFile(localPath,'utf8'));
assert.equal(source.projectRef,'nhthrtpkfpmufmrmdyjg');
assert.equal(local.localProject,'aud003-local-db-20260903');
const keys={schemas:['name'],relations:['schema','name'],columns:['schema','relation','name'],constraints:['schema','relation','name'],indexes:['schema','relation','name'],sequences:['schema','name'],sequenceOwnership:['schema','sequence'],types:['schema','name'],routines:['schema','name','identity_arguments'],views:['schema','name'],triggers:['schema','relation','name'],policies:['schemaname','tablename','policyname'],defaultAcls:['schema','role','object_type'],extensions:['name'],publications:['name'],eventTriggers:['name'],storageBuckets:['id'],pgmqQueues:['queue_name']};
function canonical(value) {
 if(Array.isArray(value))return value.map(canonical);
 if(value && typeof value==='object')return Object.fromEntries(Object.keys(value).filter(k=>k!=='acl_is_null').sort().map(k=>[k,canonical(value[k])]));
 return value;
}
const differences=[];
const counts={};
const hash=value=>createHash('sha256').update(JSON.stringify(canonical(value??null))).digest('hex');
function difference(section,key,kind,left,right,fields) {
 differences.push({section,key,kind,...(fields?{fields}:{}),sourceSha256:hash(left),localSha256:hash(right)});
}
for(const [section,fields] of Object.entries(keys)) {
 const index=rows=>{
  const entries=(rows??[]).map(row=>[fields.map(f=>row[f]).join('|'),canonical(row)]);
  const result=new Map(entries);
  assert.equal(result.size,entries.length,`DUPLICATE_CATALOG_IDENTITY:${section}`);
  return result;
 };
 const a=index(source[section]), b=index(local[section]);
 counts[section]={source:a.size,local:b.size};
 for(const key of new Set([...a.keys(),...b.keys()])) {
  if(!a.has(key)||!b.has(key))difference(section,key,a.has(key)?'MISSING_LOCAL':'LOCAL_ONLY',a.get(key),b.get(key));
  else if(JSON.stringify(a.get(key))!==JSON.stringify(b.get(key))) {
   const left=a.get(key),right=b.get(key);
   const changed=Object.keys({...left,...right}).filter(f=>JSON.stringify(left[f])!==JSON.stringify(right[f]));
   difference(section,key,'DIFFERENT',left,right,changed);
  }
 }
}
for(const section of ['storageObjectsTable','cronMetadata'])if(JSON.stringify(canonical(source[section]))!==JSON.stringify(canonical(local[section])))difference(section,'singleton','DIFFERENT',source[section],local[section]);
const rules=JSON.parse(await readFile('supabase/baseline/aud003/platform-differences.json','utf8'));
assert.equal(rules.projectRef,source.projectRef);
for(const d of differences) {
 const rule=rules.entries.find(r=>r.section===d.section && r.key===d.key && r.kind===d.kind && r.sourceSha256===d.sourceSha256 && r.localSha256===d.localSha256);
 if(rule)d.explanation=rule.explanation;
}
const unexplainedCount=differences.filter(d=>!d.explanation).length;
const result={format:'aud003-semantic-diff-v2',sourceCapturedAt:source.capturedAtUtc,localCapturedAt:local.capturedAtUtc,normalization:['Effective ACL compared; acl_is_null representation ignored. All other exceptions require exact source/local fingerprints and an explicit explanation.'],counts,differences,unexplainedCount};
await writeFile(outputPath,JSON.stringify(result,null,2)+'\n');
console.log(JSON.stringify({counts,explainedCount:differences.length-unexplainedCount,unexplainedCount},null,2));
if(unexplainedCount)process.exitCode=1;
