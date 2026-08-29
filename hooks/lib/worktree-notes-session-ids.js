"use strict";
// hooks/lib/worktree-notes-session-ids.js
// SSOT for the agent-writable `Session-ID:` line in WORKTREE_NOTES.md: the parser and
// the own-worktree matcher both resolvers used to duplicate byte-for-byte, plus the
// OBSERVATION-side enumeration #2108 needs.
// RESOLUTION vs OBSERVATION (CPR-SC): the resolvers answer "who am I" — first hit wins,
// two distinct sibling ids are ambiguous -> null. The enumeration answers "who could a
// reader think this is", so it collects EVERY candidate: no first-hit stop, no
// ambiguity fail-safe.
// Dependency discipline: fs/path/child_process only — requiring a resolver back would
// cycle and let require order decide what gets observed.

const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

const NOTES_BASENAME = "WORKTREE_NOTES.md";

// The value is agent-written, so this charset gate is a security boundary: a value
// carrying a path separator, a dot or whitespace must die here rather than reach a
// path join or a clearance comparison.
const NOTES_SID_VALID_RE = /^[A-Za-z0-9_-]+$/;

// readSessionIdFromWorktreeNotes(notesPath) -> the value, or null when the line is
// absent, fails the charset gate, or the file cannot be read. Best-effort by
// contract: absence is an ANSWER, never a throw.
function readSessionIdFromWorktreeNotes(notesPath) {
  try {
    const content = fs.readFileSync(notesPath, "utf8");
    const m = content.match(/^Session-ID:\s*(\S+)\s*$/m);
    if (m && NOTES_SID_VALID_RE.test(m[1])) return m[1];
  } catch (_) {
    // ignore
  }
  return null;
}

/**
 * Identify the "own" worktree root among `dirs`: the entry whose path is `cwd`
 * itself or a proper ancestor of `cwd`. Uses path.resolve()-normalized prefix
 * matching with a path-separator boundary (so `C:/git/wt1` does not match
 * `C:/git/wt1-other`); on win32 the comparison is case-insensitive.
 * When multiple ancestors qualify (nested worktrees), the deepest wins.
 * Returns the ORIGINAL (unnormalized) dir string, or null when none matches.
 */
function findOwnWorktreeDir(dirs, cwd) {
  const norm = (p) => (process.platform === "win32" ? p.toLowerCase() : p);
  const cwdNorm = norm(path.resolve(cwd));
  let own = null;
  let ownLen = -1;
  for (const dir of dirs) {
    if (!dir) continue;
    const dirNorm = norm(path.resolve(dir));
    const isMatch =
      cwdNorm === dirNorm ||
      (cwdNorm.startsWith(dirNorm) &&
        (dirNorm.endsWith("/") ||
          dirNorm.endsWith(path.sep) ||
          cwdNorm[dirNorm.length] === "/" ||
          cwdNorm[dirNorm.length] === path.sep));
    if (isMatch && dirNorm.length > ownLen) {
      own = dir;
      ownLen = dirNorm.length;
    }
  }
  return own;
}

// parseWorktreeDirs(porcelain) -> the worktree root paths. Some git versions emit the
// last entry with no trailing blank line (R6), so it is flushed explicitly.
function parseWorktreeDirs(porcelain) {
  const dirs = [];
  let current = null;
  for (const line of String(porcelain).split("\n")) {
    if (line.startsWith("worktree ")) {
      current = line.slice("worktree ".length).trim();
    } else if (line === "" && current !== null) {
      if (current) dirs.push(current);
      current = null;
    }
  }
  if (current) dirs.push(current);
  return dirs;
}

// git reached through execSync, exactly as both resolvers reach it. A throw here is an
// ANSWER ("no git view of this directory"), NOT an observation fault: execSync runs git
// through a shell, so a missing binary and a non-repo CWD are indistinguishable
// (`e.code` is undefined for both). Calling either a fault would make complete:false
// the norm at every non-repo CWD and fail-close every artifact name — reinstating the
// #2108 false positive this module exists to remove.
function gitOut(command) {
  try {
    return execSync(command, {
      encoding: "utf8",
      timeout: 2000,
      stdio: ["pipe", "pipe", "pipe"],
    });
  } catch (_) {
    return null;
  }
}

/**
 * enumerateWorktreeNotesSessionIds(): { sids: string[], complete: boolean } — every
 * notes-derived id a clearance reader could resolve to from here: the CWD's notes
 * (resolver priority 6), the git-common-dir parent's (6b), and every worktree git
 * lists, own and sibling alike (6c).
 * `complete` is false only when the enumeration itself faulted (e.g. process.cwd() is
 * gone) — never for a git invocation that merely had nothing to say.
 */
function enumerateWorktreeNotesSessionIds() {
  const sids = new Set();
  let complete = true;
  const add = (sid) => {
    if (typeof sid === "string" && NOTES_SID_VALID_RE.test(sid)) sids.add(sid);
  };

  try {
    add(readSessionIdFromWorktreeNotes(path.join(process.cwd(), NOTES_BASENAME)));

    const commonDir = gitOut("git rev-parse --git-common-dir");
    if (commonDir && commonDir.trim()) {
      add(
        readSessionIdFromWorktreeNotes(
          path.join(path.resolve(commonDir.trim()), "..", NOTES_BASENAME)
        )
      );
    }

    const wtOut = gitOut("git worktree list --porcelain");
    if (wtOut !== null) {
      for (const dir of parseWorktreeDirs(wtOut)) {
        add(readSessionIdFromWorktreeNotes(path.join(dir, NOTES_BASENAME)));
      }
    }
  } catch (_) {
    complete = false;
  }

  return { sids: Array.from(sids), complete };
}

module.exports = {
  NOTES_BASENAME,
  NOTES_SID_VALID_RE,
  readSessionIdFromWorktreeNotes,
  findOwnWorktreeDir,
  parseWorktreeDirs,
  enumerateWorktreeNotesSessionIds,
};
