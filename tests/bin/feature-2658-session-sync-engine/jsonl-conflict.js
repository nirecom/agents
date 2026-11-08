"use strict";
// Same-uuid conflict parts of the #2658 session-sync engine suite (release audit run-0010 item 1):
// when two machines hold different lines under one uuid, the kept line must not depend on which
// side is local, and a losing local line must be replaced by a full rewrite. The exact winner rule
// is not pinned: winnerOf derives it from union itself and fails when the two orders disagree.
// Holds no case markers; each export registers the tests of one case.
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const { jline } = require("./fixtures");

const lines = (...ls) => ls.join("\n") + "\n";
const K = "k-conflict";
const P = jline(K, { message: "alpha from one machine" });
const Q = jline(K, { message: "omega from the other machine" });
const A1 = jline("a1");
const B1 = jline("b1");

function linesFor(text, uuid) {
  return text.split("\n").filter((l) => {
    try {
      return JSON.parse(l).uuid === uuid;
    } catch (_) {
      return false;
    }
  });
}

// winnerOf(union) -> {win, lose}; asserts union(P, Q) and union(Q, P) keep the same line for K.
function winnerOf(union) {
  const kPQ = linesFor(union(lines(A1, P), lines(A1, Q)).text, K);
  const kQP = linesFor(union(lines(A1, Q), lines(A1, P)).text, K);
  assert.deepStrictEqual(kPQ, kQP, "the same-uuid winner must not depend on which side is local");
  assert.strictEqual(kPQ.length, 1, `exactly one line for ${K}: ${kPQ}`);
  return kPQ[0] === P ? { win: P, lose: Q } : { win: Q, lose: P };
}

const X = jline(K, { message: "middle from a third write" });
const S1 = '{"type":"summary","summary":"one"}';
const S2 = '{"type":"summary","summary":"two"}';

// rankK(union) -> {top, mid, low}: orders P, Q, X by the pairwise winner union itself picks
// (winnerOf asserts each pair is side-independent), so no case pins the exact winner rule.
function rankK(U) {
  const beats = (a, b) => linesFor(U(lines(A1, a), lines(A1, b)).text, K)[0] === a;
  for (const [a, b] of [[P, Q], [P, X], [Q, X]]) {
    assert.strictEqual(beats(a, b), !beats(b, a), "the pairwise same-uuid winner must not depend on the side");
  }
  const [top, mid, low] = [P, Q, X].sort((a, b) => (beats(a, b) ? -1 : 1));
  return { top, mid, low };
}

// Each case names its lines symbolically (A1, B1, S1, S2, P, top, mid, low) and states:
// k = the exact K lines of union(L,R) (and of union(R,L) when orders is "both"); oneK = exactly one
// K line, side-independent when orders is "both"; includes = lines every checked output holds;
// lr = exact fields of union(L,R), where text/appendText are symbol lists and "=remote" is verbatim.
const cases = [
  { name: "same-uuid conflict where the remote line wins", local: ["A1", "low"], remote: ["A1", "top"],
    orders: "both", k: ["top"], includes: ["A1"], lr: { replacedLocal: 1, uuidMismatch: 1 } },
  { name: "local already holds the winning line", local: ["A1", "top"], remote: ["A1", "low", "B1"],
    orders: "both", k: ["top"], lr: { text: ["A1", "top", "B1"], appendText: ["B1"], replacedLocal: 0 } },
  { name: "losing local line is replaced and later local lines stay", local: ["A1", "low", "B1"], remote: ["A1", "top"],
    orders: "both", k: ["top"], includes: ["A1", "B1"], lr: { replacedLocal: 1 } },
  { name: "remote superset without conflicts", local: ["A1", "P"], remote: ["A1", "P", "S1", "B1"],
    orders: "lr", lr: { remoteSuperset: true, text: "=remote", uuidMismatch: 0 } },
  { name: "distinct uuid-less lines", local: ["A1", "S1"], remote: ["A1", "S2"],
    orders: "both", includes: ["A1", "S1", "S2"] },
  { name: "local duplicates where the first local line wins", local: ["A1", "top", "low", "B1"], remote: ["A1", "mid"],
    orders: "both", k: ["top"], includes: ["A1", "B1"] },
  { name: "local duplicates where the first local line loses", local: ["A1", "low", "top"], remote: ["A1", "mid"],
    orders: "both", oneK: true, includes: ["A1"] },
  { name: "remote duplicates", local: ["A1", "mid"], remote: ["A1", "low", "top", "B1"],
    orders: "both", oneK: true, includes: ["A1", "B1"] },
  { name: "remote duplicates whose first line equals the local line", local: ["A1", "top"], remote: ["A1", "top", "low"],
    orders: "both", k: ["top"] },
  { name: "preferLocal keeps the losing local line", local: ["A1", "low"], remote: ["A1", "top"], opts: { preferLocal: true },
    orders: "lr", k: ["low"], lr: { replacedLocal: 0, uuidMismatch: 1 } },
  { name: "preferLocal with local duplicates keeps only the first local line", local: ["A1", "low", "top"],
    remote: ["A1", "mid"], opts: { preferLocal: true }, orders: "lr", k: ["low"], includes: ["A1"] },
];

function union(F) {
  for (const { name, local, remote, opts, orders, k, oneK, includes = [], lr = {} } of cases) {
    test(`jsonl.union table: ${name}`, () => {
      const U = F.lib("jsonl").union;
      const sym = Object.assign({ A1, B1, S1, S2, P }, rankK(U));
      const text = (names) => lines(...names.map((n) => sym[n]));
      const L = text(local);
      const R = text(remote);
      const outs = [["union(L,R)", U(L, R, opts)]];
      if (orders === "both") outs.push(["union(R,L)", U(R, L, opts)]);
      for (const [label, r] of outs) {
        const got = linesFor(r.text, K);
        if (k) assert.deepStrictEqual(got, k.map((n) => sym[n]), `${name}: ${label} K lines\n${r.text}`);
        if (oneK) assert.strictEqual(got.length, 1, `${name}: ${label} holds exactly one line for ${K}\n${r.text}`);
        const all = r.text.split("\n");
        for (const n of includes) assert.ok(all.includes(sym[n]), `${name}: ${label} holds ${n}\n${r.text}`);
      }
      if (outs.length === 2) {
        const [a, b] = outs.map(([, r]) => linesFor(r.text, K));
        assert.deepStrictEqual(a, b, `${name}: union(L,R) and union(R,L) must keep the identical ${K} lines`);
      }
      const r = outs[0][1];
      if (lr.text) assert.strictEqual(r.text, lr.text === "=remote" ? R : text(lr.text), `${name}: union(L,R) text`);
      if (lr.appendText) assert.strictEqual(r.appendText, text(lr.appendText), `${name}: union(L,R) appendText`);
      for (const f of ["remoteSuperset", "replacedLocal", "uuidMismatch"]) {
        if (f in lr) assert.strictEqual(r[f], lr[f], `${name}: union(L,R) ${f}`);
      }
    });
  }
}

// classifyConflict(F, localText, remoteText) -> {ops, final, deltaText}: runs classify on a real
// object store with W = localText and R = remoteText both changed from the base [A1].
function classifyConflict(F, localText, remoteText) {
  const G = F.lib("git");
  const dir = fs.mkdtempSync(path.join(F.TMP, "classify-"));
  F.git(dir, ["init", "-q"]);
  const rel = "p1/t.jsonl";
  const abs = path.join(dir, "p1", "t.jsonl");
  F.write(abs, localText);
  const blob = (t) => G.hashText(dir, t);
  const base = {
    mode: "sync", dir, host: "h", now: new Date(), R: null,
    lMap: new Map([[rel, { mode: "100644", blob: blob(lines(A1)) }]]),
    w: new Map([[rel, { kind: "mod", blob: blob(localText), mode: "100644", sig: F.lib("apply").statSig(abs) }]]),
    rDiff: new Map([[rel, { mode: "100644", newBlob: blob(remoteText) }]]),
    lDiff: new Map(), rMap: new Map(),
    stats: { uuidMismatch: 0, droppedMarkerLines: 0, conflicts: [] },
  };
  const { out } = F.lib("classify").classify(base);
  const ops = out.ops.filter((o) => o.rel === rel);
  let final = localText;
  for (const op of ops) {
    if (op.kind === "append") final += op.text;
    else final = op.kind === "text" ? op.text : G.catBlob(dir, op.blob).toString("utf8");
  }
  return { ops, final, deltaText: G.catBlob(dir, out.delta.get(rel).blob).toString("utf8") };
}

function classify(F) {
  test("classify rewrites the whole local transcript when the remote line wins a same-uuid conflict", () => {
    const { win, lose } = winnerOf(F.lib("jsonl").union);
    const r = classifyConflict(F, lines(A1, lose), lines(A1, win, B1));
    assert.ok(r.ops.some((o) => o.kind !== "append"), `a full rewrite op is required: ${JSON.stringify(r.ops)}`);
    assert.deepStrictEqual(linesFor(r.final, K), [win], `local must hold only the winning line: ${r.final}`);
    assert.ok(r.final.includes(B1), r.final);
    assert.strictEqual(r.deltaText, r.final, "M and W hold the same transcript");
  });
  test("classify only appends when the local line wins a same-uuid conflict", () => {
    const { win, lose } = winnerOf(F.lib("jsonl").union);
    const r = classifyConflict(F, lines(A1, win), lines(A1, lose, B1));
    assert.ok(r.ops.every((o) => o.kind === "append"), `no rewrite of the local line: ${JSON.stringify(r.ops)}`);
    assert.strictEqual(r.final, lines(A1, win, B1));
    assert.strictEqual(r.deltaText, r.final, "M and W hold the same transcript");
  });
}

function twoClone(F) {
  test("two machines editing the same-uuid line differently converge to a byte-identical transcript", () => {
    const okRun = (r, what) => assert.strictEqual(r.code, 0, `${what}: exit ${r.code}\nstdout: ${r.stdout}\nstderr: ${r.stderr}`);
    const w = F.world({ seed: { "p1/k.jsonl": lines(A1) } });
    fs.appendFileSync(path.join(w.a.projects, "p1", "k.jsonl"), P + "\n");
    fs.appendFileSync(path.join(w.b.projects, "p1", "k.jsonl"), Q + "\n");
    okRun(F.engine(w.a, "push"), "A push");
    okRun(F.engine(w.b, "push"), "B push");
    okRun(F.engine(w.a, "pull"), "A pull");
    okRun(F.engine(w.b, "pull"), "B pull");
    const a = fs.readFileSync(path.join(w.a.projects, "p1", "k.jsonl"), "utf8");
    const b = fs.readFileSync(path.join(w.b.projects, "p1", "k.jsonl"), "utf8");
    assert.strictEqual(a, b, "both machines must hold the byte-identical transcript");
    assert.strictEqual(F.show(w.remote, "main", "p1/k.jsonl"), a, "the remote holds the same transcript");
    const kept = linesFor(a, K);
    assert.strictEqual(kept.length, 1, `exactly one line for ${K}: ${a}`);
    assert.ok([P, Q].includes(kept[0]), kept[0]);
  });
}

module.exports = { union, classify, twoClone };
