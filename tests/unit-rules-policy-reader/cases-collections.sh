# shellcheck shell=bash
# Tests: hooks/lib/rules-policy-reader.js
# Tags: rules-injection, policy-reader, string-array, regex-const, stateless-regex, parser, table-driven, TL2, scope:common
#
# The two collection parsers: readStringArrayConst() and readRegexConst(). CONTRACT: readStringArrayConst distinguishes "declared empty" ([]) from "not declared" (null), the same way readStringConst distinguishes "" from null — loadPolicyAsData collapses both to [] on purpose, so the distinction can only be pinned at this level.
# readRegexConst REBUILDS the literal with `new RegExp(source, flags)` and DROPS /g — a surviving /g makes .test() stateful through lastIndex, marking the same file annotated on one pass and bare on the next, the exact non-determinism the de-injection audit cannot tolerate. Both halves are asserted: the flag is gone, AND two consecutive .test() calls on one subject agree.
# An unparseable regex SOURCE yields null rather than throwing, so a malformed policy degrades to "no marker regex" instead of taking the consumer down.
# Both parsers ANCHOR the constant name on a real `const`/`let`/`var` declaration at line start (#2037), so a commented-out decoy and a same-suffixed identifier are "not declared" — the fail-closed answer. The loose end of the same anchor (indented / `let` / `var` spellings must still declare) is pinned alongside, so tightening it further would fail here rather than silently blank the policy.
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
  // The same defect one element later, where it is WORSE than the row above: the body is
  // cut mid-way, so the elements BEFORE the `]` still parse and the ones after it vanish.
  // The declaration then reads as a shorter but perfectly well-formed list — nothing about
  // the return value says "truncated", so no consumer can tell it was.
  ["aconst-bracket-in-later-element-drops-the-tail",
   "const ON_DEMAND_FILES = [\"a.md\", \"b]c.md\", \"d.md\"];", "A:[\"a.md\"]"],
  // Escaping the bracket in the JS literal does not help: the reader scans TEXT and never
  // interprets JS escapes when locating the array body, so `\]` closes the capture exactly
  // like a bare one. The author's `a].md` is unreachable by any spelling.
  ["aconst-escaped-bracket-still-truncates",
   "const ON_DEMAND_FILES = [\"a\\].md\", \"b.md\"];", "A:[]"],
  // NON-VACUITY CONTROL for the two rows above: byte-identical shapes with the bracket
  // removed must parse in FULL. Without it, "A:[]" and "A:[\"a.md\"]" would also be what a
  // reader that simply cannot handle three elements returns.
  ["aconst-same-shape-without-bracket-parses-fully",
   "const ON_DEMAND_FILES = [\"a.md\", \"bc.md\", \"d.md\"];", "A:[\"a.md\",\"bc.md\",\"d.md\"]"],
  // ANCHORED name match (#2037), same contract as readStringConst: a same-suffixed
  // identifier is a DIFFERENT constant, so borrowing its value would let a policy whose
  // real declaration is missing read as fully populated — the fail-OPEN direction.
  ["aconst-same-suffixed-name-does-not-match", "const X_ON_DEMAND_FILES = [\"x.md\"];", "NULL"],
  ["aconst-bare-assignment-is-not-a-declaration", "ON_DEMAND_FILES = [\"x.md\"];", "NULL"],
  ["aconst-commented-decoy-loses-to-the-real-declaration",
   "// const ON_DEMAND_FILES = [\"decoy.md\"];\nconst ON_DEMAND_FILES = [\"real.md\"];",
   "A:[\"real.md\"]"],
  // The anchor stays loose enough for ordinary JS spellings.
  ["aconst-indented-declaration-still-matches", "  const ON_DEMAND_FILES = [\"in.md\"];", "A:[\"in.md\"]"],
  ["aconst-let-spelling-matches", "let ON_DEMAND_FILES = [\"l.md\"];", "A:[\"l.md\"]"],
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
  // ANCHORED like its two siblings (#2037, CPR-ORTH). The marker regex decides which
  // rules count as deliberately de-injected, so a commented-out decoy that out-ranked the
  // live declaration would let a policy edit that no reviewer reads as code silently
  // redefine what "annotated" means for the whole tree.
  ["rconst-commented-decoy-loses-to-the-real-declaration",
   "// const ON_DEMAND_MARKER_RE = /decoy/;\nconst ON_DEMAND_MARKER_RE = /real/;",
   "R:real FLAGS:"],
  ["rconst-commented-decoy-alone-is-not-declared",
   "// const ON_DEMAND_MARKER_RE = /decoy/;\n", "NULL"],
  ["rconst-same-suffixed-name-does-not-match",
   "const X_ON_DEMAND_MARKER_RE = /prefixed/;", "NULL"],
  ["rconst-bare-assignment-is-not-a-declaration",
   "ON_DEMAND_MARKER_RE = /bare/;", "NULL"],
  // ...and not over-tightened: indentation and the let/var spellings still declare.
  ["rconst-indented-declaration-still-matches",
   "  const ON_DEMAND_MARKER_RE = /indented/;", "R:indented FLAGS:"],
  ["rconst-tab-indented-declaration-still-matches",
   "\tconst ON_DEMAND_MARKER_RE = /tabbed/;", "R:tabbed FLAGS:"],
  ["rconst-var-spelling-matches", "var ON_DEMAND_MARKER_RE = /varred/;", "R:varred FLAGS:"],
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
assert_rows "S2" "$CO_REPORT" 47

# --- S2b: readPairArrayConst (#2037) -------------------------------------------------
# WHY: the policy is parsed and never evaluated, so a "rule -> required readers" MAP cannot be an object literal — it rides inside the one-line string-literal shape the reader already trusts, as `"<key>|<v1>,<v2>"`. readPairArrayConst is that decoder.
# CONTRACT: it mirrors readStringArrayConst's "declared empty vs not declared" split and adds a third distinction the consumers depend on — an element with NO `|` is MALFORMED (values === null), not an entry with zero readers (values === []). Collapsing the two lets `["rules/x.md"]` (readers never declared) read as well-formed, and the ownership gate goes dark on exactly the rule whose ownership was forgotten.
# Split-once: only the FIRST `|` separates key from values, so a `|` in the value half survives verbatim instead of silently truncating the row.
cat > "$BASE/h-pairs.js" <<'PAIRS_EOF'
"use strict";
// argv[2] = hooks/lib/rules-policy-reader.js
const R = require(process.argv[2]);

const rows = [];
let pipes = 0;
function row(name, want, got) {
  if (String(want).includes("|") || String(got).includes("|")) pipes += 1;
  rows.push(["ROW", name, want, got].join("|"));
}

// Encoded field-by-field rather than via JSON.stringify so the assertion pins the VALUES,
// not the key insertion order of the returned object. A literal `|` inside a value is
// escaped to #PIPE# so the ROW encoding stays unambiguous.
const encP = (v) =>
  v === null
    ? "NULL"
    : "P:" +
      v
        .map((e) => e.key + "=>" + (e.values === null ? "NULL" : "[" + e.values.join(";") + "]"))
        .join(" ")
        .split("|")
        .join("#PIPE#");

const HAVE = typeof R.readPairArrayConst === "function";
const call = (src, name) => (HAVE ? encP(R.readPairArrayConst(src, name)) : "NO_FUNCTION:readPairArrayConst");

// name | source | want
const PCONST = [
  ["pair-single-reader",
   'const ON_DEMAND_READERS = ["rules/a.md|skills/x/SKILL.md"];',
   "P:rules/a.md=>[skills/x/SKILL.md]"],
  ["pair-multiple-readers-comma-split",
   'const ON_DEMAND_READERS = ["rules/a.md|skills/x/SKILL.md,skills/y/SKILL.md"];',
   "P:rules/a.md=>[skills/x/SKILL.md;skills/y/SKILL.md]"],
  ["pair-multi-line-two-rows",
   'const ON_DEMAND_READERS = [\n  "rules/a.md|skills/x/SKILL.md",\n  "rules/b.md|skills/y/SKILL.md",\n];',
   "P:rules/a.md=>[skills/x/SKILL.md] rules/b.md=>[skills/y/SKILL.md]"],
  // The malformed shape the consumers must be able to name: no separator at all.
  ["pair-no-separator-is-malformed-not-empty",
   'const ON_DEMAND_READERS = ["rules/a.md"];',
   "P:rules/a.md=>NULL"],
  // Split ONCE: a second `|` belongs to the value half; it neither starts a third field
  // nor truncates the row.
  ["pair-second-separator-stays-in-values",
   'const ON_DEMAND_READERS = ["rules/a.md|skills/x/SKILL.md|extra"];',
   "P:rules/a.md=>[skills/x/SKILL.md#PIPE#extra]"],
  // Separator present, value half empty -> zero readers, DISTINCT from malformed above.
  ["pair-separator-with-empty-values",
   'const ON_DEMAND_READERS = ["rules/a.md|"];',
   "P:rules/a.md=>[]"],
  ["pair-empty-array-is-not-absent", "const ON_DEMAND_READERS = [];", "P:"],
  ["pair-declaration-absent", 'const SOMETHING_ELSE = ["rules/a.md|skills/x/SKILL.md"];', "NULL"],
  ["pair-empty-source", "", "NULL"],
  // ANCHORED (#2037), inherited from readStringArrayConst, which this decoder still
  // delegates to: a longer identifier ending in the requested name is a different
  // constant, so the ownership table cannot be silently supplied by a decoy while the
  // real ON_DEMAND_READERS is missing.
  ["pair-same-suffixed-name-does-not-match",
   'const X_ON_DEMAND_READERS = ["rules/a.md|skills/x/SKILL.md"];',
   "NULL"],
  ["pair-commented-decoy-loses-to-the-real-declaration",
   '// const ON_DEMAND_READERS = ["rules/decoy.md|skills/decoy/SKILL.md"];\nconst ON_DEMAND_READERS = ["rules/real.md|skills/real/SKILL.md"];',
   "P:rules/real.md=>[skills/real/SKILL.md]"],
  // --- `]`-truncation, INHERITED (this decoder delegates to readStringArrayConst) ------
  // The array body is captured non-greedily to the FIRST `]`, so a bracket anywhere inside
  // any element cuts the body mid-literal. The now-unbalanced quote matches nothing and the
  // whole declaration decodes as EMPTY — which is `[]`, not null, so every consumer that
  // asks "was it declared?" answers yes and then iterates zero rows. Silent, not loud.
  ["pair-bracket-in-key-empties-the-whole-table",
   'const ON_DEMAND_READERS = ["rules/a[0].md|skills/x/SKILL.md"];', "P:"],
  ["pair-bracket-in-value-empties-the-whole-table",
   'const ON_DEMAND_READERS = ["rules/a.md|skills/x[1]/SKILL.md"];', "P:"],
  // Worse than a wholesale empty: a bracket in a LATER row keeps the earlier rows and drops
  // the rest, so the table reads as a shorter, well-formed table and nothing reports a loss.
  ["pair-bracket-in-later-row-drops-the-tail",
   'const ON_DEMAND_READERS = ["rules/a.md|skills/x/SKILL.md", "rules/b].md|skills/y/SKILL.md"];',
   "P:rules/a.md=>[skills/x/SKILL.md]"],
  // Escaping does not rescue it: the reader locates the body in TEXT, before any JS escape
  // has meaning, so `\]` closes the capture exactly like a bare `]`.
  ["pair-escaped-bracket-still-truncates",
   'const ON_DEMAND_READERS = ["rules/a\\].md|skills/x/SKILL.md"];', "P:"],
  // NON-VACUITY CONTROL for the four rows above: the same two-row shape with the bracket
  // removed must decode BOTH rows. Otherwise "P:" and a one-row answer would equally be
  // what a decoder that cannot handle two rows at all returns.
  ["pair-same-shape-without-bracket-decodes-both-rows",
   'const ON_DEMAND_READERS = ["rules/a.md|skills/x/SKILL.md", "rules/b.md|skills/y/SKILL.md"];',
   "P:rules/a.md=>[skills/x/SKILL.md] rules/b.md=>[skills/y/SKILL.md]"],
];
PCONST.forEach(([name, src, want]) => row(name, want, call(src, "ON_DEMAND_READERS")));

// The MINIMIZED_UNCONDITIONAL shape: same decoder, one pointer in the value half.
row("pair-minimized-pointer-shape",
    "P:rules/workflow-off.md=>[skills/enforce-workflow-off/SKILL.md]",
    call('const MINIMIZED_UNCONDITIONAL = ["rules/workflow-off.md|skills/enforce-workflow-off/SKILL.md"];',
         "MINIMIZED_UNCONDITIONAL"));

rows.push("PIPEGUARD=" + pipes);
console.log(rows.join("\n"));
PAIRS_EOF

PAIR_REPORT="$(run_rows "$BASE/h-pairs.js")"
assert_rows "S2b" "$PAIR_REPORT" 17

# --- S2b-mut: the decoder must be its OWN function, not readStringArrayConst renamed.
# An alias would satisfy every single-element row above, leaving the malformed row as the
# only guard. The raw reader is driven over the same source and MUST return it undecoded. ---
cat > "$BASE/h-pairs-mut.js" <<'PAIRS_MUT_EOF'
"use strict";
const R = require(process.argv[2]);
const src = 'const ON_DEMAND_READERS = ["rules/a.md|skills/x/SKILL.md"];';
console.log(JSON.stringify(R.readStringArrayConst(src, "ON_DEMAND_READERS")));
PAIRS_MUT_EOF
S2B_MUT="$(run_rows "$BASE/h-pairs-mut.js")"
if [ "$S2B_MUT" = '["rules/a.md|skills/x/SKILL.md"]' ]; then
    pass "S2b-mut: readStringArrayConst still returns the row UNdecoded — the S2b rows measure readPairArrayConst's own decoding, not an alias"
else
    fail "S2b-mut: want the raw undecoded element from readStringArrayConst, got '$S2B_MUT' — the S2b rows cannot be trusted to prove a separate decoder exists"
fi

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
