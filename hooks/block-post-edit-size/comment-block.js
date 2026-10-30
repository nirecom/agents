"use strict";
// Comment-block check of hooks/block-post-edit-size.js (issue #1894): refuse an Edit/Write leaving
// an over-threshold run of consecutive comment lines in a code file, judged on the POST-edit file in
// absolute terms (the pre-commit backstop is baseline-relative instead, CPR-SC). Never bypassable:
// it reads no session escape-hatch state (tests/hooks/feature-1894-hook-comment-block/no-bypass.sh),
// and its config comes only from the settings root's .env, never process.env. Fails open.

const path = require("path");
const { MAX_BYTES, resolveTargetPath, buildPostContent } = require("../lib/post-edit-content");
const {
  hasScannableExtension,
  isExcludedPath,
  parseExtensions,
  parseMaxLines,
  scanText,
} = require("../lib/comment-block-scan");

// A modal message, not a report: past a handful of ranges the first one is buried.
const MAX_DETAIL_RANGES = 5;
const RULE_DOC = "rules/coding/file-split.md";
const TOOLS = ["Write", "Edit", "MultiEdit"];
const NONE = Object.freeze({});

// buildPost — null = cannot rebuild → approve (an unmatched old_string fails the tool call itself).
function buildPost(toolName, toolInput, absPath) {
  return buildPostContent(toolName, toolInput, absPath, { maxBytes: MAX_BYTES });
}

// buildReason — the whole remedy path, since there is no override. The comment TEXT is never quoted
// back: the reason lands in a transcript, and comments are where secrets get parked.
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

// check(input, env) -> { blocks: [reason] } | {}. editFiles / NotebookEdit carry no
// reconstructable before/after, so they pass with the commit gate as their only cover.
function check(input, env) {
  const toolName = input.tool_name;
  if (TOOLS.indexOf(toolName) === -1) return NONE;
  const toolInput = input.tool_input;
  if (!toolInput || typeof toolInput !== "object") return NONE;
  const absPath = resolveTargetPath(input, toolInput.file_path);
  if (!absPath) return NONE;

  if (env.COMMENT_BLOCK_ENFORCE === "off") return NONE;
  const threshold = parseMaxLines(env.COMMENT_BLOCK_MAX_LINES);
  const extensions = parseExtensions(env.CODE_FILE_EXTENSIONS);
  if (!hasScannableExtension(absPath, extensions)) return NONE;
  if (isExcludedPath(absPath)) return NONE;

  let post;
  try {
    post = buildPost(toolName, toolInput, absPath);
  } catch (e) {
    post = null;
  }
  if (typeof post !== "string" || post.length > MAX_BYTES) return NONE;

  const result = scanText(post, threshold);
  if (!result || !Array.isArray(result.runs) || result.runs.length === 0) return NONE;
  return { blocks: [buildReason(path.basename(absPath), result.runs, threshold)] };
}

module.exports = { check, buildReason, buildPost };
