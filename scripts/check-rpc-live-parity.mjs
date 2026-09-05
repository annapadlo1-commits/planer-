import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { assertParity, classifyInventory, compareSourceAndLive } from "./rpc-contract/parity-core.mjs";

const UAT_PROJECT_REF = "nhthrtpkfpmufmrmdyjg";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const argument = (name) => {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : null;
};
const catalogPath = argument("--catalog");
const reportPath = argument("--report");
const markdownPath = argument("--markdown");
if (!catalogPath) throw new Error("Usage: node scripts/check-rpc-live-parity.mjs --catalog <pg_proc.json> [--report <json>] [--markdown <md>]");

const temporary = mkdtempSync(path.join(tmpdir(), "szafunek-rpc-live-"));
function runInventory(script, output) {
  const result = spawnSync(process.execPath, [script, output], { cwd: root, encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(`${script} failed:\n${result.stderr || result.stdout}`);
}
function escapeCell(value) {
  return String(value ?? "").replaceAll("|", "\\|").replaceAll("\n", " ");
}

try {
  const frontendPath = path.join(temporary, "frontend.json");
  const sourcePath = path.join(temporary, "source.json");
  runInventory("scripts/rpc-contract/frontend-runtime-inventory.mjs", frontendPath);
  runInventory("scripts/rpc-contract/migration-source-inventory.mjs", sourcePath);
  const frontend = JSON.parse(readFileSync(frontendPath, "utf8"));
  const source = JSON.parse(readFileSync(sourcePath, "utf8"));
  const catalog = JSON.parse(readFileSync(path.resolve(catalogPath), "utf8"));
  if (catalog.projectRef !== UAT_PROJECT_REF) throw new Error(`Refusing non-UAT catalog: ${catalog.projectRef}`);
  if (!Array.isArray(catalog.rows)) throw new Error("Catalog must contain a rows array");
  if (frontend.unresolved.length) throw new Error(`Unresolved dynamic RPC names: ${JSON.stringify(frontend.unresolved)}`);
  const parity = classifyInventory(frontend.inventory, catalog.rows);
  const drift = compareSourceAndLive(source.inventory, catalog.rows, frontend.inventory.map((rpc) => rpc.name));
  const report = {
    scope: "frontend runtime TypeScript versus live UAT pg_proc/ACL",
    projectRef: catalog.projectRef,
    capturedAt: catalog.capturedAt,
    frontendFilesScanned: frontend.filesScanned,
    frontendUniqueRpc: frontend.uniqueCount,
    frontendCallCount: frontend.callCount,
    liveFunctionRows: catalog.rows.length,
    unresolvedDynamicNames: frontend.unresolved.length,
    counts: parity.counts,
    sourceLiveSignatureDrift: drift,
    matrix: parity.matrix,
  };
  assertParity(parity, "live UAT");
  if (drift.sourceOnly.length || drift.liveOnly.length) {
    throw new Error(`Source/live signature drift:\nsource-only=${JSON.stringify(drift.sourceOnly)}\nlive-only=${JSON.stringify(drift.liveOnly)}`);
  }
  if (reportPath) writeFileSync(path.resolve(reportPath), `${JSON.stringify(report, null, 2)}\n`);
  if (markdownPath) {
    const lines = [
      "# Frontend/live RPC parity — UAT",
      "",
      `Project: \`${catalog.projectRef}\`  `,
      `Captured: \`${catalog.capturedAt}\`  `,
      `Frontend RPC: \`${frontend.uniqueCount}\`; matched: \`${parity.counts.MATCHED}\``,
      "",
      "| RPC | exists | signature | authenticated EXECUTE | anon/PUBLIC EXECUTE | call sites | test references | result |",
      "|---|---:|---:|---:|---:|---|---|---|",
      ...parity.matrix.map((row) => `| ${escapeCell(row.rpc)} | ${row.exists ? "YES" : "NO"} | ${row.signatureMatch ? "PASS" : "FAIL"} | ${row.authenticatedExecute ? "YES" : "NO"} | ${row.anonymousExecute ? "YES" : "NO"} | ${escapeCell(row.callSites.map((site) => `${site.file}:${site.line}`).join("<br>"))} | ${escapeCell(row.testReferences.join("<br>") || "—")} | ${row.classification} |`),
      "",
    ];
    writeFileSync(path.resolve(markdownPath), lines.join("\n"));
  }
  process.stdout.write(`${JSON.stringify({ ...report, matrix: undefined }, null, 2)}\n`);
} finally {
  rmSync(temporary, { recursive: true, force: true });
}
