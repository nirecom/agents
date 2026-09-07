"use strict";

// Interpreter-body extraction for recursive-delete-scan.js: what text will an
// interpreter actually run, and does a non-shell body carry a delete call?

const {
  resolveEffectiveCommand,
  resolveEffectiveArgv,
  commandBasename,
  interpreterFoundBodies,
  UNRESOLVABLE_RE,
  INTERPRETER_SPECS,
} = require("../../bash-write-patterns/segment-utils");

// A language body is SOURCE, not shell text, so it is matched against known
// call shapes instead of re-parsed as a command. Residual gap: an options
// object bound to a VARIABLE (`fs.rm(p, opts)`) names no key to match.
const OPTS_RECURSIVE = "['\"]?recursive['\"]?\\s*:\\s*true";
const LANGUAGE_DELETE_SHAPES = {
  python: [/\brmtree\b/, /\bos\.removedirs\b/, /\bremove_tree\b/],
  perl: [/\brmtree\b/, /\bremove_tree\b/],
  ruby: [/\brm_rf\b/, /\brm_r\b/, /\bremove_entry(?:_secure)?\b/, /\bremove_dir\b/],
  node: [/\brimraf\b/, new RegExp("\\brm(?:dir)?(?:Sync)?\\s*\\([\\s\\S]*?" + OPTS_RECURSIVE)],
  // R and Tcl spell recursion in syntax nothing else here matches.
  r: [/\bunlink\s*\([\s\S]{0,200}?recursive\s*=\s*(?:TRUE|T)\b/],
  tcl: [/\bfile\s+delete\b[\s\S]{0,200}?-force\b/],
};

// Any language can shell out (`os.system("rm -rf x")`). The last two cover the
// LIST form (`subprocess.run(["rm", "-rf", d])`), which the others never match.
const SHELL_DELETE_SHAPES = [
  /\brm\s+-[A-Za-z]*[rR]/, /\brm\s+--recursive\b/, /-Recurse\b/i, /\brmdir\s+\/[sS]\b/,
  /['"]rm['"]\s*,[^\]]{0,200}?['"]--?[A-Za-z]*[rR][A-Za-z]*['"]/,
  /['"]rmdir['"]\s*,[^\]]{0,200}?['"]\/[sS]['"]/,
];

function languageBodyLooksLikeRecursiveDelete(lang, body) {
  if (typeof body !== "string") return false;
  const shapes = [...(LANGUAGE_DELETE_SHAPES[lang] || []), ...SHELL_DELETE_SHAPES];
  return shapes.some((re) => re.test(body));
}

/**
 * Every inline body an interpreter wrapper will run, as {kind, lang, body}.
 * A LIST, because one cluster can read two ways (`node -pe CODE` vs
 * `python -cCODE`) and guessing between them let `python -uc '...'` through.
 */
function interpreterBodiesOf(seg) {
  const base = commandBasename(resolveEffectiveCommand(seg));
  if (!base) return [];
  const spec = INTERPRETER_SPECS.get(base);
  if (!spec) return [];
  return interpreterFoundBodies(spec, resolveEffectiveArgv(seg));
}

// An UNQUOTED inline body stops at the first shell metacharacter, so
// `node --eval=fs.rmSync("d",{recursive:true})` reaches the shapes above
// amputated to `fs.rmSync`. Signature: the segment's raw text ends with the
// extracted body and the next character opens a group. Quoted spellings
// resolve normally, so failing closed here costs nothing (#2210).
function interpreterBodyTruncated(rawCmd, seg) {
  const raw = typeof seg.rawText === "string" ? seg.rawText : "";
  if (raw === "") return false;
  const at = rawCmd.indexOf(raw);
  if (at === -1 || !/^[([{]/.test(rawCmd.slice(at + raw.length))) return false;
  return interpreterBodiesOf(seg)
    .some((found) => typeof found.body === "string" && found.body !== "" && raw.endsWith(found.body));
}

module.exports = {
  UNRESOLVABLE_RE,
  languageBodyLooksLikeRecursiveDelete,
  interpreterBodiesOf,
  interpreterBodyTruncated,
};
