import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const nextConfig = await readFile(new URL("../next.config.ts", import.meta.url), "utf8");
const libPackage = JSON.parse(await readFile(new URL("../lib/package.json", import.meta.url), "utf8"));

test("Next and Turbopack are rooted at the current application", () => {
  assert.match(nextConfig, /const appRoot = fileURLToPath\(new URL\("\."\s*,\s*import\.meta\.url\)\)/u);
  assert.match(nextConfig, /turbopack:\s*\{\s*root:\s*appRoot/u);
  assert.doesNotMatch(nextConfig, /process\.cwd\(\)|GRAFIK PRO|\.\.[/\\]/u);
});

test("Node treats application library TypeScript as one explicit ESM boundary", () => {
  assert.deepEqual(libPackage, { private: true, type: "module" });
});
