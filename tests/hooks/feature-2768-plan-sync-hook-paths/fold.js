"use strict";
// Part of tests/hooks/feature-2768-plan-sync-hook-paths.js: every MUST path of the after-write hook
// (Write, session-progress Edit, assemble Bash) folds one turn into one commit (H1-H4), and one call
// naming several plans plus session-progress.md shares that commit (H9).

const path = require("node:path");
const { hook, progressName, editProgress, assembleCmd, multiWrite } = require("./common");

function run(F) {
  F.guard("H1-H4 Write, session-progress Edit, assemble Bash", () => {
    const repo = F.makeRepo("h1");
    const sid = F.newSid("h1");
    const t = F.startTurn(sid);
    const a = F.planName(sid, "intent");
    const n0 = F.bareCount(repo);
    F.writePlan(repo, a, "a1\n");
    const h1 = F.hookWrite(repo, a, { sid });
    F.check("H1 first write exit 0 with the blob URL", h1.code === 0 && h1.ctx.includes(F.blobUrl(a)), h1.err || h1.out);
    const firstUrl = F.blobUrl(a);
    F.writePlan(repo, a, "a2\n");
    const h1b = F.hookWrite(repo, a, { sid });
    F.check("H1 second write exit 0", h1b.code === 0, h1b.err);
    F.check("H1 two same-turn Writes -> one commit", F.bareCount(repo) === n0 + 1, F.bareCount(repo) - n0);
    const t1 = F.tipTrailers(repo);
    F.check("H1 the commit carries this turn's trailer", t1.turn[0] === t.turn.turnId && t1.session[0] === sid, JSON.stringify(t1));
    F.check("H1 latest content on main", F.showAt(repo, "refs/heads/main", a) === "a2", F.showAt(repo, "refs/heads/main", a));

    F.writePlan(repo, progressName(sid), "progress 1\n");
    const h2 = editProgress(F, repo, sid);
    F.check("H2 progress Edit: exit 0 and no output", h2.code === 0 && h2.out === "", h2.out || h2.err);
    F.check("H2 progress lands in the same turn commit", F.bareCount(repo) === n0 + 1, F.bareCount(repo) - n0);
    F.check("H2 progress is on main", F.showAt(repo, "refs/heads/main", progressName(sid)) === "progress 1", F.showAt(repo, "refs/heads/main", progressName(sid)));
    const t2 = F.tipTrailers(repo);
    F.check("H2 trailer rels gain the progress file", t2.rel.includes(a) && t2.rel.includes(progressName(sid)), JSON.stringify(t2.rel));

    const o = F.planName(sid, "outline");
    F.writePlan(repo, o, "o1\n");
    const h3 = hook(F, repo, "Bash", { command: assembleCmd(F, repo, o) }, { sid });
    F.writePlan(repo, o, "o2\n");
    const h3b = hook(F, repo, "Bash", { command: assembleCmd(F, repo, o) }, { sid });
    F.check("H3 assemble runs exit 0 and show the outline URL", h3.code === 0 && h3b.code === 0 && h3b.ctx.includes(F.blobUrl(o)), h3b.err || h3b.out);
    F.check("H3 two assemble runs in the turn -> still one commit", F.bareCount(repo) === n0 + 1, F.bareCount(repo) - n0);
    F.check("H3 outline latest content", F.showAt(repo, "refs/heads/main", o) === "o2", F.showAt(repo, "refs/heads/main", o));

    F.useRepo(repo);
    const abs = F.absOf(repo, a);
    const pub = F.ps().publishedBlobUrl(repo.dir, abs, F.allowLocal);
    const link = require(path.join(F.ROOT, "hooks", "lib", "plan-link")).linkForFile(abs, { plansDir: repo.dir });
    F.check("H4 publishedBlobUrl after replacement is the first URL", pub === firstUrl, pub);
    F.check("H4 linkForFile after replacement is the first URL", link && link.url === firstUrl, JSON.stringify(link));
  });
}

function runMulti(F) {
  F.guard("H9 two final plans + progress in one call -> one turn commit with every file", () => {
    const repo = F.makeRepo("h9");
    const sid = F.newSid("h9");
    const t = F.startTurn(sid);
    const a = F.planName(sid, "intent");
    const o = F.planName(sid, "outline");
    const pr = progressName(sid);
    const multi = () => multiWrite(F, repo, [a, o, pr], { sid });
    const n0 = F.bareCount(repo);
    for (const [rel, body] of [[a, "a1\n"], [o, "o1\n"], [pr, "p1\n"]]) F.writePlan(repo, rel, body);
    const h = multi();
    F.check("H9 exit 0 with both blob URLs in the context", h.code === 0 && h.ctx.includes(F.blobUrl(a)) && h.ctx.includes(F.blobUrl(o)), h.err || h.ctx);
    F.check("H9 the progress file gets no plan link", !h.ctx.includes(F.blobUrl(pr)), h.ctx);
    F.check("H9 one call -> one commit", F.bareCount(repo) === n0 + 1, F.bareCount(repo) - n0);
    for (const [rel, want] of [[a, "a1"], [o, "o1"], [pr, "p1"]]) {
      F.check(`H9 ${rel} on main`, F.showAt(repo, "refs/heads/main", rel) === want, F.showAt(repo, "refs/heads/main", rel));
    }
    const tt = F.tipTrailers(repo);
    F.check("H9 the commit carries this turn's trailer", tt.turn[0] === t.turn.turnId && tt.session[0] === sid, JSON.stringify(tt));
    F.check("H9 trailer rels cover every file of the call", [a, o, pr].every((rel) => tt.rel.includes(rel)), JSON.stringify(tt.rel));
    for (const [rel, body] of [[a, "a2\n"], [o, "o2\n"], [pr, "p2\n"]]) F.writePlan(repo, rel, body);
    const h2 = multi();
    F.check("H9 second call exit 0", h2.code === 0, h2.err);
    F.check("H9 second call in the turn -> still one commit", F.bareCount(repo) === n0 + 1, F.bareCount(repo) - n0);
    const latest = [[a, "a2"], [o, "o2"], [pr, "p2"]].every(([rel, want]) => F.showAt(repo, "refs/heads/main", rel) === want);
    F.check("H9 every file at its latest content", latest, [a, o, pr].map((rel) => F.showAt(repo, "refs/heads/main", rel)).join(","));
  });
}

module.exports = { run, runMulti };
