#!/usr/bin/env node
// PreToolUse hook: block direct writes to the append-only document family —
// the canonical docs/history.md + CHANGELOG.md AND their rotated archives
// (docs/history/*.md, changelog/*.md, docs/changelog/*.md) — through the
// tool-write path and the shell path (write-redirect / tee / PowerShell cmdlet /
// cp / mv targets). These files are append-only and must be modified via the
// `doc-append` CLI (which writes via its own internal API, not via shell
// redirects). Fail-open: any error path approves rather than blocking.
//
// Registration contract: settings.json must register this hook in TWO PreToolUse
// matcher groups — "Edit|Write|MultiEdit|editFiles" and "Bash|runInTerminal|runCommands"
// — matching the tool names handled by the `switch` below (parity pinned by
// tests/feature-1611-append-only-archive-guard.sh T1-R).
"use strict";
const fs = require("fs");
const { parse } = require("./lib/command-ir");
const { collectWriteTargetsFromSegments, SHELL_CONFIG_VERB_SET } = require("./lib/bash-write-targets");

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(buf.slice(0, n));
    }
  } catch (_e) {}
  return Buffer.concat(chunks).toString("utf8");
}

function approve() { console.log(JSON.stringify({ decision: "approve" })); process.exit(0); }
function block(reason) { console.log(JSON.stringify({ decision: "block", reason })); process.exit(0); }

// Shared by both dispatch lanes (CPR-ORTH): a protected hit blocks UNLESS the
// calling session has an active WORKFLOW_ENFORCE_WORKFLOW_OFF /
// WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY marker (<workflowDir>/<sid>.workflow-off),
// in which case it approves instead —
// after writing a stderr notice so the bypass is never silent. Only ever
// called once a hit has actually been detected, so a non-hit never reaches
// (and never logs via) this path.
function blockOrBypass(sid) {
  try {
    const { isWorkflowOff, workflowOffNoticeText } = require("./lib/session-markers");
    if (isWorkflowOff(sid)) {
      process.stderr.write(workflowOffNoticeText("block-history-direct", sid) + "\n");
      approve();
    }
  } catch (_e) {
    // require() or the marker check itself threw — a confirmed protected hit
    // must still block; do not let a dependency failure fail this open.
  }
  block(BLOCK_MSG);
}

// The append-only document family. Case-insensitive: Windows filesystems are
// case-insensitive, so `Docs/History/2026.md` must not slip past (CPR-UNV).
const PROTECTED_PATTERNS = [
  /(^|\/)docs\/history\.md$/i,          // canonical history
  /(^|\/)changelog\.md$/i,              // canonical changelog
  /(^|\/)docs\/history\/[^/]+\.md$/i,   // rotated history archives
  /(^|\/)changelog\/[^/]+\.md$/i,       // rotated changelog archives (incl. docs/changelog/)
];

// Rule documents that merely share a name with the protected family.
const EXCLUDED_PATTERNS = [
  /(^|\/)rules\/docs\/history\.md$/i,
  /(^|\/)rules\/docs\/changelog\.md$/i,
];

// Normalize separators and collapse `.` / `..` segments so that
// `docs/history/../history/2026.md` is judged as `docs/history/2026.md`.
function normalizePath(filePath) {
  const segments = String(filePath).replace(/\\/g, "/").split("/");
  const out = [];
  for (const seg of segments) {
    if (seg === "" || seg === ".") continue;
    if (seg === "..") { out.pop(); continue; }
    out.push(seg);
  }
  return out.join("/");
}

// Single predicate shared by the tool-write path and the shell path — never
// add a second one; both call sites must stay symmetric (CPR-ORTH).
function isProtectedPath(filePath) {
  if (!filePath || typeof filePath !== "string") return false;
  const norm = normalizePath(filePath);
  if (!norm) return false;
  if (EXCLUDED_PATTERNS.some((re) => re.test(norm))) return false;
  return PROTECTED_PATTERNS.some((re) => re.test(norm));
}

function bashHitsProtected(cmd) {
  if (!cmd || typeof cmd !== "string") return false;
  const ir = parse(cmd);
  if (!ir || ir.parseFailure) return false;
  const { targets } = collectWriteTargetsFromSegments(ir.segments, { verbs: SHELL_CONFIG_VERB_SET });
  if (!targets) return false;
  return targets.some((t) => isProtectedPath(t.path));
}

const BLOCK_MSG =
  "Direct writes to the append-only document family (canonical docs/history.md and " +
  "CHANGELOG.md, plus their rotated archives under docs/history/, changelog/ and " +
  "docs/changelog/) are blocked. Use the `doc-append` CLI to add entries, or " +
  "`uv run bin/doc-rotate.py` to archive them. See rules/docs/history.md for usage.";

let input;
try {
  input = JSON.parse(readStdin());
} catch (_e) {
  approve();
}
if (!input || typeof input !== "object") approve();

const toolName = input.tool_name;
const toolInput = input.tool_input || {};
const sid = input.session_id;

switch (toolName) {
  case "Edit":
  case "Write":
  case "MultiEdit":
  case "editFiles":
    if (isProtectedPath(toolInput.file_path)) blockOrBypass(sid);
    break;
  case "Bash":
  case "runInTerminal":
  case "runCommands":
    if (bashHitsProtected(toolInput.command)) blockOrBypass(sid);
    break;
  default:
    break;
}

approve();
