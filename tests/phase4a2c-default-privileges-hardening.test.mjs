import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile, readdir } from "node:fs/promises";
import test from "node:test";
import { canonicalGitText } from "./helpers/canonical-git-bytes.mjs";

const migrationUrl = new URL(
  "../supabase/migrations/20260830180000_phase4a2c_default_privileges_hardening.sql",
  import.meta.url,
);
const contractUrl = new URL(
  "../supabase/tests/phase4a2c_default_privileges_hardening_contract.sql",
  import.meta.url,
);
const docsUrl = new URL(
  "../docs/PHASE4A2C_DEFAULT_PRIVILEGES_HARDENING_2026-08-30.md",
  import.meta.url,
);
const baselineUrl = new URL("../supabase/baseline/phase4a2b/", import.meta.url);

const migration = await readFile(migrationUrl, "utf8");
const contract = await readFile(contractUrl, "utf8");
const docs = await readFile(docsUrl, "utf8");
const baselineCompanionWorktree = await readFile(
  new URL("99_platform_companion.sql", baselineUrl),
);
const baselineCompanion = canonicalGitText(
  "supabase/baseline/phase4a2b/99_platform_companion.sql",
  baselineCompanionWorktree,
);
const baselineManifest = JSON.parse(await readFile(
  new URL("manifest.json", baselineUrl),
  "utf8",
));

const sha256 = value => createHash("sha256").update(value).digest("hex");

const stripComments = value => value
  .replace(/--[^\n]*(?:\n|$)/gu, " ")
  .replace(/\/\*[\s\S]*?\*\//gu, " ")
  .trim();

const tokenizeStatements = sql => {
  const statements = [];
  let current = "";
  let state = "normal";
  let dollarTag = "";
  let blockDepth = 0;

  const flush = () => {
    const clean = stripComments(current);
    if (clean) statements.push(clean);
    current = "";
  };

  for (let index = 0; index < sql.length;) {
    if (state === "normal") {
      if (sql.startsWith("--", index)) {
        state = "line-comment";
        current += "--";
        index += 2;
        continue;
      }
      if (sql.startsWith("/*", index)) {
        state = "block-comment";
        blockDepth = 1;
        current += "/*";
        index += 2;
        continue;
      }
      if (sql[index] === "'") {
        state = "single";
        current += sql[index];
        index += 1;
        continue;
      }
      if (sql[index] === '"') {
        state = "double";
        current += sql[index];
        index += 1;
        continue;
      }
      if (sql[index] === "$") {
        const match = sql.slice(index).match(/^\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$/u);
        if (match) {
          [dollarTag] = match;
          state = "dollar";
          current += dollarTag;
          index += dollarTag.length;
          continue;
        }
      }
      if (sql[index] === ";") {
        flush();
        index += 1;
        continue;
      }
      current += sql[index];
      index += 1;
      continue;
    }

    if (state === "line-comment") {
      current += sql[index];
      if (sql[index] === "\n") state = "normal";
      index += 1;
      continue;
    }

    if (state === "block-comment") {
      if (sql.startsWith("/*", index)) {
        blockDepth += 1;
        current += "/*";
        index += 2;
        continue;
      }
      if (sql.startsWith("*/", index)) {
        blockDepth -= 1;
        current += "*/";
        index += 2;
        if (blockDepth === 0) state = "normal";
        continue;
      }
      current += sql[index];
      index += 1;
      continue;
    }

    if (state === "single") {
      current += sql[index];
      if (sql[index] === "'" && sql[index + 1] === "'") {
        current += sql[index + 1];
        index += 2;
        continue;
      }
      if (sql[index] === "'") state = "normal";
      index += 1;
      continue;
    }

    if (state === "double") {
      current += sql[index];
      if (sql[index] === '"' && sql[index + 1] === '"') {
        current += sql[index + 1];
        index += 2;
        continue;
      }
      if (sql[index] === '"') state = "normal";
      index += 1;
      continue;
    }

    if (state === "dollar") {
      if (sql.startsWith(dollarTag, index)) {
        current += dollarTag;
        index += dollarTag.length;
        state = "normal";
        dollarTag = "";
        continue;
      }
      current += sql[index];
      index += 1;
    }
  }

  flush();
  return statements;
};

test("migration identity follows the synthetic baseline and is unique", async () => {
  const migrations = await readdir(new URL("../supabase/migrations/", import.meta.url));
  const matches = migrations.filter(name => name.startsWith("20260830180000_"));
  assert.deepEqual(matches, [
    "20260830180000_phase4a2c_default_privileges_hardening.sql",
  ]);
  assert.ok(20260830180000n > 20260830000000n);
});

test("migration contains only the six deterministic default-privilege revokes", () => {
  const statements = tokenizeStatements(migration);
  assert.equal(statements.length, 6);
  assert.ok(statements.every(statement => /^alter default privileges\b/iu.test(statement)));

  const globalPattern = /^alter default privileges for role "postgres"\s+revoke all on (functions|tables|sequences) from public, "anon", "authenticated", "service_role"$/iu;
  const publicPattern = /^alter default privileges for role "postgres" in schema "public"\s+revoke all on (functions|tables|sequences)\s+from public, "postgres", "anon", "authenticated", "service_role"$/iu;
  const globalKinds = statements.slice(0, 3).map(statement => statement.match(globalPattern)?.[1]);
  const publicKinds = statements.slice(3).map(statement => statement.match(publicPattern)?.[1]);

  assert.deepEqual(globalKinds, ["functions", "tables", "sequences"]);
  assert.deepEqual(publicKinds, ["functions", "tables", "sequences"]);
  assert.doesNotMatch(migration, /\bgrant\b/iu);
  assert.doesNotMatch(migration, /\b(?:insert|update|delete|merge|truncate|copy|call)\b/iu);
  assert.doesNotMatch(migration, /supabase_admin|supabase_auth_admin/iu);
  assert.doesNotMatch(migration, /in schema "(?:auth|storage|realtime|extensions|cron|pgmq)"/iu);
});

test("global revokes close built-in routine exposure and public-schema legacy rows", () => {
  assert.match(
    migration,
    /alter default privileges for role "postgres"\s+revoke all on functions from public, "anon", "authenticated", "service_role"/iu,
  );
  assert.match(
    migration,
    /in schema "public"\s+revoke all on functions\s+from public, "postgres", "anon", "authenticated", "service_role"/iu,
  );
  assert.match(migration, /object owners retain their implicit owner privileges/iu);
});

test("rollback contract is local-only and pins the hardened catalog", () => {
  const statements = tokenizeStatements(contract);
  assert.equal(statements[0].toLowerCase(), "begin");
  assert.equal(statements.at(-1)?.toLowerCase(), "rollback");
  assert.equal(statements.filter(statement => /^begin$/iu.test(statement)).length, 1);
  assert.equal(statements.filter(statement => /^rollback$/iu.test(statement)).length, 1);

  assert.match(contract, /phase4a2c\.isolated_restore_gate/iu);
  assert.match(contract, /PHASE4A2C_REMOTE_DATABASE_REFUSED/u);
  assert.match(contract, /inet '127\.0\.0\.0\/8'/u);
  assert.match(contract, /current_user is distinct from 'postgres'/iu);
  assert.match(contract, /PHASE4A2C_GLOBAL_ROUTINE_DEFAULT_ACL_INVALID/u);
  assert.match(contract, /array\['postgres=X\/postgres'\]::text\[\]/u);
  assert.match(contract, /PHASE4A2C_GLOBAL_RELATION_DEFAULT_ACL_INVALID/u);
  assert.match(contract, /PHASE4A2C_PUBLIC_DEFAULT_ACL_NOT_CANONICAL/u);
  assert.match(contract, /v_count <> 27/u);
  assert.match(contract, /octet_length\(v_payload\) <> 2708/u);
  assert.match(contract, /1f690d52941e6a5865cb59919ded58fa087f2e594215836bd33a78a1141ae9ff/u);
  assert.match(contract, /4e48afbadff3c1f4a2bf8d07c492872b05ba062c59161f708e5a615e04434efe/u);
  assert.doesNotMatch(contract, /c86785623e746bdaf24fabcb75b2a6019385b230830284d851ec27ad030933a3/u);

  assert.doesNotMatch(contract, /^\s*commit\s*;/imu);
  assert.doesNotMatch(contract, /\\(?:connect|copy|include|ir)\b/iu);
  assert.doesNotMatch(contract, /\b(?:dblink|postgres_fdw|http_get|http_post|net\.http|cron\.schedule)\b/iu);
});

test("contract proves default deny and retained postgres owner rights", () => {
  assert.match(contract, /create table public\.phase4a2c_acl_probe_table/iu);
  assert.match(contract, /create sequence public\.phase4a2c_acl_probe_sequence/iu);
  assert.match(contract, /create function public\.phase4a2c_acl_probe_invoker\(\)/iu);
  assert.match(contract, /security invoker\s+set search_path = ''/iu);
  assert.match(contract, /create function public\.phase4a2c_acl_probe_definer\(\)/iu);
  assert.match(contract, /security definer\s+set search_path = ''/iu);
  assert.match(contract, /array\['anon', 'authenticated', 'service_role'\]/u);
  assert.match(contract, /has_schema_privilege\(v_role, 'public', 'CREATE'\)/u);
  assert.match(contract, /'REFERENCES', 'TRIGGER', 'MAINTAIN'/u);
  assert.match(contract, /array\['SELECT', 'UPDATE', 'USAGE'\]/u);
  assert.match(contract, /PHASE4A2C_ROUTINE_DEFAULT_NOT_DENIED/u);
  assert.match(contract, /pg_catalog\.aclexplode/iu);
  assert.match(contract, /pg_catalog\.acldefault\('s', relation_row\.relowner\)/u);
  assert.doesNotMatch(contract, /pg_catalog\.acldefault\('S',/u);
  assert.match(contract, /direct_acl\.grantee = 0/u);
  assert.match(contract, /PHASE4A2C_RAW_DEFAULT_ACL_NOT_DENIED/u);
  assert.match(contract, /PHASE4A2C_OWNER_TABLE_PRIVILEGE_MISSING/u);
  assert.match(contract, /PHASE4A2C_OWNER_SEQUENCE_PRIVILEGE_MISSING/u);
  assert.match(contract, /PHASE4A2C_OWNER_ROUTINE_PRIVILEGE_MISSING/u);
  assert.match(contract, /procedure_row\.proowner <> 'postgres'::regrole/u);
  assert.match(contract, /procedure_row\.proconfig is distinct from array\['search_path=""'\]/u);
});

test("contract demonstrates explicit least-privilege opt-in", () => {
  assert.match(contract, /enable row level security/iu);
  assert.match(contract, /for select\s+to authenticated\s+using \(owner_id = \(select auth\.uid\(\)\)\)/iu);
  assert.match(contract, /grant select on table public\.phase4a2c_acl_probe_table to authenticated/iu);
  assert.match(contract, /grant usage, select on sequence public\.phase4a2c_acl_probe_sequence to authenticated/iu);
  assert.match(contract, /grant execute on function[\s\S]*to authenticated/iu);
  assert.doesNotMatch(contract, /\bgrant\b[\s\S]{0,160}\bto\s+(?:anon|service_role)\b/iu);
  assert.match(contract, /PHASE4A2C_EXPLICIT_GRANT_SCOPE_WIDENED/u);
  assert.match(contract, /PHASE4A2C_EXPLICIT_RLS_POLICY_INVALID/u);
});

test("reviewed Phase 4A.2B baseline remains byte-identical and legacy by design", () => {
  assert.equal(
    sha256(baselineCompanion),
    "8aef851d7cf3fd5af1b8bc52d45cfe70630ad878e0d2a245bfb29d65ad018a9e",
  );
  assert.equal(baselineManifest.format, "phase4a2b-neutral-baseline-v1");
  assert.deepEqual(baselineManifest.platform_companion.default_acl_replay, {
    postgres_public_sections: 3,
    order: "last",
    supabase_admin_and_extension_managed: "observe-only",
    observed_total_records: 29,
    restore_total_records: 32,
    canonical_bytes: 3005,
    canonical_sha256: "c86785623e746bdaf24fabcb75b2a6019385b230830284d851ec27ad030933a3",
  });
  assert.match(baselineCompanion, /GRANT ALL ON TABLES TO "anon"/u);
  assert.match(baselineCompanion, /GRANT ALL ON FUNCTIONS TO "authenticated"/u);
  assert.doesNotMatch(baselineCompanion, /PHASE4A\.2C|phase4a2c/iu);
});

test("runbook keeps every remote mutation behind a separate gate", () => {
  assert.match(docs, /UAT baseline application: \*\*STOP\*\*/u);
  assert.match(docs, /UAT migration-ledger repair: \*\*STOP\*\*/u);
  assert.match(docs, /Production access or mutation: \*\*STOP\*\*/u);
  assert.match(docs, /`main`: \*\*UNCHANGED\*\*/u);
  assert.match(docs, /fresh current hosted Supabase development project/iu);
  assert.match(docs, /existing UAT is not the disposable validation\s+target/iu);
  assert.match(docs, /postgresql\.org\/docs\/current\/sql-alterdefaultprivileges\.html/u);
  assert.match(docs, /supabase\.com\/changelog\/45329-/u);
});
