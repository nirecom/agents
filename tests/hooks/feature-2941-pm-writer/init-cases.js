"use strict";
// /pm-init and /wf-init cases of tests/hooks/feature-2941-pm-writer.js (#2941). No case markers.
const assert = require("node:assert");
const { test } = require("node:test");
const W = require("./fixture");
const { P } = W;

function init() {
  test("I1 /pm-init PM-infra #2728 #2927 is accepted and writes the pm key", () => {
    const sid = W.nextSid();
    P.seedState(sid);
    const r = W.write(sid, P.wrapped("pm-init", "PM-infra #2728 #2927"));
    W.assertAccepted(r, "init", "PM-infra");
    assert.match(String(r.context), /ended=false/);
    const pm = P.readPm(sid);
    assert.strictEqual(pm.tag, "PM-infra");
    assert.deepStrictEqual(W.nums(pm), [2728, 2927]);
    assert.strictEqual(pm.archived_at, null);
    assert.ok(typeof pm.current_since === "string" && !Number.isNaN(Date.parse(pm.current_since)), JSON.stringify(pm));
    assert.strictEqual(W.lastLog(pm).op, "init");
  });
  test("I2 a later /pm-init pm-infra is rejected as a used tag (case-insensitive)", () => {
    const sid = W.nextSid();
    P.seedState(sid);
    W.assertBlocked(W.write(sid, P.wrapped("pm-init", "pm-infra #1")));
    assert.strictEqual(P.readPm(sid), undefined);
  });
  test("I3 the tag of an archived PM stays used", () => {
    const tag = W.nextTag("PM-arch");
    P.seedPm(W.nextSid(), P.pm({ tag, issues: [], archived_at: "2026-11-02T00:00:00.000Z" }));
    const sid = W.nextSid();
    P.seedState(sid);
    W.assertBlocked(W.write(sid, `/pm-init ${tag.toUpperCase()} theme`));
    assert.strictEqual(P.readPm(sid), undefined);
  });
  for (const [label, args] of [["a ref as the tag", "#2728"], ["a semicolon", "PM;infra #1"], ["a colon", "PM:infra #1"], ["no argument", ""]]) {
    test(`I4 /pm-init with ${label} is rejected`, () => {
      const sid = W.nextSid();
      P.seedState(sid);
      W.assertBlocked(W.write(sid, P.wrapped("pm-init", args)));
      assert.strictEqual(P.readPm(sid), undefined);
    });
  }
  test("I5 isValidPmTag accepts PM-infra and rejects the bad character classes, . and _ included", () => {
    const fn = P.load("hooks/pm-session/schema.js").isValidPmTag;
    assert.strictEqual(typeof fn, "function");
    assert.strictEqual(fn("PM-infra"), true);
    for (const bad of ["#2728", "PM;infra", "PM:infra", "PM infra", "PM.infra", "PM_infra", "", null]) assert.strictEqual(fn(bad), false, String(bad));
  });
  test("I6 an issue of another active PM is rejected with the owner's tag", () => {
    const owner = W.nextTag("PM-own");
    P.seedPm(W.nextSid(), P.pm({ tag: owner, issues: [4101], current_since: "2026-11-03T00:00:00.000Z" }));
    const sid = W.nextSid();
    P.seedState(sid);
    const r = W.write(sid, P.wrapped("pm-init", `${W.nextTag("PM-dup")} #4101`));
    W.assertBlocked(r);
    assert.ok(r.block.includes(owner), r.block);
    assert.strictEqual(P.readPm(sid), undefined);
  });
  test("I7 an issue of an archived PM is free to take", () => {
    P.seedPm(W.nextSid(), P.pm({ tag: W.nextTag("PM-old"), issues: [4102], archived_at: "2026-11-02T00:00:00.000Z" }));
    const sid = W.nextSid();
    P.seedState(sid);
    const tag = W.nextTag("PM-take");
    W.assertAccepted(W.write(sid, P.wrapped("pm-init", `${tag} #4102`)), "init", tag);
  });
  test("I8 /pm-init with a theme only starts a PM with 0 issues", () => {
    const sid = W.nextSid();
    P.seedState(sid);
    const tag = W.nextTag("PM-zero");
    const r = W.write(sid, P.wrapped("pm-init", `${tag} theme to discuss`));
    W.assertAccepted(r, "init", tag);
    const pm = P.readPm(sid);
    assert.deepStrictEqual(W.nums(pm), []);
    assert.strictEqual(pm.objective, "theme to discuss");
    assert.strictEqual(pm.archived_at, null);
  });
  for (const status of ["in_progress", "complete"]) {
    test(`I9 /pm-init in a workflow session (workflow_init ${status}) is rejected`, () => {
      const sid = W.nextSid();
      P.seedState(sid, { wfInit: status });
      W.assertBlocked(W.write(sid, P.wrapped("pm-init", `${W.nextTag()} #1`)));
      assert.strictEqual(P.readPm(sid), undefined);
    });
  }
  for (const archived of [null, "2026-11-02T00:00:00.000Z"]) {
    test(`I10 /pm-init in a session that already has a PM (${archived ? "archived" : "active"}) is rejected and keeps it`, () => {
      const sid = W.nextSid();
      const before = P.pm({ tag: W.nextTag("PM-self"), issues: [], archived_at: archived });
      P.seedPm(sid, before);
      W.assertBlocked(W.write(sid, P.wrapped("pm-init", `${W.nextTag()} theme`)));
      assert.deepStrictEqual(P.readPm(sid), before);
    });
  }
  test("I11 a /pm-init inside a cross-session message is not a typed command", () => {
    const sid = W.nextSid();
    P.seedState(sid);
    W.assertUntouched(W.write(sid, P.crossSession(P.wrapped("pm-init", `${W.nextTag()} #1`))));
    assert.strictEqual(P.readPm(sid), undefined);
  });
  test("I12 a plain prompt leaves the writer silent", () => {
    const sid = W.nextSid();
    P.seedState(sid);
    W.assertUntouched(W.write(sid, "hello"));
  });
}

function wfInit() {
  for (const archived of [null, "2026-11-02T00:00:00.000Z"]) {
    test(`I13 /wf-init in a PM session (${archived ? "archived" : "active"}) is rejected`, () => {
      const sid = W.nextSid();
      P.seedPm(sid, P.pm({ tag: W.nextTag("PM-wf"), issues: [], archived_at: archived }));
      W.assertBlocked(W.write(sid, P.wrapped("wf-init", "#12")));
      W.assertBlocked(W.write(sid, "/workflow-init #12"));
    });
  }
  test("I13 /wf-init in a session without the PM mark is not blocked", () => {
    const sid = W.nextSid();
    P.seedState(sid);
    const r = W.write(sid, P.wrapped("wf-init", "#12"));
    W.writer();
    assert.ok(!W.blocked(r) && !r.threw, JSON.stringify(r));
  });
}

// fresh() -> a plain session with no PM yet.
const fresh = () => { const sid = W.nextSid(); P.seedState(sid); return sid; };
// refusedInit(label, issue, holders, check, o) — another PM holds holders; /pm-init <tag> #issue is
// refused, check(block) holds, and the session gets no pm. The holder is archived afterwards.
function refusedInit(label, issue, holders, check, o = {}) {
  test(label, () => {
    const oth = holders ? W.other(holders, o.holder) : null;
    const sid = fresh();
    try {
      if (o.before) o.before();
      const r = W.write(sid, P.wrapped("pm-init", `${W.nextTag("PM-ov")} #${issue}`), o.cwd);
      W.assertBlocked(r);
      check(r.block, oth, r);
      assert.strictEqual(P.readPm(sid), undefined);
    } finally {
      W.G.mode(null);
      W.G.sleep(null);
      if (oth) W.archive(oth.sid);
      if (P.readPm(sid)) W.archive(sid);
    }
  });
}

// overlap() — /pm-init against the range of the other PMs (Steps 3), and its forge failures.
function overlap() {
  refusedInit("V1 under A's PM (meta #8000), /pm-init #8010 is refused upward naming A's tag", 8010, [8000], (b, oth) => {
    assert.ok(b.includes(oth.tag) && b.includes(oth.sid) && b.includes("8000"), b);
  });
  refusedInit("V1 under B's PM (meta #8030), /pm-init #8020 (B's parent meta) is refused downward naming B's tag", 8020, [8030], (b, oth) => {
    assert.ok(b.includes(oth.tag) && b.includes("8020"), b);
  });
  test("V2 a child of another PM's plain issue S is free; an archived PM's meta range does not count", () => {
    const s = W.other([8100]);
    const arc = W.other([8040], { archived_at: "2026-11-02T00:00:00.000Z" });
    for (const issue of [8101, 8041]) {
      const sid = fresh();
      const tag = W.nextTag("PM-free");
      W.assertAccepted(W.write(sid, P.wrapped("pm-init", `${tag} #${issue}`)), "init", tag);
      W.archive(sid);
    }
    W.archive(s.sid);
    W.archive(arc.sid);
  });
  const unverified = (b) => assert.ok(b.includes("could not verify the overlap on the forge") && b.includes("start with `/pm-init` without issues"), b);
  refusedInit("V3 a forge failure refuses: could not verify", 8401, [8400], (b) => { unverified(b); assert.ok(b.includes("gh_exec_failed"), b); }, { before: () => W.G.mode("fail") });
  refusedInit("V3 a forge slower than the 3 s budget refuses as timeout within the budget", 8402, [8400], (b, _o, r) => {
    unverified(b);
    assert.ok(b.includes("timeout"), b);
    assert.ok(r.ms < 6000, `took ${r.ms} ms`);
  }, { before: () => W.G.sleep(4000) });
  const notRetry = (b, ref, reason) => assert.ok(b.includes(`#${ref}`) && b.includes(reason) && b.includes("retrying will not fix it"), b);
  refusedInit("V4 label-overflow on a held ancestor is refused with the reduce-labels exit", 8201, [8200], (b) => {
    notRetry(b, 8201, "label-overflow");
    assert.ok(b.includes("to 100 or fewer and retry"), b);
  });
  refusedInit("V4 depth-cap is refused without the reduce-labels exit", 8311, [8400], (b) => {
    notRetry(b, 8311, "depth-cap");
    assert.ok(!b.includes("100 or fewer"), b);
  });
  refusedInit("V4 a #N with no origin repo is repo-unknown", 8403, [8400], (b) => notRetry(b, 8403, "repo-unknown"), { cwd: process.cwd() });
  // Alone, the forge sees only the PM field read/write and the sub-issue reads (descendant check, inbox meta_children baseline).
  test("V5 no forge call for an issue-less /pm-init; alone, only the PM field is read and written (#2942)", () => {
    const tag = W.nextTag("PM-nof");
    const r = W.write(fresh(), P.wrapped("pm-init", `${tag} theme`));
    W.assertAccepted(r, "init", tag);
    assert.strictEqual(r.calls, 0, W.brief(r));
    W.alone(() => {
      const t2 = W.nextTag("PM-solo");
      const r2 = W.write(fresh(), P.wrapped("pm-init", `${t2} #8404`));
      W.assertAccepted(r2, "init", t2);
      assert.deepStrictEqual(W.G.queries().slice(W.G.calls() - r2.calls).filter((q) => !/pm: fieldValueByName|^project item-edit |subIssues\(/.test(q)), [], W.brief(r2)); assert.strictEqual(W.G.pmStore().PVTI_o_r_8404, t2, "the PM field names the new PM");
    });
  });
}

// argsAndReason() — the tag's character set and length, the leading refs, and the init reason.
function argsAndReason() {
  for (const bad of ["PM.x", "PM_x"]) {
    test(`T1 /pm-init ${bad} is refused (only letters, digits and -)`, () => {
      const sid = fresh();
      W.assertBlocked(W.write(sid, P.wrapped("pm-init", `${bad}${W.nextSid().slice(0, 8)} theme`)));
      assert.strictEqual(P.readPm(sid), undefined);
    });
  }
  const tagOf = (len) => { const b = W.nextTag("PM-L"); return b + "x".repeat(len - b.length); };
  test("T2 a 40-character tag is accepted; a 41-character one is refused naming the limit", () => {
    const t40 = tagOf(40);
    W.assertAccepted(W.write(fresh(), P.wrapped("pm-init", `${t40} theme`)), "init", t40);
    const sid = fresh();
    const r = W.write(sid, P.wrapped("pm-init", `${tagOf(41)} theme`));
    W.assertBlocked(r);
    assert.ok(r.block.includes("40"), r.block);
    assert.strictEqual(P.readPm(sid), undefined);
  });
  test("T3 a #N inside the theme is not assigned: theme and init reason are the same text", () => {
    const sid = fresh();
    const tag = W.nextTag("PM-th");
    const r = W.write(sid, P.wrapped("pm-init", `${tag} groundwork, migration #12`));
    W.assertAccepted(r, "init", tag);
    const pm = P.readPm(sid);
    assert.deepStrictEqual(W.nums(pm), []);
    assert.strictEqual(pm.objective, "groundwork, migration #12");
    assert.strictEqual(W.lastLog(pm).reason, "groundwork, migration #12");
    assert.match(String(r.context), /reason=given/);
  });
  test("T4 /pm-init without a theme logs reason not stated and says reason=unstated in context and notice", () => {
    const sid = fresh();
    const tag = W.nextTag("PM-ur");
    const r = W.write(sid, P.wrapped("pm-init", `${tag} #8405`));
    W.assertAccepted(r, "init", tag);
    assert.strictEqual(W.lastLog(P.readPm(sid)).reason, W.UNSTATED);
    for (const k of ["context", "notice"]) {
      assert.ok(String(r[k] || "").includes("reason=unstated") && String(r[k] || "").includes("8405"), `${k}: ${W.brief(r)}`);
    }
  });
}

module.exports = { init, wfInit, overlap, argsAndReason };
