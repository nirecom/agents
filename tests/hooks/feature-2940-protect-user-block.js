"use strict";
// Tests: hooks/protect-user-block.js, hooks/protect-user-block/run.js, hooks/protect-user-block/extract.js, hooks/protect-user-block/extract-api.js, hooks/protect-user-block/call-guard.js, hooks/lib/gh-api-argv.js
// Tags: TL1, hook, protect-user-block, user-block, gh, github, issue, pretooluse, allow-deny, fail-closed, scope:issue-specific
// #2940 Step 7: the real hook with bin/user-block-guard replaced in-process by cli-stub-preload.js
// (F2940_UBG_VERDICTS scripts the rc). Checks the operation descriptors the hook hands the CLI
// (op, target, repo, title, body, unreadable flags) and how the CLI rc maps to the decision.
const { caseBegin, caseEnd } = require("../lib/harness");

const assert = require("node:assert");
const path = require("node:path");
const { after, test } = require("node:test");
const fx = require("./feature-2940-protect-user-block/fixture");

after(() => fx.cleanup());

const { flag, has } = fx;
const R = "example-owner/example-repo";
const run = (command, opts) => {
  assert.ok(fx.hookPresent(), "hooks/protect-user-block.js is not present (expected before write-code)");
  return fx.runHook(command, opts);
};
const one = (r) => {
  assert.strictEqual(r.calls.length, 1, `exactly one CLI call, got ${JSON.stringify(r.calls)} / ${r.stdout}${r.stderr}`);
  return r.calls[0];
};
// The descriptor fields a case asserts; undefined means "flag absent".
const desc = (c) => ({
  op: flag(c, "--op"), issue: flag(c, "--issue"), repo: flag(c, "--repo"),
  title: flag(c, "--new-title"), body: c.body === null ? undefined : c.body,
});

caseBegin("issue-create-short-long-eq-forms", "hooks/protect-user-block/extract.js");
test("gh issue create: -t/-b, --title/--body and --title=/--body= give the same descriptor", () => {
  for (const cmd of [
    "gh issue create -t T1 -b B1",
    "gh issue create --title T1 --body B1",
    "gh issue create --title=T1 --body=B1",
  ]) {
    const c = one(run(cmd));
    assert.deepStrictEqual(desc(c), { op: "create", issue: undefined, repo: undefined, title: "T1", body: "B1" }, cmd);
  }
});
caseEnd();

caseBegin("issue-create-body-file-forms", "hooks/protect-user-block/extract.js");
test("gh issue create: -F, --body-file and --body-file= hand the file content as the body", () => {
  for (const cmd of ["gh issue create -t T -F b.md", "gh issue create -t T --body-file b.md", "gh issue create -t T --body-file=b.md"]) {
    const c = one(run(cmd, { files: { "b.md": "from file\n" } }));
    assert.strictEqual(flag(c, "--op"), "create", cmd);
    assert.strictEqual(c.body, "from file\n", cmd);
    assert.strictEqual(flag(c, "--new-title"), "T", cmd);
  }
});
caseEnd();

caseBegin("issue-edit-forms-and-no-swap", "hooks/protect-user-block/extract.js");
test("gh issue edit: title and body stay apart in every form; the last repeated flag wins", () => {
  for (const cmd of ["gh issue edit 5 -t TT -b BB", "gh issue edit 5 --body BB --title TT", "gh issue edit 5 --body=BB --title=TT"]) {
    assert.deepStrictEqual(desc(one(run(cmd))), { op: "edit", issue: "5", repo: undefined, title: "TT", body: "BB" }, cmd);
  }
  const c = one(run("gh issue edit 5 -b first --body second -t a --title=b"));
  assert.strictEqual(c.body, "second");
  assert.strictEqual(flag(c, "--new-title"), "b");
  const titleOnly = one(run("gh issue edit 5 -t OnlyTitle"));
  assert.strictEqual(titleOnly.body, null, "no body flag means no --new-body-file");
  assert.ok(!has(titleOnly, "--body-unreadable"));
  const bodyOnly = one(run("gh issue edit 5 -b OnlyBody"));
  assert.ok(!has(bodyOnly, "--new-title") && !has(bodyOnly, "--title-unreadable"), "no title flag means no title change");
});
caseEnd();

caseBegin("issue-edit-body-file-forms", "hooks/protect-user-block/extract.js");
test("gh issue edit: -F, --body-file and --body-file= hand the readable file content as the body", () => {
  for (const cmd of ["gh issue edit 5 -F b.md", "gh issue edit 5 --body-file b.md", "gh issue edit 5 --body-file=b.md"]) {
    const c = one(run(cmd, { files: { "b.md": "from file\n" } }));
    assert.strictEqual(flag(c, "--op"), "edit", cmd);
    assert.strictEqual(flag(c, "--issue"), "5", cmd);
    assert.strictEqual(c.body, "from file\n", cmd);
    assert.ok(!has(c, "--body-unreadable"), `${cmd}: ${c.args.join(" ")}`);
  }
});
caseEnd();

caseBegin("issue-comment-forms", "hooks/protect-user-block/extract.js");
test("gh issue comment: -b/--body/-F/--body-file are comment-create; --edit-last and --delete-last target the last own comment", () => {
  for (const cmd of [
    "gh issue comment 8 -b hi", "gh issue comment 8 --body hi", "gh issue comment 8 --body=hi",
    "gh issue comment 8 -F c.md", "gh issue comment 8 --body-file c.md", "gh issue comment 8 --body-file=c.md",
  ]) {
    const c = one(run(cmd, { files: { "c.md": "hi" } }));
    assert.deepStrictEqual(desc(c), { op: "comment-create", issue: "8", repo: undefined, title: undefined, body: "hi" }, cmd);
  }
  const edit = one(run("gh issue comment 8 --edit-last -b new"));
  assert.strictEqual(flag(edit, "--op"), "comment-edit");
  assert.ok(has(edit, "--last-own-comment") && !has(edit, "--create-if-none"));
  assert.strictEqual(edit.body, "new");
  const createIfNone = one(run("gh issue comment 8 --edit-last --create-if-none -b new"));
  assert.ok(has(createIfNone, "--last-own-comment") && has(createIfNone, "--create-if-none"));
  const del = one(run("gh issue comment 8 --delete-last --yes"));
  assert.strictEqual(flag(del, "--op"), "comment-delete");
  assert.strictEqual(flag(del, "--issue"), "8");
  assert.ok(has(del, "--last-own-comment"));
});
caseEnd();

caseBegin("issue-delete", "hooks/protect-user-block/extract.js");
test("gh issue delete N is issue-delete on N", () => {
  const c = one(run("gh issue delete 12 --yes"));
  assert.strictEqual(flag(c, "--op"), "issue-delete");
  assert.strictEqual(flag(c, "--issue"), "12");
});
caseEnd();

caseBegin("out-of-scope-issue-commands", "hooks/protect-user-block/extract.js");
test("label-only edits, --web/--editor without a body and --template alone never call the CLI", () => {
  for (const cmd of [
    "gh issue edit 5 --add-label bug",
    "gh issue edit 5 --remove-label bug --add-assignee @me",
    "gh issue create --web",
    "gh issue create --editor",
    "gh issue create --template bug_report.md",
    "gh issue view 5",
    "gh issue list",
  ]) {
    const r = run(cmd, { verdicts: { default: 1 } });
    assert.deepStrictEqual(r.calls, [], cmd);
    assert.strictEqual(r.decision, "none", cmd);
  }
});
caseEnd();

caseBegin("multi-issue-edit", "hooks/protect-user-block/run.js");
test("gh issue edit with two targets gives one CLI call per issue", () => {
  const r = run("gh issue edit 3 4 -b x");
  assert.deepStrictEqual(r.calls.map((c) => [flag(c, "--op"), flag(c, "--issue")]), [["edit", "3"], ["edit", "4"]]);
});
caseEnd();

caseBegin("repo-resolution", "hooks/protect-user-block/extract.js");
test("-R, --repo, a GH_REPO prefix and an issue URL become --repo; nothing given means no --repo", () => {
  for (const cmd of [`gh issue edit 5 -R ${R} -b x`, `gh issue edit 5 --repo ${R} -b x`, `gh issue edit 5 --repo=${R} -b x`, `GH_REPO=${R} gh issue edit 5 -b x`]) {
    const c = one(run(cmd));
    assert.strictEqual(flag(c, "--repo"), R, cmd);
    assert.strictEqual(flag(c, "--issue"), "5", cmd);
  }
  const url = one(run(`gh issue edit https://github.com/${R}/issues/12 -b x`));
  assert.strictEqual(flag(url, "--issue"), "12");
  assert.strictEqual(flag(url, "--repo"), R);
  assert.ok(!has(one(run("gh issue edit 5 -b x")), "--repo"));
});
caseEnd();

caseBegin("unresolvable-target-ask-or-deny", "hooks/protect-user-block/run.js");
test("a non-GitHub selector or a cd prefix asks for a body change and denies a title change", () => {
  for (const [cmd, want] of [
    ["gh issue edit 5 -R gitlab.example.com/o/r -b x", "ask"],
    ["gh issue edit 5 -R gitlab.example.com/o/r -t x", "deny"],
    ["cd ../other && gh issue edit 5 -b x", "ask"],
    ["cd ../other && gh issue edit 5 -t x", "deny"],
    ["gh issue edit 5 -R \"$REPO\" -b x", "ask"],
    ["gh issue edit 5 -R \"$REPO\" -t x", "deny"],
  ]) {
    assert.strictEqual(run(cmd, { verdicts: { default: 0 } }).decision, want, cmd);
  }
});
caseEnd();

caseBegin("unresolvable-nested-substitution-unclosed", "hooks/protect-user-block/run.js");
test("bash -c nesting, a substitution head and an unclosed quote ask for a body change and deny a title change", () => {
  for (const [cmd, want] of [
    ["bash -c 'gh issue edit 5 -b x'", "ask"],
    ["bash -c 'gh issue edit 5 -t x'", "deny"],
    ["$(command -v gh) issue edit 5 -b x", "ask"],
    ["$(command -v gh) issue edit 5 -t x", "deny"],
    ["gh issue edit 5 -b \"x", "ask"],
    ["gh issue edit 5 -t \"x", "deny"],
  ]) {
    assert.strictEqual(run(cmd, { verdicts: { default: 0 } }).decision, want, cmd);
  }
});
caseEnd();

caseBegin("unreadable-body-and-title", "hooks/protect-user-block/extract.js");
test("$(...), backticks, -F -, a missing file and a file over 1 MB are unreadable bodies", () => {
  const big = "a".repeat(1024 * 1024 + 16);
  for (const cmd of [
    "gh issue edit 5 -b \"$(cat note.md)\"",
    "gh issue edit 5 -b \"`cat note.md`\"",
    "gh issue edit 5 -F -",
    "gh issue edit 5 -F missing.md",
    "gh issue edit 5 -F big.md",
    "gh issue comment 5 --body-file=-",
  ]) {
    const r = run(cmd, { files: { "big.md": big }, verdicts: { default: 2 } });
    assert.strictEqual(r.decision, "ask", cmd);
    const c = one(r);
    assert.ok(has(c, "--body-unreadable"), `${cmd}: ${c.args.join(" ")}`);
    assert.ok(!has(c, "--new-body-file"), cmd);
  }
  const t = one(run("gh issue edit 5 -t \"$(date)\"", { verdicts: { default: 1 } }));
  assert.ok(has(t, "--title-unreadable") && !has(t, "--new-title"), t.args.join(" "));
});
caseEnd();

caseBegin("gh-api-rest-endpoints", "hooks/protect-user-block/extract-api.js");
test("REST issue writes map to create / edit / comment-create / comment-edit / comment-delete", () => {
  const create = one(run(`gh api repos/${R}/issues -f title=T -f body=B`));
  assert.deepStrictEqual(desc(create), { op: "create", issue: undefined, repo: R, title: "T", body: "B" });
  for (const cmd of [`gh api -X PATCH repos/${R}/issues/5 -f body=B -f title=T`, `gh api --method PATCH repos/${R}/issues/5 -f body=B -f title=T`, `gh api --method=PATCH repos/${R}/issues/5 -F body=B -F title=T`]) {
    assert.deepStrictEqual(desc(one(run(cmd))), { op: "edit", issue: "5", repo: R, title: "T", body: "B" }, cmd);
  }
  const cc = one(run(`gh api repos/${R}/issues/5/comments -f body=hello`));
  assert.deepStrictEqual(desc(cc), { op: "comment-create", issue: "5", repo: R, title: undefined, body: "hello" });
  const ce = one(run(`gh api -X PATCH repos/${R}/issues/comments/99 -f body=new`));
  assert.strictEqual(flag(ce, "--op"), "comment-edit");
  assert.strictEqual(flag(ce, "--comment-id"), "99");
  assert.strictEqual(flag(ce, "--repo"), R);
  assert.strictEqual(ce.body, "new");
  const cd = one(run(`gh api -X DELETE repos/${R}/issues/comments/99`));
  assert.strictEqual(flag(cd, "--op"), "comment-delete");
  assert.strictEqual(flag(cd, "--comment-id"), "99");
});
caseEnd();

caseBegin("gh-api-rest-placeholder-and-leading-slash", "hooks/protect-user-block/extract-api.js");
test("repos/{owner}/{repo}/... and a leading-slash /repos/O/R/... map like the literal endpoint", () => {
  const P = "repos/{owner}/{repo}";
  // A placeholder endpoint leaves the repo to gh's own resolution: no literal OWNER/REPO reaches the CLI.
  const placeholderRepo = (c, cmd) => assert.ok([undefined, "{owner}/{repo}"].includes(flag(c, "--repo")), `${cmd}: --repo ${flag(c, "--repo")}`);
  const edit = one(run(`gh api -X PATCH ${P}/issues/5 -f body=B -f title=T`));
  assert.deepStrictEqual([flag(edit, "--op"), flag(edit, "--issue"), flag(edit, "--new-title"), edit.body], ["edit", "5", "T", "B"]);
  placeholderRepo(edit, "PATCH");
  const cc = one(run(`gh api ${P}/issues/5/comments -f body=hello`));
  assert.deepStrictEqual([flag(cc, "--op"), flag(cc, "--issue"), cc.body], ["comment-create", "5", "hello"]);
  placeholderRepo(cc, "comments POST");
  const cd = one(run(`gh api -X DELETE ${P}/issues/comments/99`));
  assert.deepStrictEqual([flag(cd, "--op"), flag(cd, "--comment-id")], ["comment-delete", "99"]);
  placeholderRepo(cd, "comments DELETE");
  const slash = one(run(`gh api -X PATCH /repos/${R}/issues/5 -f body=B`));
  assert.deepStrictEqual(desc(slash), { op: "edit", issue: "5", repo: R, title: undefined, body: "B" });
  const slashCc = one(run(`gh api /repos/${R}/issues/5/comments -f body=hi`));
  assert.deepStrictEqual(desc(slashCc), { op: "comment-create", issue: "5", repo: R, title: undefined, body: "hi" });
});
caseEnd();

caseBegin("gh-api-patch-issue-non-text-fields", "hooks/protect-user-block/extract-api.js");
test("PATCH issues/N with only state or labels[] calls no CLI; adding title=T makes one edit call", () => {
  for (const cmd of [`gh api -X PATCH repos/${R}/issues/5 -f state=closed`, `gh api -X PATCH repos/${R}/issues/5 -f 'labels[]=bug'`]) {
    const r = run(cmd, { verdicts: { default: 1 } });
    assert.deepStrictEqual([r.decision, r.calls.length], ["none", 0], cmd);
  }
  const c = one(run(`gh api -X PATCH repos/${R}/issues/5 -f state=closed -f title=T`, { verdicts: { default: 0 } }));
  assert.deepStrictEqual(desc(c), { op: "edit", issue: "5", repo: R, title: "T", body: undefined });
});
caseEnd();

caseBegin("gh-api-input-and-reads", "hooks/protect-user-block/extract-api.js");
test("--input makes the body (and on PATCH issues/N the title) unreadable; reads never call the CLI", () => {
  const c = one(run(`gh api -X PATCH repos/${R}/issues/5 --input payload.json`, { files: { "payload.json": "{}" } }));
  assert.ok(has(c, "--body-unreadable") && has(c, "--title-unreadable"), c.args.join(" "));
  const cc = one(run(`gh api repos/${R}/issues/5/comments --input payload.json`, { files: { "payload.json": "{}" } }));
  assert.ok(has(cc, "--body-unreadable") && !has(cc, "--title-unreadable"), cc.args.join(" "));
  for (const cmd of [`gh api repos/${R}/issues/5`, `gh api repos/${R}/issues/5/comments`, `gh api repos/${R}/pulls -f title=x -f head=a -f base=b`]) {
    assert.deepStrictEqual(run(cmd, { verdicts: { default: 1 } }).calls, [], cmd);
  }
});
caseEnd();

caseBegin("gh-api-rest-body-from-file", "hooks/protect-user-block/extract-api.js");
test("-F body=@file never hands the literal @path as the body: it is the file content or unreadable", () => {
  const files = { "new.md": "added <user>x</user>\n" };
  for (const [cmd, op] of [
    [`gh api -X PATCH repos/${R}/issues/5 -F body=@new.md`, "edit"],
    [`gh api repos/${R}/issues/5/comments -F body=@new.md`, "comment-create"],
    [`gh api -X PATCH repos/${R}/issues/comments/99 -F body=@new.md`, "comment-edit"],
  ]) {
    const c = one(run(cmd, { files }));
    assert.strictEqual(flag(c, "--op"), op, cmd);
    assert.notStrictEqual(c.body, "@new.md", `${cmd}: the literal @path reached the CLI as the body`);
    assert.ok(c.body === files["new.md"] || has(c, "--body-unreadable"), `${cmd}: ${c.args.join(" ")} body=${JSON.stringify(c.body)}`);
  }
});
caseEnd();

const gql = (mutation, vars) => `gh api graphql -f query='mutation(${mutation[0]}){${mutation[1]}}' ${vars}`;
caseBegin("gh-api-graphql-six-mutations", "hooks/protect-user-block/extract-api.js");
test("createIssue / addComment / updateIssue / updateIssueComment / deleteIssueComment / deleteIssue", () => {
  const create = one(run(gql(["$repositoryId:ID!,$title:String!,$body:String", "createIssue(input:{repositoryId:$repositoryId,title:$title,body:$body}){issue{id}}"], "-f repositoryId=R_1 -f title=T -f body=B")));
  assert.strictEqual(flag(create, "--op"), "create");
  assert.strictEqual(flag(create, "--new-title"), "T");
  assert.strictEqual(create.body, "B");
  const add = one(run(gql(["$id:ID!,$body:String!", "addComment(input:{subjectId:$id,body:$body}){clientMutationId}"], "-f id=I_1 -f body=hello")));
  assert.strictEqual(flag(add, "--op"), "comment-create");
  assert.strictEqual(flag(add, "--node-id"), "I_1");
  assert.strictEqual(add.body, "hello");
  const upd = one(run(gql(["$id:ID!,$title:String", "updateIssue(input:{id:$id,title:$title}){issue{id}}"], "-f id=I_1 -f title=New")));
  assert.deepStrictEqual([flag(upd, "--op"), flag(upd, "--node-id"), flag(upd, "--new-title")], ["edit", "I_1", "New"]);
  const updc = one(run(gql(["$id:ID!,$body:String!", "updateIssueComment(input:{id:$id,body:$body}){issueComment{id}}"], "-f id=IC_1 -f body=new")));
  assert.deepStrictEqual([flag(updc, "--op"), flag(updc, "--node-id"), updc.body], ["comment-edit", "IC_1", "new"]);
  const delc = one(run(gql(["$id:ID!", "deleteIssueComment(input:{id:$id}){clientMutationId}"], "-f id=IC_1")));
  assert.deepStrictEqual([flag(delc, "--op"), flag(delc, "--node-id")], ["comment-delete", "IC_1"]);
  const del = one(run(gql(["$id:ID!", "deleteIssue(input:{issueId:$id}){clientMutationId}"], "-f id=I_1")));
  assert.deepStrictEqual([flag(del, "--op"), flag(del, "--node-id")], ["issue-delete", "I_1"]);
  const literal = one(run("gh api graphql -f query='mutation{updateIssue(input:{id:\"I_9\",title:\"Lit\"}){issue{id}}}'"));
  assert.deepStrictEqual([flag(literal, "--node-id"), flag(literal, "--new-title")], ["I_9", "Lit"]);
});
caseEnd();

caseBegin("gh-api-graphql-unreadable-and-unknown", "hooks/protect-user-block/extract-api.js");
test("an unreadable structure denies when updateIssue is named and asks otherwise; unknown mutations are out of scope", () => {
  // Verdicts mimic a block-holding issue, so the outcome holds whether the hook decides itself or via the CLI.
  const verdicts = { edit: 1, default: 2 };
  const files = { "in.json": "{}" };
  assert.strictEqual(run("gh api graphql -f query='mutation($in:UpdateIssueInput!){updateIssue(input:$in){issue{id}}}' -F in=@in.json", { verdicts, files }).decision, "deny");
  assert.strictEqual(run("gh api graphql -f query='mutation($in:AddCommentInput!){addComment(input:$in){clientMutationId}}' -F in=@in.json", { verdicts, files }).decision, "ask");
  const upBody = run(gql(["$id:ID!,$body:String", "updateIssue(input:{id:$id,body:$body}){issue{id}}"], "-f id=I_1 -f body=x"), { verdicts: { default: 0 } });
  assert.ok(!has(one(upBody), "--body-unreadable"), "a readable updateIssue body stays readable");
  for (const cmd of ["gh api graphql -f query='mutation{addStar(input:{starrableId:\"R_1\"}){clientMutationId}}'", "gh api graphql -f query='query{viewer{login}}'"]) {
    const r = run(cmd, { verdicts: { default: 1 } });
    assert.deepStrictEqual([r.decision, r.calls.length], ["none", 0], cmd);
  }
});
caseEnd();

caseBegin("gh-api-rest-endpoint-normalization", "hooks/protect-user-block/extract-api.js");
test("a query string, an api.github.com absolute URL or a trailing slash still reaches the guard; a foreign host does not", () => {
  const plain = desc(one(run(`gh api -X PATCH repos/${R}/issues/5 -f body=B -f title=T`)));
  for (const ep of [`repos/${R}/issues/5?x=1`, `repos/${R}/issues/5/`, `https://api.github.com/repos/${R}/issues/5`, `api.github.com/repos/${R}/issues/5`, `/repos/${R}/issues/5#frag`]) {
    assert.deepStrictEqual(desc(one(run(`gh api -X PATCH ${ep} -f body=B -f title=T`))), plain, ep);
  }
  const foreign = run(`gh api -X PATCH https://example.com/repos/${R}/issues/5 -f body=B -f title=T`, { verdicts: { default: 1 } });
  assert.deepStrictEqual([foreign.decision, foreign.calls.length], ["none", 0]);
});
caseEnd();

caseBegin("gh-api-graphql-comment-and-multi-operation", "hooks/protect-user-block/extract-api.js");
test("a leading # comment or an earlier query operation does not hide an updateIssue mutation", () => {
  const m = "mutation{updateIssue(input:{id:\"I_9\",title:\"Lit\"}){issue{id}}}";
  const plain = desc(one(run(`gh api graphql -f query='${m}'`)));
  for (const q of [`# note\n${m}`, `query Q{viewer{login}} ${m}`, `# c1\nquery Q{viewer{login}}\n# c2\n${m}`]) {
    assert.deepStrictEqual(desc(one(run(`gh api graphql -f query='${q}'`))), plain, JSON.stringify(q));
  }
  const verdicts = { edit: 1, default: 2 };
  const files = { "in.json": "{}" };
  assert.strictEqual(run("gh api graphql -f query='# c\nquery Q{viewer{login}} mutation($in:UpdateIssueInput!){updateIssue(input:$in){issue{id}}}' -F in=@in.json", { verdicts, files }).decision, "deny");
  const commented = run("gh api graphql -f query='query{viewer{login}} # updateIssue(input:{id:1,title:2})'", { verdicts: { default: 1 } });
  assert.deepStrictEqual([commented.decision, commented.calls.length], ["none", 0]);
});
caseEnd();

caseBegin("cli-rc-mapping","hooks/protect-user-block/call-guard.js");
test("rc 0 -> {} (no decision), 1 -> deny with the CLI reason, 2 -> ask, 3 / unknown / timeout -> deny", () => {
  const allow = run("gh issue edit 5 -b x", { verdicts: { default: 0 } });
  assert.strictEqual(allow.stdout.trim(), "{}");
  assert.strictEqual(allow.status, 0);
  const deny = run("gh issue edit 5 -b x", { verdicts: { default: 1 } });
  assert.strictEqual(deny.decision, "deny");
  assert.match(deny.reason, /stub-edit-rc1/);
  const ask = run("gh issue edit 5 -b x", { verdicts: { default: 2 } });
  assert.strictEqual(ask.decision, "ask");
  assert.match(ask.reason, /stub-edit-rc2/);
  for (const v of [3, 7, "timeout"]) {
    assert.strictEqual(run("gh issue edit 5 -b x", { verdicts: { default: v } }).decision, "deny", String(v));
  }
});
caseEnd();

caseBegin("time-budget", "hooks/protect-user-block/call-guard.js");
test("--deadline-ms is below the spawn timeout, both below the decision limit; under 1000 ms left denies", () => {
  const c = one(run("gh issue edit 5 -b x", { env: { WORKFLOW_DECISION_TIME_LIMIT_MS: "10000" } }));
  const deadline = Number(flag(c, "--deadline-ms"));
  assert.ok(Number.isInteger(deadline) && deadline > 0, `--deadline-ms ${flag(c, "--deadline-ms")}`);
  assert.ok(typeof c.timeout === "number" && c.timeout > deadline, `timeout ${c.timeout} > deadline ${deadline}`);
  assert.ok(c.timeout <= 9500, `spawn timeout ${c.timeout} leaves 500 ms of the 10 s limit`);
  const tight = run("gh issue edit 5 -b x", { verdicts: { default: 0 }, env: { WORKFLOW_DECISION_TIME_LIMIT_MS: "500" } });
  assert.strictEqual(tight.decision, "deny");
});
caseEnd();

caseBegin("aggregation-deny-first", "hooks/protect-user-block/run.js");
test("deny beats ask, and the first deny stops further CLI calls", () => {
  const mixed = run("gh issue comment 3 -b a && gh issue edit 4 -t b", { verdicts: { "comment-create": 2, edit: 1 } });
  assert.strictEqual(mixed.decision, "deny");
  const stop = run("gh issue edit 3 -t a && gh issue edit 4 -t b", { verdicts: { default: 1 } });
  assert.strictEqual(stop.decision, "deny");
  assert.strictEqual(stop.calls.length, 1, "no call after the first deny");
  const asks = run("gh issue edit 3 -b a && gh issue edit 4 -b b", { verdicts: { default: 2 } });
  assert.deepStrictEqual([asks.decision, asks.calls.length], ["ask", 2]);
});
caseEnd();

caseBegin("non-targets-are-none", "hooks/protect-user-block/run.js");
test("a non-command tool, glab and git status give no decision and no CLI call", () => {
  for (const [cmd, toolName] of [["/tmp/x.md", "Read"], ["glab issue update 5 --title x", "Bash"], ["git status", "Bash"]]) {
    const r = run(cmd, { toolName, verdicts: { default: 1 } });
    assert.deepStrictEqual([r.decision, r.calls.length], ["none", 0], cmd);
  }
});
caseEnd();

caseBegin("oracle-deny-probe-short-form", "hooks/protect-user-block/extract.js");
test("the oracle deny probe reaches the CLI as create with the block in the body", () => {
  const r = run("gh issue create -t x -b \"<user>a</user>\"", { verdicts: { create: 1 } });
  assert.strictEqual(r.decision, "deny");
  assert.deepStrictEqual(desc(one(r)), { op: "create", issue: undefined, repo: undefined, title: "x", body: "<user>a</user>" });
});
caseEnd();

caseBegin("lastFieldValue-shared-identity", "hooks/lib/gh-api-argv.js");
test("hooks/lib/gh-api-argv.js owns lastFieldValue and confirm-forge re-exports the same function", () => {
  const shared = require(path.join(fx.REPO, "hooks", "lib", "gh-api-argv.js")).lastFieldValue;
  const reexport = require(path.join(fx.REPO, "hooks", "confirm-forge-target-ownership", "gh-api-argv.js")).lastFieldValue;
  assert.strictEqual(typeof shared, "function");
  assert.strictEqual(shared, reexport);
});
caseEnd();

// Review-tests gap cases; bodies live in the sibling module (500-line split).
const gap = require("./feature-2940-protect-user-block/gap-cases");
const gx = { run, one, desc, R };

caseBegin("gh-api-graphql-non-literal-query", "hooks/protect-user-block/extract-api.js");
gap.graphqlNonLiteralQuery(gx);
caseEnd();

caseBegin("gh-api-fail-closed-ambiguous-and-endpoint", "hooks/protect-user-block/extract-api.js");
gap.ghApiFailClosed(gx);
caseEnd();

caseBegin("gh-api-rest-non-literal-fields", "hooks/protect-user-block/extract-api.js");
gap.restNonLiteralFields(gx);
caseEnd();

caseBegin("gh-repo-placeholder-and-anomalies", "hooks/protect-user-block/extract.js");
gap.ghRepoPlaceholderAndAnomalies(gx);
caseEnd();

caseBegin("unreadable-issue-target", "hooks/protect-user-block/extract.js");
gap.unreadableIssueTarget(gx);
caseEnd();

caseBegin("body-vs-body-file-last-wins", "hooks/protect-user-block/extract.js");
gap.bodyVsBodyFileLastWins(gx);
caseEnd();

caseBegin("gh-api-graphql-state-only-update", "hooks/protect-user-block/extract-api.js");
gap.graphqlStateOnlyUpdate(gx);
caseEnd();

caseBegin("issue-new-alias", "hooks/protect-user-block/extract.js");
gap.issueNewAlias(gx);
caseEnd();

caseBegin("multi-line-command", "hooks/protect-user-block/run.js");
gap.multiLineCommand(gx);
caseEnd();

caseBegin("malformed-stdin-fail-open", "hooks/protect-user-block/run.js");
gap.malformedStdinFailOpen();
caseEnd();
