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
function parseGitGlobalOptions(command) {
  const tail = command.replace(/^\s*git\b\s*/, "");
  // Tokenize quote-aware
  const tokens = tail.match(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g) || [];
  // Global flags that consume the next token as their value (when not given via =)
  const FLAGS_WITH_ARG = new Set([
    "-C", "--git-dir", "--work-tree", "--namespace",
    "-c", "--config-env", "--exec-path", "--super-prefix",
  ]);
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

module.exports = { parseGitCArg, parseGitGlobalOptions };
