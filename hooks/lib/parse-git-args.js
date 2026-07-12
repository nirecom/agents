// Parse git command string arguments with quote awareness.
// Handles bare, double-quoted, and single-quoted -C path arguments.

// Extract the argument following `git -C` from a command string.
// Returns the unquoted path string, or null if -C is absent or quote is unterminated.
function parseGitCArg(command) {
  const m = command.match(/git\s+-C\s+(["']?)(\S.*)/);
  if (!m) return null;
  const quote = m[1];
  const rest = m[2];
  if (!quote) {
    const bare = rest.match(/^\S+/);
    return bare ? bare[0] : null;
  }
  const closeIdx = rest.indexOf(quote);
  if (closeIdx === -1) return null; // unterminated quote
  return rest.slice(0, closeIdx);
}

// Extract the absolute literal path following a leading `cd` command.
// Form: `cd <absolute-path> [&&|;|whitespace] ...`
// Returns unquoted path or null when:
//   - no leading `cd`
//   - unterminated quote
//   - relative path (./foo, foo)
//   - tilde (~) path
//   - shell-variable reference ($X, ${X}) — hooks see the raw command string
//     BEFORE Bash variable expansion; env-var paths cannot be resolved here.
//     Callers must fall back to process.cwd() in that case.
// First cd only: for `cd /a && cd /b && git`, returns /a (conservative).
function parseCdCommand(command) {
  if (!command || typeof command !== "string") return null;
  const m = command.match(/^\s*cd\s+(["']?)(\S.*)/);
  if (!m) return null;
  const quote = m[1];
  const rest = m[2];
  let raw;
  if (!quote) {
    const bare = rest.match(/^[^\s;|&]+/);
    if (!bare) return null;
    raw = bare[0];
  } else {
    const closeIdx = rest.indexOf(quote);
    if (closeIdx === -1) return null;
    raw = rest.slice(0, closeIdx);
  }
  if (/\$/.test(raw)) return null;     // env-var reference
  if (raw.startsWith("~")) return null; // tilde
  const isAbsolute = raw.startsWith("/") || /^[a-zA-Z]:[\\/]/.test(raw);
  if (!isAbsolute) return null;
  return raw;
}

/**
 * Extracts the cd target from a `bash/sh/zsh/dash -c '<body>'` command string.
 * Returns the absolute path of the first cd in the body, or null when:
 *   - command does not match bash/sh/zsh/dash -\w*c\w* '<body>' form
 *   - body has no leading cd, or cd target is relative/tilde/env-var
 * Fail-safe: unrecognized forms return null (caller falls back to parseCdCommand).
 * pwsh/fish/double-quote body intentionally not supported.
 *
 * Flag-set matches isReadOnlyInterpreterC() in bash-write-patterns.js: -\w*c\w*
 * accepts -c / -lc / -xc / -cx / -lxc / etc. (common login-shell + verbose
 * combinations). Mismatch with that sibling parser caused #566 HIGH — `bash -lc`
 * fell through to process.cwd() and bypassed the cd-scope fix.
 */
function parseCdCommandInInterpreter(command) {
  if (!command || typeof command !== "string") return null;
  const m = command.match(/^\s*(?:bash|sh|zsh|dash)(?:\.exe)?\s+-\w*c\w*\s+'([^']*)'\s*$/i);
  if (!m) return null;
  const body = m[1];
  const segment = body.split(/&&|\|\||;/)[0].trim();
  return parseCdCommand(segment);
}

/**
 * Parses the leading "git [global-opts...]" portion of a command and returns
 * { subcommand, rest }. Skips global git options that may appear before the
 * subcommand verb: --no-pager, -C <path>, -c k=v, --git-dir=<x>, --work-tree=<x>,
 * --namespace=<x>, --exec-path[=<x>], --paginate, -p, --bare, --no-replace-objects,
 * --literal-pathspecs, --config-env, --super-prefix.
 *
 * Returns { subcommand: null, rest: "" } when no subcommand is found.
 * Quote-aware (handles "..." and '...').
 */
// SSOT (CPR-2): git global flags that consume the next token as their value (when
// not given via =value). Imported by hooks/lib/bash-write-patterns/patterns.js
// (resolveGitSubArgv) so the two do not drift. Do not duplicate this set.
const FLAGS_WITH_ARG = new Set([
  "-C", "--git-dir", "--work-tree", "--namespace",
  "-c", "--config-env", "--exec-path", "--super-prefix",
]);

function parseGitGlobalOptions(command) {
  const tail = command.replace(/^\s*git\b\s*/, "");
  // Tokenize quote-aware
  const tokens = tail.match(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g) || [];
  let i = 0;
  while (i < tokens.length) {
    const t = tokens[i];
    if (t.startsWith("-")) {
      const key = t.split("=")[0];
      if (FLAGS_WITH_ARG.has(key) && !t.includes("=")) {
        i++; // consume the next token as value
      }
      i++;
    } else {
      // First non-flag token is the subcommand verb
      return { subcommand: t, rest: tokens.slice(i + 1).join(" ") };
    }
  }
  return { subcommand: null, rest: "" };
}

/**
 * Extract the scope-redirecting git GLOBAL options (-C / --work-tree / --git-dir)
 * from a SINGLE segment's already-tokenized, quote-resolved argv (the `argv` field
 * of a command-ir segment, i.e. the tokens AFTER cmd0="git"). Only options BEFORE
 * the subcommand verb are honored — a value-position or post-subcommand occurrence
 * (e.g. `git commit -C <ref>`, `git log --work-tree` after a subcommand) is not a
 * global scope selector and is ignored.
 *
 * This is the SEGMENT-LOCAL, quote-aware replacement for the raw-regex
 * parseGitCPath / parseGitPathFlag whole-command scanners: because it reads the
 * segment's OWN argv, a scope flag in a DIFFERENT segment or inside quoted text
 * cannot leak in (fixes cross-segment + quoted --work-tree mis-scope).
 *
 * Returns { workTree, cIn, gitDir, sawScopeFlag }:
 *   - workTree / cIn / gitDir: the string value of the LAST such flag seen, or null.
 *   - sawScopeFlag: true when ANY of -C / --work-tree / --git-dir appeared as a
 *     global option (used by callers to trigger fail-closed handling when the value
 *     is unresolvable).
 * gitArgv MUST be the token array after cmd0 (does not include the literal "git").
 */
function extractGitScopeFlagsFromArgv(gitArgv) {
  const result = { workTree: null, cIn: null, gitDir: null, sawScopeFlag: false };
  if (!Array.isArray(gitArgv)) return result;
  let i = 0;
  while (i < gitArgv.length) {
    const tok = gitArgv[i];
    if (typeof tok !== "string") break;
    if (tok[0] !== "-") break; // first non-flag = subcommand verb; stop.
    const eq = tok.indexOf("=");
    const key = eq === -1 ? tok : tok.slice(0, eq);
    const attached = eq !== -1 ? tok.slice(eq + 1) : null;
    const takesValue = FLAGS_WITH_ARG.has(key);
    let value = null;
    if (takesValue) {
      if (attached !== null) {
        value = attached;
        i += 1;
      } else {
        value = i + 1 < gitArgv.length ? gitArgv[i + 1] : null;
        i += 2;
      }
    } else {
      i += 1;
    }
    if (key === "--work-tree") { result.workTree = value; result.sawScopeFlag = true; }
    else if (key === "-C") { result.cIn = value; result.sawScopeFlag = true; }
    else if (key === "--git-dir") { result.gitDir = value; result.sawScopeFlag = true; }
  }
  return result;
}

/**
 * Collect values of `git -c <key>=<value>` global options matching the given key.
 * Returns an array (may be empty) of value strings. Only inspects global options
 * before the subcommand verb — `-c` appearing after the subcommand (e.g.
 * `git commit -c <ref>`) is a different flag and is ignored.
 * Quote-aware (strips matching outer quotes from the key=value token).
 */
function parseGitConfigValues(command, key) {
  const tail = command.replace(/^\s*git\b\s*/, "");
  const tokens = tail.match(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g) || [];
  const FLAGS_WITH_ARG_NO_EQ = new Set([
    "-C", "--git-dir", "--work-tree", "--namespace",
    "--config-env", "--exec-path", "--super-prefix",
  ]);
  const values = [];
  for (let i = 0; i < tokens.length; i++) {
    let t = tokens[i];
    if ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'"))) {
      t = t.slice(1, -1);
    }
    if (!t.startsWith("-")) break; // subcommand reached
    if (t === "-c" && i + 1 < tokens.length) {
      let v = tokens[i + 1];
      if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
        v = v.slice(1, -1);
      }
      const eq = v.indexOf("=");
      if (eq > 0 && v.slice(0, eq) === key) values.push(v.slice(eq + 1));
      i++;
    } else if (FLAGS_WITH_ARG_NO_EQ.has(t) && !t.includes("=")) {
      i++;
    }
  }
  return values;
}

module.exports = { parseGitCArg, parseCdCommand, parseCdCommandInInterpreter, parseGitGlobalOptions, parseGitConfigValues, extractGitScopeFlagsFromArgv, FLAGS_WITH_ARG };
