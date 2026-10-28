#!/usr/bin/env node
// PreToolUse hook: refuse a Write/Edit/MultiEdit that leaves a case-marker test entrypoint
// (in a repo carrying its helperLibrary) with a self-implemented harness HEAD did not have
// (#2502), a NEW one (absent from HEAD) with missing or malformed case markers (#2388), or any
// tests/ file with a test-language mismatch HEAD did not have or an invalid test-lang-exception.
// The verdicts are the bin/ CLIs run on temp copies of the rebuilt post-edit content (and the
// HEAD blob); their WARN lines go out as additionalContext. The target file is never touched.
// pre-commit is the backstop for what this cannot rebuild (editFiles, NotebookEdit).
// Fails open on any error. Design: docs/architecture/claude-code/case-marker-gate.md.
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("./lib/limited-child-process");
const { armDecisionTimeLimit } = require("./lib/decision-time-limit");
const { readPre, applyEdits, resolveTargetPath, groupEditTargets } = require("./lib/post-edit-content");
const { readHookInput, readFailOpenDiagnostic } = require("./lib/read-stdin");
const { runChecker } = require("./lib/block-case-markers/run-checker");
const { collectLanguageMatchCandidates, headBlobOf } = require("./lib/block-case-markers/language-match-candidates");

const EDIT_TOOLS = new Set(["Write", "Edit", "MultiEdit"]);
// A missing CLI file skips that CLI only.
const binOf = (n) => path.resolve(__dirname, "..", "bin", n);
const SELF_IMPL_CHECKER = binOf("check-self-impl.sh");
const CHECKERS = [binOf("check-case-markers.sh"), SELF_IMPL_CHECKER];
const LANGUAGE_MATCH_CHECKER = binOf("check-test-language-match.sh");

// caseMarkerEntry — the registry entry of a placed case-marker entrypoint (repo-relative
// `/` path: a category root or flat tests/<name>, supported with a caseMarkerReader), or
// null. Mirrors _precommit_is_case_marker_target (hooks/lib/precommit-tests-frontmatter.sh);
// the parity test pins the two together. Throws when the registry is unreadable.
function caseMarkerEntry(rel, reg) {
  const m = placedMatch(rel, reg);
  return m && hasReader(m) ? m.entry : null;
}

// placedMatch — the registry match of a file at a case-marker placement, or null.
function placedMatch(rel, reg) {
  if (typeof rel !== "string") return null;
  if (/^tests\/(_archive|lib)\//.test(rel) || rel === "tests/run-all.sh") return null;
  if (!/^tests\/((hooks|bin|skills|agents|install|tests)\/)?[^/]+$/.test(rel)) return null;
  return registry().matchBasename(rel.slice(rel.lastIndexOf("/") + 1), reg);
}

const hasReader = (m) => m.status === "supported" && Boolean(m.entry.caseMarkerReader);

function isCaseMarkerTarget(rel, reg) {
  return caseMarkerEntry(rel, reg) !== null;
}

// isReaderlessCaseMarkerTarget — a placed file some entry matches that has no caseMarkerReader.
// Mirrors _precommit_is_readerless_case_marker_target (parity-tested).
function isReaderlessCaseMarkerTarget(rel, reg) {
  const m = placedMatch(rel, reg);
  return m !== null && !hasReader(m);
}

// The reader loads only once a target under tests/ is seen.
function registry() {
  return require("./lib/test-language-registry");
}

// Each violation carries `high` (case-marker/self-impl CLIs) and `lmHigh` (language-match CLI);
// each group gets its own heading. One marker-wrap hint per language among the case-marker
// group, worded by its registry entry's diagnostics. warns: WARN lines added at the end.
function buildReason(violations, warns = []) {
  const cm = [];
  const hints = [];
  const lm = [];
  for (const v of violations) {
    const high = v.high || [];
    const markerless = high.some((h) => /code=(MISSING|MALFORMED)_CASE_MARKERS?\b/.test(h));
    for (const h of high) cm.push(`  ${v.rel}: ${h}`);
    // CASE_ADDED_WITHOUT_MARKERS on a markerless file has the case-marker cause, so it joins that group.
    for (const h of v.lmHigh || []) {
      const toCm = markerless && /code=CASE_ADDED_WITHOUT_MARKERS\b/.test(h);
      (toCm ? cm : lm).push(`  ${v.rel}: ${h}`);
    }
    if (!markerless) continue;
    const d = (v.entry && v.entry.diagnostics) || {};
    const doc = d.markerDoc || (v.entry && v.entry.notationDoc);
    const hint = d.markerWrapHint && `${d.markerWrapHint}${doc ? ` — see ${doc}` : ""}.`;
    if (hint && !hints.includes(hint)) hints.push(hint);
  }
  const lines = [];
  if (cm.length > 0) lines.push("[block-case-markers] Test file(s) fail the test gates:", ...cm, ...hints);
  if (lm.length > 0) lines.push("[block-case-markers] Test file(s) fail the language-match gate:", ...lm);
  return lines.concat(warns.length > 0 ? ["Not checked:"] : [], warns.map((w) => `  ${w}`)).join("\n");
}

function warnContext(warns) {
  return ["[block-case-markers] Not checked (the edit is allowed):"].concat(warns.map((w) => `  ${w}`)).join("\n");
}

function approve(warns) {
  const out = { decision: "approve" };
  if (warns && warns.length > 0) {
    out.hookSpecificOutput = { hookEventName: "PreToolUse", additionalContext: warnContext(warns) };
  }
  process.stdout.write(JSON.stringify(out) + "\n");
  process.exit(0);
}

function block(reason) {
  process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
  process.exit(0);
}

function realDir(p) {
  try {
    return fs.realpathSync.native(p);
  } catch (e) {
    return p;
  }
}

// repoRelOf — {top, rel} for absPath, or null. A new file's directory may not
// exist yet, so git runs from the nearest existing ancestor; both sides go
// through realpath so short/long or case spellings cannot break path.relative.
function repoRelOf(absPath) {
  let dir = path.dirname(absPath);
  while (!fs.existsSync(dir)) {
    const up = path.dirname(dir);
    if (up === dir) return null;
    dir = up;
  }
  const r = spawnSync("git", ["rev-parse", "--show-toplevel"], { cwd: dir, encoding: "utf8", timeout: 5000 });
  if (r.error || r.status !== 0 || typeof r.stdout !== "string") return null;
  const topRaw = r.stdout.trim();
  if (!topRaw) return null;
  const top = realDir(path.resolve(topRaw));
  const abs = path.join(realDir(dir), path.relative(dir, absPath));
  const rel = path.relative(top, abs).split(path.sep).join("/");
  if (!rel || rel.startsWith("../") || rel === ".." || path.isAbsolute(rel)) return null;
  return { top, rel };
}

// isInHead — true when HEAD tracks rel, and also when git cannot answer
// (error, timeout, no HEAD): an unknown answer must fail open, not gate.
function isInHead(top, rel) {
  const r = spawnSync("git", ["ls-tree", "-z", "--name-only", "HEAD", "--", rel], {
    cwd: top,
    encoding: "utf8",
    timeout: 5000,
  });
  if (r.error || r.status !== 0 || typeof r.stdout !== "string") return true;
  return r.stdout.length > 0;
}

function postContentOf(group, absPath) {
  if (group.kind === "Write") return typeof group.content === "string" ? group.content : null;
  const pre = readPre(absPath);
  if (pre === null) return null;
  return applyEdits(pre, group.edits);
}

// collectCandidates — the case-marker entrypoints this call writes ({..., head}: the HEAD blob of
// an existing one, null for a new one; a new reader-less file carries readerless: true), or null
// when the registry is unreadable (the caller then
// fails open). An existing one whose HEAD blob git cannot give is left out, as in
// collectLanguageMatchCandidates: judging it as new could block a self-impl HEAD already had.
function collectCandidates(input, toolName, toolInput) {
  const out = [];
  let reg;
  for (const group of groupEditTargets(toolName, toolInput, input)) {
    const absPath = resolveTargetPath(input, group.rawPath);
    if (!absPath) continue;
    const loc = repoRelOf(absPath);
    if (!loc || !loc.rel.startsWith("tests/")) continue;
    if (reg === undefined) {
      try {
        reg = registry().loadRegistry();
      } catch (e) {
        try { fs.writeSync(2, `[block-case-markers] test language registry not readable — check skipped: ${String(e.message).split("\n")[0]}\n`); } catch (_) {}
        return null;
      }
    }
    const entry = caseMarkerEntry(loc.rel, reg);
    if (!entry) {
      // A new reader-less one goes to the case-marker CLI for its WARN, helper library or not.
      if (!isReaderlessCaseMarkerTarget(loc.rel, reg) || isInHead(loc.top, loc.rel)) continue;
      const post = postContentOf(group, absPath);
      if (typeof post === "string") out.push({ rel: loc.rel, top: loc.top, post, entry: null, head: null, readerless: true });
      continue;
    }
    if (!entry.helperLibrary) continue;
    if (!fs.existsSync(path.join(loc.top, ...entry.helperLibrary.path.split("/")))) continue;
    let head = null;
    if (isInHead(loc.top, loc.rel)) {
      head = headBlobOf(loc.top, loc.rel);
      if (head === null) continue;
    }
    const post = postContentOf(group, absPath);
    if (typeof post !== "string") continue;
    // Content identical to HEAD has nothing new for check-self-impl --head; skip its spawn.
    if (head !== null && head.equals(Buffer.from(post))) continue;
    out.push({ rel: loc.rel, top: loc.top, post, entry, head });
  }
  return out;
}

function main() {
  const r = readHookInput();
  armDecisionTimeLimit({ hookName: "block-case-markers" });
  if (r.kind !== "ok") {
    try { fs.writeSync(2, readFailOpenDiagnostic("block-case-markers", r, "check skipped") + "\n"); } catch (_) {}
    approve();
    return;
  }
  const input = r.input;
  if (!input || typeof input !== "object") approve();
  const toolName = input.tool_name;
  if (!EDIT_TOOLS.has(toolName)) approve();
  const toolInput = input.tool_input;
  if (!toolInput || typeof toolInput !== "object") approve();

  const clis = CHECKERS.filter((c) => fs.existsSync(c));
  const lmCli = fs.existsSync(LANGUAGE_MATCH_CHECKER) ? LANGUAGE_MATCH_CHECKER : null;
  if (clis.length === 0 && !lmCli) approve();

  // Two candidate sets: case-marker entrypoints — a new one for the case-marker and self-impl
  // CLIs, an existing one for the self-impl CLI only (with its HEAD copy; the case-marker check
  // stays on new files, #2440); a new reader-less one for the case-marker CLI only (its WARN) —
  // and every tests/ file (new or existing) for the language-match CLI.
  const runs = [];
  for (const c of (clis.length > 0 && collectCandidates(input, toolName, toolInput)) || []) {
    const cs = c.readerless
      ? clis.filter((cli) => cli !== SELF_IMPL_CHECKER)
      : c.head === null ? clis : clis.filter((cli) => cli === SELF_IMPL_CHECKER);
    if (cs.length > 0) runs.push({ ...c, clis: cs });
  }
  if (lmCli) {
    const helpers = { repoRelOf, isInHead, postContentOf };
    for (const c of collectLanguageMatchCandidates(input, toolName, toolInput, helpers)) {
      runs.push({ ...c, entry: null, clis: [lmCli] });
    }
  }
  if (runs.length === 0) approve();

  const byRel = new Map();
  const warns = [];
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "case-markers-"));
  try {
    runs.forEach((c, i) => {
      const sub = path.join(dir, String(i + 1));
      fs.mkdirSync(sub);
      const base = path.posix.basename(c.rel);
      const tmpFile = path.join(sub, base);
      fs.writeFileSync(tmpFile, c.post);
      let headCopy = null;
      if (c.head) {
        fs.mkdirSync(path.join(sub, "head"));
        headCopy = path.join(sub, "head", base);
        fs.writeFileSync(headCopy, c.head);
      }
      for (const cli of c.clis) {
        const r = runChecker({ cli, rel: c.rel, tmpFile, headCopy, top: c.top });
        if (r.high.length > 0) {
          if (!byRel.has(c.rel)) byRel.set(c.rel, { rel: c.rel, high: [], lmHigh: [], entry: c.entry });
          const v = byRel.get(c.rel);
          (cli === LANGUAGE_MATCH_CHECKER ? v.lmHigh : v.high).push(...r.high);
          v.entry = v.entry || c.entry;
        }
        warns.push(...r.warn);
      }
    });
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
  const violations = [...byRel.values()];
  if (violations.length === 0) approve(warns);
  block(buildReason(violations, warns));
}

if (require.main === module) {
  try {
    main();
  } catch (e) {
    // A PreToolUse hook that throws errors every tool call; fail open instead.
    approve();
  }
}

module.exports = { isCaseMarkerTarget, isReaderlessCaseMarkerTarget, buildReason };
