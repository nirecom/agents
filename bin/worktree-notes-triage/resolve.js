"use strict";

// resolve.js — notes-path resolution for `worktree-notes-triage resolve`.
//
// Pure decision module: reads the filesystem, writes nothing, spawns nothing.
// Emits exactly one line of JSON on stdout:
//   { action: "promote", resolvedVia, notesPath }
//   { action: "skip", skipReason }
// Exit 0 for both outcomes. Exit 1 only for an unusable invocation (bad
// --caller), because "no notes to promote" is a normal session, not an error.

const fs = require("fs");
const path = require("path");

const { hasShellMetachar } = require("../../hooks/lib/worktree-notes.js");

// SSOT for the callsites allowed to drive the promotion protocol.
const CALLERS = ["worktree-end", "session-close", "issue-close-finalize"];

const NOTES_BASENAME = "WORKTREE_NOTES.md";
const BACKUP_DIR_NAME = ".worktree-backup";

// --session-id is interpolated into plans-dir file names.
const SESSION_ID_RE = /^[A-Za-z0-9._-]+$/;
// --pr-branch is interpolated into <main-root>/.worktree-backup/<branch>/.
const BRANCH_RE = /^[A-Za-z0-9][A-Za-z0-9._/-]*$/;
const ISSUE_RE = /^[1-9][0-9]*$/;

// A `..` segment in the RAW string, before any normalization collapses it.
function hasTraversal(raw) {
  return String(raw)
    .split(/[/\\]/)
    .includes("..");
}

function isSafeAnchor(raw) {
  if (typeof raw !== "string" || raw.length === 0) return false;
  if (raw.includes("\0") || /[\r\n]/.test(raw)) return false;
  return !hasTraversal(raw);
}

function isSafeSessionId(raw) {
  if (typeof raw !== "string" || raw.length === 0) return false;
  if (raw.includes("..")) return false;
  return SESSION_ID_RE.test(raw);
}

function isSafeBranch(raw) {
  if (typeof raw !== "string" || raw.length === 0) return false;
  if (raw.includes("..")) return false;
  if (raw.includes("//")) return false;
  return BRANCH_RE.test(raw);
}

function parseArgs(argv) {
  const opts = { fromSession: false };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    switch (a) {
      case "--caller": opts.caller = argv[++i]; break;
      case "--worktree": opts.worktree = argv[++i]; break;
      case "--session-id": opts.sessionId = argv[++i]; break;
      case "--issue": opts.issue = argv[++i]; break;
      case "--pr-branch": opts.prBranch = argv[++i]; break;
      case "--main-root": opts.mainRoot = argv[++i]; break;
      case "--plans-dir": opts.plansDir = argv[++i]; break;
      case "--from-session": opts.fromSession = true; break;
      default: break;
    }
  }
  return opts;
}

function resolvePlansDir(opts) {
  if (opts.plansDir && isSafeAnchor(opts.plansDir)) return path.resolve(opts.plansDir);
  const fromEnv = process.env.WORKFLOW_PLANS_DIR;
  if (fromEnv && isSafeAnchor(fromEnv)) return path.resolve(fromEnv);
  const home = process.env.HOME || process.env.USERPROFILE || process.cwd();
  return path.resolve(home, ".workflow-plans");
}

function isFile(p) {
  try {
    return fs.statSync(p).isFile();
  } catch (e) {
    return false;
  }
}

// A notes path candidate is accepted only when the file actually exists.
function notesIn(dir) {
  const p = path.resolve(dir, NOTES_BASENAME);
  return isFile(p) ? p : null;
}

// --- branch 1: --worktree -------------------------------------------------
function viaWorktree(opts) {
  if (!opts.worktree || !isSafeAnchor(opts.worktree)) return null;
  return notesIn(opts.worktree);
}

// --- branch 2: <plans>/<sid>-final-report-env.json -------------------------
function viaEnvJson(opts, plansDir) {
  if (!isSafeSessionId(opts.sessionId)) return null;
  const envFile = path.join(plansDir, `${opts.sessionId}-final-report-env.json`);
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(envFile, "utf8"));
  } catch (e) {
    return null;
  }
  const raw = parsed && parsed.NOTES_BACKUP_PATH;
  if (typeof raw !== "string" || raw.length === 0) return null;
  // NOTES_BACKUP_PATH comes from a JSON file written outside this process's
  // control — apply the same isSafeAnchor validation the other four branches
  // already apply to their untrusted path inputs (branches 1/3/4 via
  // isSafeAnchor/isSafeSessionId/isSafeBranch).
  if (!isSafeAnchor(raw)) return null;
  const candidate = path.basename(raw) === NOTES_BASENAME
    ? path.resolve(raw)
    : path.resolve(raw, NOTES_BASENAME);
  return isFile(candidate) ? candidate : null;
}

// --- branch 3: <plans>/<sid>-notes-backup/ --------------------------------
function viaNotesBackupDir(opts, plansDir) {
  if (!isSafeSessionId(opts.sessionId)) return null;
  return notesIn(path.join(plansDir, `${opts.sessionId}-notes-backup`));
}

// --- branch 4: <main-root>/.worktree-backup/<branch>/ ---------------------
function viaBackupBranchDir(opts) {
  if (!isSafeBranch(opts.prBranch)) return null;
  const root = opts.mainRoot === undefined ? process.cwd() : opts.mainRoot;
  if (!isSafeAnchor(root)) return null;
  return notesIn(path.join(path.resolve(root), BACKUP_DIR_NAME, opts.prBranch));
}

// --- branch 5: scan <plans>/*-intent.md for an exact #N reference ---------
// `#18` must not match inside `#118`, and `##19` is a malformed token rather
// than a reference to issue 19 — filing another session's findings under the
// wrong issue is worse than not promoting at all.
function referencesIssue(text, issue) {
  const re = /#(\d+)/g;
  let m = re.exec(text);
  while (m !== null) {
    const before = m.index > 0 ? text[m.index - 1] : "";
    const okBefore = before === "" || !/[#\w]/.test(before);
    if (okBefore && m[1] === issue) return true;
    m = re.exec(text);
  }
  return false;
}

function viaIntentScan(opts, plansDir) {
  if (!ISSUE_RE.test(String(opts.issue || ""))) return null;
  let names;
  try {
    names = fs.readdirSync(plansDir);
  } catch (e) {
    return null;
  }
  const matches = [];
  for (const name of names) {
    const m = /^(.+)-intent\.md$/.exec(name);
    if (m === null) continue;
    const full = path.join(plansDir, name);
    let text;
    let mtimeMs;
    try {
      text = fs.readFileSync(full, "utf8");
      mtimeMs = fs.statSync(full).mtimeMs;
    } catch (e) {
      continue;
    }
    if (!referencesIssue(text, String(opts.issue))) continue;
    matches.push({ sessionId: m[1], name, mtimeMs });
  }
  // Newest session first; equal mtimes tie-break on filename descending so a
  // re-run always lands on the same session.
  matches.sort((a, b) => (b.mtimeMs - a.mtimeMs) || (a.name < b.name ? 1 : a.name > b.name ? -1 : 0));
  for (const hit of matches) {
    const p = notesIn(path.join(plansDir, `${hit.sessionId}-notes-backup`));
    if (p !== null) return p;
  }
  return null;
}

function decide(opts) {
  // Ownership gate runs before the filesystem is consulted: under
  // --from-session the session-close callsite already promoted these notes.
  if (opts.caller === "issue-close-finalize" && opts.fromSession) {
    return { action: "skip", skipReason: "owned-by-session-close" };
  }

  const plansDir = resolvePlansDir(opts);
  const chain = [
    ["worktree", () => viaWorktree(opts)],
    ["env-json", () => viaEnvJson(opts, plansDir)],
    ["notes-backup-dir", () => viaNotesBackupDir(opts, plansDir)],
    ["backup-branch-dir", () => viaBackupBranchDir(opts)],
    ["intent-scan", () => viaIntentScan(opts, plansDir)],
  ];
  for (const [resolvedVia, probe] of chain) {
    const notesPath = probe();
    if (notesPath !== null && notesPath !== undefined) {
      // notesPath is later interpolated into a shell command by the caller
      // (skills/_shared/notes-promotion.md NP-5/NP-8) — screen it here once,
      // covering all five resolution branches, rather than at each callsite.
      if (hasShellMetachar(notesPath)) {
        return { action: "skip", skipReason: "notes-path-unsafe" };
      }
      return { action: "promote", resolvedVia, notesPath };
    }
  }
  return { action: "skip", skipReason: "notes-path-unresolved" };
}

function runResolve(argv) {
  const opts = parseArgs(argv);
  if (!CALLERS.includes(opts.caller)) {
    process.stderr.write(
      `worktree-notes-triage resolve: --caller must be one of ${CALLERS.join("|")}\n`,
    );
    return 1;
  }
  process.stdout.write(`${JSON.stringify(decide(opts))}\n`);
  return 0;
}

module.exports = { CALLERS, runResolve, decide, parseArgs, referencesIssue };
