"use strict";
// Forge cases of tests/hooks/feat-user-prompt-submit-issue-title.js (#299): the hook routes the title
// fetch through the origin's forge, a project-local self-hosted GitLab host and FORGE_TRACKER.
// No case markers.
const assert = require("node:assert");
const { test } = require("node:test");

const GLAB_JSON = (title) => ({ status: 0, stdout: JSON.stringify({ iid: 12, title }), stderr: "" });

// H11 — the hook routes through the forge of the origin, never a silent GitHub fallback.
function forgeRouting(F) {
  test("H11 GitLab origin: glab title, TRACKER_TIMEOUT_MS, no gh", () => {
    const c = F.constants();
    const gl = F.realPath("https://gitlab.com/g/p.git", { glab: GLAB_JSON("GL title") });
    const sid = F.newSid("h11"); F.seed(sid);
    const r = F.call(sid, "/wf-init #12", gl);
    assert.strictEqual(r, "#12 GL title");
    const glab = F.spawned(gl, "glab")[0];
    assert.ok(glab && c.TRACKER_TIMEOUT_MS !== undefined && glab.opts && glab.opts.timeout === c.TRACKER_TIMEOUT_MS, F.cmds(gl));
    assert.ok(F.LOADED && F.spawned(gl, "gh").length === 0, F.cmds(gl));
  });
  test("H11 unknown host: the origin was read, neither gh nor glab spawned, no title", () => {
    const un = F.realPath("https://example.com/o/r.git", { gh: { status: 0, stdout: "Wrong\n", stderr: "" }, glab: GLAB_JSON("Wrong") });
    const sid = F.newSid("h11u"); F.seed(sid);
    const r = F.call(sid, "/wf-init #12", un);
    assert.ok(F.spawned(un, "git").length > 0, F.cmds(un));
    assert.ok(F.quiet(r), JSON.stringify(r));
    assert.ok(F.spawned(un, "gh").length === 0 && F.spawned(un, "glab").length === 0, F.cmds(un));
  });
}

// H15 — GITLAB_HOSTNAME from the project's .env.local (stdin cwd = project root) routes a
// self-hosted origin to glab --hostname; without the overlay the host is unknown.
function selfHosted(F) {
  const ORIGIN = "https://git.corp.example/g/p.git";
  const answers = { glab: GLAB_JSON("Corp title"), gh: { status: 0, stdout: "Wrong\n", stderr: "" } };
  test("H15 .env.local GITLAB_HOSTNAME: glab --hostname git.corp.example, title emitted, no gh", () => {
    const dir = F.project("h15", ["GITLAB_HOSTNAME=git.corp.example"]);
    const d = F.realPath(ORIGIN, answers);
    const sid = F.newSid("h15"); F.seed(sid);
    const r = F.call(sid, "/wf-init #12", d, dir);
    assert.strictEqual(r, "#12 Corp title", F.cmds(d));
    const glab = F.spawned(d, "glab")[0];
    const args = (glab && glab.args) || [];
    const at = args.indexOf("--hostname");
    assert.ok(at >= 0 && args[at + 1] === "git.corp.example", JSON.stringify(args));
    assert.strictEqual(F.spawned(d, "gh").length, 0, F.cmds(d));
  });
  test("H15 control: same origin without the overlay -> no title, git read, no glab, no gh", () => {
    const dir = F.project("h15n", null);
    const d = F.realPath(ORIGIN, answers);
    const sid = F.newSid("h15n"); F.seed(sid);
    const r = F.call(sid, "/wf-init #12", d, dir);
    assert.ok(F.quiet(r), JSON.stringify(r));
    assert.ok(F.spawned(d, "git").length > 0, F.cmds(d));
    assert.strictEqual(F.spawned(d, "glab").length, 0, F.cmds(d));
    assert.strictEqual(F.spawned(d, "gh").length, 0, F.cmds(d));
  });
}

// H16 — FORGE_TRACKER in the project's .env.local picks the tracker, not the codehost.
function trackerPin(F) {
  const ORIGIN = "https://github.com/o/r.git";
  const answers = { gh: { status: 0, stdout: "GH title\n", stderr: "" }, glab: GLAB_JSON("GL title") };
  const runIn = (tag, envLines) => {
    const dir = F.project(tag, envLines);
    const d = F.realPath(ORIGIN, answers);
    const sid = F.newSid(tag); F.seed(sid);
    return { d, r: F.call(sid, "/wf-init #12", d, dir) };
  };
  test("H16 no FORGE_TRACKER: github origin -> gh title", () => {
    const { d, r } = runIn("h16", null);
    assert.strictEqual(r, "#12 GH title", F.cmds(d));
    assert.ok(F.spawned(d, "gh").length > 0, F.cmds(d));
  });
  test("H16 FORGE_TRACKER=gitlab: gh never spawned, the github title is not used", () => {
    const { d, r } = runIn("h16g", ["FORGE_TRACKER=gitlab"]);
    assert.ok(F.LOADED, "the hook entry is not loadable");
    assert.ok(F.spawned(d, "git").length > 0, F.cmds(d));
    assert.strictEqual(F.spawned(d, "gh").length, 0, F.cmds(d));
    assert.notStrictEqual(r, "#12 GH title");
  });
  for (const value of ["jira", "bogus"]) {
    test(`H16 FORGE_TRACKER=${value}: stub tracker -> no title, no gh, no glab`, () => {
      const { d, r } = runIn(`h16-${value}`, [`FORGE_TRACKER=${value}`]);
      assert.ok(F.quiet(r), JSON.stringify(r));
      assert.ok(F.spawned(d, "git").length > 0, F.cmds(d));
      assert.strictEqual(F.spawned(d, "gh").length, 0, F.cmds(d));
      assert.strictEqual(F.spawned(d, "glab").length, 0, F.cmds(d));
    });
  }
}

module.exports = { forgeRouting, selfHosted, trackerPin };
