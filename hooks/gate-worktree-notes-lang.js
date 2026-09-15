#!/usr/bin/env node
"use strict";
// hooks/gate-worktree-notes-lang.js — PreToolUse gate: rejects a WORKTREE_NOTES.md
// write whose ## History Notes / ## Changelog Notes bullets violate DOCS_LANG_*
// before the file changes (#2278). A fragment that carries a target heading is
// linted on its own; a headingless fragment (bullet-only Edit) is judged on the
// reconstructed post-edit document, since the section it lands in is only known
// from disk. Read-only and fail-open: check-worktree-notes-lang.js stays the backstop.

const fs = require("fs");
const path = require("path");
const { readStdinJson, pathOf, normalizePath, collectEditTargets, approve, block, applyEdits } = require("./lib/pretool-lang-gate");
const { loadDocsLangConfig, classifyPolicy } = require("./lib/lang-config");
const { lintWorktreeNotesLang, enforcementFor } = require("./lib/lint-worktree-notes-lang");
const { safeIsPrivateRepo } = require("./lib/is-private-repo");

const TARGET_BASENAME = "WORKTREE_NOTES.md";
const HEADING_RE = /^## (History Notes|Changelog Notes)$/m;

function groupEditsFor(toolInput, filePath) {
  if (!Array.isArray(toolInput.edits)) return [toolInput];
  const topPath = pathOf(toolInput);
  return toolInput.edits.filter((e) => normalizePath(pathOf(e) || topPath) === filePath);
}

function lintPath(filePath, targets, toolInput, config, isPriv, isWrite) {
  const opts = { isPrivateRepo: isPriv };
  const violations = [];
  let needReconstruct = false;
  for (const t of targets) {
    if (isWrite || HEADING_RE.test(t.fragment)) {
      violations.push(...lintWorktreeNotesLang(t.fragment, config, opts));
    } else {
      needReconstruct = true;
    }
  }
  if (!needReconstruct) return violations;
  let pre;
  try {
    pre = fs.readFileSync(filePath, "utf8");
  } catch (e) {
    return violations;
  }
  const post = applyEdits(pre, groupEditsFor(toolInput, filePath));
  if (post === null) return violations;
  violations.push(...lintWorktreeNotesLang(post, config, opts));
  return violations;
}

function main() {
  const input = readStdinJson();
  if (!input || typeof input !== "object") return approve();
  const targets = collectEditTargets(input.tool_name, input.tool_input)
    .filter((t) => path.basename(t.filePath) === TARGET_BASENAME);
  if (targets.length === 0) return approve();

  const config = loadDocsLangConfig();
  const isPriv = safeIsPrivateRepo(process.cwd());
  if (classifyPolicy(enforcementFor(config, isPriv)) !== "strict") return approve();

  const isWrite = input.tool_name === "Write" && !Array.isArray(input.tool_input.edits);
  const byPath = new Map();
  // Canonical key: alias spellings of one file must land in one group, or the
  // edits under the alias drop out of the reconstruction and escape the lint.
  for (const t of targets) {
    const key = normalizePath(t.filePath);
    if (!byPath.has(key)) byPath.set(key, []);
    byPath.get(key).push(t);
  }
  const violations = [];
  for (const [filePath, group] of byPath) {
    violations.push(...lintPath(filePath, group, input.tool_input, config, isPriv, isWrite));
  }
  if (violations.length === 0) return approve();

  const body = violations
    .slice(0, 5)
    .map((v) => "[" + v.section + ":" + v.lineNumber + "] (expected " + v.policy + ") " + v.line)
    .join("\n");
  return block(
    "[gate-worktree-notes-lang] WORKTREE_NOTES.md language check failed (rejected before write) — " +
      violations.length + " violation(s):\n" + body +
      "\nSet DOCS_LANG_PUBLIC / DOCS_LANG_PRIVATE in .env or rewrite the bullets.",
  );
}

try {
  main();
} catch (e) {
  approve();
}
