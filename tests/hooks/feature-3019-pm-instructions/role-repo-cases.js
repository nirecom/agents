"use strict";
// resolveRole cases of tests/hooks/feature-3019-pm-instructions.js (#3019, #2942) that call role.js directly
// from a chosen cwd: the PM generation and the home-repo resolution of a bare #N. No case markers.
const assert = require("node:assert");
const cp = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const { gitInit } = require("../../lib/harness");
const W8 = require("./world");

const { P, makeWorld } = W8;

// roleIn(w, cwd, sid, issues) -> resolveRole's answer from a child whose process cwd (and opts.cwd, the
// assumed injection point) is cwd, under the 5 s hook deadline (the owner spawn needs one).
const ROLE_JS = path.join(W8.ROOT, "hooks", "lib", "pm-instructions", "role.js");
const DEADLINE_JS = path.join(W8.ROOT, "hooks", "lib", "hook-deadline.js");
function roleIn(w, cwd, sid, issues) {
  const script = "const q=JSON.parse(process.env.ROLE_REQ);const deadline=require(q.dl).createDeadline({hookTimeoutMs:5000});process.stdout.write(JSON.stringify(require(q.mod).resolveRole(q.sid,{issues:q.issues,cwd:q.cwd,deadline})))";
  const req = JSON.stringify({ mod: ROLE_JS, dl: DEADLINE_JS, sid, issues, cwd });
  const r = cp.spawnSync(process.execPath, ["-e", script], {
    cwd, env: w.env({ ROLE_REQ: req, GIT_CEILING_DIRECTORIES: path.dirname(cwd) }), encoding: "utf8", timeout: 60000,
  });
  if (r.status !== 0) throw new Error(`resolveRole child exit=${r.status}: ${String(r.stderr).slice(0, 400)}`);
  return JSON.parse(r.stdout);
}

// repoDir(S, name, origin) -> a fixture dir: a git repo with that origin, or a plain dir when origin is null.
function repoDir(S, name, origin) {
  const d = path.join(S.tmp, `cwd-${name}`);
  fs.mkdirSync(d, { recursive: true });
  if (origin === null) return d;
  gitInit(d);
  const g = cp.spawnSync("git", ["-C", d, "remote", "add", "origin", origin], { encoding: "utf8", timeout: 30000 });
  if (g.status !== 0) throw new Error(`git remote add: ${g.stderr}`);
  return d;
}

// currentGeneration: after a hand-over the upstream state keeps an active pm mark; only the file with the
// largest pm.current_since for the tag is the current generation and holds the PM role.
function currentGeneration(S) {
  const w = makeWorld(S, "gen");
  const cwd = repoDir(S, "gen", "https://github.com/o/r.git");
  const up = P.uuid(0x30190601);
  const down = P.uuid(0x30190602);
  w.pm(up, P.pm({ tag: "PM-gen", issues: [4601], current_since: "2026-11-01T00:00:00.000Z" }));
  w.pm(down, P.pm({ tag: "PM-gen", issues: [4601], current_since: "2026-11-08T00:00:00.000Z", upstream_session_id: up }));
  test("R-gen-1: an active pm mark that is not the current generation of its tag -> role null", () => {
    assert.deepStrictEqual(roleIn(w, cwd, up, []), { role: null });
  });
  test("R-gen-2: the current generation (largest current_since) -> role pm with its tag", () => {
    const r = roleIn(w, cwd, down, []);
    assert.strictEqual(r.role, "pm", JSON.stringify(r));
    assert.strictEqual(r.tag, "PM-gen", JSON.stringify(r));
  });
}

// homeRepo: `bin/pm-state owner` resolves a bare #N to its cwd origin's owner/repo and reads that issue's PM
// field. The former "bare PM ref" match is gone: the PM field always sits on a repo-qualified issue, so a cwd
// without an origin cannot resolve a bare #N (a failed lookup) while a repo-qualified ref still resolves.
function homeRepo(S) {
  const w = makeWorld(S, "home");
  const pmSid = P.uuid(0x30190701);
  const wf = P.uuid(0x30190702);
  w.pm(pmSid, P.pm({ tag: "PM-home", issues: [{ number: 4701, repo: "ownerA/repoA" }] }));
  w.field({ "ownerA/repoA#4701": "PM-home" });
  w.plain(wf);
  const inA = repoDir(S, "home-a", "https://github.com/ownerA/repoA.git");
  const inB = repoDir(S, "home-b", "https://github.com/ownerB/repoB.git");
  const noGit = repoDir(S, "home-none", null);
  test("R-repo-1: bare #N, cwd origin ownerB/repoB, the PM field set on ownerA/repoA#N only -> no owner, role null", () => {
    assert.deepStrictEqual(roleIn(w, inB, wf, [{ number: 4701 }]), { role: null });
  });
  test("R-repo-2: bare #N, cwd origin ownerA/repoA, the PM field of ownerA/repoA#N names the PM -> role workflow with that PM", () => {
    const r = roleIn(w, inA, wf, [{ number: 4701 }]);
    assert.strictEqual(r.role, "workflow", JSON.stringify(r));
    assert.deepStrictEqual(r.owners.map((o) => [o.tag, o.session_id]), [["PM-home", pmSid]], JSON.stringify(r));
  });
  test("R-repo-boundary: cwd without origin -> a bare #N cannot be repo-resolved: role null with an owner-lookup-failed reason", () => {
    const r = roleIn(w, noGit, wf, [{ number: 4701 }]);
    assert.strictEqual(r.role, null, JSON.stringify(r));
    assert.match(String(r.reason), /^owner lookup failed \(.*4701/, JSON.stringify(r));
  });
  test("R-repo-boundary: cwd without origin -> a repo-qualified ownerA/repoA#N still resolves to the PM", () => {
    const r = roleIn(w, noGit, wf, [{ number: 4701, repo: "ownerA/repoA" }]);
    assert.strictEqual(r.role, "workflow", JSON.stringify(r));
    assert.deepStrictEqual(r.owners.map((o) => o.session_id), [pmSid], JSON.stringify(r));
  });
}

module.exports = { currentGeneration, homeRepo };
