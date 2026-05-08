#!/usr/bin/env node
// Claude Code PreToolUse hook: block access to .env files and .private-info-allowlist
// Matches: Bash, Read, Grep, Glob, Edit, Write, MultiEdit tools
// Allows: .env.example, .env.sample, .env.template, .env.dist

const fs = require("fs");

// Read stdin (cross-platform: fs.readSync for Windows compatibility)
function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const bytesRead = fs.readSync(0, buf, 0, buf.length);
      if (bytesRead === 0) break;
      chunks.push(buf.slice(0, bytesRead));
    }
  } catch (e) {
    // EOF or error
  }
  return Buffer.concat(chunks).toString("utf8");
}

function approve() {
  console.log(JSON.stringify({ decision: "approve" }));
  process.exit(0);
}

function block(reason) {
  console.log(JSON.stringify({ decision: "block", reason }));
  process.exit(0);
}

// Suffixes that are safe to access (documentation/template files)
const SAFE_SUFFIXES = [".env.example", ".env.sample", ".env.template", ".env.dist"];

// Flags whose VALUE is text (not a path). The token after these is skipped.
//
// Single-letter short forms `-l`, `-a`, `-r`, `-c` are intentionally OMITTED
// even though gh/git accept them, because they collide with very common Unix
// flags (`wc -l file`, `ls -a dir`, `cp -r src dst`, `bash -c script`) and
// would create read/write bypasses for `.env`. Users must use the long form
// (`--label`, `--assignee`, `--reviewer`) when targeting gh from this hook's
// scope. `-c` is handled separately via shell-wrapper recursion (SHELL_BINS).
//
// `-m` is kept (highly common for `git commit -m`, `gh pr create -m`); its
// value is text not a path, and `-m .env` as a literal git-commit message
// happens to be safe — it's a message string, not a file access.
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

// Redirect operators: the next token is the redirect target (a path).
// Matches: >, >>, 1>, 1>>, 2>, 2>>, &>, &>>, <, <<<
const REDIRECT_RE = /^(?:\d?>>?|&>>?|<<<|<)$/;

// Shell-wrapper basenames whose `-c <script>` value is parsed recursively.
const SHELL_BINS = new Set(["bash", "sh", "dash", "zsh", "ksh"]);

// Commands whose positional arguments are message text, not paths.
// Without this exemption, `echo "copy .env to prod"` would tokenize to `.env`
// and incorrectly block.
const TEXT_CMDS = new Set(["echo", "printf"]);

function isSafeDotenv(name) {
  return SAFE_SUFFIXES.some((s) => name.endsWith(s));
}

// Check if a path's basename is a .env file (not a safe variant)
// Matches: .env, .env.local, .env.production, etc.
// Does NOT match: .envrc, .environment, envconfig.js, etc.
function isDotenvPath(filePath) {
  if (!filePath) return false;
  // Normalize to forward slashes and get basename
  const basename = filePath.replace(/\\/g, "/").split("/").pop();
  if (!basename) return false;
  // Exact .env
  if (basename === ".env") return true;
  // .env.xxx but not .envrc, .environment, etc.
  if (basename.startsWith(".env.")) return !isSafeDotenv(basename);
  return false;
}

// Strip $(...) and `...` command substitutions and `<<EOF...EOF` heredoc
// bodies. These constructs carry message text, not paths — removing them
// before tokenization avoids treating message content as command tokens.
function stripSubstitutions(cmd) {
  let out = cmd;
  // $(...) — iterate to handle nested
  let prev;
  do { prev = out; out = out.replace(/\$\([^()]*\)/g, ""); } while (out !== prev);
  // `...` backtick command substitution
  out = out.replace(/`[^`]*`/g, "");
  // <<EOF ... EOF / <<-EOF ... EOF / <<'EOF' ... EOF / <<"EOF" ... EOF
  out = out.replace(/<<-?\s*['"]?(\w+)['"]?[\s\S]*?\n\s*\1\s*(?:\n|$)/g, "");
  return out;
}

// Quote-aware tokenizer: respects "...", '...', $'...'. Returns UNQUOTED
// tokens (outer quotes stripped). Backslash-escapes inside double quotes are
// honored.
function tokenizeSegment(seg) {
  const tokens = [];
  let i = 0;
  const n = seg.length;
  while (i < n) {
    while (i < n && /\s/.test(seg[i])) i++;
    if (i >= n) break;
    let tok = "";
    while (i < n && !/\s/.test(seg[i])) {
      const ch = seg[i];
      if (ch === '"') {
        i++;
        while (i < n && seg[i] !== '"') {
          if (seg[i] === "\\" && i + 1 < n) { tok += seg[i + 1]; i += 2; }
          else { tok += seg[i]; i++; }
        }
        if (i < n) i++;
      } else if (ch === "'") {
        i++;
        while (i < n && seg[i] !== "'") { tok += seg[i]; i++; }
        if (i < n) i++;
      } else if (ch === "$" && seg[i + 1] === "'") {
        i += 2;
        while (i < n && seg[i] !== "'") {
          if (seg[i] === "\\" && i + 1 < n) { tok += seg[i + 1]; i += 2; }
          else { tok += seg[i]; i++; }
        }
        if (i < n) i++;
      } else {
        tok += ch;
        i++;
      }
    }
    tokens.push(tok);
  }
  return tokens;
}

// Split cmd on UNQUOTED shell separators: && || ; | & ( )
function splitSegments(cmd) {
  const segs = [];
  let cur = "";
  let i = 0;
  const n = cmd.length;
  const flush = () => { const s = cur.trim(); if (s) segs.push(s); cur = ""; };
  while (i < n) {
    const ch = cmd[i];
    if (ch === '"') {
      cur += ch; i++;
      while (i < n && cmd[i] !== '"') {
        if (cmd[i] === "\\" && i + 1 < n) { cur += cmd[i] + cmd[i + 1]; i += 2; }
        else { cur += cmd[i]; i++; }
      }
      if (i < n) { cur += cmd[i]; i++; }
    } else if (ch === "'") {
      cur += ch; i++;
      while (i < n && cmd[i] !== "'") { cur += cmd[i]; i++; }
      if (i < n) { cur += cmd[i]; i++; }
    } else if (ch === "$" && cmd[i + 1] === "'") {
      cur += "$'"; i += 2;
      while (i < n && cmd[i] !== "'") {
        if (cmd[i] === "\\" && i + 1 < n) { cur += cmd[i] + cmd[i + 1]; i += 2; }
        else { cur += cmd[i]; i++; }
      }
      if (i < n) { cur += cmd[i]; i++; }
    } else if ((ch === "&" && cmd[i + 1] === "&") || (ch === "|" && cmd[i + 1] === "|")) {
      flush(); i += 2;
    } else if (ch === ";" || ch === "|" || ch === "&" || ch === "(" || ch === ")") {
      flush(); i += 1;
    } else {
      cur += ch; i++;
    }
  }
  flush();
  return segs;
}

// Extract bodies of $(...) and `...` command substitutions for recursive
// inspection. Substitutions execute as shell commands, so their contents must
// be analyzed even though stripSubstitutions removes them from tokenization.
function extractSubstitutionContents(cmd) {
  const out = [];
  const dollarParen = /\$\(([^()]*)\)/g;
  let m;
  while ((m = dollarParen.exec(cmd)) !== null) out.push(m[1]);
  const backtick = /`([^`]*)`/g;
  while ((m = backtick.exec(cmd)) !== null) out.push(m[1]);
  return out;
}

// Walk argv of one segment, applying redirect / TEXT_FLAGS / PATH_FLAGS /
// positional rules. Returns true iff any token in path position resolves to a
// blocked .env path.
function segmentBlocksDotenv(segment) {
  const tokens = tokenizeSegment(segment);
  if (tokens.length === 0) return false;

  // First pass: check redirect targets independent of cmd0 — `echo > .env`,
  // `printf "x" >> .env.production` must block even though echo/printf are
  // text-positional commands. Redirects are syntax-attached, not positional.
  for (let k = 0; k < tokens.length - 1; k++) {
    if (REDIRECT_RE.test(tokens[k]) && isDotenvPath(tokens[k + 1])) {
      return true;
    }
  }

  const cmd0 = tokens[0];
  const cmdBase = cmd0.replace(/\\/g, "/").split("/").pop();

  // echo/printf: positional args are message text. Redirects already checked above.
  if (TEXT_CMDS.has(cmdBase)) return false;

  // Shell wrapper recursion: `bash -c "<script>"`, `bash -lc "<script>"`,
  // `sh -ic "<script>"` etc. Combined short flags must also recurse.
  if (SHELL_BINS.has(cmdBase)) {
    let hasCFlag = false;
    let scriptIdx = -1;
    for (let k = 1; k < tokens.length; k++) {
      const tok = tokens[k];
      if (tok.startsWith("-")) {
        // Match `-c` exactly OR a combined short flag containing `c`
        // (e.g. -lc, -ic, -Oc) — bash's POSIX/login/interactive flag forms.
        if (tok === "-c" || /^-[a-zA-Z]*c[a-zA-Z]*$/.test(tok)) hasCFlag = true;
        continue;
      }
      scriptIdx = k;
      break;
    }
    if (hasCFlag && scriptIdx >= 0) {
      return checkBashCommand(tokens[scriptIdx]);
    }
    return false;
  }

  for (let k = 1; k < tokens.length; k++) {
    const t = tokens[k];

    if (REDIRECT_RE.test(t)) {
      // Already detected above; skip the target token to keep argv walking sane.
      k += 1;
      continue;
    }

    if (TEXT_FLAGS.has(t)) {
      k += 1; // skip the value: it's text
      continue;
    }

    if (PATH_FLAGS.has(t)) {
      const next = tokens[k + 1];
      if (next && isDotenvPath(next)) return true;
      k += 1;
      continue;
    }

    if (t.startsWith("-")) {
      continue; // unknown flag — skip the flag itself only
    }

    // Positional argument: check as a path
    if (isDotenvPath(t)) return true;
  }

  return false;
}

// Path-position parser: tokenize the command, walk argv, check only tokens at
// path-bearing positions. Replaces the previous strip-then-regex approach;
// text-flag values (-m, --body, --title, etc.) are skipped by construction so
// `gh pr create --body "Fix .env hook"` and `git commit -m "..."` are no
// longer false-positives.
//
// Substitutions ($(...) and backticks) are recursed into BEFORE stripping,
// because they execute as shell commands — `gh pr create --body "$(cat .env)"`
// must block.
function checkBashCommand(command) {
  if (!command) return false;
  // Recurse into command substitution bodies first (they execute as shell).
  for (const sub of extractSubstitutionContents(command)) {
    if (checkBashCommand(sub)) return true;
  }
  const stripped = stripSubstitutions(command);
  const segs = splitSegments(stripped);
  return segs.some(segmentBlocksDotenv);
}

function isAllowlistPath(filePath) {
  if (!filePath) return false;
  const basename = filePath.replace(/\\/g, "/").split("/").pop();
  return basename === ".private-info-allowlist";
}

// For Glob patterns: detect .env search patterns
function checkGlobPattern(pattern) {
  if (!pattern) return false;
  const basename = pattern.replace(/\\/g, "/").split("/").pop();
  if (!basename) return false;

  // Wildcarded .env patterns
  if (basename === ".env" || basename === ".env.*" || basename === ".env*") return true;
  // Specific .env.xxx — check if safe
  if (basename.startsWith(".env.")) return !isSafeDotenv(basename);
  return false;
}

// Parse stdin
let input;
try {
  input = JSON.parse(readStdin());
} catch (e) {
  // Invalid JSON — approve (fail-open for non-matching input)
  approve();
}

const toolName = input.tool_name;
const toolInput = input.tool_input || {};

switch (toolName) {
  case "Bash":
    if (checkBashCommand(toolInput.command)) {
      block("Access to .env files is blocked. Use .env.example for documentation.");
    }
    break;

  case "Read":
    if (isDotenvPath(toolInput.file_path)) {
      block("Reading .env files is blocked. Use .env.example for documentation.");
    }
    break;

  case "Grep":
    if (isDotenvPath(toolInput.path) || checkGlobPattern(toolInput.glob)) {
      block("Searching .env files is blocked. Use .env.example for documentation.");
    }
    break;

  case "Glob":
    if (checkGlobPattern(toolInput.pattern)) {
      block("Searching for .env files is blocked.");
    }
    break;

  case "Edit":
  case "Write":
  case "MultiEdit":
    if (isDotenvPath(toolInput.file_path)) {
      block("Writing .env files is blocked. Use .env.example for documentation.");
    }
    if (isAllowlistPath(toolInput.file_path)) {
      block("Writing .private-info-allowlist is blocked. Edit manually if an exception is genuinely needed.");
    }
    break;

  default:
    break;
}

approve();
