"use strict";
// bin/lib/size-check/git-blobs.js — the git reads of bin/size-check. Every blob of one run goes
// through a single `git cat-file --batch` (newline-named paths one `cat-file blob` each);
// a failed git call throws GitError (rc 3 upstream, which blocks the commit).

const { spawnSync } = require("child_process");

class GitError extends Error {}

function git(args, input) {
  const r = spawnSync("git", args, {
    input: input == null ? "" : input, maxBuffer: 1024 * 1024 * 1024, windowsHide: true,
  });
  if (r.error) throw new GitError(`git ${args[0]}: ${r.error.message}`);
  if (r.status !== 0) throw new GitError(`git ${args.join(" ")}: ${String(r.stderr || "").trim() || "rc=" + r.status}`);
  return r.stdout;
}

function showPrefix() {
  return git(["rev-parse", "--show-prefix"]).toString("utf8").replace(/\r?\n$/, "");
}

function stagedPaths() {
  const out = git(["-c", "core.quotePath=false", "diff", "-z", "--name-only", "--cached", "--diff-filter=ACMRT"]);
  return out.toString("utf8").split("\0").filter((p) => p.length > 0);
}

// A name holding a newline cannot ride the line-based --batch protocol: read it as a
// one-off `cat-file blob <name>` argument. A nonzero exit is a missing object.
function catFileBlobArg(name) {
  const r = spawnSync("git", ["cat-file", "blob", name], { maxBuffer: 1024 * 1024 * 1024, windowsHide: true });
  if (r.error) throw new GitError(`git cat-file blob: ${r.error.message}`);
  return r.status === 0 ? { type: "blob", data: r.stdout } : null;
}

// catFileBatch(names) -> array aligned with names: { type, data } or null for a missing object.
function catFileBatch(allNames) {
  const batchIdx = [];
  allNames.forEach((n, i) => { if (!/[\r\n]/.test(n)) batchIdx.push(i); });
  const result = new Array(allNames.length).fill(null);
  allNames.forEach((n, i) => { if (/[\r\n]/.test(n)) result[i] = catFileBlobArg(n); });
  const parsed = catFileBatchLines(batchIdx.map((i) => allNames[i]));
  batchIdx.forEach((i, k) => { result[i] = parsed[k]; });
  return result;
}

function catFileBatchLines(names) {
  if (names.length === 0) return [];
  const out = git(["cat-file", "--batch"], names.join("\n") + "\n");
  const result = [];
  let pos = 0;
  for (const name of names) {
    const nl = out.indexOf(0x0a, pos);
    if (nl === -1) throw new GitError(`git cat-file --batch: truncated output at ${name}`);
    const header = out.slice(pos, nl).toString("utf8");
    pos = nl + 1;
    const m = /^[0-9a-f]+ (\w+) (\d+)$/.exec(header);
    if (!m) {
      if (/ (missing|ambiguous)$/.test(header)) { result.push(null); continue; }
      throw new GitError(`git cat-file --batch: unexpected header: ${header}`);
    }
    const size = Number(m[2]);
    result.push({ type: m[1], data: out.slice(pos, pos + size) });
    pos += size + 1;
  }
  return result;
}

module.exports = { GitError, showPrefix, stagedPaths, catFileBatch };
