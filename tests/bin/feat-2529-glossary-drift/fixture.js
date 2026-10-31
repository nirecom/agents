"use strict";
// lang-check: ignore — Japanese fixture strings are test data for Japanese term matching.
// Test-only scaffolding for #2529 T4 / T5 (tests/bin/feat-2529-glossary-drift.js and
// tests/hooks/feat-2529-glossary-accept.js). Holds no cases of its own.
// A fixture main worktree with the combined glossary committed, plan artifacts and raw v2 state
// files inside the pinned WORKFLOW_STATE_DIR / WORKFLOW_PLANS_DIR, concern-ledger files in the
// session control dir, runners for check-glossary-drift / check-glossary-ledger-grant /
// workflow-mark, and a PASS / FAIL reporter whose failures set the exit code.
// State is written raw (never through appendEvents): the glossary_check / glossary_provenance
// annotations a case seeds must land even while the annotation keys are not registered yet.
// Call harness isolate() before requiring this module.

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { gitInit } = require("../../lib/harness");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const STATE_DIR = process.env.WORKFLOW_STATE_DIR;
const PLANS_DIR = process.env.WORKFLOW_PLANS_DIR;
if (!STATE_DIR || !PLANS_DIR) throw new Error("feat-2529 fixture: call isolate() before requiring it");

const STAGE_STEP = {
  intent: "clarify_intent", outline: "outline", detail: "detail",
  tests: "review_tests", code: "review_security", docs: "review_docs",
};
const STAGES = Object.keys(STAGE_STEP);
const RS_STAGES = ["tests", "code", "docs"];
const LEDGER_FORMAT = { outline: "outline-plan", detail: "detail-plan", tests: "test-review", code: "review-security-shared" };
const GATED = ["clarify_intent", "outline", "detail"];
const PLAN_SUFFIX = { clarify_intent: "intent", outline: "outline", detail: "detail" };

// The combined glossary: one user term, one internal term, one Japanese term.
const TERM = "glossary drift";
const TERM2 = "concern ledger";
const TERM_JA = "用語揺れ";
const entry = (term, def) => `### ${term}\n\n- **Definition**: ${def}\n- **Related**: [README.md](../../README.md)\n`;
const GLOSSARY_FILES = {
  "docs/glossary/user.md": `# Glossary — user terms\n\n${entry(TERM, "A spelling that differs from the glossary term.")}\n${entry(TERM_JA, "表記ゆれの日本語の語。")}`,
  "docs/glossary/internal.md": `# Glossary — internal terms\n\n${entry(TERM2, "The per-round list of review concerns.")}`,
};

const slash = (p) => String(p).replace(/\\/g, "/");
let counter = 0;
function newSid(tag) {
  counter += 1;
  return `g2529d-${tag}-${process.pid}-${counter}`.replace(/[^A-Za-z0-9_-]/g, "-");
}

function git(repo, args, allowFail) {
  const r = spawnSync("git", ["-C", repo].concat(args), { encoding: "utf8", timeout: 60000 });
  if (!allowFail && (r.error || r.status !== 0)) throw new Error(`git ${args.join(" ")} failed: ${r.stderr || r.error}`);
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
  git(repo, ["-c", "user.email=fixture@example.invalid", "-c", "user.name=fixture", "commit", "-q", "-m", message]);
}

// A fixture main worktree with the combined glossary (GLOSSARY_FILES, or `files`) committed.
function mkRepo(tag, files) {
  const dir = slash(fs.mkdtempSync(path.join(os.tmpdir(), `g2529d-${tag}-`)));
  gitInit(dir);
  for (const [rel, body] of Object.entries(files || GLOSSARY_FILES)) writeFile(dir, rel, body);
  writeFile(dir, "README.md", "# Fixture\n");
  git(dir, ["add", "-A"]);
  commit(dir, "fixture: initial");
  return dir;
}

// intent.md: Goal body, the ## Glossary table (rows: [term, category, operation, definition]),
// and the ## Issues section.
function intentBody(o) {
  const rows = (o && o.rows) || [[TERM, "user", "add", "A spelling that differs from the glossary term."]];
  const table = rows.map((r) => `| ${r.join(" | ")} |`).join("\n");
  // Section order per skills/clarify-intent/reference/intent-md-schema.md (checked by
  // hooks/lib/intent-glossary.js): title lines, ## Issues, then ## Glossary right after it.
  return `# Intent\n\n**Title:** Glossary drift fixture\n\n**PM type:** waterfall\n\n` +
    `## Issues\n\n${(o && o.issues) || "- #1: fixture"}\n\n` +
    `## Glossary\n\n| Term | Category | Operation | Definition |\n|---|---|---|---|\n${table}\n\n` +
    `## Goal\n\n${(o && o.goal) || "Detect spelling drift."}\n`;
}
function planPath(sid, suffix) { return path.join(PLANS_DIR, `${sid}-${suffix}.md`); }
function writePlan(sid, suffix, body) { fs.writeFileSync(planPath(sid, suffix), body); }
function writeIntent(sid, o) { writePlan(sid, "intent", intentBody(o)); }
function statePath(sid) { return path.join(STATE_DIR, `${sid}.json`); }

const ev = (o) => Object.assign({ provenance: "observed", origin: "test-fixture" }, o);
const statusEvent = (step, status) => ev({ kind: "step_status", step, status });
const annotationEvent = (step, key, value) => ev({ kind: "step_annotation", step, key, value });
function approvalEvent(sid, step) {
  const { computeArtifactSha } = require(path.join(ROOT, "hooks/workflow-state/completion-approval.js"));
  return ev({
    kind: "plan_approval", step, source: "confirm-sentinel", reason: "fixture approval",
    artifact_sha256: computeArtifactSha(sid, step), artifact_session_id: sid,
    artifact_hash_status: "recorded", provenance: "declared",
  });
}

// seedAt(sid, step, cwd, opts): a raw v2 state whose current step is `step` — every earlier
// non-terminal step complete, the gated ones approved against their current artifact (a
// minimal artifact is written when absent; intent.md always exists).
// opts.firstSid: a resumed session whose plans belong to that upstream — the artifacts and the
// approvals are the upstream's, and the top level carries the inheritance-copy ancestry fields.
function seedAt(sid, step, cwd, opts) {
  const { VALID_STEPS, TERMINAL_STEPS } = require(path.join(ROOT, "hooks/workflow-state"));
  const owner = (opts && opts.firstSid) || sid;
  if (!fs.existsSync(planPath(owner, "intent"))) writeIntent(owner);
  const events = [];
  for (const s of VALID_STEPS) {
    if (s === step) break;
    if (TERMINAL_STEPS.includes(s)) continue;
    events.push(statusEvent(s, "complete"));
    if (GATED.includes(s)) {
      if (!fs.existsSync(planPath(owner, PLAN_SUFFIX[s]))) writePlan(owner, PLAN_SUFFIX[s], `# ${s}\n\n## Body\n\nfixture\n`);
      events.push(approvalEvent(owner, s));
    }
  }
  const at = new Date().toISOString();
  events.forEach((e, i) => { e.at = at; e.seq = i + 1; });
  const ancestry = owner === sid ? {} : { upstream_session_id: owner, previous_session_ids: [owner], first_session_id: owner };
  fs.writeFileSync(statePath(sid), JSON.stringify(Object.assign({
    version: 2, session_id: sid, created_at: at,
    session_start_context: { cwd: cwd || process.cwd(), git_branch: "feature/g2529d-fixture" },
  }, ancestry, { workflow_type: "wf-code", deliverable_type: "wf-code", events }), null, 2));
}

// Appends events to the raw stream, bypassing appendEvents and its boundaries.
function appendRaw(sid, events) {
  const st = JSON.parse(fs.readFileSync(statePath(sid), "utf8"));
  const at = new Date().toISOString();
  for (const e of events) st.events.push(Object.assign({ at }, e));
  st.events.forEach((e, i) => { e.seq = i + 1; });
  fs.writeFileSync(statePath(sid), JSON.stringify(st, null, 2));
}
function inject(sid, step, key, value) { appendRaw(sid, [annotationEvent(step, key, value)]); }
function reapprove(sid, step) { appendRaw(sid, [approvalEvent(sid, step)]); }

function readState(sid) { return require(path.join(ROOT, "hooks/workflow-state")).readState(sid); }
function ann(sid, step, key) {
  const s = readState(sid);
  const e = s && s.steps && s.steps[step];
  return e && e[key] !== undefined ? e[key] : null;
}
const recordOf = (sid, stage) => ann(sid, STAGE_STEP[stage], "glossary_check");
// The raw file bytes: "state unchanged" compares these before and after a call.
function rawState(sid) { return fs.existsSync(statePath(sid)) ? fs.readFileSync(statePath(sid), "utf8") : ""; }
function currentStep(sid) { return require(path.join(ROOT, "hooks/workflow-state")).resolveCurrentStep(readState(sid), { sessionId: sid }); }

// Concern-ledger fixture: rows [{ id, state, discrim, text }] in <sid>.control/<format>-concern-ledger.txt.
function ledgerPath(sid, format) {
  const { controlPath } = require(path.join(ROOT, "hooks/workflow-state/state-io/control-dir"));
  return controlPath(sid, `${format}-concern-ledger.txt`, { forWrite: true });
}
function writeLedger(sid, format, rows) {
  const producer = format === "review-security-shared" ? "review-code-codex" : "review-plan-codex";
  const body = [`#concern-ledger-v2|${format}|${sid}|cycle=1`].concat(rows.map((r) =>
    `${r.id}|HIGH|${r.state || "open"}|1|1|plan#s${r.id.slice(1)}:correctness|${r.discrim}|${producer}|${producer}|-|${r.text}`));
  fs.writeFileSync(ledgerPath(sid, format), body.join("\n") + "\n");
}
const tagged = (term, rest) => `[glossary-drift term=${term}] ${rest || "spelling differs from the glossary"}`;

const EMPTY_TRANSCRIPTS = fs.mkdtempSync(path.join(os.tmpdir(), "g2529d-tx-"));
function runNode(file, args, opts) {
  const o = opts || {};
  const env = Object.assign({}, process.env, {
    AGENTS_MAIN_ROOT: ROOT, CLAUDE_TRANSCRIPT_BASE_DIR: EMPTY_TRANSCRIPTS,
    CLAUDE_PROJECT_DIR: o.cwd || os.tmpdir(),
  }, o.env || {});
  delete env.CLAUDE_CODE_SESSION_ID;
  const r = spawnSync(process.execPath, [path.join(ROOT, file)].concat(args || []), {
    cwd: o.cwd || os.tmpdir(), input: o.input || "", encoding: "utf8", timeout: 60000, env,
  });
  const out = r.stdout || "";
  const err = (r.stderr || "") + (r.error ? String(r.error) : "");
  return { code: r.status, out, err, all: out + err };
}
// True when the run reached the code under test (the entrypoint file exists and loaded).
const reached = (r) => !/Cannot find module|MODULE_NOT_FOUND/.test(r.all);

function drift(sid, stage, cwd, record) {
  const args = ["--session", sid, "--stage", stage].concat(record ? ["--record"] : []);
  return runNode("bin/check-glossary-drift", args, { cwd });
}
function ledgerGrant(args) { return runNode("bin/check-glossary-ledger-grant", args, {}); }
function mark(sid, command, cwd, env) {
  return runNode("hooks/workflow-mark.js", [], {
    cwd, env,
    input: JSON.stringify({ session_id: sid || undefined, transcript_path: null, tool_name: "Bash",
      tool_input: { command, cwd }, tool_response: { exit_code: 0, stdout: "" } }),
  });
}
// A rejected sentinel: a GLOSSARY_ACCEPTED rejection message (matching `extra` when given) and
// the state file byte-identical before and after. → the mark result
function expectRejected(title, sid, command, cwd, extra) {
  const before = rawState(sid);
  const r = mark(sid, command, cwd);
  const said = /GLOSSARY_ACCEPTED/.test(r.all) && /rejected|malformed/i.test(r.all);
  check(`${title}: rejected with a GLOSSARY_ACCEPTED message`, said && (!extra || extra.test(r.all)), r.all);
  check(`${title}: state unchanged`, said && rawState(sid) === before, said ? "state bytes changed" : "no rejection message");
  return r;
}
// Seeded records. A glossary_check with one open finding per term; a glossary_provenance with
// the given blocked entries ({ term, operation, category, reason }).
const FP = (c) => c.repeat(64);
function findingRecord(stage, fingerprint, terms) {
  return {
    v: 1, stage, fingerprint, inputs: { artifact: FP("1"), glossary: FP("2"), intent_rows: FP("3"), rules: FP("4") },
    findings: (terms || [TERM]).map((t) => ({ source: "deterministic", class: "spelling", term: t, norm: t,
      variant: t.replace(/ /g, "-"), where: "fixture.md:1" })),
    grants: [], ledger_grants: [],
  };
}
function provenanceRecord(fingerprint, blocked) {
  return {
    v: 1, fingerprint, inputs: { ops: FP("5"), intent_rows: null, rules: FP("4") }, session_source: "explicit",
    blocked: blocked.map((b) => Object.assign({ norm: b.term }, b)), grants: [],
  };
}
// echo "<<WORKFLOW_GLOSSARY_ACCEPTED: term=<term>[ <ids>] — <reason>>>"
function accepted(term, ids, reason) {
  return `echo "<<WORKFLOW_GLOSSARY_ACCEPTED: term=${term}${ids ? " " + ids : ""} — ${reason || "user accepted this spelling"}>>"`;
}

// DRIFT lines: `  DRIFT: <stage> "<variant>" -> "<term>" at <file>:<line>`.
const DRIFT_RE = /DRIFT: (\S+) "([^"]*)" -> "([^"]*)" at (.+):(\d+)\s*$/;
function driftLines(text) {
  return String(text).split(/\r?\n/).map((l) => DRIFT_RE.exec(l)).filter(Boolean)
    .map((m) => ({ stage: m[1], variant: m[2], term: m[3], file: slash(m[4]), line: Number(m[5]) }));
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

let failures = 0;
const clip = (s) => String(s).replace(/[\r\n]+/g, " ").slice(0, 300);
function check(name, ok, detail) {
  if (ok) {
    console.log(`PASS ${name}`);
    return true;
  }
  failures += 1;
  console.log(`FAIL ${name} :: ${clip(detail === undefined ? "" : detail)}`);
  return false;
}
function finish() {
  console.log(failures === 0 ? "ALL PASS" : `${failures} FAILED`);
  process.exitCode = failures === 0 ? 0 : 1;
}

module.exports = {
  ROOT, STATE_DIR, PLANS_DIR, STAGE_STEP, STAGES, RS_STAGES, LEDGER_FORMAT, TERM, TERM2, TERM_JA,
  GLOSSARY_FILES, entry, slash, newSid, git, writeFile, stageFile, commit, mkRepo, intentBody, planPath,
  writePlan, writeIntent, statePath, statusEvent, annotationEvent, approvalEvent, seedAt, appendRaw, inject,
  reapprove, readState, ann, recordOf, rawState, currentStep, ledgerPath, writeLedger, tagged, runNode,
  reached, drift, ledgerGrant, mark, expectRejected, FP, findingRecord, provenanceRecord, accepted, driftLines,
  mod, check, finish, clip,
};
