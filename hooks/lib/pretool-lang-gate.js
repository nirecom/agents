"use strict";
// hooks/lib/pretool-lang-gate.js — shared plumbing for the PreToolUse language
// gates (gate-plan-lang.js, gate-worktree-notes-lang.js) and the PostToolUse
// checkers that share their tool set (#2278).
// Per-edit fragments are the unit of analysis: a MultiEdit element may target a
// different file than the top-level path, so every fragment carries its own path.
// Pure helpers never throw on malformed input — callers rely on that for fail-open.

const { readStdinText } = require("./read-stdin");
// Re-exported from the shared post-edit module (#2388, CPR-SSOT).
const { pathOf, normalizePath, applyEdits } = require("./post-edit-content");

const TARGET_TOOLS = new Set(["Write", "Edit", "MultiEdit", "editFiles"]);

function readStdinJson() {
  const r = readStdinText();
  if (r.kind === "read-error") throw r.error;
  try {
    return JSON.parse(r.text);
  } catch (e) {
    return null;
  }
}

function isObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

// normalizePath is applied at comparison sites only: collectEditTargets keeps
// t.filePath verbatim, which its own consumers (and their tests) rely on.
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

module.exports = { TARGET_TOOLS, readStdinJson, pathOf, normalizePath, collectEditTargets, targetPathsOf, approve, block, applyEdits };
