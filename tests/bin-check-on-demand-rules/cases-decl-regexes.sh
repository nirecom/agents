# shellcheck shell=bash
# Tests: bin/lib/check-on-demand-rules.js
# Tags: rules-injection, on-demand-rules, static-check, regex-boundary, mutation-probe, table-driven, TL2, scope:common

# WHY (CPR-WPH): three regexes decide whether the #2037 declarations are trusted at all.
# READERS_DECL_RE and MINIMIZED_DECL_RE re-assert, anchored at a line start, that the
# declaration the data reader parsed is genuinely present — the reader matches a constant
# NAME unanchored, so a same-suffixed constant elsewhere in the file would otherwise stand
# in for a missing declaration and every annotated rule would read as registered.
# MINIMIZED_KEY_RE constrains the one declaration value this checker opens from disk.

# The behavioural cases in cases-readers.sh / cases-minimized.sh drive whole fixture trees,
# which is the right layer for the violation tokens but a coarse one for a boundary: a tree
# either trips a token or does not, so a regex that is one character too loose is only
# visible when someone happens to write the fixture that exploits it.

# So each regex gets a boundary TABLE (the near-misses a contributor actually writes:
# commented-out decoys, a substring-name collision, let/var spellings, indentation) plus a
# MUTATION set — deliberately-wrong variants of the same regex, each of which must be
# rejected by at least one row. The mutation half is what stops the table from being a
# restatement of the implementation: a row set that no wrong regex fails is decorative.
# Assumes BASE, CHECKER_LIB, node_path(), pass(), fail() from the dispatcher and fixtures.sh.

echo ""
echo "=== declaration-gate regexes: boundary rows + mutation score ==="

DR_LIB="${CHECKER_LIB:-$AGENTS_DIR/bin/lib/check-on-demand-rules.js}"

if [ ! -f "$DR_LIB" ]; then
    fail "DR: IMPLEMENTATION MISSING: bin/lib/check-on-demand-rules.js"
else
    cat > "$BASE/decl-regexes.js" <<'DR_EOF'
"use strict";
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");
const out = [];

// The regexes live in a script with no module.exports, so they are recovered from the
// source text the same way the marker cases recover theirs. Recovery is REPORTED, not
// assumed: a rename would otherwise leave every row grading an undefined regex.
function recover(name) {
  const m = new RegExp("^\\s*(?:const|let|var)\\s+" + name + "\\s*=\\s*/(.*)/([a-z]*)\\s*;\\s*$", "m").exec(src);
  if (!m) return null;
  try { return new RegExp(m[1], m[2]); } catch (_) { return null; }
}

const DECLS = ["READERS_DECL_RE", "MINIMIZED_DECL_RE", "MINIMIZED_KEY_RE"];
const RE = {};
for (const n of DECLS) {
  RE[n] = recover(n);
  out.push("DECL=" + n + " FOUND=" + (RE[n] ? "yes" : "no"));
}

// decl rows are shared by the two anchored declaration gates (CPR-ORTH): they differ only
// in the constant name, so a divergence between them is itself the defect.
function declRows(cname) {
  return [
    ["plain",            "const " + cname + " = [", "yes"],
    ["let-spelling",     "let " + cname + " = [", "yes"],
    ["var-spelling",     "var " + cname + " = [", "yes"],
    ["indented",         "    const " + cname + " = [", "yes"],
    ["tight-spacing",    "const " + cname + "=[", "yes"],
    ["wide-spacing",     "const  " + cname + "  =  [", "yes"],
    ["third-line",       "\"use strict\";\nconst other = 1;\nconst " + cname + " = [", "yes"],
    ["line-comment",     "// const " + cname + " = [", "no"],
    ["block-comment",    " * const " + cname + " = [", "no"],
    ["prefix-collision", "const X_" + cname + " = [", "no"],
    ["suffix-collision", "const " + cname + "_EXTRA = [", "no"],
    ["object-not-array", "const " + cname + " = {", "no"],
    ["mid-line",         "let x = 1; const " + cname + " = [", "no"],
    ["assignment-only",  cname + " = [", "no"],
    ["no-initializer",   "const " + cname + ";", "no"],
  ];
}

const KEY_ROWS = [
  ["root-md",           "rules/x.md", "yes"],
  ["nested-md",         "rules/sub/x.md", "yes"],
  ["dots-not-a-segment","rules/a..b.md", "yes"],
  ["bare-dotenv",       ".env", "no"],
  ["traversal-dotenv",  "rules/../.env", "no"],
  ["traversal-nested",  "rules/sub/../../.env", "no"],
  ["traversal-mid-md",  "rules/sub/../x.md", "no"],
  // PINNED DEFECT, not the ideal answer. The negative lookahead sits AFTER `^rules\/`, and
  // its `(?:^|\/)` alternation can only anchor on a literal slash from that offset on, so a
  // `..` in the FIRST segment has nothing in front of it to match and slips through. The
  // ideal answer is "no"; "yes" is what the shipped regex says. See the GAP line below.
  ["traversal-first-segment", "rules/../secrets.md", "yes"],
  ["wrong-extension",   "rules/x.json", "no"],
  ["capitalized-root",  "Rules/x.md", "no"],
  ["absolute-posix",    "/rules/x.md", "no"],
  ["drive-letter",      "C:/rules/x.md", "no"],
  ["backslash-sep",     "rules\\x.md", "no"],
  ["empty-string",      "", "no"],
  ["trailing-newline",  "rules/x.md\n", "no"],
  ["smuggled-second",   "rules/x.md\n.env", "no"],
  ["outside-rules",     "skills/x.md", "no"],
  ["directory-only",    "rules/sub/", "no"],
];

function answer(re, subject) { re.lastIndex = 0; return re.test(subject) ? "yes" : "no"; }

function runRows(label, re, rows) {
  if (!re) return;
  for (const [id, subject, want] of rows) {
    out.push("ROW=" + label + ":" + id + " WANT=" + want + " GOT=" + answer(re, subject));
  }
}

runRows("readers", RE.READERS_DECL_RE, declRows("ON_DEMAND_READERS"));
runRows("minimized", RE.MINIMIZED_DECL_RE, declRows("MINIMIZED_UNCONDITIONAL"));
runRows("key", RE.MINIMIZED_KEY_RE, KEY_ROWS);

// Each mutant is a plausible weakening of the real regex. A row set that cannot fail any
// of them cannot detect the corresponding implementation mistake either.
const MUTANTS = [
  ["readers", "m-unanchored", /(?:const|let|var)\s+ON_DEMAND_READERS\s*=\s*\[/m, declRows("ON_DEMAND_READERS")],
  ["readers", "m-name-substring", /^\s*(?:const|let|var)\s+\w*ON_DEMAND_READERS\w*\s*=\s*\[/m, declRows("ON_DEMAND_READERS")],
  ["readers", "m-no-bracket", /^\s*(?:const|let|var)\s+ON_DEMAND_READERS\s*=/m, declRows("ON_DEMAND_READERS")],
  ["readers", "m-name-only", /ON_DEMAND_READERS/, declRows("ON_DEMAND_READERS")],
  ["minimized", "m-unanchored", /(?:const|let|var)\s+MINIMIZED_UNCONDITIONAL\s*=\s*\[/m, declRows("MINIMIZED_UNCONDITIONAL")],
  ["minimized", "m-const-only", /^\s*const\s+MINIMIZED_UNCONDITIONAL\s*=\s*\[/m, declRows("MINIMIZED_UNCONDITIONAL")],
  ["minimized", "m-no-bracket", /^\s*(?:const|let|var)\s+MINIMIZED_UNCONDITIONAL\s*=/m, declRows("MINIMIZED_UNCONDITIONAL")],
  ["key", "m-no-start-anchor", /rules\/(?!.*(?:^|\/)\.\.(?:\/|$))[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*\.md$/, KEY_ROWS],
  ["key", "m-no-end-anchor", /^rules\/(?!.*(?:^|\/)\.\.(?:\/|$))[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*\.md/, KEY_ROWS],
  ["key", "m-no-traversal-guard", /^rules\/[A-Za-z0-9._\-/]+\.md$/, KEY_ROWS],
  ["key", "m-case-insensitive", /^rules\/(?!.*(?:^|\/)\.\.(?:\/|$))[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*\.md$/i, KEY_ROWS],
  ["key", "m-multiline", /^rules\/(?!.*(?:^|\/)\.\.(?:\/|$))[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*\.md$/m, KEY_ROWS],
  ["key", "m-any-extension", /^rules\/(?!.*(?:^|\/)\.\.(?:\/|$))[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*\.[a-z]+$/, KEY_ROWS],
];

for (const [group, mid, mre, rows] of MUTANTS) {
  const killers = rows.filter(([, subject, want]) => answer(mre, subject) !== want).map(([id]) => id);
  out.push("MUTANT=" + group + ":" + mid + " KILLED=" + (killers.length ? "yes" : "no") + " BY=" + (killers.join(",") || "-"));
}
console.log(out.join("\n"));
DR_EOF

    DR_REPORT="$(node "$(node_path "$BASE/decl-regexes.js")" "$(node_path "$DR_LIB")" 2>&1)"

    # DR0: recovery first. Every row and every mutant below is skipped when a regex could
    # not be recovered, so without this the file would go quiet — and green — on a rename.
    DR_FOUND="$(printf '%s\n' "$DR_REPORT" | grep -c '^DECL=.* FOUND=yes' || true)"
    if [ "${DR_FOUND:-0}" = "3" ]; then
        pass "DR0: all three declaration-gate regex literals were recovered from the checker source"
    else
        fail "DR0: recovered ${DR_FOUND:-0} of 3 regex literals — the tables below grade nothing; report: $(printf '%s' "$DR_REPORT" | tr '\n' ' ' | cut -c1-300)"
    fi

    DR_ROWS=0; DR_BAD=0
    while IFS= read -r dr_line; do
        case "$dr_line" in ROW=*) ;; *) continue ;; esac
        dr_id="$(printf '%s' "$dr_line" | tr ' ' '\n' | grep '^ROW=' | cut -d= -f2-)"
        dr_want="$(printf '%s' "$dr_line" | tr ' ' '\n' | grep '^WANT=' | cut -d= -f2-)"
        dr_got="$(printf '%s' "$dr_line" | tr ' ' '\n' | grep '^GOT=' | cut -d= -f2-)"
        DR_ROWS=$((DR_ROWS + 1))
        if [ "$dr_want" != "$dr_got" ]; then
            DR_BAD=$((DR_BAD + 1))
            fail "DR1 [$dr_id]: the declaration gate answered '$dr_got', want '$dr_want' — a declaration this shape is graded the wrong way, so the policy is trusted (or distrusted) on the strength of a near-miss"
        fi
    done <<DR_TABLE
$DR_REPORT
DR_TABLE

    echo "GAP: MINIMIZED_KEY_RE accepts 'rules/../secrets.md' — the '..' guard only fires on a segment that has a slash in front of it, so a traversal in the FIRST segment reaches the resolve-and-read path and can name any .md at the repo root. Row [key:traversal-first-segment] PINS that behaviour (want 'yes'); the ideal answer is 'no'. Source fix is out of scope for a tests-only change."

    if [ "$DR_ROWS" -lt 48 ]; then
        fail "DR1: only $DR_ROWS boundary rows ran (want 48) — the table did not execute in full, so a passing verdict here would be vacuous"
    elif [ "$DR_BAD" = "0" ]; then
        pass "DR1: all $DR_ROWS boundary rows across the three regexes answered as specified"
    fi

    DR_MUT=0; DR_SURV=0
    while IFS= read -r dr_line; do
        case "$dr_line" in MUTANT=*) ;; *) continue ;; esac
        dr_mid="$(printf '%s' "$dr_line" | tr ' ' '\n' | grep '^MUTANT=' | cut -d= -f2-)"
        dr_kill="$(printf '%s' "$dr_line" | tr ' ' '\n' | grep '^KILLED=' | cut -d= -f2-)"
        DR_MUT=$((DR_MUT + 1))
        if [ "$dr_kill" != "yes" ]; then
            DR_SURV=$((DR_SURV + 1))
            fail "DR2 [$dr_mid]: this deliberately-weakened regex passes every row — the boundary table cannot tell it from the real one, so that class of mistake would ship undetected"
        fi
    done <<DR_MUT_TABLE
$DR_REPORT
DR_MUT_TABLE

    if [ "$DR_MUT" -lt 13 ]; then
        fail "DR2: only $DR_MUT mutants were scored (want 13) — the probe set did not run"
    elif [ "$DR_SURV" = "0" ]; then
        pass "DR2: mutation score $DR_MUT/$DR_MUT — every weakened variant of the three regexes is killed by the rows above"
    fi

    unset DR_REPORT DR_ROWS DR_BAD DR_MUT DR_SURV
fi
