"use strict";
// Case bodies for #3168's batched owner lookup (entry: tests/bin/feature-3135-pm-owner-gate.js). The entry wraps them in caseBegin /
// caseEnd and calls registerOwner / registerCommon here. The fake gh and PM state are the ones the entry prepares.

// owner.js side: resolveOwnersBatch calls readPmChains exactly once and returns a whole failure as {ok:false, reason}.
function registerOwner(t) {
  const { test, assert, P, ref, brief, entries, scan, owner } = t;
  const { refKey } = require(P.ROOT + "/bin/lib/forge-issue-links");
  // fakeRead(answer) -> a readPmChains that counts its calls; answer(refs) builds the return value.
  function fakeRead(answer) {
    const calls = [];
    const read = (refs, o) => { calls.push({ refs: refs.map((r) => r.number), o }); return answer(refs); };
    return { read, calls };
  }
  const chainOf = (r, pm) => ({ ok: true, chain: [{ repo: r.repo, number: r.number, pm }] });

  test("B1 resolveOwnersBatch calls the injected readPmChains once and returns every ref's answer in input order", () => {
    const refs = [ref(9201), ref(9202), ref(9203)];
    const pms = { 9201: "PM-hold", 9202: null, 9203: "PM-hold" };
    const f = fakeRead((rs) => ({ ok: true, results: Object.fromEntries(rs.map((r) => [refKey(r.repo, r.number), chainOf(r, pms[r.number])])) }));
    const mod = owner();
    assert.strictEqual(typeof mod.resolveOwnersBatch, "function", "resolveOwnersBatch is not exported");
    const r = mod.resolveOwnersBatch(refs, { scan, entries: entries(), timeoutMs: 4000, readPmChains: f.read });
    assert.strictEqual(f.calls.length, 1, `readPmChains calls: ${brief(f.calls)}`);
    assert.deepStrictEqual(f.calls[0].refs, [9201, 9202, 9203]);
    assert.ok(Number.isFinite(f.calls[0].o.deadlineAt), brief(f.calls[0].o));
    assert.strictEqual(r.ok, true, brief(r));
    assert.strictEqual(r.answers.length, 3, brief(r));
    assert.deepStrictEqual(r.answers.map((a) => [a.ok, a.owner && a.owner.tag]), [[true, "PM-hold"], [true, null], [true, "PM-hold"]], brief(r));
  });
  test("B2 resolveOwnersBatch's whole failure is {ok:false, reason} (not expanded into per-ref answers)", () => {
    for (const reason of ["timeout", "budget-exhausted", "spawn-failed", "gh_exec_failed"]) {
      const f = fakeRead(() => ({ ok: false, reason }));
      const r = owner().resolveOwnersBatch([ref(9201), ref(9202)], { scan, entries: entries(), readPmChains: f.read });
      assert.strictEqual(f.calls.length, 1);
      assert.deepStrictEqual(r, { ok: false, reason }, `${reason}: ${brief(r)}`);
    }
  });
  test("B3 resolveOwners stays the flattening of batched: same reason for every ref on whole failure, answer array on success", () => {
    const fail = fakeRead(() => ({ ok: false, reason: "timeout" }));
    const r = owner().resolveOwners([ref(9201), ref(9202)], { scan, entries: entries(), readPmChains: fail.read });
    assert.deepStrictEqual(r, [{ ok: false, reason: "timeout" }, { ok: false, reason: "timeout" }]);
    const okRead = fakeRead((rs) => ({ ok: true, results: Object.fromEntries(rs.map((x) => [refKey(x.repo, x.number), chainOf(x, "PM-hold")])) }));
    const r2 = owner().resolveOwners([ref(9201)], { scan, entries: entries(), readPmChains: okRead.read });
    assert.ok(Array.isArray(r2) && r2.length === 1 && r2[0].ok && r2[0].owner.tag === "PM-hold", brief(r2));
  });
}

// swapOwnersOf(common, fn, body) -> {out, calls, timeouts}: sets common.ownersOf to fn only during body(), recording each call's
// ref numbers and timeoutMs. decidedOwnersOf / decidedOwnerOf go through module.exports.ownersOf, so swapping the export reaches them.
function swapOwnersOf(common, fn, body) {
  const saved = common.ownersOf;
  const calls = [];
  const timeouts = [];
  common.ownersOf = (refs, timeoutMs, ...rest) => {
    calls.push((refs || []).map((r) => r.number));
    timeouts.push(timeoutMs);
    return fn(refs, timeoutMs, ...rest);
  };
  try { return { out: body(), calls, timeouts }; } finally { common.ownersOf = saved; }
}

// common.js side: ownersOf / decidedOwnersOf and the single-ref versions (ownerOf / decidedOwnerOf) share the same judgment.
function registerCommon(t) {
  const { test, assert, P, ref, brief, entries } = t;
  const C = () => P.load("bin/lib/pm-notify/common.js");
  test("T12 decidedOwnerOf(ref) equals decidedOwnersOf([ref]).answers[0] (absent / unset-held / ok)", () => {
    const c = C();
    assert.strictEqual(typeof c.decidedOwnersOf, "function", "decidedOwnersOf is not exported");
    for (const num of [9101, 9102, 9107]) {
      const one = c.decidedOwnerOf(ref(num), 60000, entries());
      const many = c.decidedOwnersOf([ref(num)], 60000, entries());
      assert.strictEqual(many.ok, true, `${num}: ${brief(many)}`);
      assert.deepStrictEqual(one, many.answers[0], `${num}: one=${brief(one)} many=${brief(many)}`);
    }
    // Each ref's judgment is also unchanged from #3135 (absent -> pm-field-absent, unset-held -> holding PM's tag, ok -> owner).
    const many = c.decidedOwnersOf([ref(9101), ref(9102), ref(9107)], 60000, entries());
    assert.strictEqual(many.ok, true, brief(many));
    assert.deepStrictEqual(many.answers[0], { ok: false, reason: "pm-field-absent" }, brief(many));
    assert.match(String(many.answers[1].reason), /^pm-field-unset-held: .*PM-hold/, brief(many));
    assert.deepStrictEqual([many.answers[2].ok, many.answers[2].owner && many.answers[2].owner.tag], [true, "PM-hold"], brief(many));
  });
  test("B4 a throw inside ownersOf returns {ok:false, reason:\"owner-error\"} (the throw does not escape)", () => {
    const c = C();
    assert.strictEqual(typeof c.ownersOf, "function", "ownersOf is not exported");
    // Resolving a chain with a pm (9107) against broken entries makes scan.generationOfTag throw a TypeError.
    const broken = [{ session_id: "broken", file: "x", pm: null }];
    let r;
    assert.doesNotThrow(() => { r = c.ownersOf([ref(9107)], 60000, broken); });
    assert.deepStrictEqual(r, { ok: false, reason: "owner-error" }, brief(r));
  });
  test("B5 single-ref ownerOf returns a whole failure as {ok:false, reason}, with the same reason as ownersOf's whole failure", () => {
    const c = C();
    // A gh that cannot start: the batched read becomes a whole failure.
    const dead = () => ({ error: Object.assign(new Error("spawn gh ENOENT"), { code: "ENOENT" }), status: null, stdout: "", stderr: "" });
    const batch = c.ownersOf([ref(9107)], 60000, entries(), { spawnSync: dead });
    assert.strictEqual(batch.ok, false, brief(batch));
    assert.ok(!Array.isArray(batch.answers), `a whole failure must not carry answers: ${brief(batch)}`);
    const one = c.ownerOf(ref(9107), 60000, entries(), { spawnSync: dead });
    assert.deepStrictEqual(one, { ok: false, reason: batch.reason }, `one=${brief(one)} batch=${brief(batch)}`);
  });
  test("B8 single-ref decidedOwnerOf returns ownersOf's whole failure as-is as {ok:false, reason} (ownersOf called once)", () => {
    const c = C();
    assert.strictEqual(typeof c.ownersOf, "function", "ownersOf is not exported");
    for (const reason of ["timeout", "budget-exhausted", "parse_failed"]) {
      const { out, calls } = swapOwnersOf(c, () => ({ ok: false, reason }), () => c.decidedOwnerOf(ref(9107), 60000, entries()));
      assert.strictEqual(calls.length, 1, `${reason}: ownersOf calls ${brief(calls)}`);
      assert.deepStrictEqual(out, { ok: false, reason }, `${reason}: ${brief(out)}`);
    }
  });
}

// inbox side: takeUnassigned looks up all unassigned refs in one ownersOf call and discards nothing on a whole failure.
// ownersOf is swapped through common's exports (decidedOwnersOf goes through module.exports.ownersOf).
function registerInbox(t) {
  const { test, assert, P, brief, X, INBOX, sid, ORIGIN } = t;
  const COMMON = P.load("bin/lib/pm-notify/common.js");
  const at = (num) => `o/r#${num}`;
  const entry = (num) => ({ id: `b-${num}`, point: "start", issue: at(num), from_session: sid(), at: "2026-11-01T00:00:00.000Z" });
  const withOwnersOf = (fn, body) => swapOwnersOf(COMMON, fn, body);
  test("B6 inbox: the unassigned lookup carries every ref in one ownersOf call, capped by runInbox's remaining budget (not cut at 2000)", () => {
    const me = sid();
    P.seedPm(me, P.pm({ tag: "PM-batch-inbox", issues: [] }));
    X.writeBox("unassigned", [9107, 9103].map(entry));
    const real = COMMON.ownersOf;
    assert.strictEqual(typeof real, "function", "ownersOf is not exported");
    const budgetMs = 60000;
    const { out, calls, timeouts } = withOwnersOf((...a) => real(...a), () => INBOX().runInbox(me, { origin: ORIGIN, budgetMs }));
    assert.strictEqual(calls.length, 1, `ownersOf calls: ${brief(calls)} / ${out}`);
    assert.deepStrictEqual([...calls[0]].sort(), [9103, 9107], brief(calls));
    const ms = Number(timeouts[0]);
    assert.ok(ms > 2000 && ms <= budgetMs, `ownersOf timeoutMs ${timeouts[0]} is not the inbox budget left (<= ${budgetMs})`);
    const left = X.readBox("unassigned").map((e) => e.id);
    assert.ok(left.includes("b-9107") && !left.includes("b-9103"), `9107 (another PM) stays, 9103 (no owner) goes: ${left}`);
  });
  test("B7 inbox: on ownersOf's whole failure (timeout) no unassigned entry is discarded and the still-holds line is printed", () => {
    const me = sid();
    P.seedPm(me, P.pm({ tag: "PM-batch-fail", issues: [] }));
    X.writeBox("unassigned", [9107, 9103].map(entry));
    const { out, calls } = withOwnersOf(() => ({ ok: false, reason: "timeout" }), () => INBOX().runInbox(me, { origin: ORIGIN, budgetMs: 60000 }));
    assert.strictEqual(calls.length, 1, `ownersOf calls: ${brief(calls)} / ${out}`);
    const left = X.readBox("unassigned").map((e) => e.id).sort();
    assert.deepStrictEqual(left, ["b-9103", "b-9107"], `a whole failure discarded a notification: ${left}`);
    assert.match(String(out), /unassigned\.jsonl still holds 2 notification/, String(out));
  });
}

module.exports = { registerOwner, registerCommon, registerInbox };
