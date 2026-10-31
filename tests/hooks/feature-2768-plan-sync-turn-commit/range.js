"use strict";
// Part of tests/hooks/feature-2768-plan-sync-turn-range.js: where a turn starts (Plan-Sync-Turn-Base).
// F5 an appended chain keeps the first commit's parent, F6 a turn whose base lies past the 200-commit
// scan gets no links, F7 turnStartOf stops at the same session's previous turn, F8 a turn commit buried
// under more than SCAN_LIMIT other-session commits is found by a whole-history search (true base kept),
// F9 that search skips newer commits that only mention the turnId and still finds the turn's commit.

const { spawnSync } = require("node:child_process");

// Appends <n> empty commits by someone else on the bare's main, starting at <from> (one fast-import spawn);
// <msgOf>(i) gives commit i's message (default "foreign <i>").
function foreignCommits(F, repo, from, n, msgOf) {
  let s = "";
  for (let i = 1; i <= n; i++) {
    const msg = `${msgOf ? msgOf(i) : `foreign ${i}`}\n`;
    s += `commit refs/heads/main\ncommitter other <other@example.invalid> ${1700000000 + i} +0000\ndata ${Buffer.byteLength(msg)}\n${msg}`;
    if (i === 1) s += `from ${from}\n`;
    s += "\n";
  }
  const r = spawnSync("git", [`--git-dir=${repo.bare}`, "fast-import", "--quiet", "--force"], { input: s, encoding: "utf8", timeout: 60000 });
  if (r.status !== 0) throw new Error(`fast-import failed: ${r.stderr}`);
}
const baseOf = (F, repo, sha) => F.trailersOf(F.bodyOf(repo, sha)).base;

function run(F) {
  F.guard("F5 every appended commit of a turn carries the first commit's parent", () => {
    const repo = F.makeRepo("f5", { deny: true });
    const sid = F.newSid("f5");
    const turn = F.newTurn(sid);
    const a = F.planName(sid, "intent");
    const P = F.bareTip(repo);
    F.writeSync(repo, a, "a1\n", { turn });
    const X1 = F.bareTip(repo);
    F.writeSync(repo, a, "a2\n", { turn });
    const X2 = F.bareTip(repo);
    F.writeSync(F.cloneRepo(repo, "f5b"), F.planName(F.newSid("f5b"), "intent"), "B\n");
    const Y = F.bareTip(repo);
    const r3 = F.writeSync(repo, a, "a3\n", { turn });
    const X3 = F.bareTip(repo);
    F.check("F5 three turn commits appended around a foreign one", F.parentsOf(repo, X2)[0] === X1 && F.parentsOf(repo, X3)[0] === Y &&
      F.parentsOf(repo, Y)[0] === X2, `${X1} ${X2} ${Y} ${X3}`);
    for (const [name, sha] of [["X1", X1], ["X2", X2], ["X3", X3]]) {
      F.check(`F5 ${name} Turn-Base is P`, JSON.stringify(baseOf(F, repo, sha)) === JSON.stringify([P]), JSON.stringify(baseOf(F, repo, sha)));
    }
    F.check("F5 links are the turn's commits, oldest first", r3.turnLinks && r3.turnLinks.kind === "commits" &&
      JSON.stringify(r3.turnLinks.urls) === JSON.stringify([F.commitUrl(X1), F.commitUrl(X2), F.commitUrl(X3)]), JSON.stringify(r3.turnLinks));
    const TC = F.mod("hooks/lib/plan-sync/turn-commit.js");
    if (!TC) return;
    const tr = TC.turnRange(repo.dir, X3, turn);
    F.check("F5 turnRange starts at P, interleaved", tr && tr.base === P && tr.interleaved === true &&
      JSON.stringify(tr.turnCommits) === JSON.stringify([X3, X2, X1]), JSON.stringify(tr));
  });
  F.guard("F6 a turn base beyond the 200-commit scan gives no links", () => {
    const repo = F.makeRepo("f6", { deny: true });
    const sid = F.newSid("f6");
    const turn = F.newTurn(sid);
    const a = F.planName(sid, "intent");
    const P = F.bareTip(repo);
    F.writeSync(repo, a, "a1\n", { turn });
    F.writeSync(repo, a, "a2\n", { turn });
    const X2 = F.bareTip(repo);
    F.check("F6 precondition: remote learned", F.config(repo.dir, "plansync.forceRejected") === "true", F.config(repo.dir, "plansync.forceRejected"));
    foreignCommits(F, repo, X2, 199);
    const R = F.bareTip(repo);
    F.check("F6 precondition: X2 is the 200th first-parent commit from R", F.firstParentLog(repo, 200)[199] === X2, R);
    const r = F.writeSync(repo, a, "a3\n", { turn });
    const Z = F.bareTip(repo);
    F.check("F6 pushed with URL", r.status === "pushed" && r.url === F.blobUrl(a), JSON.stringify(r));
    F.check("F6 Z appended on R", F.parentsOf(repo, Z)[0] === R, F.parentsOf(repo, Z));
    F.check("F6 turnStartOf found X2 at the limit: Turn-Base is P", JSON.stringify(baseOf(F, repo, Z)) === JSON.stringify([P]),
      JSON.stringify(baseOf(F, repo, Z)));
    F.check("F6 base not reached within 200 -> no turnLinks", r.status === "pushed" && r.turnLinks === undefined, JSON.stringify(r.turnLinks));
    const TC = F.mod("hooks/lib/plan-sync/turn-commit.js");
    if (!TC) return;
    F.check("F6 turnRange -> null (no partial range)", TC.turnRange(repo.dir, Z, turn) === null, JSON.stringify(TC.turnRange(repo.dir, Z, turn)));
  });
  F.guard("F7 turnStartOf stops at the same session's previous turn", () => {
    const repo = F.makeRepo("f7");
    const sid = F.newSid("f7");
    const tA = F.newTurn(sid);
    const tB = F.newTurn(sid);
    const a = F.planName(sid, "intent");
    const P = F.bareTip(repo);
    F.writeSync(repo, a, "a1\n", { turn: tA });
    const A1 = F.bareTip(repo);
    F.writeSync(repo, a, "b1\n", { turn: tB });
    const B1 = F.bareTip(repo);
    F.check("F7 A1 base P, B1 base A1", JSON.stringify(baseOf(F, repo, A1)) === JSON.stringify([P]) &&
      JSON.stringify(baseOf(F, repo, B1)) === JSON.stringify([A1]), `${baseOf(F, repo, A1)} ${baseOf(F, repo, B1)}`);
    const r = F.writeSync(repo, a, "a2\n", { turn: tA });
    const C = F.bareTip(repo);
    F.check("F7 tA again appends on B1", r.status === "pushed" && F.parentsOf(repo, C)[0] === B1, F.parentsOf(repo, C));
    F.check("F7 C's Turn-Base is B1, not P", JSON.stringify(baseOf(F, repo, C)) === JSON.stringify([B1]), JSON.stringify(baseOf(F, repo, C)));
    const TC = F.mod("hooks/lib/plan-sync/turn-commit.js");
    if (!TC) return;
    F.check("F7 turnStartOf(B1, tA) -> B1", TC.turnStartOf(repo.dir, B1, tA) === B1, TC.turnStartOf(repo.dir, B1, tA));
    F.check("F7 turnStartOf(B1, tB) -> A1", TC.turnStartOf(repo.dir, B1, tB) === A1, TC.turnStartOf(repo.dir, B1, tB));
    F.check("F7 turnStartOf of an unseen turn on P -> P", TC.turnStartOf(repo.dir, P, F.newTurn(sid)) === P, TC.turnStartOf(repo.dir, P, F.newTurn(sid)));
  });
  F.guard("F8 a turn commit buried under more than SCAN_LIMIT other-session commits keeps its true base", () => {
    const TC = F.mod("hooks/lib/plan-sync/turn-commit.js");
    if (!TC) return;
    const N = TC.SCAN_LIMIT + 3;
    const repo = F.makeRepo("f8", { deny: true });
    const sid = F.newSid("f8");
    const turn = F.newTurn(sid);
    const a = F.planName(sid, "intent");
    const P = F.bareTip(repo);
    F.writeSync(repo, a, "a1\n", { turn });
    F.writeSync(repo, a, "a2\n", { turn });
    const X2 = F.bareTip(repo);
    F.check("F8 precondition: remote learned, X2 Turn-Base is P", F.config(repo.dir, "plansync.forceRejected") === "true" &&
      JSON.stringify(baseOf(F, repo, X2)) === JSON.stringify([P]), `${F.config(repo.dir, "plansync.forceRejected")} ${baseOf(F, repo, X2)}`);
    const other = F.newTurn(F.newSid("f8o"));
    foreignCommits(F, repo, X2, N, (i) => F.handTrailer(other, [F.planName(other.sid, "intent")], X2).replace(/^plan-sync: /, `plan-sync ${i}: `));
    const R = F.bareTip(repo);
    F.check(`F8 precondition: X2 lies beyond the ${TC.SCAN_LIMIT}-commit scan from R`, !F.firstParentLog(repo, TC.SCAN_LIMIT).includes(X2), R);
    const r = F.writeSync(repo, a, "a3\n", { turn });
    const Z = F.bareTip(repo);
    F.check("F8 pushed with URL, Z appended on R", r.status === "pushed" && r.url === F.blobUrl(a) && F.parentsOf(repo, Z)[0] === R,
      `${JSON.stringify(r)} ${F.parentsOf(repo, Z)}`);
    F.check("F8 Z's Turn-Base is the turn's true base P, not R", JSON.stringify(baseOf(F, repo, Z)) === JSON.stringify([P]),
      JSON.stringify(baseOf(F, repo, Z)));
    F.check("F8 base beyond the scan -> no partial turnLinks", r.turnLinks === undefined, JSON.stringify(r.turnLinks));
    F.check("F8 turnStartOf(R, turn) searches the whole history -> P", TC.turnStartOf(repo.dir, R, turn) === P, TC.turnStartOf(repo.dir, R, turn));
    F.check("F8 turnRange(Z) -> null (no range starting at R)", TC.turnRange(repo.dir, Z, turn) === null, JSON.stringify(TC.turnRange(repo.dir, Z, turn)));
  });
  F.guard("F9 the whole-history search checks every turnId match's trailer, newest first", () => {
    const TC = F.mod("hooks/lib/plan-sync/turn-commit.js");
    if (!TC) return;
    const N = TC.SCAN_LIMIT + 3;
    // The two newest commits name the turnId without its trailer: prose only, and another session's trailer.
    const decoys = (turn) => (i) => i === N ? `notes: see turn ${turn.turnId}` :
      i === N - 1 ? F.handTrailer({ sid: F.newSid("f9o"), turnId: turn.turnId }, ["other-intent.md"], "0".repeat(40)) : `foreign ${i}`;
    const fetchAll = (repo) => F.git(repo.dir, ["fetch", "-q", repo.bare, "refs/heads/main"]);
    const repo = F.makeRepo("f9");
    const sid = F.newSid("f9");
    const turn = F.newTurn(sid);
    const P = F.bareTip(repo);
    F.writeSync(repo, F.planName(sid, "intent"), "a1\n", { turn });
    const A = F.bareTip(repo);
    F.check("F9 precondition: A's Turn-Base is P", JSON.stringify(baseOf(F, repo, A)) === JSON.stringify([P]), JSON.stringify(baseOf(F, repo, A)));
    foreignCommits(F, repo, A, N, decoys(turn));
    const R = F.bareTip(repo);
    fetchAll(repo);
    const hits = F.git(repo.bare, ["log", "--first-parent", "--fixed-strings", `--grep=${turn.turnId}`, "--format=%H", R]).split(/\r?\n/).filter(Boolean);
    F.check("F9 precondition: A beyond the scan, two decoys match the turnId ahead of A", !F.firstParentLog(repo, TC.SCAN_LIMIT).includes(A) &&
      hits.length === 3 && hits[0] === R && hits[2] === A, `${R} ${hits}`);
    F.check("F9 turnStartOf(R, turn) skips the decoys -> A's Turn-Base P, not R", TC.turnStartOf(repo.dir, R, turn) === P, TC.turnStartOf(repo.dir, R, turn));

    const repo2 = F.makeRepo("f9b");
    const turn2 = F.newTurn(F.newSid("f9b"));
    foreignCommits(F, repo2, F.bareTip(repo2), N, decoys(turn2));
    const R2 = F.bareTip(repo2);
    fetchAll(repo2);
    F.check("F9 only decoys match the turnId, no matching trailer -> R", TC.turnStartOf(repo2.dir, R2, turn2) === R2, TC.turnStartOf(repo2.dir, R2, turn2));
  });
}

module.exports = { run, foreignCommits };
