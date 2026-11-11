"use strict";
// Tests: bin/user-block-guard.d/judge.js
// Tags: TL1, user-block-guard, user-block, github, issue, pure-function, scope:issue-specific
// #2940 Step 3: judge({ op, old, next }) -> verdict per the op table, composed deny > ask > allow.
// Input shape assumed by this test (the detail names the fields, not the object layout):
//   old  = { title, body, comments: [{ body }] }  (comment ops: old.body is the comment's body)
//   next = { title?, titleUnreadable?, body?, bodyUnreadable? }  (an absent field is unchanged)
// The verdict is read from a string result or from result.verdict.
const { caseBegin, caseEnd } = require("../lib/harness");

const assert = require("node:assert");
const path = require("node:path");
const { test } = require("node:test");

const MODULE = path.resolve(__dirname, "..", "..", "bin", "user-block-guard.d", "judge.js");
const verdict = (args) => {
  const r = require(MODULE).judge(args);
  return typeof r === "string" ? r : r && r.verdict;
};
const B = "<user>keep</user>";
const issue = (over = {}) => ({ title: "Old title", body: "plain", comments: [], ...over });

caseBegin("create-block-in-body-denies", "bin/user-block-guard.d/judge.js");
test("create: a block in the new body denies; a clean body allows", () => {
  assert.strictEqual(verdict({ op: "create", old: null, next: { title: "t", body: `x ${B}` } }), "deny");
  assert.strictEqual(verdict({ op: "create", old: null, next: { title: "t", body: "clean" } }), "allow");
});
caseEnd();

caseBegin("create-block-in-title-denies", "bin/user-block-guard.d/judge.js");
test("create: a block in the new title denies", () => {
  assert.strictEqual(verdict({ op: "create", old: null, next: { title: `t ${B}`, body: "clean" } }), "deny");
});
caseEnd();

caseBegin("create-body-unreadable-asks", "bin/user-block-guard.d/judge.js");
test("create: an unreadable body asks; a readable block in the title still denies", () => {
  assert.strictEqual(verdict({ op: "create", old: null, next: { title: "t", bodyUnreadable: true } }), "ask");
  assert.strictEqual(verdict({ op: "create", old: null, next: { title: `t ${B}`, bodyUnreadable: true } }), "deny");
});
caseEnd();

caseBegin("comment-create-cells", "bin/user-block-guard.d/judge.js");
test("comment-create: block denies, clean allows, unreadable asks", () => {
  assert.strictEqual(verdict({ op: "comment-create", old: null, next: { body: B } }), "deny");
  assert.strictEqual(verdict({ op: "comment-create", old: null, next: { body: "clean" } }), "allow");
  assert.strictEqual(verdict({ op: "comment-create", old: null, next: { bodyUnreadable: true } }), "ask");
});
caseEnd();

caseBegin("edit-body-added-changed-equal", "bin/user-block-guard.d/judge.js");
test("edit body: added denies, changed asks, equal allows", () => {
  const old = issue({ body: `a ${B}` });
  assert.strictEqual(verdict({ op: "edit", old, next: { body: `a ${B} <user>more</user>` } }), "deny");
  assert.strictEqual(verdict({ op: "edit", old, next: { body: "a <user>altered</user>" } }), "ask");
  assert.strictEqual(verdict({ op: "edit", old, next: { body: "a" } }), "ask");
  assert.strictEqual(verdict({ op: "edit", old, next: { body: `rewritten ${B} text` } }), "allow");
  assert.strictEqual(verdict({ op: "edit", old: issue(), next: { body: `new ${B}` } }), "deny");
});
caseEnd();

caseBegin("edit-body-unreadable-asks", "bin/user-block-guard.d/judge.js");
test("edit body: an unreadable new body asks, with or without a block in the old one", () => {
  assert.strictEqual(verdict({ op: "edit", old: issue({ body: B }), next: { bodyUnreadable: true } }), "ask");
  assert.strictEqual(verdict({ op: "edit", old: issue(), next: { bodyUnreadable: true } }), "ask");
});
caseEnd();

caseBegin("comment-edit-cells", "bin/user-block-guard.d/judge.js");
test("comment-edit: added denies, changed asks, equal allows, unreadable asks", () => {
  const old = { body: `c ${B}` };
  assert.strictEqual(verdict({ op: "comment-edit", old, next: { body: `c ${B}${B}` } }), "deny");
  assert.strictEqual(verdict({ op: "comment-edit", old, next: { body: "c" } }), "ask");
  assert.strictEqual(verdict({ op: "comment-edit", old, next: { body: `edited ${B}` } }), "allow");
  assert.strictEqual(verdict({ op: "comment-edit", old, next: { bodyUnreadable: true } }), "ask");
});
caseEnd();

caseBegin("edit-title-with-block-in-body-denies", "bin/user-block-guard.d/judge.js");
test("edit title: a new value denies when the issue body holds a block", () => {
  assert.strictEqual(verdict({ op: "edit", old: issue({ body: B }), next: { title: "New title" } }), "deny");
});
caseEnd();

caseBegin("edit-title-with-block-in-comment-denies", "bin/user-block-guard.d/judge.js");
test("edit title: a new value denies when any comment holds a block", () => {
  const old = issue({ comments: [{ body: "no" }, { body: `yes ${B}` }] });
  assert.strictEqual(verdict({ op: "edit", old, next: { title: "New title" } }), "deny");
});
caseEnd();

caseBegin("edit-title-without-block-allows", "bin/user-block-guard.d/judge.js");
test("edit title: a new value allows when the issue has no block anywhere", () => {
  const old = issue({ comments: [{ body: "no" }] });
  assert.strictEqual(verdict({ op: "edit", old, next: { title: "New title" } }), "allow");
});
caseEnd();

caseBegin("edit-title-same-value-is-no-change", "bin/user-block-guard.d/judge.js");
test("edit title: the old value again counts as no change", () => {
  assert.strictEqual(verdict({ op: "edit", old: issue({ body: B }), next: { title: "Old title" } }), "allow");
});
caseEnd();

caseBegin("edit-title-unreadable-denies-with-block", "bin/user-block-guard.d/judge.js");
test("edit title: an unreadable title denies on an issue with a block, allows on one without", () => {
  assert.strictEqual(verdict({ op: "edit", old: issue({ comments: [{ body: B }] }), next: { titleUnreadable: true } }), "deny");
  assert.strictEqual(verdict({ op: "edit", old: issue(), next: { titleUnreadable: true } }), "allow");
});
caseEnd();

caseBegin("edit-title-deny-beats-body-ask", "bin/user-block-guard.d/judge.js");
test("compose: a title deny wins over a body ask and a body allow", () => {
  const old = issue({ body: `a ${B}` });
  assert.strictEqual(verdict({ op: "edit", old, next: { title: "New", body: "a" } }), "deny");
  assert.strictEqual(verdict({ op: "edit", old, next: { title: "New", body: `a ${B}` } }), "deny");
  assert.strictEqual(verdict({ op: "edit", old, next: { title: "Old title", body: "a" } }), "ask");
});
caseEnd();

caseBegin("comment-delete-cells", "bin/user-block-guard.d/judge.js");
test("comment-delete: a block in the target comment asks; none allows", () => {
  assert.strictEqual(verdict({ op: "comment-delete", old: { body: `x ${B}` }, next: {} }), "ask");
  assert.strictEqual(verdict({ op: "comment-delete", old: { body: "x" }, next: {} }), "allow");
});
caseEnd();

caseBegin("issue-delete-cells", "bin/user-block-guard.d/judge.js");
test("issue-delete: a block in the body or any comment asks; none allows", () => {
  assert.strictEqual(verdict({ op: "issue-delete", old: issue({ body: B }), next: {} }), "ask");
  assert.strictEqual(verdict({ op: "issue-delete", old: issue({ comments: [{ body: B }] }), next: {} }), "ask");
  assert.strictEqual(verdict({ op: "issue-delete", old: issue({ comments: [{ body: "x" }] }), next: {} }), "allow");
});
caseEnd();

caseBegin("edit-nothing-changed-allows", "bin/user-block-guard.d/judge.js");
test("edit with neither title nor body given allows", () => {
  assert.strictEqual(verdict({ op: "edit", old: issue({ body: B }), next: {} }), "allow");
});
caseEnd();
