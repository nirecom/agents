"use strict";
// Shared #2529 glossary-check fixture for the tests/hooks/feat-2529-glossary-* entrypoints:
// a fixture repo with a combined glossary, plan artifacts and raw v2 state files inside the
// pinned WORKFLOW_STATE_DIR / WORKFLOW_PLANS_DIR, the check-glossary-drift CLI runner, and a
// PASS / FAIL reporter whose failures set the exit code.
// State is written raw (never through appendEvents) so a `complete` without a glossary_check
// record can be seeded without tripping the completion boundary the tests exercise.
// Call harness isolate() before requiring this module.

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const crypto = require("node:crypto");
const { spawnSync } = require("node:child_process");
const { gitInit } = require("./harness");

const ROOT = path.resolve(__dirname, "..", "..");
const STATE_DIR = process.env.WORKFLOW_STATE_DIR;
const PLANS_DIR = process.env.WORKFLOW_PLANS_DIR;
if (!STATE_DIR || !PLANS_DIR) throw new Error("glossary-check-fixture: call isolate() before requiring it");

const STAGE_STEP = {
  intent: "clarify_intent", outline: "outline", detail: "detail",
  tests: "review_tests", code: "review_security", docs: "review_docs",
};
const RA_STAGES = ["intent", "outline", "detail"];
const RS_STAGES = ["tests", "code", "docs"];
const STAGES = RA_STAGES.concat(RS_STAGES);
const GLOSSARY_CODES = /glossary-(check-missing|check-stale|findings-unresolved|fingerprint-unavailable)/;

// The glossary term every fixture artifact uses, and its hyphen variant (a DRIFT finding).
const TERM = "workflow step";
const VARIANT = "workflow-step";

const GLOSSARY_FILES = {
  "docs/glossary/user.md":
    "# Glossary — user terms\n\n### workflow step\n\n- **Definition**: One unit of the fixture step list.\n" +
    "- **Related**: [README.md](../../README.md)\n",
  "docs/glossary/internal.md":
    "# Glossary — internal terms\n\n### review scope\n\n- **Definition**: The files a fixture review covers.\n" +
    "- **Related**: [README.md](../../README.md)\n",
};

// One staged target per R-S stage, classified by classifyStageFile (tests/ / docs / code).
const TARGET = { tests: "tests/t.sh", code: "src/a.js", docs: "docs/guide.md" };

function targetBody(stage, word) {
  if (stage === "tests") return `#!/usr/bin/env bash\n# each ${word} is checked\nexit 0\n`;
  if (stage === "code") return `"use strict";\n// each ${word} is checked\nmodule.exports = 1;\n`;
  return `# Guide\n\nEach ${word} is checked.\n`;
}

const INTENT_GLOSSARY =
  "## Glossary\n\n| Term | Category | Operation | Definition |\n|---|---|---|---|\n" +
  "| fixture term | session | add | A term of the fixture session. |\n";

function planBody(stage, word) {
  if (stage === "intent") {
    return `# Intent\n\n## Goal\n\nEach ${word} is checked.\n\n## Issues\n\n- #1 fixture\n\n${INTENT_GLOSSARY}`;
  }
  const title = stage === "outline" ? "Outline" : "Detail";
  return `# ${title}\n\n## Approach\n\nEach ${word} is checked.\n`;
}

let counter = 0;
function newSid(tag) {
  counter += 1;
  return `g2529-${tag}-${process.pid}-${counter}`.replace(/[^A-Za-z0-9_-]/g, "-");
}

const slash = (p) => String(p).replace(/\\/g, "/");

function git(repo, args, allowFail) {
  const r = spawnSync("git", ["-C", repo].concat(args), { encoding: "utf8", timeout: 60000 });
  if (!allowFail && (r.error || r.status !== 0)) {
    throw new Error(`git ${args.join(" ")} failed: ${r.stderr || r.error}`);
  }
  return r;
}

function writeFile(repo, rel, body) {
  const abs = path.join(repo, ...rel.split("/"));
  fs.mkdirSync(path.dirname(abs), { recursive: true });
  fs.writeFileSync(abs, body);
}

function stageFile(repo, rel, body) {
  writeFile(repo, rel, body);
  git(repo, ["add", "--", rel]);
}

function commit(repo, message) {
  return git(repo, ["-c", "user.email=fixture@example.invalid", "-c", "user.name=fixture", "commit", "-q", "-m", message]);
}

// A fixture main worktree with the combined glossary committed and nothing staged.
function mkRepo(tag) {
  const dir = slash(fs.mkdtempSync(path.join(os.tmpdir(), `g2529-${tag}-`)));
  gitInit(dir);
  for (const [rel, body] of Object.entries(GLOSSARY_FILES)) writeFile(dir, rel, body);
  writeFile(dir, "README.md", "# Fixture\n");
  git(dir, ["add", "-A"]);
  commit(dir, "fixture: initial");
  return dir;
}

// A linked worktree of `repo` on a new branch; the main worktree stays `repo`.
function addWorktree(repo, tag) {
  const dir = slash(path.join(fs.mkdtempSync(path.join(os.tmpdir(), `g2529-wt-${tag}-`)), "wt"));
  git(repo, ["worktree", "add", "-q", "-b", `fixture-${tag}`, dir]);
  git(dir, ["config", "core.hooksPath", "/dev/null"]);
  return dir;
}

function planPath(sid, suffix) { return path.join(PLANS_DIR, `${sid}-${suffix}.md`); }
function writePlan(sid, stage, body) {
  fs.writeFileSync(planPath(sid, stage), body == null ? planBody(stage, TERM) : body);
}
function statePath(sid) { return path.join(STATE_DIR, `${sid}.json`); }

function stepStatusEvent(step, status) {
  return { kind: "step_status", step, status, provenance: "observed", origin: "test-fixture" };
}
function annotationEvent(step, key, value) {
  return { kind: "step_annotation", step, key, value, provenance: "observed", origin: "test-fixture" };
}

// The implementation's own approval hash of the current artifact.
function implSha(sid, step) {
  const { computeArtifactSha } = require(path.join(ROOT, "hooks/workflow-state/completion-approval.js"));
  return computeArtifactSha(sid, step);
}
function approvalEvent(sid, step) {
  const sha = implSha(sid, step);
  return {
    kind: "plan_approval", step, source: "confirm-sentinel", reason: "fixture approval",
    artifact_sha256: sha, artifact_session_id: sid, artifact_hash_status: "recorded",
    provenance: "declared", origin: "test-fixture",
  };
}

// writeState(sid, { steps: {step: status}, approve: [step], cwd }) — a raw v2 state file.
function writeState(sid, spec) {
  const s = spec || {};
  const events = [];
  for (const [step, status] of Object.entries(s.steps || {})) events.push(stepStatusEvent(step, status));
  for (const step of s.approve || []) events.push(approvalEvent(sid, step));
  const at = new Date().toISOString();
  events.forEach((e, i) => { e.at = at; e.seq = i + 1; });
  fs.writeFileSync(statePath(sid), JSON.stringify({
    version: 2, session_id: sid, created_at: at,
    session_start_context: { cwd: s.cwd || process.cwd(), git_branch: "feature/g2529-fixture" },
    workflow_type: "wf-code", deliverable_type: s.deliverableType || "wf-code", events,
  }, null, 2));
}

// Appends events to the raw stream, bypassing appendEvents and its boundaries.
function appendRaw(sid, events) {
  const st = JSON.parse(fs.readFileSync(statePath(sid), "utf8"));
  const at = new Date().toISOString();
  for (const e of events) st.events.push(Object.assign({ at }, e));
  st.events.forEach((e, i) => { e.seq = i + 1; });
  fs.writeFileSync(statePath(sid), JSON.stringify(st, null, 2));
}

function readState(sid) {
  return require(path.join(ROOT, "hooks/workflow-state")).readState(sid);
}
function statusOf(sid, step) {
  const s = readState(sid);
  return (s && s.steps && s.steps[step] && s.steps[step].status) || "pending";
}
function recordOf(sid, stage) {
  const s = readState(sid);
  const entry = s && s.steps && s.steps[STAGE_STEP[stage]];
  return (entry && entry.glossary_check) || null;
}

// A session sitting at `stage`: an intent.md (every stage reads its ## Glossary rows), the
// stage's plan artifact, every earlier gated stage complete and approved, and the stage's own
// gated approval when `approveOwn` is set.
function seedSession(tag, stage, opts) {
  const o = opts || {};
  const sid = newSid(tag);
  writePlan(sid, "intent", o.intentBody);
  if (stage === "outline" || stage === "detail") writePlan(sid, stage, o.planBody);
  const steps = { workflow_init: "complete" };
  const approve = [];
  const order = ["clarify_intent", "outline", "detail"];
  const own = STAGE_STEP[stage];
  for (const step of order) {
    if (step === own) break;
    if (step !== "clarify_intent" && !fs.existsSync(planPath(sid, step === "outline" ? "outline" : "detail"))) {
      writePlan(sid, step === "outline" ? "outline" : "detail");
    }
    steps[step] = "complete";
    approve.push(step);
  }
  steps[own] = o.ownStatus || "pending";
  if (o.approveOwn !== false && order.includes(own)) approve.push(own);
  writeState(sid, { steps, approve, cwd: o.cwd, deliverableType: o.deliverableType });
  return sid;
}

// A fresh repo + session at `stage` whose artifact uses `word`: the plan file for an R-A
// stage, the staged TARGET file for an R-S stage (opts.stageTarget === false stages nothing).
function setupStage(tag, stage, word, opts) {
  const repo = mkRepo(tag);
  const w = word || TERM;
  const o = Object.assign({ cwd: repo }, opts || {});
  if (stage === "intent") o.intentBody = planBody("intent", w);
  if (stage === "outline" || stage === "detail") o.planBody = planBody(stage, w);
  if (RS_STAGES.includes(stage) && o.stageTarget !== false) stageFile(repo, TARGET[stage], targetBody(stage, w));
  return { repo, sid: seedSession(tag, stage, o) };
}

// Changes one character of the user glossary entry in the main worktree (input 2 only).
function touchGlossary(repo, mark) {
  const rel = "docs/glossary/user.md";
  writeFile(repo, rel, GLOSSARY_FILES[rel].replace("fixture step list.", `fixture step list${mark || "!"}`));
}

// The commit gate's glossary checker for one step, against the current state and index.
function gateCheck(checker, sid, step, repo) {
  try {
    return checker.checkGlossaryRecord(step, { state: readState(sid), sessionId: sid, repoDir: repo });
  } catch (e) {
    return { action: "threw", reason: String((e && e.message) || e) };
  }
}
const gatePasses = (g) => !!g && g.action === "pass";
const gateBlocks = (g, code) => !!g && g.action === "block" && String(g.reason || "").includes(code);

function runNode(file, args, opts) {
  const o = opts || {};
  const r = spawnSync(process.execPath, [path.join(ROOT, file)].concat(args || []), {
    cwd: o.cwd || os.tmpdir(), input: o.input || "", encoding: "utf8", timeout: 60000,
    env: Object.assign({}, process.env, o.env || {}),
  });
  return { code: r.status, out: r.stdout || "", err: (r.stderr || "") + (r.error ? String(r.error) : "") };
}

// bin/check-glossary-drift --session <sid> --stage <stage> [--record], run from `cwd`.
function drift(sid, stage, cwd, record) {
  const args = ["--session", sid, "--stage", stage];
  if (record !== false) args.push("--record");
  return runNode("bin/check-glossary-drift", args, { cwd });
}

// The hook and CLI routes run with the fixture repo as both cwd and CLAUDE_PROJECT_DIR.
function mark(sid, command, cwd) {
  return runNode("hooks/workflow-mark.js", [], {
    cwd, env: { CLAUDE_PROJECT_DIR: cwd },
    input: JSON.stringify({ session_id: sid, cwd, tool_name: "Bash", tool_input: { command },
      tool_response: { exit_code: 0, stdout: "", stderr: "" } }),
  });
}

function advance(sid, step, cwd) {
  return runNode("bin/workflow/next-step", ["--session", sid, "--advance", "--step", step, "--complete"],
    { cwd, env: { CLAUDE_PROJECT_DIR: cwd } });
}

// The in-process completion boundary: one step_status=complete batch through appendEvents,
// run from `repo` (the cwd git root is the worktree fallback). → { ok } | { ok:false, code, message }
function completeInProcess(sid, step, repo, opts) {
  const { appendEvents } = require(path.join(ROOT, "hooks/workflow-state/state-io/events.js"));
  const prev = process.cwd();
  process.chdir(repo);
  try {
    appendEvents(sid, [stepStatusEvent(step, "complete")], opts || {});
    return { ok: true };
  } catch (e) {
    return { ok: false, code: e && e.code, name: e && e.name, message: String((e && e.message) || e) };
  } finally {
    process.chdir(prev);
  }
}

// True when a refusal carries `code` (the error's code, or the code named in its message).
function refusedWith(res, code) {
  return !!res && res.ok === false && (res.code === code || String(res.message || "").includes(code));
}

// Adds an ACCEPTED-style grant for every finding of the stage's record, bound to `fingerprint`
// (default: the record's own fingerprint).
function grantFindings(sid, stage, fingerprint) {
  const rec = recordOf(sid, stage);
  if (!rec) return false;
  const fp = fingerprint || rec.fingerprint;
  const grants = (rec.findings || []).map((f) => ({ norm: f.norm, fingerprint: fp, reason: "fixture grant" }));
  appendRaw(sid, [annotationEvent(STAGE_STEP[stage], "glossary_check", Object.assign({}, rec, { grants }))]);
  return true;
}

// The module under test, or null when it is not there yet (the red reason is then logged).
function mod(rel) {
  try {
    return require(path.join(ROOT, rel));
  } catch (e) {
    check(`module ${rel} loads`, false, e.code || e.message);
    return null;
  }
}

function sha256(buf) { return crypto.createHash("sha256").update(buf).digest("hex"); }

let failures = 0;
const clip = (s) => String(s).replace(/[\r\n]+/g, " ").slice(0, 300);
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

module.exports = {
  ROOT, STATE_DIR, PLANS_DIR, STAGE_STEP, RA_STAGES, RS_STAGES, STAGES, GLOSSARY_CODES, TERM, VARIANT,
  GLOSSARY_FILES, TARGET, targetBody, planBody, newSid, slash, git, writeFile, stageFile, commit, mkRepo,
  addWorktree, planPath, writePlan, statePath, stepStatusEvent, annotationEvent, implSha, approvalEvent,
  writeState, appendRaw, readState, statusOf, recordOf, seedSession, runNode, drift, mark, advance,
  completeInProcess, refusedWith, grantFindings, setupStage, touchGlossary, gateCheck, gatePasses, gateBlocks, mod, sha256, check, finish, failureCount, clip,
};
