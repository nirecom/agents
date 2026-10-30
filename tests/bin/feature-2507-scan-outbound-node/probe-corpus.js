"use strict";
// lang-check: ignore — the class probes carry CJK subjects on purpose.
// Probe tables of tests/bin/feature-2507-scan-outbound-node.js (#2507 D6): single ERE, glob and
// skip-path probes whose golden answer bash gives (generate-golden.js). Editing a row means
// regenerating the golden.

const BS = "\\";
const cp = (...c) => String.fromCodePoint(...c);

// ERE probes: bash `[[ subject =~ pattern ]]` decides the golden answer (match text, no match,
// or rc 2 = an invalid ERE). Valid-but-untranslatable patterns are deliberately absent (D6).
const ERE_CASES = [
  ["class-alpha-ascii", "^[[:alpha:]]+$", "abc"],
  ["class-alpha-latin", "^[[:alpha:]]$", "é"],
  ["class-alpha-hiragana", "^[[:alpha:]]$", "あ"],
  ["class-alpha-digit", "^[[:alpha:]]$", "1"],
  ["class-alnum-latin", "^[[:alnum:]]$", "é"],
  ["class-digit-ascii", "^[[:digit:]]$", "7"],
  ["class-digit-fullwidth", "^[[:digit:]]$", "１"],
  ["class-upper-latin", "^[[:upper:]]$", "À"],
  ["class-upper-lower", "^[[:upper:]]$", "a"],
  ["class-lower-sharp-s", "^[[:lower:]]$", "ß"],
  ["class-space-tab", "^[[:space:]]$", "\t"],
  ["class-space-nbsp", "^[[:space:]]$", " "],
  ["class-space-ideographic", "^[[:space:]]$", "　"],
  ["class-blank-tab", "^[[:blank:]]$", "\t"],
  ["class-punct-ascii", "^[[:punct:]]$", "!"],
  ["class-punct-cjk", "^[[:punct:]]$", "、"],
  ["class-xdigit-f", "^[[:xdigit:]]$", "f"],
  ["class-xdigit-g", "^[[:xdigit:]]$", "g"],
  ["class-cntrl", "^[[:cntrl:]]$", "\u0001"],
  ["class-print-latin", "^[[:print:]]$", "é"],
  ["class-graph-space", "^[[:graph:]]$", " "],
  ["class-unknown-name", "[[:nope:]]", "a"],
  ["dot-two-byte", "^x.$", "xé"],
  ["dot-astral", "^x.$", `x${cp(0x1f600)}`],
  ["dot-cjk", "^x.$", "xあ"],
  ["negated-bracket-two-byte", "^x[^a]$", "xé"],
  ["bracket-backslash-literal", `[${BS}]b`, `a${BS}b`],
  ["bracket-backslash-n-on-n", `^[${BS}n]$`, "n"],
  ["bracket-backslash-n-on-backslash", `^[${BS}n]$`, BS],
  ["bracket-close-first", "^[]a]$", "]"],
  ["bracket-negated-close-first", "^[^]a]$", "b"],
  ["bracket-dash-last", "^[a-]$", "-"],
  ["word-begin-hit", `${BS}<ab`, "x ab"],
  ["word-begin-miss", `${BS}<ab`, "xab"],
  ["word-end-hit", `ab${BS}>`, "ab c"],
  ["word-end-miss", `ab${BS}>`, "abc"],
  ["backslash-d-on-d", `${BS}d`, "d"],
  ["backslash-d-on-digit", `${BS}d`, "5"],
  ["backslash-w", `a${BS}w`, "a_"],
  ["backslash-w-latin", `a${BS}w`, "aé"],
  ["backslash-W-underscore", `a${BS}W`, "a_"],
  ["backslash-W-space", `a${BS}W`, "a "],
  ["backslash-s", `a${BS}sb`, "a b"],
  ["backslash-b", `${BS}bfoo`, "x foo"],
  ["escaped-plus", `a${BS}+`, "a+"],
  ["escaped-dot-hit", `a${BS}.b`, "a.b"],
  ["escaped-dot-miss", `a${BS}.b`, "axb"],
  ["longest-alternation", "(a|ab)(c|bcd)", "abcd"],
  ["longest-prefix-alternation", "x(a|ab)", "xab"],
  ["longest-classic-weeknights", "(wee|week)(knights|night)", "weeknights"],
  ["longest-three-alternatives", "a|ab|abc", "abcd"],
  ["leftmost-before-longer", "b+|ab", "aabbb"],
  ["plus-then-question", "a+?", "aaa"],
  ["star-star", "a**", "aaa"],
  ["brace-open-lower", "a{,3}", "aaaa"],
  ["brace-zero", "xa{0}y", "xy"],
  ["case-sensitive", "abc", "ABC"],
  ["backreference", `(a)${BS}1`, "aa"],
  ["empty-alternative", "(|a)b", "ab"],
  ["empty-group", "a()b", "ab"],
  ["anchor-caret-miss", "^b", "ab"],
  ["anchor-dollar-before-cr", "a$", "a\r"],
  ["invalid-brace-order", "a{2,1}", "aaa"],
  ["invalid-open-paren", "(abc", "abc"],
  ["invalid-range", "[z-a]", "abc"],
  ["invalid-leading-star", "*abc", "abc"],
  ["invalid-open-brace", "a{1", "a{1"],
  ["invalid-trailing-backslash", `abc${BS}`, "abc"],
];

// Valid in bash's ERE (bash matches them) but with no faithful JS RegExp form: the new scanner
// must refuse to scan (rc 4) rather than guess (D6 fail-closed). Kept out of every golden.
const UNTRANSLATABLE = ["fixture-eq-[[=a=]]", "fixture-coll-[[.-.]]"];

// Glob probes for the allowlist `file:value` form: bash `[[ subject == glob ]]`.
const GLOB_CASES = [
  ["star-same-dir", "docs/*.md", "docs/a.md"],
  ["star-crosses-slash", "docs/*.md", "docs/sub/a.md"],
  ["star-wrong-ext", "docs/*.md", "docs/a.txt"],
  ["anchored-start", "docs/*.md", "xdocs/a.md"],
  ["qmark-one", "notes/?.txt", "notes/a.txt"],
  ["qmark-two", "notes/?.txt", "notes/ab.txt"],
  ["qmark-slash", "notes/?.txt", "notes//.txt"],
  ["bracket-hit", "[ab]/x.txt", "a/x.txt"],
  ["bracket-miss", "[ab]/x.txt", "c/x.txt"],
  ["bracket-bang", "[!ab]/x.txt", "c/x.txt"],
  ["bracket-caret", "[^ab]/x.txt", "a/x.txt"],
  ["bracket-class", "[[:digit:]]*", "1x"],
  ["star-empty", "*", ""],
  ["escaped-star-hit", `a${BS}*b`, "a*b"],
  ["escaped-star-miss", `a${BS}*b`, "axb"],
  ["dot-literal", "a.b", "axb"],
  ["paren-literal", "(a)", "(a)"],
  ["star-any-depth", "*.md", "a/b.md"],
  ["double-star", "**/x", "a/b/x"],
  ["double-star-needs-slash", "**/x", "x"],
  ["utf8-qmark", "é?", "éx"],
  ["extglob-at", "@(a|b)/x.txt", "b/x.txt"],
  ["extglob-plus", "+(a)/x.txt", "aa/x.txt"],
  ["extglob-not", "!(a)/x.txt", "c/x.txt"],
];

// Staged paths for the pre-commit SKIP_PATTERNS (grep -E substring match).
const SKIP_PATHS = [
  "bin/scan-outbound.sh",
  "x/bin/scan-outbound.sh",
  "bin/scan-outbound-sh",
  "bin/scan-outbound.shx",
  "bin/scan-outbound.d/cli.js",
  ".private-info-allowlist",
  "sub/.private-info-allowlist.bak",
  "xprivate-info-allowlist",
  ".private-info-blocklist",
  ".offensive-content-blocklist.example",
  ".offensive-content-blocklist",
  "hooks/lib/outbound-scan/scan-line.js",
  "hooks/lib/ere/translate.js",
];

// #2507: \w / \W follow GNU regex ([_[:alnum:]]); the Windows Git Bash libc leaves "_" out, so
// these rows replace the probe's answer when the golden is generated (meta.overrides records it).
const GNU_OVERRIDES = {
  "backslash-w": { status: "match", text: "a_" },
  "backslash-W-underscore": { status: "nomatch" },
};
const GNU_OVERRIDE_NOTE = "\\w follows GNU regex ([_[:alnum:]]), not Windows Git Bash, whose \\w leaves out _; rows listed in overrides are not the probe's answer";

module.exports = { ERE_CASES, UNTRANSLATABLE, GLOB_CASES, SKIP_PATHS, GNU_OVERRIDES, GNU_OVERRIDE_NOTE };
