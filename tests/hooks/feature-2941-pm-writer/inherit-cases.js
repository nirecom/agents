"use strict";
// /resume-session --from cases of tests/hooks/feature-2941-pm-writer.js (#2941). No case markers.
const assert = require("node:assert");
const { test } = require("node:test");
const W = require("./fixture");
const { P } = W;

const SEQ = { updated_at: "2026-11-01T01:00:00.000Z", tables: [{ title: "T", waves: [{ issues: [{ number: 6101, reason: "r", blocked_by: [], conflicts: [] }] }] }] };
const from = (up) => P.wrapped("resume-session", `--from ${up}`);

function upstream(extra) {
  const sid = W.nextSid();
  const tag = W.nextTag("PM-up");
  P.seedPm(sid, P.pm(Object.assign({ tag, issues: [6101, 6102], objective: "inherited PM", sequence: SEQ }, extra || {})));
  return { sid, tag, pm: P.readPm(sid) };
}

function inherit() {
  test("R1 --from an active PM copies tag, issues, objective and sequence into the new generation", () => {
    const up = upstream();
    const down = W.nextSid();
    P.seedState(down);
    const r = W.write(down, from(up.sid));
    W.assertAccepted(r, "inherit", up.tag);
    const pm = P.readPm(down);
    assert.strictEqual(pm.tag, up.tag);
    assert.deepStrictEqual(W.nums(pm), [6101, 6102]);
    assert.strictEqual(pm.objective, "inherited PM");
    assert.deepStrictEqual([pm.sequence.updated_at, pm.sequence.tables], [SEQ.updated_at, SEQ.tables]);
    assert.ok(pm.sequence.unverified === null || pm.sequence.unverified === undefined, JSON.stringify(pm.sequence));
    assert.strictEqual(pm.upstream_session_id, up.sid);
    assert.ok(Date.parse(pm.current_since) > Date.parse(up.pm.current_since), JSON.stringify(pm));
    assert.strictEqual(W.lastLog(pm).op, "inherit");
    assert.ok(typeof W.lastLog(pm).reason === "string" && W.lastLog(pm).reason.includes("sequence=copied"), JSON.stringify(W.lastLog(pm)));
    assert.match(String(r.context), /sequence=copied/);
    assert.strictEqual(pm.archived_at, null);
  });
  test("R2 --from an active PM creates the state of a new session that has none yet", () => {
    const up = upstream();
    const down = W.nextSid();
    assert.strictEqual(P.exists(down), false);
    W.assertAccepted(W.write(down, from(up.sid)), "inherit", up.tag);
    assert.strictEqual(P.readPm(down).tag, up.tag);
  });
  for (const wf of [null, "complete"]) {
    test(`R3 --from a non-PM upstream does nothing (downstream ${wf ? "workflow" : "plain"} session)`, () => {
      const up = W.nextSid();
      P.seedState(up, { wfInit: "complete" });
      const down = W.nextSid();
      P.seedState(down, { wfInit: wf || undefined });
      W.assertUntouched(W.write(down, from(up)));
      assert.strictEqual(P.readPm(down), undefined);
    });
  }
  test("R4 --from an archived PM inherits nothing", () => {
    const up = upstream({ issues: [], archived_at: "2026-11-02T00:00:00.000Z" });
    const down = W.nextSid();
    P.seedState(down);
    const r = W.write(down, from(up.sid));
    W.writer();
    assert.ok(!r.threw && !/op=inherit/.test(String(r.context || "")), JSON.stringify(r));
    assert.strictEqual(P.readPm(down), undefined);
  });
  for (const [label, seed] of [
    ["an active PM", (sid) => P.seedPm(sid, P.pm({ tag: W.nextTag("PM-mine"), issues: [] }))],
    ["an archived PM", (sid) => P.seedPm(sid, P.pm({ tag: W.nextTag("PM-mine"), issues: [], archived_at: "2026-11-02T00:00:00.000Z" }))],
    ["a workflow session", (sid) => P.seedState(sid, { wfInit: "in_progress" })],
  ]) {
    test(`R5 --from a PM into ${label} is rejected and the session's pm is unchanged`, () => {
      const up = upstream();
      const down = W.nextSid();
      seed(down);
      const before = P.readPm(down);
      const r = W.write(down, from(up.sid));
      W.assertBlocked(r);
      assert.deepStrictEqual(P.readPm(down), before);
      assert.strictEqual(r.calls, 0, "a cheap refusal asked the forge");
    });
  }
  test("R6 --from an old generation of a PM is rejected", () => {
    const old = upstream({ current_since: "2026-11-01T00:00:00.000Z" });
    P.seedPm(W.nextSid(), P.pm({ tag: old.tag, issues: [6101, 6102], current_since: "2026-11-06T00:00:00.000Z", upstream_session_id: old.sid }));
    const down = W.nextSid();
    P.seedState(down);
    const r = W.write(down, from(old.sid));
    W.assertBlocked(r);
    assert.strictEqual(P.readPm(down), undefined);
    assert.strictEqual(r.calls, 0, "an old-generation refusal asked the forge");
  });
}

const EMPTY = { updated_at: null, tables: [], unverified: null };
const tbl = (issues) => ({ updated_at: "2026-11-01T02:00:00.000Z", tables: [{ title: "T", waves: [{ issues: issues.map((i) => Object.assign({ number: i, reason: "r", blocked_by: [], conflicts: [] }, typeof i === "object" ? i : {})) }] }] });
// run(o) -> {up, down, r, pm}: upstream holds o.issues with table o.seq; the downstream inherits it.
function run(o) {
  const up = upstream({ issues: o.issues || [6101, 6102], sequence: o.seq });
  const down = W.nextSid();
  P.seedState(down);
  try {
    if (o.before) o.before(up);
    const r = W.write(down, from(up.sid), o.cwd);
    // tableCalls: the gh calls other than the post-lock inbox's one-time sub-issue read (#2942 meta_children baseline).
    const tableCalls = W.G.queries().slice(W.G.calls() - r.calls).filter((q) => !/subIssues\(/.test(q)).length;
    return { up, down, r, pm: P.readPm(down), sideLeft: W.G.sideArmed(), tableCalls };
  } finally {
    W.G.mode(null);
    W.G.sleep(null);
    W.G.clearSide();
    W.archive(up.sid);
    if (P.readPm(down)) W.archive(down);
  }
}
// notCopied(x, words, issues?) — the assignment (issues, else the upstream's) and tag came over, the
// table did not, no mark was set; context names sequence=not-copied and every word.
function notCopied(x, words, issues) {
  W.assertAccepted(x.r, "inherit", x.up.tag);
  assert.strictEqual(x.pm.tag, x.up.tag);
  assert.deepStrictEqual(W.nums(x.pm), issues || W.nums(x.up.pm));
  assert.deepStrictEqual(x.pm.sequence, EMPTY);
  const log = W.lastLog(x.pm);
  assert.ok(typeof log.reason === "string" && log.reason.includes("sequence=not-copied"), JSON.stringify(log));
  for (const w of ["sequence=not-copied"].concat(words)) assert.ok(String(x.r.context).includes(w), `${w}: ${W.brief(x.r)}`);
}

// sequenceCases() — the upstream table is checked before it is copied (Steps 3 --from).
function sequenceCases() {
  test("F1 a table beyond the upstream's range is not copied; context and notice name the ref", () => {
    const x = run({ seq: tbl([6101, 8500]) });
    notCopied(x, ["out-of-range", "8500"]);
    assert.ok(String(x.r.notice || "").includes("8500"), W.brief(x.r));
  });
  test("F1 a table missing a required field is structure, without a forge call", () => {
    const seq = tbl([6101]);
    delete seq.tables[0].waves[0].issues[0].blocked_by;
    const x = run({ seq });
    notCopied(x, ["structure"]);
    assert.strictEqual(x.tableCalls, 0, W.brief(x.r));
  });
  for (const field of ["blocked_by", "conflicts"]) {
    test(`F1 a table whose ${field} holds a malformed element is structure, without a forge call`, () => {
      const seq = tbl([6101]);
      seq.tables[0].waves[0].issues[0][field] = ["abc"];
      const x = run({ seq });
      notCopied(x, ["structure"]);
      assert.strictEqual(x.tableCalls, 0, W.brief(x.r));
    });
  }
  test("F1 an empty upstream table is sequence=none without a forge call", () => {
    const x = run({ seq: { updated_at: null, tables: [] } });
    W.assertAccepted(x.r, "inherit", x.up.tag);
    assert.match(String(x.r.context), /sequence=none/);
    assert.strictEqual(x.tableCalls, 0, W.brief(x.r));
  });
  for (const [reason, issues, table, cwd] of [
    ["label-overflow", [8200], [8201]], ["depth-cap", [8300], [8311]], ["cycle", [8320], [8321]], ["repo-unknown", [6101], [8510], process.cwd()],
  ]) {
    test(`F2 ${reason} in the table: not copied, no mark, the assignment comes over`, () => notCopied(run({ issues, seq: tbl(table), cwd }), [reason, String(table[0])]));
  }
  for (const [label, arm, reason] of [["a forge failure", () => W.G.mode("fail"), "gh_exec_failed"], ["a forge timeout", () => W.G.sleep(4000), "timeout"]]) {
    test(`F3 ${label}: the table is copied with the unverified mark (copied-unverified)`, () => {
      const seq = tbl([6101]);
      const x = run({ seq, before: arm });
      W.assertAccepted(x.r, "inherit", x.up.tag);
      assert.deepStrictEqual(x.pm.sequence.tables, seq.tables);
      assert.strictEqual((x.pm.sequence.unverified || {}).reason, reason, JSON.stringify(x.pm.sequence));
      assert.ok(String(x.r.context).includes("sequence=copied-unverified") && String(x.r.context).includes("--revalidate"), W.brief(x.r));
    });
  }
  test("F3 the upstream's unverified mark stays when the check passes", () => {
    const mark = { reason: "timeout", at: "2026-11-01T03:00:00.000Z" };
    const x = run({ seq: Object.assign(tbl([6101]), { unverified: mark }) });
    W.assertAccepted(x.r, "inherit", x.up.tag);
    assert.deepStrictEqual(x.pm.sequence.unverified, mark);
    assert.match(String(x.r.context), /sequence=copied\b/);
  });
  raceCases();
}

// raceCases() — the upstream changes while the forge is asked (the fake gh writes it mid-check).
function raceCases() {
  const race = (patch) => run({ seq: tbl([6101]), before: (up) => W.G.side(P.statePath(up.sid), patch(up)) });
  const consumed = (x) => assert.strictEqual(x.sideLeft, false, "the forge was not asked, so the race never fired");
  test("F4 the upstream's assignment changed mid-check: the re-read assignment comes over, the table does not", () => {
    const x = race(() => ({ issues: [{ number: 6101 }, { number: 6102 }, { number: 6103 }] }));
    consumed(x);
    notCopied(x, ["changed"], [6101, 6102, 6103]);
  });
  test("F4 the upstream's table changed mid-check: not copied as changed", () => {
    const x = race(() => ({ sequence: Object.assign(tbl([6101]), { updated_at: "2026-11-05T00:00:00.000Z" }) }));
    consumed(x);
    notCopied(x, ["changed"]);
  });
  for (const [label, patch] of [["archived", () => ({ issues: [], archived_at: "2026-11-05T00:00:00.000Z" })], ["renamed", () => ({ tag: W.nextTag("PM-ren") })]]) {
    test(`F4 the upstream was ${label} mid-check: the inheritance is refused`, () => {
      const x = race(patch);
      consumed(x);
      W.assertBlocked(x.r);
      assert.strictEqual(x.pm, undefined);
    });
  }
}

module.exports = { inherit, sequenceCases };
