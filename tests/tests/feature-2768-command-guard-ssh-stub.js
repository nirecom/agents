"use strict";
// Tests: tests/lib/command-guard/ssh-stub.js, tests/lib/command-guard/main.js, tests/lib/command-guard/resolve-target.js, tests/lib/command-guard-build.js
// Tags: scope:issue-specific, tl2, command-guard, fixture-isolation, ssh-stub
// The command guard lets an ssh URL through only when the ssh command git would run starts the
// guard.conf `sshstub=` stub itself (#2768): GIT_SSH_COMMAND, else core.sshCommand, else GIT_SSH.
// A copy, a wrapper, shell syntax, another transport, or a guard with no stub declared is refused.
// Each guard dir is a real instance command-guard-build.js --instance writes, as command_guard_ensure
// does; every call runs that instance's generated bin/git, so a builder that stops emitting
// `sshstub=` turns the allowed cases red.
const { caseBegin, caseEnd } = require("../lib/harness");

const assert = require("node:assert");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..");
const BUILDER = path.join(SCRIPT_CHECKOUT_ROOT, "tests", "lib", "command-guard-build.js");
const fwd = (p) => p.replace(/\\/g, "/");
const STUB = fwd(fs.realpathSync.native(path.join(SCRIPT_CHECKOUT_ROOT, "tests", "lib", "git-ssh-stub.sh")));
const EXE = process.platform === "win32" ? ".exe" : "";
const TMP = fwd(fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), "cg2768s-"))));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));

const RR = `${TMP}/rr`;
const HOME = `${TMP}/home`;
const GDIR = `${TMP}/guard`;
const GDIR_NOSTUB = `${TMP}/guard-nostub`;
for (const d of [RR, HOME, GDIR, GDIR_NOSTUB]) fs.mkdirSync(d, { recursive: true });
fs.writeFileSync(`${HOME}/.gitconfig`, "");

// The real git binary, never a command guard shim on PATH.
function findRealGit() {
  const exec = spawnSync("git", ["--exec-path"], { encoding: "utf8" });
  const cand = path.join(String(exec.stdout || "").trim(), `git${EXE}`);
  if (exec.status === 0 && fs.existsSync(cand)) return fwd(cand);
  for (const d of String(process.env.PATH || "").split(path.delimiter)) {
    if (/command-guard/.test(d)) continue;
    if (fs.existsSync(path.join(d, `git${EXE}`))) return fwd(path.join(d, `git${EXE}`));
  }
  throw new Error("no real git found");
}
const REALGIT = findRealGit();
function buildInstance(dir) {
  const r = spawnSync(process.execPath, [BUILDER, "--instance", dir, "--allowed", RR, "--realgit", REALGIT],
    { encoding: "utf8", timeout: 120000 });
  if (r.status !== 0) throw new Error(`command-guard-build --instance ${dir}: ${r.status} ${r.stderr}`);
  return fs.readFileSync(`${dir}/guard.conf`, "utf8");
}
const BUILT_CONF = buildInstance(GDIR);
// The no-stub and missing-stub guards keep every other line the builder wrote.
function withStubLine(dir, line) {
  buildInstance(dir);
  const rest = BUILT_CONF.split("\n").filter((l) => !l.startsWith("sshstub="));
  fs.writeFileSync(`${dir}/guard.conf`, [...rest.slice(0, -1), ...(line ? [line] : []), ""].join("\n"));
}
withStubLine(GDIR_NOSTUB, null);

const BARE = `${RR}/served.git`;
const STUB_CMD = `sh "${STUB}"`;
// The stub's own `git receive-pack` / `upload-pack` must reach the real git, not a shim on PATH.
const BASE = { ...process.env, HOME, USERPROFILE: HOME, GIT_CONFIG_GLOBAL: `${HOME}/.gitconfig`, GIT_CONFIG_NOSYSTEM: "1",
  GIT_TERMINAL_PROMPT: "0", ROOT_DECOY_TEST_ID: "cg2768s", GIT_SSH_STUB_BARE: BARE,
  PATH: `${path.dirname(REALGIT)}${path.delimiter}${process.env.PATH || ""}` };
for (const n of ["GIT_DIR", "GIT_WORK_TREE", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "CLAUDE_CODE_SESSION_ID",
  "GIT_SSH", "GIT_SSH_COMMAND", "GIT_SSH_VARIANT", "GIT_SSH_STUB_FAIL", "GIT_SSH_STUB_INJECT", "GIT_SSH_STUB_REPO",
  "GIT_SSH_STUB_LOG", "GIT_SSH_STUB_CALL_LOG"]) delete BASE[n];
const envWith = (extra) => ({ ...BASE, ...extra });
const STUB_ENV = envWith({ GIT_SSH_COMMAND: STUB_CMD });

function rgit(args, cwd = TMP) {
  const r = spawnSync(REALGIT, args, { cwd, env: BASE, encoding: "utf8" });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr}`);
  return r.stdout.trim();
}
const refOf = (gitDir, ref) => spawnSync(REALGIT, ["--git-dir", gitDir, "rev-parse", "-q", "--verify", ref], { env: BASE, encoding: "utf8" }).stdout.trim();
const hits = (g) => (fs.existsSync(`${g}/hits`) ? fs.readdirSync(`${g}/hits`).length : 0);
const guard = (g, cwd, env, args) => spawnSync(`${g}/bin/git${EXE}`, args, { cwd, env, encoding: "utf8", timeout: 60000 });

function expectAllow(cwd, env, args, g = GDIR) {
  const before = hits(g);
  const r = guard(g, cwd, env, args);
  assert.strictEqual(r.status, 0, `allowed: git ${args.join(" ")}\n${r.stderr}`);
  assert.strictEqual(hits(g), before, `no hit: git ${args.join(" ")}`);
  return r;
}
function expectRefuse(cwd, env, args, g = GDIR) {
  const before = hits(g);
  const r = guard(g, cwd, env, args);
  assert.strictEqual(r.status, 97, `refused: git ${args.join(" ")}\n${r.stderr}`);
  assert.strictEqual(hits(g), before + 1, `one hit: git ${args.join(" ")}`);
  assert.ok(r.stderr.includes("(network URL)"), `reason network URL: ${r.stderr}`);
  return r;
}

const SSH_URL = "ssh://git@github.com/test-owner/test-repo.git";
const SCP_URL = "git@github.com:test-owner/test-repo.git";
function mkRepo(dir, config = {}) {
  rgit(["init", "-q", dir]);
  rgit(["-C", dir, "config", "core.hooksPath", "/dev/null"]);
  rgit(["-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "--allow-empty", "-m", "c"]);
  rgit(["-C", dir, "config", "remote.origin.url", SSH_URL]);
  for (const [k, v] of Object.entries(config)) rgit(["-C", dir, "config", k, v]);
  return dir;
}
rgit(["init", "-q", "--bare", BARE]);
const SRC = mkRepo(`${RR}/src`);
const SEED = rgit(["-C", SRC, "rev-parse", "HEAD"]);
rgit(["-C", SRC, "push", "-q", BARE, "HEAD:refs/heads/seed"]);
const head = (repo) => rgit(["-C", repo, "rev-parse", "HEAD"]);

// A wrapper that runs the stub, and a byte-identical copy of it: neither is the declared stub.
const WRAP = `${TMP}/ssh-wrap.sh`;
fs.writeFileSync(WRAP, `#!/bin/sh\nexec sh "${STUB}" "$@"\n`);
const COPY = `${TMP}/git-ssh-stub.sh`;
fs.copyFileSync(STUB, COPY);

caseBegin("builder-declares-the-tree-stub", "tests/lib/command-guard-build.js");
test("command-guard-build.js --instance writes one sshstub= line naming this tree's git-ssh-stub.sh", () => {
  const lines = BUILT_CONF.split("\n").filter((l) => l.startsWith("sshstub="));
  assert.strictEqual(lines.length, 1, `one sshstub= line:\n${BUILT_CONF}`);
  const declared = lines[0].slice("sshstub=".length);
  assert.ok(path.isAbsolute(declared), `absolute: ${declared}`);
  const canon = (p) => { const r = fwd(fs.realpathSync.native(p)); return process.platform === "win32" ? r.toLowerCase() : r; };
  assert.strictEqual(canon(declared), canon(STUB));
  assert.ok(fs.existsSync(`${GDIR}/bin/git${EXE}`), "the instance has a generated bin/git");
});
caseEnd();

caseBegin("stub-via-git-ssh-command-is-allowed", "tests/lib/command-guard/ssh-stub.js");
test("push / fetch / ls-remote / clone over ssh with GIT_SSH_COMMAND starting the stub pass and reach the bare", () => {
  const repo = mkRepo(`${RR}/a`);
  expectAllow(repo, STUB_ENV, ["push", "-q", "origin", "HEAD:refs/heads/a"]);
  assert.strictEqual(refOf(BARE, "refs/heads/a"), head(repo));
  assert.ok(expectAllow(repo, STUB_ENV, ["ls-remote", "origin"]).stdout.includes(SEED));
  expectAllow(repo, STUB_ENV, ["fetch", "-q", "origin", "refs/heads/seed"]);
  assert.strictEqual(rgit(["-C", repo, "rev-parse", "FETCH_HEAD"]), SEED);
  expectAllow(repo, envWith({ GIT_SSH_COMMAND: STUB_CMD, GIT_SSH_STUB_REPO: "/test-owner/test-repo.git" }), ["push", "-q", SCP_URL, "HEAD:refs/heads/a-scp"]);
  assert.strictEqual(refOf(BARE, "refs/heads/a-scp"), head(repo));
  expectAllow(repo, envWith({ GIT_SSH_COMMAND: `bash '${STUB}' -o BatchMode=yes` }), ["ls-remote", "origin"]);
  expectAllow(RR, STUB_ENV, ["clone", "-q", SSH_URL, `${RR}/clone-a`]);
  assert.strictEqual(rgit(["-C", `${RR}/clone-a`, "rev-parse", "refs/remotes/origin/seed"]), SEED);
});
caseEnd();

caseBegin("stub-via-core-sshcommand-is-allowed", "tests/lib/command-guard/ssh-stub.js");
test("core.sshCommand from the repo config or from -c that starts the stub passes", () => {
  const repo = mkRepo(`${RR}/b`, { "core.sshCommand": STUB_CMD });
  expectAllow(repo, BASE, ["push", "-q", "origin", "HEAD:refs/heads/b"]);
  assert.strictEqual(refOf(BARE, "refs/heads/b"), head(repo));
  const plain = mkRepo(`${RR}/b2`);
  expectAllow(plain, BASE, ["-c", `core.sshCommand=${STUB_CMD}`, "fetch", "-q", "origin", "refs/heads/seed"]);
  assert.strictEqual(rgit(["-C", plain, "rev-parse", "FETCH_HEAD"]), SEED);
  expectAllow(RR, BASE, ["-c", `core.sshCommand=${STUB_CMD}`, "clone", "-q", SSH_URL, `${RR}/clone-b`]);
  expectRefuse(plain, BASE, ["push", "-q", "origin", "HEAD:refs/heads/b2"]);
  assert.strictEqual(refOf(BARE, "refs/heads/b2"), "");
});
caseEnd();

caseBegin("stub-copy-or-wrapper-is-refused", "tests/lib/command-guard/ssh-stub.js");
test("a copy of the stub, a wrapper around it, sh -c and env prefixes are refused", () => {
  const repo = mkRepo(`${RR}/c`);
  for (const cmd of [`sh "${COPY}"`, `sh "${WRAP}"`, `"${WRAP}"`, `sh -c 'sh ${STUB}'`, `env sh "${STUB}"`, `ssh`, "false"]) {
    expectRefuse(repo, envWith({ GIT_SSH_COMMAND: cmd }), ["push", "-q", "origin", "HEAD:refs/heads/c"]);
  }
  expectRefuse(repo, BASE, ["-c", `core.sshCommand=sh "${WRAP}"`, "ls-remote", "origin"]);
  expectRefuse(repo, envWith({ GIT_SSH: WRAP }), ["ls-remote", "origin"]);
  assert.strictEqual(refOf(BARE, "refs/heads/c"), "");
});
caseEnd();

caseBegin("stub-with-shell-syntax-is-refused", "tests/lib/command-guard/ssh-stub.js");
test("chaining, pipes, substitution, redirects and expansions around the stub are refused", () => {
  const repo = mkRepo(`${RR}/d`);
  const cmds = [`${STUB_CMD}; true`, `${STUB_CMD} && true`, `${STUB_CMD} | cat`, `sh "$(echo ${STUB})"`, `sh \`echo ${STUB}\``,
    `${STUB_CMD} > ${TMP}/o`, `sh "${STUB}" "$HOME"`, `${STUB_CMD} &`, `sh ${STUB} # x`, `sh "${STUB}`];
  for (const cmd of cmds) {
    expectRefuse(repo, envWith({ GIT_SSH_COMMAND: cmd }), ["push", "-q", "origin", "HEAD:refs/heads/d"]);
  }
  expectRefuse(repo, BASE, ["-c", `core.sshCommand=${STUB_CMD}; true`, "fetch", "-q", "origin"]);
  assert.strictEqual(refOf(BARE, "refs/heads/d"), "");
});
caseEnd();

caseBegin("ssh-command-precedence-follows-git", "tests/lib/command-guard/ssh-stub.js");
test("GIT_SSH_COMMAND beats core.sshCommand, which beats GIT_SSH; GIT_SSH naming the stub's absolute path passes", () => {
  const stubRepo = mkRepo(`${RR}/e`, { "core.sshCommand": STUB_CMD });
  expectRefuse(stubRepo, envWith({ GIT_SSH_COMMAND: "false" }), ["ls-remote", "origin"]);
  const falseRepo = mkRepo(`${RR}/e2`, { "core.sshCommand": "false" });
  expectAllow(falseRepo, STUB_ENV, ["push", "-q", "origin", "HEAD:refs/heads/e2"]);
  assert.strictEqual(refOf(BARE, "refs/heads/e2"), head(falseRepo));
  expectRefuse(falseRepo, envWith({ GIT_SSH: STUB }), ["ls-remote", "origin"]);
  const plain = mkRepo(`${RR}/e3`);
  expectAllow(plain, envWith({ GIT_SSH: STUB }), ["push", "-q", "origin", "HEAD:refs/heads/e3"]);
  assert.strictEqual(refOf(BARE, "refs/heads/e3"), head(plain));
  assert.ok(expectAllow(plain, envWith({ GIT_SSH: STUB }), ["ls-remote", "origin"]).stdout.includes(SEED));
  expectRefuse(plain, envWith({ GIT_SSH: WRAP }), ["ls-remote", "origin"]);
  expectRefuse(plain, envWith({ GIT_SSH: `sh ${STUB}` }), ["ls-remote", "origin"]);
});
caseEnd();

caseBegin("non-ssh-transports-stay-refused", "tests/lib/command-guard/ssh-stub.js");
test("https / git:// / ssh:: helper URLs are refused even with the stub as the ssh command", () => {
  const repo = mkRepo(`${RR}/f`, {
    "remote.web.url": "https://github.com/test-owner/test-repo.git",
    "remote.daemon.url": "git://github.com/test-owner/test-repo.git",
    "remote.helper.url": "ssh::git@github.com/test-owner/test-repo.git",
  });
  for (const remote of ["web", "daemon", "helper"]) {
    expectRefuse(repo, STUB_ENV, ["push", "-q", remote, "HEAD:refs/heads/f"]);
    expectRefuse(repo, STUB_ENV, ["ls-remote", remote]);
  }
  expectRefuse(RR, STUB_ENV, ["clone", "-q", "https://github.com/test-owner/test-repo.git", `${RR}/clone-f`]);
  assert.ok(!fs.existsSync(`${RR}/clone-f`));
});
caseEnd();

caseBegin("no-declared-stub-refuses-every-ssh-url", "tests/lib/command-guard/main.js");
test("a guard.conf without sshstub= (or naming a missing file) refuses the stub command too", () => {
  const repo = mkRepo(`${RR}/g`);
  expectRefuse(repo, STUB_ENV, ["push", "-q", "origin", "HEAD:refs/heads/g"], GDIR_NOSTUB);
  expectRefuse(repo, STUB_ENV, ["ls-remote", "origin"], GDIR_NOSTUB);
  const missing = `${TMP}/guard-missing`;
  withStubLine(missing, `sshstub=${TMP}/absent.sh`);
  expectRefuse(repo, envWith({ GIT_SSH_COMMAND: `sh "${TMP}/absent.sh"` }), ["ls-remote", "origin"], missing);
  assert.strictEqual(refOf(BARE, "refs/heads/g"), "");
});
caseEnd();
