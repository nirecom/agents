"use strict";
// collect(root) — aggregates the /migrate-* needs.js judgments in tracker, issues, tests order, plus the
// tracker board's forge judge (trackerFields). Process budget: one `git status` on every path; with the upstream
// origin/<branch>, `git rev-list origin/<branch>..HEAD` only when ahead; otherwise (the push runs
// without -u, so no-upstream is common) `git rev-parse` of origin/<branch>, then that rev-list; when
// the ref is absent or HEAD is detached, `git remote get-url origin` and, when origin exists,
// `git rev-list HEAD --not --remotes=origin`. The origin lookup is shared with the host lookup.
// UNCOMMITTED / UNPUSHED are the git state of .agents.json, kept apart from the content judgment
// (CPR-SC): a worktree made later sees only the committed file, and a peer only the pushed one.
// MALFORMED (1: .agents.json is unparsable, not an object, or fails the reader's validation in version
// or the tests / migrate section; a newer version (unsupported) is 0) is a plain fs read, no process.

const cp = require("child_process");
const path = require("path");
const { nativePath, readDoc, isMalformedDoc } = require(path.join(__dirname, "..", "..", "hooks", "lib", "repo-settings"));
const { migrateForgeType } = require(path.join(__dirname, "migrate-forge-type"));

const SKILLS_DIR = path.join(__dirname, "..", "..", "skills");
const ORDER = ["tracker", "issues", "tests"];
const HOST_KEYS = new Set(["tracker", "issues"]);

const judges = ORDER.map((k) => require(path.join(SKILLS_DIR, `migrate-${k}`, "scripts", "needs.js")));

function git(root, args) {
  const r = cp.spawnSync("git", ["-C", root, ...args], { encoding: "utf8", windowsHide: true });
  if (r.error) throw r.error;
  return r;
}

// hostOf(url, root) — the migrate forge type of an origin URL, with root's .env.local in view.
function hostOf(url, root) {
  return migrateForgeType(String(url || "").trim(), root).type;
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
  const tracker = trackerFields(root, needed, originOf);
  if (tracker.needed) needed.unshift("tracker"); // tracker is first in ORDER
  let host = "";
  if (needed.some((k) => HOST_KEYS.has(k))) {
    const r = originOf();
    host = r.status === 0 ? hostOf(r.stdout, root) : "unknown";
  }
  return { needed, uncommitted, unpushed, host, malformed: malformedOf(root), diagnostics: tracker.diagnostics };
}

// trackerFields(root, needed, originOf) -> {needed, diagnostics}: the tracker board's forge judge (#3135) for a
// tracker-done GitHub repo, kept apart from the needs.js judgments (which never call the forge). It runs only
// when this machine has an active PM (the pm field matters to PM sessions alone), so a repo without PM use
// pays no forge call. A forge failure is an undecidable diagnostic, never NEEDED (an offline /migrate ends).
function trackerFields(root, needed, originOf) {
  const none = { needed: false, diagnostics: [] };
  if (needed.includes("tracker")) return none;
  const scan = require(path.join(__dirname, "..", "..", "hooks", "pm-session", "scan"));
  if (scan.listActivePms(scan.listPmFiles()).length === 0) return none;
  const r = originOf();
  if (r.status !== 0 || hostOf(r.stdout, root) !== "github") return none;
  const { parseOriginOwnerRepo } = require(path.join(__dirname, "..", "..", "hooks", "lib", "parse-remote-url"));
  const repo = parseOriginOwnerRepo(String(r.stdout).trim());
  if (!repo || !repo.ok) return none;
  try {
    const j = require(path.join(__dirname, "tracker-fields", "judge")).judgeRepo(repo.ownerRepo);
    return { needed: j.needed, diagnostics: j.diagnostics };
  } catch (e) {
    return { needed: false, diagnostics: [{ kind: "undecidable", message: `the tracker field judge failed (${e.message})` }] };
  }
}

function malformedOf(root) {
  try {
    return isMalformedDoc(readDoc(root)) ? 1 : 0;
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
