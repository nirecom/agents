"use strict";
// lang-check: ignore -- the deny wording pinned here is user-facing Japanese text.
// Tests: bin/user-block-guard, bin/user-block-guard.d/main.js, bin/user-block-guard.d/fetch.js
// Tags: TL2, user-block-guard, user-block, github, gh, issue, subprocess, fail-closed, scope:issue-specific
// #2940 Steps 1 and 4: the real CLI against a scripted stub gh first on PATH. Exit codes 0 allow /
// 1 deny / 2 ask / 3 usage, one `user-block-guard: <reason>` stdout line, fetch failures deny.
// TL3 gap (what this test does NOT catch):
// - the real GitHub GraphQL schema and `{owner}`/`{repo}` placeholder resolution (Step 9 measures)
// - gh's own --edit-last selection limit against the CLI's last-own-comment choice
const { caseBegin, caseEnd } = require("../lib/harness");

const assert = require("node:assert");
const { after, test } = require("node:test");
const fx = require("./feat-2940-user-block-guard-cli/fixture");

after(() => fx.cleanup());

const B = "<user>keep</user>";
const ok = (data) => [{ match: "graphql", stdout: data }];
const R = fx.REPO_ARGS;
const oneLine = (r) => {
  const lines = r.stdout.split("\n").filter(Boolean);
  assert.strictEqual(lines.length, 1, `exactly one stdout line, got: ${JSON.stringify(r.stdout)}`);
  assert.match(lines[0], /^user-block-guard: \S/);
};

caseBegin("usage-errors-exit-3", "bin/user-block-guard");
test("a broken invocation exits 3", () => {
  const body = fx.bodyFile("x");
  for (const args of [
    ["--issue", "1", ...R, "--new-body-file", body],
    ["--op", "rename", "--issue", "1", ...R],
    ["--op", "edit", "--issue", "1", "--node-id", "I_x", "--new-body-file", body],
    ["--op", "comment-edit", "--comment-id", "5", "--new-body-file", body],
    ["--op", "comment-edit", "--last-own-comment", ...R, "--new-body-file", body],
  ]) {
    const r = fx.runCli(args);
    assert.strictEqual(r.status, 3, `${args.join(" ")} -> ${r.status} ${r.stdout}${r.stderr}`);
  }
});
caseEnd();

caseBegin("create-verdicts-without-fetch", "bin/user-block-guard");
test("create: block in body or title exits 1, clean exits 0, no gh call needed", () => {
  const deny = fx.runCli(["--op", "create", ...R, "--new-title", "t", "--new-body-file", fx.bodyFile(`a ${B}`)]);
  assert.strictEqual(deny.status, 1);
  oneLine(deny);
  assert.strictEqual(fx.runCli(["--op", "create", ...R, "--new-title", `t ${B}`, "--new-body-file", fx.bodyFile("a")]).status, 1);
  const allow = fx.runCli(["--op", "create", ...R, "--new-title", "t", "--new-body-file", fx.bodyFile("clean")]);
  assert.strictEqual(allow.status, 0);
  oneLine(allow);
  assert.deepStrictEqual(allow.calls, []);
});
caseEnd();

caseBegin("exit-2-asks-with-guarantee-reason", "bin/user-block-guard");
test("an unreadable body exits 2 with a one-line reason that carries the approval guarantee", () => {
  for (const [args, rules] of [
    [["--op", "create", ...R, "--new-title", "t", "--body-unreadable"], []],
    [["--op", "edit", "--issue", "7", ...R, "--body-unreadable"], ok(fx.issueData({ body: `old ${B}` }))],
  ]) {
    const r = fx.runCli(args, { rules });
    assert.strictEqual(r.status, 2, args.join(" "));
    oneLine(r);
    // Detail Step 1 / ARP-EXBG: approving means the user guarantees no <user> block is added or altered.
    assert.match(r.stdout, /<user>/);
    assert.match(r.stdout, /保証|guarantee/i, `guarantee wording: ${r.stdout}`);
    assert.match(r.stdout, /追加|\badd/i, `"add" wording: ${r.stdout}`);
    assert.match(r.stdout, /改変|変更|alter|modif|chang/i, `"alter" wording: ${r.stdout}`);
  }
});
caseEnd();

caseBegin("body-from-stdin", "bin/user-block-guard");
test("--new-body-file - reads the body from stdin", () => {
  assert.strictEqual(fx.runCli(["--op", "comment-create", "--issue", "3", ...R, "--new-body-file", "-"], { input: `x ${B}` }).status, 1);
  assert.strictEqual(fx.runCli(["--op", "comment-create", "--issue", "3", ...R, "--new-body-file", "-"], { input: "clean" }).status, 0);
});
caseEnd();

caseBegin("edit-body-against-fetched-old", "bin/user-block-guard");
test("edit body compares with the fetched old body: equal 0, changed 2, added 1", () => {
  const rules = ok(fx.issueData({ body: `old ${B}` }));
  assert.strictEqual(fx.runCli(["--op", "edit", "--issue", "7", ...R, "--new-body-file", fx.bodyFile(`new ${B} text`)], { rules }).status, 0);
  assert.strictEqual(fx.runCli(["--op", "edit", "--issue", "7", ...R, "--new-body-file", fx.bodyFile("old <user>kept?</user>")], { rules }).status, 2);
  const added = fx.runCli(["--op", "edit", "--issue", "7", ...R, "--new-body-file", fx.bodyFile(`old ${B} <user>new</user>`)], { rules });
  assert.strictEqual(added.status, 1);
  const call = added.calls.find((c) => c.args[0] === "api" && c.args.includes("graphql"));
  assert.ok(call, "one gh api graphql call");
  assert.ok(call.args.includes("owner=example-owner") && call.args.includes("name=example-repo") && call.args.includes("number=7"),
    `owner/name/number fields: ${call.args.join(" ")}`);
  assert.strictEqual(call.msysNoPathconv, "1");
});
caseEnd();

caseBegin("repo-placeholder-without-repo", "bin/user-block-guard");
test("without --repo the query uses the {owner}/{repo} placeholders", () => {
  const r = fx.runCli(["--op", "edit", "--issue", "7", "--new-body-file", fx.bodyFile("x")], { rules: ok(fx.issueData()) });
  const call = r.calls.find((c) => c.args.includes("graphql"));
  assert.ok(call && call.args.includes("owner={owner}") && call.args.includes("name={repo}"), JSON.stringify(r.calls));
});
caseEnd();

caseBegin("edit-title-reads-comments", "bin/user-block-guard");
test("edit title: a block only in a comment exits 1; no block anywhere exits 0; same title exits 0", () => {
  const withBlock = ok(fx.issueData({ comments: [fx.comment("x"), fx.comment(B, { id: 2 })] }));
  assert.strictEqual(fx.runCli(["--op", "edit", "--issue", "7", ...R, "--new-title", "New"], { rules: withBlock }).status, 1);
  assert.strictEqual(fx.runCli(["--op", "edit", "--issue", "7", ...R, "--new-title", "Old title"], { rules: withBlock }).status, 0);
  assert.strictEqual(fx.runCli(["--op", "edit", "--issue", "7", ...R, "--title-unreadable"], { rules: withBlock }).status, 1);
  const clean = ok(fx.issueData({ comments: [fx.comment("x")] }));
  assert.strictEqual(fx.runCli(["--op", "edit", "--issue", "7", ...R, "--new-title", "New"], { rules: clean }).status, 0);
});
caseEnd();

caseBegin("comment-pages-followed", "bin/user-block-guard");
test("hasNextPage makes the CLI fetch the next page from endCursor; a block there denies", () => {
  const rules = [
    { match: "CURSOR-P2", stdout: fx.issueData({ comments: [fx.comment(B, { id: 101 })] }) },
    { match: "graphql", stdout: fx.issueData({ comments: [fx.comment("p1", { id: 1 })], hasNextPage: true, endCursor: "CURSOR-P2" }) },
  ];
  const r = fx.runCli(["--op", "edit", "--issue", "7", ...R, "--new-title", "New"], { rules });
  assert.strictEqual(r.status, 1, r.stdout);
  assert.strictEqual(r.calls.filter((c) => c.args.join(" ").includes("CURSOR-P2")).length, 1, "the second page was requested once");
});
caseEnd();

caseBegin("comment-pages-followed-delete-and-last-own", "bin/user-block-guard");
test("issue-delete and --last-own-comment also follow hasNextPage to the second page", () => {
  const paged = (p1, p2) => [
    { match: "CURSOR-P2", stdout: fx.issueData({ comments: p2 }) },
    { match: "graphql", stdout: fx.issueData({ comments: p1, hasNextPage: true, endCursor: "CURSOR-P2" }) },
  ];
  const del = fx.runCli(["--op", "issue-delete", "--issue", "7", ...R], { rules: paged([fx.comment("p1", { id: 1 })], [fx.comment(B, { id: 101 })]) });
  assert.strictEqual(del.status, 2, del.stdout);
  assert.ok(del.calls.some((c) => c.args.join(" ").includes("CURSOR-P2")), "issue-delete requested the second page");
  // The page-1 own comment holds a block, so judging it instead of the page-2 one turns "mine, edited" into an ask.
  const rules = paged([fx.comment(B, { own: true, id: 1 })], [fx.comment("mine", { own: true, id: 103 })]);
  const base = ["--op", "comment-edit", "--issue", "7", ...R, "--last-own-comment"];
  const edited = fx.runCli([...base, "--new-body-file", fx.bodyFile("mine, edited")], { rules });
  assert.strictEqual(edited.status, 0, edited.stdout);
  assert.ok(edited.calls.some((c) => c.args.join(" ").includes("CURSOR-P2")), "--last-own-comment requested the second page");
  assert.strictEqual(fx.runCli([...base, "--new-body-file", fx.bodyFile(`mine ${B}`)], { rules }).status, 1);
});
caseEnd();

caseBegin("fetch-failures-deny", "bin/user-block-guard");
test("gh non-zero exit, a null issue and invalid JSON all exit 1", () => {
  const args = ["--op", "edit", "--issue", "7", ...R, "--new-body-file", fx.bodyFile("same")];
  for (const rules of [
    [{ match: "graphql", stderr: "HTTP 502", exit: 1 }],
    ok(fx.nullIssue()),
    [{ match: "graphql", stdout: "{not json" }],
  ]) {
    const r = fx.runCli(args, { rules });
    assert.strictEqual(r.status, 1, JSON.stringify(rules));
    oneLine(r);
  }
});
caseEnd();

caseBegin("fetch-failures-deny-other-targets", "bin/user-block-guard.d/fetch.js");
test("a failed REST comment read, a null node and a failed second page all exit 1", () => {
  // Each new state would pass (no block anywhere) were the failure read as an empty old state.
  const restFail = [{ match: "issues/comments/42", stderr: "HTTP 404", exit: 1 }];
  for (const args of [
    ["--op", "comment-edit", "--comment-id", "42", ...R, "--new-body-file", fx.bodyFile("clean")],
    ["--op", "comment-delete", "--comment-id", "42", ...R],
  ]) {
    const r = fx.runCli(args, { rules: restFail });
    assert.strictEqual(r.status, 1, `REST failure: ${args.join(" ")} -> ${r.stdout}`);
    oneLine(r);
  }
  const nullNode = ok({ data: { node: null } });
  for (const args of [
    ["--op", "comment-edit", "--node-id", "IC_gone", "--new-body-file", fx.bodyFile("clean")],
    ["--op", "edit", "--node-id", "I_gone", "--new-title", "New"],
  ]) {
    const r = fx.runCli(args, { rules: nullNode });
    assert.strictEqual(r.status, 1, `null node: ${args.join(" ")} -> ${r.stdout}`);
    oneLine(r);
  }
  const page2Fail = [
    { match: "CURSOR-P2", stderr: "HTTP 502", exit: 1 },
    { match: "graphql", stdout: fx.issueData({ comments: [fx.comment("p1", { id: 1 })], hasNextPage: true, endCursor: "CURSOR-P2" }) },
  ];
  const r = fx.runCli(["--op", "edit", "--issue", "7", ...R, "--new-title", "New"], { rules: page2Fail });
  assert.strictEqual(r.status, 1, `second page failure -> ${r.stdout}`);
  oneLine(r);
  assert.ok(r.calls.some((c) => c.args.join(" ").includes("CURSOR-P2")), "the second page was requested");
});
caseEnd();

caseBegin("deadline-exceeded-denies", "bin/user-block-guard");
test("a gh call that outlives --deadline-ms exits 1 within the deadline's reach", () => {
  const rules = [{ match: "graphql", stdout: fx.issueData(), sleepMs: 6000 }];
  const r = fx.runCli(["--op", "edit", "--issue", "7", ...R, "--new-body-file", fx.bodyFile("x"), "--deadline-ms", "800"], { rules });
  assert.strictEqual(r.status, 1);
  assert.ok(r.elapsedMs < 5000, `returned after ${r.elapsedMs} ms`);
});
caseEnd();

caseBegin("last-own-comment-picks-last", "bin/user-block-guard");
test("--last-own-comment compares with the viewer's last comment, not another one", () => {
  const rules = ok(fx.issueData({ comments: [fx.comment(B, { own: true, id: 1 }), fx.comment(B, { id: 2 }), fx.comment("mine", { own: true, id: 3 })] }));
  const base = ["--op", "comment-edit", "--issue", "7", ...R, "--last-own-comment"];
  assert.strictEqual(fx.runCli([...base, "--new-body-file", fx.bodyFile("mine, edited")], { rules }).status, 0);
  assert.strictEqual(fx.runCli([...base, "--new-body-file", fx.bodyFile(`mine ${B}`)], { rules }).status, 1);
  const del = ok(fx.issueData({ comments: [fx.comment("x", { own: true, id: 1 }), fx.comment(B, { own: true, id: 2 })] }));
  assert.strictEqual(fx.runCli(["--op", "comment-delete", "--issue", "7", ...R, "--last-own-comment"], { rules: del }).status, 2);
});
caseEnd();

caseBegin("last-own-comment-none", "bin/user-block-guard");
test("no own comment: --create-if-none judges as comment-create, without it the CLI allows", () => {
  const rules = ok(fx.issueData({ comments: [fx.comment(B, { id: 2 })] }));
  const base = ["--op", "comment-edit", "--issue", "7", ...R, "--last-own-comment"];
  assert.strictEqual(fx.runCli([...base, "--create-if-none", "--new-body-file", fx.bodyFile(`n ${B}`)], { rules }).status, 1);
  assert.strictEqual(fx.runCli([...base, "--create-if-none", "--new-body-file", fx.bodyFile("n")], { rules }).status, 0);
  assert.strictEqual(fx.runCli([...base, "--new-body-file", fx.bodyFile(`n ${B}`)], { rules }).status, 0);
});
caseEnd();

caseBegin("node-id-issue-and-comment", "bin/user-block-guard");
test("--node-id: an IssueComment compares its body; an Issue title edit denies on a block", () => {
  const comment = ok(fx.nodeComment(`c ${B}`));
  assert.strictEqual(fx.runCli(["--op", "comment-edit", "--node-id", "IC_kw9", "--new-body-file", fx.bodyFile(`c2 ${B}`)], { rules: comment }).status, 0);
  assert.strictEqual(fx.runCli(["--op", "comment-edit", "--node-id", "IC_kw9", "--new-body-file", fx.bodyFile("c2")], { rules: comment }).status, 2);
  const issue = ok(fx.nodeIssue({ body: B }));
  const r = fx.runCli(["--op", "edit", "--node-id", "I_kw1", "--new-title", "New"], { rules: issue });
  assert.strictEqual(r.status, 1);
  assert.ok(r.calls.some((c) => c.args.join(" ").includes("I_kw1")), "the node id reaches the query variables");
});
caseEnd();

caseBegin("node-id-delete-verdicts", "bin/user-block-guard");
test("--node-id deletes: a <user> block asks, none allows, a failed read denies", () => {
  const cases = [
    [["--op", "comment-delete", "--node-id", "IC_kw9"], ok(fx.nodeComment(`c ${B}`)), 2],
    [["--op", "comment-delete", "--node-id", "IC_kw9"], ok(fx.nodeComment("no block")), 0],
    [["--op", "issue-delete", "--node-id", "I_kw1"], ok(fx.nodeIssue({ comments: [fx.comment(B)] })), 2],
    [["--op", "issue-delete", "--node-id", "I_kw1"], ok(fx.nodeIssue({ body: `b ${B}` })), 2],
    [["--op", "issue-delete", "--node-id", "I_kw1"], ok(fx.nodeIssue()), 0],
  ];
  for (const [args, rules, want] of cases) {
    const r = fx.runCli(args, { rules });
    assert.strictEqual(r.status, want, `${args.join(" ")} -> ${r.status} ${r.stdout}`);
    oneLine(r);
    assert.ok(r.calls.some((c) => c.args.join(" ").includes(args[3])), "the node id reaches the query variables");
  }
  for (const args of [["--op", "comment-delete", "--node-id", "IC_kw9"], ["--op", "issue-delete", "--node-id", "I_kw1"]]) {
    for (const rules of [ok({ data: { node: null } }), [{ match: "graphql", stderr: "HTTP 502", exit: 1 }]]) {
      const r = fx.runCli(args, { rules });
      assert.strictEqual(r.status, 1, `fetch failure: ${args.join(" ")} ${JSON.stringify(rules)} -> ${r.stdout}`);
    }
  }
});
caseEnd();

caseBegin("node-id-comment-for-title-denies", "bin/user-block-guard");
test("an edit title on a node id that turns out to be an IssueComment denies", () => {
  const r = fx.runCli(["--op", "edit", "--node-id", "IC_kw9", "--new-title", "New"], { rules: ok(fx.nodeComment("no block")) });
  assert.strictEqual(r.status, 1);
});
caseEnd();

caseBegin("rest-comment-id", "bin/user-block-guard");
test("--comment-id reads the comment over REST: added denies, delete with a block asks", () => {
  const rules = [{ match: "issues/comments/42", stdout: { id: 42, body: `c ${B}` } }];
  const r = fx.runCli(["--op", "comment-edit", "--comment-id", "42", ...R, "--new-body-file", fx.bodyFile(`c ${B}${B}`)], { rules });
  assert.strictEqual(r.status, 1);
  assert.ok(r.calls.some((c) => c.args[0] === "api" && c.args.includes("repos/example-owner/example-repo/issues/comments/42")), JSON.stringify(r.calls));
  assert.strictEqual(fx.runCli(["--op", "comment-delete", "--comment-id", "42", ...R], { rules }).status, 2);
});
caseEnd();

caseBegin("issue-delete-verdicts", "bin/user-block-guard");
test("issue-delete: a block in a comment exits 2, none exits 0", () => {
  assert.strictEqual(fx.runCli(["--op", "issue-delete", "--issue", "7", ...R], { rules: ok(fx.issueData({ comments: [fx.comment(B)] })) }).status, 2);
  assert.strictEqual(fx.runCli(["--op", "issue-delete", "--issue", "7", ...R], { rules: ok(fx.issueData()) }).status, 0);
});
caseEnd();
