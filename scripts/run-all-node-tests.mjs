import { readdirSync } from "node:fs";
import { spawnSync } from "node:child_process";

const files = readdirSync(new URL("../tests/", import.meta.url))
  .filter((name) => name.endsWith(".mjs"))
  .sort()
  .map((name) => `tests/${name}`);

const result = spawnSync(
  process.execPath,
  ["--experimental-strip-types", "--test", ...files],
  { cwd: new URL("../", import.meta.url), stdio: "inherit" },
);
process.exit(result.status ?? 1);
