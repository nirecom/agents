"use strict";
// tests/hooks/feat-pm-repo-normalize-sequence-sync.js
// Tests: hooks/pm-session/writer-common.js, bin/lib/pm-state/cli.js, bin/lib/pm-state/sequence.js
// Tags: TL1, scope:common, issue-2942, pm-session, pm-state, normalize, sequence
// #2942 S4: writer-common's `resolved` becomes normalizeRef(ref, home), the one ref normalizer: a ref
// whose repo cannot be resolved is Refusal("repo-unresolved"); cli.normalizer and sequence.js use it.
// S9: removeFromSequence(sequence, refs) drops the rows of removed issues and, when a remaining row
// waits (blocked_by) on a removed issue, clears the verified mark (sequence.unverified becomes non-null).
// Assumed: removeFromSequence returns the new sequence or edits it in place (both accepted).

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test, after } = require("node:test");
const P = require("../lib/pm-state-fixture");

const restore = isolate();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "pm-normalize-"));
after(() => { fs.rmSync(tmp, { recursive: true, force: true }); restore(); });

const C = () => P.load("hooks/pm-session/writer-common.js");
const normalizeRef = (ref, home) => {
  const fn = C().normalizeRef;
  assert.strictEqual(typeof fn, "function", "writer-common does not export normalizeRef");
  return fn(ref, home);
};
const src = (rel) => fs.readFileSync(path.join(P.ROOT, rel), "utf8");
const HOME = "acme/widgets";

caseBegin("normalize-ref-single-implementation", "hooks/pm-session/writer-common.js");
for (const [label, ref, home, want] of [
  ["a bare ref takes the home repo", { number: 5 }, HOME, { number: 5, repo: HOME }],
  ["a qualified ref keeps its repo without a home", { number: 7, repo: "other/lib" }, null, { number: 7, repo: "other/lib" }],
  ["a qualified ref keeps its repo over the home", { number: 7, repo: "other/lib" }, HOME, { number: 7, repo: "other/lib" }],
]) {
  test(`${label}`, () => assert.deepStrictEqual(normalizeRef(ref, home), want));
}
test("normalizing twice is a no-op (idempotent)", () => {
  const once = normalizeRef({ number: 5 }, HOME);
  assert.deepStrictEqual(normalizeRef(once, null), once);
});
test("the old `resolved` export is gone (no second implementation)", () => {
  assert.strictEqual(require(path.join(P.ROOT, "hooks", "pm-session", "writer-common.js")).resolved, undefined);
});
caseEnd();

caseBegin("normalize-ref-repo-unresolved", "hooks/pm-session/writer-common.js");
for (const [label, ref, home] of [["a bare ref with no home repo", { number: 5 }, null], ["a bare ref with an empty home", { number: 5 }, ""]]) {
  test(`${label} -> Refusal("repo-unresolved")`, () => {
    assert.throws(() => normalizeRef(ref, home), (e) => e instanceof C().Refusal && /repo-unresolved/.test(e.message));
  });
}
// The writer path: the cwd is a plain directory (no origin), so the home repo is unresolved.
// The stub forge answers every ref with an empty ancestor chain (no parent), so no range check fails.
const noParents = (refs) => ({ ok: true, results: Object.fromEntries(refs.map((r) => [`${String(r.repo).toLowerCase()}#${r.number}`, { ok: true, chain: [] }])) });
const DEPS = { now: () => Date.parse("2026-11-21T00:00:00.000Z"), fetchAncestorChains: noParents };
const pmInit = (sid, args, extra) => P.load("hooks/pm-session/writer.js").runPmWriter(Object.assign({ session_id: sid, prompt: `/pm-init ${args}`, cwd: tmp }, extra || {}), DEPS) || {};
// The dedup case runs first: under the current code the refusal case below still writes a PM holding
// an unresolved #5, which would make this case's overlap check fail for an unrelated reason.
// An origin-less cwd now refuses before any PM field write (#2942), so this case pins a GitLab origin:
// the PM field is then skipped (no forge call) and only the normalization is under test.
test("/pm-init with qualified duplicates differing in case -> deduplicated after normalization", () => {
  const sid = P.uuid(0x29424002);
  P.seedState(sid);
  const r = pmInit(sid, `PM-norm2 ${HOME}#15 ACME/Widgets#15 other/lib#19`, { __origin: "https://gitlab.com/acme/widgets.git" });
  assert.ok(!r.block, JSON.stringify(r));
  const got = P.readPm(sid).issues.map((i) => `${String(i.repo).toLowerCase()}#${i.number}`);
  assert.deepStrictEqual(got, [`${HOME}#15`, "other/lib#19"]);
});
test("/pm-init mixing a bare ref (repo unknown) with its qualified duplicate -> refused repo-unresolved, nothing written", () => {
  const sid = P.uuid(0x29424001);
  P.seedState(sid);
  const r = pmInit(sid, `PM-norm1 #5 ${HOME}#5`);
  assert.ok(typeof r.block === "string" && /repo-unresolved|repo of #5/.test(r.block), JSON.stringify(r));
  assert.strictEqual(P.readPm(sid), undefined, "a refused /pm-init must not write pm");
});
caseEnd();

caseBegin("cli-normalizer-shares-normalize-ref", "bin/lib/pm-state/cli.js");
test("cli.normalizer(home) agrees with normalizeRef on a resolvable ref", () => {
  const cli = P.load("bin/lib/pm-state/cli.js");
  assert.deepStrictEqual(cli.normalizer(HOME)({ number: 5 }), normalizeRef({ number: 5 }, HOME));
});
test("cli.normalizer throws on an unresolvable ref", () => {
  assert.throws(() => P.load("bin/lib/pm-state/cli.js").normalizer(null)({ number: 5 }));
});
test("cli.js carries no own resolveRepo-based normalizer", () => {
  assert.ok(!/resolveRepo\(/.test(src("bin/lib/pm-state/cli.js")), "cli.js still normalizes with S.resolveRepo itself");
  assert.ok(/normalizeRef/.test(src("bin/lib/pm-state/cli.js")), "cli.js does not use normalizeRef");
});
caseEnd();

// [number, blocked_by numbers]
const row = (n, waits = []) => ({ number: n, reason: `r${n}`, blocked_by: waits.map((w) => ({ number: w })), conflicts: [] });
const seqOf = (rows) => ({ updated_at: "2026-11-20T00:00:00.000Z", tables: [{ title: "T", waves: [{ issues: rows }] }], unverified: null });
const numbers = (seq) => seq.tables.flatMap((t) => t.waves.flatMap((w) => w.issues.map((i) => i.number)));
function removeRows(seq, refs) {
  const fn = P.load("bin/lib/pm-state/sequence.js").removeFromSequence;
  assert.strictEqual(typeof fn, "function", "sequence.js does not export removeFromSequence");
  const out = fn(seq, refs);
  return out && typeof out === "object" ? out : seq;
}

caseBegin("remove-from-sequence", "bin/lib/pm-state/sequence.js");
test("sequence.js keeps no local `resolved` normalizer", () => {
  assert.ok(!/resolveRepo\(/.test(src("bin/lib/pm-state/sequence.js")), "sequence.js still normalizes with S.resolveRepo itself");
});
test("removing an issue nobody waits on drops its row and keeps the verified mark", () => {
  const out = removeRows(seqOf([row(1), row(2), row(3, [1])]), [{ number: 2 }]);
  assert.deepStrictEqual(numbers(out), [1, 3]);
  assert.strictEqual(out.unverified, null);
});
test("removing an issue a remaining row waits on drops its row and clears the verified mark", () => {
  const out = removeRows(seqOf([row(1), row(2), row(3, [2])]), [{ number: 2 }]);
  assert.deepStrictEqual(numbers(out), [1, 3]);
  assert.notStrictEqual(out.unverified, null, "the verified mark must be cleared");
  assert.notStrictEqual(out.unverified, undefined, "the verified mark must be cleared");
});
test("removing several issues at once", () => {
  assert.deepStrictEqual(numbers(removeRows(seqOf([row(1), row(2), row(3)]), [{ number: 1 }, { number: 3 }])), [2]);
});
test("removing an issue that is not in the table changes nothing", () => {
  const before = seqOf([row(1), row(2, [1])]);
  const out = removeRows(JSON.parse(JSON.stringify(before)), [{ number: 9 }]);
  assert.deepStrictEqual(numbers(out), [1, 2]);
  assert.strictEqual(out.unverified, null);
});
test("removing the same issue twice gives the same rows (idempotent)", () => {
  const once = removeRows(seqOf([row(1), row(2), row(3)]), [{ number: 2 }]);
  const twice = removeRows(JSON.parse(JSON.stringify(once)), [{ number: 2 }]);
  assert.deepStrictEqual(numbers(twice), numbers(once));
});
caseEnd();

caseBegin("remove-from-sequence-mixed-refs", "bin/lib/pm-state/sequence.js");
const removeWith = (seq, refs, opts) => P.load("bin/lib/pm-state/sequence.js").removeFromSequence(seq, refs, opts);
const AT = "2026-11-22T00:00:00.000Z";
test("bare (repo-unknown) and qualified refs with duplicates, home given -> exact remaining rows and unverified {removed, at}", () => {
  const r3 = { number: 3, repo: "other/lib", reason: "r3", blocked_by: [], conflicts: [] };
  const r4 = { number: 4, reason: "r4", blocked_by: [{ number: 1 }], conflicts: [] };
  const seq = { updated_at: "2026-11-20T00:00:00.000Z", tables: [{ title: "T", waves: [
    { issues: [{ number: 1, reason: "r1", blocked_by: [], conflicts: [] }, { number: 2, repo: HOME, reason: "r2", blocked_by: [], conflicts: [] }] },
    { issues: [r3, r4] },
  ] }], unverified: null };
  const out = removeWith(seq, [{ number: 2 }, { number: 2 }, { number: 1, repo: "ACME/Widgets" }, { number: 1 }], { homeRepo: HOME, at: AT });
  assert.deepStrictEqual(out.tables, [{ title: "T", waves: [{ issues: [r3, r4] }] }], "the emptied first wave is dropped, the rest kept as is");
  assert.deepStrictEqual(out.unverified, { reason: "removed", at: AT });
  assert.strictEqual(out.updated_at, "2026-11-20T00:00:00.000Z");
});
test("no home: a bare ref removes only the bare row, never a qualified row with the same number; unverified kept", () => {
  const kept = { number: 2, repo: "other/lib", reason: "q", blocked_by: [], conflicts: [] };
  const prior = { reason: "forge-timeout", at: "2026-11-19T00:00:00.000Z" };
  const seq = { tables: [{ title: "T", waves: [{ issues: [row(2), kept] }] }], unverified: prior };
  const out = removeWith(seq, [{ number: 2 }, { number: 2 }], {});
  assert.deepStrictEqual(out.tables, [{ title: "T", waves: [{ issues: [kept] }] }]);
  assert.deepStrictEqual(out.unverified, prior, "a remove with no orphaned wait keeps the earlier unverified mark");
});
test("a remove with duplicate refs is idempotent: a second run gives the same tables and unverified", () => {
  const seq = seqOf([row(1), row(2), row(3, [2])]);
  const once = removeWith(seq, [{ number: 2 }, { number: 2 }], { homeRepo: HOME, at: AT });
  const twice = removeWith(JSON.parse(JSON.stringify(once)), [{ number: 2 }, { number: 2 }], { homeRepo: HOME, at: "2026-12-01T00:00:00.000Z" });
  assert.deepStrictEqual(twice.tables, once.tables);
  assert.strictEqual(twice.unverified && twice.unverified.reason, "removed", JSON.stringify(twice.unverified));
});
caseEnd();
