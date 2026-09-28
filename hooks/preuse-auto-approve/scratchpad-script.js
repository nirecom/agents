"use strict";
// isAllowedScratchpadInvocation(cmdText) — true ONLY for `bash <absolute-path>.sh [literal-arg…]`
// where the script resolves inside THIS session's scratchpad directory (path
// containment only — script content is not inspected; see issue #2233).
// FAIL-TO-ASK: every uncertainty (no session context, unresolvable path, parse
// failure, any thrown error) returns false, which surfaces the normal permission
// prompt. It never denies — this module feeds an allow-only hook.
// Containment is REALPATH-based and compared SEGMENT-ARRAY-wise: a lexical
// path.resolve would miss a symlink pointing out of the scratchpad, and a naive
// string prefix would accept the sibling directory `scratchpad-evil`.

const fs = require("fs");
const path = require("path");
// Cross-feature import: the clearance-token scanner is the ONE sanctioned site
// enabling the preserveSubstitutionSpans option (fix-1780-round11 X1/X2).
const { parseWithSubstitutionSpans } = require("../block-clearance-token-write/bash-scan/scan");
const { ASSIGN_RE } = require("../lib/bash-write-patterns/segment-utils");
const { segHasHereInput } = require("../lib/bash-write-targets/here.js");
const {
  foldCase,
  getClaudeBaseNorm,
  getCurrentSessionScratchpadRootNorm,
  isRepoExcluded,
} = require("../lib/claude-scratchpad-base");
const { findRepoRoot } = require("../enforce-worktree/git-repo-detection");
const { toWindowsPath } = require("../lib/branch-diff");

// Any of these in the RAW argument means the shell would rewrite the path after
// this hook inspected it, so the inspected path is not what runs.
const UNRESOLVABLE_CHARS = ["$", "`", "*", "?", "[", "]", "{", "}"];
const SCRATCHPAD_DIR_NAME = "scratchpad";

function splitSegments(p) {
  return path.resolve(p).split(/[\\/]+/).filter((s) => s.length > 0);
}

// The segments of `child` below `root`, or null when child is not STRICTLY under
// root. Element-wise comparison — never a string prefix test.
function segmentsUnder(root, child) {
  const rootSegs = splitSegments(root);
  const childSegs = splitSegments(child);
  if (childSegs.length <= rootSegs.length) return null;
  for (let i = 0; i < rootSegs.length; i++) {
    if (foldCase(rootSegs[i]) !== foldCase(childSegs[i])) return null;
  }
  return childSegs.slice(rootSegs.length);
}

// The single `bash <script>` segment, or null. Rejects chaining/pipes/subshells
// (any separator), env-prefix assignments, redirects, here-input, a missing
// operand, and any argument the shell would expand.
function singleBashSegment(cmdText) {
  if (typeof cmdText !== "string" || cmdText.trim() === "") return null;
  // Newlines are command separators in the shell — never valid in a single scratchpad
  // invocation. The parser would silently treat \n as whitespace, placing a second
  // command token into argv where it would pass the arg validation checks below.
  if (cmdText.includes("\n") || cmdText.includes("\r")) return null;
  const ir = parseWithSubstitutionSpans(cmdText);
  if (!ir || ir.parseFailure === true || !Array.isArray(ir.segments)) return null;
  if (ir.segments.length !== 1) return null;
  if (Array.isArray(ir.separators) && ir.separators.length !== 0) return null;
  const seg = ir.segments[0];
  if (!seg || typeof seg.cmd0 !== "string" || seg.cmd0 === "") return null;
  if (ASSIGN_RE.test(seg.cmd0)) return null;
  // Bare literal, not a basename: a path-qualified `C:\attacker\bash.exe` shares
  // the basename but need not be a shell, and could ignore the inspected script.
  if (seg.cmd0 !== "bash") return null;
  if (!Array.isArray(seg.redirects) || seg.redirects.length !== 0) return null;
  if (segHasHereInput(seg)) return null;
  const argv = Array.isArray(seg.argv) ? seg.argv : [];
  if (argv.length < 1) return null;
  if (!Array.isArray(seg.argvRaw) || seg.argvRaw.length !== argv.length) return null;
  if (!seg.argvRaw.every((x) => typeof x === "string")) return null;
  const argvRaw = seg.argvRaw;
  // Leading `~` is bash home-expansion; a mid-token `~` (8.3 short names) is literal.
  for (const rawArg of argvRaw.slice(1)) {
    if (rawArg.startsWith("~")) return null;
    for (const ch of UNRESOLVABLE_CHARS) {
      if (rawArg.indexOf(ch) !== -1) return null;
    }
  }
  return { arg: argv[0], raw: argvRaw[0] };
}

// The realpath of the script, or null when it is not an existing regular `.sh`
// file given as a literal absolute path.
function resolveScriptPath(operand) {
  if (typeof operand.raw !== "string") return null;
  for (const ch of UNRESOLVABLE_CHARS) {
    if (operand.raw.indexOf(ch) !== -1) return null;
  }
  const arg = toWindowsPath(operand.arg);
  if (typeof arg !== "string" || !path.isAbsolute(arg)) return null;
  if (!/\.sh$/.test(arg)) return null;
  const real = fs.realpathSync(arg);
  return fs.statSync(real).isFile() ? real : null;
}

// {kind:"session"} carries no directory, so the base-relative shape is matched
// structurally: <project-slug>/<session-id>/scratchpad/<...>.
function isUnderSessionShape(realScript, sessionId) {
  const segs = segmentsUnder(fs.realpathSync(toWindowsPath(getClaudeBaseNorm())), realScript);
  if (segs === null || segs.length < 4) return false;
  return foldCase(segs[1]) === foldCase(sessionId) && foldCase(segs[2]) === SCRATCHPAD_DIR_NAME;
}

function isAllowedScratchpadInvocation(cmdText) {
  try {
    const operand = singleBashSegment(cmdText);
    if (operand === null) return false;
    const root = getCurrentSessionScratchpadRootNorm();
    if (root === null) return false;
    const realScript = resolveScriptPath(operand);
    if (realScript === null) return false;

    const contained = root.kind === "path"
      ? segmentsUnder(fs.realpathSync(root.root), realScript) !== null
      : isUnderSessionShape(realScript, root.sessionId);
    if (!contained) return false;

    // F1: a poisoned TEMP can place the whole claude base inside a repo.
    return !isRepoExcluded(realScript, findRepoRoot);
  } catch (_e) {
    return false;
  }
}

module.exports = { isAllowedScratchpadInvocation };
