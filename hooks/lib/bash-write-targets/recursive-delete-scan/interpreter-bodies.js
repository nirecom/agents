"use strict";

// Interpreter-body extraction and source-shape matching for
// recursive-delete-scan.js: given a segment, WHAT text will an interpreter
// actually run, and does a non-shell body carry a known recursive-delete call?
// Split out of the parent when it crossed the 500-line hard limit; the parent
// keeps the fold-to-verdict step because that one recurses back into the scan.

const {
  resolveEffectiveCommand,
  resolveEffectiveArgv,
  commandBasename,
  interpreterFoundBodies,
  UNRESOLVABLE_RE,
  INTERPRETER_SPECS,
} = require("../../bash-write-patterns/segment-utils");

// Every interpreter name, body flag and extraction rule — PowerShell's
// `-Command` join and `-EncodedCommand` decode included — is owned by
// segment-utils/interpreter-specs.js (CPR-SSOT), the same table the mid-argv
// scanWrappedInterpreter net reads, so the two nets cannot diverge.

// A language body is SOURCE, not shell text, so it is matched against known
// recursive-delete call shapes instead of being re-parsed as a command. The
// options object is matched with the key quoted or bare ({recursive:true} and
// {"recursive":true} are the same call). Accepted residual gap: an options
// object bound to a VARIABLE (`fs.rm(p, opts)`) names no key here at all, and
// resolving it needs dataflow analysis that text-shape matching cannot do.
const OPTS_RECURSIVE = "['\"]?recursive['\"]?\\s*:\\s*true";
const LANGUAGE_DELETE_SHAPES = {
  python: [/\brmtree\b/, /\bos\.removedirs\b/, /\bremove_tree\b/],
  perl: [/\brmtree\b/, /\bremove_tree\b/],
  ruby: [/\brm_rf\b/, /\brm_r\b/, /\bremove_entry(?:_secure)?\b/, /\bremove_dir\b/],
  node: [/\brimraf\b/, new RegExp("\\brm(?:dir)?(?:Sync)?\\s*\\([\\s\\S]*?" + OPTS_RECURSIVE)],
  // R and Tcl spell recursion with their own syntax, which neither the
  // options-object shapes above nor the shell spellings below would ever match:
  // `unlink("d", recursive = TRUE)` and `file delete -force d`.
  r: [/\bunlink\s*\([\s\S]{0,200}?recursive\s*=\s*(?:TRUE|T)\b/],
  tcl: [/\bfile\s+delete\b[\s\S]{0,200}?-force\b/],
};

// Any language can also shell out (`os.system("rm -rf x")`), so every body is
// matched against the shell spellings too. The last two cover the LIST form
// (`subprocess.run(["rm", "-rf", d])`), where the argv is an array of string
// literals and the space-separated spellings above never match.
const SHELL_DELETE_SHAPES = [
  /\brm\s+-[A-Za-z]*[rR]/, /\brm\s+--recursive\b/, /-Recurse\b/i, /\brmdir\s+\/[sS]\b/,
  /['"]rm['"]\s*,[^\]]{0,200}?['"]--?[A-Za-z]*[rR][A-Za-z]*['"]/,
  /['"]rmdir['"]\s*,[^\]]{0,200}?['"]\/[sS]['"]/,
];

// True when a non-shell interpreter body carries a known recursive-delete shape.
function languageBodyLooksLikeRecursiveDelete(lang, body) {
  if (typeof body !== "string") return false;
  const shapes = [...(LANGUAGE_DELETE_SHAPES[lang] || []), ...SHELL_DELETE_SHAPES];
  return shapes.some((re) => re.test(body));
}

/**
 * interpreterBodiesOf(seg) — every inline body an interpreter wrapper will run,
 * as {kind, lang, body} so the caller knows how to judge each: "shell" bodies
 * are re-scanned as command text, "language" bodies are matched against
 * source-level delete shapes, "unresolvable" fails closed. A LIST because one
 * cluster can read two ways (`node -pe CODE` vs `python -cCODE`) and guessing
 * between them is what let `python -uc '...'` through. Contract: detail.md Step 4 2b.
 */
function interpreterBodiesOf(seg) {
  const base = commandBasename(resolveEffectiveCommand(seg));
  if (!base) return [];
  const spec = INTERPRETER_SPECS.get(base);
  if (!spec) return [];
  return interpreterFoundBodies(spec, resolveEffectiveArgv(seg));
}

// An UNQUOTED inline body stops at the first shell metacharacter: the parser
// reads `node --eval=fs.rmSync("d",{recursive:true})` as a command followed by a
// subshell, so the body reaching the shapes above is the amputated prefix
// `fs.rmSync` and every delete shape misses. The signature is a segment whose
// raw text ENDS with the extracted body and whose next character opens a group,
// i.e. the body demonstrably continues past the token. Both quoted spellings
// resolve normally, so failing closed here costs nothing (#2210 round-5).
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
