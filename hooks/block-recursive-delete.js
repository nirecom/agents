#!/usr/bin/env node
// PreToolUse hook: deny every recursive delete, whatever shell or spelling
// carries it (#2210). Unconditional guard — it reads no `.workflow-off` /
// `.worktree-off` marker and honors no bypass env var. All judgment lives in
// hooks/lib/bash-write-targets/recursive-delete-scan.js (CPR-SSOT); this file
// is transport only. Fail-open on transport faults (unparseable stdin,
// non-command tool, empty command), fail-closed on any in-process fault.
// TL3 gap: the PowerShell and cmd.exe routes are judged from command TEXT
// only — no real pwsh.exe / cmd.exe expands these payloads in any test, so
// their semantics are asserted, not verified (see cases-cmdexe.sh's header).

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

// Returns { text, failed }. `failed` is true when readSync threw mid-read
// (EAGAIN/EINTR etc.) — the caller must fail CLOSED on that signal rather than
// handing the truncated `text` to JSON.parse, whose failure path is fail-open
// for the ordinary "not a command" case and cannot tell the two apart on its
// own (#2210 round8 N4).
function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(65536);
  let failed = false;
  try {
    while (true) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      // COPY, never a view: `buf` is reused by the next readSync, and a
      // Buffer.slice/subarray view over it would be overwritten in place — so a
      // payload spanning two reads lost its earlier bytes, JSON.parse threw, and
      // the catch below approved. Padding a command past 64KiB bypassed the
      // whole guard (#2210 round-6).
      chunks.push(Buffer.from(buf.subarray(0, n)));
    }
  } catch (e) {
    failed = true;
  }
  return { text: Buffer.concat(chunks).toString("utf8"), failed };
}

function approve() {
  console.log(JSON.stringify({ decision: "approve" }));
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

  // Loaded here, not at module scope, so a require that throws (a corrupt or
  // half-written lib file) is caught by the wrapper below rather than aborting
  // module load before any decision can be emitted (#2210 round-5).
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

// ANY in-process fault — a failed require, a malformed tool_input shape, a
// throw inside the scan — must not crash the hook into the harness's fail-OPEN
// path: with the settings.json deny globs gone there is no backstop layer left,
// so every escaping throw becomes a block instead (#2210 C9, widened round-5).
// Residual limitation this file cannot reach: a PROCESS-level failure (the
// harness's 5-second timeout killing the hook, `node` never launching) runs
// none of this code, so no decision is emitted at all and the harness applies
// its own non-blocking default. Closing that one is the harness's to make.
if (require.main === module) {
  try {
    main();
  } catch (e) {
    block();
  }
}
