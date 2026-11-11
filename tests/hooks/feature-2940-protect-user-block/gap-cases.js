"use strict";
// Review-tests gap cases of tests/hooks/feature-2940-protect-user-block.js (#2940): non-literal
// GraphQL queries, the gh api fail-closed branches, non-literal REST fields, GH_REPO with a
// placeholder or an anomalous value, an unreadable issue target, --body / --body-file last-wins,
// a state-only updateIssue, the `issue new` alias, multi-line commands and malformed stdin.
// The entrypoint owns the case markers; each export is one case. Every case asserts both the
// targeted verdict (deny / ask) and its sanctioned counterpart (a CLI call or none).
const assert = require("node:assert");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const fx = require("./fixture");

const { flag, has } = fx;

// Verdicts mimic an issue that holds a block, so a CLI call would not soften a deny into none.
const BLOCKED = { edit: 1, default: 2 };

function graphqlNonLiteralQuery({ run }) {
  test("a non-literal GraphQL query denies when it names updateIssue( and is none otherwise", () => {
    for (const cmd of [
      "gh api graphql -f query=\"mutation{updateIssue(input:$IN){issue{id}}}\"",
      "gh api graphql -f query=\"mutation{updateIssue(input:{id:\\\"$ID\\\",title:\\\"x\\\"}){issue{id}}}\"",
    ]) {
      const r = run(cmd, { verdicts: { default: 0 } });
      assert.deepStrictEqual([r.decision, r.calls.length], ["deny", 0], cmd);
    }
    // The raw text names no updateIssue(, so the hook cannot see a title change: no decision.
    for (const cmd of ["gh api graphql -f query=\"$Q\"", "gh api graphql -f query=\"$(cat m.graphql)\""]) {
      const r = run(cmd, { verdicts: { default: 1 }, files: { "m.graphql": "mutation{updateIssue(input:{id:\"I_1\",title:\"T\"}){issue{id}}}" } });
      assert.deepStrictEqual([r.decision, r.calls.length], ["none", 0], cmd);
    }
  });
}

function ghApiFailClosed({ run, R }) {
  test("an unknown gh api flag or a non-literal endpoint denies a title PATCH and asks a body PATCH, with no CLI call", () => {
    for (const [cmd, want] of [
      [`gh api --bogus-flag -X PATCH repos/${R}/issues/5 -f title=T`, "deny"],
      [`gh api --bogus-flag -X PATCH repos/${R}/issues/5 -f body=B`, "ask"],
      ["gh api -X PATCH \"repos/$R/issues/5\" -f title=T", "deny"],
      ["gh api -X PATCH \"repos/$R/issues/5\" -f body=B", "ask"],
    ]) {
      const r = run(cmd, { verdicts: { default: 0 } });
      assert.deepStrictEqual([r.decision, r.calls.length], [want, 0], cmd);
    }
    // Sanctioned counterparts: a known boolean flag and a double-quoted literal endpoint reach the CLI.
    for (const cmd of [`gh api --silent -X PATCH repos/${R}/issues/5 -f title=T`, `gh api -X PATCH "repos/${R}/issues/5" -f title=T`]) {
      const r = run(cmd, { verdicts: { default: 0 } });
      assert.strictEqual(r.decision, "none", cmd);
      assert.strictEqual(r.calls.length, 1, cmd);
      assert.deepStrictEqual([flag(r.calls[0], "--op"), flag(r.calls[0], "--issue"), flag(r.calls[0], "--new-title")], ["edit", "5", "T"], cmd);
    }
  });
}

function restNonLiteralFields({ run, one, R }) {
  test("a non-literal REST title / body field is unreadable; a single-quoted one is the literal text", () => {
    const r = run(`gh api -X PATCH repos/${R}/issues/5 -f title="$(date)" -f body="$(cat x)"`, { verdicts: { edit: 1 } });
    assert.strictEqual(r.decision, "deny");
    const c = one(r);
    assert.ok(has(c, "--title-unreadable") && has(c, "--body-unreadable"), c.args.join(" "));
    assert.ok(!has(c, "--new-title") && !has(c, "--new-body-file"), c.args.join(" "));
    const lit = one(run(`gh api -X PATCH repos/${R}/issues/5 -f title='$(date)' -f body='$(cat x)'`, { verdicts: { default: 0 } }));
    assert.strictEqual(flag(lit, "--new-title"), "$(date)");
    assert.strictEqual(lit.body, "$(cat x)");
    assert.ok(!has(lit, "--title-unreadable") && !has(lit, "--body-unreadable"), lit.args.join(" "));
  });
}

function ghRepoPlaceholderAndAnomalies({ run, one, R }) {
  test("GH_REPO fills a {owner}/{repo} endpoint; a non-literal or non-OWNER/REPO GH_REPO denies a title and asks a body", () => {
    const P = "repos/{owner}/{repo}/issues/5";
    const c = one(run(`GH_REPO=${R} gh api -X PATCH ${P} -f title=T`, { verdicts: { default: 0 } }));
    assert.deepStrictEqual([flag(c, "--op"), flag(c, "--issue"), flag(c, "--repo"), flag(c, "--new-title")], ["edit", "5", R, "T"]);
    const bare = one(run(`gh api -X PATCH ${P} -f title=T`, { verdicts: { default: 0 } }));
    assert.notStrictEqual(flag(bare, "--repo"), R, "without GH_REPO no repo is invented");
    for (const [cmd, want] of [
      ["GH_REPO=$X gh issue edit 5 -t x", "deny"],
      ["GH_REPO=$X gh issue edit 5 -b x", "ask"],
      ["GH_REPO=notarepo gh issue edit 5 -t x", "deny"],
      ["GH_REPO=notarepo gh issue edit 5 -b x", "ask"],
      [`GH_REPO=notarepo gh api -X PATCH ${P} -f title=T`, "deny"],
    ]) {
      const r = run(cmd, { verdicts: { default: 0 } });
      assert.deepStrictEqual([r.decision, r.calls.length], [want, 0], cmd);
    }
  });
}

function unreadableIssueTarget({ run, one }) {
  test("gh issue edit/comment/delete with no issue or a non-literal issue never call the CLI; a literal one does", () => {
    for (const [cmd, want] of [
      ["gh issue edit -t x", "deny"],
      ["gh issue edit -b x", "ask"],
      ["gh issue comment -b x", "ask"],
      ["gh issue delete --yes", "ask"],
      ["gh issue edit \"$N\" -t x", "deny"],
      ["gh issue edit \"$N\" -b x", "ask"],
      ["gh issue edit 'abc' -t x", "deny"],
    ]) {
      const r = run(cmd, { verdicts: { default: 0 } });
      assert.deepStrictEqual([r.decision, r.calls.length], [want, 0], cmd);
    }
    for (const cmd of ["gh issue edit \"5\" -t x", "gh issue edit '#5' -t x"]) {
      const c = one(run(cmd, { verdicts: { default: 0 } }));
      assert.deepStrictEqual([flag(c, "--op"), flag(c, "--issue"), flag(c, "--new-title")], ["edit", "5", "x"], cmd);
    }
  });
}

function bodyVsBodyFileLastWins({ run, one }) {
  test("--body and --body-file: the one written last is the body", () => {
    const files = { "b.md": "from file\n" };
    for (const [cmd, want] of [
      ["gh issue edit 5 -b B -F b.md", "from file\n"],
      ["gh issue edit 5 -F b.md -b B", "B"],
      ["gh issue edit 5 --body-file=b.md --body B", "B"],
      ["gh issue edit 5 --body B --body-file b.md", "from file\n"],
    ]) {
      assert.strictEqual(one(run(cmd, { files })).body, want, cmd);
    }
    // A later unreadable --body-file overrides an earlier readable --body.
    const late = one(run("gh issue edit 5 -b B -F -", { verdicts: { default: 2 } }));
    assert.ok(has(late, "--body-unreadable") && !has(late, "--new-body-file"), late.args.join(" "));
  });
}

function graphqlStateOnlyUpdate({ run, one }) {
  test("updateIssue with only state (no title, no body) is none; adding a title makes one edit call", () => {
    for (const cmd of [
      "gh api graphql -f query='mutation{updateIssue(input:{id:\"I_1\",state:CLOSED}){issue{id}}}'",
      "gh api graphql -f query='mutation($id:ID!,$s:IssueState){updateIssue(input:{id:$id,state:$s}){issue{id}}}' -f id=I_1 -f s=CLOSED",
    ]) {
      const r = run(cmd, { verdicts: BLOCKED });
      assert.deepStrictEqual([r.decision, r.calls.length], ["none", 0], cmd);
    }
    const r = run("gh api graphql -f query='mutation{updateIssue(input:{id:\"I_1\",state:CLOSED,title:\"T\"}){issue{id}}}'", { verdicts: BLOCKED });
    assert.strictEqual(r.decision, "deny");
    assert.deepStrictEqual([flag(one(r), "--op"), flag(one(r), "--node-id"), flag(one(r), "--new-title")], ["edit", "I_1", "T"]);
  });
}

function issueNewAlias({ run, one }) {
  test("gh issue new is create like gh issue create; new --web alone is none", () => {
    const r = run("gh issue new -t T -b \"<user>a</user>\"", { verdicts: { create: 1 } });
    assert.strictEqual(r.decision, "deny");
    const c = one(r);
    assert.deepStrictEqual([flag(c, "--op"), flag(c, "--new-title"), c.body], ["create", "T", "<user>a</user>"]);
    const web = run("gh issue new --web", { verdicts: { default: 1 } });
    assert.deepStrictEqual([web.decision, web.calls.length], ["none", 0]);
  });
}

function multiLineCommand({ run, one }) {
  test("each line of a multi-line command is checked; a newline inside quotes stays in the body", () => {
    const r = run("echo start\ngh issue edit 5 -t x", { verdicts: { edit: 1 } });
    assert.strictEqual(r.decision, "deny");
    assert.strictEqual(flag(one(r), "--issue"), "5");
    const two = run("gh issue edit 3 -b a\ngh issue edit 4 -b b", { verdicts: { default: 2 } });
    assert.deepStrictEqual([two.decision, two.calls.map((c) => flag(c, "--issue"))], ["ask", ["3", "4"]]);
    const quoted = one(run("gh issue edit 5 -b 'line1\nline2'", { verdicts: { default: 0 } }));
    assert.strictEqual(quoted.body, "line1\nline2");
    const plain = run("echo a\necho b", { verdicts: { default: 1 } });
    assert.deepStrictEqual([plain.decision, plain.calls.length], ["none", 0]);
  });
}

// Spawns the hook with raw stdin (runHook always sends valid JSON).
function rawStdinRun(input) {
  const work = fx.tempDir("stdin");
  const logFile = path.join(work, "cli-calls.jsonl");
  const env = { ...process.env, F2940_UBG_LOG: logFile, F2940_UBG_VERDICTS: JSON.stringify({ default: 1 }), AGENTS_STATE_DIR: path.join(work, "agents-state"), CLAUDE_TRANSCRIPT_BASE_DIR: path.join(work, "transcripts") };
  for (const name of ["CLAUDE_CODE_SESSION_ID", "CLAUDECODE", "CLAUDE_PROJECT_DIR", "GH_REPO"]) delete env[name];
  const preload = path.join(__dirname, "cli-stub-preload.js");
  const done = childProcess.spawnSync(process.execPath, ["--require", preload, path.join(fx.REPO, "hooks", "protect-user-block.js")], {
    input, env, cwd: work, encoding: "utf8", timeout: fx.WAIT_CAP_MS,
  });
  const calls = fs.existsSync(logFile) ? fs.readFileSync(logFile, "utf8").split("\n").filter(Boolean) : [];
  return { ...done, ...fx.decisionOf(done.stdout), calls };
}

function malformedStdinFailOpen() {
  test("malformed or empty stdin is fail-open (no decision, exit 0, no CLI call); the same command as valid JSON denies", () => {
    const cmd = "gh issue edit 5 -t x";
    for (const input of [`{"tool_name":"Bash","tool_input":{"command":"${cmd}"`, "", "not json"]) {
      const r = rawStdinRun(input);
      assert.deepStrictEqual([r.status, r.decision, r.calls.length], [0, "none", 0], JSON.stringify(input));
    }
    const ok = rawStdinRun(JSON.stringify({ tool_name: "Bash", tool_input: { command: cmd } }));
    assert.deepStrictEqual([ok.decision, ok.calls.length], ["deny", 1]);
  });
}

// A title change whose same call adds a <user> block: gh issue edit, REST PATCH and GraphQL updateIssue.
const TITLE_EDIT_ADDS_BLOCK = [
  "gh issue edit 5 -t New -b '<user>x</user>'",
  "gh api -X PATCH repos/example-owner/example-repo/issues/5 -f title=New -f body='<user>x</user>'",
  "gh api graphql -f query='mutation($id:ID!,$title:String,$body:String){updateIssue(input:{id:$id,title:$title,body:$body}){issue{id}}}' -f id=I_1 -f title=New -f body='<user>x</user>'",
];

function titleEditAddsBlock({ run, one }) {
  test("a title edit that adds a block in the same call hands title and body to ONE edit call; its rc decides", () => {
    for (const cmd of TITLE_EDIT_ADDS_BLOCK) {
      const r = run(cmd, { verdicts: { edit: 1, default: 0 } });
      assert.strictEqual(r.decision, "deny", cmd);
      const c = one(r);
      assert.deepStrictEqual([flag(c, "--op"), flag(c, "--new-title"), c.body], ["edit", "New", "<user>x</user>"], cmd);
      assert.ok(!has(c, "--title-unreadable") && !has(c, "--body-unreadable"), `${cmd}: ${c.args.join(" ")}`);
      // Sanctioned counterpart: the hook adds no deny of its own, so a CLI allow gives no decision.
      const allowed = run(cmd, { verdicts: { default: 0 } });
      assert.deepStrictEqual([allowed.decision, allowed.calls.length], ["none", 1], cmd);
    }
  });
}

module.exports = {
  graphqlNonLiteralQuery, ghApiFailClosed, restNonLiteralFields, ghRepoPlaceholderAndAnomalies,
  unreadableIssueTarget, bodyVsBodyFileLastWins, graphqlStateOnlyUpdate, issueNewAlias,
  multiLineCommand, malformedStdinFailOpen, titleEditAddsBlock,
};
