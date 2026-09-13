"use strict";
// hooks/lib/pretool-lang-gate.js — shared plumbing for the PreToolUse language
// gates (gate-plan-lang.js, gate-worktree-notes-lang.js) and the PostToolUse
// checkers that share their tool set (#2278).
// Per-edit fragments are the unit of analysis: a MultiEdit element may target a
// different file than the top-level path, so every fragment carries its own path.
// Pure helpers never throw on malformed input — callers rely on that for fail-open.

const fs = require("fs");
const path = require("path");
const { normalizeCwd } = require("./path-normalize");

const TARGET_TOOLS = new Set(["Write", "Edit", "MultiEdit", "editFiles"]);

function readStdinJson() {
  const chunks = [];
  const buf = Buffer.alloc(65536);
  for (;;) {
    let n = 0;
    try {
      n = fs.readSync(0, buf, 0, buf.length, null);
    } catch (e) {
      if (e && e.code === "EAGAIN") continue;
      if (e && e.code === "EOF") break;
      throw e;
    }
    if (n === 0) break;
    chunks.push(Buffer.from(buf.subarray(0, n)));
  }
  const raw = Buffer.concat(chunks).toString("utf8");
  try {
    return JSON.parse(raw);
  } catch (e) {
    return null;
  }
}

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

// Canonical form for path EQUALITY: two spellings of the same file (relative vs
// absolute, `/c/...` vs `C:\...`, `./` segments) must collapse, or a MultiEdit
// element hiding under an alias spelling escapes grouping and never gets linted.
// No case folding — the repo has no case-insensitive path convention to follow.
// Applied at comparison sites only: collectEditTargets keeps t.filePath verbatim,
// which its own consumers (and their tests) rely on.
function normalizePath(p) {
  if (typeof p !== "string" || p.length === 0) return p;
  const win = normalizeCwd(p) || p;
  try {
    return path.resolve(win);
  } catch (e) {
    return win;
  }
}

function collectEditTargets(toolName, toolInput) {
  if (!TARGET_TOOLS.has(toolName) || !isObject(toolInput)) return [];
  const out = [];
  if (Array.isArray(toolInput.edits)) {
    const topPath = pathOf(toolInput);
    toolInput.edits.forEach((e, i) => {
      const filePath = pathOf(e) || topPath;
      const fragment = isObject(e) && typeof e.new_string === "string" ? e.new_string : null;
      if (filePath && fragment !== null) out.push({ filePath, fragment, editIndex: i });
    });
    return out;
  }
  const filePath = pathOf(toolInput);
  if (!filePath) return [];
  let fragment = null;
  if (typeof toolInput.content === "string") fragment = toolInput.content;
  else if (toolName !== "Write" && typeof toolInput.new_string === "string") fragment = toolInput.new_string;
  if (fragment === null) return [];
  return [{ filePath, fragment, editIndex: null }];
}

function targetPathsOf(targets) {
  if (!Array.isArray(targets)) return [];
  return [...new Set(targets.map((t) => (isObject(t) ? t.filePath : null)).filter((p) => typeof p === "string"))];
}

function approve() {
  process.stdout.write(JSON.stringify({ decision: "approve" }) + "\n");
  process.exit(0);
}

function block(reason) {
  process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
  process.exit(0);
}

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

module.exports = { TARGET_TOOLS, readStdinJson, pathOf, normalizePath, collectEditTargets, targetPathsOf, approve, block, applyEdits };
