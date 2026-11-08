"use strict";
// collect(root) — aggregates the /migrate-* needs.js judgments in tracker, issues, tests order.
// Holds no judgment of its own. Process budget: one `git status` on every path; with the upstream
// origin/<branch>, `git rev-list origin/<branch>..HEAD` only when ahead; otherwise (the push runs
// without -u, so no-upstream is common) `git rev-parse` of origin/<branch>, then that rev-list; when
// the ref is absent or HEAD is detached, `git remote get-url origin` and, when origin exists,
// `git rev-list HEAD --not --remotes=origin`. The origin lookup is shared with the host lookup.
// UNCOMMITTED / UNPUSHED are the git state of .agents.json, kept apart from the content judgment
// (CPR-SC): a worktree made later sees only the committed file, and a peer only the pushed one.
// MALFORMED (1: .agents.json exists but is not a JSON object) is a plain fs read, no process.

const cp = require("child_process");
const path = require("path");
const { nativePath, readDoc } = require(path.join(__dirname, "..", "..", "hooks", "lib", "repo-settings"));

const SKILLS_DIR = path.join(__dirname, "..", "..", "skills");
const ORDER = ["tracker", "issues", "tests"];
const HOST_KEYS = new Set(["tracker", "issues"]);

const judges = ORDER.map((k) => require(path.join(SKILLS_DIR, `migrate-${k}`, "scripts", "needs.js")));

function git(root, args) {
  const r = cp.spawnSync("git", ["-C", root, ...args], { encoding: "utf8", windowsHide: true });
  if (r.error) throw r.error;
  return r;
}

function hostOf(url) {
  const u = String(url || "").trim().toLowerCase();
  if (/(^|[@/.])gitlab\.[^:/]+[:/]/.test(u)) return "gitlab";
  if (/(^|[@/.])github\.com[:/]/.test(u)) return "github";
  return "unknown";
}

function collect(rootArg) {
  const root = nativePath(String(rootArg || process.cwd()));
  const needed = judges.filter((j) => j.needs(root)).map((j) => j.key);
  const st = git(root, ["status", "--porcelain=v2", "--branch", "--untracked-files=all", "--", ".agents.json"]);
  if (st.status !== 0) throw new Error(`git status failed in ${root}: ${String(st.stderr || "").trim()}`);
  const lines = String(st.stdout || "").split(/\r?\n/).filter(Boolean);
  const uncommitted = lines.some((l) => !l.startsWith("#")) ? 1 : 0;
  let origin = null;
  const originOf = () => origin || (origin = git(root, ["remote", "get-url", "origin"]));
  const unpushed = unpushedState(root, lines, originOf);
  let host = "";
  if (needed.some((k) => HOST_KEYS.has(k))) {
    const r = originOf();
    host = r.status === 0 ? hostOf(r.stdout) : "unknown";
  }
  return { needed, uncommitted, unpushed, host, malformed: malformedOf(root) };
}

function malformedOf(root) {
  try {
    const doc = readDoc(root);
    return doc !== null && typeof doc === "object" && !Array.isArray(doc) ? 0 : 1;
  } catch {
    return 1;
  }
}

function unpushedState(root, lines, originOf) {
  const field = (name) => {
    const prefix = `# branch.${name} `;
    const line = lines.find((l) => l.startsWith(prefix));
    return line ? line.slice(prefix.length) : null;
  };
  const head = field("head");
  const branch = head === "(detached)" ? null : head;
  const target = `refs/remotes/origin/${branch}`;
  const ab = field("ab");
  // A gone upstream prints branch.upstream without branch.ab, so it takes the slow path.
  if (branch && ab && field("upstream") === `origin/${branch}`) {
    return /^\+[1-9]/.test(ab) ? unpushedOf(root, [`${target}..HEAD`]) : 0;
  }
  if (branch && git(root, ["rev-parse", "--verify", "-q", target]).status === 0) {
    return unpushedOf(root, [`${target}..HEAD`]);
  }
  return originOf().status === 0 ? unpushedOf(root, ["HEAD", "--not", "--remotes=origin"]) : 0;
}

// unpushedOf — 1 when a commit in range touches .agents.json (a push that failed). The range
// mirrors unpushed_allowlist_commits in commit-migration-artifacts.sh.
function unpushedOf(root, range) {
  const r = git(root, ["rev-list", "--count", ...range, "--", ".agents.json"]);
  return r.status === 0 && Number(String(r.stdout).trim()) > 0 ? 1 : 0;
}

module.exports = { ORDER, collect, hostOf };
