// Inline gitignore-compatible matcher replacing the `ignore` npm package.
// Rewritten to fix issue #239: `ignore` requires `npm install` which fails on
// fresh clone due to enforce-worktree's npm-write block.
//
// API contract preserved verbatim: buildMatcher(patterns) → { ignores(relPath) }
//
// Deliberately unsupported gitignore corners:
//   - Character classes [abc], [a-z] (not used in this repo's patterns)
//   - Complex ** interior segments like a/**/b (** only appears at segment edges)

function globToRegex(glob) {
  let src = "";
  let i = 0;
  while (i < glob.length) {
    if (glob[i] === "*" && glob[i + 1] === "*") {
      src += ".*";
      i += 2;
    } else if (glob[i] === "*") {
      src += "[^/]*";
      i += 1;
    } else if (glob[i] === "?") {
      src += "[^/]";
      i += 1;
    } else if (/[.+^${}[\]|(]/.test(glob[i])) {
      src += "\\" + glob[i];
      i += 1;
    } else {
      src += glob[i];
      i += 1;
    }
  }
  return new RegExp("^" + src + "$");
}

function buildMatcher(patterns) {
  return {
    ignores(relPath) {
      const normalized = relPath.replace(/\\/g, "/").replace(/^\.\//, "");
      let ignored = false;

      for (const rawPattern of patterns) {
        let pattern = rawPattern.trim();
        if (pattern === "" || pattern.startsWith("#")) continue;

        let negate = false;
        if (pattern.startsWith("!")) {
          negate = true;
          pattern = pattern.slice(1);
        } else if (pattern.startsWith("\\")) {
          pattern = pattern.slice(1);
        }

        let dirOnly = false;
        if (pattern.endsWith("/")) {
          dirOnly = true;
          pattern = pattern.slice(0, -1);
        }

        // Detect anchor: contains '/' in remaining pattern (leading '/' also anchors)
        let anchored = pattern.includes("/");
        if (pattern.startsWith("/")) {
          pattern = pattern.slice(1);
        }

        const regex = globToRegex(pattern);

        let matched = false;
        if (dirOnly) {
          // Match the dir-name at any depth: equal to pattern-name, starts with it + "/"
          // or has it as a path segment
          if (anchored) {
            matched = normalized === pattern ||
              normalized.startsWith(pattern + "/");
          } else {
            const segments = normalized.split("/");
            for (let s = 0; s < segments.length; s++) {
              if (regex.test(segments[s])) {
                const prefix = segments.slice(0, s + 1).join("/");
                if (normalized === prefix || normalized.startsWith(prefix + "/")) {
                  matched = true;
                  break;
                }
              }
            }
          }
        } else if (anchored) {
          matched = regex.test(normalized);
        } else {
          const basename = normalized.includes("/")
            ? normalized.slice(normalized.lastIndexOf("/") + 1)
            : normalized;
          matched = regex.test(normalized) || regex.test(basename);
        }

        if (matched) ignored = !negate;
      }

      return ignored;
    },
  };
}

module.exports = { buildMatcher };
