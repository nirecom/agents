// hooks/enforce-worktree/effective-target/resolve.js
// #3147: ask git where each redirected write really lands and rank it against the session
// anchors: unresolvable > main-checkout > linked > outside-session. A segment takes the
// stricter of its git-dir axis and its work-tree axis; the command takes its strictest segment.

"use strict";

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("../../lib/limited-child-process");
const { normalizeForCompare } = require("../git-repo-detection");
const { collectInputs } = require("./inputs");
const { canonDir, naturalIdentity, naturalAnchors } = require("./natural-git");

const RANK = { "outside-session": 0, linked: 1, "main-checkout": 2, unresolvable: 3 };

function probe(s) {
  const args = [];
  if (s.gitDir !== null) args.push(`--git-dir=${s.gitDir}`);
  if (s.workTree !== null) args.push(`--work-tree=${s.workTree}`);
  if (s.coreWorktree !== null) args.push("-c", `core.worktree=${s.coreWorktree}`);
  args.push("rev-parse", "--git-dir", "--git-common-dir", "--show-toplevel");
  const env = { ...process.env, ...s.envOverride };
  delete env.GIT_COMMON_DIR;
  delete env.GIT_CONFIG_PARAMETERS;
  try {
    const r = spawnSync("git", args, { cwd: s.origin, env, encoding: "utf8", timeout: 2000 });
    if (r.error || r.status !== 0) return null;
    const lines = (r.stdout || "").trim().split(/\r?\n/);
    if (lines.length < 3 || lines.some((l) => !l)) return null;
    const gitDir = canonDir(path.resolve(s.origin, lines[0]));
    const commonDir = canonDir(path.resolve(s.origin, lines[1]));
    const toplevel = normalizeForCompare(path.resolve(s.origin, lines[2]));
    return { gitDir, commonDir, toplevel };
  } catch {
    return null;
  }
}

const unresolvable = (reason) => ({ kind: "unresolvable", reason });

function mainCheckoutOf(commonDir) {
  return path.basename(commonDir) === ".git" ? path.dirname(commonDir) : commonDir;
}

function gitDirAxis(p, anchors) {
  if (!anchors.commonDirs.has(p.commonDir)) return { kind: "outside-session", roots: [] };
  if (p.gitDir === p.commonDir) return { kind: "main-checkout", mainCheckout: mainCheckoutOf(p.commonDir) };
  let back;
  try { back = fs.readFileSync(path.join(p.gitDir, "gitdir"), "utf8").trim(); } catch { back = ""; }
  if (!back) return unresolvable(`the linked git dir ${p.gitDir} names no work tree`);
  return { kind: "linked", roots: [normalizeForCompare(path.dirname(path.resolve(p.gitDir, back)))] };
}

function overlaps(dir, worktreePaths) {
  const under = (a, b) => a === b || a.startsWith(b.endsWith(path.sep) ? b : b + path.sep);
  return worktreePaths.some((w) => under(dir, w) || under(w, dir));
}

function workTreeAxis(p, anchors) {
  const id = naturalIdentity(p.toplevel);
  if (id && anchors.commonDirs.has(id.commonDir)) {
    return id.isMain ? { kind: "main-checkout", mainCheckout: p.toplevel } : { kind: "linked", roots: [id.root] };
  }
  if (overlaps(p.toplevel, anchors.worktreePaths)) return unresolvable(`the work tree ${p.toplevel} overlaps a session checkout`);
  return { kind: "outside-session", roots: [p.toplevel] };
}

function segmentVerdict(s, anchors) {
  if (s.unresolvable) return unresolvable(s.unresolvable);
  const p = probe(s);
  if (!p) return unresolvable("git cannot resolve the work tree (missing path, bare repo, or not a repository)");
  const a = gitDirAxis(p, anchors);
  let b = workTreeAxis(p, anchors);
  // git honors core.worktree only on some setup paths (a discovered linked worktree ignores
  // it), so the named directory is judged as a work tree too.
  if (s.coreWorktree !== null) {
    const c = workTreeAxis({ toplevel: normalizeForCompare(path.resolve(p.gitDir, s.coreWorktree)) }, anchors);
    if (RANK[c.kind] > RANK[b.kind]) b = c;
  }
  if (a.kind === "linked" && b.kind === "linked") return { kind: "linked", roots: [...new Set([...a.roots, ...b.roots])] };
  const v = RANK[a.kind] > RANK[b.kind] ? a : b;
  return v.kind === "main-checkout" ? { ...v, root: p.toplevel, gitDir: p.gitDir, commonDir: p.commonDir } : v;
}

// → { kind: "none" } | { kind, reason?, root?, mainCheckout?, gitDir?, commonDir?, roots?, inherited, cwdRoot, coversAllWrites }
function resolveEffectiveTarget(ir, toolCwd, env = process.env) {
  const inputs = collectInputs(ir, toolCwd, env);
  if (!inputs.anyOverride) return { kind: "none" };
  const anchors = naturalAnchors(toolCwd);
  const base = { cwdRoot: anchors ? anchors.cwdId.root : null, coversAllWrites: inputs.coversAllWrites };
  if (!anchors) return { ...base, kind: "unresolvable", reason: "cwd is not a git repository", inherited: false };
  const verdicts = inputs.segments.map((s) => ({ s, v: segmentVerdict(s, anchors) }));
  const top = Math.max(...verdicts.map(({ v }) => RANK[v.kind]));
  const tied = verdicts.filter(({ v }) => RANK[v.kind] === top);
  const worst = tied[0].v;
  const roots = worst.roots ? [...new Set(tied.flatMap(({ v }) => v.roots))] : undefined;
  return { ...base, ...worst, roots, inherited: tied.some(({ s }) => Boolean(s.inherited)) };
}

module.exports = { resolveEffectiveTarget };
