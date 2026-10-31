"use strict";
// Target and ref cases of tests/hooks/feat-user-prompt-submit-issue-title.js (#299): which prompts
// make a session a target, where its refs come from, and when the cache saves every spawn.
// No case markers.
const assert = require("node:assert");
const { test } = require("node:test");

// H1 — a typed /wf-init or /workflow-init decides the target and its refs.
function promptForms(F) {
  for (const [label, prompt, want] of [
    ["wrapped /wf-init", F.wrapped("wf-init", "#12"), "#12 Title12"],
    ["wrapped /workflow-init two refs", F.wrapped("workflow-init", "#12 #34"), "#12 #34 Title12"],
    ["bare /wf-init #12", "/wf-init #12", "#12 Title12"],
    ["bare /workflow-init #12", "/workflow-init #12", "#12 Title12"],
  ]) {
    test(`H1 ${label} emits ${JSON.stringify(want)} and records it in its own control dir`, () => {
      const sid = F.newSid("h1"); F.seed(sid);
      const r = F.call(sid, prompt, F.deps());
      assert.strictEqual(r, want);
      assert.strictEqual((F.readRecord(sid) || {}).last_emitted, want, JSON.stringify(F.readRecord(sid)));
    });
  }
  for (const [label, prompt] of [["/wf-init on line 2", "hello\n/wf-init #12"], ["/wf-init without a token", "/wf-init please start"]]) {
    test(`H1 ${label} emits nothing, fetches nothing`, () => {
      const sid = F.newSid("h1n"); F.seed(sid);
      const d = F.deps();
      const r = F.call(sid, prompt, d);
      assert.ok(F.quiet(r), JSON.stringify(r));
      assert.strictEqual(d.fetchCalls.length, 0);
    });
  }
}

// H2 — a later prompt is a target only after the begun mark, and only with refs in ## Issues.
function begunMark(F) {
  for (const status of ["in_progress", "complete"]) {
    test(`H2 workflow_init ${status} + ## Issues emits`, () => {
      const sid = F.newSid("h2"); F.seed(sid, { status }); F.writeIntent(sid, ["- #12: x", "- other#5"]);
      assert.strictEqual(F.call(sid, "continue please", F.deps()), "#12 other#5 Title12");
    });
  }
  const silent = [
    ["workflow_init pending", (sid) => { F.seed(sid, { status: "pending" }); F.writeIntent(sid, ["- #12: x"]); }],
    ["workflow_init absent", (sid) => { F.seed(sid); F.writeIntent(sid, ["- #12: x"]); }],
    ["begun mark without intent.md", (sid) => F.seed(sid, { status: "in_progress" })],
    ["begun mark with an empty ## Issues", (sid) => { F.seed(sid, { status: "in_progress" }); F.writeIntent(sid, []); }],
  ];
  for (const [label, make] of silent) {
    test(`H2 ${label}: emits nothing, 0 fetch, 0 spawn`, () => {
      const sid = F.newSid("h2n"); make(sid);
      const d = F.deps();
      const r = F.call(sid, "continue please", d);
      assert.ok(F.quiet(r), JSON.stringify(r));
      assert.strictEqual(d.fetchCalls.length, 0, JSON.stringify(d.fetchCalls));
      assert.strictEqual(d.spawnCalls.length, 0, F.cmds(d));
    });
  }
}

// H3 — a cached title needs no fetch and no spawn; a non-target session spawns nothing.
function cacheAndNonTarget(F) {
  test("H3 cache hit emits from cache with 0 fetch, and 0 spawn on the real path", () => {
    const sid = F.newSid("h3"); F.seed(sid);
    F.call(sid, "/wf-init #12", F.deps({ "#12": "Cached title" }));
    const d = F.deps();
    assert.strictEqual(F.call(sid, "/wf-init #12 #34", d), "#12 #34 Cached title");
    assert.strictEqual(d.fetchCalls.length, 0, JSON.stringify(d.fetchCalls));
    const real = F.deps(); delete real.fetchTitle;
    F.call(sid, "/wf-init #12", real);
    assert.ok(F.LOADED, "the hook entry is not loadable");
    assert.strictEqual(real.spawnCalls.length, 0, `no originUrl, no tracker: ${F.cmds(real)}`);
  });
  test("H3 non-target session: nothing, 0 spawn", () => {
    const off = F.deps(); delete off.fetchTitle;
    const other = F.newSid("h3n"); F.seed(other);
    const r = F.call(other, "plain question", off);
    assert.ok(F.quiet(r), JSON.stringify(r));
    assert.strictEqual(off.spawnCalls.length, 0, F.cmds(off));
  });
}

module.exports = { promptForms, begunMark, cacheAndNonTarget };
