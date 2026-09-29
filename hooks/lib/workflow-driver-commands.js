// hooks/lib/workflow-driver-commands.js
// Recognises a command that DRIVES the workflow state machine forward, i.e. an
// advance-class CLI invoked with a state-mutating flag. #2102 moved the
// write_tests and research completion doors from a sentinel echo to that CLI
// form, so the subagent backstop needs a detector for the new door shape too.
// Matching is segment-, token- and path-segment-aware, never substring: the CLI
// must be the program the segment actually runs (`cat .../next-step --advance`
// is data), and a flag inside a quoted value drives nothing.
"use strict";

const path = require("path");

// CPR-SSOT: the advance-class roster is owned by record-step-verdict.js.
// Fail-open to an empty roster — an unloadable module must approve, not crash.
let ADVANCE_CLI_NAMES = [];
try {
  const { ADVANCE_ORIGINS } = require("../workflow-state/record-step-verdict");
  ADVANCE_CLI_NAMES = Object.keys(ADVANCE_ORIGINS || {});
} catch (e) {
  ADVANCE_CLI_NAMES = [];
}

// CPR-SSOT-adjacent: every next-step flag that settles a step verdict, per
// bin/workflow/lib/next-step/advance-args.js. --advance alone is not the door.
const MUTATING_FLAGS = ["--advance", "--mark", "--reset"];

const WORD_SEPARATORS = " \t";
const SEGMENT_SEPARATORS = ";|&()<>`\n\r";
// A backslash before one of these is genuine shell escaping; before anything
// else it is a Windows path separator that must survive tokenisation.
const ESCAPABLE = "\"'\\$" + WORD_SEPARATORS + SEGMENT_SEPARATORS;

// Shells whose <flag> <string> argument is another command to re-examine.
// PowerShell and cmd flag spellings are case-insensitive; POSIX -c is not.
const COMMAND_SHELLS = [
  { names: ["bash", "sh", "zsh", "dash", "ksh"], flags: ["-c"], ci: false },
  { names: ["pwsh", "powershell"], flags: ["-c", "-command"], ci: true },
  { names: ["cmd"], flags: ["/c", "/k"], ci: true },
];
// Programs that run their first non-flag argument as a script.
const INTERPRETERS = [
  "node", "bash", "sh", "zsh", "dash", "ksh", "python", "python3", "pwsh", "powershell",
];
// Wrappers that stand before the real program without being it.
const PREFIX_TOKENS = ["{", "!", "exec", "env", "sudo", "command", "nohup", "time", "eval"];
const ENV_ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=/;
const PATH_FRAGMENT = /[\\/:]/;
const MAX_DEPTH = 3;

// Quote-aware split into command segments of argv-like tokens. Quotes are
// consumed (so `"--advance"` yields the bare flag) but they still bind, so a
// quoted value stays ONE token and cannot masquerade as a standalone flag.
// Segments keep `;`/`|`/`&`/... boundaries, so a token's position within its own
// invocation is knowable.
function tokenizeSegments(command) {
  const segments = [];
  let tokens = [];
  let current = "";
  let started = false;
  let quote = "";
  const endToken = () => {
    if (started) tokens.push(current);
    current = "";
    started = false;
  };
  const endSegment = () => {
    endToken();
    if (tokens.length) segments.push(tokens);
    tokens = [];
  };
  for (let i = 0; i < command.length; i += 1) {
    const ch = command[i];
    if (quote) {
      if (ch === quote) quote = "";
      else current += ch;
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      started = true;
      continue;
    }
    if (ch === "\\" && i + 1 < command.length) {
      const next = command[i + 1];
      current += ESCAPABLE.indexOf(next) === -1 ? ch + next : next;
      started = true;
      i += 1;
      continue;
    }
    if (WORD_SEPARATORS.indexOf(ch) !== -1) {
      endToken();
      continue;
    }
    if (SEGMENT_SEPARATORS.indexOf(ch) !== -1) {
      endSegment();
      continue;
    }
    current += ch;
    started = true;
  }
  endSegment();
  return segments;
}

function baseName(token) {
  return path.basename(String(token).replace(/\\/g, "/")).replace(/\.exe$/i, "").toLowerCase();
}

function namesCli(token, names) {
  const segments = String(token).split(/[/\\]/);
  return segments.some((seg) => names.indexOf(seg.toLowerCase()) !== -1);
}

// A surviving backslash is a path separator everywhere else, but `\-\-advance`
// is still the flag once the shell has eaten the escapes.
function isMutatingFlag(token) {
  return MUTATING_FLAGS.indexOf(String(token).replace(/\\/g, "")) !== -1;
}

function headIndex(tokens) {
  let i = 0;
  while (i < tokens.length &&
         (ENV_ASSIGNMENT.test(tokens[i]) || PREFIX_TOKENS.indexOf(baseName(tokens[i])) !== -1)) {
    i += 1;
  }
  return i;
}

function isFlagLike(token) {
  return String(token).charAt(0) === "-";
}

// Where the program path may END. Usually the head token, but an unquoted path
// carrying a space arrives pre-split (`C:/Program Files/Git/usr/bin/node` is two
// tokens), so the path keeps growing while the fragment before it looks like one.
function programEnds(tokens, head) {
  const ends = [head];
  for (let i = head + 1; i < tokens.length; i += 1) {
    if (isFlagLike(tokens[i]) || !PATH_FRAGMENT.test(tokens[i - 1])) break;
    ends.push(i);
  }
  return ends;
}

// The named CLI must be the program this segment RUNS: the program itself, or
// the first non-flag argument of an interpreter. Named merely as an argument to
// something else (`cat .../next-step --advance`) it is data, not a door.
function invokesCli(tokens, names) {
  const head = headIndex(tokens);
  if (head >= tokens.length) return false;
  for (const end of programEnds(tokens, head)) {
    if (namesCli(tokens[end], names)) return true;
    if (INTERPRETERS.indexOf(baseName(tokens[end])) === -1) continue;
    for (let i = end + 1; i < tokens.length; i += 1) {
      if (isFlagLike(tokens[i])) continue;
      if (namesCli(tokens[i], names)) return true;
      break;
    }
  }
  return false;
}

function nestedCommands(tokens) {
  const nested = [];
  for (let i = 1; i + 1 < tokens.length; i += 1) {
    const name = baseName(tokens[i - 1]);
    const shell = COMMAND_SHELLS.find((s) => s.names.indexOf(name) !== -1);
    if (!shell) continue;
    const flag = shell.ci ? String(tokens[i]).toLowerCase() : tokens[i];
    if (shell.flags.indexOf(flag) !== -1) nested.push(tokens[i + 1]);
  }
  return nested;
}

function commandMatches(command, depth, segmentHits) {
  for (const tokens of tokenizeSegments(command)) {
    if (segmentHits(tokens)) return true;
    if (depth >= MAX_DEPTH) continue;
    // `bash -c '<command>'` (and pwsh -Command / cmd /c) hides a real invocation
    // one quoting level down; only a real shell's argument is re-examined, so
    // `echo "<text>"` stays data.
    for (const inner of nestedCommands(tokens)) {
      if (commandMatches(inner, depth + 1, segmentHits)) return true;
    }
  }
  return false;
}

function matchesSafely(command, segmentHits) {
  if (typeof command !== "string" || command === "") return false;
  try {
    return commandMatches(command, 0, segmentHits);
  } catch (e) {
    return false;
  }
}

function isWorkflowStateDriverCommand(command) {
  if (!ADVANCE_CLI_NAMES.length) return false;
  return matchesSafely(command, (tokens) => invokesCli(tokens, ADVANCE_CLI_NAMES) && tokens.some(isMutatingFlag));
}

// `record` trusts its caller-built classification file and completes run_tests as
// observed evidence, so bin/run-tests-baseline (a subprocess no hook sees) is its
// only legitimate caller; a tool-issued `record` would forge that evidence (#2431).
const BASELINE_EVIDENCE_CLI = ["run-tests-baseline-evidence"];
const BASELINE_RECORD_SUBCOMMAND = "record";

function isBaselineEvidenceRecordCommand(command) {
  return matchesSafely(command, (tokens) =>
    invokesCli(tokens, BASELINE_EVIDENCE_CLI) &&
    tokens.some((t) => String(t).replace(/\\/g, "") === BASELINE_RECORD_SUBCOMMAND));
}

module.exports = { isWorkflowStateDriverCommand, isBaselineEvidenceRecordCommand };
