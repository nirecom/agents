"use strict";
// hooks/lib/post-edit-content.js — the file content a Write/Edit/MultiEdit will
// leave on disk, rebuilt in memory for PreToolUse gates (#2388; formerly private
// copies in block-comment-block-size.js and pretool-lang-gate.js, CPR-SSOT).
// Nothing here writes: a PreToolUse hook that materialised the post file would
// have performed the very write it is about to refuse. null = "cannot rebuild",
// which every caller turns into approve (fail-open). Depends only on
// ./path-normalize so pretool-lang-gate.js can re-export without a require cycle.

const fs = require("fs");
const path = require("path");
const { normalizeCwd, resolveRepoCwd } = require("./path-normalize");

// Performance guard, compiled in: a settable cap is a settable way to review nothing.
const MAX_BYTES = 1000000;

function isObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

function pathOf(obj) {
  if (!isObject(obj)) return null;
  const keys = ["file_path", "path", "notebook_path"];
  for (const k of keys) {
    if (typeof obj[k] === "string" && obj[k].length > 0) return obj[k];
  }
  return null;
}

// Canonical form for path EQUALITY: relative vs absolute, `/c/...` vs `C:\...`
// and `./` segments must collapse, or a MultiEdit element under an alias
// spelling escapes grouping. No case folding (no such repo convention).
function normalizePath(p) {
  if (typeof p !== "string" || p.length === 0) return p;
  const win = normalizeCwd(p) || p;
  try {
    return path.resolve(win);
  } catch (e) {
    return win;
  }
}

// resolveTargetPath — absolute path Node can open. resolveRepoCwd() owns the cwd
// priority (input.cwd beats CLAUDE_PROJECT_DIR when they disagree); the hook's own
// cwd is never the base, since it is only coincidentally the repo.
function resolveTargetPath(input, rawPath) {
  if (typeof rawPath !== "string" || rawPath.length === 0) return null;
  const normalized = normalizeCwd(rawPath) || rawPath;
  if (path.isAbsolute(normalized)) return normalized;
  const base = resolveRepoCwd({ input });
  if (typeof base !== "string" || base.length === 0) return null;
  return path.resolve(base, normalized);
}

// readPre — "" for a file that does not exist yet (a new file), null when it
// is over the byte cap, not a regular file, or unreadable.
function readPre(absPath, opts) {
  const maxBytes = opts && Number.isFinite(opts.maxBytes) ? opts.maxBytes : MAX_BYTES;
  let st;
  try {
    st = fs.statSync(absPath);
  } catch (e) {
    return e && e.code === "ENOENT" ? "" : null;
  }
  try {
    if (!st.isFile() || st.size > maxBytes) return null;
    return fs.readFileSync(absPath, "utf8");
  } catch (e) {
    return null;
  }
}

// applyEdits — edits applied in sequence, each onto the previous result (a later
// old_string often exists only in an earlier step's output). The function-form
// replace keeps `$&`/`$1` in new_string literal. Empty or absent old_string → null.
function applyEdits(pre, edits) {
  if (typeof pre !== "string" || !Array.isArray(edits)) return null;
  let text = pre;
  for (const e of edits) {
    if (!isObject(e) || typeof e.old_string !== "string" || e.old_string.length === 0) return null;
    if (typeof e.new_string !== "string") return null;
    if (text.indexOf(e.old_string) === -1) return null;
    text = e.replace_all === true
      ? text.split(e.old_string).join(e.new_string)
      : text.replace(e.old_string, () => e.new_string);
  }
  return text;
}

// buildPostContent — post-edit content of absPath, assuming every MultiEdit
// element targets it (use groupEditTargets for per-edit paths).
function buildPostContent(toolName, toolInput, absPath, opts) {
  if (!isObject(toolInput)) return null;
  if (toolName === "Write") {
    return typeof toolInput.content === "string" ? toolInput.content : null;
  }
  let edits;
  if (toolName === "Edit") edits = [toolInput];
  else if (toolName === "MultiEdit") edits = toolInput.edits;
  else return null;
  if (!Array.isArray(edits) || edits.length === 0) return null;
  const pre = readPre(absPath, opts);
  if (pre === null) return null;
  return applyEdits(pre, edits);
}

// groupKey — relative spellings resolve against the hook input's cwd (as
// resolveTargetPath does), never the hook process cwd: otherwise `a.sh` and its
// absolute alias split into two groups and neither group sees the final state.
function groupKey(input, rawPath) {
  const abs = input ? resolveTargetPath(input, rawPath) : null;
  return normalizePath(abs || rawPath);
}

// groupEditTargets — one entry per distinct target file:
// {rawPath, kind: "Write"|"Edit", content|edits}. A MultiEdit element's own path
// wins over the top-level one (same rule as collectEditTargets); groups are keyed
// by groupKey and keep the original edit order.
function groupEditTargets(toolName, toolInput, input) {
  if (!isObject(toolInput)) return [];
  const topPath = pathOf(toolInput);
  if (toolName === "Write") {
    return topPath ? [{ rawPath: topPath, kind: "Write", content: toolInput.content }] : [];
  }
  if (toolName === "Edit") {
    return topPath ? [{ rawPath: topPath, kind: "Edit", edits: [toolInput] }] : [];
  }
  if (toolName !== "MultiEdit" || !Array.isArray(toolInput.edits)) return [];
  const groups = new Map();
  for (const e of toolInput.edits) {
    const rawPath = pathOf(e) || topPath;
    if (!rawPath) continue;
    const key = groupKey(input, rawPath);
    if (!groups.has(key)) groups.set(key, { rawPath, kind: "Edit", edits: [] });
    groups.get(key).edits.push(e);
  }
  return [...groups.values()];
}

module.exports = {
  MAX_BYTES,
  pathOf,
  normalizePath,
  resolveTargetPath,
  readPre,
  applyEdits,
  buildPostContent,
  groupEditTargets,
};
