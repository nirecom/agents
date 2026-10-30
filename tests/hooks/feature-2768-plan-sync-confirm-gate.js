"use strict";
// tests/hooks/feature-2768-plan-sync-confirm-gate.js
// Tests: hooks/lib/plan-sync/commit-push.js, hooks/confirm-checkpoint.js
// Tags: scope:issue-specific, TL2, plan-sync, turn-commit, confirm-checkpoint, presentation-receipt
// #2768 T25: a same-turn replacement keeps the blob URL byte-identical, so the presentation receipt
// and the confirm gate pass as before; the auth backoff keeps published plans confirmable.

// TL3 gap (what this test does NOT catch), category: hook-registration
// - the real timing between the transcript's prompt record and UserPromptSubmit (the PROMPT_SKEW_MS premise)
// - which transcript a real subagent hook input points to (turn context is passed in-process here)
// - whether the model actually prints the TURN_DIFF_DUTY line (no live model is driven)

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const path = require("node:path");

const restore = isolate();
const F = require("../lib/plan-sync-turn-fixture");
const { seedReceipt } = require("../lib/presentation-receipt-seed");

// One plans dir at WORKFLOW_PLANS_DIR: the receipt seed and the hook resolve the plan there.
const repo = F.makeRepo("cg", { dir: F.slash(process.env.WORKFLOW_PLANS_DIR) });

function marker(sid, rel) {
  require(path.join(F.ROOT, "hooks", "lib", "turn-marker")).writeTurnMarker(sid, {
    absPath: path.resolve(F.absOf(repo, rel)), suffix: "intent", ts: Date.now(), created_at: new Date().toISOString() });
}
// confirm(sid, mode) -> confirm-checkpoint output for the CONFIRM_INTENT echo under CONFIRM_INTENT=<mode> (default on).
function confirm(sid, mode) {
  const input = { tool_name: "Bash", tool_input: { command: 'echo "<<WORKFLOW_CONFIRM_INTENT>>"' }, session_id: sid,
    transcript_path: F.txPath(sid) };
  const res = F.runNode("hooks/confirm-checkpoint.js", input, { env: { CONFIRM_INTENT: mode || "on" }, unset: ["SHOW_PLAN_LINK_NO_AUTO_OPEN", "SHOW_PLAN_LINK_NO_SPAWN"] });
  const hso = (res.json && res.json.hookSpecificOutput) || {};
  return Object.assign(res, { decision: hso.permissionDecision || "", ctx: hso.additionalContext || "",
    msg: (res.json && res.json.systemMessage) || "" });
}
const backoff = () => {
  F.git(repo.dir, ["config", "--local", "plansync.remoteStateUrl", F.config(repo.dir, "remote.origin.url")]);
  F.git(repo.dir, ["config", "--local", "plansync.authBackoffUntil", String(Date.now() + 600000)]);
};
const unbackoff = () => {
  for (const k of ["plansync.remoteStateUrl", "plansync.authBackoffUntil"]) F.git(repo.dir, ["config", "--local", "--unset", k], true);
};

try {
caseBegin("T25 same-turn replacement keeps the receipt and the CONFIRM gate", "hooks/lib/plan-sync/commit-push.js");
  F.guard("T25", () => {
    const sid = F.newSid("t25");
    const turn = F.newTurn(sid);
    const a = F.planName(sid, "intent");
    const n0 = F.bareCount(repo);
    const r1 = F.writeSync(repo, a, "first\n", { turn });
    const r2 = F.writeSync(repo, a, "second\n", { turn });
    F.check("T25 both syncs pushed with the same blob URL", r1.url === F.blobUrl(a) && r2.status === "pushed" && r2.url === r1.url,
      JSON.stringify([r1, r2]));
    F.check("T25 the second sync replaced the first (bare +1)", F.bareCount(repo) === n0 + 1, F.bareCount(repo) - n0);
    F.check("T25 the replacement is on main", F.showAt(repo, "refs/heads/main", a) === "second", F.showAt(repo, "refs/heads/main", a));
    marker(sid, a);
    F.check("T25 receipt seeded with the blob URL", Boolean(seedReceipt(sid, "intent")), "no receipt");
    const c = confirm(sid);
    F.check("T25 confirm exit 0, not denied", c.code === 0 && c.decision !== "deny", c.out || c.err);
    F.check("T25 systemMessage shows the blob URL", c.msg.includes(F.blobUrl(a)), c.msg);
    F.check("T25 additionalContext carries the same blob URL", c.ctx.includes(F.blobUrl(a)), c.ctx);
  });
  // Intent has no off waiver (#2277): CONFIRM_INTENT=off still runs the gate, so the replaced plan's
  // receipt must pass it exactly as under on, with the same blob URL and no skip message.
  F.guard("T25 CONFIRM_INTENT=off", () => {
    const sid = F.newSid("t25off");
    const turn = F.newTurn(sid);
    const a = F.planName(sid, "intent");
    F.writeSync(repo, a, "first\n", { turn });
    const r2 = F.writeSync(repo, a, "second\n", { turn });
    F.check("T25off the replacement pushed with the blob URL", r2.status === "pushed" && r2.url === F.blobUrl(a), JSON.stringify(r2));
    marker(sid, a);
    F.check("T25off receipt seeded with the blob URL", Boolean(seedReceipt(sid, "intent")), "no receipt");
    const c = confirm(sid, "off");
    F.check("T25off intent is not skipped", c.code === 0 && !c.msg.includes("[confirm-skipped"), c.out || c.err);
    F.check("T25off confirm not denied", c.decision !== "deny", c.out || c.err);
    F.check("T25off systemMessage and additionalContext show the blob URL", c.msg.includes(F.blobUrl(a)) && c.ctx.includes(F.blobUrl(a)),
      c.out);
  });
caseEnd();
caseBegin("auth backoff keeps a published plan confirmable and an unpublished one fail-closed", "hooks/confirm-checkpoint.js");
  F.guard("backoff: published plan", () => {
    const sid = F.newSid("cgb");
    const a = F.planName(sid, "intent");
    F.writeSync(repo, a, "published\n");
    try {
      backoff();
      const r = F.sync(repo, a);
      F.check("C1 published content keeps pushed + URL under the backoff", r.status === "pushed" && r.url === F.blobUrl(a), JSON.stringify(r));
      marker(sid, a);
      F.check("C1 receipt seeded", Boolean(seedReceipt(sid, "intent")), "no receipt");
      const c = confirm(sid);
      F.check("C1 confirm not denied, URL shown", c.code === 0 && c.decision !== "deny" && c.msg.includes(F.blobUrl(a)), c.out || c.err);
    } finally { unbackoff(); }
  });
  F.guard("backoff: changed content", () => {
    const sid = F.newSid("cgc");
    const a = F.planName(sid, "intent");
    F.writeSync(repo, a, "v1\n");
    try {
      backoff();
      const r = F.writeSync(repo, a, "v2 never sent\n");
      F.check("C1 changed content fails auth-backoff", r.status === "failed" && r.reason === "auth-backoff", JSON.stringify(r));
      F.check("C1 bare still holds v1", F.showAt(repo, "refs/heads/main", a) === "v1", F.showAt(repo, "refs/heads/main", a));
      marker(sid, a);
      F.check("C1 no receipt for unpublished content", seedReceipt(sid, "intent") === null, "receipt seeded");
      const c = confirm(sid);
      F.check("C1 confirm denies the unpublished plan", c.code === 0 && c.decision === "deny", c.out || c.err);    } finally { unbackoff(); }
  });
caseEnd();
} finally {
  F.finish();
  restore();
}
