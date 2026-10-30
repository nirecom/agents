"use strict";
// Same-turn replacement: R1-R4 (run, from feature-2768-plan-sync-turn-commit.js), R5-R7 and turnBaseOf
// (runMore, from feature-2768-plan-sync-turn-replace.js), and the overlayCommit parent/message extension.
// Remote facts are read from the bare repo with git.

const ID = "plan-sync <plan-sync@localhost>";

function setup(F, tag) {
  const repo = F.makeRepo(tag);
  const sid = F.newSid(tag);
  return { repo, sid, turn: F.newTurn(sid), a: F.planName(sid, "intent"), b: F.planName(sid, "outline"),
    c: F.planName(sid, "detail"), P: F.bareTip(repo), n0: F.bareCount(repo) };
}

function run(F) {
  F.guard("R1 same-turn writes a, b, a become one commit", () => {
    const s = setup(F, "r1");
    const r1 = F.writeSync(s.repo, s.a, "a1\n", { turn: s.turn });
    const r2 = F.writeSync(s.repo, s.b, "b1\n", { turn: s.turn });
    const r3 = F.writeSync(s.repo, s.a, "a2\n", { turn: s.turn });
    F.check("R1 every write pushed with its blob URL", [r1, r2, r3].every((r) => r.status === "pushed") &&
      r1.url === F.blobUrl(s.a) && r2.url === F.blobUrl(s.b) && r3.url === F.blobUrl(s.a), JSON.stringify([r1, r2, r3]));
    F.check("R1 bare gained exactly one commit", F.bareCount(s.repo) === s.n0 + 1, `${s.n0} -> ${F.bareCount(s.repo)}`);
    const tip = F.bareTip(s.repo);
    F.check("R1 parent is the pre-turn tip", JSON.stringify(F.parentsOf(s.repo, tip)) === JSON.stringify([s.P]), F.parentsOf(s.repo, tip));
    F.check("R1 author is plan-sync", F.authorOf(s.repo, tip) === ID, F.authorOf(s.repo, tip));
    const t = F.tipTrailers(s.repo);
    F.check("R1 rels [a, b] in trailer and list", JSON.stringify(t.rel) === JSON.stringify([s.a, s.b]) &&
      JSON.stringify(t.listed) === JSON.stringify([s.a, s.b]), JSON.stringify(t));
    F.check("R1 trailer names this turn", t.session[0] === s.sid && t.turn[0] === s.turn.turnId && t.session.length === 1, JSON.stringify(t));
    F.check("R1 Turn-Base is the pre-turn tip", t.base.length === 1 && t.base[0] === s.P, JSON.stringify(t.base));
    F.check("R1 subject", t.subject === `plan-sync: ${s.a} (+1 more)`, t.subject);
    F.check("R1 tree holds the latest content", F.showAt(s.repo, tip, s.a) === "a2" && F.showAt(s.repo, tip, s.b) === "b1",
      `${F.showAt(s.repo, tip, s.a)} / ${F.showAt(s.repo, tip, s.b)}`);
  });
  F.guard("R2 a new turn appends on the previous turn commit", () => {
    const s = setup(F, "r2");
    F.writeSync(s.repo, s.a, "a1\n", { turn: s.turn });
    const X = F.bareTip(s.repo);
    const t2 = F.newTurn(s.sid);
    const r = F.writeSync(s.repo, s.a, "a2\n", { turn: t2 });
    F.check("R2 pushed", r.status === "pushed", JSON.stringify(r));
    F.check("R2 two commits", F.bareCount(s.repo) === s.n0 + 2, F.bareCount(s.repo));
    F.check("R2 previous turn commit is the first parent", F.parentsOf(s.repo, F.bareTip(s.repo))[0] === X, F.parentsOf(s.repo, F.bareTip(s.repo)));
    F.check("R2 tip trailer is the new turn", F.tipTrailers(s.repo).turn[0] === t2.turnId, JSON.stringify(F.tipTrailers(s.repo)));
  });
  F.guard("R3 another session with the same turn id appends", () => {
    const s = setup(F, "r3");
    F.writeSync(s.repo, s.a, "a1\n", { turn: s.turn });
    const other = { sid: F.newSid("r3o"), turnId: s.turn.turnId };
    const rel = F.planName(other.sid, "intent");
    const r = F.writeSync(s.repo, rel, "o1\n", { turn: other });
    F.check("R3 pushed", r.status === "pushed", JSON.stringify(r));
    F.check("R3 two commits", F.bareCount(s.repo) === s.n0 + 2, F.bareCount(s.repo));
    F.check("R3 tip names the other session", F.tipTrailers(s.repo).session[0] === other.sid, JSON.stringify(F.tipTrailers(s.repo)));
  });
  F.guard("R4 without a turn every write appends a legacy commit", () => {
    const s = setup(F, "r4");
    F.writeSync(s.repo, s.a, "a1\n");
    F.writeSync(s.repo, s.a, "a2\n");
    F.check("R4 two commits", F.bareCount(s.repo) === s.n0 + 2, F.bareCount(s.repo));
    F.check("R4 message is exactly plan-sync: <rel>", F.bodyOf(s.repo, F.bareTip(s.repo)) === `plan-sync: ${s.a}`, F.bodyOf(s.repo, F.bareTip(s.repo)));
  });
}

function runMore(F) {
  F.guard("R5 a human commit carrying a matching trailer is never replaced", () => {
    const s = setup(F, "r5");
    F.writeSync(s.repo, s.a, "a1\n", { turn: s.turn });
    const H = F.humanPush(s.repo, s.b, "human\n", F.handTrailer(s.turn, [s.b], s.P));
    const r = F.writeSync(s.repo, s.a, "a2\n", { turn: s.turn });
    F.check("R5 pushed", r.status === "pushed", JSON.stringify(r));
    F.check("R5 human commit survives as the parent", F.parentsOf(s.repo, F.bareTip(s.repo))[0] === H, F.parentsOf(s.repo, F.bareTip(s.repo)));
    F.check("R5 three commits", F.bareCount(s.repo) === s.n0 + 3, F.bareCount(s.repo));
    F.check("R5 human content kept", F.showAt(s.repo, "refs/heads/main", s.b) === "human", F.showAt(s.repo, "refs/heads/main", s.b));
  });
  F.guard("R6 an unchanged write leaves the remote untouched", () => {
    const s = setup(F, "r6");
    F.writeSync(s.repo, s.a, "same\n", { turn: s.turn });
    const tip = F.bareTip(s.repo);
    const r = F.sync(s.repo, s.a, { turn: s.turn });
    F.check("R6 pushed with URL", r.status === "pushed" && r.url === F.blobUrl(s.a), JSON.stringify(r));
    F.check("R6 tip unchanged", F.bareTip(s.repo) === tip, `${tip} -> ${F.bareTip(s.repo)}`);
  });
  F.guard("R7 only rels whose bytes changed are listed", () => {
    const s = setup(F, "r7");
    F.writeSync(s.repo, s.c, "c0\n");
    const P = F.bareTip(s.repo);
    F.writeSync(s.repo, s.a, "a1\n", { turn: s.turn });
    const same = F.sync(s.repo, s.c, { turn: s.turn });
    F.check("R7 byte-equal c pushed with URL", same.status === "pushed" && same.url === F.blobUrl(s.c), JSON.stringify(same));
    F.check("R7 byte-equal c is not listed", JSON.stringify(F.tipTrailers(s.repo).rel) === JSON.stringify([s.a]), JSON.stringify(F.tipTrailers(s.repo).rel));
    F.writeSync(s.repo, s.c, "c1\n", { turn: s.turn });
    F.check("R7 changed c is listed after a", JSON.stringify(F.tipTrailers(s.repo).rel) === JSON.stringify([s.a, s.c]), JSON.stringify(F.tipTrailers(s.repo).rel));
    F.check("R7 still one turn commit on P", F.parentsOf(s.repo, F.bareTip(s.repo))[0] === P, F.parentsOf(s.repo, F.bareTip(s.repo)));
  });
  // R8 guards the tree rebuild (publishOnRemoteTip's carried entries): local main is ahead of the
  // remote with a sendable plan and a tracked file that must never leave the machine.
  F.guard("R8 replacement with a local-only sendable plan and a non-sendable tracked file", () => {
    const fs = require("node:fs");
    const s = setup(F, "r8");
    F.writeSync(s.repo, s.a, "a1\n", { turn: s.turn });
    const X = F.bareTip(s.repo);
    const secret = "notes-r8.txt";
    F.writePlan(s.repo, s.c, "c-local\n");
    F.record(s.repo, s.c);
    fs.writeFileSync(F.absOf(s.repo, secret), "must stay local\n");
    F.git(s.repo.dir, ["add", "-f", "--", s.c, secret]);
    F.git(s.repo.dir, ["commit", "-q", "-m", "local only"]);
    const L = F.git(s.repo.dir, ["rev-parse", "refs/heads/main"]);
    F.check("R8 precondition: local main is ahead of the remote", L !== X &&
      F.git(s.repo.dir, ["merge-base", "--is-ancestor", X, L], true).status === 0, `${X} ${L}`);
    const r = F.writeSync(s.repo, s.a, "a2\n", { turn: s.turn });
    F.check("R8 pushed with the blob URL", r.status === "pushed" && r.url === F.blobUrl(s.a), JSON.stringify(r));
    const tip = F.bareTip(s.repo);
    F.check("R8 replaced: still one turn commit on P", F.bareCount(s.repo) === s.n0 + 1 && F.parentsOf(s.repo, tip)[0] === s.P,
      `${F.bareCount(s.repo) - s.n0} ${F.parentsOf(s.repo, tip)}`);
    F.check("R8 remote tree holds a2 and the local-only plan", F.showAt(s.repo, tip, s.a) === "a2" && F.showAt(s.repo, tip, s.c) === "c-local",
      `${F.showAt(s.repo, tip, s.a)} / ${F.showAt(s.repo, tip, s.c)}`);
    const listed = F.git(s.repo.bare, ["ls-tree", "--name-only", tip]).split(/\r?\n/);
    F.check("R8 the non-sendable file is not in the remote tree", listed.includes(s.a) && !listed.includes(secret), listed.join(","));
  });
  F.guard("R-unit turnBaseOf", () => {
    const TC = F.mod("hooks/lib/plan-sync/turn-commit.js");
    if (!TC) return;
    const s = setup(F, "rtb");
    F.check("R-unit provision tip -> null", TC.turnBaseOf(s.repo.dir, s.P, s.turn) === null, "non-null");
    F.writeSync(s.repo, s.a, "a1\n", { turn: s.turn });
    const X = F.bareTip(s.repo);
    const got = TC.turnBaseOf(s.repo.dir, X, s.turn);
    F.check("R-unit own turn commit -> {X, parent, base, rels}", got && got.X === X && got.parent === s.P && got.base === s.P &&
      JSON.stringify(got.rels) === JSON.stringify([s.a]), JSON.stringify(got));
    F.check("R-unit other turn -> null", TC.turnBaseOf(s.repo.dir, X, F.newTurn(s.sid)) === null, "non-null");
    F.check("R-unit other sid -> null", TC.turnBaseOf(s.repo.dir, X, { sid: "ps2768-zz", turnId: s.turn.turnId }) === null, "non-null");
    const H = F.humanPush(s.repo, s.b, "h\n", F.handTrailer(s.turn, [s.b], X));
    F.git(s.repo.dir, ["fetch", "-q", "origin", `+refs/heads/main:refs/remotes/origin/main`]);
    F.check("R-unit human author -> null", TC.turnBaseOf(s.repo.dir, H, s.turn) === null, "non-null");
  });
}

function runOverlay(F) {
  F.guard("R-unit overlayCommit parent and message function", () => {
    const G = F.mod("hooks/lib/plan-sync/git.js");
    const s = setup(F, "rov");
    F.writeSync(s.repo, s.a, "a1\n");
    F.writeSync(s.repo, s.b, "b1\n");
    const base = F.bareTip(s.repo);
    const dir = s.repo.dir;
    const blobA = G.hashBytes(dir, "a-new\n");
    const blobB = F.git(dir, ["rev-parse", `${base}:${s.b}`]);
    let seen = null;
    const c = G.overlayCommit(dir, base, [{ rel: s.a, blob: blobA }, { rel: s.b, blob: blobB }],
      { parent: s.P, message: (rels) => { seen = rels; return `m:${rels.join(",")}`; } });
    F.check("R-unit overlay ok + changed", c && c.ok && c.changed === true, JSON.stringify(c));
    F.check("R-unit message fn gets only changed rels", JSON.stringify(seen) === JSON.stringify([s.a]), JSON.stringify(seen));
    F.check("R-unit opts.parent used", c.ok && F.git(dir, ["log", "-1", "--format=%P", c.commit]) === s.P, c.ok && F.git(dir, ["log", "-1", "--format=%P", c.commit]));
    F.check("R-unit message from fn", c.ok && F.git(dir, ["log", "-1", "--format=%B", c.commit]).trim() === `m:${s.a}`, c.ok && F.git(dir, ["log", "-1", "--format=%B", c.commit]));
    const same = G.overlayCommit(dir, base, [{ rel: s.b, blob: blobB }], { message: () => "never" });
    F.check("R-unit unchanged tree returns base", same && same.ok && same.commit === base && same.changed === false, JSON.stringify(same));
    const str = G.overlayCommit(dir, base, [{ rel: s.a, blob: blobA }], { message: "plain message" });
    F.check("R-unit string message, base as parent", str.ok && F.git(dir, ["log", "-1", "--format=%P%n%B", str.commit]).trim() ===
      `${base}\nplain message`, str.ok && F.git(dir, ["log", "-1", "--format=%P%n%B", str.commit]));
  });
  F.guard("R-unit overlayCommit changedRels table (indexBlobs `<mode> <blob> <stage>\\t<path>` parse)", () => runChangedTable(F));
}

// Each case: base files {rel: content} (modes overrides 100644 per rel), overlay entries
// [[rel, content]], and the changedRels the message function must receive (before the forced new rel). A rel the
// ls-files -z parse misses reads as changed, so every "same blob -> []" row is an accept boundary.
const CHANGED_CASES = [
  { name: "plain-same-blob", base: { "p.md": "x\n" }, entries: [["p.md", "x\n"]], want: [] },
  { name: "plain-new-blob", base: { "p.md": "x\n" }, entries: [["p.md", "y\n"]], want: ["p.md"] },
  { name: "absent-from-base", base: { "p.md": "x\n" }, entries: [["q.md", "x\n"]], want: ["q.md"] },
  { name: "spaces-in-path", base: { "a b c.md": "x\n" }, entries: [["a b c.md", "x\n"]], want: [] },
  // Leading only: Git for Windows (core.protectNTFS) drops a path ending in a space from the index.
  { name: "leading-space", base: { " lead.md": "x\n" }, entries: [[" lead.md", "x\n"]], want: [] },
  // lang-check: ignore — the non-ASCII path is the fixture under test.
  { name: "non-ascii-unquoted", base: { "計画 ü.md": "x\n" }, entries: [["計画 ü.md", "x\n"]], want: [] },
  { name: "nested-dir", base: { "d/e/f.md": "x\n" }, entries: [["d/e/f.md", "x\n"]], want: [] },
  { name: "path-shaped-like-a-record", base: { "100644 deadbeef 0 z.md": "x\n" }, entries: [["100644 deadbeef 0 z.md", "x\n"]], want: [] },
  { name: "exec-mode-same-blob", base: { "run.sh": "x\n" }, modes: { "run.sh": "100755" }, entries: [["run.sh", "x\n"]], want: [] },
  { name: "symlink-mode-same-blob", base: { "ln": "target\n" }, modes: { "ln": "120000" }, entries: [["ln", "target\n"]], want: [] },
  { name: "prefix-sibling-not-confused", base: { "a.md": "x\n", "a.md.bak": "x\n" }, entries: [["a.md", "x\n"], ["a.md.bak", "z\n"]], want: ["a.md.bak"] },
  { name: "duplicate-entry-listed-once", base: { "p.md": "x\n" }, entries: [["p.md", "y\n"], ["p.md", "y\n"]], want: ["p.md"] },
  { name: "first-seen-order", base: { "a.md": "x\n", "b.md": "x\n" }, entries: [["b.md", "1\n"], ["a.md", "1\n"]], want: ["b.md", "a.md"] },
];
// Rels overlayCommit refuses before touching the index (its /[\t\r\n\0]/ unsafe-path check).
const UNSAFE_CASES = [
  { name: "tab-in-rel", rel: "a\tb.md" },
  { name: "cr-in-rel", rel: "a\rb.md" },
  { name: "lf-in-rel", rel: "a\nb.md" },
  { name: "nul-in-rel", rel: "a\0b.md" },
];

function runChangedTable(F) {
  const G = F.mod("hooks/lib/plan-sync/git.js");
  if (!G) return;
  const dir = setup(F, "rct").repo.dir;
  const blob = (content) => G.hashBytes(dir, content);
  function baseCommit(files, modes) {
    const c = G.overlayCommit(dir, null, Object.entries(files).map(([rel, body]) => ({ rel, blob: blob(body) })), { message: "base" });
    if (!c.ok || !modes) return c.ok ? c.commit : null;
    const env = { GIT_INDEX_FILE: `${dir}/.git/rct-index-${process.pid}` };
    const step = (args, input) => G.runGit(dir, args, { env, input });
    step(["read-tree", c.commit]);
    step(["update-index", "--index-info"], Object.entries(modes).map(([rel, mode]) => `${mode} ${blob(files[rel])}\t${rel}\n`).join(""));
    const tree = step(["write-tree"]).stdout.trim();
    require("node:fs").rmSync(env.GIT_INDEX_FILE, { force: true });
    const ct = G.runGit(dir, ["commit-tree", tree, "-m", "base modes"], { env: G.COMMIT_IDENTITY });
    return ct.status === 0 ? ct.stdout.trim() : null;
  }
  // An unchanged tree never calls the message function, so every case also overlays one new rel.
  const FORCE = "zz-force-new.md";
  for (const { name, base, modes, entries, want } of CHANGED_CASES) {
    const b = baseCommit(base, modes);
    let seen = null;
    const c = b && G.overlayCommit(dir, b, [...entries, [FORCE, `${name}\n`]].map(([rel, body]) => ({ rel, blob: blob(body) })),
      { message: (rels) => { seen = rels; return "m"; } });
    const full = [...want, FORCE];
    F.check(`R-table ${name}: changedRels ${JSON.stringify(want)}`, Boolean(c && c.ok) && JSON.stringify(seen) === JSON.stringify(full),
      `base=${b} result=${JSON.stringify(c)} seen=${JSON.stringify(seen)}`);
  }
  const safeBase = baseCommit({ "p.md": "x\n" });
  for (const { name, rel } of UNSAFE_CASES) {
    const c = G.overlayCommit(dir, safeBase, [{ rel, blob: blob("y\n") }], { message: () => "m" });
    F.check(`R-table ${name}: refused as unsafe`, c && c.ok === false && c.error === "unsafe path in entries", JSON.stringify(c));
  }
}

module.exports = { run, runMore, runOverlay };
