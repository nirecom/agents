#!/usr/bin/env node
"use strict";
// Tests: bin/vscode-cc-repair/patch/classify.js
// Tags: TL1, TL2, bin, vscode-cc-repair, classify, anchor, boundary, scope:issue-specific
// #2683: the single `sessionListOptions(){return{` anchor counts only when both sides look
// like a method definition: before it `{ } , ;` or offset 0; after the literal's `}` the
// method body's `}`, then `} , ;`, an identifier start, or end of file. Anything else —
// e.g. the anchor copied into a string or comment — refuses with reason=ambiguous-anchor.
// Group D drives the same rule through patchDir().

const { isolate } = require("../lib/harness");
const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");

const ROOT = path.join(__dirname, "..", "..");
const { classify, KEY } = require(path.join(ROOT, "bin", "vscode-cc-repair", "patch", "classify.js"));
const { patchDir, BUNDLE } = require(path.join(ROOT, "bin", "vscode-cc-repair", "patch", "apply.js"));

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "ccr-anchor-boundary-"));
test.after(() => {
  fs.rmSync(TMP, { recursive: true, force: true });
  restore();
});

const AMBIGUOUS = { state: "refused", reason: "ambiguous-anchor", anchorValue: "ambiguous", nAnchor: 1, site: false };
const UNPATCHED = { state: "unpatched", reason: undefined, anchorValue: "falsy", nAnchor: 1, site: true };

const METHOD = "sessionListOptions(){return{includeWorktrees:!1}}";
const REAL = "class X{" + METHOD + "}";
const A1 = 'var s="x;' + METHOD + '";';

const ROWS = [
  // A — the char after the method body's `}` (or after the literal) is not a member boundary.
  { name: "A1 double-quoted string", input: A1, want: AMBIGUOUS },
  { name: "A2 single-quoted string", input: "var s='x;" + METHOD + "';", want: AMBIGUOUS },
  { name: "A3 template literal", input: "var s=`x;" + METHOD + "`;", want: AMBIGUOUS },
  { name: "A5 line comment, newline after", input: "// x;" + METHOD + "\nvar y=1;", want: AMBIGUOUS },
  { name: "A6 block comment, space after", input: "/* x;" + METHOD + " */var y=1;", want: AMBIGUOUS },
  { name: "A10 no method-body close after the literal", input: "class X{sessionListOptions(){return{includeWorktrees:!1};x}}", want: AMBIGUOUS },
  // A9 — legacy keeps its single-literal verdict; only the anchor-value diagnostic changes.
  { name: "A9 legacy method on A1", input: A1, method: "legacy", want: { ...UNPATCHED, anchorValue: "ambiguous" } },
  // C — real method definitions keep today's verdicts.
  { name: "C1 offset 0 at end of file", input: METHOD, want: UNPATCHED },
  { name: "C2 class member followed by }", input: REAL, want: UNPATCHED },
  { name: "C3 object method followed by ,", input: "var o={" + METHOD + ",y:1};", want: UNPATCHED },
  { name: "C4 class member followed by ;", input: "class X{" + METHOD + ";a=1}", want: UNPATCHED },
  { name: "C5 followed by the next method identifier", input: "class X{" + METHOD + "get x(){return 1}}", want: UNPATCHED },
  { name: "C6 followed by a $-named method", input: "class X{" + METHOD + "$y(){return 1}}", want: UNPATCHED },
  { name: "C7 already-patched anchor", input: REAL.replace("!1", "!0"), want: { state: "already", reason: undefined, anchorValue: "truthy", nAnchor: 1, site: false } },
  { name: "C8 real anchor plus a string copy of the full anchor", input: 'var s="sessionListOptions(){return{";' + REAL, want: { state: "refused", reason: "multiple-anchors", anchorValue: "-", nAnchor: 2, site: false } },
];

for (const { name, input, method, want } of ROWS) {
  test(name, () => {
    const keyAt = input.indexOf(KEY);
    assert.strictEqual(keyAt, input.lastIndexOf(KEY), `${name}: fixture must hold exactly one KEY`);
    const got = classify(input, method ? { method } : undefined);
    assert.strictEqual(got.state, want.state, `${name}: state`);
    assert.strictEqual(got.reason, want.reason, `${name}: reason`);
    assert.strictEqual(got.counts.anchorValue, want.anchorValue, `${name}: counts.anchorValue`);
    assert.strictEqual(got.counts.nAnchor, want.nAnchor, `${name}: counts.nAnchor`);
    assert.strictEqual(got.siteOffset, want.site ? keyAt : -1, `${name}: siteOffset`);
  });
}

function extDir(name, body) {
  const dir = path.join(TMP, name);
  fs.mkdirSync(dir);
  fs.writeFileSync(path.join(dir, BUNDLE), body, "latin1");
  return dir;
}

test("D1 patchDir refuses a bundle whose only anchor sits in a string", () => {
  const name = "D1";
  const dir = extDir("d1", A1);
  const got = patchDir(dir, { method: "anchor", dryRun: false });
  assert.strictEqual(got.state, "refused", `${name}: state`);
  assert.deepStrictEqual(got.reasons, ["reason=ambiguous-anchor"], `${name}: reasons`);
  assert.strictEqual(fs.readFileSync(path.join(dir, BUNDLE), "latin1"), A1, `${name}: bundle bytes unchanged`);
  assert.deepStrictEqual(fs.readdirSync(dir), [BUNDLE], `${name}: no backup or temp file written`);
});

test("D2 patchDir still patches a real class member", () => {
  const name = "D2";
  const dir = extDir("d2", REAL);
  const got = patchDir(dir, { method: "anchor", dryRun: false });
  assert.strictEqual(got.state, "patched", `${name}: state`);
  assert.strictEqual(fs.readFileSync(path.join(dir, BUNDLE), "latin1"), REAL.replace("!1", "!0"), `${name}: only the site flipped`);
  assert.ok(fs.existsSync(path.join(dir, BUNDLE + ".bak")), `${name}: backup created`);
});
