"use strict";
// Tests: bin/user-block-guard.d/blocks.js
// Tags: TL1, user-block-guard, user-block, github, issue, pure-function, scope:issue-specific
// #2940 Step 2: extractBlocks(text) returns the raw `<user>`…`</user>` strings (CRLF/CR -> LF,
// depth-counted, nested kept inside the outer block, an unclosed tag runs to the end, a depth-0
// closing tag ignored); compareBlocks(old, next) answers "equal" / "added" / "changed".
const { caseBegin, caseEnd } = require("../lib/harness");

const assert = require("node:assert");
const path = require("node:path");
const { test } = require("node:test");

const MODULE = path.resolve(__dirname, "..", "..", "bin", "user-block-guard.d", "blocks.js");
// Loaded per case so a missing module fails each case, not the whole file at load time.
const load = () => require(MODULE);

caseBegin("extract-single-block", "bin/user-block-guard.d/blocks.js");
test("a single block is returned as its raw text, tags included", () => {
  const { extractBlocks } = load();
  assert.deepStrictEqual(extractBlocks("intro\n<user>keep this</user>\noutro"), ["<user>keep this</user>"]);
});
caseEnd();

caseBegin("extract-no-block", "bin/user-block-guard.d/blocks.js");
test("text without a block yields an empty list", () => {
  const { extractBlocks } = load();
  assert.deepStrictEqual(extractBlocks("plain body, mentions user but no tag"), []);
  assert.deepStrictEqual(extractBlocks(""), []);
});
caseEnd();

caseBegin("extract-multiple-blocks-in-order", "bin/user-block-guard.d/blocks.js");
test("several blocks come back in document order", () => {
  const { extractBlocks } = load();
  const text = "<user>one</user> mid <user>two</user>\n<user>three</user>";
  assert.deepStrictEqual(extractBlocks(text), ["<user>one</user>", "<user>two</user>", "<user>three</user>"]);
});
caseEnd();

caseBegin("extract-nested-kept-in-outer", "bin/user-block-guard.d/blocks.js");
test("a nested block belongs to the outer block's content", () => {
  const { extractBlocks } = load();
  const text = "a <user>outer <user>inner</user> tail</user> b";
  assert.deepStrictEqual(extractBlocks(text), ["<user>outer <user>inner</user> tail</user>"]);
});
caseEnd();

caseBegin("extract-unclosed-runs-to-end", "bin/user-block-guard.d/blocks.js");
test("an unclosed opening tag makes one block up to the end of the text", () => {
  const { extractBlocks } = load();
  assert.deepStrictEqual(extractBlocks("head <user>never closed\nsecond line"), ["<user>never closed\nsecond line"]);
});
caseEnd();

caseBegin("extract-depth-zero-close-ignored", "bin/user-block-guard.d/blocks.js");
test("a closing tag at depth 0 is ignored", () => {
  const { extractBlocks } = load();
  assert.deepStrictEqual(extractBlocks("stray </user> then <user>real</user>"), ["<user>real</user>"]);
  assert.deepStrictEqual(extractBlocks("only a stray </user>"), []);
});
caseEnd();

caseBegin("extract-crlf-normalized", "bin/user-block-guard.d/blocks.js");
test("CRLF and CR become LF before extraction", () => {
  const { extractBlocks } = load();
  assert.deepStrictEqual(extractBlocks("x\r\n<user>a\r\nb\rc</user>\r\n"), ["<user>a\nb\nc</user>"]);
});
caseEnd();

caseBegin("extract-uppercase-tags", "bin/user-block-guard.d/blocks.js");
test("tag names match case-insensitively and keep their raw spelling", () => {
  const { extractBlocks } = load();
  assert.deepStrictEqual(extractBlocks("<USER>loud</User >"), ["<USER>loud</User >"]);
});
caseEnd();

caseBegin("extract-attribute-tag", "bin/user-block-guard.d/blocks.js");
test("an opening tag with attributes still opens a block; a longer tag name does not", () => {
  const { extractBlocks } = load();
  assert.deepStrictEqual(extractBlocks('<user id="1" lang=ja>x</user>'), ['<user id="1" lang=ja>x</user>']);
  assert.deepStrictEqual(extractBlocks("<username>x</username>"), []);
});
caseEnd();

caseBegin("compare-equal", "bin/user-block-guard.d/blocks.js");
test("same count, order and content is equal; text outside the blocks does not matter", () => {
  const { extractBlocks, compareBlocks } = load();
  const oldB = extractBlocks("old intro <user>a</user> <user>b</user>");
  const newB = extractBlocks("new intro, rewritten <user>a</user> more <user>b</user> appended");
  assert.strictEqual(compareBlocks(oldB, newB), "equal");
  assert.strictEqual(compareBlocks([], []), "equal");
});
caseEnd();

caseBegin("compare-added", "bin/user-block-guard.d/blocks.js");
test("more blocks in next is added, even when another block was rewritten", () => {
  const { compareBlocks } = load();
  assert.strictEqual(compareBlocks([], ["<user>new</user>"]), "added");
  assert.strictEqual(compareBlocks(["<user>a</user>"], ["<user>a</user>", "<user>b</user>"]), "added");
  assert.strictEqual(compareBlocks(["<user>a</user>"], ["<user>A!</user>", "<user>b</user>"]), "added");
});
caseEnd();

caseBegin("compare-changed-content", "bin/user-block-guard.d/blocks.js");
test("a rewritten block is changed, whitespace included", () => {
  const { compareBlocks } = load();
  assert.strictEqual(compareBlocks(["<user>a</user>"], ["<user>b</user>"]), "changed");
  assert.strictEqual(compareBlocks(["<user>a b</user>"], ["<user>a  b</user>"]), "changed");
});
caseEnd();

caseBegin("compare-changed-order", "bin/user-block-guard.d/blocks.js");
test("swapping two blocks is changed", () => {
  const { compareBlocks } = load();
  assert.strictEqual(compareBlocks(["<user>a</user>", "<user>b</user>"], ["<user>b</user>", "<user>a</user>"]), "changed");
});
caseEnd();

caseBegin("compare-changed-removed", "bin/user-block-guard.d/blocks.js");
test("dropping a block is changed", () => {
  const { compareBlocks } = load();
  assert.strictEqual(compareBlocks(["<user>a</user>", "<user>b</user>"], ["<user>a</user>"]), "changed");
  assert.strictEqual(compareBlocks(["<user>a</user>"], []), "changed");
});
caseEnd();

caseBegin("compare-broken-tag-in-next", "bin/user-block-guard.d/blocks.js");
test("a closing tag lost only in the new text reads as changed, never equal", () => {
  const { extractBlocks, compareBlocks } = load();
  const oldB = extractBlocks("<user>a</user> tail");
  const newB = extractBlocks("<user>a tail");
  assert.notStrictEqual(compareBlocks(oldB, newB), "equal");
});
caseEnd();
