"use strict";
// tests/bin/feature-3145-fix-in-session-verdict.js
// Tests: bin/github-issues/lib/validate-review-verdict.js
// Tags: TL1, bin, issue-create, verdict, fix-in-session, closes-session, candidate-cap, same-fix, validator, table-driven, scope:issue-specific, pwsh-not-required
// #3145 S5: `fix-in-session` hands a proposal back to the session whose PR closes the target issue.
// The target must be a candidate the survey marked `closes_session: true`; same_fix is true; children
// and related stay empty. closes_session is an optional boolean, and CANDIDATE_MAX (25) counts only the
// search candidates, so every closes_issues issue rides outside the cap. Legacy artifacts stay valid.

const { caseBegin, caseEnd } = require("../lib/harness");
const { test } = require("node:test");
const assert = require("node:assert");
const path = require("node:path");

const V = require(path.resolve(__dirname, "..", "..", "bin", "github-issues", "lib", "validate-review-verdict.js"));

function cand(number, extra) {
  return Object.assign({
    number, title: `c${number}`, state: "open", labels: [], body: `b${number}`,
    relation_status: "resolved", parent_number: null, parent_is_meta: false, has_sub_issues: false,
  }, extra || {});
}
function artifact(candidates, over) {
  return Object.assign({
    schema_version: 3, proposal: { title: "P", background: "B", changes: "C" },
    verdict: "none", target: null, children: [], related: [], reason: "survey", same_fix: false,
    relations_mode: "batched", relation_errors: [], candidates,
  }, over || {});
}
function raw(review) {
  return `FINAL_VERDICT_JSON:\n${JSON.stringify(Object.assign({ children: [], related: [], reason: "r", worth_filing: true }, review))}\n`;
}
const range = (from, n, extra) => Array.from({ length: n }, (_, i) => cand(from + i, extra));
// #10 is a search hit, #20 is an issue the session's PR closes.
const MIXED = () => artifact([cand(10), cand(20, { closes_session: true })]);

caseBegin("fix-in-session-grammar", "bin/github-issues/lib/validate-review-verdict.js");
test("fix-in-session-grammar: the verdict joins VERDICTS with same_fix true", () => {
  assert.ok(V.VERDICTS.includes("fix-in-session"), "VERDICTS lists fix-in-session");
  assert.ok(V.ARTIFACT_VERDICTS.includes("fix-in-session"), "the artifact grammar follows VERDICTS");
  assert.strictEqual(V.SAME_FIX_BY_VERDICT["fix-in-session"], true, "same_fix is true");
  assert.strictEqual(V.CANDIDATE_MAX, 25, "the search cap stays 25");
});
caseEnd();

caseBegin("fix-in-session-valid-and-invalid", "bin/github-issues/lib/validate-review-verdict.js");
test("fix-in-session-valid-and-invalid: target must be a closes_session candidate, shape fixed", () => {
  // [name, artifact, review, wantOk]
  const ROWS = [
    ["target is the closes_session candidate", MIXED(), { verdict: "fix-in-session", target: 20, same_fix: true }, true],
    ["target is a search candidate", MIXED(), { verdict: "fix-in-session", target: 10, same_fix: true }, false],
    ["target outside the survey", MIXED(), { verdict: "fix-in-session", target: 99, same_fix: true }, false],
    ["target null", MIXED(), { verdict: "fix-in-session", target: null, same_fix: true }, false],
    ["same_fix false", MIXED(), { verdict: "fix-in-session", target: 20, same_fix: false }, false],
    ["children non-empty", MIXED(), { verdict: "fix-in-session", target: 20, same_fix: true, children: [10] }, false],
    ["related non-empty", MIXED(), { verdict: "fix-in-session", target: 20, same_fix: true, related: [10] }, false],
    ["closes_session false on the target", artifact([cand(10), cand(20, { closes_session: false })]), { verdict: "fix-in-session", target: 20, same_fix: true }, false],
    ["closes_session is the string true", artifact([cand(10), cand(20, { closes_session: "true" })]), { verdict: "fix-in-session", target: 20, same_fix: true }, false],
    ["closes_session is 1", artifact([cand(10), cand(20, { closes_session: 1 })]), { verdict: "fix-in-session", target: 20, same_fix: true }, false],
    ["closes_session is null", artifact([cand(10), cand(20, { closes_session: null })]), { verdict: "none", target: null, same_fix: false }, false],
  ];
  for (const [name, art, review, wantOk] of ROWS) {
    const r = V.validate(art, raw(review));
    assert.strictEqual(r.ok, wantOk, `${name}: ok=${wantOk} (reason: ${r.reason})`);
    if (wantOk) assert.deepStrictEqual([r.review.verdict, r.review.target, r.review.same_fix], ["fix-in-session", 20, true], `${name}: canonical review`);
  }
});
caseEnd();

caseBegin("fix-in-session-survey-artifact", "bin/github-issues/lib/validate-review-verdict.js");
test("fix-in-session-survey-artifact: a survey may itself record fix-in-session", () => {
  const art = artifact([cand(10), cand(20, { closes_session: true })], { verdict: "fix-in-session", target: 20, same_fix: true });
  assert.deepStrictEqual(V.validateArtifact(art), { ok: true, reason: "" }, "fix-in-session artifact with same_fix true");
  const wrong = artifact([cand(20, { closes_session: true })], { verdict: "fix-in-session", target: 20, same_fix: false });
  assert.strictEqual(V.validateArtifact(wrong).ok, false, "same_fix false on a fix-in-session artifact");
});
caseEnd();

caseBegin("legacy-artifact-without-closes-session", "bin/github-issues/lib/validate-review-verdict.js");
test("legacy-artifact-without-closes-session: old artifacts and verdicts are unchanged", () => {
  const legacy = artifact([cand(10), cand(11)]);
  assert.strictEqual(V.validateArtifact(legacy).ok, true, "artifact without closes_session is valid");
  // [name, review, wantOk]
  const ROWS = [
    ["none", { verdict: "none", target: null, same_fix: false }, true],
    ["reopen", { verdict: "reopen", target: 10, same_fix: true }, true],
    ["sibling", { verdict: "sibling", target: null, same_fix: false, related: [10, 11] }, true],
    ["fix-in-session with no closes_session candidate", { verdict: "fix-in-session", target: 10, same_fix: true }, false],
    ["none with same_fix true", { verdict: "none", target: null, same_fix: true }, false],
    ["sibling with a target", { verdict: "sibling", target: 10, same_fix: false, related: [11] }, false],
  ];
  for (const [name, review, wantOk] of ROWS) {
    const r = V.validate(legacy, raw(review));
    assert.strictEqual(r.ok, wantOk, `${name}: ok=${wantOk} (reason: ${r.reason})`);
  }
});
caseEnd();

caseBegin("none-and-sibling-with-closes-candidates", "bin/github-issues/lib/validate-review-verdict.js");
test("none-and-sibling-with-closes-candidates: closes_session candidates do not change none / sibling", () => {
  const art = MIXED();
  assert.strictEqual(V.validate(art, raw({ verdict: "none", target: null, same_fix: false })).ok, true, "none");
  assert.strictEqual(V.validate(art, raw({ verdict: "sibling", target: null, same_fix: false, related: [10] })).ok, true, "sibling");
});
caseEnd();

caseBegin("candidate-cap-counts-search-only", "bin/github-issues/lib/validate-review-verdict.js");
test("candidate-cap-counts-search-only: 25 search + 30 closes valid, 26 search invalid", () => {
  const closes30 = range(1001, 30, { closes_session: true });
  // [name, candidates, wantOk]
  const ROWS = [
    ["25 search + 30 closes", range(1, 25).concat(closes30), true],
    ["0 search + 30 closes", closes30, true],
    ["26 search", range(1, 26), false],
    ["26 search + 30 closes", range(1, 26).concat(closes30), false],
    ["25 search + 1 closes_session false", range(1, 25).concat([cand(500, { closes_session: false })]), false],
  ];
  for (const [name, candidates, wantOk] of ROWS) {
    const r = V.validateArtifact(artifact(candidates));
    assert.strictEqual(r.ok, wantOk, `${name}: ok=${wantOk} (reason: ${r.reason})`);
  }
  const big = artifact(range(1, 25).concat(closes30));
  const r = V.validate(big, raw({ verdict: "fix-in-session", target: 1030, same_fix: true }));
  assert.strictEqual(r.ok, true, `fix-in-session on the 30th closes candidate past the cap (reason: ${r.reason})`);
});
caseEnd();
