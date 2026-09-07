// Pure .env / protected-blocklist path detection. Consumer:
// hooks/block-dotenv.js.
"use strict";

const {
  checkBashCommand: checkCmd,
  stripSubstitutions,
  splitSegments,
  tokenizeSegment,
  extractSubstitutionContents,
} = require("./command-parser");
const { getBasename } = require("./path-match");

// Suffixes that are safe to access (documentation/template files)
const SAFE_SUFFIXES = [".env.example", ".env.sample", ".env.template", ".env.dist"];

// Flags whose VALUE is text (not a path); the token after them is skipped.
// Short forms -l/-a/-r/-c are deliberately absent: they collide with common
// Unix flags (`wc -l`, `cp -r`, `bash -c`) and would open a `.env` bypass.
// `-c` is handled instead by shell-wrapper recursion (SHELL_BINS).
const TEXT_FLAGS = new Set([
  "-m", "--message",
  "--body", "--title", "--notes", "--description", "--subject",
  "--branch",
  "--label",
  "--assignee",
  "--reviewer",
  "--milestone", "--project",
  "--head", "--base",
  "--config",
]);

// Flags whose VALUE is a path. The token after is checked with isDotenvPath.
const PATH_FLAGS = new Set([
  "-f", "--file",
  "-o", "--output",
  "-i", "--input",
  "--from-file", "--to-file",
  "-T", "--upload-file",
]);

// Shell-wrapper basenames whose `-c <script>` value is parsed recursively.
const SHELL_BINS = new Set(["bash", "sh", "dash", "zsh", "ksh"]);

// Commands whose positional arguments are message text, not paths.
// Without this exemption, `echo "copy .env to prod"` would tokenize to `.env`
// and incorrectly block.
const TEXT_CMDS = new Set(["echo", "printf"]);

function isSafeDotenv(name) {
  return SAFE_SUFFIXES.some((s) => name.endsWith(s));
}

// Matches .env, .env.local, .env.production; not .envrc, .environment.
function isDotenvPath(filePath) {
  if (!filePath) return false;
  const basename = getBasename(filePath);
  if (!basename) return false;
  if (basename === ".env") return true;
  if (basename.startsWith(".env.")) return !isSafeDotenv(basename);
  return false;
}

// Path-position parser: only tokens at path-bearing positions are checked, so
// text-flag values are skipped by construction. Substitutions are recursed
// into before stripping — `gh pr create --body "$(cat .env)"` must block.
function checkBashCommand(command) {
  return checkCmd(command, {
    isTargetPath: isDotenvPath,
    textFlags: TEXT_FLAGS,
    pathFlags: PATH_FLAGS,
    textCmds: TEXT_CMDS,
    shellBins: SHELL_BINS,
  });
}

// env-effective-kv --allow-dump prints every key AND value of the resolved
// config map, so a direct Bash-tool call to it is a .env read by another name.
// The tool is matched by basename and the flag by exact token, both within one
// invocation, so an unrelated tool carrying --allow-dump stays allowed.
const ALLOW_DUMP_BIN = "env-effective-kv";
const ALLOW_DUMP_FLAG = "--allow-dump";

function commandBasename(token) {
  return String(token).replace(/\\/g, "/").split("/").pop();
}

// True when tokens[k] is `-c` or a combined short flag containing `c` (-lc, -ic).
function isShellCFlag(token) {
  return token === "-c" || /^-[a-zA-Z]*c[a-zA-Z]*$/.test(token);
}

// One segment: `env-effective-kv ... --allow-dump`, either as cmd0 or as the
// script argument of a shell wrapper (`bash bin/env-effective-kv --allow-dump`).
// A wrapper's `-c` body is a script, not a path, so it recurses instead.
function segmentDumpsEnv(segment) {
  const tokens = tokenizeSegment(segment);
  if (tokens.length === 0) return false;
  let target = commandBasename(tokens[0]);
  if (SHELL_BINS.has(target)) {
    let hasCFlag = false;
    let scriptIdx = -1;
    for (let k = 1; k < tokens.length; k++) {
      if (tokens[k].startsWith("-")) {
        if (isShellCFlag(tokens[k])) hasCFlag = true;
        continue;
      }
      scriptIdx = k;
      break;
    }
    if (hasCFlag && scriptIdx >= 0) return checkAllowDumpCommand(tokens[scriptIdx]);
    if (scriptIdx < 0) return false;
    target = commandBasename(tokens[scriptIdx]);
  }
  if (target !== ALLOW_DUMP_BIN) return false;
  return tokens.some((t) => t === ALLOW_DUMP_FLAG);
}

// Substitution bodies execute as shell, so they are recursed into first —
// the same order checkBashCommand uses.
function checkAllowDumpCommand(command) {
  if (!command) return false;
  for (const sub of extractSubstitutionContents(command)) {
    if (checkAllowDumpCommand(sub)) return true;
  }
  return splitSegments(stripSubstitutions(command)).some(segmentDumpsEnv);
}

function isProtectedPath(filePath) {
  if (!filePath) return false;
  const basename = getBasename(filePath);
  return basename === ".private-info-allowlist" || basename === ".offensive-content-blocklist";
}

// For Glob patterns: detect .env search patterns
function checkGlobPattern(pattern) {
  if (!pattern) return false;
  const basename = getBasename(pattern);
  if (!basename) return false;
  if (basename === ".env" || basename === ".env.*" || basename === ".env*") return true;
  if (basename.startsWith(".env.")) return !isSafeDotenv(basename);
  return false;
}

// codegraph_explore is Read-equivalent: it returns verbatim source for whatever its
// free-text `query` names, so every token in the query is treated as a candidate
// path and checked exactly as a Read path would be.
function checkExploreQuery(query) {
  if (typeof query !== "string" || !query) return false;
  return query
    .split(/[\s,;:'"`()[\]{}<>]+/)
    .filter(Boolean)
    .some((token) => isDotenvPath(token) || checkGlobPattern(token));
}

module.exports = {
  SAFE_SUFFIXES,
  TEXT_FLAGS,
  PATH_FLAGS,
  SHELL_BINS,
  TEXT_CMDS,
  isSafeDotenv,
  isDotenvPath,
  checkBashCommand,
  checkAllowDumpCommand,
  isProtectedPath,
  checkGlobPattern,
  checkExploreQuery,
};
