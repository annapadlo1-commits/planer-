import { spawnSync } from "node:child_process";

const normalizeCrlf = value => Buffer.from(value.toString("utf8").replace(/\r\n/gu, "\n"), "utf8");

export const canonicalGitBytes = (repoPath, worktreeBytes) => {
  const result = spawnSync("git", ["show", `HEAD:${repoPath}`], {
    encoding: null,
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.status !== 0) {
    throw new Error(`Cannot read canonical Git blob ${repoPath}: ${result.stderr?.toString("utf8").trim()}`);
  }

  const canonical = Buffer.from(result.stdout);
  const working = Buffer.from(worktreeBytes);
  if (!working.equals(canonical) && !normalizeCrlf(working).equals(canonical)) {
    throw new Error(`Worktree content differs from canonical Git blob beyond CRLF: ${repoPath}`);
  }
  return canonical;
};

export const canonicalGitText = (repoPath, worktreeBytes) =>
  canonicalGitBytes(repoPath, worktreeBytes).toString("utf8");
