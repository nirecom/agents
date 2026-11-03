"use strict";
// GLOSSARY_ACCEPTED against a real pending provenance block (#2824 Steps 2 and 4).
// applied: a recorded grant stays INFO on the normal channel.
// parallel: two GLOSSARY_ACCEPTED hook processes started at the same moment (two Bash calls of one
// assistant message). Each grant is either recorded or refused with a reason on the strong channel; a
// grant that is neither (lost silently) is the defect. Repeated over several rounds, since a race is
// not reproduced every run: a green run here does not prove the race absent.
// TL3 gap: Claude Code's real PostToolUse fan-out timing and its 5 s hook timeout (H1); the
// processes here run without that timeout.
// Load order: the dispatcher requires this module after isolate() and before fixture.make(), so the
// provenance fixture (common) and the refusal fixture share one pinned pair of workflow dirs.

const assert = require("node:assert");
const childProcess = require("node:child_process");
const path = require("node:path");
// common isolates the workflow dirs, empties the transcript base and drops the session id on load.
const C = require("../../bin/feat-2529-glossary-provenance/common");
const O = require("../../lib/workflow-mark-output");

const ROUNDS = 3;
const TERMS = { beta: "An accepted fixture term.", gamma: "Another accepted fixture term." };
const CONFIRM = { CONFIRM_INTENT: "on", CONFIRM_OUTLINE: "on", CONFIRM_DETAIL: "on" };

// acceptAsync(sid, repo, term) -> Promise<{code, stdout, stderr}> of one real hook process.
function acceptAsync(sid, repo, term) {
  const command = `echo "<<WORKFLOW_GLOSSARY_ACCEPTED: term=${term} op=add cat=user — user accepted this change>>"`;
  const input = { session_id: sid, cwd: repo, tool_name: "Bash", tool_input: { command },
    tool_response: { exit_code: 0, stdout: "", stderr: "" } };
  return new Promise((resolve) => {
    const child = childProcess.spawn(process.execPath, [path.join(C.ROOT, "hooks", "workflow-mark.js")],
      { cwd: repo, env: C.childEnv({ CLAUDE_PROJECT_DIR: repo, ...CONFIRM }) });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => child.kill(), 90000);
    child.stdout.on("data", (d) => { stdout += d; });
    child.stderr.on("data", (d) => { stderr += d; });
    child.on("close", (code) => { clearTimeout(timer); resolve({ code, stdout, stderr }); });
    child.stdin.end(JSON.stringify(input));
  });
}

// withConfirm(fn) — CONFIRM_* on for the provenance CLI and the hook, restored afterwards.
async function withConfirm(fn) {
  const saved = Object.fromEntries(Object.keys(CONFIRM).map((k) => [k, process.env[k]]));
  Object.assign(process.env, CONFIRM);
  try { return await fn(); } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

function pendingSession(tag) {
  const repo = C.mkRepo(tag);
  C.stageUser(repo, [["alpha", C.DEFS.alpha], ["beta", TERMS.beta], ["gamma", TERMS.gamma], ["omega", C.DEFS.omega]]);
  const sid = C.approvedSession(tag, [["delta", "user", "add", "Unrelated term."]], { cwd: repo });
  const first = C.prov(repo, sid);
  assert.strictEqual(first.code, 1, `fixture: both hand-written adds block (out: ${first.all})`);
  for (const t of Object.keys(TERMS)) assert.ok(C.has(C.blockedOf(sid), t, "add", "user"), `fixture: ${t} pending`);
  return { repo, sid };
}
const grantedOf = (sid) => {
  const rec = C.provRecord(sid) || {};
  return new Set((rec.grants || []).filter((g) => g.fingerprint === rec.fingerprint).map((g) => g.norm));
};

function applied() {
  return withConfirm(() => {
    const { repo, sid } = pendingSession("info");
    const r = C.accept(sid, repo, "beta", "op=add cat=user");
    assert.ok(grantedOf(sid).has("beta"), `the grant is recorded: ${r.all}`);
    const why = O.infoFailure({ code: r.code, stdout: r.out, stderr: r.err }, /GLOSSARY_ACCEPTED: grant recorded for "beta"/);
    assert.strictEqual(why, null, why);
  });
}

function parallel() {
  return withConfirm(async () => {
    const lost = [];
    for (let round = 1; round <= ROUNDS; round++) {
      const { repo, sid } = pendingSession(`par${round}`);
      const [rb, rg] = await Promise.all([acceptAsync(sid, repo, "beta"), acceptAsync(sid, repo, "gamma")]);
      const granted = grantedOf(sid);
      for (const [term, r] of [["beta", rb], ["gamma", rg]]) {
        if (granted.has(term)) continue;
        // Not recorded: the hook must have said so on the strong channel, naming the term.
        const why = O.unappliedFailure(r, new RegExp(term));
        if (why) lost.push(`round ${round} ${term}: grant not recorded and not refused — ${why}`);
      }
      if (granted.size === 2) assert.strictEqual(C.prov(repo, sid).code, 0, `round ${round}: both grants pass the gate`);
    }
    assert.deepStrictEqual(lost, [], lost.join("\n"));
  });
}

module.exports = { applied, parallel };
