"use strict";
// hooks/lib/plan-sync/git.js
// Low-level git plumbing shared by provision.js and commit-push.js. Nothing here
// touches the working tree or the main index (.git/index): commits are built in a
// throwaway index under .git/ that is always removed.
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { spawnSync } = require("child_process");

const NULL_DEV = process.platform === "win32" ? "NUL" : "/dev/null";
const DEFAULT_TIMEOUT_MS = 15000;
const MAIN_REF = "refs/heads/main";
const ORIGIN_MAIN_REF = "refs/remotes/origin/main";

// Repository-location variables would redirect git away from plansDir; they are dropped
// so `-C plansDir` is the only thing that picks the repo.
const STRIPPED_ENV = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR"];

// A fixed identity keeps commits independent of the user's git config.
const COMMIT_IDENTITY = Object.freeze({
  GIT_AUTHOR_NAME: "plan-sync",
  GIT_AUTHOR_EMAIL: "plan-sync@localhost",
  GIT_COMMITTER_NAME: "plan-sync",
  GIT_COMMITTER_EMAIL: "plan-sync@localhost",
});

function buildEnv(extra) {
  const env = Object.assign({}, process.env);
  for (const k of STRIPPED_ENV) delete env[k];
  env.GIT_TERMINAL_PROMPT = "0";
  return Object.assign(env, extra || {});
}

// runGit(plansDir, args, {deadline, env, input, timeoutMs}) -> {status, stdout, stderr, timedOut}
function runGit(plansDir, args, opts) {
  const o = opts || {};
  let timeout = o.timeoutMs || DEFAULT_TIMEOUT_MS;
  if (o.deadline) timeout = Math.min(timeout, o.deadline - Date.now());
  if (timeout <= 0) return { status: null, stdout: "", stderr: "plan-sync: budget exhausted", timedOut: true };
  const argv = ["-C", plansDir, "-c", `core.hooksPath=${NULL_DEV}`, "-c", "core.fsmonitor=false", ...args];
  const r = spawnSync("git", argv, {
    encoding: "utf8",
    windowsHide: true,
    env: buildEnv(o.env),
    input: o.input,
    timeout,
    maxBuffer: 16 * 1024 * 1024,
  });
  const timedOut = Boolean(r.error && r.error.code === "ETIMEDOUT");
  return {
    status: r.status,
    stdout: r.stdout || "",
    stderr: r.stderr || (r.error && !timedOut ? String(r.error.message) : ""),
    timedOut,
  };
}

function gitOut(plansDir, args, opts) {
  const r = runGit(plansDir, args, opts);
  return r.status === 0 ? r.stdout.replace(/\r?\n$/, "") : null;
}

function revParse(plansDir, ref, opts) {
  const v = gitOut(plansDir, ["rev-parse", "--verify", "-q", `${ref}^{commit}`], opts);
  return v || null;
}

function hashObjectWrite(plansDir, absPath, opts) {
  return gitOut(plansDir, ["hash-object", "-w", "--no-filters", "--", absPath], opts);
}

function hashObject(plansDir, absPath, opts) {
  return gitOut(plansDir, ["hash-object", "--no-filters", "--", absPath], opts);
}

// hashBytes writes content (string or Buffer) as a blob; hashBytesId only computes its id.
function hashBytes(plansDir, content, opts) {
  return gitOut(plansDir, ["hash-object", "-w", "--stdin", "--no-filters"], Object.assign({}, opts, { input: content }));
}

function hashBytesId(plansDir, content, opts) {
  return gitOut(plansDir, ["hash-object", "--stdin", "--no-filters"], Object.assign({}, opts, { input: content }));
}

function treeOf(plansDir, commit, opts) {
  return gitOut(plansDir, ["rev-parse", "--verify", "-q", `${commit}^{tree}`], opts);
}

// blobAt(commit, rel) -> sha | null
function blobAt(plansDir, commit, rel, opts) {
  return gitOut(plansDir, ["rev-parse", "--verify", "-q", `${commit}:${rel}`], opts);
}

function isAncestor(plansDir, a, b, opts) {
  return runGit(plansDir, ["merge-base", "--is-ancestor", a, b], opts).status === 0;
}

// overlayCommit(plansDir, base, entries, opts) -> {ok, commit, changed, error?}
// base: commit sha or null (root commit). entries: [{rel, blob}] added or overwritten
// on base's tree; nothing is ever deleted. An unchanged tree returns base itself.
function overlayCommit(plansDir, base, entries, opts) {
  const o = opts || {};
  const idx = path.join(plansDir, ".git", `plansync-index-${process.pid}-${crypto.randomBytes(4).toString("hex")}`);
  const env = Object.assign({}, o.env, { GIT_INDEX_FILE: idx });
  const run = (args, extra) => runGit(plansDir, args, Object.assign({ deadline: o.deadline }, extra, { env }));
  try {
    if (base) {
      const rt = run(["read-tree", base]);
      if (rt.status !== 0) return { ok: false, error: rt.stderr || "read-tree failed" };
    }
    // One update-index for every entry: init can overlay over a thousand plans at once.
    if (entries.some((e) => /[\t\r\n\0]/.test(e.rel))) return { ok: false, error: "unsafe path in entries" };
    if (entries.length > 0) {
      const info = entries.map((e) => `100644 ${e.blob}\t${e.rel}\n`).join("");
      const up = run(["update-index", "--add", "--index-info"], { input: info });
      if (up.status !== 0) return { ok: false, error: up.stderr || "update-index failed" };
    }
    const wt = run(["write-tree"]);
    if (wt.status !== 0) return { ok: false, error: wt.stderr || "write-tree failed" };
    const tree = wt.stdout.trim();
    if (base && treeOf(plansDir, base, { deadline: o.deadline }) === tree) {
      return { ok: true, commit: base, changed: false };
    }
    const args = ["commit-tree", tree];
    if (base) args.push("-p", base);
    args.push("-m", o.message || "plan-sync");
    const ct = runGit(plansDir, args, { deadline: o.deadline, env: Object.assign({}, COMMIT_IDENTITY) });
    if (ct.status !== 0) return { ok: false, error: ct.stderr || "commit-tree failed" };
    return { ok: true, commit: ct.stdout.trim(), changed: true };
  } finally {
    try { fs.unlinkSync(idx); } catch (_) { /* never created */ }
    try { fs.unlinkSync(`${idx}.lock`); } catch (_) { /* never created */ }
  }
}

// casUpdate(plansDir, ref, newSha, oldSha|null) — compare-and-swap; null old means "must not exist".
function casUpdate(plansDir, ref, newSha, oldSha, opts) {
  const old = oldSha || "";
  return runGit(plansDir, ["update-ref", "-m", "plan-sync", ref, newSha, old], opts).status === 0;
}

function setRef(plansDir, ref, sha, opts) {
  return runGit(plansDir, ["update-ref", "-m", "plan-sync", ref, sha], opts).status === 0;
}

const PUSH_TIMEOUT_MS = 15000;

// opts.transferTimeoutMs lifts the per-write cap for init, whose first push carries every plan.
function transferOpts(opts) {
  return Object.assign({}, opts, { timeoutMs: (opts && opts.transferTimeoutMs) || PUSH_TIMEOUT_MS });
}

function pushMain(plansDir, opts) {
  return runGit(plansDir, ["push", "--no-verify", "origin", `${MAIN_REF}:${MAIN_REF}`], transferOpts(opts));
}

function fetchMain(plansDir, opts) {
  return runGit(plansDir, ["fetch", "--no-tags", "--no-write-fetch-head", "origin", `+${MAIN_REF}:${ORIGIN_MAIN_REF}`],
    transferOpts(opts));
}

// blobIdOf(bytes) — the SHA-1 object id git assigns to bytes as a blob.
function blobIdOf(bytes) {
  return crypto.createHash("sha1").update(`blob ${bytes.length}\0`).update(bytes).digest("hex");
}

// hashFiles(plansDir, rels, opts) -> [sha] | null — writes every file as a blob in one git call.
function hashFiles(plansDir, rels, opts) {
  if (rels.length === 0) return [];
  if (rels.some((r) => /[\r\n\0]/.test(r))) return null;
  const out = gitOut(plansDir, ["hash-object", "-w", "--no-filters", "--stdin-paths"],
    Object.assign({}, opts, { input: rels.join("\n") + "\n" }));
  if (out === null) return null;
  const shas = out.split(/\r?\n/);
  return shas.length === rels.length ? shas : null;
}

function isNonFastForward(r) {
  return /non-fast-forward|fetch first|\[rejected\]|rejected/i.test(r.stderr || "");
}

// classifyFailure(r) — short fixed vocabulary for a failed network git call.
function classifyFailure(r) {
  if (r.timedOut) return "push-timeout";
  const s = r.stderr || "";
  if (isNonFastForward(r)) return "push-rejected";
  if (/permission denied|authentication failed|could not read (username|password)|publickey|403/i.test(s)) return "auth";
  if (/could not resolve|connection refused|network is unreachable|timed out|unable to access|connection reset|no route to host/i.test(s)) {
    return "offline";
  }
  return "push-failed";
}

// Only regular-file modes are carried: a symlink (120000) or gitlink (160000) entry would
// publish link text or be rewritten to 100644 by overlayCommit.
const REGULAR_MODES = new Set(["100644", "100755"]);

// localOnlyEntries(plansDir, remote, local, keep, opts) -> [{rel, blob}]
// Regular-file paths added or modified on the local side since the merge base (three-dot),
// filtered by keep(rel), with their blobs from local's tree. No merge base -> [].
function localOnlyEntries(plansDir, remote, local, keep, opts) {
  if (!remote || !local) return [];
  const mb = gitOut(plansDir, ["merge-base", remote, local], opts);
  if (!mb) return [];
  const raw = gitOut(plansDir, ["diff-tree", "-r", "--no-renames", "--no-abbrev", "--diff-filter=AM", "-z", mb, local], opts);
  if (raw === null) return [];
  const parts = raw.split("\0");
  const out = [];
  for (let i = 0; i + 1 < parts.length; i += 2) {
    const m = parts[i].match(/^:\d+ (\d+) [0-9a-f]+ ([0-9a-f]+) [AM]$/);
    const rel = parts[i + 1];
    if (m && rel && REGULAR_MODES.has(m[1]) && keep(rel)) out.push({ rel, blob: m[2] });
  }
  return out;
}

// treeEntries(plansDir, commit, keep, opts) -> [{rel, blob}] of commit's top-level regular-file blobs kept by keep(rel).
function treeEntries(plansDir, commit, keep, opts) {
  const raw = gitOut(plansDir, ["ls-tree", "-z", commit], opts);
  if (raw === null) return [];
  const out = [];
  for (const line of raw.split("\0").filter(Boolean)) {
    const m = line.match(/^(\d+) blob ([0-9a-f]+)\t(.+)$/);
    if (m && REGULAR_MODES.has(m[1]) && keep(m[3])) out.push({ rel: m[3], blob: m[2] });
  }
  return out;
}

// carriedEntries(plansDir, remote, local, keep, opts) -> [{rel, blob}] — the local-side
// entries a commit built on the remote tip must carry: the three-dot local-only paths, or
// every top-level entry of local when the two histories share no merge base. Always keep-filtered,
// so whatever else local main tracks never reaches a published tree.
function carriedEntries(plansDir, remote, local, keep, opts) {
  if (!local) return [];
  if (!remote || !gitOut(plansDir, ["merge-base", remote, local], opts)) return treeEntries(plansDir, local, keep, opts);
  return localOnlyEntries(plansDir, remote, local, keep, opts);
}

// mergeEntries(primary, rest) — primary wins on a duplicate path.
function mergeEntries(primary, rest) {
  const seen = new Set(primary.map((e) => e.rel));
  return primary.concat(rest.filter((e) => !seen.has(e.rel)));
}

module.exports = {
  NULL_DEV,
  MAIN_REF,
  ORIGIN_MAIN_REF,
  runGit,
  gitOut,
  revParse,
  hashObject,
  hashObjectWrite,
  hashBytes,
  hashBytesId,
  blobAt,
  isAncestor,
  overlayCommit,
  casUpdate,
  setRef,
  pushMain,
  fetchMain,
  blobIdOf,
  hashFiles,
  isNonFastForward,
  classifyFailure,
  localOnlyEntries,
  treeEntries,
  carriedEntries,
  mergeEntries,
};
