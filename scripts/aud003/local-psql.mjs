import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { inspectLocalTarget } from "./local-target.mjs";

const container = "supabase_db_aud003-local-db-20260903";
const project = "aud003-local-db-20260903";
const docker = process.env.AUD003_DOCKER_BINARY || "docker";
const [sqlPath, database = "postgres", mode] = process.argv.slice(2);
if (!sqlPath || !["postgres", "aud003_rebuild_a", "aud003_rebuild_b"].includes(database) || (mode && !["--transaction", "--baseline-empty"].includes(mode))) {
  throw new Error("LOCAL_SQL_FILE_AND_ALLOWLISTED_DATABASE_REQUIRED");
}
inspectLocalTarget();
const inspected = spawnSync(docker, ["inspect", container], { encoding: "utf8", maxBuffer: 4 * 1024 * 1024 });
if (inspected.status !== 0) throw new Error("LOCAL_CONTAINER_INSPECTION_FAILED");
const [state] = JSON.parse(inspected.stdout);
assert.equal(state.Name, `/${container}`);
assert.equal(state.Config.Labels["com.supabase.cli.project"], project);
assert.equal(state.State.Running, true);
assert.equal(state.State.Health.Status, "healthy");
// The localhost-only container is created from the verified immutable image ID,
// not from a mutable tag. Reject any other image identity.
assert.equal(state.Config.Image, "sha256:28f0e16a019e648089fc1a6d333549a55548f6019c15ae4bd7cd58b989027518");
assert.deepEqual(state.NetworkSettings.Ports, { "5432/tcp": [{ HostIp: "127.0.0.1", HostPort: "55432" }] });
if (/nhthrtpkfpmufmrmdyjg|bdybebzvzapihjdauehg|supabase\.co|pooler\.supabase/iu.test(JSON.stringify(state.Config))) {
  throw new Error("REMOTE_CONFIGURATION_REFUSED");
}
const sql = readFileSync(sqlPath);
const emptyGuard = `DO $guard$ BEGIN
 IF EXISTS(SELECT 1 FROM pg_namespace WHERE nspname IN ('solver_private','authorization_private'))
 OR EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','f'))
 OR EXISTS(SELECT 1 FROM auth.users) OR EXISTS(SELECT 1 FROM storage.objects) OR EXISTS(SELECT 1 FROM storage.buckets)
 OR to_regclass('supabase_migrations.schema_migrations') IS NOT NULL
 THEN RAISE EXCEPTION 'AUD003_EMPTY_LOCAL_PLATFORM_REQUIRED'; END IF;
 END $guard$;\n`;
const input = mode === "--baseline-empty" ? Buffer.concat([Buffer.from(emptyGuard), sql]) : sql;
const args = ["--context", "desktop-linux", "exec", "-i", container, "psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-h", "/var/run/postgresql", "-U", "postgres", "-d", database];
// psql's single-transaction + ON_ERROR_STOP sends ROLLBACK on a failed file.
// Unlike an appended COMMIT, this also covers errors anywhere in the input file.
if (mode) args.push("--single-transaction");
args.push("--file=/dev/stdin");
const result = spawnSync(docker, args, {
  input, encoding: "utf8", maxBuffer: 64 * 1024 * 1024,
});
process.stdout.write(result.stdout || "");
process.stderr.write(result.stderr || "");
process.exit(result.status ?? 1);
