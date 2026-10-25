"use strict";
// Tests: hooks/workflow-mark/supervisor-block-override-handler.js, hooks/block-subagent-sentinels.js, hooks/lib/sentinel-patterns.js, settings.json
// Tags: TL2, supervisor, block-override, sentinel, permissions, subagent, scope:issue-specific, dup-group-keep:size-hard-limit
// #2597 — WORKFLOW_SUPERVISOR_BLOCK_ACCEPTED is renamed WORKFLOW_SUPERVISOR_VERDICT_ACCEPTED: the retired
// name records nothing and points at the new one (A-new1), and a subagent can emit neither (A-new2).
// Split from feature-2709-approval-bypass-closure.js, which sits at the 500-line hard limit.
// TL3 gap (what this test does NOT catch):
// - the real permissions.ask dialog; settings.json is read statically
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { after, test } = require("node:test");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2597s-"));
const CFG = path.join(TMP, "cfg");
fs.mkdirSync(CFG);
fs.mkdirSync(path.join(TMP, "transcripts"));
fs.writeFileSync(path.join(CFG, ".env"), "");
process.env.AGENTS_MAIN_ROOT = CFG;
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(TMP, "transcripts");
delete process.env.WORKFLOW_SESSION_ID;
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const { make, mod, ROOT } = require("./feature-2709-approval-bypass-closure/fixture");
const show = (v) => JSON.stringify(v);
const F = make({ TMP, CFG, show,
  eq: (got, want, what) => assert.deepStrictEqual(got, want, what),
  ok: (cond, what) => assert.ok(cond, what) });

const OLD = "WORKFLOW_SUPERVISOR_BLOCK_ACCEPTED";
const NEW = "WORKFLOW_SUPERVISOR_VERDICT_ACCEPTED";
const REASON = "verified manually with the reviewer; the BLOCK is a false positive";
const echo = (name, body) => `echo "<<${name}: ${body}>>"`;

// subagentHook(command, agentId) -> the decision of the real block-subagent-sentinels.js hook.
function subagentHook(command, agentId) {
  const input = { tool_name: "Bash", session_id: "f2597s", tool_input: { command } };
  if (agentId) input.agent_id = agentId;
  const env = Object.assign({}, process.env);
  delete env.CLAUDE_CODE_SESSION_ID;
  const r = spawnSync(process.execPath, [path.join(ROOT, "hooks", "block-subagent-sentinels.js")],
    { input: JSON.stringify(input), encoding: "utf8", timeout: 60000, env, cwd: TMP });
  assert.ok(!r.error, `hook ran: ${r.error && r.error.message}`);
  const last = String(r.stdout || "").trim().split("\n").pop() || "{}";
  return JSON.parse(last).decision;
}

caseBegin("a-new1-retired-name-records-nothing", "hooks/workflow-mark/supervisor-block-override-handler.js");
test("A-new1: echoing the retired name records nothing and names the new sentinel", () => {
  for (const verdict of ["BLOCK", "WARN"]) {
    const sid = F.nextSid(`old-${verdict}`);
    F.seedSup(sid, [F.terminalRun("run-0011", verdict)]);
    const p = F.writer.getStatePath(sid);
    const before = fs.readFileSync(p, "utf8");
    const msg = F.markHook(sid, echo(OLD, `run-0011 ${REASON}`));
    assert.strictEqual(F.overrides(sid).length, 0, `${verdict}: the retired name records nothing; msg ${show(msg)}`);
    assert.strictEqual(fs.readFileSync(p, "utf8"), before, `${verdict}: supervisor state unchanged`);
    assert.ok(msg.includes(NEW), `${verdict}: the guidance names ${NEW}; got ${show(msg)}`);
    assert.ok(/renamed/i.test(msg), `${verdict}: the guidance says the sentinel was renamed; got ${show(msg)}`);
  }
});
test("A-new1: the new name records the same acceptance (control)", () => {
  const sid = F.nextSid("new");
  F.seedSup(sid, [F.terminalRun("run-0011", "BLOCK")]);
  F.markHook(sid, echo(NEW, `run-0011 ${REASON}`));
  assert.deepStrictEqual(F.overrides(sid).map((b) => [b.run_id, b.verdict]), [["run-0011", "BLOCK"]]);
});
caseEnd();

caseBegin("a-new1-settings-ask-row-renamed", "settings.json");
test("A-new1: settings.json asks for the new name and no longer carries the retired ask row", () => {
  const ask = (JSON.parse(fs.readFileSync(path.join(ROOT, "settings.json"), "utf8")).permissions || {}).ask || [];
  assert.ok(ask.includes(`Bash(echo "<<${NEW}: *>>")`), "the new ask row is present");
  assert.ok(!ask.some((r) => r.includes(OLD)), "the retired ask row is removed");
});
caseEnd();

caseBegin("a-new2-patterns-keep-both-names-strict", "hooks/lib/sentinel-patterns.js");
test("A-new2: isStrictSentinel recognises the new form and keeps the retired look-alike", () => {
  const sp = mod("hooks/lib/sentinel-patterns.js");
  assert.strictEqual(sp.isStrictSentinel(echo(NEW, `run-0011 ${REASON}`)), true, "new valid form");
  assert.strictEqual(sp.isStrictSentinel(echo(OLD, `run-0011 ${REASON}`)), true, "retired valid form");
  assert.strictEqual(sp.isSentinel(echo(OLD, `run-0011 ${REASON}`)), true, "the retired form reaches the handler");
});
caseEnd();

caseBegin("a-new2-subagent-cannot-emit-either-name", "hooks/block-subagent-sentinels.js");
test("A-new2: a subagent emitting the new or the retired name is blocked; the main conversation is not", () => {
  for (const name of [NEW, OLD]) {
    for (const body of [`run-0011 ${REASON}`, "run-0011"]) {
      const cmd = echo(name, body);
      assert.strictEqual(subagentHook(cmd, "agent-1"), "block", `subagent: ${cmd}`);
      assert.strictEqual(subagentHook(cmd, null), "approve", `main conversation: ${cmd}`);
    }
    assert.strictEqual(subagentHook(`echo "<<${name}>>"`, "agent-1"), "block", `subagent bare ${name}`);
  }
});
caseEnd();
