"use strict";
// Record cases of tests/hooks/feat-user-prompt-submit-issue-title.js (#299): the chain record at the
// first session, roots that cannot be confirmed, the last-emitted comparison and traversal ids.
// No case markers.
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");

// H6 — a downstream session compares against the chain's record and writes none of its own.
function chainRecord(F) {
  test("H6 the root emits; a downstream with the same candidate emits nothing and writes no record", () => {
    const sid1 = F.newSid("h6r"); F.seed(sid1);
    assert.strictEqual(F.call(sid1, "/wf-init #12", F.deps()), "#12 Title12", "root emits");
    const sid2 = F.newSid("h6d"); F.seed(sid2, { transcript: null, first: sid1 });
    const r = F.call(sid2, "/wf-init #12", F.deps());
    assert.ok(F.quiet(r), JSON.stringify(r));
    assert.ok(!fs.existsSync(F.recordPath(sid2)), "downstream wrote a record of its own");
    assert.strictEqual((F.readRecord(sid1) || {}).last_emitted, "#12 Title12", JSON.stringify(F.readRecord(sid1)));
  });
}

// H7 — every path that cannot confirm a root: nothing, no record, 0 fetch, 0 spawn.
function unconfirmedRoots(F) {
  for (const [label, make] of [
    ["no state", () => {}],
    ["corrupt state", (sid) => { fs.mkdirSync(path.dirname(F.WS.getStatePath(sid)), { recursive: true }); fs.writeFileSync(F.WS.getStatePath(sid), "{broken"); }],
    ["no ancestry and transcript_path null", (sid) => F.seed(sid, { transcript: null })],
    ["transcript_path null via a begun mark + ## Issues", (sid) => { F.seed(sid, { transcript: null, status: "in_progress" }); F.writeIntent(sid, ["- #12"]); }],
  ]) {
    test(`H7 ${label}: nothing, no record, 0 fetch, 0 spawn`, () => {
      const sid = F.newSid("h7"); make(sid);
      const d = F.deps();
      const r = F.call(sid, label.includes("begun") ? "continue" : "/wf-init #12", d);
      assert.ok(F.quiet(r), JSON.stringify(r));
      assert.ok(!fs.existsSync(F.recordPath(sid)), "a record was written");
      assert.strictEqual(d.fetchCalls.length, 0);
      assert.strictEqual(d.spawnCalls.length, 0, F.cmds(d));
    });
  }
}

// H8 — the candidate is compared with the chain's last_emitted only.
function lastEmitted(F) {
  test("H8 S1 -> S2 -> S1 emits all three; the same value again emits nothing", () => {
    const sid = F.newSid("h8"); F.seed(sid);
    const seq = ["/wf-init #12", "/wf-init #34", "/wf-init #12"].map((p) => F.call(sid, p, F.deps()));
    assert.deepStrictEqual(seq, ["#12 Title12", "#34 Title34", "#12 Title12"]);
    assert.ok(F.quiet(F.call(sid, "/wf-init #12", F.deps())), "the same value again was emitted");
  });
  test("H8 fork sharing one first sid re-emits every time (accepted risk)", () => {
    const a = F.newSid("h8a"); F.seed(a);
    const b = F.newSid("h8b"); F.seed(b, { transcript: null, first: a });
    const fork = [[a, "/wf-init #1"], [b, "/wf-init #2"], [a, "/wf-init #1"], [b, "/wf-init #2"]].map(([s, p]) => F.call(s, p, F.deps()));
    assert.deepStrictEqual(fork, ["#1 Title1", "#2 Title2", "#1 Title1", "#2 Title2"]);
  });
}

// H12 — a traversal session_id or first_session_id writes nothing and emits nothing.
function traversal(F) {
  for (const bad of ["../evil", "a/b", "..\\evil", ""]) {
    test(`H12 session_id ${JSON.stringify(bad)}: nothing, 0 fetch, no control dir written`, () => {
      const good = F.newSid("h12"); F.seed(good);
      const stateDir = path.dirname(F.WS.getStatePath(good));
      // A valid state sits where an unvalidated path.join would look, so only the sid check stops it.
      const planted = path.join(stateDir, `${bad}.json`);
      fs.mkdirSync(path.dirname(planted), { recursive: true });
      fs.writeFileSync(planted, fs.readFileSync(F.WS.getStatePath(good), "utf8"));
      const d = F.deps();
      const r = F.call(bad, "/wf-init #12", d);
      assert.ok(F.quiet(r), JSON.stringify(r));
      assert.strictEqual(d.fetchCalls.length, 0);
      assert.ok(!fs.existsSync(path.join(process.env.WORKFLOW_STATE_DIR, `${bad}.control`)), "control dir under the state root");
      assert.ok(!fs.existsSync(path.join(stateDir, `${bad}.control`)), "control dir beside the planted state");
    });
  }
  test("H12 first_session_id \"../x\": nothing, 0 fetch, no record anywhere", () => {
    const sid = F.newSid("h12f"); F.seed(sid, { first: "../x" });
    const stateDir = path.dirname(F.WS.getStatePath(sid));
    const d = F.deps();
    const r = F.call(sid, "/wf-init #12", d);
    assert.ok(F.quiet(r), JSON.stringify(r));
    assert.strictEqual(d.fetchCalls.length, 0);
    assert.ok(!fs.existsSync(F.recordPath(sid)), "a record was written for the session itself");
    for (const base of [process.env.WORKFLOW_STATE_DIR, stateDir]) {
      assert.ok(!fs.existsSync(path.join(base, "../x.control")), `control dir escaped to ${path.join(base, "../x.control")}`);
    }
  });
}

module.exports = { chainRecord, unconfirmedRoots, lastEmitted, traversal };
