"use strict";
// Part of tests/hooks/feature-2768-plan-sync-hook-diff.js: the turn diff line rides after the unchanged
// plan-link block and in any systemMessage (H5, H5m, H6), renderTurnDiff units, and progress-then-plan calls sharing one commit (H10).

const { DUTY_TEXT, DIFF_HEAD, hook, progressName, editProgress, learn, expectedHead, multiWrite } = require("./common");

function run(F) {
  F.guard("H5 learned remote: plan-link block, then the turn diff line, then the duty", () => {
    const repo = F.makeRepo("h5", { deny: true });
    learn(F, repo);
    const sid = F.newSid("h5");
    F.startTurn(sid);
    const a = F.planName(sid, "intent");
    const P = F.bareTip(repo);
    F.writePlan(repo, a, "a1\n");
    F.hookWrite(repo, a, { sid });
    F.writePlan(repo, a, "a2\n");
    const h = F.hookWrite(repo, a, { sid });
    const X = F.bareTip(repo);
    F.check("H5 exit 0", h.code === 0, h.err);
    const at = h.ctx.indexOf(DIFF_HEAD);
    F.check("H5 the turn diff block is present", at > 0, h.ctx);
    F.check("H5 plan-link block byte-identical to the no-diff render", at > 0 && h.ctx.slice(0, at) === expectedHead(F, repo, a),
      at > 0 ? h.ctx.slice(0, at) : h.ctx);
    const tail = at > 0 ? h.ctx.slice(at + 2).split("\n") : [];
    F.check("H5 turn diff line is the compare of the whole turn", tail[0] === `[plan-sync] turn diff: ${F.compareUrl(P, X)}`, tail[0]);
    F.check("H5 TURN_DIFF_DUTY follows and ends the context", tail.length === 2 && tail[1] === DUTY_TEXT, JSON.stringify(tail));
    F.check("H5 the turn diff line comes after every [plan-link] line", at > h.ctx.split(DUTY_TEXT).join("").lastIndexOf("[plan-link]"), h.ctx);
    F.check("H5 published plan shows no systemMessage", h.msg === "", h.msg);
  });
  // detail S4-4: whenever showsMessage emits a systemMessage, the turn diff line rides there too.
  F.guard("H5m learned remote with a breadcrumb: the systemMessage also carries the turn diff line", () => {
    const repo = F.makeRepo("h5m", { deny: true });
    learn(F, repo);
    const sid = F.newSid("h5m");
    F.startTurn(sid);
    const a = F.planName(sid, "intent");
    const absent = F.planName(sid, "outline");
    const P = F.bareTip(repo);
    F.writePlan(repo, a, "a1\n");
    F.hookWrite(repo, a, { sid });
    F.writePlan(repo, a, "a2\n");
    const h = multiWrite(F, repo, [a, absent], { sid });
    const line = `[plan-sync] turn diff: ${F.compareUrl(P, F.bareTip(repo))}`;
    F.check("H5m exit 0", h.code === 0, h.err);
    F.check("H5m precondition: the context carries the turn diff line", h.ctx.includes(`\n\n${line}\n${DUTY_TEXT}`), h.ctx);
    F.check("H5m precondition: the absent plan's breadcrumb makes a systemMessage", h.msg.includes(absent), h.msg || h.out);
    F.check("H5m systemMessage carries the turn diff line", h.msg.split("\n").includes(line), h.msg);
    F.check("H5m systemMessage carries no duty text", !h.msg.includes(DUTY_TEXT), h.msg);
  });
  F.guard("H5 unlearned remote: no turn diff anywhere, context unchanged", () => {
    const repo = F.makeRepo("h5u");
    const sid = F.newSid("h5u");
    F.startTurn(sid);
    const a = F.planName(sid, "intent");
    F.writePlan(repo, a, "a1\n");
    F.hookWrite(repo, a, { sid });
    F.writePlan(repo, a, "a2\n");
    const h = F.hookWrite(repo, a, { sid });
    F.check("H5u no turn diff in the context", h.code === 0 && !h.ctx.includes("[plan-sync] turn diff"), h.ctx);
    F.check("H5u no turn diff in the systemMessage", !h.msg.includes("[plan-sync] turn diff"), h.msg);
    F.check("H5u context is exactly the plan-link render", h.ctx === expectedHead(F, repo, a), h.ctx);
  });
  F.guard("H6 progress-only turn on a learned remote: only the turn diff block", () => {
    const repo = F.makeRepo("h6", { deny: true });
    learn(F, repo);
    const sid = F.newSid("h6");
    F.startTurn(sid);
    const P = F.bareTip(repo);
    F.writePlan(repo, progressName(sid), "p1\n");
    editProgress(F, repo, sid);
    F.writePlan(repo, progressName(sid), "p2\n");
    const h = hook(F, repo, "Write", { file_path: F.absOf(repo, progressName(sid)), content: "p2\n" }, { sid });
    const X2 = F.bareTip(repo);
    const line = `[plan-sync] turn diff: ${F.compareUrl(P, X2)}`;
    F.check("H6 exit 0", h.code === 0, h.err);
    F.check("H6 context is the turn diff block", h.ctx.trim() === `${line}\n${DUTY_TEXT}`, h.ctx || h.out);
    F.check("H6 no plan-link block", !h.ctx.split(DUTY_TEXT).join("").includes("[plan-link]") && !h.msg.includes("[plan-link]"), h.ctx);
    F.check("H6 systemMessage carries the diff line, not the duty", h.msg.includes(line) && !h.msg.includes(DUTY_TEXT), h.msg);
    F.check("H6 progress content still sent", F.showAt(repo, "refs/heads/main", progressName(sid)) === "p2", F.showAt(repo, "refs/heads/main", progressName(sid)));
  });
  F.guard("H6 progress-only turn on an unlearned remote prints nothing", () => {
    const repo = F.makeRepo("h6u");
    const sid = F.newSid("h6u");
    F.startTurn(sid);
    F.writePlan(repo, progressName(sid), "p1\n");
    editProgress(F, repo, sid);
    F.writePlan(repo, progressName(sid), "p2\n");
    const h = hook(F, repo, "Write", { file_path: F.absOf(repo, progressName(sid)), content: "p2\n" }, { sid });
    F.check("H6u exit 0 and empty stdout", h.code === 0 && h.out === "", h.out || h.err);
    F.check("H6u progress content sent", F.showAt(repo, "refs/heads/main", progressName(sid)) === "p2", F.showAt(repo, "refs/heads/main", progressName(sid)));
  });
}

function runUnits(F) {
  F.guard("renderTurnDiff", () => {
    const TD = F.mod("hooks/show-plan-link/turn-diff.js");
    if (!TD) return;
    F.check("TURN_DIFF_DUTY text", TD.TURN_DIFF_DUTY === DUTY_TEXT, TD.TURN_DIFF_DUTY);
    const r = (turnLinks) => ({ filePath: "/plans/x-intent.md", absPath: "/plans/x-intent.md", result: Object.assign({ status: "pushed", url: "u" }, turnLinks ? { turnLinks } : {}) });
    F.check("no results -> empty", TD.renderTurnDiff([]) === "", TD.renderTurnDiff([]));
    F.check("no turnLinks -> empty", TD.renderTurnDiff([r(null), { filePath: "a", absPath: "a", result: { status: "failed", reason: "auth" } }]) === "", "non-empty");
    const cmp = { kind: "compare", urls: [F.compareUrl("b1", "h1")] };
    F.check("compare block", TD.renderTurnDiff([r(cmp)]) === `[plan-sync] turn diff: ${F.compareUrl("b1", "h1")}\n${DUTY_TEXT}`, TD.renderTurnDiff([r(cmp)]));
    const cmts = { kind: "commits", urls: [F.commitUrl("c1"), F.commitUrl("c2")], more: 0 };
    F.check("commits block without more", TD.renderTurnDiff([r(cmts)]).split("\n")[0] ===
      `[plan-sync] turn diff (other commits interleave, one link per commit of this turn): ${F.commitUrl("c1")} ${F.commitUrl("c2")}`, TD.renderTurnDiff([r(cmts)]));
    const more = { kind: "commits", urls: [1, 2, 3, 4, 5].map((n) => F.commitUrl(`c${n}`)), more: 2 };
    F.check("commits block with (+N more)", TD.renderTurnDiff([r(more)]).split("\n")[0].endsWith(`${F.commitUrl("c5")} (+2 more)`), TD.renderTurnDiff([r(more)]));
    const two = TD.renderTurnDiff([r(cmp), r(null), r({ kind: "compare", urls: [F.compareUrl("b1", "h2")] })]);
    F.check("several results: one line, the latest wins", two === `[plan-sync] turn diff: ${F.compareUrl("b1", "h2")}\n${DUTY_TEXT}`, two);
    F.check("same turnLinks twice -> one line", TD.renderTurnDiff([r(cmp), r(cmp)]).split("\n").length === 2, TD.renderTurnDiff([r(cmp), r(cmp)]));
    F.check("null/garbage input -> empty", TD.renderTurnDiff(null) === "" && TD.renderTurnDiff([null, {}]) === "", "non-empty");
  });
}

function runProgressFirst(F) {
  F.guard("H10 progress first, then a plan, in separate calls -> one turn commit with both", () => {
    const repo = F.makeRepo("h10");
    const sid = F.newSid("h10");
    const t = F.startTurn(sid);
    const a = F.planName(sid, "intent");
    const n0 = F.bareCount(repo);
    F.writePlan(repo, progressName(sid), "p1\n");
    const h1 = editProgress(F, repo, sid);
    F.check("H10 progress Edit exit 0", h1.code === 0, h1.err);
    F.writePlan(repo, a, "a1\n");
    const h2 = F.hookWrite(repo, a, { sid });
    F.check("H10 plan Write exit 0 with the blob URL", h2.code === 0 && h2.ctx.includes(F.blobUrl(a)), h2.err || h2.ctx);
    F.check("H10 still one commit", F.bareCount(repo) === n0 + 1, F.bareCount(repo) - n0);
    F.check("H10 both files at their latest content", F.showAt(repo, "refs/heads/main", progressName(sid)) === "p1" &&
      F.showAt(repo, "refs/heads/main", a) === "a1", `${F.showAt(repo, "refs/heads/main", progressName(sid))},${F.showAt(repo, "refs/heads/main", a)}`);
    const tt = F.tipTrailers(repo);
    F.check("H10 the turn trailer names both files", tt.turn[0] === t.turn.turnId && tt.rel.includes(a) && tt.rel.includes(progressName(sid)), JSON.stringify(tt));
  });
}

module.exports = { run, runUnits, runProgressFirst };
