"use strict";
// tests/bin/feat-pm-forge-failure.js
// Tests: bin/lib/forge-issue-links.js, bin/lib/pm-state/ancestry.js
// Tags: TL2, scope:common, issue-2942, pm-session, forge, graphql, retry
// #2942 S3: gh api graphql exits 1 when one issue of a batch does not exist but still prints data
// plus errors[].type NOT_FOUND. runChunk reads data on exit 1, marks only that slot issue_not_found
// and resolves the rest (classifyGraphqlResult); RETRYABLE holds only network and auth failures.
// A fake gh (generated into a tmp bin on PATH; the code spawns `bash -c 'exec gh'`) prints the response.
// TL3 gap: the exact stdout / stderr / exit code of a real gh against GitHub (NOT_FOUND batch, expired
// token, offline) is mirrored by hand here, not recorded live; a gh format change is caught only live.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { test, after } = require("node:test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const P = require("../lib/pm-state-fixture");

const restore = isolate();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "pm-forge-fail-"));
const bin = path.join(tmp, "bin");
fs.mkdirSync(bin);
const OUT = path.join(tmp, "stdout.json");
const LOG = path.join(tmp, "calls.log");
fs.writeFileSync(path.join(bin, "gh"), [
  "#!/bin/bash",
  "cat >/dev/null",
  "echo call >>\"$FAKE_GH_LOG\"",
  "cat \"$FAKE_GH_OUT\"",
  "[ -n \"$FAKE_GH_ERR\" ] && printf '%s\\n' \"$FAKE_GH_ERR\" >&2",
  "exit \"${FAKE_GH_EXIT:-0}\"",
  "",
].join("\n"), { mode: 0o755 });
const PATH_KEY = Object.keys(process.env).find((k) => k.toUpperCase() === "PATH") || "PATH";
const savedEnv = { path: process.env[PATH_KEY] };
process.env[PATH_KEY] = `${bin}${path.delimiter}${process.env[PATH_KEY]}`;
process.env.FAKE_GH_OUT = fwdSafe(OUT);
process.env.FAKE_GH_LOG = fwdSafe(LOG);
after(() => {
  process.env[PATH_KEY] = savedEnv.path;
  for (const k of ["FAKE_GH_OUT", "FAKE_GH_LOG", "FAKE_GH_ERR", "FAKE_GH_EXIT"]) delete process.env[k];
  fs.rmSync(tmp, { recursive: true, force: true });
  restore();
});
function fwdSafe(p) { return String(p).replace(/\\/g, "/"); }

const links = () => P.load("bin/lib/forge-issue-links.js");
const anc = () => P.load("bin/lib/pm-state/ancestry.js");
const REPO = "acme/widgets";
const ref = (n) => ({ repo: REPO, number: n });
const key = (n) => `${REPO}#${n}`;
const node = (n, parent = null, labels = []) => ({ number: n, repository: { nameWithOwner: REPO }, labels: { nodes: labels.map((name) => ({ name })), pageInfo: { hasNextPage: false } }, parent });

// gh(stdout, exit, stderr) -> fetchAncestorChains([#1, #2, #3]) against that canned response.
function fetchWith(body, exit, stderr = "") {
  fs.writeFileSync(OUT, body === null ? "" : JSON.stringify(body));
  process.env.FAKE_GH_EXIT = String(exit);
  process.env.FAKE_GH_ERR = stderr;
  return links().fetchAncestorChains([ref(1), ref(2), ref(3)], { timeoutMs: 30000 });
}
const PARTIAL = (errType) => ({
  data: { r0: { i0: node(1), i1: null, i2: node(3, node(10, null, ["meta"])) } },
  errors: [{ type: errType, path: ["r0", "i1"], locations: [{ line: 1, column: 1 }], message: "Could not resolve to an Issue with the number of 2." }],
});

caseBegin("forge-chunk-not-found-slot", "bin/lib/forge-issue-links.js");
test("exit 1 with data + NOT_FOUND on one slot -> only that slot is issue_not_found", () => {
  const r = fetchWith(PARTIAL("NOT_FOUND"), 1, "gh: Could not resolve to an Issue with the number of 2.");
  assert.strictEqual(r.ok, true, JSON.stringify(r));
  assert.deepStrictEqual(r.results[key(2)], { ok: false, reason: "issue_not_found" });
  assert.deepStrictEqual(r.results[key(1)], { ok: true, chain: [] });
  assert.deepStrictEqual(r.results[key(3)], { ok: true, chain: [{ number: 10, repo: REPO, meta: true }] });
});
test("the same response read twice gives the same result (idempotent read)", () => {
  const a = fetchWith(PARTIAL("NOT_FOUND"), 1);
  const b = fetchWith(PARTIAL("NOT_FOUND"), 1);
  assert.deepStrictEqual(a, b);
});
test("classifyGraphqlResult is exported as a function", () => {
  assert.strictEqual(typeof links().classifyGraphqlResult, "function");
});
caseEnd();

caseBegin("forge-chunk-other-errors", "bin/lib/forge-issue-links.js");
for (const errType of ["FORBIDDEN", "INTERNAL", "RATE_LIMITED"]) {
  test(`exit 1 with data + ${errType} on a slot -> that slot is never read as issue_not_found`, () => {
    const r = fetchWith(PARTIAL(errType), 1);
    if (r.ok) assert.notStrictEqual((r.results[key(2)] || {}).reason, "issue_not_found", JSON.stringify(r));
    else assert.notStrictEqual(r.reason, "issue_not_found", JSON.stringify(r));
  });
}
test("exit 1 with no data (auth failure) -> a whole-call failure, not issue_not_found", () => {
  const r = fetchWith(null, 4, "To get started with GitHub CLI, please run:  gh auth login");
  assert.strictEqual(r.ok, false, JSON.stringify(r));
  assert.notStrictEqual(r.reason, "issue_not_found");
});
caseEnd();

// ancestry over the real fetchAncestorChains and the fake gh: retryability is decided in ancestry only.
const holder = { tag: "PM-x", session_id: P.uuid(0x29423001), issues: [] };
function holdersVia(body, exit, stderr) {
  fs.writeFileSync(OUT, body === null ? "" : JSON.stringify(body));
  process.env.FAKE_GH_EXIT = String(exit);
  process.env.FAKE_GH_ERR = stderr || "";
  const a = anc().createAncestry({ fetchAncestorChains: links().fetchAncestorChains });
  a.prefetch([ref(1), ref(2), ref(3)]);
  return [1, 2, 3].map((n) => a.holdersOf(ref(n), [holder]));
}
caseBegin("ancestry-retryable-classes", "bin/lib/pm-state/ancestry.js");
test("a NOT_FOUND slot is issue_not_found and not retryable; its batch peers resolve", () => {
  const [h1, h2, h3] = holdersVia(PARTIAL("NOT_FOUND"), 1);
  assert.deepStrictEqual([h1.ok, h3.ok], [true, true], JSON.stringify([h1, h3]));
  assert.deepStrictEqual({ ok: h2.ok, reason: h2.reason, retryable: h2.retryable }, { ok: false, reason: "issue_not_found", retryable: false });
});
for (const [label, exit, stderr] of [
  ["auth failure", 4, "To get started with GitHub CLI, please run:  gh auth login"],
  ["HTTP 401", 1, "HTTP 401: Bad credentials (https://api.github.com/graphql)"],
  ["network failure", 1, "error connecting to api.github.com"],
]) {
  test(`${label} -> ok:false and retryable`, () => {
    for (const h of holdersVia(null, exit, stderr)) {
      assert.strictEqual(h.ok, false, JSON.stringify(h));
      assert.strictEqual(h.retryable, true, JSON.stringify(h));
      assert.ok(anc().RETRYABLE.has(h.reason), h.reason);
    }
  });
}
test("RETRYABLE excludes issue_not_found and parse_failed, keeps timeout", () => {
  const R = anc().RETRYABLE;
  assert.strictEqual(R.has("issue_not_found"), false);
  assert.strictEqual(R.has("parse_failed"), false, "a malformed answer is not a network or auth failure");
  assert.strictEqual(R.has("timeout"), true);
});
test("unparsable stdout on exit 0 -> parse_failed, not retryable", () => {
  fs.writeFileSync(OUT, "not json");
  process.env.FAKE_GH_EXIT = "0";
  process.env.FAKE_GH_ERR = "";
  const a = anc().createAncestry({ fetchAncestorChains: links().fetchAncestorChains });
  const h = a.holdersOf(ref(1), [holder]);
  assert.deepStrictEqual({ ok: h.ok, reason: h.reason, retryable: h.retryable }, { ok: false, reason: "parse_failed", retryable: false });
});
caseEnd();
