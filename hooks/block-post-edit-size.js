#!/usr/bin/env node
// PreToolUse hook: post-edit size checks of a Write/Edit/MultiEdit, dispatch only (#1894, #2631).
// Reads the input once, runs block-post-edit-size/comment-block.js then file-size.js, and merges:
// any block -> one block whose reason joins every check's reasons; advice only -> approve with
// additionalContext. Each check fails open on its own, so one crash never silences the other.
"use strict";

const fs = require("fs");
const { readDefaultEnvFile } = require("./lib/load-env");
const { readHookInput, readFailOpenDiagnostic } = require("./lib/read-stdin");
const { MAX_BYTES, resolveTargetPath } = require("./lib/post-edit-content");
const commentBlock = require("./block-post-edit-size/comment-block");
const fileSize = require("./block-post-edit-size/file-size");

const CHECKS = [commentBlock.check, fileSize.check];

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
  process.exit(0);
}

function runCheck(fn, input, env) {
  try {
    return fn(input, env) || {};
  } catch (_) {
    return {};
  }
}

function merge(results) {
  const blocks = [];
  const advice = [];
  for (const r of results) {
    if (Array.isArray(r.blocks)) blocks.push(...r.blocks);
    if (Array.isArray(r.advice)) advice.push(...r.advice);
  }
  if (blocks.length > 0) return { decision: "block", reason: blocks.join("\n") };
  if (advice.length > 0) {
    return { decision: "approve", hookSpecificOutput: { hookEventName: "PreToolUse", additionalContext: advice.join("\n") } };
  }
  return { decision: "approve" };
}

function main() {
  const r = readHookInput();
  if (r.kind !== "ok") {
    try { fs.writeSync(2, readFailOpenDiagnostic("block-post-edit-size", r, "check skipped") + "\n"); } catch (_) {}
    emit({ decision: "approve" });
  }
  const input = r.input;
  if (!input || typeof input !== "object") emit({ decision: "approve" });
  const env = readDefaultEnvFile() || {};
  emit(merge(CHECKS.map((fn) => runCheck(fn, input, env))));
}

if (require.main === module) {
  try {
    main();
  } catch (e) {
    // A PreToolUse hook that throws becomes an error on every tool call, which is how a guard gets uninstalled.
    emit({ decision: "approve" });
  }
}

module.exports = { buildReason: commentBlock.buildReason, buildPost: commentBlock.buildPost, resolveTargetPath, MAX_BYTES };
