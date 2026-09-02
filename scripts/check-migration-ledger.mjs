import { createHash } from "node:crypto";
import { readFile, readdir, writeFile } from "node:fs/promises";
import path from "node:path";

const UAT_PROJECT_REF = "nhthrtpkfpmufmrmdyjg";
const CANONICAL_BASE_SHA = "c0b6c4aba5419651992dc931fcd890e5a3439a5d";

function option(name, fallback = null) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : fallback;
}

const root = process.cwd();
const migrationDir = path.resolve(root, option("--migration-dir", "supabase/migrations"));
const manifestPath = path.resolve(root, option("--manifest", "supabase/migrations/ledger.manifest.json"));
const catalogPath = option("--catalog");
const writeMode = process.argv.includes("--write");

function canonicalBytes(buffer) {
  return Buffer.from(buffer.toString("utf8").replaceAll("\r\n", "\n"), "utf8");
}

function digest(algorithm, bytes) {
  return createHash(algorithm).update(bytes).digest("hex");
}

function gitBlobSha1(bytes) {
  const header = Buffer.from(`blob ${bytes.length}\0`, "utf8");
  return digest("sha1", Buffer.concat([header, bytes]));
}

function parseMigrationName(file) {
  const match = file.match(/^(\d{4}|\d{14})_([a-z0-9_]+)\.sql$/u);
  if (!match) throw new Error(`MIGRATION_FILENAME_INVALID:${file}`);
  return { version: match[1], name: match[2] };
}

async function buildManifest() {
  const files = (await readdir(migrationDir))
    .filter((file) => file.endsWith(".sql"))
    .sort((left, right) => left.localeCompare(right, "en"));
  const seenVersions = new Set();
  const entries = [];
  for (const file of files) {
    const { version, name } = parseMigrationName(file);
    if (seenVersions.has(version)) throw new Error(`MIGRATION_VERSION_DUPLICATE:${version}`);
    seenVersions.add(version);
    const bytes = canonicalBytes(await readFile(path.join(migrationDir, file)));
    entries.push({
      version,
      name,
      file,
      canonicalBytes: bytes.length,
      canonicalSha256: digest("sha256", bytes),
      gitBlobSha1: gitBlobSha1(bytes),
    });
  }
  const aggregateInput = entries
    .map((entry) => `${entry.version}:${entry.name}:${entry.canonicalSha256}`)
    .join("\n");
  return {
    schemaVersion: 1,
    projectRef: UAT_PROJECT_REF,
    canonicalBaseSha: CANONICAL_BASE_SHA,
    canonicalization: "UTF-8 with CRLF normalized to LF",
    aggregateSha256: digest("sha256", Buffer.from(aggregateInput, "utf8")),
    entries,
  };
}

function normalizedCatalogRows(payload) {
  const projectRef = String(payload.projectRef ?? payload.project_ref ?? "");
  if (projectRef !== UAT_PROJECT_REF) throw new Error(`REFUSING_NON_UAT_CATALOG:${projectRef || "MISSING"}`);
  const rows = Array.isArray(payload.rows) ? payload.rows : payload.migrations;
  if (!Array.isArray(rows)) throw new Error("MIGRATION_CATALOG_ROWS_MISSING");
  return rows.map((row) => ({
    version: String(row.version ?? row.timestamp ?? ""),
    name: String(row.name ?? ""),
  }));
}

function compareCatalog(manifest, payload) {
  const live = normalizedCatalogRows(payload);
  const sourceByVersion = new Map(manifest.entries.map((entry) => [entry.version, entry]));
  const liveByVersion = new Map(live.map((entry) => [entry.version, entry]));
  const sourceOnly = manifest.entries.filter((entry) => !liveByVersion.has(entry.version)).map((entry) => entry.version);
  const liveOnly = live.filter((entry) => !sourceByVersion.has(entry.version)).map((entry) => entry.version);
  const nameMismatch = live.flatMap((entry) => {
    const source = sourceByVersion.get(entry.version);
    return source && entry.name && entry.name !== source.name
      ? [{ version: entry.version, source: source.name, live: entry.name }]
      : [];
  });
  return { sourceOnly, liveOnly, nameMismatch };
}

const current = await buildManifest();
if (writeMode) {
  await writeFile(manifestPath, `${JSON.stringify(current, null, 2)}\n`, "utf8");
  process.stdout.write(`MIGRATION_LEDGER_WRITTEN ${current.entries.length} ${current.aggregateSha256}\n`);
} else {
  const expected = JSON.parse(await readFile(manifestPath, "utf8"));
  if (JSON.stringify(expected) !== JSON.stringify(current)) {
    throw new Error("MIGRATION_LEDGER_MANIFEST_MISMATCH: run with --write and review every changed entry");
  }
  process.stdout.write(`MIGRATION_LEDGER_MATCHED ${current.entries.length} ${current.aggregateSha256}\n`);
}

if (catalogPath) {
  const comparison = compareCatalog(current, JSON.parse(await readFile(path.resolve(root, catalogPath), "utf8")));
  process.stdout.write(`${JSON.stringify(comparison)}\n`);
  if (comparison.sourceOnly.length || comparison.liveOnly.length || comparison.nameMismatch.length) {
    process.exitCode = 1;
  }
}
