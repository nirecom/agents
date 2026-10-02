#!/usr/bin/env node
// PreToolUse hook: refuse a Write/Edit/MultiEdit that leaves a NEW .sh test
// entrypoint (absent from HEAD, in a repo carrying tests/lib/harness.sh) with
// missing or malformed case_begin/case_end markers (#2388). The verdict is
// bin/check-case-markers.sh run on a temp copy of the rebuilt post-edit content;
// the target file is never touched. pre-commit is the backstop for what this
// cannot rebuild (editFiles, NotebookEdit). Fails open on any error.
// Design: docs/architecture/claude-code/case-marker-gate.md.
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");
const { readPre, applyEdits, resolveTargetPath, groupEditTargets } = require("./lib/post-edit-content");
const { readHookInput, readFailOpenDiagnostic } = require("./lib/read-stdin");

const EDIT_TOOLS = new Set(["Write", "Edit", "MultiEdit"]);
const CHECKER = path.resolve(__dirname, "..", "bin", "check-case-markers.sh");
const RULE_DOC = "skills/_shared/test-design/case-markers.md";
const CHECK_TIMEOUT_MS = 8000;

// isCaseMarkerTarget — .sh test entrypoint by repo-relative `/` path. Mirrors
// _precommit_is_sh_test_entrypoint (hooks/lib/precommit-tests-frontmatter.sh);
// the parity test pins the two together.
function isCaseMarkerTarget(rel) {
  if (typeof rel !== "string") return false;
  if (rel === "tests/run-all.sh") return false;
  return /^tests\/(hooks|bin|skills|agents|install|tests)\/[^/]+\.sh$/.test(rel) || /^tests\/[^/]+\.sh$/.test(rel);
}

function buildReason(violations) {
  const lines = ["[block-case-markers] New test file(s) fail the case-marker gate:"];
  for (const v of violations) {
    for (const h of v.high) lines.push(`  ${v.rel}: ${h}`);
  }
  lines.push(`Wrap each case in column-0 case_begin/case_end at depth 0 — see ${RULE_DOC}.`);
  return lines.join("\n");
}

function approve() {
  process.stdout.write(JSON.stringify({ decision: "approve" }) + "\n");
  process.exit(0);
}

function block(reason) {
  process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
  process.exit(0);
}

function shellPath(p) {
  return p.split(path.sep).join("/");
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

// checkOne — HIGH lines (temp path rewritten to rel) or null when not a violation.
// Anything but rc 1 with a HIGH line (WARN-only rc 0, rc 2, timeout) fails open.
function checkOne(tmpFile, rel, cwd) {
  const r = spawnSync("bash", [shellPath(CHECKER), shellPath(tmpFile)], {
    cwd,
    encoding: "utf8",
    timeout: CHECK_TIMEOUT_MS,
  });
  if (r.error || r.status !== 1 || typeof r.stdout !== "string") return null;
  const high = r.stdout
    .split(/\r?\n/)
    .filter((l) => /^HIGH: .* code=/.test(l))
    .map((l) => l.split(shellPath(tmpFile)).join(rel).split(tmpFile).join(rel));
  return high.length > 0 ? high : null;
}

function collectCandidates(input, toolName, toolInput) {
  const out = [];
  for (const group of groupEditTargets(toolName, toolInput, input)) {
    const absPath = resolveTargetPath(input, group.rawPath);
    if (!absPath) continue;
    const loc = repoRelOf(absPath);
    if (!loc || !isCaseMarkerTarget(loc.rel)) continue;
    if (!fs.existsSync(path.join(loc.top, "tests", "lib", "harness.sh"))) continue;
    if (isInHead(loc.top, loc.rel)) continue;
    const post = postContentOf(group, absPath);
    if (typeof post !== "string") continue;
    out.push({ rel: loc.rel, post });
  }
  return out;
}

function main() {
  const r = readHookInput();
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

  if (!fs.existsSync(CHECKER)) approve();

  const candidates = collectCandidates(input, toolName, toolInput);
  if (candidates.length === 0) approve();

  const violations = [];
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "case-markers-"));
  try {
    candidates.forEach((c, i) => {
      const sub = path.join(dir, String(i + 1));
      fs.mkdirSync(sub);
      const tmpFile = path.join(sub, path.posix.basename(c.rel));
      fs.writeFileSync(tmpFile, c.post);
      const high = checkOne(tmpFile, c.rel, dir);
      if (high) violations.push({ rel: c.rel, high });
    });
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
  if (violations.length === 0) approve();
  block(buildReason(violations));
}

if (require.main === module) {
  try {
    main();
  } catch (e) {
    // A PreToolUse hook that throws errors every tool call; fail open instead.
    approve();
  }
}

module.exports = { isCaseMarkerTarget, buildReason };
