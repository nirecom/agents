"use strict";
// Fixtures for tests/bin/feat-2940-user-block-guard-cli.js: one scripted stub gh for the whole
// file (tests/lib/gh-scripted-stub.js), GraphQL / REST payload builders, and runCli(), which runs
// the real bin/user-block-guard with that stub first on PATH from a neutral temp cwd.

const childProcess = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { makeStubGh } = require("../../lib/gh-scripted-stub");

const REPO_ROOT = path.resolve(__dirname, "..", "..", "..");
const CLI = path.join(REPO_ROOT, "bin", "user-block-guard");
const WORK = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "f2940-cli-")));
const stub = makeStubGh(path.join(WORK, "stub"));
let seq = 0;

function cleanup() {
  try { fs.rmSync(WORK, { recursive: true, force: true, maxRetries: 5, retryDelay: 300 }); } catch (_e) { /* OS temp */ }
}

// bodyFile(text) -> a fresh file holding text, as a forward-slash path.
function bodyFile(text) {
  seq += 1;
  const file = path.join(WORK, `body-${seq}.txt`);
  fs.writeFileSync(file, text);
  return file.replace(/\\/g, "/");
}

const comment = (body, { own = false, id = 0 } = {}) => ({ id: `IC_${id}`, databaseId: 1000 + id, body, viewerDidAuthor: own });

// issueData({ title, body, comments, hasNextPage, endCursor }) -> the raw `gh api graphql` reply.
function issueData({ title = "Old title", body = "plain", comments = [], hasNextPage = false, endCursor = null } = {}) {
  return { data: { repository: { issue: { id: "I_kw1", title, body, comments: { pageInfo: { hasNextPage, endCursor }, nodes: comments } } } } };
}
const nullIssue = () => ({ data: { repository: { issue: null } } });
const nodeIssue = ({ title = "Old title", body = "plain", comments = [] } = {}) => ({
  data: { node: { __typename: "Issue", id: "I_kw1", title, body, comments: { pageInfo: { hasNextPage: false, endCursor: null }, nodes: comments } } },
});
const nodeComment = (body) => ({ data: { node: { __typename: "IssueComment", id: "IC_kw9", databaseId: 9, body } } });

// runCli(args, { rules, input }) -> { status, stdout, stderr, calls, elapsedMs }.
// A CLI that is missing or fails to load also exits 1, which would read as deny: refuse to report it.
function runCli(args, { rules = [], fallback, input } = {}) {
  if (!fs.existsSync(CLI)) throw new Error(`bin/user-block-guard is not present: ${CLI}`);
  stub.setSpec({ rules, fallback });
  stub.resetCalls();
  const env = { ...process.env, ...stub.env };
  for (const name of Object.keys(env)) {
    if (name.toUpperCase() === "PATH" && name !== "PATH") delete env[name];
  }
  delete env.CLAUDE_CODE_SESSION_ID;
  delete env.GH_REPO;
  const started = Date.now();
  const done = childProcess.spawnSync(process.execPath, [CLI, ...args], {
    cwd: WORK, env, input: input === undefined ? "" : input, encoding: "utf8", timeout: 30000,
  });
  const stderr = done.stderr || "";
  if (/Cannot find module|SyntaxError|ReferenceError|TypeError/.test(stderr)) throw new Error(`the CLI crashed: ${stderr}`);
  return { status: done.status, stdout: done.stdout || "", stderr, calls: stub.calls(), elapsedMs: Date.now() - started };
}

const REPO_ARGS = ["--repo", "example-owner/example-repo"];

module.exports = { CLI, WORK, REPO_ARGS, cleanup, bodyFile, comment, issueData, nullIssue, nodeIssue, nodeComment, runCli };
