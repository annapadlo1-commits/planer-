import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {writeFile} from 'node:fs/promises';
import {classifyInventory,compareSourceAndLive,assertParity} from '../rpc-contract/parity-core.mjs';
const output=process.argv[2];assert.ok(output);
function json(args) {
 const r=spawnSync(process.execPath,args,{encoding:'utf8',maxBuffer:32*1024*1024});
 assert.equal(r.status,0,`LOCAL_RPC_PROOF_FAILED:${r.stderr}`);return JSON.parse(r.stdout);
}
const live=json(['scripts/aud003/local-psql.mjs','scripts/aud003/capture-local-rpc.sql']);
assert.equal(live.localProject,'aud003-local-db-20260903');assert.equal(live.database,'postgres');
const frontend=json(['scripts/rpc-contract/frontend-runtime-inventory.mjs']);
const source=json(['scripts/rpc-contract/migration-source-inventory.mjs']);
assert.equal(frontend.unresolved.length,0);
const parity=classifyInventory(frontend.inventory,live.rows);
const drift=compareSourceAndLive(source.inventory,live.rows,frontend.inventory.map(x=>x.name));
const result={scope:'Actual disposable LOCAL PostgreSQL after baseline + six audit migrations; NOT live UAT',counts:parity.counts,frontendUniqueRpc:frontend.uniqueCount,sourceOverloads:source.inventory.length,localOverloads:live.rows.length,sourceLocalSignatureDrift:drift,matrix:parity.matrix};
await writeFile(output,JSON.stringify(result,null,2)+'\n');
console.log(JSON.stringify({...result,matrix:undefined},null,2));
assertParity(parity,'actual local PostgreSQL');
assert.deepEqual(drift,{sourceOnly:[],liveOnly:[]});
