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
 *   1. ctx.sessionIdFromInput   2. CLAUDE_CODE_SESSION_ID (CC-native)
 *   3. ctx.transcriptPath basename
 * The former relay tier and inferred tiers are both retired — see
 * docs/architecture/claude-code/session-id-resolution.md.
 */
function resolveSessionId(ctx = {}) {
  if (
    typeof ctx.sessionIdFromInput === "string" &&
    SESSION_ID_VALID_RE.test(ctx.sessionIdFromInput)
  ) {
    return ctx.sessionIdFromInput;
  }
  // CC-native session id, set directly in hook and tool subprocesses by the CC binary.
  const codeSid = process.env.CLAUDE_CODE_SESSION_ID;
  if (codeSid && SESSION_ID_VALID_RE.test(codeSid.trim())) return codeSid.trim();
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
