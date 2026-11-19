#!/usr/bin/env node
// PreToolUse hook (#2941): block direct writes to a state file that carries the pm key (own,
// another PM, archived or an old generation) through the tool-write path and the shell path; for a
// state file without it, block a tool write whose new text carries "pm" and every shell write.
// The PM assignment changes only via /pm-init, /pm-add, /pm-remove and bin/pm-state set-sequence.
// Unreadable stdin blocks; a non-JSON stdin and other error paths approve. WORKFLOW_OFF bypasses.
// The tool surface follows hooks/block-clearance-token-write/dispatch.js; bash and PowerShell text
// run through the detection write-target collector (redirects, tee/rm/cp/mv, the pwsh write cmdlets),
// with home/env aliases expanded and relative targets placed against the cd-tracked directory.
// Registration: settings.json "Edit|Write|MultiEdit|editFiles|NotebookEdit" and
// "Bash|runInTerminal|runCommands|PowerShell".
"use strict";
const fs = require("fs");
const path = require("path");
const { toWindowsPath } = require("./lib/branch-diff");
const { PWSH_ENV_PREFIX } = require("./lib/case-insensitive-literal");
const { isProtectedPmStatePath, isStateFilePath } = require("./pm-session/state-path");
const { isCommandTool, isPowerShellTool } = require("./lib/tool-command-text");
const { isEditWriteTool, collectEditWritePaths } = require("./lib/write-tools");
const { scannableCommandListOf } = require("./lib/scannable-command-list");
const { readHookInput, readFailureReason, readFailOpenDiagnostic } = require("./lib/read-stdin");

const HOOK_NAME = "block-pm-state-write";
const BLOCK_MSG =
  "Direct writes to a PM session's state file (any file carrying the `pm` key) are blocked, as are " +
  "writing the `pm` key into any session state file and every shell write to one. " +
  "Change the assignment with /pm-add or /pm-remove in the PM session, and the issue order with " +
  "`bin/pm-state set-sequence`. See docs/architecture/cross-session-messaging.md.";

function approve() { console.log(JSON.stringify({ decision: "approve" })); process.exit(0); }
function block(reason) { console.log(JSON.stringify({ decision: "block", reason })); process.exit(0); }

function blockOrBypass(sid) {
  try {
    const { isWorkflowOff, workflowOffNoticeText } = require("./lib/session-markers");
    if (isWorkflowOff(sid)) {
      process.stderr.write(workflowOffNoticeText(HOOK_NAME, sid) + "\n");
      approve();
    }
  } catch (_e) { /* a confirmed hit still blocks when the marker check fails */ }
  block(BLOCK_MSG);
}

// PowerShell reads a leading `$env:NAME` / `${env:NAME}` from the environment; bash `~` and
// `$HOME` are expanded by expandForDetection.
const PWSH_ENV_REF_RE = new RegExp(
  `^("?)(?:\\$${PWSH_ENV_PREFIX}([A-Za-z_]\\w*)|\\$\\{${PWSH_ENV_PREFIX}([A-Za-z_]\\w*)\\})(?=[\\\\/"]|$)`);
function expandPwshEnv(raw) {
  const m = PWSH_ENV_REF_RE.exec(raw);
  const v = m && process.env[m[2] || m[3]];
  return v && path.isAbsolute(v) ? m[1] + v.replace(/\\/g, "/") + raw.slice(m[0].length) : raw;
}

// Each write target is placed against the directory a preceding cd/pushd left the shell in.
function segmentTargets(segments, idx, baseCwd) {
  const { collectDetectionTargets } = require("./lib/bash-write-targets/detection-targets");
  const { expandForDetection } = require("./lib/bash-write-targets/detection-expand");
  const { commandCwd } = require("./block-clearance-token-write/bash-target-context/cwd-tracking");
  const cwd = toWindowsPath(commandCwd(segments, idx, baseCwd) || baseCwd);
  const out = [];
  for (const raw of collectDetectionTargets([segments[idx]])) {
    const d = expandForDetection(expandPwshEnv(raw));
    if (d.path && !d.dynamicTail && !d.aliasUnresolved) out.push(path.resolve(cwd, toWindowsPath(d.path)));
  }
  return out;
}

// Shell content is not inspectable, so a shell write to any state file (pm mark or not) is a hit.
function bashHitsPm(cmd, baseCwd) {
  if (!cmd || typeof cmd !== "string") return false;
  const { parse } = require("./lib/command-ir");
  const ir = parse(cmd);
  if (!ir || ir.parseFailure || !Array.isArray(ir.segments)) return false;
  return ir.segments.some((seg, idx) => Boolean(seg) && segmentTargets(ir.segments, idx, baseCwd).some(isStateFilePath));
}

// A tool write to an unmarked state file is a hit only when its new text carries a "pm" key.
const PM_KEY_RE = /"pm"\s*:/;
function newTextsOf(toolInput) {
  const texts = [];
  const push = (o) => {
    if (!o || typeof o !== "object") return;
    for (const k of ["content", "new_string", "new_source"]) if (typeof o[k] === "string") texts.push(o[k]);
  };
  push(toolInput);
  if (Array.isArray(toolInput.edits)) toolInput.edits.forEach(push);
  return texts;
}

function toolHitsPm(toolInput) {
  const paths = collectEditWritePaths(toolInput);
  if (paths.some(isProtectedPmStatePath)) return true;
  return paths.some(isStateFilePath) && newTextsOf(toolInput).some((t) => PM_KEY_RE.test(t));
}

// command-ir joins a statement after a newline onto the previous one, so each line is scanned too.
// PowerShell escapes with a backtick, so its `\` is a literal path separator, not a bash escape.
function shellHitsPm(cmd, powershell, baseCwd) {
  if (!cmd || typeof cmd !== "string") return false;
  const text = powershell ? cmd.replace(/\\/g, "/") : cmd;
  return [text, ...text.split(/\r?\n/)].some((t) => bashHitsPm(t, baseCwd));
}

const r = readHookInput();
if (r.kind === "read-error") block(readFailureReason(HOOK_NAME, r.error));
if (r.kind === "json-invalid") {
  try { fs.writeSync(2, readFailOpenDiagnostic(HOOK_NAME, r, "check skipped") + "\n"); } catch (_) {}
  approve();
}
const input = r.input;
if (!input || typeof input !== "object") approve();

const toolName = input.tool_name;
const toolInput = input.tool_input || {};
const sid = input.session_id;

try {
  const powershell = isPowerShellTool(toolName);
  const baseCwd = typeof toolInput.cwd === "string" && toolInput.cwd ? toWindowsPath(toolInput.cwd) : process.cwd();
  const shellHit = (c) => shellHitsPm(c, powershell, baseCwd);
  if ((isCommandTool(toolName) || powershell) && scannableCommandListOf(toolName, toolInput).some(shellHit)) blockOrBypass(sid);
  if (isEditWriteTool(toolName) && toolHitsPm(toolInput)) blockOrBypass(sid);
} catch (_e) { /* fail-open on a detection error */ }

approve();
