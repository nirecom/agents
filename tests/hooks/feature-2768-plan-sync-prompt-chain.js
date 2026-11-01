"use strict";
// tests/hooks/feature-2768-plan-sync-prompt-chain.js
// Tests: hooks/user-prompt-submit-turn-id.js, hooks/show-plan-link.js, hooks/lib/prompt-turn-id.js
// Tags: scope:issue-specific, TL2, plan-sync, turn-commit, prompt-turn, user-prompt-submit, a-pure
// #2768 (A-pure): the real UserPromptSubmit hook chained to the real after-write hook. show-plan-link
// reads the id the hook wrote, so the writes of one prompt fold into one commit and the next prompt appends.

// TL3 gap (what this test does NOT catch), category: hook-registration
// - whether UserPromptSubmit really fires before the model's first tool call in a live session
// - whether a real subagent PostToolUse input carries the parent's session_id

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { after, test } = require("node:test");
const { noNewFailures } = require("../lib/case-verdict");

const restore = isolate();
const F = require("../lib/plan-sync-turn-fixture");
after(() => {
  F.finish();
  restore();
});

caseBegin("real UserPromptSubmit hook chained to the real after-write hook", "hooks/user-prompt-submit-turn-id.js");
test("real UserPromptSubmit hook chained to the real after-write hook", () => noNewFailures(F.failureCount, () => {
  F.guard("C3 prompt hook -> show-plan-link, end to end", () => {
    const repo = F.makeRepo("c3");
    const sid = F.newSid("c3");
    // prompt(text) -> the record the real hook wrote for one user prompt.
    const prompt = (text) => {
      const u = F.runNode("hooks/user-prompt-submit-turn-id.js", { session_id: sid, hook_event_name: "UserPromptSubmit", prompt: text, cwd: F.DIRS.neutral });
      F.check(`C3 prompt hook "${text}": exit 0 and {}`, u.code === 0 && u.out.trim() === "{}", u.err || u.out);
      return F.readPromptTurnFile(sid) || {};
    };
    const a = F.planName(sid, "intent");
    const b = F.planName(sid, "outline");
    const write = (rel, body) => { F.writePlan(repo, rel, body); return F.hookWrite(repo, rel, { sid }); };
    const n0 = F.bareCount(repo);
    const rec1 = prompt("first");
    F.check("C3 the hook recorded a 32-hex turn id", /^[0-9a-f]{32}$/.test(String(rec1.turn_id)), JSON.stringify(rec1));
    const w1 = write(a, "a1\n");
    const w2 = write(b, "b1\n");
    const w3 = write(a, "a2\n");
    F.check("C3 every write exits 0", [w1, w2, w3].every((w) => w.code === 0), [w1, w2, w3].map((w) => w.err).join(" | "));
    F.check("C3 turn 1: three writes -> one commit", F.bareCount(repo) === n0 + 1, F.bareCount(repo) - n0);
    const X1 = F.bareTip(repo);
    const tr1 = F.tipTrailers(repo);
    F.check("C3 turn 1 trailer is the hook's turn id", Boolean(rec1.turn_id) && tr1.turn[0] === rec1.turn_id && tr1.session[0] === sid, JSON.stringify(tr1));
    F.check("C3 turn 1 commit names both plans", tr1.rel.includes(a) && tr1.rel.includes(b), JSON.stringify(tr1.rel));
    F.check("C3 turn 1 commit holds the latest content", F.showAt(repo, "refs/heads/main", a) === "a2" && F.showAt(repo, "refs/heads/main", b) === "b1",
      `${F.showAt(repo, "refs/heads/main", a)},${F.showAt(repo, "refs/heads/main", b)}`);

    const rec2 = prompt("second");
    F.check("C3 the second prompt got a new turn id", Boolean(rec2.turn_id) && rec2.turn_id !== rec1.turn_id, `${rec1.turn_id} ${rec2.turn_id}`);
    write(a, "a3\n");
    write(a, "a4\n");
    const X2 = F.bareTip(repo);
    F.check("C3 turn 2: two writes -> one commit appended on turn 1's", F.bareCount(repo) === n0 + 2 && F.parentsOf(repo, X2)[0] === X1, F.bareCount(repo) - n0);
    const tr2 = F.tipTrailers(repo);
    F.check("C3 turn 2 trailer is the second turn id", Boolean(rec2.turn_id) && tr2.turn[0] === rec2.turn_id && tr2.turn[0] !== tr1.turn[0], JSON.stringify(tr2));
    F.check("C3 turn 1's commit stays in the history", F.isAncestor(repo, X1, X2), X1);
  });
}));
caseEnd();
