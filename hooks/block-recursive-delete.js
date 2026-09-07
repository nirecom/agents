#!/usr/bin/env node
// PreToolUse hook: deny every recursive delete. Unconditional — no marker or
// bypass env var is read; all judgment lives in recursive-delete-scan.js.
// Fail-open on transport faults, fail-closed on any in-process fault.

"use strict";

const fs = require("fs");

const BLOCK_MESSAGE =
  "Recursive deletion is denied. This is banned regardless of flag spelling, " +
  "order, short/long form, or shell (rm -r/-rf/--recursive, Remove-Item -Recurse, " +
  "cmd /c rmdir /s, and any wrapper or substitution that hides them). " +
  "The only sanctioned route is: node hooks/cleanup-orphan-dir.js " +
  "--force-if-not-registered <path>. Non-recursive deletion of a single file " +
  "(rm <file>) remains available.";

module.exports = { BLOCK_MESSAGE };

// `failed` marks a mid-read throw: JSON.parse cannot distinguish truncation
// from "not a command", and its failure path is fail-open.
function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(65536);
  let failed = false;
  try {
    while (true) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      // COPY, never a view: `buf` is reused by the next readSync, so a view
      // lost its bytes and padding past 64KiB bypassed the guard (#2210).
      chunks.push(Buffer.from(buf.subarray(0, n)));
    }
  } catch (e) {
    failed = true;
  }
  return { text: Buffer.concat(chunks).toString("utf8"), failed };
}

// Silence, not `decision: "approve"`: this is a deny-only guard on the widest
// matcher, and an explicit approve bypasses the permission prompt every other
// layer would still raise, so one scanner miss becomes an auto-approval (C15).
function approve() {
  process.exit(0);
}

function block() {
  console.log(JSON.stringify({ decision: "block", reason: BLOCK_MESSAGE }));
  process.exit(0);
}

function main() {
  let input = null;
  const { text, failed } = readStdin();
  if (failed) block(); // fail-closed: a read exception may have truncated the payload
  try {
    input = JSON.parse(text);
  } catch (e) {
    approve(); // fail-open on malformed stdin (transport fault, not a command)
  }

  // Required here, not at module scope, so a throwing require is caught by the
  // wrapper below instead of aborting before any decision is emitted.
  const { COMMAND_TOOL_NAMES, commandTextOf } = require("./lib/tool-command-text");
  const { scanCommandTextForRecursiveDelete } = require("./lib/bash-write-targets/recursive-delete-scan");

  // A non-object top level (null / array / scalar) carries no tool call.
  if (!input || typeof input !== "object" || Array.isArray(input)) approve();
  if (!COMMAND_TOOL_NAMES.includes(input.tool_name)) approve();

  const rawCmd = commandTextOf(input.tool_name, input.tool_input);
  if (!rawCmd) approve();
  if (scanCommandTextForRecursiveDelete(rawCmd)) block();
  approve();
}

// Any escaping throw becomes a block: the settings.json deny globs are gone,
// so crashing would fall through to the harness's fail-OPEN default.
if (require.main === module) {
  try {
    main();
  } catch (e) {
    block();
  }
}
