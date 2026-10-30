"use strict";
// Commit fixture of tests/hooks/feature-2507-precommit-node.js and -commit-edge.js (#2507). Holds
// no case markers.
// One template repo carries this checkout's hooks/ and bin/, a synthetic private-info list and
// stub gate checkers; each case copies it and runs a real `git commit` through its hooks/.
const assert = require("node:assert");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const REPO = path.join(__dirname, "..", "..", "..");
const SECTIONS = ["enforce-worktree", "settings-effort-unstage", "code-lang", "sh-exec-bit", "prompt-extraction",
  "tests-frontmatter", "agents-repo-gates", "comment-block-size", "repo-visibility", "env-file-block", "outbound-scan"];
// [cliPath, Node module path, marker name] of the six agents-repo gates, in call order.
const GATES = [
  ["bin/check-on-demand-rules.sh", "bin/lib/check-on-demand-rules.js", "check-on-demand-rules"],
  ["bin/check-session-id-ssot.sh", "bin/check-session-id-ssot/main.js", "check-session-id-ssot"],
  ["bin/check-migration-blocks.sh", "bin/lib/check-migration-blocks.js", "check-migration-blocks"],
  ["bin/check-plans-artifacts", "bin/check-plans-artifacts", "check-plans-artifacts"],
  ["bin/check-plans-dir-isolation.sh", "bin/check-plans-dir-isolation/main.js", "check-plans-dir-isolation"],
  ["bin/check-root-names.sh", "bin/check-root-names/main.js", "check-root-names"],
];
const GATE_MARKERS = GATES.map(([, , n]) => `agents-repo-gate-${n}`);
const AGENTS_SEQUENCE = [...SECTIONS.slice(0, 7), ...GATE_MARKERS, ...SECTIONS.slice(7)];
const HARD_TERM = "fixture-term-bravo";
const WARN_TERM = "fixture-term-alpha";
const SCRUB = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR",
  "CLAUDE_CODE_SESSION_ID", "CODE_LANG", "CODE_LANG_EXCLUDE", "DEFAULT_BRANCHES", "ENFORCE_WORKTREE_EXCLUDE",
  "ENFORCE_WORKTREE_EXCLUDE_REPOS", "COMMENT_BLOCK_ENFORCE", "COMMENT_BLOCK_MAX_LINES", "CODE_FILE_EXTENSIONS"];

const fwd = (p) => p.replace(/\\/g, "/");

// A gate stub: records its name in $F2507_CALLS, prints one line, and answers the rc that
// $F2507_GATE_FAIL=<name>:<rc> names (0 otherwise). The bash form serves the cliPath.
const bashGate = (n) => ["#!/usr/bin/env bash", `[ -n "\${F2507_CALLS:-}" ] && printf '%s\\n' '${n}' >> "$F2507_CALLS"`,
  `echo 'gate-out ${n}'`, `case "\${F2507_GATE_FAIL:-}" in ${n}:*) exit "\${F2507_GATE_FAIL#*:}" ;; esac`, "exit 0", ""].join("\n");
const nodeStub = (n, failVar) => `"use strict";
const fs = require("fs");
function run(o) {
  if (process.env.F2507_CALLS) fs.appendFileSync(process.env.F2507_CALLS, "${n}\\n");
  ((o && o.stdout) || process.stdout).write("gate-out ${n}\\n");
  const f = process.env.${failVar} || "";
  return f.startsWith("${n}:") ? Number(f.slice(${n.length + 1})) : 0;
}
module.exports = { run };
if (require.main === module) process.exitCode = run({ argv: process.argv.slice(2), stdout: process.stdout });
`;

function makeTemplate(tmpRoot, gitInit) {
  let seq = 0;
  const tmp = (name) => {
    seq += 1;
    const dir = path.join(tmpRoot, `${name}-${seq}`);
    fs.mkdirSync(dir, { recursive: true });
    return dir;
  };
  const git = (cwd, args, { allowFail = false } = {}) => {
    const done = spawnSync("git", ["-C", cwd, ...args], { encoding: "utf8", env: scrubbedEnv() });
    if (!allowFail) assert.strictEqual(done.status, 0, `git ${args.join(" ")}: ${done.stderr}`);
    return allowFail ? done : done.stdout.trim();
  };
  const write = (dir, rel, body) => {
    const file = path.join(dir, rel);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, body);
    if (/\.sh$|^bin\/check-plans-artifacts$/.test(rel)) fs.chmodSync(file, 0o755);
    return file;
  };
  const initRepo = (dir, branch = "main") => {
    gitInit(dir);
    git(dir, ["config", "user.name", "f2507"]);
    git(dir, ["config", "user.email", "f2507@example.invalid"]);
    git(dir, ["config", "commit.gpgsign", "false"]);
    git(dir, ["symbolic-ref", "HEAD", `refs/heads/${branch}`]);
  };

  const T = tmp("template");
  initRepo(T);
  fs.cpSync(path.join(REPO, "hooks"), path.join(T, "hooks"), { recursive: true });
  fs.cpSync(path.join(REPO, "bin"), path.join(T, "bin"), { recursive: true });
  write(T, ".env", "ENFORCE_WORKTREE=off\n");
  write(T, ".gitignore", ".env\n.private-info-blocklist\n.private-info-allowlist\n");
  write(T, ".private-info-blocklist", `warn:${WARN_TERM}\n${HARD_TERM}\n`);
  write(T, ".private-info-allowlist", "");
  write(T, ".prompt-extraction-allowlist", "");
  write(T, "bin/lib/prompt-extraction/cli.js", nodeStub("prompt-extraction", "F2507_PE_FAIL"));
  for (const [cli, mod, n] of GATES) {
    if (cli !== mod) write(T, cli, bashGate(n));
    write(T, mod, nodeStub(n, "F2507_GATE_FAIL"));
  }
  fs.cpSync(path.join(REPO, "tests", "lib", "harness.js"), path.join(T, "tests", "lib", "harness.js"));
  write(T, "a.txt", "a\n");
  git(T, ["add", "-A"]);
  for (const [cli] of GATES) git(T, ["update-index", "--chmod=+x", cli]);
  git(T, ["commit", "-q", "-m", "template"]);

  // agents(name) — a copy of the template: an agents repo whose hooks/ is armed for itself.
  const agents = (name) => {
    const dir = tmp(name);
    fs.cpSync(T, dir, { recursive: true });
    git(dir, ["config", "core.hooksPath", fwd(path.join(dir, "hooks"))]);
    return dir;
  };
  // foreign(name, hookRepo, { seed }) — a repo with no agents content routed to hookRepo's hooks/.
  const foreign = (name, hookRepo, { seed = true } = {}) => {
    const dir = tmp(name);
    initRepo(dir);
    if (seed) {
      write(dir, "seed.txt", "seed\n");
      git(dir, ["add", "seed.txt"]);
      git(dir, ["commit", "-q", "-m", "seed"]);
    }
    git(dir, ["config", "core.hooksPath", fwd(path.join(hookRepo, "hooks"))]);
    return dir;
  };
  const stage = (dir, rels, { force = false, exec } = {}) => {
    git(dir, ["add", ...(force ? ["-f"] : []), "--", ...rels]);
    if (exec !== undefined) git(dir, ["update-index", `--chmod=${exec ? "+" : "-"}x`, ...rels]);
  };
  const headCount = (dir) => {
    const r = git(dir, ["rev-list", "--count", "HEAD"], { allowFail: true });
    return r.status === 0 ? Number(r.stdout.trim()) : 0;
  };
  // commit(dir, { hookRepo, env, args, timeout }) — a real `git commit`; returns status, stdout,
  // stderr (hook output lands there: git redirects a hook's stdout), markers and calls.
  const commit = (dir, { hookRepo = dir, env = {}, args = [], timeout = 90000 } = {}) => {
    const calls = path.join(tmp("calls"), "calls.txt");
    const full = scrubbedEnv({ ENFORCE_WORKTREE: "off", AGENTS_MAIN_ROOT: fwd(hookRepo), F2507_CALLS: calls,
      CLAUDE_TRANSCRIPT_BASE_DIR: tmp("transcripts"), ...env });
    for (const [k, v] of Object.entries(env)) if (v === undefined) delete full[k];
    const done = spawnSync("git", ["commit", "-q", "-m", "f2507", ...args], {
      cwd: dir, env: full, encoding: "utf8", timeout, windowsHide: true, stdio: ["ignore", "pipe", "pipe"],
    });
    const stderr = done.stderr || "";
    const markers = stderr.split(/\r?\n/).filter((l) => l.startsWith("pre-commit-section: ")).map((l) => l.slice(20));
    const callList = fs.existsSync(calls) ? fs.readFileSync(calls, "utf8").split(/\r?\n/).filter(Boolean) : [];
    return { status: done.status, signal: done.signal, error: done.error, stdout: done.stdout || "", stderr, markers, calls: callList };
  };
  return { T, tmp, git, write, initRepo, agents, foreign, stage, headCount, commit };
}

// scrubbedEnv(extra) — process.env without the git plumbing and the developer's policy knobs.
function scrubbedEnv(extra = {}) {
  const env = { ...process.env };
  for (const k of SCRUB) delete env[k];
  return { ...env, ...extra };
}

const show = (r) => `status=${r.status} signal=${r.signal} markers=${r.markers.join(",")}\n${r.stderr.slice(-1500)}`;

module.exports = { makeTemplate, SECTIONS, GATES, GATE_MARKERS, AGENTS_SEQUENCE, HARD_TERM, WARN_TERM, show, fwd };
