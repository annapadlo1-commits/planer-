import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";

const container = process.env.AUD014_LOCAL_DB_CONTAINER ??
  "supabase_db_aud003-local-db-20260903";
assert.match(container, /^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/u);

const migrationDirectory = new URL("../../supabase/migrations/", import.meta.url);
const names = (await readdir(migrationDirectory)).filter((name) =>
  name.endsWith("_aud014_evidence_backed_fk_indexes.sql"),
);
assert.equal(names.length, 1);
const migration = await readFile(new URL(names[0], migrationDirectory), "utf8");
assert.match(migration, /commit;\s*$/u);
const migrationBody = migration
  .replace(/\bbegin;\s*/u, "")
  .replace(/commit;\s*$/u, "");

const exactUatControl = String.raw`
insert into public.uat_environment_controls(control_key,enabled,config)
values(
  'ISOLATED_UAT_DESTRUCTIVE_TOOLS',
  true,
  '{"environment":"ISOLATED_UAT","projectRef":"nhthrtpkfpmufmrmdyjg"}'::jsonb
)
on conflict(control_key) do update
set enabled=excluded.enabled,
    config=excluded.config;
`;

const negativeGuardProbe = String.raw`
begin;
update public.uat_environment_controls
set config=jsonb_set(
  config,'{projectRef}','"aud014-negative-local-test"'::jsonb,true
)
where control_key='ISOLATED_UAT_DESTRUCTIVE_TOOLS';
${migrationBody}
`;

const negativeRun = spawnSync(
  "docker",
  ["exec", "-i", container, "psql", "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres"],
  { input: negativeGuardProbe, encoding: "utf8", maxBuffer: 8 * 1024 * 1024 },
);
if (negativeRun.error) throw negativeRun.error;
assert.notEqual(
  negativeRun.status,
  0,
  "exact-project guard nie odrzucił lokalnej próby z obcym refem",
);
assert.match(
  `${negativeRun.stdout}\n${negativeRun.stderr}`,
  /AUD014_WRONG_SUPABASE_PROJECT/u,
);

const negativeDefinitionProbe = String.raw`
begin;
${exactUatControl}
drop index if exists public.application_access_directory_v1_auth_user_id_fk_idx;
create index application_access_directory_v1_auth_user_id_fk_idx
  on public.application_access_directory_v1 (id);
${migrationBody}
`;

const negativeDefinitionRun = spawnSync(
  "docker",
  ["exec", "-i", container, "psql", "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres"],
  { input: negativeDefinitionProbe, encoding: "utf8", maxBuffer: 8 * 1024 * 1024 },
);
if (negativeDefinitionRun.error) throw negativeDefinitionRun.error;
assert.notEqual(
  negativeDefinitionRun.status,
  0,
  "istniejący indeks o prawidłowej nazwie i błędnej definicji nie został odrzucony",
);
assert.match(
  `${negativeDefinitionRun.stdout}\n${negativeDefinitionRun.stderr}`,
  /AUD014_INDEX_DEFINITION_MISMATCH/u,
);

const verification = migration
  .replace(/\bbegin;\s*/u, `begin;\n${exactUatControl}\n`)
  .replace(/commit;\s*$/u, String.raw`
do $verify$
declare
  v_expected text[]:=array[
    'application_access_directory_v1_auth_user_id_fk_idx',
    'audit_log_actor_id_fk_idx',
    'employee_preferences_employee_id_fk_idx'
  ];
begin
  if (
    select count(*)
    from pg_catalog.pg_index index_row
    join pg_catalog.pg_class index_relation
      on index_relation.oid=index_row.indexrelid
    where index_relation.relnamespace='public'::regnamespace
      and index_relation.relname=any(v_expected)
      and index_row.indisvalid
      and index_row.indisready
      and index_row.indislive
      and index_row.indpred is null
      and index_row.indexprs is null
      and index_row.indnkeyatts=1
      and index_row.indnatts=1
  )<>3 then
    raise exception 'AUD014_LOCAL_INDEX_CATALOG_MISMATCH';
  end if;
end;
$verify$;

select jsonb_build_object(
  'migration','AUD-2026-09-01-014',
  'projectGuard','nhthrtpkfpmufmrmdyjg',
  'indexes',jsonb_agg(jsonb_build_object(
    'name',index_relation.relname,
    'relation',index_row.indrelid::regclass::text,
    'column',pg_catalog.pg_get_indexdef(index_relation.oid,1,true),
    'valid',index_row.indisvalid,
    'ready',index_row.indisready
  ) order by index_relation.relname),
  'persistentChanges',false
)::text
from pg_catalog.pg_index index_row
join pg_catalog.pg_class index_relation
  on index_relation.oid=index_row.indexrelid
where index_relation.relnamespace='public'::regnamespace
  and index_relation.relname=any(array[
    'application_access_directory_v1_auth_user_id_fk_idx',
    'audit_log_actor_id_fk_idx',
    'employee_preferences_employee_id_fk_idx'
  ]);

rollback;
`);

const run = spawnSync(
  "docker",
  ["exec", "-i", container, "psql", "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres"],
  { input: verification, encoding: "utf8", maxBuffer: 8 * 1024 * 1024 },
);
if (run.error) throw run.error;
if (run.status !== 0) {
  process.stderr.write(run.stderr);
  process.stdout.write(run.stdout);
  process.exit(run.status ?? 1);
}

const proof = run.stdout.split(/\r?\n/u).find((line) => line.startsWith("{"));
assert.ok(proof, "brak katalogowego dowodu migracji");
process.stdout.write(`${JSON.stringify(JSON.parse(proof), null, 2)}\n`);
