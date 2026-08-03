// hooks/block-off-clearance-write/dispatch.js
// Tool-shape dispatch + block-message selection for the
// block-off-clearance-write entrypoint (file-split, rules/coding/file-split.md).
"use strict";

const { classifyProtectedPath } = require("../lib/protected-basenames");
const { isEditWriteTool, isCommandTool, collectEditWritePaths, commandTextOf } = require("../lib/write-tools");
const { bashHitsProtected } = require("./bash-scan");

const TOKEN_BLOCK_MSG = [
  "Direct write to an OFF-clearance token blocked.",
  "Clearance tokens are minted only by the Phase1 examination:",
  "  bash \"$AGENTS_CONFIG_DIR/bin/request-off-clearance\" --target <workflow|worktree> --category <rubric category> --detail \"<why>\"",
  "If the examiner itself is broken, use the EMERGENCY OFF sentinel (human approval required).",
  "To READ a token, use a plain shell read (cat / Get-Content) — interpreter one-liners are blocked regardless of intent unless they match a recognized read-only shape.",
  "Recognized shapes take single-quoted literals or $env:/process.env only; double-quoted PowerShell arguments and backslash paths are never accepted.",
].join("\n");

// Session-override markers authorize purely on file EXISTENCE
// (hooks/lib/session-markers.js), so a single forged file grants full
// clearance. Writing one directly is never legitimate — the sentinels are
// the only sanctioned route, and they are human-gated by settings.json `ask`.
const MARKER_BLOCK_MSG = [
  "Direct write to a session-override marker blocked.",
  "Markers (.workflow-off / .worktree-off / .issue-close-verified / .next-step-paused / .off-emergency-invoked)",
  "grant clearance by their mere existence, so they are never written by hand.",
  "Use the sentinel instead — it is human-gated and audited:",
  "  echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF: {reason}>>\"   (requires a clearance token)",
  "  echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY: {reason}>>\"   (examiner broken; human approval)",
  "Restore with: echo \"<<WORKFLOW_ENFORCE_WORKFLOW_ON: {reason}>>\"",
].join("\n");

// A bulk glob (`<workflowDir>/*`, `<workflowDir>/s1*`) commits no literal
// character to a protected suffix but still expands onto the live clearance
// token and every session-override marker. Blocked on DIRECTORY CONTAINMENT
// rather than name overlap, so it gets its own remediation text.
const WORKFLOW_GLOB_BLOCK_MSG = [
  "Wildcard write into the workflow directory blocked.",
  "A glob in this directory expands onto the OFF-clearance token and the session-override",
  "markers, whose mere existence and contents grant clearance — so a bulk write here is",
  "indistinguishable from forging them.",
  "Name the exact file you mean to write, or run the sanctioned route:",
  "  bash \"$AGENTS_CONFIG_DIR/bin/request-off-clearance\" --target <workflow|worktree> --category <rubric category> --detail \"<why>\"",
].join("\n");

// A target whose BASENAME is assembled at execution time gets its own text
// rather than reusing WORKFLOW_GLOB_BLOCK_MSG — that message opens with
// "Wildcard write", which is misleading when there is no `*` to find
// (CPR-1/CPR-7).
const WORKFLOW_DYNAMIC_BLOCK_MSG = [
  "Dynamically-named write into the workflow directory blocked.",
  "The filename is assembled at execution time (command substitution, backtick, or an",
  "unresolved shell variable), so this hook cannot tell it apart from the OFF-clearance",
  "token or a session-override marker — whose mere existence grants clearance.",
  "Spell the target out literally, or run the sanctioned route:",
  "  bash \"$AGENTS_CONFIG_DIR/bin/request-off-clearance\" --target <workflow|worktree> --category <rubric category> --detail \"<why>\"",
].join("\n");

// A command this scanner cannot PARSE cannot be cleared, so a protected
// mention inside unparsable text blocks — and says so out loud, since a
// block whose cause is invisible is a block nobody can act on (CPR-1).
const UNPARSED_PREFIX = [
  "This command could not be parsed, and its text names an OFF-clearance token",
  "or a session-override marker — so it cannot be cleared and is blocked.",
  "If the write is legitimate, re-issue it as a plainly parsable command:",
  "close every quote, and drop trailing comments containing apostrophes.",
  "",
].join("\n");

function blockMessageFor(kind) {
  if (kind === "unparsed-marker") return UNPARSED_PREFIX + MARKER_BLOCK_MSG;
  if (kind === "unparsed-token") return UNPARSED_PREFIX + TOKEN_BLOCK_MSG;
  if (kind === "marker") return MARKER_BLOCK_MSG;
  if (kind === "workflow-glob") return WORKFLOW_GLOB_BLOCK_MSG;
  if (kind === "workflow-dynamic") return WORKFLOW_DYNAMIC_BLOCK_MSG;
  return TOKEN_BLOCK_MSG;
}

// evaluateProtectedWrite({ toolName, toolInput }): null when the call may
// proceed, otherwise { kind, reason }. Throwing is the caller's fail-open
// signal; this function itself never decides to approve on error.
//
// The tool-class membership tests and the edit-payload path extraction
// (file_path / path / notebook_path, top level and per-entry in `edits[]`)
// both live in hooks/lib/write-tools.js, so this hook and
// hooks/enforce-worktree.js cover exactly the same tool surface (CPR-2/CPR-5).
function evaluateProtectedWrite(toolName, toolInput) {
  if (isEditWriteTool(toolName)) {
    for (const p of collectEditWritePaths(toolInput)) {
      const kind = classifyProtectedPath(p);
      if (kind) return { kind, reason: blockMessageFor(kind) };
    }
    return null;
  }
  // runCommands delivers an ARRAY under `commands`, not a string under
  // `command` — reading `.command` here would silently bypass this hook.
  // commandTextOf joins with "\n" so a write in commands[1] is scanned as
  // its own statement rather than glued onto the tail of commands[0].
  if (isCommandTool(toolName)) {
    const kind = bashHitsProtected(commandTextOf(toolName, toolInput), { cwd: toolInput.cwd });
    return kind ? { kind, reason: blockMessageFor(kind) } : null;
  }
  return null;
}

module.exports = {
  TOKEN_BLOCK_MSG,
  MARKER_BLOCK_MSG,
  WORKFLOW_GLOB_BLOCK_MSG,
  WORKFLOW_DYNAMIC_BLOCK_MSG,
  blockMessageFor,
  collectEditWritePaths,
  evaluateProtectedWrite,
};
