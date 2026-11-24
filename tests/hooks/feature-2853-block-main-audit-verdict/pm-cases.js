"use strict";
// #3144 cases of tests/hooks/feature-2853-block-main-audit-verdict.js: the PM-route exception for the verdict
// CLI (S1-2, judgePmWrite audit), the pm-review command of bin/review-rounds (request row -> judgeRequestWrite,
// verdict row -> judgePmWrite pm-review) and the subagent block on a PM-route run (S2-6). The hook runs with
// owner-stub-preload.js through NODE_OPTIONS, so the stub decides the assigned PM.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const X = require("../feature-3144-pm-review-writer/fixture");

const HOOK = X.rel("hooks/block-main-audit-verdict.js");
let F = null;
// setup() -> the fixture helpers (once; the caller already ran isolate()).
function setup() {
  if (F) return F;
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "f2853pm-"));
  process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(tmp, "transcripts");
  fs.mkdirSync(process.env.CLAUDE_TRANSCRIPT_BASE_DIR);
  F = X.make(tmp);
  require(X.PRELOAD).install();
  return F;
}

// hook(callerSid, cmd, agentId) -> {rc, json, out}: the hook as callerSid's PreToolUse on a Bash command.
function hook(callerSid, cmd, agentId) {
  const o = { session_id: callerSid, hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: { command: cmd } };
  if (agentId !== undefined) o.agent_id = agentId;
  const env = Object.assign({}, process.env, F.env(), { NODE_OPTIONS: `--require ${X.PRELOAD.replace(/\\/g, "/")}` });
  delete env.CLAUDE_CODE_SESSION_ID;
  const r = spawnSync(process.execPath, [HOOK], { input: JSON.stringify(o), env, encoding: "utf8", timeout: 30000, cwd: process.env.WORKFLOW_STATE_DIR });
  let json = null;
  try { json = JSON.parse((r.stdout || "").trim()); } catch (_) { json = null; }
  return { rc: r.status, json, out: (r.stdout || "") + (r.stderr || "").slice(0, 200) };
}
const VBIN = `node "$AGENTS_MAIN_ROOT/bin/supervisor-write-audit-verdict"`;
const verdictCmd = (target, runId) => `${VBIN} --session-id ${target} --audit-run-id ${runId} --verdict CONTINUE --verdict-summary "ok"`;
const RR = `node "$AGENTS_MAIN_ROOT/bin/review-rounds" append --format pm-review`;
const reqCmd = (target, pmSid, pr) => `${RR} --session ${target} --request --pm-sid ${pmSid} --pr ${pr}`;
const pmCmd = (target, t) => `${RR} --session ${target} --round ${t.round} --fingerprint ${t.fp} --pr ${t.pr} --verdict ${t.verdict || "OK"}`;

// world(owners, holders) -> a target closing #3901/#3902 with candidates A (destination) and B, run armed.
function world(o) {
  const A = F.pm("pm-a");
  const B = F.pm("pm-b");
  F.setOwners((o && o.owners) || { 3901: A, 3902: B }, o && o.holders);
  const sid = F.target([3901, 3902]);
  const run = F.arm(sid, (o && o.cause) || "pre-confirm:outline");
  if (!o || o.dest !== false) F.dest(sid, run, A.session_id);
  return { A, B, sid, run };
}

// pmAuditCases(expect) — C1: who may run the verdict CLI for another session's pre-confirm run.
function pmAuditCases(expect) {
  setup();
  const w = world();
  expect("P1 destination PM, pending pre-confirm run", "approve", hook(w.A.session_id, verdictCmd(w.sid, w.run)));
  expect("P1 the other candidate B", "block", hook(w.B.session_id, verdictCmd(w.sid, w.run)));
  expect("P1 a non-candidate session", "block", hook(F.pm("stranger").session_id, verdictCmd(w.sid, w.run)));
  expect("P1 the audited session itself (caller == target)", "block", hook(w.sid, verdictCmd(w.sid, w.run)));
  expect("P1 destination PM, wrong run id", "block", hook(w.A.session_id, verdictCmd(w.sid, "run-0099")));
  expect("P1 destination PM, no --audit-run-id", "block", hook(w.A.session_id, `${VBIN} --session-id ${w.sid} --verdict CONTINUE --verdict-summary x`));
  expect("P1 destination PM, --set-audit-verdict is never the exception", "block",
    hook(w.A.session_id, `node "$AGENTS_MAIN_ROOT/bin/supervisor-write-audit" --session-id ${w.sid} --set-audit-verdict CONTINUE`));
  expect("P1 destination PM, --session-id with shell metacharacters", "block", hook(w.A.session_id, verdictCmd(`${w.sid};id`, w.run)));
  const noDest = world({ dest: false });
  expect("P1 no destination finding recorded", "block", hook(noDest.A.session_id, verdictCmd(noDest.sid, noDest.run)));
  const moved = world();
  F.setOwners({ 3901: F.pm("pm-new"), 3902: moved.B });
  expect("P1 destination no longer a candidate (owner changed)", "block", hook(moved.A.session_id, verdictCmd(moved.sid, moved.run)));
  const held = world();
  F.setOwners({ 3901: "timeout", 3902: held.B }, { 3901: [held.A] });
  expect("P1 timeout, local holder == destination (holder is never a candidate)", "block", hook(held.A.session_id, verdictCmd(held.sid, held.run)));
  F.setOwners({ 3901: null, 3902: held.B }, { 3901: [held.A] });
  expect("P1 field unset, local holder == destination", "block", hook(held.A.session_id, verdictCmd(held.sid, held.run)));
  const settled = world();
  F.settle(settled.sid, settled.run);
  expect("P1 settled run", "block", hook(settled.A.session_id, verdictCmd(settled.sid, settled.run)));
  const tr4 = world({ cause: "threshold:severity" });
  expect("P1 cause is not pre-confirm:", "block", hook(tr4.A.session_id, verdictCmd(tr4.sid, tr4.run)));
  const fb = world();
  F.fallback(fb.sid, fb.run);
  expect("P1 the user chose the classic audit for this run", "block", hook(fb.A.session_id, verdictCmd(fb.sid, fb.run)));
}

// pmReviewCases(expect) — C1: the pm-review request and verdict rows of bin/review-rounds.
function pmReviewCases(expect) {
  setup();
  const w = world();
  const T1 = { round: 1, fp: X.FP.a, pr: 12 };
  expect("P2 subagent runs review-rounds pm-review", "block", hook(w.sid, reqCmd(w.sid, w.A.session_id, 12), "agent-3144"));
  expect("P2 workflow session request row, round 0 -> 1", "approve", hook(w.sid, reqCmd(w.sid, w.A.session_id, 12)));
  expect("P2 request row from another session", "block", hook(w.A.session_id, reqCmd(w.sid, w.A.session_id, 12)));
  expect("P2 --pm-sid is not a candidate", "block", hook(w.sid, reqCmd(w.sid, F.pm("stranger").session_id, 12)));
  expect("P2 --pm-sid with shell metacharacters", "block", hook(w.sid, reqCmd(w.sid, `${w.A.session_id};id`, 12)));
  expect("P2 --pr with shell metacharacters", "block", hook(w.sid, reqCmd(w.sid, w.A.session_id, "12&&id")));
  expect("P2 other review-rounds formats are not pm-review", "approve",
    hook(w.sid, `node "$AGENTS_MAIN_ROOT/bin/review-rounds" append --session ${w.sid} --format codex-plan --counter-round 1 --exit 0 --verdict APPROVED --source codex --run-id r1`));
  F.addRows(w.sid, [F.reqRow(1, w.A.session_id, 12, X.FP.a)]);
  expect("P2 destination PM verdict row on the last request", "approve", hook(w.A.session_id, pmCmd(w.sid, T1)));
  expect("P2 non-destination candidate verdict row", "block", hook(w.B.session_id, pmCmd(w.sid, T1)));
  expect("P2 subagent verdict row", "block", hook(w.A.session_id, pmCmd(w.sid, T1), "agent-3144"));
  expect("P2 --round of an earlier round", "block", hook(w.A.session_id, pmCmd(w.sid, Object.assign({}, T1, { round: 2 }))));
  expect("P2 --fingerprint differs from the request HEAD", "block", hook(w.A.session_id, pmCmd(w.sid, Object.assign({}, T1, { fp: X.FP.b }))));
  expect("P2 --pr differs from the request PR", "block", hook(w.A.session_id, pmCmd(w.sid, Object.assign({}, T1, { pr: 13 }))));
  expect("P2 --fingerprint with shell metacharacters", "block", hook(w.A.session_id, pmCmd(w.sid, Object.assign({}, T1, { fp: "$(id)" }))));
  expect("P2 --round with shell metacharacters", "block", hook(w.A.session_id, pmCmd(w.sid, Object.assign({}, T1, { round: "1;id" }))));
  expect("P2 review target flags missing", "block", hook(w.A.session_id, `${RR} --session ${w.sid} --verdict OK`));
  F.addRows(w.sid, [F.pmRow(1, "NOT_OK", w.A.session_id, 12, X.FP.a)]);
  expect("P2 second verdict for the same round", "block", hook(w.A.session_id, pmCmd(w.sid, T1)));
  expect("P2 next request after a verdict at round 1 (< CAP)", "approve", hook(w.sid, reqCmd(w.sid, w.A.session_id, 12)));
  F.addRows(w.sid, [F.reqRow(2, w.A.session_id, 12, X.FP.b)]);
  expect("P2 late round-1 verdict after the round-2 request", "block", hook(w.A.session_id, pmCmd(w.sid, T1)));
  F.addRows(w.sid, [F.pmRow(2, "NOT_OK", w.A.session_id, 12, X.FP.b)]);
  expect("P2 round CAP without AUTO_EXTEND -> request blocked", "block", hook(w.sid, reqCmd(w.sid, w.A.session_id, 12)));
  const e = world();
  F.addRows(e.sid, [F.reqRow(1, e.A.session_id, 12, X.FP.a), F.pmRow(1, "NOT_OK", e.A.session_id, 12, X.FP.a),
    F.reqRow(2, e.A.session_id, 12, X.FP.b), F.pmRow(2, "AUTO_EXTEND", e.A.session_id, 12, X.FP.b)]);
  expect("P2 round CAP with the destination's AUTO_EXTEND -> request allowed", "approve", hook(e.sid, reqCmd(e.sid, e.A.session_id, 12)));
  F.addRows(e.sid, [F.reqRow(3, e.A.session_id, 12, X.FP.c)]);
  expect("P2 round 3 -> request blocked", "block", hook(e.sid, reqCmd(e.sid, e.A.session_id, 12)));
  const u = world();
  F.addRows(u.sid, [F.reqRow(1, u.A.session_id, 12, X.FP.a), F.userRow(1, 12, X.FP.a)]);
  expect("P2 verdict after the user row", "block", hook(u.A.session_id, pmCmd(u.sid, T1)));
  const und = world();
  F.setOwners({ 3901: "timeout", 3902: und.B });
  expect("P2 undecidable owner -> request blocked", "block", hook(und.sid, reqCmd(und.sid, und.A.session_id, 12)));
}

// subagentRouteCases(expect) — C2 S2-6: the supervisor-audit subagent and a PM-route run.
function subagentRouteCases(expect) {
  setup();
  const w = world();
  expect("P3 subagent writes the verdict of a run routed to the assigned PM", "block", hook(w.sid, verdictCmd(w.sid, w.run), "agent-3144"));
  const ask = world({ dest: false });
  F.setOwners({ 3901: "timeout", 3902: ask.B });
  expect("P3 subagent on a pre-confirm run while the route is ask", "block", hook(ask.sid, verdictCmd(ask.sid, ask.run), "agent-3144"));
  const fb = world();
  F.fallback(fb.sid, fb.run);
  expect("P3 subagent on a run the user sent to the classic audit", "approve", hook(fb.sid, verdictCmd(fb.sid, fb.run), "agent-3144"));
  F.setOwners({});
  const none = F.target([3905]);
  const run = F.arm(none);
  expect("P3 subagent, session without an assigned PM", "approve", hook(none, verdictCmd(none, run), "agent-3144"));
}

module.exports = { pmAuditCases, pmReviewCases, subagentRouteCases };
