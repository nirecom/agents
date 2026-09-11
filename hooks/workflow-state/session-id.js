"use strict";

const fs = require("fs");
const path = require("path");
// Direct submodule require (not the ./state-io barrel) to avoid a circular
// dependency: state-io's barrel pulls in modules that require session-id.js.
const { SESSION_ID_VALID_RE } = require("./state-io/core");

/**
 * The one enumeration of a transcript directory, reporting what could NOT be observed
 * instead of swallowing it. Returns { files, errors }: readable `.jsonl` REGULAR-FILE
 * entries as { name, mtime } (mtime descending), and [{ scope: "dir"|"file", path, code }]
 * — a failed readdir yields one `dir` error and no files, a failed lstatSync drops only
 * that file. lstat + regular-file-only, so a `.jsonl` symlink cannot pull a transcript in
 * from outside the directory (CPR-ORTH with the prune walker and bin/measure-norm-docs);
 * a skipped entry is not an error. _listJsonlByMtime below is the swallowing view.
 */
function listJsonlByMtimeStrict(transcriptDir) {
  const files = [];
  const errors = [];
  let names;
  try {
    names = fs.readdirSync(transcriptDir);
  } catch (e) {
    errors.push({ scope: "dir", path: transcriptDir, code: e.code || "EIO" });
    return { files, errors };
  }
  for (const name of names) {
    if (!name.endsWith(".jsonl")) continue;
    const full = path.join(transcriptDir, name);
    try {
      const st = fs.lstatSync(full);
      if (!st.isFile()) continue;
      files.push({ name, mtime: st.mtimeMs });
    } catch (e) {
      errors.push({ scope: "file", path: full, code: e.code || "EIO" });
    }
  }
  files.sort((a, b) => b.mtime - a.mtime);
  return { files, errors };
}

// Legacy view, preserved bit-for-bit: the original single try/catch returned [] whether
// the readdir or any individual statSync failed, so any observed error still yields [].
// Changing this to return partial results would change session resolution in state-io.js.
function _listJsonlByMtime(transcriptDir) {
  const r = listJsonlByMtimeStrict(transcriptDir);
  return r.errors.length > 0 ? [] : r.files;
}

/**
 * Resolve the current session ID from SUPPLIED sources only, by priority:
 *   1. ctx.sessionIdFromInput   2. CLAUDE_CODE_SESSION_ID (CC-native; the only one
 *      reliably present in the Bash-tool subprocess — #1082, Anthropic bug #27987)
 *   3. CLAUDE_SESSION_ID   4. ctx.transcriptPath basename
 * No source infers an id from filesystem traces — see
 * docs/architecture/claude-code/session-id-resolution.md for why the former
 * inferred tier (CLAUDE_ENV_FILE / WORKTREE_NOTES.md / JSONL mtime scan) was
 * removed.
 */
function resolveSessionId(ctx = {}) {
  if (
    typeof ctx.sessionIdFromInput === "string" &&
    SESSION_ID_VALID_RE.test(ctx.sessionIdFromInput)
  ) {
    return ctx.sessionIdFromInput;
  }
  // CC-native session id, set directly in tool and hook subprocesses. Reliably
  // present where the manufactured CLAUDE_SESSION_ID relay (read below) is not —
  // the Bash-tool path. Without this, resolution falls through to priority 3,
  // which is a manufactured relay rather than the CC-native value (#1082).
  const codeSid = process.env.CLAUDE_CODE_SESSION_ID;
  if (codeSid && SESSION_ID_VALID_RE.test(codeSid.trim())) return codeSid.trim();
  const envSid = process.env.CLAUDE_SESSION_ID;
  if (envSid && SESSION_ID_VALID_RE.test(envSid.trim())) return envSid.trim();
  if (typeof ctx.transcriptPath === "string" && ctx.transcriptPath.length > 0) {
    const base = path.basename(ctx.transcriptPath, ".jsonl");
    if (SESSION_ID_VALID_RE.test(base)) return base;
  }
  return null;
}

module.exports = {
  _listJsonlByMtime,
  listJsonlByMtimeStrict,
  resolveSessionId,
};
