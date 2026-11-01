"use strict";
// tests/lib/plan-sync-turn-fixture.js
// Tests: tests/lib/plan-sync-turn-fixture.js
// Tags: scope:issue-specific, shared-lib, plan-sync, fixture, turn-commit
// #2768 shared scaffolding for tests/hooks/feature-2768-*: one temp root, isolated git config, empty
// AGENTS_MAIN_ROOT and transcript base, neutral cwd, a `code` stub, and tests/lib/git-ssh-stub.sh as the
// ssh command, logging each call and serving a local bare repo (no network). Fixture facts are
// written and read without the code under test. Call harness isolate() before requiring it.

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const crypto = require("node:crypto");
const { spawnSync } = require("node:child_process");
const { gitInit } = require("./harness");

const ROOT = path.resolve(__dirname, "..", "..");
const slash = (p) => String(p).replace(/\\/g, "/");
if (!process.env.WORKFLOW_STATE_DIR || !process.env.WORKFLOW_PLANS_DIR) {
  throw new Error("plan-sync-turn fixture: call isolate() before requiring it");
}

const TMP = slash(fs.mkdtempSync(path.join(os.tmpdir(), "ps2768-")));
const DIRS = { neutral: `${TMP}/neutral`, cfg: `${TMP}/cfg`, tx: `${TMP}/transcripts`, work: `${TMP}/work`, code: `${TMP}/code-stub` };
for (const d of Object.values(DIRS)) fs.mkdirSync(d, { recursive: true });

const ORIGIN_GH = "ssh://git@github.com/test-owner/test-repo.git";
const ORIGIN_PLAIN = "ssh://git@plans.example.com/test-owner/test-repo.git";
const GH_WEB = "https://github.com/test-owner/test-repo";
const blobUrl = (rel) => `${GH_WEB}/blob/main/${rel}`;
const commitUrl = (sha) => `${GH_WEB}/commit/${sha}`;
const compareUrl = (b, h) => `${GH_WEB}/compare/${b}...${h}`;

// --- environment (top level: every later spawn and in-process call inherits it) ---
for (const k of ["GITLAB_HOSTNAME", "GITLAB_SSH_HOSTNAME", "CLAUDE_PROJECT_DIR", "CONFIRM_INTENT", "CONFIRM_OUTLINE",
  "CONFIRM_DETAIL", "GIT_SSH", "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_SSH_STUB_LOG", "GIT_SSH_STUB_REPO",
  "TERM_PROGRAM", "CLAUDE_CODE_ENTRYPOINT", "SHOW_PLAN_LINK_MARKER_FILE", "STOP_CONFIRM_CONTINUE_T0_OFFSET_MS",
  "CLAUDE_CODE_SESSION_ID", "NODE_OPTIONS"]) delete process.env[k];
fs.writeFileSync(`${TMP}/gitconfig`, "[core]\n\thooksPath = /dev/null\n[user]\n\tname = plan-sync-test\n\temail = plan-sync-test@example.invalid\n");
Object.assign(process.env, {
  GIT_CONFIG_GLOBAL: `${TMP}/gitconfig`, GIT_CONFIG_NOSYSTEM: "1", GIT_TERMINAL_PROMPT: "0",
  AGENTS_MAIN_ROOT: DIRS.cfg, CLAUDE_TRANSCRIPT_BASE_DIR: DIRS.tx,
  SHOW_USER_VERIFIED_NO_SPAWN: "1", SHOW_PLAN_LINK_NO_AUTO_OPEN: "1", SHOW_PLAN_LINK_NO_SPAWN: "1",
  PLAN_SYNC_REMOTE_URL: ORIGIN_GH, PS2768_SSH_LOG: `${TMP}/ssh.log`, GIT_SSH_VARIANT: "ssh", PS2768_INJECT: `${TMP}/inject.sh`,
});
fs.writeFileSync(process.env.PS2768_SSH_LOG, "");
// GIT_SSH_COMMAND runs tests/lib/git-ssh-stub.sh directly (the only ssh command the test command guard
// trusts). It logs "<cmd> '<path>'" to $PS2768_SSH_LOG, runs an armed $PS2768_INJECT once before the next
// receive-pack advertises its refs (a deterministic push race), and refuses auth while GIT_SSH_STUB_FAIL=auth.
const STUB = slash(path.join(ROOT, "tests", "lib", "git-ssh-stub.sh"));
delete process.env.GIT_SSH_STUB_FAIL;
Object.assign(process.env, { GIT_SSH_STUB_CALL_LOG: process.env.PS2768_SSH_LOG, GIT_SSH_STUB_INJECT: process.env.PS2768_INJECT,
  GIT_SSH_COMMAND: `sh "${STUB}"` });
// `code` stub: confirmation and plan display must never launch the real editor.
process.env.CODE_STUB_LOG = process.platform === "win32" ? path.win32.normalize(`${DIRS.code}/code.log`) : `${DIRS.code}/code.log`;
fs.writeFileSync(`${DIRS.code}/code`, '#!/bin/sh\necho "code $*" >> "$CODE_STUB_LOG"\n', { mode: 0o755 });
fs.writeFileSync(`${DIRS.code}/code.cmd`, '@echo off\r\necho code %*>>"%CODE_STUB_LOG%"\r\n');
process.env.PATH = `${process.platform === "win32" ? path.win32.normalize(DIRS.code) : DIRS.code}${path.delimiter}${process.env.PATH}`;
process.chdir(DIRS.neutral);

// useSsh(fail): the stub serves (falsy), refuses auth (true), or fails as <fail> ("offline").
const useSsh = (fail) => {
  process.env.GIT_SSH_COMMAND = `sh "${STUB}"`;
  if (fail) process.env.GIT_SSH_STUB_FAIL = fail === true ? "auth" : fail;
  else delete process.env.GIT_SSH_STUB_FAIL;
};
function sshCalls(kind) {
  const lines = fs.readFileSync(process.env.PS2768_SSH_LOG, "utf8").split(/\r?\n/).filter(Boolean);
  return lines.filter((l) => l.startsWith(kind)).length;
}

// --- git ---
function git(cwd, args, allowFail) {
  const r = spawnSync("git", ["-C", cwd].concat(args), { encoding: "utf8", timeout: 60000 });
  if (!allowFail && (r.error || r.status !== 0)) throw new Error(`git ${args.join(" ")} failed: ${r.stderr || r.error}`);
  return allowFail ? r : String(r.stdout).replace(/\r?\n$/, "");
}
const gitTry = (cwd, args) => {
  const r = git(cwd, args, true);
  return r.status === 0 ? String(r.stdout).replace(/\r?\n$/, "") : null;
};

let counter = 0;
const uniq = (tag) => `${tag}-${process.pid}-${++counter}`.replace(/[^A-Za-z0-9_-]/g, "-");
const newSid = (tag) => `ps2768-${uniq(tag)}`;
const newTurn = (sid) => ({ sid, turnId: crypto.randomBytes(16).toString("hex") });
const planName = (sid, stage) => `${sid}-${stage}.md`;

function ps() { return require(path.join(ROOT, "hooks", "lib", "plan-sync")); }
const allowLocal = { isAllowedRemoteUrl: (u) => ps().isAllowedRemoteUrl(u) || path.isAbsolute(u) };

// A git project whose origin is on <host>: the project-host record of a plan written for it.
const projects = {};
function project(host) {
  if (projects[host]) return projects[host];
  const dir = `${DIRS.work}/project-${host.replace(/[^a-z0-9]/gi, "-")}`;
  gitInit(dir);
  git(dir, ["commit", "-q", "--allow-empty", "-m", "init"]);
  git(dir, ["remote", "add", "origin", `ssh://git@${host}/test-owner/test-repo.git`]);
  projects[host] = dir;
  return dir;
}

// makeRepo(tag, {url, deny}) -> {dir, bare, url, host}: a bare remote and a provisioned plans dir.
function makeRepo(tag, opts) {
  const o = opts || {};
  const name = uniq(tag);
  const bare = `${DIRS.work}/${name}.git`;
  git(DIRS.work, ["init", "-q", "--bare", bare]);
  git(bare, ["symbolic-ref", "HEAD", "refs/heads/main"]);
  if (o.deny) git(bare, ["config", "receive.denyNonFastForwards", "true"]);
  const url = o.url || ORIGIN_GH;
  const repo = { dir: o.dir || `${DIRS.work}/${name}-plans`, bare, url, host: url === ORIGIN_PLAIN ? "plans.example.com" : "github.com" };
  provision(repo);
  return repo;
}
function useRepo(repo) {
  process.env.GIT_SSH_STUB_BARE = repo.bare;
  process.env.PLAN_SYNC_REMOTE_URL = repo.url;
}
function provision(repo) {
  useRepo(repo);
  fs.mkdirSync(repo.dir, { recursive: true });
  const deps = Object.assign({ listPrivateRepoNames: () => [], repoVisibility: () => "private" }, allowLocal);
  const r = ps().provisionRepo(repo.dir, repo.url, deps);
  if (!r || !r.ok) throw new Error(`provisionRepo failed: ${JSON.stringify(r)}`);
  return r;
}
// A second provisioned plans dir on the same bare (another machine).
function cloneRepo(repo, tag) {
  const other = { dir: `${DIRS.work}/${uniq(tag)}-plans`, bare: repo.bare, url: repo.url, host: repo.host };
  provision(other);
  return other;
}

const absOf = (repo, rel) => path.join(repo.dir, rel);
function writePlan(repo, rel, body) { fs.writeFileSync(absOf(repo, rel), body); }
function record(repo, rel) {
  const r = ps().recordProjectHost(absOf(repo, rel), project(repo.host));
  if (!r || !r.ok) throw new Error(`recordProjectHost failed: ${JSON.stringify(r)}`);
}
// sync(repo, rel, extra) -> the syncPlanFile result (match record written first).
function sync(repo, rel, extra) {
  useRepo(repo);
  record(repo, rel);
  return ps().syncPlanFile(repo.dir, absOf(repo, rel), Object.assign({ budgetMs: 20000, deps: allowLocal }, extra || {}));
}
function writeSync(repo, rel, body, extra) {
  writePlan(repo, rel, body);
  return sync(repo, rel, extra);
}

// --- remote inspection ---
const bareCount = (repo) => Number(gitTry(repo.bare, ["rev-list", "--count", "refs/heads/main"]) || 0);
const bareTip = (repo) => gitTry(repo.bare, ["rev-parse", "--verify", "-q", "refs/heads/main"]);
const parentsOf = (repo, sha) => git(repo.bare, ["log", "-1", "--format=%P", sha]).split(" ").filter(Boolean);
const authorOf = (repo, sha) => git(repo.bare, ["log", "-1", "--format=%an <%ae>", sha]);
const bodyOf = (repo, sha) => git(repo.bare, ["log", "-1", "--format=%B", sha]).replace(/\s+$/, "");
const showAt = (repo, ref, rel) => gitTry(repo.bare, ["show", `${ref}:${rel}`]);
const isAncestor = (repo, a, b) => git(repo.bare, ["merge-base", "--is-ancestor", a, b], true).status === 0;
const firstParentLog = (repo, n) => git(repo.bare, ["log", "--first-parent", `-n${n}`, "--format=%H", "refs/heads/main"]).split(/\r?\n/).filter(Boolean);
const config = (dir, key) => gitTry(dir, ["config", "--local", "--get", key]);

// trailersOf(text) -> trailer values of the last paragraph plus the "- <rel>" list lines, read here
// and never through the module under test.
function trailersOf(text) {
  const t = String(text).replace(/\r/g, "");
  const paras = t.trim().split(/\n\s*\n/);
  const last = paras[paras.length - 1] || "";
  const pick = (key) => last.split("\n").map((l) => new RegExp(`^${key}: (.*)$`).exec(l)).filter(Boolean).map((m) => m[1]);
  const listed = t.split("\n").map((l) => /^- (.+)$/.exec(l)).filter(Boolean).map((m) => m[1]);
  return { session: pick("Plan-Sync-Session"), turn: pick("Plan-Sync-Turn"), base: pick("Plan-Sync-Turn-Base"), rel: pick("Plan-Sync-Rel"),
    listed, subject: t.split("\n")[0], paragraphs: paras.length };
}
const tipTrailers = (repo) => trailersOf(bodyOf(repo, bareTip(repo)));

// humanPush(repo, rel, body, message, ref) -> sha: a commit by a person (plain clone, plain push to ref).
function humanPush(repo, rel, body, message, ref) {
  const dir = `${DIRS.work}/${uniq("human")}`;
  const r = spawnSync("git", ["clone", "-q", repo.bare, dir], { encoding: "utf8", timeout: 60000 });
  if (r.status !== 0) throw new Error(`clone failed: ${r.stderr}`);
  git(dir, ["config", "core.hooksPath", "/dev/null"]);
  fs.writeFileSync(path.join(dir, rel), body);
  git(dir, ["add", "--", rel]);
  git(dir, ["-c", "user.name=someone", "-c", "user.email=someone@example.invalid", "commit", "-q", "-m", message]);
  git(dir, ["push", "-q", "origin", `HEAD:${ref || "refs/heads/main"}`]);
  return git(dir, ["rev-parse", "HEAD"]);
}
// A trailer paragraph spelled by hand, for commits the module under test did not make.
const handTrailer = (turn, rels, base) => `plan-sync: ${rels[0]}\n\n${rels.map((r) => `- ${r}`).join("\n")}\n\n` +
  `Plan-Sync-Session: ${turn.sid}\nPlan-Sync-Turn: ${turn.turnId}\nPlan-Sync-Turn-Base: ${base}\n${rels.map((r) => `Plan-Sync-Rel: ${r}`).join("\n")}`;

// --- prompt turn ---
function controlPath(sid, name) {
  const { controlPath: cp } = require(path.join(ROOT, "hooks", "workflow-state", "state-io", "control-dir"));
  return cp(sid, name, { forWrite: true });
}
const promptTurnPath = (sid) => controlPath(sid, "prompt-turn.json");
function writePromptTurnFile(sid, body) {
  const p = promptTurnPath(sid);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, typeof body === "string" ? body : JSON.stringify(body));
  return p;
}
function readPromptTurnFile(sid) {
  try { return JSON.parse(fs.readFileSync(promptTurnPath(sid), "utf8")); } catch (_) { return null; }
}
const iso = (ms) => new Date(ms).toISOString();
// txPath(sid) -> a transcript path that is never created (hook inputs that need a transcript_path field).
function txPath(sid) { return `${DIRS.tx}/project/${sid}.jsonl`; }
// startTurn(sid) -> {turn, created}: the prompt-turn file the UserPromptSubmit hook would have written.
function startTurn(sid) {
  const created = Date.now();
  const turnId = crypto.randomBytes(16).toString("hex");
  writePromptTurnFile(sid, { turn_id: turnId, created_at: iso(created) });
  return { turn: { sid, turnId }, created };
}
// renameFailPreload() -> a `node --require` file making every rename of a prompt-turn path fail with EPERM.
function renameFailPreload() {
  const pre = `${TMP}/rename-fails.js`;
  if (!fs.existsSync(pre)) fs.writeFileSync(pre, [
    "const fs = require('fs');",
    "const bad = (p) => String(p).includes('prompt-turn');",
    "const err = () => Object.assign(new Error('EPERM rename (test)'), { code: 'EPERM' });",
    "const rs = fs.renameSync; fs.renameSync = function (a, b) { if (bad(a) || bad(b)) throw err(); return rs.apply(this, arguments); };",
    "const r = fs.rename; fs.rename = function (a, b, cb) { if (bad(a) || bad(b)) return process.nextTick(cb, err()); return r.apply(this, arguments); };",
    "const pr = fs.promises.rename; fs.promises.rename = function (a, b) { if (bad(a) || bad(b)) return Promise.reject(err()); return pr.apply(this, arguments); };",
  ].join("\n"));
  return pre;
}

// --- spawned entrypoints ---
function runNode(rel, input, opts) {
  const o = opts || {};
  const env = Object.assign({}, process.env, o.env || {});
  delete env.CLAUDE_CODE_SESSION_ID;
  for (const k of o.unset || []) delete env[k];
  const r = spawnSync(process.execPath, (o.nodeArgs || []).concat([path.join(ROOT, rel)]), {
    cwd: DIRS.neutral, input: typeof input === "string" ? input : JSON.stringify(input), encoding: "utf8", timeout: 90000, env,
  });
  const out = r.stdout || "";
  let json = null;
  try { json = JSON.parse(out); } catch (_) { json = null; }
  return { code: r.status, out, err: (r.stderr || "") + (r.error ? String(r.error) : ""), json };
}
// hookWrite(repo, rel, {sid, env}) -> show-plan-link output for one Write of <rel>.
function hookWrite(repo, rel, o) {
  const input = { tool_name: "Write", tool_input: { file_path: absOf(repo, rel), content: "x" }, tool_response: { success: true },
    session_id: o.sid, cwd: project(repo.host), hook_event_name: "PostToolUse" };
  const res = runNode("hooks/show-plan-link.js", input, { env: Object.assign({ WORKFLOW_PLANS_DIR: repo.dir,
    PLAN_SYNC_REMOTE_URL: repo.url, GIT_SSH_STUB_BARE: repo.bare }, o.env || {}) });
  const hso = (res.json && res.json.hookSpecificOutput) || {};
  return Object.assign(res, { ctx: hso.additionalContext || "", msg: (res.json && res.json.systemMessage) || "" });
}

// The module under test, or null when it is not there yet (the red reason is then logged).
function mod(rel) {
  try { return require(path.join(ROOT, rel)); } catch (e) {
    check(`module ${rel} loads`, false, `not implemented: ${e.code || e.message}`);
    return null;
  }
}

let failures = 0;
let passes = 0;
const clip = (s) => String(s).replace(/[\r\n]+/g, " ").slice(0, 400);
function check(name, ok, detail) {
  if (ok) { passes += 1; console.log(`PASS ${name}`); return true; }
  failures += 1;
  console.log(`FAIL ${name} :: ${clip(detail === undefined ? "" : detail)}`);
  return false;
}
// guard(name, fn): a thrown error inside a case is one failure of that case, never an abort.
function guard(name, fn) {
  try { fn(); } catch (e) { check(`${name} (threw)`, false, e && e.stack ? e.stack.split("\n").slice(0, 3).join(" | ") : e); }
}
function finish() {
  console.log(failures === 0 ? `ALL PASS (${passes})` : `${failures} FAILED, ${passes} passed`);
  try { process.chdir(os.tmpdir()); fs.rmSync(TMP, { recursive: true, force: true }); } catch (_) { /* best effort */ }
}
const failureCount = () => failures;

module.exports = {
  ROOT, TMP, DIRS, ORIGIN_GH, ORIGIN_PLAIN, GH_WEB, blobUrl, commitUrl, compareUrl, slash, useSsh, sshCalls,
  git, gitTry, uniq, newSid, newTurn, planName, ps, allowLocal, project, makeRepo, useRepo, provision, cloneRepo,
  absOf, writePlan, record, sync, writeSync, bareCount, bareTip, parentsOf, authorOf, bodyOf, showAt, isAncestor,
  firstParentLog, config, trailersOf, tipTrailers, humanPush, handTrailer, controlPath, promptTurnPath,
  writePromptTurnFile, readPromptTurnFile, iso, txPath, startTurn, renameFailPreload, runNode, hookWrite, mod, check, guard, finish, failureCount, clip,
};
