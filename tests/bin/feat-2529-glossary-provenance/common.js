"use strict";
// Tests: bin/check-glossary-provenance, bin/lib/glossary-provenance.js
// Tags: TL2, bin, glossary, provenance, fixture, scope:issue-specific
// Shared by every part of tests/bin/feat-2529-glossary-provenance.js (and the promote parts).
// Loading it isolates the workflow dirs into one temp root (removed at exit), points the
// transcript base at an empty dir and drops the inherited session id. Fixture repos carry a
// split glossary (docs/glossary/user.md: alpha, omega; docs/glossary/internal.md: kilo) and
// sessions carry a CONFIRM_INTENT approval (confirm-sentinel + the artifact sha) written raw.

const { caseBegin, caseEnd, isolate, gitInit } = require("../../lib/harness");
const { spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2529-prov-"));
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(TMP, "transcripts");
fs.mkdirSync(process.env.CLAUDE_TRANSCRIPT_BASE_DIR);
delete process.env.CLAUDE_CODE_SESSION_ID;
process.on("exit", () => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true });
});

const ROOT = path.join(__dirname, "..", "..", "..");
const STATE_DIR = process.env.WORKFLOW_STATE_DIR;
const PLANS_DIR = process.env.WORKFLOW_PLANS_DIR;
const fwd = (p) => String(p).replace(/\\/g, "/");

const totals = { passed: 0, failed: 0 };
const clip = (s) => String(s).replace(/[\r\n]+/g, " ").slice(0, 400);
function check(name, fn) {
  let why = null;
  try {
    const r = fn();
    if (typeof r === "string") why = r;
  } catch (e) {
    why = e && e.message ? e.message : String(e);
  }
  if (why === null) {
    totals.passed += 1;
    process.stdout.write(`PASS: ${name}\n`);
  } else {
    totals.failed += 1;
    process.stdout.write(`FAIL: ${name} — ${clip(why)}\n`);
  }
}
const show = (v) => (v === undefined ? "undefined" : JSON.stringify(v));
function eq(got, want, what) {
  if (JSON.stringify(got) !== JSON.stringify(want)) throw new Error(`${what || "value"}: want=${show(want)} got=${show(got)}`);
}
function ok(cond, what) {
  if (!cond) throw new Error(what || "assertion failed");
}

// mod(rel) — the module under test; a missing module throws a readable red reason.
function mod(rel) {
  try {
    return require(path.join(ROOT, rel));
  } catch (e) {
    throw new Error(`module ${rel} does not load (${e.code || e.message})`);
  }
}

caseBegin("fixture-glossary-texts-and-repos", "bin/lib/glossary-provenance.js");
// --- glossary fixture text ---
const DEFS = {
  alpha: "The first fixture term.",
  omega: "The last fixture term.",
  kilo: "A middle internal term.",
};
function entry(term, def, rel) {
  return `### ${term}\n\n- **Definition**: ${def}\n- **Related**: ${rel || "[README.md](../../README.md)"}\n`;
}
// glossaryText(category, [[term, def, rel?], ...]) — one entry file in sorted input order.
function glossaryText(category, entries) {
  const head = `# Glossary — ${category} terms\n`;
  return [head].concat(entries.map(([t, d, r]) => entry(t, d, r))).join("\n");
}
const BASE = {
  "docs/glossary/user.md": glossaryText("user", [["alpha", DEFS.alpha], ["omega", DEFS.omega]]),
  "docs/glossary/internal.md": glossaryText("internal", [["kilo", DEFS.kilo]]),
};

// --- git fixture ---
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
function readFile(repo, rel) {
  try { return fs.readFileSync(path.join(repo, ...rel.split("/")), "utf8"); } catch (_) { return null; }
}
function stage(repo, rel, body) {
  writeFile(repo, rel, body);
  git(repo, ["add", "--", rel]);
}
function commit(repo, message) {
  git(repo, ["-c", "user.email=fixture@example.invalid", "-c", "user.name=fixture", "commit", "-q", "-m", message]);
}
let repoCount = 0;
// mkRepo(tag, files) — a committed fixture repo (default: BASE glossary + README).
function mkRepo(tag, files) {
  repoCount += 1;
  const dir = fwd(path.join(TMP, `repo-${tag}-${repoCount}`));
  fs.mkdirSync(dir, { recursive: true });
  gitInit(dir);
  for (const [rel, body] of Object.entries(files || BASE)) writeFile(dir, rel, body);
  writeFile(dir, "README.md", "# Fixture\n");
  git(dir, ["add", "-A"]);
  commit(dir, "fixture: initial");
  return dir;
}
// stageUser / stageInternal — stage a whole replacement entry list for one category file.
const stageUser = (repo, entries) => stage(repo, "docs/glossary/user.md", glossaryText("user", entries));
const stageInternal = (repo, entries) => stage(repo, "docs/glossary/internal.md", glossaryText("internal", entries));
const U0 = () => [["alpha", DEFS.alpha], ["omega", DEFS.omega]];
const I0 = () => [["kilo", DEFS.kilo]];
caseEnd();

caseBegin("fixture-sessions-and-cli-runners", "bin/check-glossary-provenance");
// --- intent / state fixture ---
let sidCount = 0;
function newSid(tag) {
  sidCount += 1;
  return `p2529-${tag}-${process.pid}-${sidCount}`.replace(/[^A-Za-z0-9_-]/g, "-");
}
const intentPath = (sid) => path.join(PLANS_DIR, `${sid}-intent.md`);
const statePath = (sid) => path.join(STATE_DIR, `${sid}.json`);

// intentText(rows, opts) — rows [[term, category, operation, definition]]; opts.issues,
// opts.glossary (a raw `## Glossary` body that replaces the table), opts.noGlossary.
function intentText(rows, opts) {
  const o = opts || {};
  const table = "| Term | Category | Operation | Definition |\n|---|---|---|---|\n" +
    rows.map((r) => `| ${r[0]} | ${r[1]} | ${r[2]} | ${r[3] || ""} |`).join("\n") + (rows.length ? "\n" : "");
  const glossary = o.noGlossary ? "" : `## Glossary\n\n${o.glossary !== undefined ? o.glossary : table}\n`;
  return `# Agreed Requirements — fixture\n\n## Issues\n\n${o.issues || "- #1 fixture"}\n\n${glossary}` +
    "## Background / Motivation\n\nFixture background.\n";
}
function writeIntent(sid, rows, opts) {
  fs.writeFileSync(intentPath(sid), intentText(rows, opts));
  return intentPath(sid);
}

// The implementation's own approval hash of the current intent.md (pre-existing API).
function intentSha(sid) {
  return require(path.join(ROOT, "hooks/workflow-state/completion-approval.js")).computeArtifactSha(sid, "clarify_intent");
}

// writeState(sid, opts) — a raw v2 state file. opts.approval: false (none) | object overrides
// of the confirm-sentinel approval event ({ source, artifact_sha256, artifact_session_id }).
function writeState(sid, opts) {
  const o = opts || {};
  const at = new Date().toISOString();
  const events = [
    { kind: "step_status", step: "workflow_init", status: "complete", provenance: "observed", origin: "test-fixture" },
    { kind: "step_status", step: "clarify_intent", status: "complete", provenance: "observed", origin: "test-fixture" },
  ];
  if (o.approval !== false) {
    events.push(Object.assign({
      kind: "plan_approval", step: "clarify_intent", source: "confirm-sentinel", reason: "fixture approval",
      artifact_sha256: intentSha(sid), artifact_session_id: sid, artifact_hash_status: "recorded",
      provenance: "declared", origin: "test-fixture",
    }, o.approval || {}));
  }
  events.forEach((e, i) => { e.at = at; e.seq = i + 1; });
  fs.writeFileSync(statePath(sid), JSON.stringify({
    version: 2, session_id: sid, created_at: at,
    session_start_context: { cwd: o.cwd || TMP, git_branch: "feature/p2529-fixture" },
    workflow_type: "wf-code", deliverable_type: "wf-code", events,
  }, null, 2));
}

// approvedSession(tag, rows, opts) — intent.md written, then a state whose CONFIRM_INTENT
// approval pins its sha. opts.approval / opts.cwd pass through to writeState.
function approvedSession(tag, rows, opts) {
  const sid = newSid(tag);
  writeIntent(sid, rows, opts);
  writeState(sid, opts);
  return sid;
}

// reapprove(sid) — CONFIRM_INTENT taken again: a fresh approval over the current bytes.
function reapprove(sid) {
  const st = JSON.parse(fs.readFileSync(statePath(sid), "utf8"));
  st.events.push({
    kind: "plan_approval", step: "clarify_intent", source: "confirm-sentinel", reason: "fixture re-approval",
    artifact_sha256: intentSha(sid), artifact_session_id: sid, artifact_hash_status: "recorded",
    provenance: "declared", origin: "test-fixture", at: new Date().toISOString(), seq: st.events.length + 1,
  });
  fs.writeFileSync(statePath(sid), JSON.stringify(st, null, 2));
}

function readState(sid) {
  return require(path.join(ROOT, "hooks/workflow-state")).readState(sid);
}
// provRecord(sid) — the review_docs glossary_provenance annotation, or null.
function provRecord(sid) {
  const s = readState(sid);
  const rd = s && s.steps && s.steps.review_docs;
  return (rd && rd.glossary_provenance) || null;
}
const blockedOf = (sid) => ((provRecord(sid) || {}).blocked || []);

// --- process runners ---
// childEnv(extra) — the isolated env without a session id, plus `extra` (null deletes).
function childEnv(extra) {
  const env = Object.assign({}, process.env);
  delete env.CLAUDE_CODE_SESSION_ID;
  for (const [k, v] of Object.entries(extra || {})) {
    if (v === null) delete env[k];
    else env[k] = v;
  }
  return env;
}
function result(r) {
  const out = (r.stdout || "").replace(/\r/g, "");
  const err = (r.stderr || "").replace(/\r/g, "") + (r.error ? String(r.error) : "");
  return { code: r.status, out, err, all: out + err };
}
function runNode(rel, args, opts) {
  const o = opts || {};
  return result(spawnSync(process.execPath, [path.join(ROOT, rel)].concat(args || []), {
    cwd: o.cwd || TMP, input: o.input || "", encoding: "utf8", timeout: 90000, env: childEnv(o.env),
  }));
}
function runBash(rel, args, opts) {
  const o = opts || {};
  return result(spawnSync("bash", [fwd(path.join(ROOT, rel))].concat(args || []), {
    cwd: o.cwd || TMP, encoding: "utf8", timeout: 90000, env: childEnv(o.env),
  }));
}
// prov(repo, sid, opts) — bin/check-glossary-provenance --staged [--session sid] --repo repo.
function prov(repo, sid, opts) {
  const args = ["--staged"];
  if (sid !== null && sid !== undefined) args.push("--session", sid);
  args.push("--repo", repo);
  return runNode("bin/check-glossary-provenance", args, Object.assign({ cwd: repo }, opts || {}));
}
// accept(sid, repo, term, ids, reason) — one real PostToolUse call of hooks/workflow-mark.js
// carrying the GLOSSARY_ACCEPTED sentinel (ids: "op=add cat=user" or "").
function accept(sid, repo, term, ids, reason) {
  const disc = ids ? ` ${ids}` : "";
  const command = `echo "<<WORKFLOW_GLOSSARY_ACCEPTED: term=${term}${disc} — ${reason || "user accepted this change"}>>"`;
  const input = { session_id: sid, cwd: repo, tool_name: "Bash", tool_input: { command },
    tool_response: { exit_code: 0, stdout: "", stderr: "" } };
  return runNode("hooks/workflow-mark.js", [], { cwd: repo, input: JSON.stringify(input), env: { CLAUDE_PROJECT_DIR: repo } });
}

const has = (blocked, term, operation, category, reason) => blocked.some((b) =>
  String(b.term).toLowerCase() === term && b.operation === operation && b.category === category &&
  (reason === undefined || b.reason === reason));
caseEnd();

module.exports = {
  TMP, ROOT, STATE_DIR, PLANS_DIR, fwd, totals, check, eq, ok, show, clip, mod,
  DEFS, entry, glossaryText, BASE, git, writeFile, readFile, stage, commit, mkRepo, stageUser, stageInternal, U0, I0,
  newSid, intentPath, statePath, intentText, writeIntent, intentSha, writeState, approvedSession, reapprove,
  readState, provRecord, blockedOf, childEnv, runNode, runBash, prov, accept, has,
};
