"use strict";
// Shared fixture for the #2631 size-limit tests (tests/hooks/feature-2631-*.js). The caller runs
// harness isolate() before requiring this file. Provides: the reporter, text builders of an exact
// line / char count, a "workflow started" state writer, a config root, and a node CLI spawner.

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const ROOT = path.resolve(__dirname, "..", "..", "..");

// The SSOT numbers the issue fixes (intent): kind -> [warn, hard, unit].
const EXPECTED = {
  code: [300, 500, "lines"], prompt: [100, 200, "lines"], docs: [300, 500, "lines"],
  history: [500, 800, "lines"], intent: [100, 200, "lines"], outline: [100, 200, "lines"],
  detail: [300, 500, "lines"], progress: [400, 600, "chars"],
};

let failures = 0;
const clip = (s) => String(s).replace(/[\r\n]+/g, " ").slice(0, 400);
function check(name, ok, detail) {
  if (ok) console.log(`PASS: ${name}`);
  else { failures += 1; console.log(`FAIL: ${name} — ${clip(detail)}`); }
}
// run(name, fn) — a thrown error (MODULE_NOT_FOUND while the source is missing) is one FAIL.
function run(name, fn) {
  try { fn(); } catch (e) { check(name + " (threw)", false, (e && (e.code ? e.code + " " : "") + e.message) || e); }
}
function failureCount() { return failures; }

function load(rel) { return require(path.join(ROOT, rel)); }
function newSid() { return crypto.randomUUID(); }
function work() { return path.dirname(process.env.WORKFLOW_STATE_DIR); }

// codeLines(n) — n newline-terminated code lines without comments (countLines === n).
function codeLines(n, tag) {
  let s = "";
  for (let i = 1; i <= n; i++) s += `const ${tag || "a"}${i} = ${i};\n`;
  return s;
}
// proseLines(n) — n newline-terminated English lines (plan-lang clean).
function proseLines(n, tag) {
  let s = "";
  for (let i = 1; i <= n; i++) s += `Line ${i} of the ${tag || "fixture"} text.\n`;
  return s;
}
// progressDoc(chars) — a session-progress.md whose trimmed Current state is exactly `chars`.
function progressDoc(chars, extra) {
  const body = "x".repeat(Math.max(0, chars));
  return `# Session progress\n\n## Current state\n\n${body}\n\n## Plan files\n\n- none\n` + (extra || "");
}

// writeStartedState(sid, top, extra) — a raw v5 state with one self-recorded settled step, so
// lifecycle.isWorkflowStarted(sid) is true (origin mark-step, provenance observed).
function writeStartedState(sid, top, extra) {
  const at = new Date().toISOString();
  const events = [{ kind: "step_status", step: "workflow_init", status: "complete", provenance: "observed", origin: "mark-step" }]
    .concat(extra || []).map((e, i) => Object.assign({ at }, e, { seq: i + 1 }));
  const state = Object.assign({
    version: 5, session_id: sid, created_at: at,
    session_start_context: { cwd: work(), git_branch: "feature/f2631-fixture" }, events,
  }, top || {});
  const p = path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.json`);
  fs.writeFileSync(p, JSON.stringify(state, null, 2));
  return p;
}
function writeMarker(sid, kind) {
  fs.writeFileSync(path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.${kind}`), "fixture\n");
}
// startedSanity(sid) — guards the fixture premise against the existing predicate.
function startedSanity(sid) {
  const lc = load("hooks/workflow-state/lifecycle.js");
  check("fixture premise: isWorkflowStarted(started sid)", lc.isWorkflowStarted(sid) === true, sid);
}

function configRoot(name, lines) {
  const dir = path.join(work(), "cfg-" + name);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, ".env"), lines.join("\n") + "\n");
  return dir;
}

// nodeCli(rel, args, opts) — spawn a repo node CLI / hook with process.execPath.
function nodeCli(rel, args, opts) {
  const o = opts || {};
  const r = spawnSync(process.execPath, [path.join(ROOT, rel)].concat(args || []), {
    input: o.input == null ? "" : o.input, encoding: "utf8", timeout: 60000,
    env: Object.assign({}, process.env, o.env || {}), cwd: o.cwd || work(),
  });
  return { status: r.status, stdout: String(r.stdout || ""), stderr: String(r.stderr || ""), error: r.error };
}

function git(dir, args) {
  const r = spawnSync("git", ["-C", dir].concat(args), { encoding: "utf8" });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr}`);
  return String(r.stdout || "");
}
function commitAll(dir, msg) {
  git(dir, ["add", "-A"]);
  git(dir, ["-c", "user.email=test@example.com", "-c", "user.name=Test", "commit", "-q", "-m", msg || "fixture"]);
}

module.exports = {
  ROOT, EXPECTED, check, run, failureCount, clip, load, newSid, work, codeLines, proseLines,
  progressDoc, writeStartedState, writeMarker, startedSanity, configRoot, nodeCli, git, commitAll,
};
