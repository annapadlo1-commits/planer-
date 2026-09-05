import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";

const container = process.env.AUD014_LOCAL_DB_CONTAINER ??
  "supabase_db_aud003-local-db-20260903";
assert.match(
  container,
  /^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/u,
  "Nieprawidłowa nazwa lokalnego kontenera Docker",
);

const sql = await readFile(
  new URL("./benchmark-evidence-backed-fk-indexes.sql", import.meta.url),
  "utf8",
);
const run = spawnSync(
  "docker",
  ["exec", "-i", container, "psql", "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres"],
  { input: sql, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
);

if (run.error) throw run.error;
if (run.status !== 0) {
  process.stderr.write(run.stderr);
  process.stdout.write(run.stdout);
  process.exit(run.status ?? 1);
}

const rows = run.stdout
  .split(/\r?\n/u)
  .filter((line) => line.startsWith("{"))
  .map((line) => JSON.parse(line));

assert.equal(rows.length, 54, "benchmark musi zwrócić pełne 3×3×2×3");
assert.deepEqual(
  [...new Set(rows.map((row) => row.scale))],
  [1000, 100000, 1000000],
);
assert.deepEqual(
  [...new Set(rows.map((row) => row.repetitions))],
  [5],
);

for (const row of rows) {
  assert.ok(Number.isFinite(row.medianMs) && row.medianMs >= 0);
  assert.ok(Number.isFinite(row.minMs) && row.minMs >= 0);
  assert.ok(Number.isFinite(row.maxMs) && row.maxMs >= row.minMs);
}

const planEvidence = rows
  .filter((row) => row.operation === "read")
  .map((row) => {
    const planText = JSON.stringify(row.readPlan);
    const scanKinds = [];
    const visit = (value) => {
      if (Array.isArray(value)) {
        value.forEach(visit);
      } else if (value && typeof value === "object") {
        if (typeof value["Node Type"] === "string" && value["Node Type"].endsWith("Scan")) {
          scanKinds.push(value["Node Type"]);
        }
        Object.values(value).forEach(visit);
      }
    };
    visit(row.readPlan);
    return {
      scenario: row.scenario,
      scale: row.scale,
      phase: row.phase,
      usesBenchmarkIndex: planText.includes("aud014_child_fk_idx"),
      scanKinds: [...new Set(scanKinds)],
    };
  });
const comparisons = rows
  .filter((row) => row.phase === "before")
  .map((before) => {
    const after = rows.find((row) =>
      row.scenario === before.scenario &&
      row.scale === before.scale &&
      row.operation === before.operation &&
      row.phase === "after",
    );
    assert.ok(after, "brak wyniku after dla próbki before");
    return {
      scenario: before.scenario,
      scale: before.scale,
      operation: before.operation,
      evidenceRows: before.evidenceRows,
      beforeMedianMs: before.medianMs,
      afterMedianMs: after.medianMs,
      speedup: after.medianMs === 0
        ? null
        : Number((before.medianMs / after.medianMs).toFixed(3)),
    };
  });

process.stdout.write(`${JSON.stringify({
  evidence: "AUD-2026-09-01-014",
  executionBoundary: "local-docker-unix-socket",
  persistentChanges: false,
  container,
  comparisons,
  planEvidence,
}, null, 2)}\n`);
