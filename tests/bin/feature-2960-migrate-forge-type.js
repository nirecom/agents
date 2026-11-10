"use strict";
// Tests: bin/lib/migrate-forge-type.js, bin/lib/migrate-needs.js, bin/detect-forge-type
// Tags: TL2, bin, migrate, gitlab, forge, table-driven, scope:issue-specific
// #2960 — migrate judges the origin host with the forge resolver (GITLAB_HOSTNAME from the effective .env,
// exact host match); only when it says unknown but read a project path does it guess gitlab for a host
// with a `gitlab.` label, or github for the plan-sync alias ssh.github.com with an exact owner/repo project.
// bin/detect-forge-type applies the guess only with --guess-unconfigured-host, which no existing caller
// passes. Contract: the #2960 detail plan S1-S3 and S8.
// TL3 gap: a real self-managed GitLab origin; every origin here is a URL string never contacted.
// Closest-to-action mitigation: none — no bin/check-verification-gate.sh category covers the host judgment.
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const cp = require("node:child_process");

const restore = isolate();
after(() => restore());

const CHECKOUT = path.resolve(__dirname, "..", "..");
const LIB = path.join(CHECKOUT, "bin", "lib", "migrate-forge-type.js");
const NEEDS = path.join(CHECKOUT, "bin", "lib", "migrate-needs.js");
const CLI = path.join(CHECKOUT, "bin", "detect-forge-type");
const FLAG = "--guess-unconfigured-host";
const { resolveForgeTarget } = require(path.join(CHECKOUT, "hooks", "lib", "parse-remote-url.js"));

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "mft2960-"));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));
// No global .env and no exported GitLab host: only a fixture's .env.local may configure one.
const MAIN = path.join(TMP, "stub-agents");
fs.mkdirSync(MAIN);
const STRIP = new Set(["GITLAB_HOSTNAME", "GITLAB_SSH_HOSTNAME", "CLAUDE_PROJECT_DIR", "AGENTS_MAIN_ROOT"]);
const savedEnv = {};
for (const k of Object.keys(process.env)) {
  if (STRIP.has(k.toUpperCase())) {
    savedEnv[k] = process.env[k];
    delete process.env[k];
  }
}
process.env.AGENTS_MAIN_ROOT = MAIN;
after(() => {
  delete process.env.AGENTS_MAIN_ROOT;
  Object.assign(process.env, savedEnv);
});
const CHILD_ENV = { ...process.env };

// want: the migrate judgment (lib, hostOf, CLI with the flag); plain: the CLI default (resolver as is).
const CASES = [
  { name: "configured", origin: "git@git.example.com:grp/sub/proj.git", local: "git.example.com", want: "gitlab", plain: "gitlab" },
  { name: "gitlab-com-subgroup", origin: "git@gitlab.com:grp/sub/proj.git", want: "gitlab", plain: "gitlab" },
  { name: "unconfigured-gitlab", origin: "https://gitlab.example.com/grp/proj.git", want: "gitlab", plain: "unknown" },
  { name: "unconfigured-gitlab-inner-label", origin: "https://git.gitlab.internal/grp/proj.git", want: "gitlab", plain: "unknown" },
  { name: "unconfigured-other", origin: "https://git.example.org/grp/proj.git", want: "unknown", plain: "unknown" },
  { name: "gitlab-substring-host", origin: "https://notgitlab.example.com/grp/proj.git", want: "unknown", plain: "unknown" },
  { name: "gitlab-label-prefix", origin: "https://gitlab-ci.example.com/grp/proj.git", want: "unknown", plain: "unknown" },
  { name: "gitlab-label-suffix", origin: "https://example.gitlabx.com/grp/proj.git", want: "unknown", plain: "unknown" },
  { name: "gitlab-in-path-only", origin: "https://example.com/gitlab.x/proj.git", want: "unknown", plain: "unknown" },
  { name: "github", origin: "git@github.com:o/r.git", want: "github", plain: "github" },
  { name: "ssh-github", origin: "git@ssh.github.com:o/r.git", want: "github", plain: "unknown" },
  { name: "ssh-github-https", origin: "https://ssh.github.com/o/r.git", want: "github", plain: "unknown" },
  { name: "ssh-github-subgroup", origin: "git@ssh.github.com:o/r/x.git", want: "unknown", plain: "unknown" },
  { name: "poisoned-path", origin: "https://gitlab.example.com/grp/../proj.git", want: "unknown", plain: "unknown" },
  { name: "scp-no-user", origin: "gitlab.example.com:grp/proj.git", want: "unknown", plain: "unknown" },
  { name: "ssh-host-configured", origin: "git@ssh.git.example.com:grp/proj.git", sshLocal: "ssh.git.example.com", want: "gitlab", plain: "gitlab" },
  { name: "ssh-host-unconfigured", origin: "git@ssh.git.example.com:grp/proj.git", want: "unknown", plain: "unknown" },
];

function repo(c) {
  const d = path.join(TMP, c.name);
  fs.mkdirSync(d, { recursive: true });
  gitInit(d);
  const r = cp.spawnSync("git", ["-C", d, "remote", "add", "origin", c.origin], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(`git remote add ${c.origin}: ${r.stderr}`);
  const env = [c.local && `GITLAB_HOSTNAME=${c.local}`, c.sshLocal && `GITLAB_SSH_HOSTNAME=${c.sshLocal}`].filter(Boolean);
  if (env.length > 0) fs.writeFileSync(path.join(d, ".env.local"), `${env.join("\n")}\n`);
  return d;
}
const ROOTS = Object.fromEntries(CASES.map((c) => [c.name, repo(c)]));

function lib() {
  assert.ok(fs.existsSync(LIB), "bin/lib/migrate-forge-type.js exists (not implemented yet)");
  const mod = require(LIB);
  assert.equal(typeof mod.guessUnconfiguredType, "function", "exports guessUnconfiguredType");
  assert.equal(typeof mod.migrateForgeType, "function", "exports migrateForgeType");
  return mod;
}
const typeOf = (out) => (typeof out === "string" ? out : out && out.type);

function cli(args) {
  const r = cp.spawnSync(process.execPath, [CLI, ...args], { encoding: "utf8", env: CHILD_ENV, timeout: 60000 });
  return { rc: r.status, out: String(r.stdout || "").trim(), err: String(r.stderr || "") };
}

caseBegin("MFT-guess-pure", "bin/lib/migrate-forge-type.js");
test("MFT-guess-pure: only an unknown result with a host and a project is guessed, toward gitlab or the github alias", () => {
  const { guessUnconfiguredType } = lib();
  const cases = [
    { name: "github passes through", res: { type: "github", host: "github.com", project: "o/r" }, want: "github" },
    { name: "configured gitlab passes through", res: { type: "gitlab", host: "git.example.com", project: "g/p" }, want: "gitlab" },
    { name: "gitlab.* host", res: { type: "unknown", host: "gitlab.example.com", project: "g/p" }, want: "gitlab" },
    { name: "gitlab.* host in upper case", res: { type: "unknown", host: "GitLab.Example.com", project: "g/p" }, want: "gitlab" },
    { name: "inner gitlab label", res: { type: "unknown", host: "git.gitlab.internal", project: "g/s/p" }, want: "gitlab" },
    { name: "gitlab.* without project", res: { type: "unknown", host: "gitlab.example.com", project: null }, want: "unknown" },
    { name: "no host", res: { type: "unknown", host: null, project: null }, want: "unknown" },
    { name: "ssh.github.com is the github alias", res: { type: "unknown", host: "ssh.github.com", project: "o/r" }, want: "github" },
    { name: "ssh.github.com in upper case", res: { type: "unknown", host: "SSH.GitHub.com", project: "o/r" }, want: "github" },
    { name: "ssh.github.com with a subgroup-shaped path", res: { type: "unknown", host: "ssh.github.com", project: "o/r/x" }, want: "unknown" },
    { name: "ssh.github.com without project", res: { type: "unknown", host: "ssh.github.com", project: null }, want: "unknown" },
    { name: "github look-alike", res: { type: "unknown", host: "github.com.evil.example", project: "o/r" }, want: "unknown" },
    { name: "alias key as a label suffix", res: { type: "unknown", host: "notssh.github.com", project: "o/r" }, want: "unknown" },
    { name: "alias key with a prefixed letter", res: { type: "unknown", host: "xssh.github.com", project: "o/r" }, want: "unknown" },
    { name: "alias key as a host prefix", res: { type: "unknown", host: "ssh.github.com.evil.example", project: "o/r" }, want: "unknown" },
    { name: "gitlab as a substring of a label", res: { type: "unknown", host: "notgitlab.example.com", project: "g/p" }, want: "unknown" },
    { name: "gitlab as a label prefix", res: { type: "unknown", host: "gitlab-ci.example.com", project: "g/p" }, want: "unknown" },
    { name: "gitlab as a label stem", res: { type: "unknown", host: "example.gitlabx.com", project: "g/p" }, want: "unknown" },
  ];
  for (const { name, res, want } of cases) {
    assert.equal(typeOf(guessUnconfiguredType({ ...res })), want, name);
  }
});
caseEnd();

caseBegin("MFT-migrate-forge-type", "bin/lib/migrate-forge-type.js");
test("MFT-migrate-forge-type: type per the CASES table; host and project are the resolver's own", () => {
  const { migrateForgeType } = lib();
  for (const c of CASES) {
    const got = migrateForgeType(c.origin, ROOTS[c.name]);
    const res = resolveForgeTarget(c.origin, { gitlabHost: c.local || null, gitlabSshHost: c.sshLocal || null });
    assert.equal(got.type, c.want, `${c.name}: type`);
    assert.equal(got.host, res.host, `${c.name}: host`);
    assert.equal(got.project, res.project, `${c.name}: project`);
  }
});
caseEnd();

caseBegin("MFT-hostOf-root", "bin/lib/migrate-needs.js");
test("MFT-hostOf-root: hostOf(url, root) reads the root's .env.local and follows the CASES table", () => {
  const { hostOf } = require(NEEDS);
  for (const c of CASES) {
    assert.equal(hostOf(c.origin, ROOTS[c.name]), c.want, `${c.name}: hostOf`);
    assert.equal(hostOf(`  ${c.origin}\n`, ROOTS[c.name]), c.want, `${c.name}: hostOf trims the git output`);
  }
  assert.equal(hostOf("git@git.example.com:grp/sub/proj.git", ROOTS.github), "unknown", "the configured host is unknown under a root that does not configure it");
});
caseEnd();

caseBegin("MFT-collect-root", "bin/lib/migrate-needs.js");
test("MFT-collect-root: collect(root).host and bin/migrate-needs HOST judge the origin with root's .env.local", () => {
  const { collect } = require(NEEDS);
  const origin = "git@git.example.com:grp/sub/proj.git";
  const rows = [
    { root: repo({ name: "collect-configured", origin, local: "git.example.com" }), want: "gitlab" },
    { root: repo({ name: "collect-unconfigured", origin }), want: "unknown" },
  ];
  for (const { root, want } of rows) {
    const name = path.basename(root);
    const got = collect(root);
    assert.ok(got.needed.includes("tracker") || got.needed.includes("issues"), `${name}: a host-judging skill is needed ${JSON.stringify(got.needed)}`);
    assert.equal(got.host, want, `${name}: collect(root).host`);
    const r = cp.spawnSync(process.execPath, [path.join(CHECKOUT, "bin", "migrate-needs"), "--root", root],
      { encoding: "utf8", env: CHILD_ENV, cwd: TMP, timeout: 60000 });
    assert.equal(r.status, 0, `${name}: migrate-needs rc ${r.stderr}`);
    assert.match(String(r.stdout), new RegExp(`^HOST=${want}$`, "m"), `${name}: migrate-needs HOST`);
  }
});
caseEnd();

caseBegin("MFT-cli-default-unchanged", "bin/detect-forge-type");
test("MFT-cli-default-unchanged: without the flag the CLI answers the resolver's type, never the guess", () => {
  for (const c of CASES) {
    for (const how of [["--repo-dir", ROOTS[c.name]], ["--url", c.origin, "--repo-dir", ROOTS[c.name]]]) {
      const r = cli([...how, "--field", "type"]);
      assert.equal(r.rc, 0, `${c.name} ${how[0]}: rc ${r.err}`);
      assert.equal(r.out, c.plain, `${c.name} ${how[0]}: default type`);
    }
  }
});
caseEnd();

caseBegin("MFT-cli-flag", "bin/detect-forge-type");
test("MFT-cli-flag: --guess-unconfigured-host changes the type only; host and project stay as without it", () => {
  for (const c of CASES) {
    const base = ["--repo-dir", ROOTS[c.name]];
    const r = cli([...base, "--field", "type", FLAG]);
    assert.equal(r.rc, 0, `${c.name}: rc ${r.err}`);
    assert.equal(r.out, c.want, `${c.name}: type with ${FLAG}`);
    assert.equal(cli([FLAG, "--url", c.origin, "--repo-dir", ROOTS[c.name], "--field", "type"]).out, c.want, `${c.name}: --url form, flag first`);
    for (const field of ["host", "project"]) {
      assert.equal(cli([...base, "--field", field, FLAG]).out, cli([...base, "--field", field]).out, `${c.name}: ${field} unchanged by the flag`);
    }
    const plain = JSON.parse(cli(base).out);
    const flagged = JSON.parse(cli([...base, FLAG]).out);
    assert.deepEqual(flagged, { ...plain, type: c.want }, `${c.name}: JSON output differs in type only`);
  }
});
caseEnd();

caseBegin("MFT-global-env-host", "bin/lib/migrate-forge-type.js");
test("MFT-global-env-host: a GITLAB_HOSTNAME in AGENTS_MAIN_ROOT/.env alone makes every judge answer gitlab", () => {
  // A tmp global root stands in for the agents .env; the repo has no .env.local.
  const GLOBAL = path.join(TMP, "global-root");
  fs.mkdirSync(GLOBAL, { recursive: true });
  fs.writeFileSync(path.join(GLOBAL, ".env"), "GITLAB_HOSTNAME=git.example.com\n");
  const origin = "git@git.example.com:grp/sub/proj.git";
  const root = repo({ name: "global-env-configured", origin });
  assert.ok(!fs.existsSync(path.join(root, ".env.local")), "fixture: no .env.local");
  const { migrateForgeType } = lib();
  const { hostOf } = require(NEEDS);
  // Control: the same repo under the empty global root is unknown, so the global .env is what decides.
  assert.equal(hostOf(origin, root), "unknown", "empty global root: hostOf");
  process.env.AGENTS_MAIN_ROOT = GLOBAL;
  try {
    assert.equal(migrateForgeType(origin, root).type, "gitlab", "migrateForgeType");
    assert.equal(hostOf(origin, root), "gitlab", "hostOf");
  } finally {
    process.env.AGENTS_MAIN_ROOT = MAIN;
  }
  const env = { ...CHILD_ENV, AGENTS_MAIN_ROOT: GLOBAL };
  for (const extra of [[], [FLAG]]) {
    const r = cp.spawnSync(process.execPath, [CLI, "--repo-dir", root, "--field", "type", ...extra], { encoding: "utf8", env, timeout: 60000 });
    assert.equal(r.status, 0, `CLI ${extra.join(" ")}: rc ${r.stderr}`);
    assert.equal(String(r.stdout).trim(), "gitlab", `CLI ${extra.join(" ") || "default"}: type`);
  }
});
caseEnd();

caseBegin("MFT-global-env-ssh-host", "bin/lib/migrate-forge-type.js");
test("MFT-global-env-ssh-host: a GITLAB_SSH_HOSTNAME in AGENTS_MAIN_ROOT/.env alone makes every judge answer gitlab", () => {
  const GLOBAL = path.join(TMP, "global-root-ssh");
  fs.mkdirSync(GLOBAL, { recursive: true });
  fs.writeFileSync(path.join(GLOBAL, ".env"), "GITLAB_SSH_HOSTNAME=ssh.git.example.com\n");
  const origin = "git@ssh.git.example.com:grp/proj.git";
  const root = repo({ name: "global-env-ssh-configured", origin });
  assert.ok(!fs.existsSync(path.join(root, ".env.local")), "fixture: no .env.local");
  const { migrateForgeType } = lib();
  const { hostOf } = require(NEEDS);
  assert.equal(migrateForgeType(origin, root).type, "unknown", "empty global root: migrateForgeType");
  assert.equal(hostOf(origin, root), "unknown", "empty global root: hostOf");
  process.env.AGENTS_MAIN_ROOT = GLOBAL;
  try {
    assert.equal(migrateForgeType(origin, root).type, "gitlab", "migrateForgeType");
    assert.equal(hostOf(origin, root), "gitlab", "hostOf");
  } finally {
    process.env.AGENTS_MAIN_ROOT = MAIN;
  }
  for (const [label, env, want] of [["empty global root", CHILD_ENV, "unknown"], ["global .env", { ...CHILD_ENV, AGENTS_MAIN_ROOT: GLOBAL }, "gitlab"]]) {
    for (const extra of [[], [FLAG]]) {
      const r = cp.spawnSync(process.execPath, [CLI, "--repo-dir", root, "--field", "type", ...extra], { encoding: "utf8", env, timeout: 60000 });
      assert.equal(r.status, 0, `${label} CLI ${extra.join(" ")}: rc ${r.stderr}`);
      assert.equal(String(r.stdout).trim(), want, `${label} CLI ${extra.join(" ") || "default"}: type`);
    }
  }
});
caseEnd();

caseBegin("MFT-callers-without-flag", "bin/detect-forge-type");
test("MFT-callers-without-flag: the existing detect-forge-type callers do not pass the opt-in flag", () => {
  const callers = [
    "bin/github-issues/wip-state.sh",
    "bin/github-issues/ensure-board-card.sh",
    "bin/github-issues/find-pr-by-marker.sh",
    "bin/github-issues/sync-labels.sh",
    "skills/get-release-approval/scripts/preflight.sh",
    "skills/worktree-end/SKILL.md",
    "bin/worker-dispatch/workers/commit-push/procedure.js",
  ];
  for (const rel of callers) {
    const src = fs.readFileSync(path.join(CHECKOUT, ...rel.split("/")), "utf8");
    assert.ok(src.includes("detect-forge-type"), `${rel}: still a detect-forge-type caller`);
    assert.ok(!src.includes(FLAG), `${rel}: passes ${FLAG}`);
  }
});
caseEnd();
