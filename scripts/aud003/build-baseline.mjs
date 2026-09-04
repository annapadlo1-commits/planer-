import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const appSchemas = ["authorization_private", "public", "solver_private"];
const q = value => `"${String(value).replaceAll('"', '""')}"`;
const literal = value => `'${String(value).replaceAll("'", "''")}'`;
const object = (schema, name) => `${q(schema)}.${q(name)}`;
const role = name => name === "" ? "PUBLIC" : q(name);
const privileges = { a: "INSERT", r: "SELECT", w: "UPDATE", d: "DELETE", D: "TRUNCATE", x: "REFERENCES", t: "TRIGGER", m: "MAINTAIN", X: "EXECUTE", U: "USAGE", C: "CREATE" };

// pg_get_functiondef can contain CRLF inside a dollar-quoted body. Encode CR
// in an escape string rather than normalize the body: PostgreSQL must recover
// the exact original prosrc, including CR in literals/comments and backslashes.
export function formatRoutineDefinition(definition) {
  const sql = definition.trimEnd();
  if (!sql.includes("\r")) return sql;
  const match = /\bAS (\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$)([\s\S]*)\1$/u.exec(sql);
  assert.ok(match, "CR_ROUTINE_REQUIRES_DOLLAR_QUOTED_BODY");
  assert.equal(match[2].includes(match[1]), false, "AMBIGUOUS_ROUTINE_BODY_DELIMITER");
  const prefix = sql.slice(0, match.index);
  assert.equal(prefix.includes("\r"), false, "CR_OUTSIDE_ROUTINE_BODY");
  const escaped = match[2].replaceAll("\\", "\\\\").replaceAll("'", "''").replaceAll("\r", "\\r");
  return `${prefix}AS E'${escaped}'`;
}

function aclStatements(kind, target, acl, owner) {
  const parsed = acl.map(item => {
    const match = item.match(/^([^=]*)=([A-Za-z*]*)\/([^/]+)$/u);
    if (!match) throw new Error(`UNSUPPORTED_ACL_FORMAT:${kind}:${target}`);
    if (match[3] !== owner) throw new Error(`UNEXPECTED_ACL_GRANTOR:${kind}:${target}`);
    return { grantee: match[1], codes: match[2] };
  });
  const recipients = [...new Set(["", owner, "anon", "authenticated", "service_role", ...parsed.map(x => x.grantee)])];
  const lines = [`REVOKE ALL ON ${kind} ${target} FROM ${recipients.map(role).join(", ")};`];
  for (const entry of parsed) {
    for (const token of entry.codes.match(/[A-Za-z]\*?/gu) ?? []) {
      const privilege = privileges[token[0]];
      if (!privilege) throw new Error(`UNSUPPORTED_PRIVILEGE:${token[0]}`);
      lines.push(`GRANT ${privilege} ON ${kind} ${target} TO ${role(entry.grantee)}${token.endsWith("*") ? " WITH GRANT OPTION" : ""};`);
    }
  }
  return lines;
}

export function buildBaseline(capture) {
  assert.equal(capture.format, "aud003-uat-catalog-v2");
  assert.equal(capture.projectRef, "nhthrtpkfpmufmrmdyjg");
  assert.equal(capture.environment, "ISOLATED_UAT");
  assert.equal(capture.identityEnabled, true);
  assert.equal(capture.transactionReadOnly, "on");
  const lines = [
    "-- AUD-003 canonical application schema baseline, generated from a coherent read-only UAT catalog.",
    `-- Source UAT SHA: ${capture.sourceUatSha}`,
    `-- Capture UTC: ${capture.capturedAtUtc}; ledger SHA-256: ${capture.ledger.sha256}`,
    "-- Schema only: no business/Auth rows, remote ledger rows, Storage objects or cron commands.",
    "-- Apply only to a fresh isolated local Supabase platform during this preparation phase.",
    "SET statement_timeout = 0;",
    "SET lock_timeout = 0;",
    "SET check_function_bodies = false;",
    "SET search_path = '';",
    "SET client_min_messages = warning;",
  ];
  for (const schema of appSchemas.filter(name => name !== "public")) {
    lines.push(`CREATE SCHEMA ${q(schema)} AUTHORIZATION postgres;`);
  }
  lines.push("CREATE SCHEMA IF NOT EXISTS pgmq AUTHORIZATION postgres;");
  for (const extension of capture.extensions) {
    if (extension.name === "plpgsql") continue;
    // Supabase's postgres role cannot select extension versions. Require the
    // installed platform version explicitly instead of accepting a warning.
    lines.push(`CREATE EXTENSION IF NOT EXISTS ${q(extension.name)} WITH SCHEMA ${q(extension.schema)};`);
    lines.push(`DO $aud003_extension$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_extension e JOIN pg_catalog.pg_namespace n ON n.oid=e.extnamespace WHERE e.extname=${literal(extension.name)} AND e.extversion=${literal(extension.version)} AND n.nspname=${literal(extension.schema)}) THEN RAISE EXCEPTION 'AUD003_EXTENSION_VERSION_OR_SCHEMA_MISMATCH'; END IF; END $aud003_extension$;`);
  }
  // Remove only application-owned per-schema creation grants. Managed defaults stay platform-owned.
  for (const schema of appSchemas) for (const kind of ["TABLES", "SEQUENCES", "FUNCTIONS", "TYPES"]) {
    lines.push(`ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA ${q(schema)} REVOKE ALL ON ${kind} FROM PUBLIC, postgres, anon, authenticated, service_role;`);
  }
  const globalFunctionAcl = capture.defaultAcls.find(x => x.role === "postgres" && x.schema === "" && x.object_type === "f");
  assert.deepEqual(globalFunctionAcl?.acl, ["postgres=X/postgres"]);
  lines.push("ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;");
  assert.equal(capture.defaultAcls.filter(x => x.role === "postgres" && appSchemas.includes(x.schema)).length, 0);

  for (const type of capture.types) {
    assert.equal(type.kind, "e", `Unimplemented type kind for ${type.schema}.${type.name}`);
    lines.push(`CREATE TYPE ${object(type.schema, type.name)} AS ENUM (${type.enum_labels.map(literal).join(", ")});`);
  }
  for (const table of capture.relations.filter(x => x.kind !== "S")) {
    assert.equal(table.kind, "r");
    assert.equal(table.is_partition, false);
    assert.equal(table.owner, "postgres");
    assert.equal(table.replica_identity, "d");
    const columns = capture.columns.filter(x => x.schema === table.schema && x.relation === table.name).sort((a,b) => a.ordinal-b.ordinal);
    const definitions = columns.map(column => {
      assert.equal(column.generated, "", "Generated columns require explicit support");
      let definition = `${q(column.name)} ${column.type}`;
      if (column.collation) definition += ` COLLATE ${column.collation}`;
      if (column.identity) {
        assert.ok(["a", "d"].includes(column.identity));
        const ownership = capture.sequenceOwnership.find(x => x.table_schema === table.schema && x.table_name === table.name && x.column_name === column.name);
        assert.ok(ownership, "Identity sequence provenance required");
        const seq = capture.sequences.find(x => x.schema === ownership.schema && x.name === ownership.sequence);
        assert.ok(seq);
        definition += ` GENERATED ${column.identity === "a" ? "ALWAYS" : "BY DEFAULT"} AS IDENTITY (SEQUENCE NAME ${object(seq.schema, seq.name)} START WITH ${seq.start} INCREMENT BY ${seq.increment} MINVALUE ${seq.min} MAXVALUE ${seq.max} CACHE ${seq.cache}${seq.cycle ? " CYCLE" : " NO CYCLE"})`;
      }
      if (column.not_null) definition += " NOT NULL";
      return definition;
    });
    lines.push(`CREATE ${table.persistence === "u" ? "UNLOGGED " : ""}TABLE ${object(table.schema, table.name)} (\n  ${definitions.join(",\n  ")}\n)${table.options.length ? ` WITH (${table.options.join(", ")})` : ""};`);
  }
  for (const routine of capture.routines) {
    assert.ok(appSchemas.includes(routine.schema));
    assert.equal(routine.owner, "postgres");
    const definition = formatRoutineDefinition(routine.definition);
    lines.push(definition.endsWith(';') ? definition : `${definition};`);
  }
  for (const column of capture.columns) {
    if (column.default_expression !== null) lines.push(`ALTER TABLE ${object(column.schema, column.relation)} ALTER COLUMN ${q(column.name)} SET DEFAULT ${column.default_expression};`);
    assert.equal(column.acl.length, 0, "Column ACL requires explicit support");
  }
  const constraints = capture.constraints.filter(x => x.type !== "t").sort((a,b) => {
    const rank = x => ["p", "u", "x"].includes(x.type) ? 0 : x.type === "c" ? 1 : 2;
    return rank(a)-rank(b) || `${a.schema}.${a.relation}.${a.name}`.localeCompare(`${b.schema}.${b.relation}.${b.name}`, "en");
  });
  for (const constraint of constraints) {
    assert.ok(["p", "u", "x", "c", "f"].includes(constraint.type));
    let definition = constraint.definition;
    if (!constraint.validated && !/\bNOT VALID\b/u.test(definition)) definition += " NOT VALID";
    lines.push(`ALTER TABLE ${object(constraint.schema, constraint.relation)} ADD CONSTRAINT ${q(constraint.name)} ${definition};`);
  }
  for (const index of capture.indexes.filter(x => !x.constraint_name)) {
    assert.equal(index.valid, true); assert.equal(index.ready, true);
    lines.push(`${index.definition};`);
  }
  assert.equal((capture.views ?? []).length, 0, "Views require explicit dependency ordering");
  for (const trigger of capture.triggers) {
    lines.push(`${trigger.definition};`);
    const state = { O: "ENABLE", D: "DISABLE", A: "ENABLE ALWAYS", R: "ENABLE REPLICA" }[trigger.enabled];
    assert.ok(state);
    if (trigger.enabled !== "O") lines.push(`ALTER TABLE ${object(trigger.schema, trigger.relation)} ${state} TRIGGER ${q(trigger.name)};`);
  }
  for (const policy of capture.policies) {
    assert.ok([...appSchemas, "storage"].includes(policy.schemaname), "Unexpected managed policy");
    lines.push(`CREATE POLICY ${q(policy.policyname)} ON ${object(policy.schemaname, policy.tablename)} AS ${policy.permissive} FOR ${policy.cmd} TO ${policy.roles.map(x => x === "public" ? "PUBLIC" : q(x)).join(", ")}${policy.qual === null ? "" : ` USING (${policy.qual})`}${policy.with_check === null ? "" : ` WITH CHECK (${policy.with_check})`};`);
  }
  for (const table of capture.relations.filter(x => x.kind === "r")) {
    lines.push(`ALTER TABLE ${object(table.schema, table.name)} ${table.rls ? "ENABLE" : "DISABLE"} ROW LEVEL SECURITY;`);
    if (table.force_rls) lines.push(`ALTER TABLE ${object(table.schema, table.name)} FORCE ROW LEVEL SECURITY;`);
  }
  for (const type of capture.types) lines.push(...aclStatements("TYPE", object(type.schema,type.name),type.acl,type.owner));
  for (const relation of capture.relations) lines.push(...aclStatements(relation.kind === "S" ? "SEQUENCE" : "TABLE",object(relation.schema,relation.name),relation.acl,relation.owner));
  for (const routine of capture.routines) lines.push(...aclStatements(routine.kind === "p" ? "PROCEDURE" : "FUNCTION",`${object(routine.schema,routine.name)}(${routine.identity_arguments})`,routine.acl,routine.owner));
  for (const schema of capture.schemas.filter(x => appSchemas.includes(x.name))) {
    lines.push(`ALTER SCHEMA ${q(schema.name)} OWNER TO ${q(schema.owner)};`);
    lines.push(`SET ROLE ${q(schema.owner)};`,...aclStatements("SCHEMA",q(schema.name),schema.acl,schema.owner),"RESET ROLE;");
  }
  for (const queue of capture.pgmqQueues) {
    assert.equal(queue.is_partitioned,false); assert.equal(queue.is_unlogged,false);
    lines.push(`SELECT pgmq.create(${literal(queue.queue_name)});`);
  }
  for (const publication of capture.publications) {
    assert.equal(publication.name,"supabase_realtime"); assert.equal(publication.all_tables,false);
    assert.equal(publication.owner,"postgres"); assert.equal(publication.via_root,false);
    assert.equal(publication.insert,true); assert.equal(publication.update,true); assert.equal(publication.delete,true); assert.equal(publication.truncate,true);
    for (const table of publication.tables) {
      assert.equal(table.rowfilter,null);
      assert.deepEqual(table.attnames,capture.columns.filter(x => x.schema === table.schemaname && x.relation === table.tablename).sort((a,b) => a.ordinal-b.ordinal).map(x => x.name));
      lines.push(`ALTER PUBLICATION ${q(publication.name)} ADD TABLE ONLY ${object(table.schemaname,table.tablename)};`);
    }
  }
  lines.push("-- Storage bucket metadata is provisioned separately through the local Storage API.","-- Cron jobs are deliberately not scheduled; only their metadata/hash is retained in source evidence.","RESET check_function_bodies;","RESET search_path;");
  return `${lines.join("\n\n")}\n`;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const capturePath = process.argv[2] || "supabase/baseline/aud003/uat-catalog-2026-09-03.json";
  const output = process.argv[3] || "supabase/baseline/aud003/generated-baseline.sql";
  const capture = JSON.parse(await readFile(capturePath,"utf8"));
  const sql = buildBaseline(capture);
  await writeFile(output,sql,"utf8");
  console.log(`AUD003_BASELINE_GENERATED ${Buffer.byteLength(sql)} bytes`);
}
