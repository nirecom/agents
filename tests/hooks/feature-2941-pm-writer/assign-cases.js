"use strict";
// /pm-add and /pm-remove cases of tests/hooks/feature-2941-pm-writer.js (#2941). No case markers.
const assert = require("node:assert");
const { test } = require("node:test");
const W = require("./fixture");
const { P } = W;

// active(issues) -> {sid, tag} of a fresh active PM, current generation of its tag.
function active(issues, extra) {
  const sid = W.nextSid();
  const tag = W.nextTag("PM-as");
  P.seedPm(sid, P.pm(Object.assign({ tag, issues }, extra || {})));
  return { sid, tag };
}

function assign() {
  test("A1 /pm-add adds the issues and logs the reason", () => {
    const { sid, tag } = active([5101]);
    const r = W.write(sid, P.wrapped("pm-add", "#5102 #5103 reason for adding"));
    W.assertAccepted(r, "add", tag);
    assert.match(String(r.context), /ended=false/);
    const pm = P.readPm(sid);
    assert.deepStrictEqual(W.nums(pm).sort(), [5101, 5102, 5103]);
    assert.strictEqual(W.lastLog(pm).op, "add");
    assert.match(String(W.lastLog(pm).reason), /reason for adding/);
  });
  test("A2 /pm-add of an issue another active PM holds is rejected with the owner's tag", () => {
    const other = active([5201]);
    const { sid } = active([5202]);
    const r = W.write(sid, P.wrapped("pm-add", "#5201"));
    W.assertBlocked(r);
    assert.ok(r.block.includes(other.tag), r.block);
    assert.deepStrictEqual(W.nums(P.readPm(sid)), [5202]);
  });
  test("A3 /pm-remove removes the issue and logs it", () => {
    const { sid, tag } = active([5301, 5302]);
    W.assertAccepted(W.write(sid, P.wrapped("pm-remove", "#5301 done")), "remove", tag);
    const pm = P.readPm(sid);
    assert.deepStrictEqual(W.nums(pm), [5302]);
    assert.strictEqual(W.lastLog(pm).op, "remove");
    assert.strictEqual(pm.archived_at, null);
  });
  test("A4 /pm-remove down to 0 issues archives the PM and says ended=true", () => {
    const { sid, tag } = active([5401]);
    const r = W.write(sid, "/pm-remove #5401");
    W.assertAccepted(r, "remove", tag);
    assert.match(String(r.context), /ended=true/);
    const pm = P.readPm(sid);
    assert.deepStrictEqual(W.nums(pm), []);
    assert.ok(typeof pm.archived_at === "string" && !Number.isNaN(Date.parse(pm.archived_at)), JSON.stringify(pm));
    assert.strictEqual(pm.tag, tag, "the archived PM keeps its tag so the tag stays used");
  });
  test("A5 /pm-add in an archived PM is rejected and changes nothing", () => {
    const { sid } = active([], { archived_at: "2026-11-02T00:00:00.000Z" });
    const before = P.readPm(sid);
    W.assertBlocked(W.write(sid, P.wrapped("pm-add", "#5501")));
    assert.deepStrictEqual(P.readPm(sid), before);
  });
  test("A6 /pm-remove of an issue not assigned is rejected", () => {
    const { sid } = active([5601]);
    W.assertBlocked(W.write(sid, P.wrapped("pm-remove", "#5699")));
    assert.deepStrictEqual(W.nums(P.readPm(sid)), [5601]);
  });
  test("A7 /pm-add in a session without a PM is rejected", () => {
    const sid = W.nextSid();
    P.seedState(sid);
    W.assertBlocked(W.write(sid, P.wrapped("pm-add", "#5701")));
    assert.strictEqual(P.readPm(sid), undefined);
  });
  test("A8 an old generation of the tag cannot write; the reason names the current session", () => {
    const tag = W.nextTag("PM-gen");
    const oldSid = W.nextSid();
    const curSid = W.nextSid();
    P.seedPm(oldSid, P.pm({ tag, issues: [5801], current_since: "2026-11-01T00:00:00.000Z" }));
    P.seedPm(curSid, P.pm({ tag, issues: [5801], current_since: "2026-11-05T00:00:00.000Z", upstream_session_id: oldSid }));
    const before = P.readPm(oldSid);
    for (const prompt of [P.wrapped("pm-add", "#5802"), P.wrapped("pm-remove", "#5801")]) {
      const r = W.write(oldSid, prompt);
      W.assertBlocked(r);
      assert.ok(r.block.includes(curSid), r.block);
    }
    assert.deepStrictEqual(P.readPm(oldSid), before);
  });
  refIdentity();
}

const HOME_REPO = "o2941/r2941";

// originCheckout() -> a throwaway git repo whose origin is HOME_REPO: the writer reads it from input.cwd.
function originCheckout() {
  const fs = require("node:fs");
  const os = require("node:os");
  const path = require("node:path");
  const cp = require("node:child_process");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pm-writer-origin-"));
  const git = (args) => {
    const r = cp.spawnSync("git", ["-C", dir, ...args], { encoding: "utf8", timeout: 20000 });
    assert.strictEqual(r.status, 0, `git ${args.join(" ")}: ${r.stderr}`);
  };
  git(["init", "-q"]);
  git(["config", "core.hooksPath", "/dev/null"]);
  git(["remote", "add", "origin", `https://github.com/${HOME_REPO}.git`]);
  require("node:test").after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

// refIdentity() — `#N` and `owner/repo#N` (owner/repo = the cwd's origin) name one issue in every check.
function refIdentity() {
  const cwd = originCheckout();
  const home = () => cwd;
  const full = (n) => `${HOME_REPO}#${n}`;
  test("N1 /pm-add o/r#N of an issue another PM holds as #N is rejected with the owner's tag", () => {
    const other = active([5901]);
    const { sid } = active([5902]);
    const r = W.write(sid, P.wrapped("pm-add", full(5901)), home());
    W.assertBlocked(r);
    assert.ok(r.block.includes(other.tag), r.block);
    assert.deepStrictEqual(W.nums(P.readPm(sid)), [5902]);
  });
  test("N1 /pm-init with #N of an issue another PM holds as o/r#N is rejected with the owner's tag", () => {
    const other = active([{ number: 5903, repo: HOME_REPO }]);
    const sid = W.nextSid();
    P.seedState(sid);
    const r = W.write(sid, P.wrapped("pm-init", `${W.nextTag("PM-nid")} #5903`), home());
    W.assertBlocked(r);
    assert.ok(r.block.includes(other.tag), r.block);
    assert.strictEqual(P.readPm(sid), undefined);
  });
  test("N1 control: the same number in another repo is a different issue", () => {
    active([5904]);
    const { sid, tag } = active([5905]);
    W.assertAccepted(W.write(sid, P.wrapped("pm-add", "x2941/y2941#5904"), home()), "add", tag);
  });
  test("N2 /pm-remove matches #N and o/r#N in both directions", () => {
    const a = active([5911, 5919]);
    W.assertAccepted(W.write(a.sid, P.wrapped("pm-remove", full(5911)), home()), "remove", a.tag);
    assert.deepStrictEqual(W.nums(P.readPm(a.sid)), [5919]);
    const b = active([{ number: 5912, repo: HOME_REPO }, 5918]);
    W.assertAccepted(W.write(b.sid, P.wrapped("pm-remove", "#5912"), home()), "remove", b.tag);
    assert.deepStrictEqual(W.nums(P.readPm(b.sid)), [5918]);
  });
  test("N3 /pm-add o/r#N of an issue this PM already holds as #N is rejected as a duplicate", () => {
    const { sid } = active([5921]);
    const before = P.readPm(sid);
    W.assertBlocked(W.write(sid, P.wrapped("pm-add", full(5921)), home()));
    assert.deepStrictEqual(P.readPm(sid), before);
  });
  test("N3 /pm-init #N o/r#N stores the issue once", () => {
    const sid = W.nextSid();
    P.seedState(sid);
    const tag = W.nextTag("PM-ndup");
    W.assertAccepted(W.write(sid, P.wrapped("pm-init", `${tag} #5922 ${full(5922)}`), home()), "init", tag);
    assert.deepStrictEqual(W.nums(P.readPm(sid)), [5922]);
  });
}

// refusedAdd(label, issue, holders, check, o) — another PM holds holders; /pm-add #issue in this PM is
// refused, check(block) holds and the issues stay; the case's PMs are archived afterwards.
function refusedAdd(label, issue, holders, check, o = {}) {
  test(label, () => {
    const oth = W.other(holders);
    const me = active([8490]);
    try {
      if (o.before) o.before();
      const r = W.write(me.sid, P.wrapped("pm-add", `#${issue}`));
      W.assertBlocked(r);
      check(r.block, oth);
      assert.deepStrictEqual(W.nums(P.readPm(me.sid)), [8490]);
    } finally {
      W.G.mode(null);
      W.archive(oth.sid);
      W.archive(me.sid);
    }
  });
}

// overlapAndReason() — /pm-add against the other PMs' range (Steps 3), the leading refs and the reason.
function overlapAndReason() {
  for (const n of [8011, 8012]) {
    refusedAdd(`V1 under A's PM (meta #8000 > meta #8010), /pm-add #${n} is refused upward naming A's tag`, n, [8000], (b, oth) => assert.ok(b.includes(oth.tag), b));
  }
  refusedAdd("V2 B's PM holds the child meta #8010: /pm-add of its parent meta #8000 is refused downward naming B's tag", 8000, [8010], (b, oth) => {
    assert.ok(b.includes(oth.tag) && b.includes("(down: "), b);
  });
  refusedAdd("V3 a forge failure refuses /pm-add: could not verify", 8406, [8400], (b) => assert.ok(b.includes("could not verify the overlap on the forge"), b), { before: () => W.G.mode("fail") });
  refusedAdd("V4 label-overflow on a held ancestor refuses /pm-add with the reduce-labels exit", 8201, [8200], (b) => {
    assert.ok(b.includes("label-overflow") && b.includes("retrying will not fix it") && b.includes("to 100 or fewer and retry"), b);
  });
  test("T5 only the refs right after /pm-add are assigned; the reason keeps its text verbatim", () => {
    const { sid, tag } = active([8491]);
    const why = "PM and EM work closely together—merged for the same reason as #2927, as agreed";
    const r = W.write(sid, P.wrapped("pm-add", `#8492 ${why}`));
    W.assertAccepted(r, "add", tag);
    const pm = P.readPm(sid);
    assert.deepStrictEqual(W.nums(pm), [8491, 8492]);
    assert.strictEqual(W.lastLog(pm).reason, why);
    assert.match(String(r.context), /reason=given/);
    W.archive(sid);
  });
  test("T5 /pm-add #1, #2 reason assigns both refs", () => {
    const { sid, tag } = active([8493]);
    W.assertAccepted(W.write(sid, P.wrapped("pm-add", "#8494, #8495 reason")), "add", tag);
    const pm = P.readPm(sid);
    assert.deepStrictEqual(W.nums(pm).sort(), [8493, 8494, 8495]);
    assert.strictEqual(W.lastLog(pm).reason, "reason");
    W.archive(sid);
  });
  for (const op of ["add", "remove"]) {
    test(`T6 /pm-${op} without a reason logs reason not stated and says reason=unstated`, () => {
      const { sid, tag } = active([8496, 8497]);
      const r = W.write(sid, P.wrapped(`pm-${op}`, op === "add" ? "#8498" : "#8497"));
      W.assertAccepted(r, op, tag);
      assert.strictEqual(W.lastLog(P.readPm(sid)).reason, W.UNSTATED);
      assert.match(String(r.context), /reason=unstated/);
      if (op === "remove") assert.deepStrictEqual(W.G.queries().slice(W.G.calls() - r.calls).filter((q) => !/pm: fieldValueByName|^project item-edit /.test(q)), [], "/pm-remove asked the forge for more than the PM field (#2942)");
      W.archive(sid);
    });
  }
}

module.exports = { assign, overlapAndReason };
