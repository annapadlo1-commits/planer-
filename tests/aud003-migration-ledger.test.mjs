import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = fileURLToPath(new URL("../", import.meta.url));
const script = fileURLToPath(new URL("../scripts/check-migration-ledger.mjs", import.meta.url));
const UAT_REF = "nhthrtpkfpmufmrmdyjg";

function run(cwd, args) {
  return spawnSync(process.execPath, [script, ...args], { cwd, encoding: "utf8" });
}

test("canonical migration ledger has exact immutable hashes", () => {
  const result = run(root, []);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /^MIGRATION_LEDGER_MATCHED \d+ [a-f0-9]{64}$/mu);
});

test("ledger detects changed, missing and additional migration bytes", async () => {
  const temp = await mkdtemp(path.join(tmpdir(), "szafunek-ledger-"));
  try {
    const migrations = path.join(temp, "migrations");
    await import("node:fs/promises").then(({ mkdir }) => mkdir(migrations));
    await writeFile(path.join(migrations, "20260903000000_first.sql"), "select 1;\r\n", "utf8");
    const manifest = path.join(temp, "manifest.json");
    assert.equal(run(root, ["--migration-dir", migrations, "--manifest", manifest, "--write"]).status, 0);
    assert.equal(run(root, ["--migration-dir", migrations, "--manifest", manifest]).status, 0);
    await writeFile(path.join(migrations, "20260903000000_first.sql"), "select 2;\n", "utf8");
    const changed = run(root, ["--migration-dir", migrations, "--manifest", manifest]);
    assert.notEqual(changed.status, 0);
    assert.match(changed.stderr, /MIGRATION_LEDGER_MANIFEST_MISMATCH/u);
    await writeFile(path.join(migrations, "20260903000000_first.sql"), "select 1;\n", "utf8");
    await writeFile(path.join(migrations, "20260903000001_extra.sql"), "select 2;\n", "utf8");
    assert.notEqual(run(root, ["--migration-dir", migrations, "--manifest", manifest]).status, 0);
  } finally {
    await rm(temp, { recursive: true, force: true });
  }
});

test("live comparison fails closed for drift and for a non-UAT project", async () => {
  const manifest = JSON.parse(await readFile(new URL("../supabase/migrations/ledger.manifest.json", import.meta.url), "utf8"));
  const temp = await mkdtemp(path.join(tmpdir(), "szafunek-ledger-live-"));
  try {
    const matching = path.join(temp, "matching.json");
    await writeFile(matching, JSON.stringify({ projectRef: UAT_REF, rows: manifest.entries }), "utf8");
    assert.equal(run(root, ["--catalog", matching]).status, 0);

    const drifted = path.join(temp, "drifted.json");
    await writeFile(drifted, JSON.stringify({
      projectRef: UAT_REF,
      rows: [...manifest.entries.slice(1), { version: "20990101000000", name: "live_only" }],
    }), "utf8");
    const drift = run(root, ["--catalog", drifted]);
    assert.equal(drift.status, 1);
    assert.match(drift.stdout, /sourceOnly/u);
    assert.match(drift.stdout, /liveOnly/u);

    const wrongProject = path.join(temp, "wrong-project.json");
    await writeFile(wrongProject, JSON.stringify({ projectRef: "bdybebzvzapihjdauehg", rows: [] }), "utf8");
    const refused = run(root, ["--catalog", wrongProject]);
    assert.notEqual(refused.status, 0);
    assert.match(refused.stderr, /REFUSING_NON_UAT_CATALOG/u);
  } finally {
    await rm(temp, { recursive: true, force: true });
  }
});
