"use strict";
// #2961 subagent cases: a plan written by a subagent reaches show-plan-link with the main session's
// session_id and its own agent_id. The turn marker lands under the main sid, the mid-turn write gets
// the INTERIM duty, and the main turn's Stop is no plan presentation turn until the audit settles.
// Called from ../feature-2961-plan-presentation-turn.js, which owns the case markers.
const path = require("path");
const assert = require("node:assert/strict");
const { spawnSync } = require("child_process");
const C = require("./common");

const { R, S, show } = C;
const HOOK = path.join(C.ROOT, "hooks", "show-plan-link.js");

// subagentWrite(s) -> {rc, ctx, err}: the real hook on a subagent's Write of the stage's plan.
function subagentWrite(s) {
  const input = {
    session_id: s.sid, agent_id: "a2961sub", agent_type: "outline-planner", hook_event_name: "PostToolUse",
    tool_name: "Write", tool_input: { file_path: s.plan, content: "rewritten" }, tool_response: { success: true }, cwd: R.TDIR,
  };
  const env = R.envFor({ mode: "plan-sync-off", env: { CONV_LANG: "english", PLAN_SYNC_REMOTE_URL: "" } });
  const r = spawnSync(process.execPath, [HOOK], { input: JSON.stringify(input), env, encoding: "utf8", timeout: 60000, cwd: R.TDIR });
  let json = {};
  try { json = JSON.parse(r.stdout || "{}"); } catch (_) { json = {}; }
  return { rc: r.status, ctx: String((json.hookSpecificOutput || {}).additionalContext || ""), err: r.stderr || "" };
}

// CONV_LANG=english keeps the language directive off the block reason, so `continued` reads its head.
const STOP_OPTS = { env: { CONV_LANG: "english" } };
const view = (st) => show({ rc: st.rc, blocked: st.blocked, continued: st.continued, reason: String(st.reason).slice(-400) });

function subagentMidTurnThenPresentation() {
  const s = C.at("outline", { audit: false });
  const before = R.turnMarkersLeft(s.sid);
  const w = subagentWrite(s);
  assert.equal(w.rc, 0, `hook exit ${w.rc}: ${w.err}`);
  assert.equal(R.turnMarkersLeft(s.sid), before + 1, "the subagent's write leaves its turn marker under the main sid");
  const st = R.stop(s.sid, R.presentTurn(s, [], "The planner wrote the outline; the audit runs next.", { markers: false }), STOP_OPTS);
  assert.ok(!st.blocked && !st.continued, `mid-turn Stop: no block, no continue ${view(st)}`);
  assert.ok(!R.receiptExists(s.sid, "outline"), "mid-turn Stop: no receipt");
  const interim = C.need("hooks/lib/plan-link.js", "INTERIM_DUTY");
  assert.ok(w.ctx.includes(interim), `the subagent's mid-turn write gets INTERIM_DUTY:\n${w.ctx}`);
  assert.ok(!w.ctx.includes(C.ON_HEAD), `no link-line duty:\n${w.ctx}`);
  S.settle(s.sid, "outline", "CONTINUE");
  const w2 = subagentWrite(s);
  assert.equal(w2.rc, 0, `hook exit ${w2.rc}: ${w2.err}`);
  const st2 = R.stop(s.sid, R.presentTurn(s, [], "The outline is ready.", { markers: false }), STOP_OPTS);
  assert.ok(st2.blocked, `settled: a plan presentation turn, block without the link ${view(st2)}`);
}

module.exports = { subagentMidTurnThenPresentation };
