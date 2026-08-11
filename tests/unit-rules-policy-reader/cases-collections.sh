# shellcheck shell=bash
# Tests: hooks/lib/rules-policy-reader.js
# Tags: rules-injection, policy-reader, string-array, regex-const, stateless-regex, parser, table-driven, TL2, scope:common
#
# The two collection parsers: readStringArrayConst() and readRegexConst(). CONTRACT: readStringArrayConst distinguishes "declared empty" ([]) from "not declared" (null), the same way readStringConst distinguishes "" from null — loadPolicyAsData collapses both to [] on purpose, so the distinction can only be pinned at this level.
# readRegexConst REBUILDS the literal with `new RegExp(source, flags)` and DROPS /g — a surviving /g makes .test() stateful through lastIndex, marking the same file annotated on one pass and bare on the next, the exact non-determinism the de-injection audit cannot tolerate. Both halves are asserted: the flag is gone, AND two consecutive .test() calls on one subject agree.
# An unparseable regex SOURCE yields null rather than throwing, so a malformed policy degrades to "no marker regex" instead of taking the consumer down.
# Assumes BASE, run_rows(), assert_rows(), pass(), fail() from the dispatcher.

echo ""
echo "=== readStringArrayConst / readRegexConst (table-driven) ==="

cat > "$BASE/h-collections.js" <<'COLL_EOF'
"use strict";
// argv[2] = hooks/lib/rules-policy-reader.js
const R = require(process.argv[2]);

const rows = [];
let pipes = 0;
function row(name, want, got) {
  if (String(want).includes("|") || String(got).includes("|")) pipes += 1;
  rows.push(["ROW", name, want, got].join("|"));
}
const encA = (v) => (v === null ? "NULL" : "A:" + JSON.stringify(v));
const encR = (v) => (v === null ? "NULL" : "R:" + v.source + " FLAGS:" + v.flags);

// --- readStringArrayConst: name | source | want ------------------------------------
const ACONST = [
  ["aconst-single-line", "const ON_DEMAND_FILES = [\"a.md\", \"b.md\"];", "A:[\"a.md\",\"b.md\"]"],
  ["aconst-multi-line",
   "const ON_DEMAND_FILES = [\n  \"rules/docs.md\",\n  \"rules/test.md\",\n];", "A:[\"rules/docs.md\",\"rules/test.md\"]"],
  ["aconst-trailing-comma", "const ON_DEMAND_FILES = [\"a.md\", \"b.md\",];", "A:[\"a.md\",\"b.md\"]"],
  ["aconst-empty-array-is-not-absent", "const ON_DEMAND_FILES = [];", "A:[]"],
  ["aconst-declaration-absent", "const SOMETHING_ELSE = [\"a.md\"];", "NULL"],
  ["aconst-empty-source", "", "NULL"],
  ["aconst-mixed-quote-styles", "const ON_DEMAND_FILES = ['a.md', \"b.md\"];", "A:[\"a.md\",\"b.md\"]"],
  ["aconst-single-element", "const ON_DEMAND_FILES = [\"only.md\"];", "A:[\"only.md\"]"],
  ["aconst-escaped-quote-in-element", "const ON_DEMAND_FILES = [\"a\\\"b.md\"];", "A:[\"a\\\"b.md\"]"],
  ["aconst-comma-inside-element", "const ON_DEMAND_FILES = [\"a,b.md\"];", "A:[\"a,b.md\"]"],
  ["aconst-line-comment-between-elements",
   "const ON_DEMAND_FILES = [\n  \"a.md\", // why a\n  \"b.md\",\n];", "A:[\"a.md\",\"b.md\"]"],
  ["aconst-wide-spacing", "const ON_DEMAND_FILES   =   [ \"a.md\" ];", "A:[\"a.md\"]"],
  // PINNED CURRENT BEHAVIOUR: the array body is captured non-greedily up to the FIRST
  // `]`, so a `]` inside an element truncates the body mid-literal and the now-unbalanced
  // quote matches nothing — the declaration reads as empty rather than as its real
  // contents. A path containing `]` is out of contract for the policy file, but the
  // failure mode is silent, so it is recorded here rather than left to be discovered.
  ["aconst-bracket-inside-element-truncates", "const ON_DEMAND_FILES = [\"a[0].md\", \"b.md\"];", "A:[]"],
  // PINNED CURRENT BEHAVIOUR: unanchored name match, same as readStringConst.
  ["aconst-name-matches-as-a-substring", "const X_ON_DEMAND_FILES = [\"x.md\"];", "A:[\"x.md\"]"],
];
ACONST.forEach(([name, src, want]) => row(name, want, encA(R.readStringArrayConst(src, "ON_DEMAND_FILES"))));

// --- readRegexConst: name | source | want ------------------------------------------
const RCONST = [
  ["rconst-with-flags", "const ON_DEMAND_MARKER_RE = /abc/i;", "R:abc FLAGS:i"],
  ["rconst-without-flags", "const ON_DEMAND_MARKER_RE = /abc/;", "R:abc FLAGS:"],
  ["rconst-multiline-flag-kept", "const ON_DEMAND_MARKER_RE = /abc/m;", "R:abc FLAGS:m"],
  ["rconst-g-flag-stripped", "const ON_DEMAND_MARKER_RE = /abc/g;", "R:abc FLAGS:"],
  ["rconst-gi-keeps-i-drops-g", "const ON_DEMAND_MARKER_RE = /abc/gi;", "R:abc FLAGS:i"],
  ["rconst-char-class-containing-slash", "const ON_DEMAND_MARKER_RE = /[/]x/;", "R:[/]x FLAGS:"],
  ["rconst-escaped-slash", "const ON_DEMAND_MARKER_RE = /a\\/b/;", "R:a\\/b FLAGS:"],
  ["rconst-declaration-absent", "const SOMETHING_ELSE = /abc/;", "NULL"],
  ["rconst-empty-source", "", "NULL"],
  // An outer match that new RegExp() rejects must degrade to null, not throw.
  ["rconst-invalid-quantifier-source", "const ON_DEMAND_MARKER_RE = /a{2,1}/;", "NULL"],
  ["rconst-invalid-char-class-range", "const ON_DEMAND_MARKER_RE = /[z-a]/;", "NULL"],
  // The real declaration shape, so a rewrite of the policy file's marker regex that this
  // parser cannot recover shows up here and not only in the consumers.
  ["rconst-canonical-marker-shape",
   "const ON_DEMAND_MARKER_RE = /<!--\\s*injection:\\s*on-demand-only(?!-?\\w)/;",
   "R:<!--\\s*injection:\\s*on-demand-only(?!-?\\w) FLAGS:"],
];
RCONST.forEach(([name, src, want]) => row(name, want, encR(R.readRegexConst(src, "ON_DEMAND_MARKER_RE"))));

// --- statefulness: the /g regression, asserted as behaviour rather than as a flag -----
// A /g regex keeps lastIndex between calls, so re-testing the SAME subject alternates
// true/false. These rows exercise the rebuilt regex twice on one subject.
const g1 = R.readRegexConst("const ON_DEMAND_MARKER_RE = /on-demand-only/g;", "ON_DEMAND_MARKER_RE");
row("stateless-g-flag-absent", "no", g1 && g1.flags.includes("g") ? "yes" : "no");
row("stateless-g-first-test", "true", String(g1.test("<!-- on-demand-only -->")));
row("stateless-g-second-test-agrees", "true", String(g1.test("<!-- on-demand-only -->")));
row("stateless-g-negative-first", "false", String(g1.test("nothing here")));
row("stateless-g-negative-second-agrees", "false", String(g1.test("nothing here")));
// Control: the same subject through a NON-g declaration must answer identically, which is
// what proves the two rows above measure statelessness and not the subject.
const g2 = R.readRegexConst("const ON_DEMAND_MARKER_RE = /on-demand-only/;", "ON_DEMAND_MARKER_RE");
row("stateless-control-nog-first", "true", String(g2.test("<!-- on-demand-only -->")));
row("stateless-control-nog-second", "true", String(g2.test("<!-- on-demand-only -->")));

rows.push("PIPEGUARD=" + pipes);
console.log(rows.join("\n"));
COLL_EOF

CO_REPORT="$(run_rows "$BASE/h-collections.js")"
assert_rows "S2" "$CO_REPORT" 33

# --- S2-mut: the /g statelessness rows must be able to fail. Without this, all four
# stateless-* rows would stay green even if readRegexConst stopped stripping /g on a
# subject that happens to reset lastIndex. A raw /g regex is driven through the identical
# two-call sequence and MUST disagree with itself. ---
S2_MUT="$( ( cd "$BASE" && node -e '
const re = /on-demand-only/g;
const s = "<!-- on-demand-only -->";
console.log(String(re.test(s)) + "," + String(re.test(s)));
' ) 2>&1 )"
if [ "$S2_MUT" = "true,false" ]; then
    pass "S2-mut: a /g regex really does alternate across two .test() calls — the stateless-* rows are a live check, not a tautology"
else
    fail "S2-mut: want 'true,false' from a raw /g regex, got '$S2_MUT' — the statelessness rows cannot be trusted to detect a surviving /g"
fi
