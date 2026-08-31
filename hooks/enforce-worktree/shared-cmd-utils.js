"use strict";

const path = require("path");
const { normalizeCwd } = require("../lib/path-normalize");
const { parseExcludePatterns } = require("../lib/glob-match");
const { isCoveredByEntryList } = require("../lib/path-coverage-match");
const { stripQuotedArgs, stripHeredocBody } = require("../lib/strip-quoted-args");
const { parse } = require("../lib/command-ir");

// Built-in exclude patterns: always merged with ENFORCE_WORKTREE_EXCLUDE. Users
// cannot disable these — set ENFORCE_WORKTREE=off session-scoped if needed.
// .worktree-backup/**: lets /worktree-end Step WE-8 stage gitignored backups even
// when Bash CWD has reset to the main worktree.
const BUILTIN_EXCLUDE_PATTERNS = Object.freeze(["**/.worktree-backup/**"]);

// True if cmd contains shell chaining/pipe operators outside of quotes, or a
// command substitution ($()/backtick) — a substitution spawns a shell that
// runs the inner command, effectively chaining for exemption-allowance
// purposes (blocks `git merge --ff-only $(rm -rf /)`). fd-dup redirects
// (2>&1 etc.) are excluded via the IR parser's fd-dup lookahead. Bare `&`
// also matches PowerShell's call operator, so `& git.exe ...` is
// conservatively rejected too.
function hasShellChaining(cmd) {
  if (!cmd || typeof cmd !== "string") return false;
  const ir = parse(cmd);
  if (ir.parseFailure) return true; // fail-closed
  // Use separators (not segment count) so leading/trailing operators are caught:
  // `& git.exe status` and `git pull &` each produce 1 segment but 1 separator.
  if (ir.separators.length > 0) return true;
  return /\$\(|`/.test(stripQuotedArgs(cmd));
}

function rejectRceGitFlags(cmd) {
  if (!cmd || typeof cmd !== "string") return false;
  if (/(^|\s)-c(\s|$)/.test(cmd)) return true;
  if (/(^|\s)--upload-pack(?:=|\s)/.test(cmd)) return true;
  if (/(^|\s)--receive-pack(?:=|\s)/.test(cmd)) return true;
  return false;
}

function rejectInterpreterAndChaining(cmd) {
  if (!cmd || typeof cmd !== "string") return false;
  const INTERP_NAMES = "bash|sh|zsh|dash|fish|pwsh|powershell|cmd|node|python\\d*|perl|ruby";
  const ENV_PREFIX   = "(?:[A-Za-z_][A-Za-z0-9_]*=\\S*\\s+)*";
  const LAUNCHER_CHAIN = "(?:(?:env|command|exec|sudo)\\s+)*";
  const OPT_PATH     = "(?:/[^\\s]*/|\\\\\\\\[^\\s\\\\]+\\\\(?:[^\\s\\\\]+\\\\)*)?";
  // Match at string start: optional env prefix, optional launcher chain, optional path prefix, then interpreter name
  const startRe = new RegExp(
    `^\\s*${ENV_PREFIX}${LAUNCHER_CHAIN}${OPT_PATH}(?:${INTERP_NAMES})\\b`
  );
  if (startRe.test(cmd)) return true;
  // Match after shell separator: path-qualified interpreter after ; | & or newline
  const sepPathRe = new RegExp(
    `(?:^|[;|&\\n])\\s*(?:/[^\\s]*/|\\\\\\\\[^\\s\\\\]+\\\\(?:[^\\s\\\\]+\\\\)*)(?:${INTERP_NAMES})\\b`
  );
  if (sepPathRe.test(cmd)) return true;
  // IR-based chaining gate: newlines and substitutions checked first, then IR segment count.
  if (/\n/.test(cmd)) return true;
  const stripped = stripQuotedArgs(cmd);
  if (/\$\(|`|<\(|>\(/.test(stripped)) return true;
  const ir = parse(cmd);
  if (ir.parseFailure) return true; // fail-closed
  // Use separators (not segment count) so leading/trailing operators are caught.
  if (ir.separators.length > 0) return true;
  return false;
}

/**
 * Returns the index of the first unquoted `&&` in cmd, or -1 if none.
 * Tracks single- and double-quote state so `&&` inside quoted paths is ignored.
 *
 * Note: does not track backslash escapes. This matches the same simplification
 * used by hasShellChaining / stripQuotedArgs — acceptable for a UX guard.
 */
function findFirstUnquotedAnd(cmd) {
  let inSingle = false, inDouble = false;
  for (let i = 0; i < cmd.length - 1; i++) {
    const c = cmd[i];
    if (c === "'" && !inDouble) { inSingle = !inSingle; continue; }
    if (c === '"' && !inSingle) { inDouble = !inDouble; continue; }
    if (!inSingle && !inDouble && c === "&" && cmd[i + 1] === "&") return i;
  }
  return -1;
}

// True when cmd contains command-sequencing operators (;, &&, ||) outside quotes
// AND outside a heredoc body (stripped first, so shell fragments inside a
// `cat <<'EOF'` write are not treated as real sequencing — #2121). Single |
// (pipe) is excluded — needed for `cmd | tee file`. Uses IR separators so
// fd-dup redirects (2>&1 etc.) are never misclassified as chaining.
// Commands with sequencing must not be fast-pathed through the session-scope
// allow: the un-extracted portion may contain in-scope writes (e.g. rm, mv).
function hasCommandSequencing(cmd) {
  if (!cmd || typeof cmd !== "string") return false;
  const ir = parse(stripHeredocBody(cmd));
  if (ir.parseFailure) return true; // fail-closed
  return ir.separators.some((s) => s === ";" || s === "&&" || s === "||");
}

// Alias kept for call-site compatibility: hasCommandSequencing is itself
// heredoc-aware now, so this is equivalent.
function hasCommandSequencingOutsideHeredoc(cmd) {
  return hasCommandSequencing(cmd);
}

// True when cmd contains a heredoc opener (`<<`/`<<-`, optionally quoted tag),
// detected independently of stripHeredocBody(). That function deliberately
// REFUSES to strip the most dangerous shapes (interpreter heredocs, $()/backtick
// bodies, pipe-chained sinks); this predicate must still report true for those so
// callers route them through the narrow plans-dir/scratchpad gate (Guard 6)
// instead of the broad outside-session-scope allow (Guard 5) — #2120/#2121
// security review r2 (F2). Tested against the RAW command: stripQuotedArgs
// blanks a quoted tag (`<<'EOF'` -> `<<''`) and would hide the opener, and
// true routes to the NARROWER gate, so over-matching here is the safe side.
const HEREDOC_OPENER_RE = /<<-?\s*(['"]?)[A-Za-z_][A-Za-z0-9_.-]*\1/;

function hasHeredoc(cmd) {
  if (typeof cmd !== "string") return false;
  return HEREDOC_OPENER_RE.test(cmd);
}

/**
 * True when targetPath resolves to a location OUTSIDE repoRoot.
 * Relative paths are resolved against process.cwd() (the main worktree when
 * this hook runs), which gives the correct semantic for worktree paths.
 * Fails open (returns true) when the path cannot be resolved.
 */
function isPathOutsideRepo(targetPath, repoRoot) {
  try {
    // Normalize POSIX drive-letter paths (a slash-c-slash prefix) to Windows
    // native form before path.resolve, which on Windows otherwise misresolves them
    // to C:\c\git\foo. No-op on non-Windows and on already-native paths.
    const normTarget = normalizeCwd(targetPath) || targetPath;
    const normBase = normalizeCwd(repoRoot) || repoRoot;
    const resolved = path.resolve(normTarget).toLowerCase();
    const base = path.resolve(normBase).toLowerCase();
    return resolved !== base &&
           !resolved.startsWith(base + path.sep) &&
           !resolved.startsWith(base + "/");
  } catch (e) {
    return true; // fail-open
  }
}

function hasWorktreeEndSkillPrefix(cmd) {
  return /^WORKTREE_END_SKILL=1\s/.test(cmd);
}

function stripWorktreeEndSkillPrefix(cmd) {
  return cmd.replace(/^WORKTREE_END_SKILL=1[ \t]+/, "");
}

function getExcludePatterns() {
  const user = parseExcludePatterns(process.env.ENFORCE_WORKTREE_EXCLUDE || "");
  return BUILTIN_EXCLUDE_PATTERNS.concat(user);
}

function isExcluded(filePath, patterns) {
  if (!patterns || patterns.length === 0) return false;
  if (!filePath || typeof filePath !== "string") return false;
  try {
    const norm = normalizeCwd(filePath) || filePath;
    const abs = path.resolve(norm);
    // Delegate each entry to the unified path-coverage matcher. getExcludePatterns()
    // returns a string[] (BUILTIN + user); pass each entry as a single-element list
    // so per-entry glob/prefix dispatch is preserved and the array interface is kept.
    for (const entry of patterns) {
      if (!entry) continue;
      if (isCoveredByEntryList(entry, abs)) return true;
      // Gitignore basename semantics: an entry without '/' also matches the basename.
      if (!entry.includes("/") && isCoveredByEntryList(entry, path.basename(abs))) return true;
    }
    return false;
  } catch (e) { return false; }
}

module.exports = {
  hasShellChaining,
  findFirstUnquotedAnd,
  hasCommandSequencing,
  hasCommandSequencingOutsideHeredoc,
  hasHeredoc,
  isPathOutsideRepo,
  isExcluded,
  getExcludePatterns,
  hasWorktreeEndSkillPrefix,
  stripWorktreeEndSkillPrefix,
  rejectRceGitFlags,
  rejectInterpreterAndChaining,
  BUILTIN_EXCLUDE_PATTERNS,
};
