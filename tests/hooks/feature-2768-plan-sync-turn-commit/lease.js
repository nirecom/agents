"use strict";
// Part of tests/hooks/feature-2768-plan-sync-turn-lease.js: the replacement push is leased (L1-L3).
// Another writer's commit is never overwritten, and a stale local origin/main converges.

const fs = require("node:fs");
const FOREIGN_REF = "refs/heads/ps2768-foreign";

// race(F, repo, X) -> Y: a foreign commit on X, parked on a side ref; armed so the next receive-pack
// moves bare main X -> Y before advertising. Nothing is fetched, so local origin/main stays X.
// The foreign file is another session's plan: the plans repo's .gitignore admits only plan names.
const foreignRel = (F) => F.planName("ps2768-foreign-session", "intent");
function race(F, repo, X) {
  const Y = F.humanPush(repo, foreignRel(F), "foreign\n", "foreign commit", FOREIGN_REF);
  const g = `git --git-dir="${repo.bare}"`;
  fs.writeFileSync(process.env.PS2768_INJECT, `${g} update-ref refs/heads/main ${Y} ${X}\n${g} update-ref -d ${FOREIGN_REF}\n`);
  return Y;
}
const armed = () => fs.existsSync(process.env.PS2768_INJECT);

function runRace(F) {
  F.guard("L4 a foreign commit lands after the tip was read: lease miss, fetch, append", () => {
    const RS = F.mod("hooks/lib/plan-sync/remote-state.js");
    const repo = F.makeRepo("l4");
    const sid = F.newSid("l4");
    const turn = F.newTurn(sid);
    const a = F.planName(sid, "intent");
    const n0 = F.bareCount(repo);
    F.writeSync(repo, a, "a1\n", { turn });
    const X = F.bareTip(repo);
    const Y = race(F, repo, X);
    F.check("L4 precondition: local origin/main is X, bare main still X", F.gitTry(repo.dir, ["rev-parse", "refs/remotes/origin/main"]) === X &&
      F.bareTip(repo) === X, F.bareTip(repo));
    const rp = F.sshCalls("git-receive-pack");
    const up = F.sshCalls("git-upload-pack");
    const r = F.writeSync(repo, a, "a2\n", { turn });
    const Z = F.bareTip(repo);
    F.check("L4 the race fired during the write", !armed(), "injection never ran");
    F.check("L4 pushed with the blob URL", r.status === "pushed" && r.url === F.blobUrl(a), JSON.stringify(r));
    F.check("L4 the retry fetched", F.sshCalls("git-upload-pack") > up, "no fetch");
    F.check("L4 two receive-packs: the missed lease, then the append", F.sshCalls("git-receive-pack") - rp === 2, F.sshCalls("git-receive-pack") - rp);
    const fp = F.firstParentLog(repo, 10);
    F.check("L4 foreign Y and X both in main's first-parent history", fp.includes(Y) && fp.includes(X) && F.parentsOf(repo, Y)[0] === X, JSON.stringify(fp));
    F.check("L4 Z appended on Y (X not overwritten)", F.parentsOf(repo, Z)[0] === Y && F.bareCount(repo) === n0 + 3, `${F.parentsOf(repo, Z)} count=${F.bareCount(repo) - n0}`);
    F.check("L4 foreign content and latest plan both on main", F.showAt(repo, Z, foreignRel(F)) === "foreign" && F.showAt(repo, Z, a) === "a2",
      `${F.showAt(repo, Z, foreignRel(F))} ${F.showAt(repo, Z, a)}`);
    const t = F.trailersOf(F.bodyOf(repo, Z));
    F.check("L4 Z carries this turn's trailer", t.turn[0] === turn.turnId && t.session[0] === sid, JSON.stringify(t));
    F.check("L4 a lease miss is not learned as force refusal", F.config(repo.dir, "plansync.forceRejected") === null, F.config(repo.dir, "plansync.forceRejected"));
    if (RS) {
      const st = RS.readRemoteState(repo.dir, F.config(repo.dir, "remote.origin.url"));
      F.check("L4 readRemoteState: nothing learned", st && st.forceRejected === false, JSON.stringify(st));
    }
  });
  F.guard("L4 the real porcelain of the missed lease is stale info -> lease-miss", () => {
    const LP = F.mod("hooks/lib/plan-sync/lease-push.js");
    if (!LP) return;
    const repo = F.makeRepo("l4u");
    const sid = F.newSid("l4u");
    F.writeSync(repo, F.planName(sid, "intent"), "a1\n", { turn: F.newTurn(sid) });
    const X = F.bareTip(repo);
    const Y = race(F, repo, X);
    const tree = F.git(repo.dir, ["rev-parse", `${X}^{tree}`]);
    const repl = F.git(repo.dir, ["commit-tree", tree, "-p", F.git(repo.dir, ["rev-parse", `${X}^`]), "-m", "replacement"]);
    F.git(repo.dir, ["update-ref", "refs/heads/main", repl]);
    const r = LP.pushMainWithLease(repo.dir, X, { deadline: Date.now() + 20000 });
    F.check("L4u the race fired", !armed(), "injection never ran");
    F.check("L4u porcelain says stale info", /\[rejected\][^\n]*stale info/.test(`${r.stdout || ""}\n${r.stderr || ""}`), JSON.stringify(r));
    F.check("L4u classified lease-miss", LP.classifyLeasePush(r) === "lease-miss", LP.classifyLeasePush(r));
    F.check("L4u bare main is the foreign commit, untouched", F.bareTip(repo) === Y, F.bareTip(repo));
  });
  try { fs.rmSync(process.env.PS2768_INJECT, { force: true }); } catch (_) { /* never left armed */ }
}

function run(F) {
  F.guard("L1 another machine pushed after our turn commit: append, nothing lost", () => {
    const repo = F.makeRepo("l1");
    const sid = F.newSid("l1");
    const turn = F.newTurn(sid);
    const a = F.planName(sid, "intent");
    const n0 = F.bareCount(repo);
    F.writeSync(repo, a, "a1\n", { turn });
    const X = F.bareTip(repo);
    const B = F.cloneRepo(repo, "l1b");
    const bRel = F.planName(F.newSid("l1b"), "intent");
    const rb = F.writeSync(B, bRel, "from B\n");
    const Y = F.bareTip(repo);
    F.check("L1 B pushed Y on X", rb.status === "pushed" && F.parentsOf(repo, Y)[0] === X, JSON.stringify(rb));
    const r = F.writeSync(repo, a, "a2\n", { turn });
    const Z = F.bareTip(repo);
    F.check("L1 pushed", r.status === "pushed" && r.url === F.blobUrl(a), JSON.stringify(r));
    F.check("L1 Z appended on Y", F.parentsOf(repo, Z)[0] === Y && F.bareCount(repo) === n0 + 3, `${F.parentsOf(repo, Z)} count=${F.bareCount(repo)}`);
    F.check("L1 X and Y both survive", F.isAncestor(repo, X, Z) && F.isAncestor(repo, Y, Z), "lost history");
    F.check("L1 B's content kept", F.showAt(repo, Z, bRel) === "from B", F.showAt(repo, Z, bRel));
    const t = F.trailersOf(F.bodyOf(repo, Z));
    F.check("L1 Z carries this turn's trailer", t.turn[0] === turn.turnId && t.session[0] === sid, JSON.stringify(t));
  });
  F.guard("L2 a stale origin/main still converges to one turn commit", () => {
    const repo = F.makeRepo("l2");
    const sid = F.newSid("l2");
    const turn = F.newTurn(sid);
    const a = F.planName(sid, "intent");
    const P = F.bareTip(repo);
    const n0 = F.bareCount(repo);
    F.writeSync(repo, a, "a1\n", { turn });
    const X0 = F.bareTip(repo);
    F.writeSync(repo, a, "a2\n", { turn });
    F.check("L2 precondition: second write replaced X0", F.bareCount(repo) === n0 + 1 && F.bareTip(repo) !== X0, F.bareCount(repo));
    F.git(repo.dir, ["update-ref", "refs/remotes/origin/main", X0]);
    const r = F.writeSync(repo, a, "a3\n", { turn });
    F.check("L2 pushed", r.status === "pushed" && r.url === F.blobUrl(a), JSON.stringify(r));
    F.check("L2 still one commit on P", F.bareCount(repo) === n0 + 1 && F.parentsOf(repo, F.bareTip(repo))[0] === P,
      `count=${F.bareCount(repo)} parents=${F.parentsOf(repo, F.bareTip(repo))}`);
    F.check("L2 latest content", F.showAt(repo, "refs/heads/main", a) === "a3", F.showAt(repo, "refs/heads/main", a));
  });
  F.guard("L3 after a push local origin/main equals the bare main", () => {
    const repo = F.makeRepo("l3");
    const sid = F.newSid("l3");
    const turn = F.newTurn(sid);
    const a = F.planName(sid, "intent");
    F.writeSync(repo, a, "a1\n", { turn });
    F.writeSync(repo, a, "a2\n", { turn });
    const local = F.gitTry(repo.dir, ["rev-parse", "--verify", "-q", "refs/remotes/origin/main"]);
    F.check("L3 tracking ref matches", local === F.bareTip(repo), `${local} vs ${F.bareTip(repo)}`);
  });
}

module.exports = { run, runRace };
