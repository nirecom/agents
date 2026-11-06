"use strict";
// Git plumbing for the session-sync engine (#2658): trees, blobs and refs only, never rebase or merge.

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { runGit, buildEnv, casUpdate, isNonFastForward } = require("../../../hooks/lib/plan-sync/git.js");

const LONG_MS = 600000;
const MAIN = "refs/heads/main";
const ORIGIN = "refs/remotes/origin/main";
const NULL_DEV = process.platform === "win32" ? "NUL" : "/dev/null";
const EMPTY_TREE_INPUT = "";

function git(dir, args, opts) {
  return runGit(dir, args, Object.assign({ timeoutMs: LONG_MS }, opts));
}

function gitOut(dir, args, opts) {
  const r = git(dir, args, opts);
  return r.status === 0 ? r.stdout.replace(/\r?\n$/, "") : null;
}

function revParse(dir, ref) {
  return gitOut(dir, ["rev-parse", "--verify", "-q", `${ref}^{commit}`]) || null;
}

function treeOf(dir, commit) {
  return commit ? gitOut(dir, ["rev-parse", "--verify", "-q", `${commit}^{tree}`]) : null;
}

function emptyTree(dir) {
  return gitOut(dir, ["hash-object", "-w", "-t", "tree", "--stdin"], { input: EMPTY_TREE_INPUT });
}

// catBlob(dir, sha) -> Buffer; spawned directly so a large transcript is not cut by a buffer cap.
function catBlob(dir, sha) {
  const r = spawnSync("git", ["-C", dir, "cat-file", "blob", sha], {
    env: buildEnv(), windowsHide: true, maxBuffer: 1024 * 1024 * 1024,
  });
  if (r.status !== 0) throw new Error(`cat-file ${sha} failed: ${String(r.stderr || r.error || "")}`);
  return r.stdout;
}

function blobIdOf(bytes) {
  return crypto.createHash("sha1").update(`blob ${bytes.length}\0`).update(bytes).digest("hex");
}

function hashText(dir, content) {
  const r = spawnSync("git", ["-C", dir, "hash-object", "-w", "--no-filters", "--stdin"], {
    env: buildEnv(), windowsHide: true, input: content, maxBuffer: 1024 * 1024,
  });
  if (r.status !== 0) throw new Error(`hash-object failed: ${String(r.stderr || "")}`);
  return String(r.stdout).trim();
}

function hashPaths(dir, rels) {
  if (rels.length === 0) return [];
  const out = gitOut(dir, ["hash-object", "-w", "--stdin-paths"], { input: rels.join("\n") + "\n" });
  if (out === null) throw new Error("hash-object --stdin-paths failed");
  const shas = out.split(/\r?\n/);
  if (shas.length !== rels.length) throw new Error("hash-object returned a short list");
  return shas;
}

// lsTree(dir, commit) -> Map rel -> {mode, blob}
function lsTree(dir, commit) {
  const map = new Map();
  if (!commit) return map;
  const raw = gitOut(dir, ["ls-tree", "-r", "-z", "--full-tree", commit]);
  if (raw === null) throw new Error(`ls-tree ${commit} failed`);
  for (const rec of raw.split("\0")) {
    const m = rec.match(/^(\d+) \w+ ([0-9a-f]+)\t([\s\S]+)$/);
    if (m) map.set(m[3], { mode: m[1], blob: m[2] });
  }
  return map;
}

// diffTree(dir, a, b) -> Map rel -> {status, oldBlob, newBlob, mode}
function diffTree(dir, a, b) {
  const map = new Map();
  const raw = gitOut(dir, ["diff-tree", "-r", "-z", "--no-renames", "--no-abbrev", a, b]);
  if (raw === null) throw new Error(`diff-tree ${a} ${b} failed`);
  const parts = raw.split("\0");
  for (let i = 0; i + 1 < parts.length; i += 2) {
    const m = parts[i].match(/^:(\d+) (\d+) ([0-9a-f]+) ([0-9a-f]+) ([A-Z])/);
    if (!m) continue;
    const zero = /^0+$/;
    map.set(parts[i + 1], {
      status: m[5], mode: m[2],
      oldBlob: zero.test(m[3]) ? null : m[3], newBlob: zero.test(m[4]) ? null : m[4],
    });
  }
  return map;
}

function setIndex(dir, commit) {
  const r = commit ? git(dir, ["read-tree", "-m", commit]) : git(dir, ["read-tree", "--empty"]);
  if (r.status === 0) return;
  const again = git(dir, ["read-tree", commit]);
  if (again.status !== 0) throw new Error(`read-tree failed: ${again.stderr}`);
}

// writeTree(dir, base, delta) -> tree sha; delta: Map rel -> {mode, blob} | null (removed).
function writeTree(dir, base, delta) {
  const idx = path.join(dir, ".git", `session-sync-index-${process.pid}-${crypto.randomBytes(4).toString("hex")}`);
  const env = { GIT_INDEX_FILE: idx };
  try {
    const rt = base ? git(dir, ["read-tree", base], { env }) : git(dir, ["read-tree", "--empty"], { env });
    if (rt.status !== 0) throw new Error(`read-tree failed: ${rt.stderr}`);
    const zero = "0".repeat(40);
    const info = [...delta].map(([rel, e]) => (e ? `${e.mode} ${e.blob}\t${rel}\n` : `0 ${zero}\t${rel}\n`)).join("");
    if (info) {
      const up = git(dir, ["update-index", "--add", "--remove", "--index-info"], { env, input: info });
      if (up.status !== 0) throw new Error(`update-index failed: ${up.stderr}`);
    }
    const wt = git(dir, ["write-tree"], { env });
    if (wt.status !== 0) throw new Error(`write-tree failed: ${wt.stderr}`);
    return wt.stdout.trim();
  } finally {
    for (const f of [idx, `${idx}.lock`]) fs.rmSync(f, { force: true });
  }
}

const FALLBACK_IDENTITY = {
  GIT_AUTHOR_NAME: "session-sync", GIT_AUTHOR_EMAIL: "session-sync@localhost",
  GIT_COMMITTER_NAME: "session-sync", GIT_COMMITTER_EMAIL: "session-sync@localhost",
};

// commitTree uses the user's git identity; a clone with none configured gets a fixed one.
function commitTree(dir, tree, parent, message) {
  const args = ["commit-tree", tree, ...(parent ? ["-p", parent] : []), "-m", message];
  let r = git(dir, args);
  if (r.status !== 0 && /tell me who you are|identity|empty ident/i.test(r.stderr)) {
    r = git(dir, args, { env: FALLBACK_IDENTITY });
  }
  if (r.status !== 0) throw new Error(`commit-tree failed: ${r.stderr}`);
  return r.stdout.trim();
}

function isAncestor(dir, a, b) {
  return git(dir, ["merge-base", "--is-ancestor", a, b]).status === 0;
}

function mergeBase(dir, a, b) {
  return a && b ? gitOut(dir, ["merge-base", a, b]) : null;
}

function fetchArgs() {
  return ["fetch", "--no-tags", "--no-write-fetch-head", "origin", `+${MAIN}:${ORIGIN}`];
}

function fetch(dir) {
  return git(dir, fetchArgs());
}

function push(dir, commit) {
  return git(dir, ["push", "--no-verify", "origin", `${commit}:${MAIN}`]);
}

// ensureUpstream keeps plain `git push` / `git pull` working in the clone, as `push -u` once did.
function ensureUpstream(dir) {
  if (gitOut(dir, ["config", "--get", "branch.main.merge"])) return;
  git(dir, ["config", "branch.main.remote", "origin"]);
  git(dir, ["config", "branch.main.merge", MAIN]);
}

const OFFLINE =/could not resolve|connection refused|network is unreachable|timed out|unable to access|connection reset|no route to host|connection closed|could not read from remote/i;

function failureKind(r) {
  if (r.timedOut) return "timeout";
  return OFFLINE.test(r.stderr || "") ? "offline" : "failed";
}

function remoteTimeMs(dir, rev, rel) {
  const out = gitOut(dir, ["log", "-1", "--format=%ct", rev, "--", rel]);
  return out ? Number(out) * 1000 : 0;
}

module.exports = {
  MAIN, ORIGIN, NULL_DEV, LONG_MS, git, gitOut, revParse, treeOf, emptyTree, catBlob, blobIdOf,
  hashText, hashPaths, lsTree, diffTree, setIndex, writeTree, commitTree, isAncestor, mergeBase,
  fetchArgs, fetch, push, ensureUpstream, failureKind, remoteTimeMs, casUpdate, isNonFastForward, buildEnv,
};
