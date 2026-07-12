"use strict";

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const { normalizeCwd } = require("../lib/path-normalize");
const { parseCdCommand, parseCdCommandInInterpreter, extractGitScopeFlagsFromArgv } = require("../lib/parse-git-args");
const { parse } = require("../lib/command-ir");
const { resolveGitArgvForSegment, isGitWriteArgv } = require("../lib/bash-write-patterns/git-write-ir");

// Normalize a path to Windows form when possible. Handles Git Bash style
// `/c/path` → `C:\path` and `c:/path` → `c:\path` on win32.
function toWindowsPath(raw) {
  if (!raw) return raw;
  const driveMatch = raw.match(/^\/([a-zA-Z])(\/.*)?$/);
  if (driveMatch) {
    return driveMatch[1].toUpperCase() + ":\\" +
      (driveMatch[2] || "").replace(/\//g, "\\").replace(/^\\/, "");
  }
  if (process.platform === "win32" && /^[a-zA-Z]:\//.test(raw)) return raw.replace(/\//g, "\\");
  return raw;
}

// Trivalue (#885 Axis A):
//   true  → main worktree (--git-common-dir === --git-dir)
//   false → linked worktree (paths differ) OR spawnSync threw (fail-safe to
//           linked-worktree behavior — existing caller semantics)
//   null  → indeterminate: git rev-parse ran but returned non-zero
//           (non-git CWD, broken repo, etc.). Callers should treat null as
//           "checked but unresolved" — by convention block-side under
//           enforce-worktree (see #885 plan).
function isMainCheckout(repoCwd) {
  try {
    const common = spawnSync("git", ["rev-parse", "--git-common-dir"], {
      cwd: repoCwd, encoding: "utf8", timeout: 2000,
    });
    const gitDir = spawnSync("git", ["rev-parse", "--git-dir"], {
      cwd: repoCwd, encoding: "utf8", timeout: 2000,
    });
    // Axis A (#885) trivalue:
    //   spawnSync error (e.g. ENOENT on cwd) → false (fail-safe, existing behavior)
    //   git rev-parse non-zero status → null (indeterminate: non-git CWD,
    //                                          broken repo, etc.)
    //   both succeed and paths match → true; mismatch → false
    if (common.error || gitDir.error) return false;
    if (common.status !== 0 || gitDir.status !== 0) return null;
    const c = path.resolve(repoCwd, (common.stdout || "").trim());
    const g = path.resolve(repoCwd, (gitDir.stdout || "").trim());
    return c.toLowerCase() === g.toLowerCase();
  } catch (e) {
    return false;
  }
}

// Parse git -C <path> from a command string (best-effort, not a full shell parser).
// Handles: git -C /path, git -C "/path with spaces", git -C 'path', git --work-tree=... -C path
function parseGitCPath(cmd) {
  const m = cmd.match(/\bgit\b(?:\s+-\S+)*\s+-C\s+(?:"([^"]+)"|'([^']+)'|(\S+))/);
  if (!m) return null;
  const raw = m[1] || m[2] || m[3];
  if (!raw) return null;
  return toWindowsPath(raw);
}

// Parse a git global path-flag value (best-effort, not a full shell parser).
// Supports both separated (`--work-tree <path>`) and attached (`--work-tree=<path>`)
// forms, quoted or bare. `flag` is the long option name without `=` (e.g.
// "--work-tree" / "--git-dir"). Returns the toWindowsPath-normalized value or null.
function parseGitPathFlag(cmd, flag) {
  const esc = flag.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  // attached: --flag=value | --flag="value" | --flag='value'
  const attached = cmd.match(new RegExp("\\bgit\\b[^|;&]*?\\s" + esc + "=(?:\"([^\"]+)\"|'([^']+)'|([^\\s|;&]+))"));
  if (attached) {
    const raw = attached[1] || attached[2] || attached[3];
    if (raw) return toWindowsPath(raw);
  }
  // separated: --flag value | --flag "value" | --flag 'value'
  const sep = cmd.match(new RegExp("\\bgit\\b[^|;&]*?\\s" + esc + "\\s+(?:\"([^\"]+)\"|'([^']+)'|(\\S+))"));
  if (sep) {
    const raw = sep[1] || sep[2] || sep[3];
    if (raw) return toWindowsPath(raw);
  }
  return null;
}

// Resolve a scope-flag value string to an ABSOLUTE working-tree root candidate, or
// return the AMBIGUOUS sentinel when the value is missing/relative/env-var/tilde
// (unresolvable in a WRITE detector without a shell). null means "flag not present".
const AMBIGUOUS_SCOPE = Symbol("ambiguous-scope");
function resolveScopeValue(raw) {
  if (raw == null) return null;
  if (typeof raw !== "string" || raw === "") return AMBIGUOUS_SCOPE;
  if (/\$/.test(raw)) return AMBIGUOUS_SCOPE;      // env-var reference (pre-expansion)
  if (raw.startsWith("~")) return AMBIGUOUS_SCOPE; // tilde (home) — unresolved here
  const win = toWindowsPath(raw);
  const isAbsolute = win.startsWith("/") || /^[a-zA-Z]:[\\/]/.test(win);
  if (!isAbsolute) return AMBIGUOUS_SCOPE;         // relative → cannot resolve safely
  return win;
}

// Segment-aware, quote-aware git write-scope resolution (FIX A, convergence).
// Sources -C / --work-tree / --git-dir from the GIT-WRITE SEGMENT'S OWN IR argv
// (already tokenized + quote-resolved + segment-local) instead of a raw-regex scan
// of the whole command. This closes two FAIL-OPEN mis-scope classes:
//   - cross-segment: `git --work-tree /outside status && git commit` no longer
//     attributes /outside to the later commit — the commit segment carries no
//     scope flag, so the write scopes to the CWD repo (in-session → block).
//   - quoted: `printf "git --work-tree /outside" && git commit` — the flag lives
//     inside a printf argument token, never in the git segment's global options.
//
// Returns one of:
//   { root: <absolute-path-or-null> }  — resolve rev-parse from this dir.
//   { failClosed: true }               — scope flags present but unresolvable /
//                                        relative / ambiguous: the caller must
//                                        treat the target as IN-SESSION (CWD repo),
//                                        never as an "outside" self-target.
//   null                               — no git-write segment / no scope flags;
//                                        caller falls back to cd/cwd behavior.
// Resolve one git segment's scope flags → { root } | { failClosed } | null.
// { failClosed } is only meaningful for WRITE segments (a write whose scope is
// ambiguous must block); for READ segments the caller ignores failClosed.
function scopeFromGitArgv(gitArgv) {
  const flags = extractGitScopeFlagsFromArgv(gitArgv);
  if (!flags.sawScopeFlag) return null;          // no scope redirection
  // Precedence for the working-tree root: --work-tree > -C > --git-dir(parent).
  if (flags.workTree != null) {
    const v = resolveScopeValue(flags.workTree);
    return v === AMBIGUOUS_SCOPE ? { failClosed: true } : { root: v };
  }
  if (flags.cIn != null) {
    const v = resolveScopeValue(flags.cIn);
    return v === AMBIGUOUS_SCOPE ? { failClosed: true } : { root: v };
  }
  if (flags.gitDir != null) {
    const v = resolveScopeValue(flags.gitDir);
    if (v === AMBIGUOUS_SCOPE) return { failClosed: true };
    // .git dir → containing directory is the working-tree root (best-effort).
    const stripped = v.replace(/[\\/]\.git[\\/]?$/i, "");
    return { root: stripped || v };
  }
  return { failClosed: true };                   // sawScopeFlag but no value captured
}

function resolveGitWriteScopeFromSegments(cmd, toolCwd) {
  let ir;
  try { ir = parse(cmd); } catch (e) { return { failClosed: true }; }
  if (!ir || ir.parseFailure === true || !Array.isArray(ir.segments)) return null;

  // A WRITE segment's scope is authoritative. Only when NO write segment exists do
  // we honor a read git segment's -C / --work-tree (preserves the single-segment
  // `git -C <path> status` contract, #286). A read segment's scope can NEVER
  // override a later write segment — that is the cross-segment mis-scope class this
  // fix closes (`git --work-tree /outside status && git commit`).
  let readScope = null;
  for (const seg of ir.segments) {
    let gitArgv;
    try { gitArgv = resolveGitArgvForSegment(seg); } catch (e) { gitArgv = null; }
    if (gitArgv === null) continue;              // not a git segment
    if (isGitWriteArgv(gitArgv)) {
      const s = scopeFromGitArgv(gitArgv);
      return s === null ? null : s;              // write scope wins immediately
    }
    // git read segment — remember its scope as a fallback only.
    if (readScope === null) readScope = scopeFromGitArgv(gitArgv);
  }
  // No write segment. A read segment's fail-closed is not security-relevant (reads
  // are allowed upstream); surface only a concrete root, else fall to cwd.
  if (readScope && readScope.root) return { root: readScope.root };
  return null;
}

function findRepoRootForBash(cmd, toolCwd) {
  // FIX A: git write-scope is resolved from the WRITE SEGMENT'S OWN argv (see
  // resolveGitWriteScopeFromSegments). A scope flag in a different segment or
  // inside quoted text can no longer set the write target. FAIL-CLOSED: when a
  // git-write segment carries --work-tree / -C / --git-dir but the value is
  // unresolvable/relative/ambiguous, the write is scoped to the CWD repo
  // (in-session) rather than an "outside" self-target — a WRITE detector must
  // block, never allow, when unsure.
  const scope = resolveGitWriteScopeFromSegments(cmd, toolCwd);
  let cArg = null;
  let failClosed = false;
  if (scope) {
    if (scope.failClosed === true) failClosed = true;
    else cArg = scope.root; // absolute working-tree root from the write segment
  }
  // Payload-derived `cd <absolute-path> && ...` extraction (issue #321).
  // No CLAUDE_PROJECT_DIR fallback — Approach E rejects it (start-time-fixed,
  // does not follow Bash `cd`). Skipped under fail-closed (scope must be CWD repo).
  let cdArg = null;
  if (!cArg && !failClosed) {
    cdArg = parseCdCommandInInterpreter(cmd);
    if (!cdArg) cdArg = parseCdCommand(cmd);
  }
  // Prefer the Bash tool's explicit cwd (#286) over process.cwd() when neither a
  // git write-scope selector nor a leading cd names a start directory. Under
  // fail-closed, force the CWD repo (never the ambiguous redirected path).
  let startDir = failClosed
    ? (toolCwd || process.cwd())
    : (cArg || cdArg || toolCwd || process.cwd());
  if (typeof startDir === "string" && /^\/[a-zA-Z]\//.test(startDir)) {
    startDir = toWindowsPath(startDir);
  }
  try {
    const r = spawnSync("git", ["rev-parse", "--show-toplevel"], {
      cwd: startDir, encoding: "utf8", timeout: 2000,
    });
    if (r.status !== 0) return null;
    return (r.stdout || "").trim() || null;
  } catch (e) {
    return null;
  }
}

// Normalize a path for case-aware comparison.
// Windows: case-insensitive (FS is case-insensitive); POSIX: case-sensitive.
function normalizeForCompare(p) {
  try {
    const resolved = path.resolve(p);
    return process.platform === "win32" ? resolved.toLowerCase() : resolved;
  } catch (e) {
    return null;
  }
}

// Resolve a directory to its containing git repo root, with normalization for compare.
function resolveRepoRoot(startDir) {
  try {
    const r = spawnSync("git", ["rev-parse", "--show-toplevel"], {
      cwd: startDir, encoding: "utf8", timeout: 2000,
    });
    if (r.status !== 0) return null;
    const out = (r.stdout || "").trim();
    return out ? normalizeForCompare(out) : null;
  } catch (e) {
    return null;
  }
}

function findRepoRoot(filePath) {
  let dir;
  try {
    const normalized = normalizeCwd(filePath) || filePath;
    dir = path.dirname(path.resolve(normalized));
  } catch (e) {
    return null;
  }
  // Walk up to find an existing directory: a non-existent target path (e.g.
  // `rm "<repo>/path with spaces/file"` where the dir does not exist) must
  // still resolve to the enclosing repo. Without this walk, spawnSync's cwd
  // ENOENT yields null and the path is incorrectly treated as outside scope.
  try {
    let cur = dir;
    while (cur && !fs.existsSync(cur)) {
      const parent = path.dirname(cur);
      if (parent === cur) { cur = null; break; }
      cur = parent;
    }
    if (!cur) return null;
    dir = cur;
  } catch (e) {
    return null;
  }
  try {
    const r = spawnSync("git", ["rev-parse", "--show-toplevel"], {
      cwd: dir, encoding: "utf8", timeout: 2000,
    });
    if (r.status !== 0) return null;
    return (r.stdout || "").trim() || null;
  } catch (e) {
    return null;
  }
}

module.exports = {
  isMainCheckout,
  parseGitCPath,
  parseGitPathFlag,
  findRepoRootForBash,
  normalizeForCompare,
  resolveRepoRoot,
  findRepoRoot,
};
