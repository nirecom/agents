#!/usr/bin/env node
// PreToolUse hook: refuse an Edit/Write leaving an over-threshold run of
// consecutive comment lines in a code file (issue #1894) — shift-left
// companion to hooks/pre-commit's backstop scan. Judgment is the POST-edit
// file in absolute terms, not diff-relative (commit-time layer is baseline-
// relative instead, CPR-SC). Never bypassable — no session escape-hatch state
// read (tests/feature-1894-hook-comment-block/no-bypass.sh); config comes only
// from the config dir's .env, never process.env. Fails open on any unreadable
// file, unreconstructable payload, or unexpected shape.
"use strict";

const fs = require("fs");
const path = require("path");
const { readDefaultEnvFile } = require("./lib/load-env");
const { normalizeCwd, resolveRepoCwd } = require("./lib/path-normalize");
const {
  hasScannableExtension,
  isExcludedPath,
  parseExtensions,
  parseMaxLines,
  scanText,
} = require("./lib/comment-block-scan");

// Same byte cap as the CLI: an Edit to a multi-megabyte generated file must not
// spend the hot path scanning it. A performance guard, so its direction is
// approve — and compiled in rather than configurable, since a settable cap is a
// settable way to review nothing.
const MAX_BYTES = 1000000;
// A modal message, not a report: past a handful of ranges the first one is
// buried. The CLI report uses the same cap.
const MAX_DETAIL_RANGES = 5;
const RULE_DOC = "rules/coding/file-split.md";

const WRITE_TOOL = "Write";
const EDIT_TOOLS = ["Edit", "MultiEdit"];

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(65536);
  try {
    for (;;) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(Buffer.from(buf.slice(0, n)));
    }
  } catch (e) {
    // EOF on a pipe surfaces as an exception on some platforms; whatever was
    // read so far is still the payload.
  }
  return Buffer.concat(chunks).toString("utf8");
}

function approve() {
  process.stdout.write(JSON.stringify({ decision: "approve" }) + "\n");
  process.exit(0);
}

function block(reason) {
  process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
  process.exit(0);
}

// resolveTargetPath — the file the tool is about to write, as an absolute path
// Node can open. resolveRepoCwd() owns the cwd priority order (input.cwd beats
// CLAUDE_PROJECT_DIR when they disagree, which is the linked-worktree signal);
// process.cwd() is never used as a base directly, because a hook's cwd is
// wherever Claude Code was launched from and only coincidentally the repo.
// normalizeCwd() also converts the POSIX drive-letter shape that msys hands
// over on Windows (e.g. a slash-c-slash prefix) into a form fs can open.
function resolveTargetPath(input, rawPath) {
  if (typeof rawPath !== "string" || rawPath.length === 0) return null;
  const normalized = normalizeCwd(rawPath) || rawPath;
  if (path.isAbsolute(normalized)) return normalized;
  const base = resolveRepoCwd({ input });
  if (typeof base !== "string" || base.length === 0) return null;
  return path.resolve(base, normalized);
}

function readPre(absPath) {
  try {
    const st = fs.statSync(absPath);
    if (!st.isFile() || st.size > MAX_BYTES) return null;
    return fs.readFileSync(absPath, "utf8");
  } catch (e) {
    return null;
  }
}

// applyOne — one Edit step against a buffer. null means "cannot reconstruct",
// which the caller turns into an approve: the tool call itself is going to fail
// on an unmatched old_string, and a policy verdict about a state that will
// never exist is worse than no verdict.
function applyOne(buf, edit) {
  if (!edit || typeof edit !== "object") return null;
  const oldStr = edit.old_string;
  const newStr = edit.new_string;
  if (typeof oldStr !== "string" || typeof newStr !== "string") return null;
  if (oldStr.length === 0) return null;
  const idx = buf.indexOf(oldStr);
  if (idx === -1) return null;
  if (edit.replace_all === true) return buf.split(oldStr).join(newStr);
  return buf.slice(0, idx) + newStr + buf.slice(idx + oldStr.length);
}

// buildPost — the file content as it will be AFTER the tool runs, reconstructed
// in memory. Nothing here touches disk for writing: a PreToolUse hook advises,
// and a hook that materialised the post file to scan it would have performed
// the very write it is about to refuse.
function buildPost(toolName, toolInput, absPath) {
  if (toolName === WRITE_TOOL) {
    return typeof toolInput.content === "string" ? toolInput.content : null;
  }
  const pre = readPre(absPath);
  if (pre === null) return null;
  if (toolName === "Edit") return applyOne(pre, toolInput);
  // MultiEdit applies its edits in sequence, each onto the previous result —
  // the second step's old_string routinely exists only in the first step's
  // output, so the buffer has to evolve.
  const edits = toolInput.edits;
  if (!Array.isArray(edits) || edits.length === 0) return null;
  let buf = pre;
  for (const edit of edits) {
    buf = applyOne(buf, edit);
    if (buf === null) return null;
  }
  return buf;
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
  let input;
  try {
    input = JSON.parse(readStdin());
  } catch (e) {
    approve();
    return;
  }
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

  // Config from the config dir's .env and nowhere else — see the header.
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
