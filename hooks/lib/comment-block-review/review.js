"use strict";
// Comment-block size review (#2507, ported from bin/review-comment-block-size): --staged judges
// the index against its baseline and may block (rc 1); --all reports on the tree and only advises.
// Exit: 0 performed or skipped, 1 BLOCK (--staged only), 3 an unreadable file or index.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("../limited-child-process");
const { toWindowsPath } = require("../branch-diff");
const scan = require("../comment-block-scan");
const { readConfig } = require("./config");
const { esc, createReport } = require("./report");
const { inProgress, findBaselines } = require("./baseline");
const { blobs } = require("../test-gates/git-blobs");

const HDR = "## Comment-block Size Review";
// Compiled-in performance guards, not configuration: an ambient value able to raise them would
// let the check silently review nothing.
const MAX_FILES = 200;
const MAX_BYTES = 1000000;
const GIT_TIMEOUT_MS = 60000;

function gitRunner(cwd, env) {
  return (args, input) => {
    const r = spawnSync("git", args, { cwd, env, input, timeout: GIT_TIMEOUT_MS, maxBuffer: 1 << 30, windowsHide: true });
    return { ok: !r.error && r.status === 0, status: r.error ? 1 : r.status, out: r.stdout || Buffer.alloc(0) };
  };
}

const nulList = (buf) => buf.toString("utf8").split("\0");

function scanBuffer(buf, threshold) {
  const r = scan.scanText(buf.toString("utf8"), threshold);
  return { runs: r.runs, n: r.runs.length, m: r.runs.reduce((a, x) => Math.max(a, x.len), 0) };
}

// stagedEntries(listBuf) -> [{ src, dst, oid }] from `diff -z --raw -M --no-abbrev` output.
function stagedEntries(listBuf) {
  const tok = nulList(listBuf);
  const out = [];
  for (let i = 0; i < tok.length && tok[i].startsWith(":");) {
    const [, , , oid, st = ""] = tok[i++].slice(1).split(" ");
    if (st[0] === "R" || st[0] === "C") {
      if (i + 1 >= tok.length) break;
      out.push({ src: tok[i], dst: tok[i + 1], oid });
      i += 2;
    } else {
      if (i >= tok.length) break;
      out.push({ src: tok[i], dst: tok[i], oid });
      i += 1;
    }
  }
  return out;
}

// blobSizes(git, oids) -> Map oid -> size of each blob from one `cat-file --batch-check`; a
// missing or non-blob object is left out, any other gap in the reply throws.
function blobSizes(git, oids) {
  const out = new Map();
  const asked = [...new Set(oids)];
  if (asked.length === 0) return out;
  const r = git(["cat-file", "--batch-check"], `${asked.join("\n")}\n`);
  if (!r.ok) throw new Error(`git cat-file --batch-check failed (rc=${r.status})`);
  const lines = r.out.toString("utf8").split("\n");
  if (lines.length !== asked.length + 1 || lines[asked.length] !== "") throw new Error("git cat-file --batch-check: reply count mismatch");
  asked.forEach((oid, k) => {
    if (lines[k] === `${oid} missing`) return;
    const [got, type, size] = lines[k].split(" ");
    if (got !== oid || !/^[0-9]+$/.test(size || "")) throw new Error(`git cat-file --batch-check: ${oid}: malformed reply`);
    if (type === "blob") out.set(oid, Number(size));
  });
  return out;
}

// readStaged(ctx, headOk, refs, entries) -> { sizes, baseOf, bodies }, with a fixed number of git
// processes whatever the entry count; a git failure throws.
function readStaged(ctx, headOk, refs, entries) {
  const sizes = blobSizes(ctx.git, entries.map((e) => e.oid));
  const wanted = entries.filter((e) => !(sizes.get(e.oid) > MAX_BYTES));
  const baseOf = findBaselines(ctx.git, headOk, refs, wanted.map((e) => e.src));
  const bodies = blobs(ctx.cwd, ctx.env, [...wanted.map((e) => e.oid), ...baseOf.values()]);
  return { sizes, baseOf, bodies };
}

function runStaged(ctx) {
  const { git, cfg, rep, stderr } = ctx;
  const headOk = git(["rev-parse", "--verify", "--quiet", "HEAD"]).ok;
  const prog = inProgress(git, ctx.cwd);
  ctx.label = prog.label;
  const list = git(["-c", "core.quotePath=false", "diff", "-z", "--cached", "--raw", "-M", "--no-abbrev", "--diff-filter=ACMRT"]);
  if (!list.ok) {
    return { early: [`${HDR}: PERFORMED (staged mode, incomplete: 1 file(s) unreadable)`, `ERROR: (staged index) — git diff --cached failed (rc=${list.status})`], rc: 3 };
  }
  const entries = stagedEntries(list.out).filter((e) => scan.hasScannableExtension(e.dst, cfg.extensions) && !scan.isExcludedPath(e.dst)
    && (!ctx.only || ctx.only.has(e.dst)));
  if (entries.length > MAX_FILES) {
    // A blocking verdict must not degrade to "skip and let the commit through" on a padded commit.
    stderr.write(`pre-commit: comment-block size review — staged file count (${entries.length}) exceeds the ${MAX_FILES} performance guard; scanning in full anyway\n`);
  }
  let got;
  try {
    got = readStaged(ctx, headOk, prog.refs, entries);
  } catch (e) {
    return { early: [`${HDR}: PERFORMED (staged mode, incomplete: 1 file(s) unreadable)`, `ERROR: (staged index) — ${esc(e.message)}`], rc: 3 };
  }
  for (const { src, dst, oid } of entries) {
    if (got.sizes.get(oid) > MAX_BYTES) {
      rep.counts.tooBig++;
      continue;
    }
    const dstE = esc(dst);
    const body = got.bodies.get(oid);
    if (!body) {
      rep.counts.error++;
      rep.add(`ERROR: ${dstE} — staged blob unreadable`);
      continue;
    }
    rep.counts.scanned++;
    const s = scanBuffer(body, cfg.threshold);
    if (got.baseOf.has(src)) {
      const base = got.bodies.get(got.baseOf.get(src));
      if (!base) {
        rep.counts.error++;
        rep.add(`ERROR: ${dstE} — baseline blob unreadable`);
        continue;
      }
      const b = scanBuffer(base, cfg.threshold);
      if (s.n > b.n || s.m > b.m) {
        rep.add(`BLOCK: ${dstE} — longest comment run ${b.m} → ${s.m} lines (over-threshold runs ${b.n} → ${s.n})`);
        rep.details(s.runs);
        rep.counts.warn++;
      }
    } else if (s.m > 0) {
      rep.add(`BLOCK: ${dstE} — longest comment run ${s.m} lines (no baseline: absolute-state fallback)`);
      rep.details(s.runs);
      rep.counts.warn++;
    }
  }
  return null;
}

// One walk over tracked + untracked-but-not-ignored paths; symlinks are never followed.
function runAll(ctx) {
  const { git, cfg, rep } = ctx;
  const seen = new Set();
  for (const f of nulList(git(["-c", "core.quotePath=false", "ls-files", "-z", "--cached", "--others", "--exclude-standard"]).out)) {
    if (!f || seen.has(f)) continue;
    seen.add(f);
    if (!scan.hasScannableExtension(f, cfg.extensions) || scan.isExcludedPath(f)) continue;
    const abs = path.join(ctx.cwd, f);
    const st = fs.lstatSync(abs, { throwIfNoEntry: false });
    if (!st || st.isSymbolicLink() || !st.isFile()) continue;
    if (st.size > MAX_BYTES) {
      rep.counts.tooBig++;
      continue;
    }
    let buf;
    try {
      buf = fs.readFileSync(abs);
    } catch {
      rep.counts.error++;
      rep.add(`ERROR: ${esc(f)} — file unreadable`);
      continue;
    }
    rep.counts.scanned++;
    const s = scanBuffer(buf, cfg.threshold);
    if (s.m > 0) {
      rep.add(`WARN: ${esc(f)} — longest comment run ${s.m} lines (${s.n} runs over threshold)`);
      rep.details(s.runs);
      rep.counts.warn++;
    }
  }
  return null;
}

function finalLines(ctx, staged) {
  const { rep, cfg } = ctx;
  let desc = staged ? "staged mode" : "all-scan mode";
  if (staged && ctx.label) desc += `, ${ctx.label} in progress`;
  if (rep.counts.error > 0) desc += `, incomplete: ${rep.counts.error} file(s) unreadable`;
  const label = staged ? "Staged code files scanned" : "All code files scanned";
  const lines = [`${HDR}: PERFORMED (${desc})`,
    `${label}: ${rep.counts.scanned} (extensions: ${esc(cfg.extensionsRaw)}; threshold: > ${cfg.threshold} comment lines per block)`];
  if (rep.counts.tooBig > 0) lines.push(`  skipped (too large): ${rep.counts.tooBig}`);
  lines.push(...rep.body());
  if (rep.counts.warn > 0) lines.push("  Compress to a one-line summary + a pointer to the authoritative doc (CPR-SSOT).");
  return lines;
}

// review({ mode, cwd, env, cfgDir, stderr, only }) -> { lines, rc }; mode is "staged" or "all".
// only, when given, is the iterable of staged paths --staged may review (a merge's narrowed set).
function review({ mode, cwd, env, cfgDir, stderr, only }) {
  const skip = (why) => ({ lines: [`${HDR}: SKIPPED — ${why}`], rc: 0 });
  const top = gitRunner(cwd, env)(["rev-parse", "--show-toplevel"]);
  const topDir = top.ok ? top.out.toString("utf8").replace(/\r?\n$/, "") : "";
  if (!topDir) return skip("not a git repository");
  const root = toWindowsPath(topDir);
  if (!fs.statSync(root, { throwIfNoEntry: false })?.isDirectory()) return skip("not a git repository");
  const config = readConfig(cfgDir);
  if (config.enforce === "off") return skip("COMMENT_BLOCK_ENFORCE=off");
  const cfg = { ...config, extensions: scan.parseExtensions(config.extensionsRaw) };
  const ctx = { git: gitRunner(root, env), cwd: root, env, only: only ? new Set(only) : null, cfg, rep: createReport(), stderr, label: "" };
  const staged = mode === "staged";
  const early = staged ? runStaged(ctx) : runAll(ctx);
  if (early) return { lines: early.early, rc: early.rc };
  const lines = finalLines(ctx, staged);
  if (ctx.rep.counts.error > 0) return { lines, rc: 3 };
  // rc 1 is the blocking verdict, and only --staged may return it.
  return { lines, rc: staged && ctx.rep.counts.warn > 0 ? 1 : 0 };
}

module.exports = { review, HDR };
