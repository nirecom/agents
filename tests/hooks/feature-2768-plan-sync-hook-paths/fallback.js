"use strict";
// Part of tests/hooks/feature-2768-plan-sync-hook-fallback.js: a stale turn id or unusable session
// falls back to an append (H7, H8); a force-refusing remote is learned by real hook runs (H11, H12).

const fs = require("node:fs");
const path = require("node:path");
const { progressName, multiWrite } = require("./common");

function run(F) {
  F.guard("H7 the next prompt's hook fails to write its turn id: no replacement", () => {
    const repo = F.makeRepo("h7");
    const sid = F.newSid("h7");
    const t = F.startTurn(sid);
    const a = F.planName(sid, "intent");
    const n0 = F.bareCount(repo);
    F.writePlan(repo, a, "a1\n");
    F.hookWrite(repo, a, { sid });
    const X = F.bareTip(repo);
    F.check("H7 precondition: X carries the T1 trailer", F.tipTrailers(repo).turn[0] === t.turn.turnId, JSON.stringify(F.tipTrailers(repo)));
    const u = F.runNode("hooks/user-prompt-submit-turn-id.js", { session_id: sid, hook_event_name: "UserPromptSubmit", prompt: "next",
      cwd: F.DIRS.neutral }, { nodeArgs: ["--require", F.renameFailPreload()] });
    F.check("H7 the failing prompt hook exits 0 with {}", u.code === 0 && u.out.trim() === "{}", u.err || u.out);
    F.check("H7 prompt-turn.json is gone", !fs.existsSync(F.promptTurnPath(sid)), JSON.stringify(F.readPromptTurnFile(sid)));
    F.writePlan(repo, a, "a2\n");
    const h = F.hookWrite(repo, a, { sid });
    F.check("H7 exit 0 with the blob URL", h.code === 0 && h.ctx.includes(F.blobUrl(a)), h.err || h.ctx);
    F.check("H7 X kept, new commit appended on it", F.bareCount(repo) === n0 + 2 && F.parentsOf(repo, F.bareTip(repo))[0] === X &&
      F.isAncestor(repo, X, F.bareTip(repo)) && F.showAt(repo, "refs/heads/main", a) === "a2", F.bareCount(repo) - n0);
    const tt = F.tipTrailers(repo);
    F.check("H7 the appended commit has no turn trailer", tt.turn.length === 0 && tt.session.length === 0, JSON.stringify(tt));
  });
  F.guard("H8 an unusable session id never reaches git: append, no trailer", () => {
    const repo = F.makeRepo("h8");
    const sid = F.newSid("h8");
    F.startTurn(sid);
    const a = F.planName(sid, "intent");
    const n0 = F.bareCount(repo);
    for (const [i, bad] of [["1", "../escape"], ["2", "x;rm -rf ."], ["3", "a\nb"], ["4", "$(touch pwned)"]]) {
      F.writePlan(repo, a, `v${i}\n`);
      const h = F.hookWrite(repo, a, { sid: bad });
      F.check(`H8 sid ${JSON.stringify(bad)}: exit 0`, h.code === 0, h.err);
    }
    F.check("H8 each write appended", F.bareCount(repo) === n0 + 4, F.bareCount(repo) - n0);
    const tt = F.tipTrailers(repo);
    F.check("H8 no trailer from an unusable session", tt.turn.length === 0 && tt.session.length === 0, JSON.stringify(tt));
    F.check("H8 the sid was never run as a command", !fs.existsSync(path.join(F.DIRS.neutral, "pwned")) && !fs.existsSync(path.join(repo.dir, "pwned")), "pwned exists");
  });
}

// Nothing is seeded: the refusal must come from receive.denyNonFastForwards and reach the compare line.
function runForce(F) {
  F.guard("H11 refused replacement appends, shows the compare line, and is not retried", () => {
    const repo = F.makeRepo("h11", { deny: true });
    const sid = F.newSid("h11");
    const t = F.startTurn(sid);
    const a = F.planName(sid, "intent");
    const P = F.bareTip(repo);
    F.writePlan(repo, a, "a1\n");
    F.hookWrite(repo, a, { sid });
    const X = F.bareTip(repo);
    F.check("H11 precondition: run 1 made this turn's commit", F.tipTrailers(repo).turn[0] === t.turn.turnId, JSON.stringify(F.tipTrailers(repo)));
    F.writePlan(repo, a, "a2\n");
    const p2 = F.sshCalls("git-receive-pack");
    const h2 = F.hookWrite(repo, a, { sid });
    const Y = F.bareTip(repo);
    F.check("H11 run 2 tried the replacement first (refused push + append push)", F.sshCalls("git-receive-pack") - p2 >= 2, F.sshCalls("git-receive-pack") - p2);
    F.check("H11 run 2 exit 0 with the blob URL", h2.code === 0 && h2.ctx.includes(F.blobUrl(a)), h2.err || h2.ctx);
    F.check("H11 run 2 appended on X", Y !== X && F.parentsOf(repo, Y)[0] === X && F.showAt(repo, "refs/heads/main", a) === "a2", Y);
    F.check("H11 run 2 compare line spans the turn", h2.ctx.includes(`[plan-sync] turn diff: ${F.compareUrl(P, Y)}`), h2.ctx);
    const pushes = F.sshCalls("git-receive-pack");
    F.writePlan(repo, a, "a3\n");
    const h3 = F.hookWrite(repo, a, { sid });
    const Z = F.bareTip(repo);
    F.check("H11 run 3 appended on Y", F.parentsOf(repo, Z)[0] === Y && F.showAt(repo, "refs/heads/main", a) === "a3", Z);
    F.check("H11 run 3 pushed once (no replacement retried first)", F.sshCalls("git-receive-pack") - pushes === 1, F.sshCalls("git-receive-pack") - pushes);
    F.check("H11 run 3 compare line spans the turn", h3.ctx.includes(`[plan-sync] turn diff: ${F.compareUrl(P, Z)}`), h3.ctx);
  });
  F.guard("H12 one call writes a plan and progress on a force-refusing remote: one turn diff, both files kept", () => {
    const repo = F.makeRepo("h12", { deny: true });
    const sid = F.newSid("h12");
    const t = F.startTurn(sid);
    const a = F.planName(sid, "intent");
    const pr = progressName(sid);
    const multi = () => multiWrite(F, repo, [a, pr], { sid });
    const P = F.bareTip(repo);
    for (const [rel, body] of [[a, "a1\n"], [pr, "p1\n"]]) F.writePlan(repo, rel, body);
    const h1 = multi();
    const X = F.bareTip(repo);
    F.check("H12 first call exit 0, the turn's commits sit on P", h1.code === 0 && X !== P && F.showAt(repo, "refs/heads/main", pr) === "p1", h1.err || X);
    for (const [rel, body] of [[a, "a2\n"], [pr, "p2\n"]]) F.writePlan(repo, rel, body);
    const h2 = multi();
    const Y = F.bareTip(repo);
    const line = `[plan-sync] turn diff: ${F.compareUrl(P, Y)}`;
    F.check("H12 second call exit 0, refused replacement appended on X", h2.code === 0 && Y !== X && F.parentsOf(repo, Y)[0] !== P, h2.err || Y);
    F.check("H12 the turn diff line appears once and spans the turn", h2.ctx.includes(line) && h2.ctx.split("[plan-sync] turn diff").length === 2, h2.ctx);
    F.check("H12 plan-link line for the plan, none for progress", h2.ctx.includes(F.blobUrl(a)) && !h2.ctx.includes(F.blobUrl(pr)), h2.ctx);
    F.check("H12 the turn diff line comes after the plan-link block", h2.ctx.indexOf(line) > h2.ctx.indexOf(F.blobUrl(a)), h2.ctx);
    F.check("H12 both files at their latest content on the remote", F.showAt(repo, "refs/heads/main", a) === "a2" &&
      F.showAt(repo, "refs/heads/main", pr) === "p2", `${F.showAt(repo, "refs/heads/main", a)},${F.showAt(repo, "refs/heads/main", pr)}`);
    const own = F.firstParentLog(repo, 20).filter((h) => F.trailersOf(F.bodyOf(repo, h)).turn[0] === t.turn.turnId);
    const rels = own.flatMap((h) => F.trailersOf(F.bodyOf(repo, h)).rel);
    F.check("H12 every commit since P belongs to this turn", own.length >= 2 && F.firstParentLog(repo, own.length + 1)[own.length] === P, own.length);
    F.check("H12 the turn's commits together name both files", rels.includes(a) && rels.includes(pr), JSON.stringify(rels));
  });
}

module.exports = { run, runForce };
