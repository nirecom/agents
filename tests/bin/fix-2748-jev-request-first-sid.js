#!/usr/bin/env node
"use strict";
// Tests: bin/workflow/lib/jev-request-common.js
// Tags: TL2, jev, plan-artifact, session-inherit, regression-2748, scope:issue-specific, pwsh-not-required
// #2748: a session-downstream B (previous_session_ids [A]) finds its chain's plans under the
// first_session_id name A: artifactPathsFor and readArtifactsFor resolve intent/outline/detail to
// <A>-*.md, while context.md ("issue body") stays on B's own sid; a 3-generation chain keeps the first.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { test } = require("node:test");
const fs = require("fs");
const path = require("path");

const restore = isolate();
process.on("exit", () => restore());

const ROOT = path.resolve(__dirname, "..", "..");
const S = require(path.join(ROOT, "hooks/workflow-state/state-io"));
const C = require(path.join(ROOT, "bin/workflow/lib/jev-request-common.js"));
const PLANS = process.env.WORKFLOW_PLANS_DIR;

// check(name, fn) — one node:test test; fn fails it by throwing or by returning a message string.
function check(name, fn) {
  test(name, () => {
    const why = fn();
    if (typeof why === "string") assert.fail(why);
  });
}
function eq(got, want, what) {
  assert.strictEqual(JSON.stringify(got), JSON.stringify(want), `${what}: want=${JSON.stringify(want)} got=${JSON.stringify(got)}`);
}
const key = (p) => path.resolve(p).toLowerCase();
const plan = (name) => path.join(PLANS, name);

const A = "j2748-first";
const B = "j2748-down";
const ctx = { cwd: "/fixture/up", git_branch: "feature/up", transcript_path: "/fixture/t/up.jsonl" };
S.writeState(A, S.createInitialState(A, ctx));
const stB = S.createInitialState(B, ctx);
stB.previous_session_ids = [A];
stB.upstream_session_id = A;
S.writeState(B, stB);
for (const n of ["intent", "outline", "detail"]) fs.writeFileSync(plan(`${A}-${n}.md`), `# ${n} of ${A}\n`);
fs.writeFileSync(plan(`${B}-context.md`), "# context of B\n");
fs.writeFileSync(plan(`${A}-context.md`), "# context of A\n");

caseBegin("artifact-paths-for-first-sid-plans", "bin/workflow/lib/jev-request-common.js");
{
  check("J1: artifactPathsFor(B, write-tests) returns the A-named plans and B's own context.md", () => {
    const got = C.artifactPathsFor(B, "write-tests").map((e) => [e.section, key(e.file), e.copy]);
    eq(got, [
      ["intent", key(plan(`${A}-intent.md`)), "intent.md"],
      ["outline", key(plan(`${A}-outline.md`)), "outline.md"],
      ["detail", key(plan(`${A}-detail.md`)), "detail.md"],
      ["issue body", key(plan(`${B}-context.md`)), "context.md"],
    ], "artifactPathsFor");
  });
  check("J1: a first generation A still resolves to its own files", () => {
    const got = C.artifactPathsFor(A, "write-tests").map((e) => key(e.file));
    eq(got, ["intent", "outline", "detail", "context"].map((n) => key(plan(`${A}-${n}.md`))), "artifactPathsFor(A)");
  });
}
caseEnd();

caseBegin("read-artifacts-for-first-sid-plans", "bin/workflow/lib/jev-request-common.js");
{
  check("J2: readArtifactsFor(dir, B) reads the A-named plan files", () => {
    const got = C.readArtifactsFor(PLANS, B);
    eq(got, ["intent", "outline", "detail"].map((n) => ({ name: n, text: `# ${n} of ${A}\n` })), "readArtifactsFor");
  });
  check("J2: an invalid id reads nothing", () => eq(C.readArtifactsFor(PLANS, "../x"), [], "readArtifactsFor(invalid)"));
}
caseEnd();

// 3-generation session chain G1 -> G2 -> G3 (previous_session_ids oldest first, no first_session_id
// recorded): the plans stay on G1's name; G2- and G3-named plans are decoys.
const G1 = "j2748-g1";
const G2 = "j2748-g2";
const G3 = "j2748-g3";
S.writeState(G1, S.createInitialState(G1, ctx));
const stG2 = S.createInitialState(G2, ctx);
stG2.previous_session_ids = [G1];
stG2.upstream_session_id = G1;
S.writeState(G2, stG2);
const stG3 = S.createInitialState(G3, ctx);
stG3.previous_session_ids = [G1, G2];
stG3.upstream_session_id = G2;
S.writeState(G3, stG3);
for (const n of ["intent", "outline", "detail"]) {
  fs.writeFileSync(plan(`${G1}-${n}.md`), `# ${n} of ${G1}\n`);
  fs.writeFileSync(plan(`${G2}-${n}.md`), `# decoy ${n} of ${G2}\n`);
  fs.writeFileSync(plan(`${G3}-${n}.md`), `# decoy ${n} of ${G3}\n`);
}
fs.writeFileSync(plan(`${G3}-context.md`), "# context of G3\n");

caseBegin("three-generation-chain-first-sid-plans", "bin/workflow/lib/jev-request-common.js");
{
  check("J3: artifactPathsFor(G3, write-tests) returns G1's plans, not the middle generation's", () => {
    const got = C.artifactPathsFor(G3, "write-tests").map((e) => [e.section, key(e.file)]);
    eq(got, [
      ["intent", key(plan(`${G1}-intent.md`))],
      ["outline", key(plan(`${G1}-outline.md`))],
      ["detail", key(plan(`${G1}-detail.md`))],
      ["issue body", key(plan(`${G3}-context.md`))],
    ], "artifactPathsFor(G3)");
  });
  check("J3: readArtifactsFor(dir, G3) reads G1's plan text", () => {
    const got = C.readArtifactsFor(PLANS, G3);
    eq(got, ["intent", "outline", "detail"].map((n) => ({ name: n, text: `# ${n} of ${G1}\n` })), "readArtifactsFor(G3)");
  });
}
caseEnd();
