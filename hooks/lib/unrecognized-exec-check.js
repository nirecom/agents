// commandInvokesUnrecognizedExec(line) — true when a line hands execution to an
// interpreter or executable this repo's Bash guards never inspect: `node x.js`,
// `python3 x.py`, `npx pkg`, `sh -c '...'`, `. ./x`, `/tmp/evil`, `./evil`,
// `pwsh x.ps1`, `evil.exe`, `eval "$CMD"`, `zsh x.sh`.
// Consumer: hooks/preuse-auto-approve/script-body-scan.js — `bash <script>.sh`
// is the only invocation form that scan can follow, so every other execution
// channel inside a body is answered suspect rather than auto-approved.
"use strict";

const { WRAPPER_SPECS } = require("./bash-write-patterns/segment-utils");
const { maskDisplayOnlySegments } = require("./display-only-mask");

// Command position: line start or immediately after a separator. Required for
// the path forms, where a plain whitespace anchor would match `cd /tmp`.
const CMD_POS = "(?:^|[;|&(])\\s*";
// A no-op wrapper builtin occupies CMD_POS without changing what runs, so
// `command eval …` / `env -i node …` must read as the wrapped command. Names come
// from the WRAPPER_SPECS SSOT; repetition is bounded to keep backtracking linear.
const WRAPPER_NAMES = Object.keys(WRAPPER_SPECS).join("|");
const WRAPPER_PREFIX =
  "(?:(?:" + WRAPPER_NAMES + ")(?:\\s+(?:-[A-Za-z-]+|[A-Za-z_][A-Za-z0-9_]*=[^\\s;|&]*)){0,8}\\s+){0,3}";
// Every rule below anchors on CMD_POS (plus wrappers), never plain whitespace, so
// an interpreter NAME in data position — `echo node foo` — stays data.
const CMD_POS_W = CMD_POS + WRAPPER_PREFIX;

// A directory prefix may be quoted: on Windows a space-bearing path REQUIRES
// quoting, so a class that stops at `"` would hide the only runnable spelling.
const DQ_DIR = "(?:[^\"]*[\\\\/])?";
const SQ_DIR = "(?:[^']*[\\\\/])?";
const UNQ_DIR = "(?:[^\\s;|&'\"]*[\\\\/])?";
const PWSH_NAME = "(?:pwsh|powershell)(?:\\.exe)?";
// `bash`/`sh` are ABSENT here on purpose: script-body-scan.js follows those two
// into the child script. No scanner follows zsh/dash/ksh — their syntax is not
// bash's — so handing a script to one of them is an unrecognized channel.
const ALT_SHELL_NAME = "(?:zsh|dash|ksh)(?:\\.exe)?";

const INTERPRETER_RE = new RegExp(
  CMD_POS_W + "(?:node|nodejs|python|python3|npx|pnpx|bunx|ruby|perl|source)(?=\\s|$)",
);
const SUBSHELL_C_RE = /(?:^|[\s;|&(])(?:ba|z|k|da)?sh\s+-[a-zA-Z]*c(?=\s|$)/;
const DOT_SOURCE_RE = new RegExp(CMD_POS_W + "\\.\\s+\\S");
const DIRECT_EXEC_RE = new RegExp(CMD_POS_W + "(?:\\.{1,2})?/[^\\s;|&]");
const PWSH_RE = new RegExp(
  CMD_POS_W + "(?:" + UNQ_DIR + PWSH_NAME + "|\"" + DQ_DIR + PWSH_NAME + "\"|'" + SQ_DIR + PWSH_NAME + "')(?=\\s|$)",
  "i",
);
const BARE_EXE_RE = new RegExp(
  CMD_POS_W + "(?:[^\\s;|&'\"]*\\.exe|\"[^\"]*\\.exe\"|'[^']*\\.exe')(?=\\s|$)",
  "i",
);
const EVAL_RE = new RegExp(CMD_POS_W + "eval(?=\\s|$)");
// Same three quoting arms as PWSH_RE: a directory-qualified `/bin/zsh` and the
// quoted spellings are the same channel as the bare name.
const ALT_SHELL_RE = new RegExp(
  CMD_POS_W +
    "(?:" + UNQ_DIR + ALT_SHELL_NAME + "|\"" + DQ_DIR + ALT_SHELL_NAME + "\"|'" + SQ_DIR + ALT_SHELL_NAME + "')(?=\\s|$)",
  "i",
);

function commandInvokesUnrecognizedExec(line) {
  if (typeof line !== "string" || line === "") return false;
  // SUBSHELL_C_RE keeps a whitespace-tolerant anchor so `xargs sh -c …` and the
  // other non-wrapper prefixes stay caught; masking the display-only segments
  // first is what separates that from `echo sh -c …`, which runs nothing.
  const scanned = maskDisplayOnlySegments(line);
  return (
    INTERPRETER_RE.test(scanned) ||
    SUBSHELL_C_RE.test(scanned) ||
    DOT_SOURCE_RE.test(scanned) ||
    DIRECT_EXEC_RE.test(scanned) ||
    PWSH_RE.test(scanned) ||
    BARE_EXE_RE.test(scanned) ||
    EVAL_RE.test(scanned) ||
    ALT_SHELL_RE.test(scanned)
  );
}

module.exports = { commandInvokesUnrecognizedExec };
