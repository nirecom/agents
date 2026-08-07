#!/usr/bin/env bash
# tests/unit-worktree-notes-sections-table.sh
# Tests: hooks/lib/worktree-notes-sections.js
# Tags: worktree-notes, parser, marker-regex, table-driven, mutation-probe, TL1, scope:common
#
# hooks/lib/worktree-notes-sections.js is a parser: a section scanner plus one
# regex constant (MARKER_RE) that decides whether an entry has already been
# promoted. Everything downstream trusts that decision — a false negative files
# the same finding as a second GitHub issue, a false positive silently drops a
# finding on the floor. Both failures are invisible in the promotion flow, so
# the regex and the section boundaries are pinned here case by case.
#
# The table is then handed to bin/mutation-probe.sh as its test command: the
# probe breaks each regex constant in the module in turn and requires this file
# to fail for every one of them. A table that still passes against a broken
# MARKER_RE is a table that is not testing the regex, and the probe says so with
# an explicit mutation score checked against MP_THRESHOLD below.
#
# TL1: pure in-process parsing, no subprocess under test beyond the node host.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
LIB_JS="$AGENTS_DIR/hooks/lib/worktree-notes-sections.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }

if [ ! -f "$LIB_JS" ]; then
    echo "FAIL: precondition missing — hooks/lib/worktree-notes-sections.js"
    echo ""
    echo "Total: PASS=0 FAIL=1"
    exit 1
fi

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wn-sections-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# ---------------------------------------------------------------------------
# Runner: prints one `<case-name>|<result>` line per case for the given module.
# Results are compact strings so the expectations below read as a table.
# ---------------------------------------------------------------------------
cat > "$TMPD/run-cases.js" <<'JS'
"use strict";
const lib = require(process.argv[2]);
const { parseSectionEntries, extractSection, markEntryPromoted } = lib;

const CRLF = (s) => s.replace(/\n/g, "\r\n");

// count[:raw of first entry][:hasMarker flags joined]
function summarize(entries) {
  if (entries.length === 0) return "0";
  return [
    entries.length,
    entries[0].raw,
    entries[0].lineNumber,
    entries.map((e) => (e.hasMarker ? "T" : "F")).join(""),
  ].join(":");
}

const S = (body) => `# Worktree Notes\nBranch: t\n\n${body}\n`;

const CASES = {
  // --- section boundaries ------------------------------------------------
  "missing-section": () =>
    summarize(parseSectionEntries(S("## RelatedTasks\n- only this"), "BugsFound")),

  "empty-section": () =>
    summarize(parseSectionEntries(S("## BugsFound\n\n## RelatedTasks\n- x"), "BugsFound")),

  "placeholder-only": () =>
    summarize(parseSectionEntries(S("## BugsFound\n- (none)\n"), "BugsFound")),

  "single-entry": () =>
    summarize(parseSectionEntries(S("## BugsFound\n- bug one\n"), "BugsFound")),

  "two-entries": () =>
    summarize(parseSectionEntries(S("## BugsFound\n- bug one\n- bug two\n"), "BugsFound")),

  // A second identical heading re-enters the section rather than ending it —
  // the heading test runs before the "next `## ` ends the section" test — so a
  // duplicated `## BugsFound` merges both blocks. Pinned because the merge is
  // the safe direction (entries in the second block are still promoted); the
  // silent-loss direction is what must never appear here.
  "duplicate-section-headers": () =>
    summarize(parseSectionEntries(
      S("## BugsFound\n- first block\n\n## BugsFound\n- second block\n"), "BugsFound")),

  // `### ` inside the section terminates it.
  "nested-heading-terminates": () =>
    summarize(parseSectionEntries(
      S("## BugsFound\n- before\n\n### Details\n- after\n"), "BugsFound")),

  // A heading that merely starts with the name is a different section.
  "similar-heading-not-matched": () =>
    summarize(parseSectionEntries(S("## BugsFoundLater\n- nope\n"), "BugsFound")),

  // Only `- ` bullets at column 0 are entries; an indented continuation is not.
  "indented-bullet-ignored": () =>
    summarize(parseSectionEntries(S("## BugsFound\n- bug one\n  - detail\n"), "BugsFound")),

  "placeholder-plus-real-entry": () =>
    summarize(parseSectionEntries(S("## BugsFound\n- (none)\n- real one\n"), "BugsFound")),

  "crlf-document": () =>
    summarize(parseSectionEntries(CRLF(S("## BugsFound\n- bug one\n")), "BugsFound")),

  // --- MARKER_RE ---------------------------------------------------------
  "marked-entry": () =>
    summarize(parseSectionEntries(
      S("## BugsFound\n- bug one <!-- promoted: #12 -->\n"), "BugsFound")),

  "marked-entry-crlf": () =>
    summarize(parseSectionEntries(
      CRLF(S("## BugsFound\n- bug one <!-- promoted: #12 -->\n")), "BugsFound")),

  "mixed-marked-and-unmarked": () =>
    summarize(parseSectionEntries(
      S("## BugsFound\n- one <!-- promoted: #1 -->\n- two\n- three <!-- promoted: #3 -->\n"),
      "BugsFound")),

  // Two markers on one line: the trailing one still satisfies the regex. The
  // duplicate is a data defect, not a parse failure — annotate must not create
  // it (see the idempotency case in the triage-flow suite).
  "duplicate-markers-one-line": () =>
    summarize(parseSectionEntries(
      S("## BugsFound\n- one <!-- promoted: #1 --> <!-- promoted: #2 -->\n"), "BugsFound")),

  // Malformed suffixes must NOT count as promoted, or the finding is dropped.
  "marker-non-numeric": () =>
    summarize(parseSectionEntries(
      S("## BugsFound\n- one <!-- promoted: #abc -->\n"), "BugsFound")),

  "marker-empty-number": () =>
    summarize(parseSectionEntries(
      S("## BugsFound\n- one <!-- promoted: # -->\n"), "BugsFound")),

  "marker-missing-hash": () =>
    summarize(parseSectionEntries(
      S("## BugsFound\n- one <!-- promoted: 12 -->\n"), "BugsFound")),

  "marker-not-at-end": () =>
    summarize(parseSectionEntries(
      S("## BugsFound\n- one <!-- promoted: #12 --> trailing words\n"), "BugsFound")),

  "marker-no-leading-space": () =>
    summarize(parseSectionEntries(
      S("## BugsFound\n- one<!-- promoted: #12 -->\n"), "BugsFound")),

  "marker-trailing-space": () =>
    summarize(parseSectionEntries(
      S("## BugsFound\n- one <!-- promoted: #12 --> \n"), "BugsFound")),

  // --- extractSection ----------------------------------------------------
  "extract-missing": () => extractSection(S("## RelatedTasks\n- x"), "BugsFound"),
  "extract-placeholder": () => extractSection(S("## BugsFound\n- (none)"), "BugsFound"),
  "extract-single": () => extractSection(S("## BugsFound\n- bug one"), "BugsFound"),
  "extract-two": () => extractSection(S("## BugsFound\n- a\n- b"), "BugsFound").replace(/\n/g, "~"),

  // --- markEntryPromoted -------------------------------------------------
  "mark-appends": () => {
    const out = markEntryPromoted("- one\n- two\n", 1, 7);
    return JSON.stringify(out);
  },
  "mark-preserves-crlf": () => {
    const out = markEntryPromoted("- one\r\n- two\r\n", 1, 7);
    return JSON.stringify(out);
  },
  "mark-out-of-range": () => {
    const src = "- one\n";
    return String(markEntryPromoted(src, 99, 7) === src);
  },
  "mark-line-zero": () => {
    const src = "- one\n";
    return String(markEntryPromoted(src, 0, 7) === src);
  },
};

for (const [name, fn] of Object.entries(CASES)) {
  let out;
  try { out = String(fn()); } catch (e) { out = "THREW:" + e.message; }
  process.stdout.write(name + "|" + out.replace(/\n/g, "~") + "\n");
}
JS

run_cases() {
    node "$(nodepath "$TMPD/run-cases.js")" "$(nodepath "$1")" 2>&1
}

REAL_OUT="$(run_cases "$LIB_JS")"
if ! printf '%s\n' "$REAL_OUT" | grep -q '^missing-section|'; then
    fail "runner did not execute against the real module" "$(printf '%s' "$REAL_OUT" | head -c 400)"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

result_of() { printf '%s\n' "$REAL_OUT" | grep "^$1|" | head -1 | cut -d'|' -f2-; }

# ---------------------------------------------------------------------------
# The table. Result format for parse cases:
#   0                                   → no entries
#   <count>:<first raw>:<first line>:<hasMarker flags, T/F per entry>
# ---------------------------------------------------------------------------
check_table() {
    local name want got
    while IFS='|' read -r name want; do
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        got="$(result_of "$name")"
        if [ "$got" = "$want" ]; then
            pass "$name → $want"
        else
            fail "$name" "got=[$got] want=[$want]"
        fi
    done <<'TABLE'
missing-section|0
empty-section|0
placeholder-only|0
single-entry|1:- bug one:5:F
two-entries|2:- bug one:5:FF
duplicate-section-headers|2:- first block:5:FF
nested-heading-terminates|1:- before:5:F
similar-heading-not-matched|0
indented-bullet-ignored|1:- bug one:5:F
placeholder-plus-real-entry|1:- real one:6:F
crlf-document|1:- bug one:5:F
marked-entry|1:- bug one <!-- promoted: #12 -->:5:T
marked-entry-crlf|1:- bug one <!-- promoted: #12 -->:5:T
mixed-marked-and-unmarked|3:- one <!-- promoted: #1 -->:5:TFT
duplicate-markers-one-line|1:- one <!-- promoted: #1 --> <!-- promoted: #2 -->:5:T
marker-non-numeric|1:- one <!-- promoted: #abc -->:5:F
marker-empty-number|1:- one <!-- promoted: # -->:5:F
marker-missing-hash|1:- one <!-- promoted: 12 -->:5:F
marker-not-at-end|1:- one <!-- promoted: #12 --> trailing words:5:F
marker-no-leading-space|1:- one<!-- promoted: #12 -->:5:F
marker-trailing-space|1:- one <!-- promoted: #12 --> :5:F
extract-missing|(none)
extract-placeholder|(none)
extract-single|- bug one
extract-two|- a~- b
mark-appends|"- one <!-- promoted: #7 -->\n- two\n"
mark-preserves-crlf|"- one <!-- promoted: #7 -->\r\n- two\r\n"
mark-out-of-range|true
mark-line-zero|true
TABLE
}

# ---------------------------------------------------------------------------
# Mutation probe (required): the repo's own bin/mutation-probe.sh, not a local
# re-implementation of it (CPR-2 — one owner for "how a mutation is applied").
# It rewrites each single-line `const NAME = /regex/;` in the target to a
# never-matching regex and requires the test command to FAIL for each one.
#
# --test-cmd is mandatory here: the probe's auto-detect resolves the test file
# from the `# Tests:` header, which is THIS file, and the child would run the
# probe again. MP_CHILD=1 makes the child run the table only.
#
# Threshold is 100, not the tool's default 80: the target declares exactly one
# regex constant (MARKER_RE), so 80% would round down to "0 of 1 killed passes".
MP_THRESHOLD=100

mutation_probe() {
    local probe="$AGENTS_DIR/bin/mutation-probe.sh" out rc score missing=""
    if [ ! -f "$probe" ]; then
        fail "MP: bin/mutation-probe.sh missing" "expected at $probe"
        return
    fi

    out="$(MP_CHILD=1 bash "$probe" --threshold "$MP_THRESHOLD" \
            --test-cmd "MP_CHILD=1 bash '$AGENTS_DIR/tests/unit-worktree-notes-sections-table.sh'" \
            "$LIB_JS" 2>&1)"
    rc=$?

    # The tool reports "KILLED: <k> / <n> (score: <s>%)".
    score="$(printf '%s\n' "$out" | sed -n 's/.*(score: \([0-9]*\)%).*/\1/p' | head -1)"
    [ -n "$score" ] || missing="$missing no-score-reported"
    printf '%s\n' "$out" | grep -q '^KILLED: MARKER_RE' || missing="$missing MARKER_RE-not-killed"
    printf '%s\n' "$out" | grep -q '^LIVE:' && missing="$missing live-mutant-survived"
    if [ -n "$score" ] && [ "$score" -lt "$MP_THRESHOLD" ]; then
        missing="$missing score=$score<$MP_THRESHOLD"
    fi
    [ "$rc" = "0" ] || missing="$missing probe-rc=$rc"

    # The probe restores the file from its backup; a leftover backup means it
    # died mid-run and the working tree is not what it was.
    [ -e "$LIB_JS.probe-backup" ] && missing="$missing backup-left-behind"

    if [ -z "$missing" ]; then
        pass "MP: bin/mutation-probe.sh scores ${score}% (>= ${MP_THRESHOLD}%) against this table — every regex constant in the target has a case that dies with it"
    else
        fail "MP: mutation score below threshold or probe unusable" "$missing (out=$out)"
    fi
}

check_table
# The probe re-enters this file as its test command; the child asserts the table
# against the mutated module and must not launch another probe.
if [ "${MP_CHILD:-0}" != "1" ]; then
    mutation_probe
fi

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
