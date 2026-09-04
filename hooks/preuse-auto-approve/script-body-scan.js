// scriptBodyIsSuspect(realScript) — the content scan behind the scratchpad
// auto-approve. Every other Bash PreToolUse guard sees only `bash <script>` and
// never opens the file, so the body is the one unguarded execution channel; this
// module re-applies those guards' pure predicates to it, plus the
// unknown-interpreter and egress predicates in ../lib/.
// Truthiness is CONSERVATIVE, mirroring the caller's fail-to-ask: whatever this
// scan cannot verify (parse failure, unreadable/oversized file, cycle, budget
// exhausted, a predicate that threw) answers `true`.
// KNOWN LIMITATION: a credential path assigned literally then read through `$VAR`
// IS caught; one assembled at runtime still needs data-flow analysis.
"use strict";

const fs = require("fs");
const path = require("path");

const { stripQuotedArgs } = require("../lib/strip-quoted-args");
const { getBlockCategory } = require("../lib/system-ops-categories");
const { commandTouchesCredentials, textHoldsIndirectCredentialAccess } = require("../lib/credential-check");
const { checkBashCommand: commandTouchesDotenv } = require("../lib/dotenv-check");
const { bashHitsMemory } = require("../lib/memory-path-check");
const { bashHitsProtected: bashHitsHistory } = require("../lib/history-path-check");
const { bashHitsProtected: bashHitsClearance } = require("../block-clearance-token-write/bash-scan/scan");
const {
  isSentinel,
  CHAIN_BOUNDARY_SENTINEL_DQ_RE,
  CHAIN_BOUNDARY_SENTINEL_SQ_MARKER_RE,
} = require("../lib/sentinel-patterns");
const { isForgeScanTarget } = require("../lib/forge-write-extract");
const { matchesBashDenyRule, matchesBashAskRule } = require("../lib/settings-deny-match");
const { commandInvokesUnrecognizedExec } = require("../lib/unrecognized-exec-check");
const { commandIsEgressTool } = require("../lib/egress-command-check");
const { maskDisplayOnlySegments } = require("../lib/display-only-mask");
const { parse } = require("../lib/command-ir");
const { detectWritePredicate } = require("../enforce-worktree/write-detector");

// Budgets. A PreToolUse hook has ~5s total, so an oversized or pathologically
// long script is answered "suspect" instead of being scanned.
const MAX_SCRIPT_BYTES = 1024 * 1024;
const MAX_SCRIPT_DEPTH = 5;
const MAX_LOGICAL_LINES = 2000;

// scan-outbound.js scans the outbound content of these command families; it
// cannot be re-run cheaply here, so their presence alone is suspect.
const GIT_COMMIT_RE = /(?:^|[\s;|&])git\s+(?:-C\s+\S+\s+)?commit\b/;

// `bash <script>` nested inside the body — the script-to-script channel.
// /g plus the option skip so EVERY nested target on a line is enumerated.
// `-O`/`+O` take a shopt-name OPERAND, which would otherwise be read as the
// script and shift the real target out of the match.
const NESTED_FLAG = "(?:[-+]O\\s+[^\\s;|&]+|-[A-Za-z]+|--)\\s+";
const NESTED_SHELL = "(?:bash|sh)";
// A script needs no extension, so any path-shaped operand counts; `.sh` without a
// directory stays in for the relative spellings the old shape already caught.
const NESTED_TARGET =
  "(\"[^\"]+\"|'[^']+'|(?!-)[^\\s;|&]*[/\\\\][^\\s;|&]*|(?!-)[^\\s;|&]+\\.sh)";
// Any operand at all — no path shape required, so `bash evil` is enumerated too.
// Widening the operand this far is only safe at the COMMAND position: with the
// whitespace-tolerant anchor below it would read the word after a prose ` bash `
// as a script and answer every such comment line suspect.
const NESTED_TARGET_ANY = "(\"[^\"]+\"|'[^']+'|(?!-)[^\\s;|&<>]+)";
const NESTED_CMD_POS = "(?:^|[;|&(])\\s*";
const NESTED_SCRIPT_RE = new RegExp(
  "(?:^|[\\s;|&])" + NESTED_SHELL + "\\s+(?:" + NESTED_FLAG + "){0,8}" + NESTED_TARGET + "(?=[\\s;|&]|$)",
  "g",
);
const NESTED_BARE_RE = new RegExp(
  NESTED_CMD_POS + NESTED_SHELL + "\\s+(?:" + NESTED_FLAG + "){0,8}" + NESTED_TARGET_ANY + "(?=[\\s;|&]|$)",
  "g",
);
// `bash < script`: the child body arrives on stdin, so the script is the
// REDIRECT's operand and no arm above ever sees it.
const NESTED_STDIN_RE = new RegExp(
  NESTED_CMD_POS + NESTED_SHELL + "\\s*(?:" + NESTED_FLAG + "){0,8}<\\s*" + NESTED_TARGET_ANY + "(?=[\\s;|&]|$)",
  "g",
);
const NESTED_REGEXES = [NESTED_SCRIPT_RE, NESTED_BARE_RE, NESTED_STDIN_RE];

// Same class as scratchpad-script.js UNRESOLVABLE_CHARS: glob and brace forms
// let the shell rewrite the path after this scan resolved it.
const UNRESOLVABLE_CHARS_RE = /[$`*?[\]{}]/;

// Bash joins a line ending in an ODD number of backslashes with the next
// physical line. Scanning physical lines lets `winget \` + `  install jq` slip
// past every `(?:^|[\s;|&])`-anchored predicate below.
function toLogicalLines(text) {
  const physical = text.split(/\r?\n/);
  const out = [];
  let pending = null;
  for (const line of physical) {
    const current = pending === null ? line : pending + line;
    const trailing = /(\\+)$/.exec(current);
    if (trailing && trailing[1].length % 2 === 1) {
      pending = current.slice(0, -1);
      continue;
    }
    out.push(current);
    pending = null;
  }
  if (pending !== null) out.push(pending);
  return out;
}

// enforce-system-ops.js classifies the stripped form plus each `-c '<body>'` body
// it extracts, because the category regexes anchor on `(?:^|[\s;|&])` and a quote
// blocks that anchor. Blanking every quote reaches the same bodies — and any
// other quote-hidden command — without a second copy of that extractor's regex.
function hitsSystemOps(line) {
  const candidates = [line, stripQuotedArgs(line), line.replace(/['"]/g, " ")];
  return candidates.some((c) => getBlockCategory(c) !== null);
}

function lineIsSuspectInner(line) {
  if (hitsSystemOps(line)) return true;
  if (commandTouchesCredentials(line)) return true;
  if (commandTouchesDotenv(line)) return true;
  if (bashHitsClearance(line, {}) !== null) return true;
  if (isSentinel(line)) return true;
  if (CHAIN_BOUNDARY_SENTINEL_DQ_RE.test(line)) return true;
  if (CHAIN_BOUNDARY_SENTINEL_SQ_MARKER_RE.test(line)) return true;
  if (bashHitsMemory(line)) return true;
  if (bashHitsHistory(line)) return true;
  if (isForgeScanTarget(line) || GIT_COMMIT_RE.test(line)) return true;
  if (matchesBashDenyRule(line)) return true;
  if (matchesBashAskRule(line)) return true;
  if (commandInvokesUnrecognizedExec(line)) return true;
  if (commandIsEgressTool(line)) return true;
  const ir = parse(line);
  if (!ir || ir.parseFailure === true) return true;
  return detectWritePredicate(ir) !== null;
}

function lineIsSuspect(line) {
  if (line.trim() === "") return false;
  try {
    return lineIsSuspectInner(line);
  } catch (_e) {
    return true;
  }
}

// One entry per nested invocation on the line: "" when the target cannot be
// resolved (suspect), otherwise the nested script's realpath.
function nestedScriptTargets(line) {
  const out = [];
  // An operand of `echo`/`printf` is displayed, never run: without this the
  // scan opens `echo bash /abs/danger.sh`'s argument as a nested script.
  const scanned = maskDisplayOnlySegments(line);
  for (const re of NESTED_REGEXES) {
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(scanned)) !== null) {
      const raw = m[1].replace(/^["']/, "").replace(/["']$/, "");
      if (UNRESOLVABLE_CHARS_RE.test(raw) || !path.isAbsolute(raw)) {
        out.push("");
        continue;
      }
      try {
        const real = fs.realpathSync(raw);
        out.push(fs.statSync(real).isFile() ? real : "");
      } catch (_e) {
        out.push("");
      }
    }
  }
  return out;
}

function scanScript(realScript, state, depth) {
  if (depth > MAX_SCRIPT_DEPTH) return true;
  if (state.stack.has(realScript)) return true;
  if (state.done.has(realScript)) return false;
  let text;
  try {
    if (fs.statSync(realScript).size > MAX_SCRIPT_BYTES) return true;
    text = fs.readFileSync(realScript, "utf8");
  } catch (_e) {
    return true;
  }
  const lines = toLogicalLines(text);
  state.lines += lines.length;
  if (state.lines > MAX_LOGICAL_LINES) return true;
  if (textHoldsIndirectCredentialAccess(lines.join("\n"))) return true;
  state.stack.add(realScript);
  for (const line of lines) {
    if (lineIsSuspect(line)) return true;
    for (const nested of nestedScriptTargets(line)) {
      if (nested === "" || scanScript(nested, state, depth + 1)) return true;
    }
  }
  state.stack.delete(realScript);
  state.done.add(realScript);
  return false;
}

function scriptBodyIsSuspect(realScript) {
  try {
    return scanScript(realScript, { stack: new Set(), done: new Set(), lines: 0 }, 0);
  } catch (_e) {
    return true;
  }
}

module.exports = {
  scriptBodyIsSuspect,
  toLogicalLines,
  lineIsSuspect,
  MAX_SCRIPT_BYTES,
  MAX_SCRIPT_DEPTH,
};
