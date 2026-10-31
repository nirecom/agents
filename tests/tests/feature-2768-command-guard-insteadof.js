"use strict";
// Tests: tests/lib/command-guard/main.js, tests/lib/command-guard/resolve-target.js, tests/lib/command-guard/remote-urls.js
// Tags: scope:issue-specific, tl2, command-guard, fixture-isolation
// The command guard judges a remote URL after git's own url.<base>.insteadOf / pushInsteadOf
// rewriting (#2768): a network URL rewritten to a repo inside the run root passes, a local URL
// rewritten to the network is refused, a push rewritten outside the run root is refused, and a
// push to a raw network URL stays refused whatever it is rewritten to.
// The guard's main.js runs directly against a fixture guard dir (guard.conf: real git, run root).
const { caseBegin, caseEnd } = require("../lib/harness");

const assert = require("node:assert");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..");
const MAIN_JS = path.join(SCRIPT_CHECKOUT_ROOT, "tests", "lib", "command-guard", "main.js");
const EXE = process.platform === "win32" ? ".exe" : "";
const fwd = (p) => p.replace(/\\/g, "/");
const TMP = fwd(fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), "cg2768-"))));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));

const RR = `${TMP}/rr`;
const OUTSIDE = `${TMP}/outside`;
const HOME = `${TMP}/home`;
const GDIR = `${TMP}/guard`;
for (const d of [RR, OUTSIDE, HOME, GDIR]) fs.mkdirSync(d, { recursive: true });
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
fs.writeFileSync(`${GDIR}/guard.conf`, `realgit=${REALGIT}\nallowed=${RR}\n`);

const ENV = { ...process.env, HOME, USERPROFILE: HOME, GIT_CONFIG_GLOBAL: `${HOME}/.gitconfig`, GIT_CONFIG_NOSYSTEM: "1",
  GIT_TERMINAL_PROMPT: "0", GIT_SSH_COMMAND: "false", ROOT_DECOY_TEST_ID: "cg2768" };
for (const n of ["GIT_DIR", "GIT_WORK_TREE", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "CLAUDE_CODE_SESSION_ID"]) delete ENV[n];

function rgit(args, cwd = TMP) {
  const r = spawnSync(REALGIT, args, { cwd, env: ENV, encoding: "utf8" });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr}`);
  return r.stdout.trim();
}
const refOf = (gitDir, ref) => spawnSync(REALGIT, ["--git-dir", gitDir, "rev-parse", "-q", "--verify", ref], { env: ENV, encoding: "utf8" }).stdout.trim();
const hits = () => (fs.existsSync(`${GDIR}/hits`) ? fs.readdirSync(`${GDIR}/hits`).length : 0);
const guard = (cwd, args) => spawnSync(process.execPath, [MAIN_JS, GDIR, "git", ...args], { cwd, env: ENV, encoding: "utf8", timeout: 60000 });

function mkRepo(dir, remotes = {}) {
  rgit(["init", "-q", dir]);
  rgit(["-C", dir, "config", "core.hooksPath", "/dev/null"]);
  rgit(["-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "--allow-empty", "-m", "c"]);
  for (const [k, v] of Object.entries(remotes)) rgit(["-C", dir, "config", "--add", k, v]);
  return dir;
}
const bare = (dir) => (rgit(["init", "-q", "--bare", dir]), dir);

function expectAllow(cwd, args) {
  const before = hits();
  const r = guard(cwd, args);
  assert.strictEqual(r.status, 0, `allowed: git ${args.join(" ")}\n${r.stderr}`);
  assert.strictEqual(hits(), before, `no hit: git ${args.join(" ")}`);
  return r;
}
function expectRefuse(cwd, args, reason) {
  const before = hits();
  const r = guard(cwd, args);
  assert.strictEqual(r.status, 97, `refused: git ${args.join(" ")}\n${r.stderr}`);
  assert.strictEqual(hits(), before + 1, `one hit: git ${args.join(" ")}`);
  assert.ok(r.stderr.includes(`(${reason})`), `reason ${reason}: ${r.stderr}`);
  return r;
}

const BARE_A = bare(`${RR}/bareA.git`);
const BARE_B = bare(`${RR}/bareB.git`);
const BARE_C = bare(`${RR}/bareC.git`);
const BARE_D = bare(`${RR}/bareD.git`);
const OUT_BARE = bare(`${OUTSIDE}/outbare.git`);
const SRC = mkRepo(`${RR}/src`);
const SEED = rgit(["-C", SRC, "rev-parse", "HEAD"]);
rgit(["-C", SRC, "push", "-q", BARE_A, "HEAD:refs/heads/seed"]);
const SSH_ORIGIN = "ssh://git@github.com/test-owner/test-repo.git";

caseBegin("insteadof-network-remote-rewritten-inside-is-allowed", "tests/lib/command-guard/remote-urls.js");
test("push / ls-remote / fetch to an ssh remote that insteadOf rewrites to an inside bare repo pass", () => {
  const repo = mkRepo(`${RR}/a`, { "remote.origin.url": SSH_ORIGIN, [`url.${BARE_A}.insteadOf`]: SSH_ORIGIN });
  const head = rgit(["-C", repo, "rev-parse", "HEAD"]);
  expectAllow(repo, ["push", "-q", "origin", "HEAD:refs/heads/a"]);
  assert.strictEqual(refOf(BARE_A, "refs/heads/a"), head);
  assert.ok(expectAllow(repo, ["ls-remote", "origin"]).stdout.includes(head));
  expectAllow(repo, ["fetch", "-q", "origin", "refs/heads/seed"]);
  assert.strictEqual(rgit(["-C", repo, "rev-parse", "FETCH_HEAD"]), SEED);
});
caseEnd();

caseBegin("pushinsteadof-network-remote-rewritten-inside-is-allowed", "tests/lib/command-guard/remote-urls.js");
test("push via pushInsteadOf to an inside bare repo passes; the unrewritten fetch side stays refused", () => {
  const url = "ssh://example.invalid/pi.git";
  const repo = mkRepo(`${RR}/b`, { "remote.pi.url": url, [`url.${BARE_B}.pushInsteadOf`]: url });
  expectAllow(repo, ["push", "-q", "pi", "HEAD:refs/heads/b"]);
  assert.strictEqual(refOf(BARE_B, "refs/heads/b"), rgit(["-C", repo, "rev-parse", "HEAD"]));
  expectRefuse(repo, ["fetch", "-q", "pi"], "network URL");
});
caseEnd();

caseBegin("local-remote-rewritten-to-network-is-refused", "tests/lib/command-guard/remote-urls.js");
test("insteadOf / pushInsteadOf that rewrite an inside url to the network are refused", () => {
  const repo = mkRepo(`${RR}/c`, {
    "remote.leak.url": BARE_C, "url.https://example.invalid/leak.git.insteadOf": BARE_C,
    "remote.pleak.url": BARE_D, "url.https://example.invalid/pleak.git.pushInsteadOf": BARE_D,
  });
  expectRefuse(repo, ["fetch", "-q", "leak"], "network URL");
  expectRefuse(repo, ["push", "-q", "leak", "HEAD:refs/heads/c"], "network URL");
  assert.strictEqual(refOf(BARE_C, "refs/heads/c"), "");
  expectRefuse(repo, ["push", "-q", "pleak", "HEAD:refs/heads/c"], "network URL");
  assert.strictEqual(refOf(BARE_D, "refs/heads/c"), "");
  expectAllow(repo, ["ls-remote", "pleak"]);
});
caseEnd();

caseBegin("insteadof-from-c-globals-is-honoured", "tests/lib/command-guard/remote-urls.js");
test("git -c url.<base>.insteadOf=... rewrites in both directions", () => {
  const url = "ssh://example.invalid/d.git";
  const repo = mkRepo(`${RR}/d`, { "remote.origin.url": url, "remote.loc.url": BARE_A });
  expectAllow(repo, ["-c", `url.${BARE_A}.insteadOf=${url}`, "push", "-q", "origin", "HEAD:refs/heads/d"]);
  assert.strictEqual(refOf(BARE_A, "refs/heads/d"), rgit(["-C", repo, "rev-parse", "HEAD"]));
  expectRefuse(repo, ["push", "-q", "origin", "HEAD:refs/heads/d2"], "network URL");
  expectRefuse(repo, ["-c", `url.https://example.invalid/z.git.insteadOf=${BARE_A}`, "ls-remote", "loc"], "network URL");
  expectAllow(repo, ["ls-remote", "loc"]);
  const leak = ["-c", `remote.x.url=${BARE_A}`, "-c", `url.https://example.invalid/r.git.pushInsteadOf=${BARE_A}`];
  expectRefuse(repo, [...leak, "push", "-q", "x", "HEAD:refs/heads/r"], "network URL");
  assert.strictEqual(refOf(BARE_A, "refs/heads/r"), "");
});
caseEnd();

caseBegin("raw-url-operand-push-stays-conservative", "tests/lib/command-guard/remote-urls.js");
test("a raw network push operand is refused even when rewritten inside; a raw fetch follows the rewrite", () => {
  const url = "ssh://example.invalid/e.git";
  const repo = mkRepo(`${RR}/e`);
  const rewrite = `url.${BARE_A}.insteadOf=${url}`;
  expectRefuse(repo, ["-c", rewrite, "push", "-q", url, "HEAD:refs/heads/e"], "network URL");
  assert.strictEqual(refOf(BARE_A, "refs/heads/e"), "");
  expectAllow(repo, ["-c", rewrite, "fetch", "-q", url, "refs/heads/seed"]);
  assert.strictEqual(rgit(["-C", repo, "rev-parse", "FETCH_HEAD"]), SEED);
  expectRefuse(repo, ["-c", `url.https://example.invalid/q.git.pushInsteadOf=${BARE_A}`, "push", "-q", BARE_A, "HEAD:refs/heads/q"], "network URL");
  assert.strictEqual(refOf(BARE_A, "refs/heads/q"), "");
  expectAllow(repo, ["push", "-q", BARE_A, "HEAD:refs/heads/e2"]);
  assert.strictEqual(refOf(BARE_A, "refs/heads/e2"), rgit(["-C", repo, "rev-parse", "HEAD"]));
});
caseEnd();

caseBegin("push-rewritten-outside-the-run-root-is-refused", "tests/lib/command-guard/resolve-target.js");
test("a push that insteadOf / pushInsteadOf rewrite to an outside path is refused as an outside write", () => {
  const u1 = "ssh://example.invalid/out.git";
  const u2 = "ssh://example.invalid/out2.git";
  const repo = mkRepo(`${RR}/f`, { "remote.out.url": u1, [`url.${OUT_BARE}.insteadOf`]: u1, "remote.out2.url": u2, [`url.${OUT_BARE}.pushInsteadOf`]: u2 });
  expectRefuse(repo, ["push", "-q", "out", "HEAD:refs/heads/f"], "write outside the run root");
  expectRefuse(repo, ["push", "-q", "out2", "HEAD:refs/heads/f"], "write outside the run root");
  assert.strictEqual(refOf(OUT_BARE, "refs/heads/f"), "");
});
caseEnd();

caseBegin("no-operand-checks-every-remote", "tests/lib/command-guard/remote-urls.js");
test("bare fetch / push are refused while any remote reaches the network; all-rewritten-inside passes", () => {
  const url = "ssh://example.invalid/g.git";
  const repo = mkRepo(`${RR}/g`, { "remote.origin.url": url, [`url.${BARE_A}.insteadOf`]: url, "remote.net.url": "https://example.invalid/net.git" });
  expectRefuse(repo, ["fetch", "-q"], "network URL");
  expectRefuse(repo, ["push", "-q"], "network URL");
  const only = mkRepo(`${RR}/g2`, { "remote.origin.url": url, [`url.${BARE_A}.insteadOf`]: url, "remote.origin.fetch": "+refs/heads/*:refs/remotes/origin/*" });
  expectAllow(only, ["fetch", "-q"]);
  assert.strictEqual(rgit(["-C", only, "rev-parse", "refs/remotes/origin/seed"]), SEED);
});
caseEnd();

caseBegin("clone-source-is-judged-after-rewriting", "tests/lib/command-guard/resolve-target.js");
test("clone follows insteadOf from globals and from its own -c, and plain network clones stay refused", () => {
  const url = "ssh://example.invalid/c.git";
  expectAllow(RR, ["-c", `url.${SRC}.insteadOf=${url}`, "clone", "-q", url, `${RR}/clone-ok`]);
  assert.ok(fs.existsSync(`${RR}/clone-ok/.git`));
  expectRefuse(RR, ["clone", "-q", "-c", `url.https://example.invalid/c.git.insteadOf=${SRC}`, SRC, `${RR}/clone-leak`], "network URL");
  assert.ok(!fs.existsSync(`${RR}/clone-leak`));
  expectRefuse(RR, ["clone", "-q", "https://example.invalid/x/y", `${RR}/y`], "network URL");
});
caseEnd();

caseBegin("plain-remotes-keep-their-verdicts", "tests/lib/command-guard/main.js");
test("a plain network remote is refused and a plain inside remote passes", () => {
  const repo = mkRepo(`${RR}/h`, { "remote.net.url": "https://example.invalid/h.git", "remote.in.url": BARE_A });
  expectRefuse(repo, ["fetch", "-q", "net"], "network URL");
  expectRefuse(repo, ["push", "-q", "net", "HEAD:refs/heads/h"], "network URL");
  expectAllow(repo, ["push", "-q", "in", "HEAD:refs/heads/h"]);
  assert.strictEqual(refOf(BARE_A, "refs/heads/h"), rgit(["-C", repo, "rev-parse", "HEAD"]));
  expectAllow(repo, ["fetch", "-q", "in", "refs/heads/seed"]);
});
caseEnd();
