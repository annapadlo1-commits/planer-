import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";

const normalizeCrlf = value => Buffer.from(value.toString("utf8").replace(/\r\n/gu, "\n"), "utf8");

export const canonicalGitBytes = (repoPath, worktreeBytes) => {
  let source = `HEAD:${repoPath}`;
  let archiveEntry;
  if (repoPath.startsWith("supabase/archive/aud003/migrations/")) {
    const manifest = JSON.parse(readFileSync(new URL("../../supabase/archive/aud003/archive.manifest.json", import.meta.url), "utf8"));
    archiveEntry = manifest.entries.find(entry => entry.path === repoPath);
    if (manifest.sourceSha !== "92bc2c8bcbba780d251f5a37a7e56767ecdb6386" || !archiveEntry) throw new Error("ARCHIVE_PROVENANCE_MISSING");
    // Prefer the committed archive blob so a depth-1 CI checkout works. During
    // preparation only, the archive is untracked and the original blob is used.
    const archived = spawnSync("git", ["cat-file", "-e", source], { encoding: null });
    if (archived.status !== 0) source = `${manifest.sourceSha}:${archiveEntry.sourcePath}`;
  }
  const result = spawnSync("git", ["show", source], {
    encoding: null,
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.status !== 0) {
    throw new Error(`Cannot read canonical Git blob ${repoPath}: ${result.stderr?.toString("utf8").trim()}`);
  }

  const canonical = Buffer.from(result.stdout);
  if (archiveEntry && createHash("sha256").update(canonical).digest("hex") !== archiveEntry.sha256) throw new Error("ARCHIVE_SOURCE_HASH_MISMATCH");
  const working = Buffer.from(worktreeBytes);
  if (!working.equals(canonical) && !normalizeCrlf(working).equals(canonical)) {
    throw new Error(`Worktree content differs from canonical Git blob beyond CRLF: ${repoPath}`);
  }
  return canonical;
};

export const canonicalGitText = (repoPath, worktreeBytes) =>
  canonicalGitBytes(repoPath, worktreeBytes).toString("utf8");
