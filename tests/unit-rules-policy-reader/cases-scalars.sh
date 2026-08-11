# shellcheck shell=bash
# Tests: hooks/lib/rules-policy-reader.js
# Tags: rules-injection, policy-reader, unescape, string-const, parser, table-driven, TL2, scope:common
#
# The two scalar parsers: unescapeLiteral() and readStringConst(). CONTRACT: unescapeLiteral is a BACKSLASH STRIPPER, not a JS escape decoder — `\n` in the source becomes the letter `n`, NOT a newline. That's correct for its one job (recovering a quoted path literal such as "rules/docs.md") and would be wrong for anything else, so the distinction is asserted rather than assumed.
# readStringConst distinguishes "declared as the empty string" (returns "") from "not declared at all" (returns null) — loadPolicyAsData's documented contract rests on that difference, so it is pinned directly.
# The declaration regex is UNANCHORED and text-only. Two consequences are pinned as CURRENT BEHAVIOUR with an explicit note, because both are accepted limitations of parsing rather than evaluating, not bugs this suite should hide.
# Assumes BASE, run_rows(), assert_rows(), pass(), fail() from the dispatcher.

echo ""
echo "=== unescapeLiteral / readStringConst (table-driven) ==="

cat > "$BASE/h-scalars.js" <<'SCALARS_EOF'
"use strict";
// argv[2] = hooks/lib/rules-policy-reader.js
const R = require(process.argv[2]);

const rows = [];
let pipes = 0;
function row(name, want, got) {
  if (String(want).includes("|") || String(got).includes("|")) pipes += 1;
  rows.push(["ROW", name, want, got].join("|"));
}
const encS = (v) => (v === null ? "NULL" : "S:" + v);

// --- unescapeLiteral: name | input | want ------------------------------------------
// Inputs are written as JS literals, so "a\\nb" is the four characters a \ n b — i.e.
// exactly what the parser sees after slicing a quoted literal out of the policy source.
const UNESCAPE = [
  ["unesc-backslash-n-is-not-a-newline", "a\\nb", "anb"],
  ["unesc-backslash-t-is-not-a-tab", "a\\tb", "atb"],
  ["unesc-double-backslash-collapses", "a\\\\b", "a\\b"],
  ["unesc-escaped-single-quote", "a\\'b", "a'b"],
  ["unesc-escaped-double-quote", "a\\\"b", "a\"b"],
  ["unesc-no-escape-passthrough", "rules/docs.md 123", "rules/docs.md 123"],
  ["unesc-escape-of-escape-protects-next", "a\\\\nb", "a\\nb"],
  ["unesc-trailing-backslash-survives", "ab\\", "ab\\"],
  ["unesc-empty-input", "", ""],
];
UNESCAPE.forEach(([name, input, want]) => row(name, want, R.unescapeLiteral(input)));

// --- readStringConst: name | source | want -----------------------------------------
const SCONST = [
  ["sconst-single-quotes", "const ON_DEMAND_TOKEN = 'abc';", "S:abc"],
  ["sconst-double-quotes", "const ON_DEMAND_TOKEN = \"abc\";", "S:abc"],
  ["sconst-declaration-absent", "const SOMETHING_ELSE = \"abc\";", "NULL"],
  ["sconst-empty-source", "", "NULL"],
  ["sconst-embedded-escaped-double-quote", "const ON_DEMAND_TOKEN = \"a\\\"b\";", "S:a\"b"],
  ["sconst-embedded-escaped-single-quote", "const ON_DEMAND_TOKEN = 'a\\'b';", "S:a'b"],
  ["sconst-apostrophe-inside-double-quotes", "const ON_DEMAND_TOKEN = \"it's\";", "S:it's"],
  ["sconst-empty-string-is-not-absent", "const ON_DEMAND_TOKEN = \"\";", "S:"],
  ["sconst-duplicate-declarations-first-wins",
   "const ON_DEMAND_TOKEN = \"first\";\nconst ON_DEMAND_TOKEN = \"second\";", "S:first"],
  ["sconst-wide-spacing", "const ON_DEMAND_TOKEN   =   \"spaced\";", "S:spaced"],
  ["sconst-no-spacing", "const ON_DEMAND_TOKEN=\"tight\";", "S:tight"],
  ["sconst-declaration-deep-in-source",
   "\"use strict\";\n// header comment\n\nconst ON_DEMAND_TOKEN = \"deep\";\n", "S:deep"],
  ["sconst-canonical-token-literal",
   "const ON_DEMAND_TOKEN = \".on-demand-only/never-match\";", "S:.on-demand-only/never-match"],
  // PINNED CURRENT BEHAVIOUR (accepted limitation, not a defect to hide): the quote
  // character class is ["'] only, so a backtick-quoted declaration is invisible to the
  // parser and reads as "not declared". The policy file's header already requires plain
  // one-line quoted literals, so a backtick declaration is out of contract at source.
  ["sconst-backtick-quoted-is-invisible", "const ON_DEMAND_TOKEN = `abc`;", "NULL"],
  // PINNED CURRENT BEHAVIOUR: the regex requires no `const` keyword and is unanchored,
  // so a bare assignment is accepted and a LONGER identifier ending in the requested name
  // also matches. Both follow from parsing text instead of evaluating a module; they are
  // recorded here so a future tightening is a deliberate, visible change.
  ["sconst-const-keyword-not-required", "ON_DEMAND_TOKEN = \"bare\";", "S:bare"],
  ["sconst-name-matches-as-a-substring", "const X_ON_DEMAND_TOKEN = \"prefixed\";", "S:prefixed"],
  // PINNED CURRENT BEHAVIOUR — KNOWN LIMITATION L3 (comment-hides-declaration).
  // A commented-out declaration placed BEFORE the real one wins, because the parser has
  // no notion of JS comments. This is an accepted limitation tracked as a follow-up; it
  // is deliberately NOT fixed here (a source change is out of scope for this test file),
  // and it is pinned so the day it changes, this row fails and the change is reviewed.
  ["sconst-L3-comment-before-real-decl-wins",
   "// const ON_DEMAND_TOKEN = \"decoy\";\nconst ON_DEMAND_TOKEN = \"real\";", "S:decoy"],
];
SCONST.forEach(([name, src, want]) => row(name, want, encS(R.readStringConst(src, "ON_DEMAND_TOKEN"))));

rows.push("PIPEGUARD=" + pipes);
console.log(rows.join("\n"));
SCALARS_EOF

SC_REPORT="$(run_rows "$BASE/h-scalars.js")"
assert_rows "S1" "$SC_REPORT" 26
