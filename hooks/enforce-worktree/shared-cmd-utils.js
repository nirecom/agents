"use strict";

const path = require("path");
const { normalizeCwd } = require("../lib/path-normalize");
const { parseExcludePatterns, matchesAnyExcludePattern } = require("../lib/glob-match");
const { stripQuotedArgs, stripHeredocBody } = require("../lib/strip-quoted-args");

// Built-in exclude patterns: always merged with ENFORCE_WORKTREE_EXCLUDE. Users
// cannot disable these — set ENFORCE_WORKTREE=off session-scoped if needed.
// .worktree-backup/**: lets /worktree-end Step WE-8 stage gitignored backups even
// when Bash CWD has reset to the main worktree.
const BUILTIN_EXCLUDE_PATTERNS = Object.freeze(["**/.worktree-backup/**"]);

/** True if cmd contains shell chaining/pipe operators outside of quotes.
 *  Also rejects command substitutions ($() and backticks): those spawn a
 *  shell that runs the inner command, which is effectively chaining for
 *  exemption-allowance purposes. Without this, `git merge --ff-only $(rm -rf
 *  /)` would slip past the chaining guard.
 *  POSIX fd-dup redirects (`2>&1`, `1>&2`, `>&2`, `N>&-`, `>&-`) are stripped
 *  before the chaining test — their `&` is a file-descriptor duplication, not a
 *  chaining operator. `&>` / `&>>` (redirect-both-to-file) are intentionally
 *  NOT stripped: they are file write targets that collectBashWriteTargets must
 *  see (the leading bare `&` is preserved so it still trips the guard).
 *  Note: bare `&` also matches PowerShell's call operator (& git.exe ...),
 *  so `& git.exe worktree add` is conservatively rejected. */
function hasShellChaining(cmd) {
  const stripped = stripQuotedArgs(cmd).replace(/\d*>&\d+|\d*>&-/g, " ");
  return /[|;&]|\$\(|`/.test(stripped);
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
  // Belt-and-braces stripped-gate: operator detection after SQ body collapse.
  // fd-dup redirects (2>&1 etc.) stripped first — their `&` is not chaining.
  const stripped = stripQuotedArgs(cmd).replace(/\d*>&\d+|\d*>&-/g, " ");
  if (/[|;&\n]|\$\(|`|<\(|>\(/.test(stripped)) return true;
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

// True when cmd contains command-sequencing operators (;, &&, ||) outside quotes.
// Single | (pipe) is excluded — needed for `cmd | tee file`. &> (redirect) is
// not matched because the regex requires two & characters for &&.
// Commands with sequencing must not be fast-pathed through the session-scope
// allow: the un-extracted portion may contain in-scope writes (e.g. rm, mv).
function hasCommandSequencing(cmd) {
  const stripped = stripQuotedArgs(cmd);
  return /;|&&|\|\|/.test(stripped);
}

// True when cmd has sequencing operators (; && ||) OUTSIDE the heredoc body.
// Strips the heredoc body before the sequencing test so body-internal operators
// (e.g. shell fragments in a cat <<'EOF' write) are not treated as real sequencing.
function hasCommandSequencingOutsideHeredoc(cmd) {
  return hasCommandSequencing(stripHeredocBody(cmd));
}

/**
 * True when targetPath resolves to a location OUTSIDE repoRoot.
 * Relative paths are resolved against process.cwd() (the main worktree when
 * this hook runs), which gives the correct semantic for worktree paths.
 * Fails open (returns true) when the path cannot be resolved.
 */
function isPathOutsideRepo(targetPath, repoRoot) {
  try {
    // Normalize POSIX drive-letter paths (e.g. /c/git/foo) to Windows native
    // form before path.resolve, which on Windows otherwise misresolves them
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
    // Full-path match (patterns containing '/' or '**').
    if (matchesAnyExcludePattern(abs, patterns)) return true;
    // Gitignore semantics: patterns without '/' also match against basename.
    const basenamePatterns = patterns.filter((p) => !p.includes("/"));
    if (basenamePatterns.length === 0) return false;
    return matchesAnyExcludePattern(path.basename(abs), basenamePatterns);
  } catch (e) { return false; }
}

module.exports = {
  hasShellChaining,
  findFirstUnquotedAnd,
  hasCommandSequencing,
  hasCommandSequencingOutsideHeredoc,
  isPathOutsideRepo,
  isExcluded,
  getExcludePatterns,
  hasWorktreeEndSkillPrefix,
  stripWorktreeEndSkillPrefix,
  rejectRceGitFlags,
  rejectInterpreterAndChaining,
  BUILTIN_EXCLUDE_PATTERNS,
};
