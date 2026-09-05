import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { assertParity, classifyInventory } from "./rpc-contract/parity-core.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const reportPathIndex = process.argv.indexOf("--report");
const reportPath = reportPathIndex >= 0 ? path.resolve(process.argv[reportPathIndex + 1]) : null;
const temporary = mkdtempSync(path.join(tmpdir(), "szafunek-rpc-source-"));

function runInventory(script, output) {
  const result = spawnSync(process.execPath, [script, output], { cwd: root, encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(`${script} failed:\n${result.stderr || result.stdout}`);
}

try {
  const frontendPath = path.join(temporary, "frontend.json");
  const sourcePath = path.join(temporary, "source.json");
  runInventory("scripts/rpc-contract/frontend-runtime-inventory.mjs", frontendPath);
  runInventory("scripts/rpc-contract/migration-source-inventory.mjs", sourcePath);
  const frontend = JSON.parse(readFileSync(frontendPath, "utf8"));
  const source = JSON.parse(readFileSync(sourcePath, "utf8"));
  if (frontend.unresolved.length) throw new Error(`Unresolved dynamic RPC names: ${JSON.stringify(frontend.unresolved)}`);
  const parity = classifyInventory(frontend.inventory, source.inventory);
  const report = {
    scope: "frontend runtime TypeScript versus ordered canonical migration DDL",
    frontendFilesScanned: frontend.filesScanned,
    frontendUniqueRpc: frontend.uniqueCount,
    frontendCallCount: frontend.callCount,
    migrationFiles: source.migrationFiles,
    functionOverloads: source.functionOverloads,
    unresolvedDynamicNames: frontend.unresolved.length,
    counts: parity.counts,
    matrix: parity.matrix,
  };
  assertParity(parity, "source");
  if (reportPath) writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
  process.stdout.write(`${JSON.stringify({ ...report, matrix: undefined }, null, 2)}\n`);
} finally {
  rmSync(temporary, { recursive: true, force: true });
}
