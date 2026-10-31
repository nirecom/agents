"use strict";
// The lines a staged change adds or modifies against HEAD (#2770), as 1-based line numbers of the
// staged file: one zero-context `git diff --cached`, read from its `+++` headers and hunk headers.
// A new file lists every line; a deletion or a mode-only change lists none.

const HUNK_RE = /^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/;
const ESCAPES = { a: 7, b: 8, t: 9, n: 10, v: 11, f: 12, r: 13, '"': 34, "\\": 92 };

// A path git quoted C-style ("...", octal escapes for raw bytes) back to its UTF-8 text.
function unquote(s) {
  if (!s.startsWith('"')) return s;
  const bytes = [];
  for (let i = 1; i < s.length - 1; i++) {
    if (s[i] !== "\\") { bytes.push(...Buffer.from(s[i], "utf8")); continue; }
    const oct = /^[0-7]{3}/.exec(s.slice(i + 1));
    if (oct) { bytes.push(parseInt(oct[0], 8)); i += 3; continue; }
    i++;
    bytes.push(ESCAPES[s[i]] === undefined ? s.charCodeAt(i) : ESCAPES[s[i]]);
  }
  return Buffer.from(bytes).toString("utf8");
}

// parseChangedLines(patch) -> Map(path -> [line]) for each path the patch carries a hunk for.
function parseChangedLines(patch) {
  const out = new Map();
  let current = null;
  let inHeader = false;
  for (const line of patch.split("\n")) {
    if (line.startsWith("diff --git ")) { current = null; inHeader = true; continue; }
    if (inHeader && line.startsWith("+++ ")) {
      const name = unquote(line.slice(4).replace(/\t$/, ""));
      current = name === "/dev/null" ? null : name.replace(/^b\//, "");
      if (current !== null && !out.has(current)) out.set(current, []);
      continue;
    }
    const m = HUNK_RE.exec(line);
    if (!m) continue;
    inHeader = false;
    if (current === null) continue;
    const start = Number(m[1]);
    const count = m[2] === undefined ? 1 : Number(m[2]);
    for (let n = start; n < start + count; n++) out.get(current).push(n);
  }
  return out;
}

// changedLinesOf(git, repoDir) -> Map(path -> [line]) over the whole index; git(repoDir, args).
function changedLinesOf(git, repoDir) {
  const patch = git(repoDir, ["-c", "core.quotePath=false", "diff", "--cached", "-U0", "--no-renames", "--text",
    "--no-ext-diff", "--no-textconv", "--no-color", "--no-relative", "--src-prefix=a/", "--dst-prefix=b/"]);
  return parseChangedLines(patch.toString("utf8"));
}

module.exports = { changedLinesOf, parseChangedLines };
