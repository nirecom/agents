"use strict";
// Part of tests/hooks/feature-2768-plan-sync-turn-range.js: an unreadable log fails closed (audit run-0014).
// F12 (plan F8) turnStartOf returns "unknown" when its first-parent scan or whole-history grep fails, and the
// commit carries Plan-Sync-Turn-Base: unknown with no turnLinks; F13 (plan F9) a later commit of that turn keeps
// "unknown"; F10 parseTurnMessage accepts exactly "unknown" besides a 40-hex base; F11 turnRange -> null on an
// unreadable log or when the turn's newest commit has an "unknown" base. Plan F8/F9 labels are taken in range.js.

const { foreignCommits } = require("./range");

const baseOf = (F, repo, sha) => F.trailersOf(F.bodyOf(repo, sha)).base;
const isScanLog = (args) => args[0] === "log" && args.includes("--first-parent") && !args.includes("--fixed-strings");
const isGrepLog = (args) => args[0] === "log" && args.includes("--fixed-strings");

// failingLog(F, pred, times) -> {fired, restore}: the next <times> git calls whose args match <pred> fail as an
// unreadable log does (gitOut -> null, runGit -> non-zero exit). Patches the module the library itself shares.
function failingLog(F, pred, times) {
  const G = F.mod("hooks/lib/plan-sync/git.js");
  const orig = { gitOut: G.gitOut, runGit: G.runGit };
  let left = times;
  let fired = 0;
  const hit = (args) => {
    if (left <= 0 || !Array.isArray(args) || !pred(args)) return false;
    left -= 1;
    fired += 1;
    return true;
  };
  G.gitOut = function (dir, args) { return hit(args) ? null : orig.gitOut.apply(this, arguments); };
  G.runGit = function (dir, args) {
    return hit(args) ? { status: 128, stdout: "", stderr: "fatal: injected unreadable log (test)", timedOut: false } : orig.runGit.apply(this, arguments);
  };
  return { fired: () => fired, restore: () => Object.assign(G, orig) };
}

// learnedRepo(F, tag) -> a repo refusing forced updates whose plans dir already learned it (plansync.forceRejected).
function learnedRepo(F, tag) {
  const repo = F.makeRepo(tag, { deny: true });
  const t = F.newTurn(F.newSid(`${tag}l`));
  const rel = F.planName(t.sid, "intent");
  F.writeSync(repo, rel, "l1\n", { turn: t });
  F.writeSync(repo, rel, "l2\n", { turn: t });
  F.check(`${tag} precondition: remote learned`, F.config(repo.dir, "plansync.forceRejected") === "true", F.config(repo.dir, "plansync.forceRejected"));
  return repo;
}

function writeFailing(F, repo, rel, body, turn, pred) {
  const inj = failingLog(F, pred, 1);
  try {
    return Object.assign(F.writeSync(repo, rel, body, { turn }), { fired: inj.fired() });
  } finally {
    inj.restore();
  }
}

const UNKNOWN = JSON.stringify(["unknown"]);

function run(F) {
  const TC = F.mod("hooks/lib/plan-sync/turn-commit.js");
  if (!TC) return;
  F.guard("F12 an unreadable first-parent scan gives Turn-Base unknown and no turnLinks", () => {
    const repo = learnedRepo(F, "f12");
    const sid = F.newSid("f12");
    const turn = F.newTurn(sid);
    const a = F.planName(sid, "intent");
    const R = F.bareTip(repo);
    const r = writeFailing(F, repo, a, "a1\n", turn, isScanLog);
    const X = F.bareTip(repo);
    F.check("F12 precondition: pushed on R, the scan failed once", r.status === "pushed" && F.parentsOf(repo, X)[0] === R && r.fired === 1,
      `${JSON.stringify(r)} ${F.parentsOf(repo, X)}`);
    F.check("F12 trailer Plan-Sync-Turn-Base: unknown (not R)", JSON.stringify(baseOf(F, repo, X)) === UNKNOWN, JSON.stringify(baseOf(F, repo, X)));
    F.check("F12 unknown base -> no turnLinks", r.turnLinks === undefined, JSON.stringify(r.turnLinks));
    const fresh = F.newTurn(F.newSid("f12c"));
    F.check("F12 control: a readable log with no commit of the session -> R", TC.turnStartOf(repo.dir, R, fresh) === R, TC.turnStartOf(repo.dir, R, fresh));
    const late = TC.turnStartOf(repo.dir, R, fresh, { deadline: Date.now() - 1 });
    F.check("F12 deadline already past -> unknown", late === "unknown", late);
    const broken = TC.turnStartOf(repo.dir, "0".repeat(40), fresh);
    F.check("F12 unreadable tip (git log exits non-zero) -> unknown", broken === "unknown", broken);
  });
  F.guard("F12 an unreadable whole-history grep past the scan gives unknown", () => {
    const repo = F.makeRepo("f12g");
    foreignCommits(F, repo, F.bareTip(repo), TC.SCAN_LIMIT + 3);
    const R = F.bareTip(repo);
    F.git(repo.dir, ["fetch", "-q", repo.bare, "refs/heads/main"]);
    const turn = F.newTurn(F.newSid("f12g"));
    F.check("F12 control: the full scan and the grep find nothing -> R", TC.turnStartOf(repo.dir, R, turn) === R, TC.turnStartOf(repo.dir, R, turn));
    const inj = failingLog(F, isGrepLog, 1);
    let got;
    try { got = TC.turnStartOf(repo.dir, R, turn); } finally { inj.restore(); }
    F.check("F12 precondition: the grep ran and failed once", inj.fired() === 1, inj.fired());
    F.check("F12 grep failure -> unknown (not R)", got === "unknown", got);
  });
  F.guard("F13 a later commit of an unknown-base turn keeps unknown", () => {
    const repo = learnedRepo(F, "f13");
    const sid = F.newSid("f13");
    const turn = F.newTurn(sid);
    const a = F.planName(sid, "intent");
    const r1 = writeFailing(F, repo, a, "a1\n", turn, isScanLog);
    const X1 = F.bareTip(repo);
    const r2 = F.writeSync(repo, a, "a2\n", { turn });
    const X2 = F.bareTip(repo);
    F.check("F13 precondition: X2 appended on X1 (no replace)", r1.fired === 1 && r2.status === "pushed" && F.parentsOf(repo, X2)[0] === X1,
      `${r1.fired} ${JSON.stringify(r2)} ${F.parentsOf(repo, X2)}`);
    F.check("F13 X1 Turn-Base unknown", JSON.stringify(baseOf(F, repo, X1)) === UNKNOWN, JSON.stringify(baseOf(F, repo, X1)));
    F.check("F13 X2 Turn-Base stays unknown", JSON.stringify(baseOf(F, repo, X2)) === UNKNOWN, JSON.stringify(baseOf(F, repo, X2)));
    F.check("F13 no turnLinks for the later commit", r2.turnLinks === undefined, JSON.stringify(r2.turnLinks));
  });
  F.guard("F13 an unknown base read back from history propagates", () => {
    const repo = learnedRepo(F, "f13b");
    const sid = F.newSid("f13b");
    const turn = F.newTurn(sid);
    const a = F.planName(sid, "intent");
    const H = F.humanPush(repo, a, "h\n", F.handTrailer(turn, [a], "unknown"));
    const r = F.writeSync(repo, a, "a2\n", { turn });
    const Z = F.bareTip(repo);
    F.check("F13 precondition: Z appended on the unknown-base commit H", r.status === "pushed" && F.parentsOf(repo, Z)[0] === H,
      `${JSON.stringify(r)} ${F.parentsOf(repo, Z)}`);
    F.check("F13 Z Turn-Base copies H's unknown", JSON.stringify(baseOf(F, repo, Z)) === UNKNOWN, JSON.stringify(baseOf(F, repo, Z)));
    F.check("F13 no turnLinks", r.turnLinks === undefined, JSON.stringify(r.turnLinks));
  });
  F.guard("F11 turnRange is null on an unreadable log or an unknown base", () => {
    const repo = F.makeRepo("f11");
    const sid = F.newSid("f11");
    const turn = F.newTurn(sid);
    const a = F.planName(sid, "intent");
    const P = F.bareTip(repo);
    F.writeSync(repo, a, "a1\n", { turn });
    const X1 = F.bareTip(repo);
    const ok = TC.turnRange(repo.dir, X1, turn);
    F.check("F11 control: readable log -> range from P", ok && ok.base === P && JSON.stringify(ok.turnCommits) === JSON.stringify([X1]), JSON.stringify(ok));
    const late = TC.turnRange(repo.dir, X1, turn, { deadline: Date.now() - 1 });
    F.check("F11 deadline already past -> null", late === null, JSON.stringify(late));
    const broken = TC.turnRange(repo.dir, "0".repeat(40), turn);
    F.check("F11 unreadable tip -> null", broken === null, JSON.stringify(broken));
    const inj = failingLog(F, isScanLog, 1);
    let failed;
    try { failed = TC.turnRange(repo.dir, X1, turn); } finally { inj.restore(); }
    F.check("F11 failing git log -> null", inj.fired() === 1 && failed === null, `${inj.fired()} ${JSON.stringify(failed)}`);
    const H = F.humanPush(repo, a, "h\n", F.handTrailer(turn, [a], "unknown"));
    F.git(repo.dir, ["fetch", "-q", repo.bare, "refs/heads/main"]);
    const unk = TC.turnRange(repo.dir, H, turn);
    F.check("F11 newest turn commit has base unknown -> null (older X1 not used)", unk === null, JSON.stringify(unk));
  });
}

function runTrailer(F) {
  const T = F.mod("hooks/lib/plan-sync/turn-trailer.js");
  if (!T) return;
  F.guard("F10 Turn-Base accepts a 40-hex SHA or exactly unknown", () => {
    const turn = { sid: "ps2768-sid-f10", turnId: "0123456789abcdef0123456789abcdef" };
    const sha = "89abcdef0123456789abcdef0123456789abcdef";
    const rt = T.parseTurnMessage(T.formatTurnMessage({ sid: turn.sid, turnId: turn.turnId, base: "unknown", rels: ["a.md"] }));
    F.check("F10 format/parse round-trip keeps base unknown", rt && rt.base === "unknown" && rt.sid === turn.sid && rt.turnId === turn.turnId &&
      JSON.stringify(rt.rels) === JSON.stringify(["a.md"]), JSON.stringify(rt));
    const cases = [
      { name: "unknown", input: "unknown", want: "unknown" },
      { name: "40-hex sha (control)", input: sha, want: sha },
      { name: "short hex deadbeef", input: "deadbeef", want: null },
      { name: "UNKNOWN uppercase", input: "UNKNOWN", want: null },
      { name: "Unknown capitalized", input: "Unknown", want: null },
      { name: "unknown with trailing space", input: "unknown ", want: null },
      { name: "unknown with leading space", input: " unknown", want: null },
      { name: "unknownx", input: "unknownx", want: null },
      { name: "sha followed by unknown", input: `${sha}unknown`, want: null },
      { name: "empty base", input: "", want: null },
    ];
    for (const { name, input, want } of cases) {
      const p = T.parseTurnMessage(F.handTrailer(turn, ["a.md"], input));
      const got = p ? p.base : null;
      F.check(`F10 ${name} -> ${JSON.stringify(want)}`, got === want, JSON.stringify(p));
    }
  });
}

module.exports = { run, runTrailer };
