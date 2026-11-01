"use strict";
// Tests: hooks/lib/merge-parents.js
// Tags: TL2, hooks, merge, merge-parents, scope:issue-specific
// Test-only scaffolding for tests/hooks/feat-2812-merge-parents.js. Holds no cases.
// Builds fixture repos (core.hooksPath=/dev/null, core.autocrlf=false) in uncommitted merge states,
// reads the expected oids with plain git, and loads the modules under test through a guarded require
// so a module that does not exist yet becomes one FAIL per case instead of ending the file.

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { gitInit } = require("../../lib/harness");
const M = require("../feat-2761-glossary-merge/fixture");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const slash = (p) => String(p).replace(/\\/g, "/");

let failures = 0;
const clip = (s) => String(s).replace(/\s+/g, " ").slice(0, 600);
function check(name, ok, detail) {
  if (ok) {
    console.log(`PASS ${name}`);
    return true;
  }
  failures += 1;
  console.log(`FAIL ${name} :: ${clip(detail)}`);
  return false;
}
function finish() {
  console.log(failures === 0 ? "ALL PASS" : `${failures} FAILED`);
}
const failureCount = () => failures;
const guarded = (name, fn) => M.guarded(check, name, fn);

const cache = {};
// The module at rel (relative to the checkout root), or null with one FAIL while it is missing.
function mod(label, rel) {
  if (!(rel in cache)) {
    try {
      cache[rel] = require(path.join(ROOT, rel));
    } catch (e) {
      cache[rel] = { loadError: e.code || e.message };
    }
  }
  if (cache[rel].loadError) {
    check(`${label}: ${rel} loads`, false, cache[rel].loadError);
    return null;
  }
  return cache[rel];
}

const git = (repo, args, allowFail) => M.git(repo, args, allowFail);
const oid = (repo, spec) => {
  const r = git(repo, ["rev-parse", "-q", "--verify", spec], true);
  return r.status === 0 ? r.stdout.trim() : "";
};
const mergeBase = (repo) => git(repo, ["merge-base", "--all", "HEAD", "MERGE_HEAD"], true).stdout.split(/\r?\n/).filter(Boolean);

function mkRepo(tag, files) {
  const dir = slash(fs.mkdtempSync(path.join(os.tmpdir(), `mp2812-${tag}-`)));
  gitInit(dir);
  git(dir, ["config", "core.autocrlf", "false"]);
  M.commitAll(dir, Object.assign({ "README.md": "# fixture\n" }, files || {}), "fixture: base");
  return dir;
}

// One merge holding a path for every rule of D2 (R7 needs a criss-cross: crissCross below).
// rN.txt is the path that must land on rule N; r5nb / r6nb have no merge-base blob.
function allRules(tag) {
  const repo = mkRepo(tag, {
    "r1h.txt": "base r1h\n", "r5.txt": "base r5\n", "r6.txt": "l1\nl2\nl3\nl4\nl5\n", "mode.sh": "#!/bin/sh\nexit 0\n",
  });
  const fx = M.startMerge(repo, {
    upstream: {
      "r1m.txt": "only in MERGE_HEAD\n", "r4.txt": "m4\n", "r5.txt": "same r5\n", "r5nb.txt": "same r5nb\n",
      "r6.txt": "L1\nl2\nl3\nl4\nl5\n", "r6nb.txt": "upstream r6nb\n",
    },
    branch: {
      "r3.txt": "b3\n", "r5.txt": "same r5\n", "r5nb.txt": "same r5nb\n", "r6.txt": "l1\nl2\nl3\nl4\nL5\n", "r6nb.txt": "branch r6nb\n",
    },
    resolve: {
      "r3.txt": "b3 edited in the merge\n", "r4.txt": "m4 edited in the merge\n", "r5.txt": "same r5 edited\n",
      "r5nb.txt": "same r5nb edited\n", "r6.txt": "L1\nl2\nl3\nl4\nL5\nextra\n", "r6nb.txt": "resolved r6nb\n",
      "r2.txt": "new in the merge\n",
    },
  });
  git(repo, ["update-index", "--chmod=+x", "--", "mode.sh"]);
  return Object.assign({ repo }, fx);
}

// Only H = M paths (with and without a merge-base blob) and S = parent paths: no merge-base needed.
function identicalOnly(tag) {
  const repo = mkRepo(tag, { "same.txt": "base\n", "keep.txt": "keep\n" });
  M.startMerge(repo, {
    upstream: { "same.txt": "same\n", "nb.txt": "same nb\n", "up.txt": "up\n" },
    branch: { "same.txt": "same\n", "nb.txt": "same nb\n" },
    resolve: { "same.txt": "same edited\n", "nb.txt": "same nb edited\n" },
  });
  return repo;
}

// Two merge-bases (x1, y1), then a merge of the two criss-crossed tips: cc-diff.txt has H != M
// (R7), cc-same.txt has H = M (R5 even here).
function crissCross(tag) {
  const repo = mkRepo(tag, { "cc-diff.txt": "base\n", "cc-same.txt": "base\n" });
  const id = (args) => git(repo, M.IDENT.concat(args));
  git(repo, ["branch", "ccy"]);
  git(repo, ["checkout", "-q", "-b", "ccx"]);
  M.commitAll(repo, { "x.txt": "x\n" }, "fixture: x1");
  const x1 = oid(repo, "HEAD");
  git(repo, ["checkout", "-q", "ccy"]);
  M.commitAll(repo, { "y.txt": "y\n" }, "fixture: y1");
  const y1 = oid(repo, "HEAD");
  git(repo, ["checkout", "-q", "ccx"]);
  id(["merge", "-q", "--no-ff", "-m", "fixture: mx", y1]);
  git(repo, ["checkout", "-q", "ccy"]);
  id(["merge", "-q", "--no-ff", "-m", "fixture: my", x1]);
  M.commitAll(repo, { "cc-diff.txt": "y side\n", "cc-same.txt": "same\n" }, "fixture: y2");
  git(repo, ["checkout", "-q", "ccx"]);
  M.commitAll(repo, { "cc-diff.txt": "x side\n", "cc-same.txt": "same\n" }, "fixture: x2");
  const m = git(repo, M.IDENT.concat(["merge", "--no-commit", "--no-ff", "ccy"]), true);
  if (m.error || (m.status !== 0 && m.status !== 1)) throw new Error(`criss-cross merge failed: ${m.stderr}`);
  M.apply(repo, { "cc-diff.txt": "resolved\n", "cc-same.txt": "same edited\n" });
  return repo;
}

// resolveMergeParents through the in-process module; null (with a FAIL) while it is missing.
function resolve(label, repo, paths) {
  const m = mod(label, "hooks/lib/merge-parents.js");
  if (!m) return null;
  try {
    return m.resolveMergeParents(repo, paths);
  } catch (e) {
    check(`${label}: resolveMergeParents does not throw`, false, (e && e.stack) || e);
    return null;
  }
}

// A record in a comparable shape: numbers for the flags, "" for an absent oid ("-" in the CLI).
const blank = (v) => (v === undefined || v === null || v === "-" ? "" : String(v));
function norm(rec) {
  if (!rec) return null;
  const flag = (a, b) => Number(rec[a] !== undefined ? rec[a] : rec[b]);
  return { in_parent: flag("in_parent", "inParent"), same: flag("same", "same"), b1: blank(rec.b1), b2: blank(rec.b2), base: blank(rec.base) };
}
const show = (v) => JSON.stringify(v);

// node bin/merge-parents [--repo <repo>] with NUL-separated paths on stdin.
function cli(args, paths, env) {
  const r = spawnSync(process.execPath, [path.join(ROOT, "bin", "merge-parents")].concat(args), {
    cwd: os.tmpdir(), input: Buffer.from(paths.map((p) => `${p}\0`).join(""), "utf8"), timeout: 60000,
    env: Object.assign({}, process.env, env || {}),
  });
  return { code: r.status, out: r.stdout ? r.stdout.toString("utf8") : "", err: (r.stderr ? r.stderr.toString("utf8") : "") + (r.error ? String(r.error) : "") };
}
// → { header: [..], records: [{ fields: [..], path }] } or null when the record stream is malformed.
function parseCli(out) {
  const parts = out.split("\0");
  if (parts[parts.length - 1] !== "") return null;
  parts.pop();
  if (parts.length === 0 || (parts.length - 1) % 2 !== 0) return null;
  const records = [];
  for (let i = 1; i < parts.length; i += 2) records.push({ fields: parts[i].split("\t"), path: parts[i + 1] });
  return { header: parts[0].split("\t"), records };
}

// Runs fn with GIT_TRACE pointed at a fresh file; → the trace text (empty when nothing ran).
function traced(fn) {
  const file = slash(path.join(fs.mkdtempSync(path.join(os.tmpdir(), "mp2812-trace-")), "trace.log"));
  const saved = process.env.GIT_TRACE;
  process.env.GIT_TRACE = file;
  let value;
  try {
    value = fn();
  } finally {
    if (saved === undefined) delete process.env.GIT_TRACE;
    else process.env.GIT_TRACE = saved;
  }
  return { value, trace: fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "" };
}
const ranMergeBase = (trace) => /\bgit(?:\.exe)?\b[^\n]*\bmerge-base\b/.test(trace) || /built-in: git merge-base/.test(trace);

module.exports = {
  ROOT, M, slash, check, finish, failureCount, guarded, mod, git, oid, mergeBase, mkRepo, allRules, identicalOnly, crissCross,
  resolve, norm, show, cli, parseCli, traced, ranMergeBase,
};
