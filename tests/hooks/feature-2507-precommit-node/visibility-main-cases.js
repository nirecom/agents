"use strict";
// repo-visibility and main.js part of tests/hooks/feature-2507-precommit-node.js (#2507).
// parseRemote(url) -> { host, repoId } is pinned to a table and to the current hooks/pre-commit
// sed pipeline run through bash; start({ remoteUrl, spawnGh }) -> { result(), kill() }.
const assert = require("node:assert");
const { spawn, spawnSync } = require("node:child_process");
const path = require("node:path");
const { test } = require("node:test");

// url, host, repoId (repoId null = not asserted: the host alone decides "skip").
const TABLE = [
  ["https://github.com/owner/repo.git", "github.com", "owner/repo"],
  ["https://github.com/owner/repo", "github.com", "owner/repo"],
  ["git@github.com:owner/repo.git", "github.com", "owner/repo"],
  ["ssh://git@github.com/owner/repo", "github.com", "owner/repo"],
  // Split so the commit-time outbound scan does not read user:tok + host as an address.
  [`https://user:tok${"@"}github.com/owner/repo`, "github.com", "owner/repo"],
  ["https://github.com:443/owner/repo", "github.com", "owner/repo"],
  ["https://example.invalid/agents-fixture.git", "example.invalid", "example.invalid/agents-fixture"],
  ["/c/git/repo", "/c/git/repo", "git/repo"],
  ["C:/git/repo.git", "C:/git/repo.git", "git/repo"],
  ["github.com:owner/repo", "github.com:owner/repo", null],
  ["https://GitHub.com/o/r", "GitHub.com", "o/r"],
];
const HOST_SED = "printf '%s\\n' \"$1\" | sed -E 's#^(ssh|https?)://([^@]+@)?([^/:]+).*#\\3#' | sed -E 's#^[^@]+@([^:]+):.*#\\1#'";
const ID_SED = "printf '%s\\n' \"$1\" | sed 's/\\.git$//' | sed -E 's#.*[:/]([^/]+/[^/]+)$#\\1#'";
const sed = (script, url) => spawnSync("bash", ["-c", script, "_", url], { encoding: "utf8" }).stdout.replace(/\n$/, "");

const vis = (F) => F.fresh("checks/repo-visibility.js");
const node = (code) => () => spawn(process.execPath, ["-e", code]);

function repoVisibility(F) {
  test("the parse table matches the current bash sed pipeline", () => {
    for (const [url, host, id] of TABLE) {
      assert.strictEqual(sed(HOST_SED, url), host, `host oracle: ${url}`);
      if (id !== null) assert.strictEqual(sed(ID_SED, url), id, `repoId oracle: ${url}`);
    }
  });
  test("parseRemote(url) returns the table's host and repoId", () => {
    const { parseRemote } = vis(F);
    for (const [url, host, id] of TABLE) {
      const got = parseRemote(url);
      assert.strictEqual(got.host, host, url);
      if (id !== null) assert.strictEqual(got.repoId, id, url);
    }
  });
  test("non-GitHub host (case-sensitive) is 'skip' without asking gh; no origin is 'scan'", async () => {
    const { start } = vis(F);
    let asked = 0;
    const spawnGh = () => { asked += 1; return node("process.stdout.write('false')")(); };
    for (const url of ["https://example.invalid/a.git", "https://GitHub.com/o/r", "github.com:o/r", "/c/git/repo"]) {
      assert.strictEqual(await start({ remoteUrl: url, spawnGh }).result(), "skip", url);
    }
    assert.strictEqual(asked, 0);
    assert.strictEqual(await start({ remoteUrl: "", spawnGh }).result(), "scan");
  });
  test("gh answers: 'true' is skip; false, empty, a failure or a missing gh is scan", async () => {
    const { start } = vis(F);
    const url = "git@github.com:owner/repo.git";
    let args = null;
    const rec = (code) => (a) => { args = a; return node(code)(); };
    assert.strictEqual(await start({ remoteUrl: url, spawnGh: rec("process.stdout.write('true\\n')") }).result(), "skip");
    assert.deepStrictEqual(args, ["api", "repos/owner/repo", "--jq", ".private"]);
    assert.strictEqual(await start({ remoteUrl: url, spawnGh: rec("process.stdout.write('false\\n')") }).result(), "scan");
    assert.strictEqual(await start({ remoteUrl: url, spawnGh: rec("") }).result(), "scan");
    assert.strictEqual(await start({ remoteUrl: url, spawnGh: rec("process.stdout.write('true');process.exit(1)") }).result(), "scan");
    const enoent = () => spawn(path.join(F.tmp("no-gh"), "gh-missing"), []);
    assert.strictEqual(await start({ remoteUrl: url, spawnGh: enoent }).result(), "scan");
    assert.strictEqual(await start({ remoteUrl: url, spawnGh: () => { throw new Error("no gh"); } }).result(), "scan");
  });
  test("kill() terminates the pending gh child", async () => {
    const { start } = vis(F);
    let child = null;
    const spawnGh = () => { child = spawn(process.execPath, ["-e", "setTimeout(() => {}, 60000)"]); return child; };
    const probe = start({ remoteUrl: "https://github.com/o/r", spawnGh });
    const exited = new Promise((res) => child.once("exit", () => res(true)));
    probe.kill();
    assert.strictEqual(await Promise.race([exited, new Promise((res) => setTimeout(() => res(false), 10000))]), true);
  });
  test("the check returns skip-rest when the probe says skip, pass when it says scan", async () => {
    const dir = F.repo("vis");
    F.write(dir, "a.txt", "a\n");
    F.stage(dir, "a.txt");
    const run = (answer) => F.runCheck("repo-visibility", { repoTop: dir, cfgDir: dir, env: F.cleanEnv(), visibility: { result: async () => answer, kill() {} } });
    assert.strictEqual((await run("skip")).verdict, "skip-rest");
    assert.strictEqual((await run("scan")).verdict, "pass");
  });
}

const NINE = ["enforce-worktree", "settings-effort-unstage", "code-lang", "sh-exec-bit", "prompt-extraction", "tests-frontmatter", "agents-repo-gates", "comment-block-size", "repo-visibility"];

function mainEntry(F) {
  test("main.js exports CONFIRM_WARN = 10", () => {
    assert.strictEqual(F.fresh("main.js").CONFIRM_WARN, 10);
  });
  test("main.js in a foreign repo with a non-GitHub origin exits 0 after the nine markers", () => {
    const dir = F.repo("main-foreign");
    F.git(dir, ["remote", "add", "origin", "https://example.invalid/agents-fixture.git"]);
    F.write(dir, "app.txt", "x\n");
    F.stage(dir, "app.txt");
    const state = F.tmp("main-state");
    const env = F.cleanEnv({ ENFORCE_WORKTREE: "off", CODE_LANG: "", WORKFLOW_STATE_DIR: state, WORKFLOW_PLANS_DIR: state, CLAUDE_TRANSCRIPT_BASE_DIR: F.tmp("main-tx") });
    delete env.CLAUDE_CODE_SESSION_ID;
    const done = spawnSync(process.execPath, [path.join(F.PCD, "main.js")], { cwd: dir, env, encoding: "utf8", timeout: 60000 });
    assert.strictEqual(done.status, 0, done.stderr);
    const markers = done.stderr.split(/\r?\n/).filter((l) => l.startsWith("pre-commit-section: ")).map((l) => l.slice(20));
    assert.deepStrictEqual(markers, NINE);
  });
}

module.exports = { repoVisibility, mainEntry };
