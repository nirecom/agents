#!/usr/bin/env node
// PreToolUse hook: refuse an Edit/Write leaving an over-threshold run of
// consecutive comment lines in a code file (issue #1894) — shift-left
// companion to hooks/pre-commit's backstop scan. Judgment is the POST-edit
// file in absolute terms, not diff-relative (commit-time layer is baseline-
// relative instead, CPR-SC). Never bypassable — no session escape-hatch state
// read (tests/hooks/feature-1894-hook-comment-block/no-bypass.sh); config comes only
// from the settings root's .env, never process.env. Fails open on any unreadable
// file, unreconstructable payload, or unexpected shape.
"use strict";

const fs = require("fs");
const path = require("path");
const { readDefaultEnvFile } = require("./lib/load-env");
const { readHookInput, readFailOpenDiagnostic } = require("./lib/read-stdin");
// Post-edit reconstruction is shared with block-case-markers.js (#2388).
const { MAX_BYTES, resolveTargetPath, buildPostContent } = require("./lib/post-edit-content");
const {
  hasScannableExtension,
  isExcludedPath,
  parseExtensions,
  parseMaxLines,
  scanText,
} = require("./lib/comment-block-scan");

// MAX_BYTES (shared) is the CLI's byte cap too: over it the hook approves.
// A modal message, not a report: past a handful of ranges the first one is
// buried. The CLI report uses the same cap.
const MAX_DETAIL_RANGES = 5;
const RULE_DOC = "rules/coding/file-split.md";

const WRITE_TOOL = "Write";
const EDIT_TOOLS = ["Edit", "MultiEdit"];

function approve() {
  process.stdout.write(JSON.stringify({ decision: "approve" }) + "\n");
  process.exit(0);
}

function block(reason) {
  process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
  process.exit(0);
}

// buildPost — compatibility alias: the post-edit content, rebuilt in memory by
// the shared module (null = cannot rebuild → approve; an unmatched old_string
// fails the tool call itself, so no verdict beats a verdict on a phantom state).
function buildPost(toolName, toolInput, absPath) {
  return buildPostContent(toolName, toolInput, absPath, { maxBytes: MAX_BYTES });
}

// buildReason — what a refused author is told. The hook offers no override, so
// the message is the entire remedy path: which file, which lines, what the
// limit is, and where the rule lives. The comment TEXT is never quoted back —
// the reason lands in a transcript, and comments are where secrets get parked.
function buildReason(fileName, runs, threshold) {
  const shown = runs.slice(0, MAX_DETAIL_RANGES);
  const lines = [
    `Comment-block size: ${fileName} would carry ${runs.length} comment block(s) ` +
      `carrying more than ${threshold} comment lines per block.`,
  ];
  for (const r of shown) {
    lines.push(`  L${r.start}-L${r.end} (${r.len} comment lines)`);
  }
  const rest = runs.length - shown.length;
  if (rest > 0) lines.push(`  ... and ${rest} more`);
  lines.push(
    `Compress each to a one-line summary + a pointer to the authoritative doc (CPR-SSOT), ` +
      `or split the file — see ${RULE_DOC} (Pattern A).`
  );
  return lines.join("\n");
}

function main() {
  const r = readHookInput();
  if (r.kind !== "ok") {
    try { fs.writeSync(2, readFailOpenDiagnostic("block-comment-block-size", r, "check skipped") + "\n"); } catch (_) {}
    approve();
    return;
  }
  const input = r.input;
  if (!input || typeof input !== "object") approve();

  const toolName = input.tool_name;
  // editFiles and NotebookEdit share the settings.json matcher group but carry
  // no reconstructable before/after in their payload, so they pass through by
  // design with the commit gate as their only cover.
  if (toolName !== WRITE_TOOL && EDIT_TOOLS.indexOf(toolName) === -1) approve();

  const toolInput = input.tool_input;
  if (!toolInput || typeof toolInput !== "object") approve();

  const absPath = resolveTargetPath(input, toolInput.file_path);
  if (!absPath) approve();

  // Config from the settings root's .env and nowhere else — see the header.
  const env = readDefaultEnvFile() || {};
  if (env.COMMENT_BLOCK_ENFORCE === "off") approve();
  const threshold = parseMaxLines(env.COMMENT_BLOCK_MAX_LINES);
  const extensions = parseExtensions(env.CODE_FILE_EXTENSIONS);

  // Scope filter first: it runs on every Edit, and vendored or archived trees
  // are not the author's code to fix.
  if (!hasScannableExtension(absPath, extensions)) approve();
  if (isExcludedPath(absPath)) approve();

  let post;
  try {
    post = buildPost(toolName, toolInput, absPath);
  } catch (e) {
    post = null;
  }
  if (typeof post !== "string") approve();
  if (post.length > MAX_BYTES) approve();

  let result;
  try {
    result = scanText(post, threshold);
  } catch (e) {
    approve();
    return;
  }
  if (!result || !Array.isArray(result.runs) || result.runs.length === 0) approve();

  block(buildReason(path.basename(absPath), result.runs, threshold));
}

if (require.main === module) {
  try {
    main();
  } catch (e) {
    // Last resort: a PreToolUse hook that throws becomes an error on every tool
    // call, which is how a guard gets uninstalled.
    approve();
  }
}

module.exports = { buildReason, buildPost, resolveTargetPath, MAX_BYTES };
