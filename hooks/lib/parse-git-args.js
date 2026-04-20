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

module.exports = { parseGitCArg };
