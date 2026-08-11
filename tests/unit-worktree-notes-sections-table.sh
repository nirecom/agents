#!/usr/bin/env bash
# tests/unit-worktree-notes-sections-table.sh
# Tests: hooks/lib/worktree-notes-sections.js
# Tags: worktree-notes, parser, marker-regex, severity-marker, scan-section, table-driven, mutation-probe, TL1, scope:common
#
# hooks/lib/worktree-notes-sections.js is a parser: a section scanner plus
# THREE regex constants, each guarding a different failure mode. Everything
# downstream trusts their verdicts, and every one of these failures is
# invisible at the point it happens:
#   - PROMOTED_MARKER_RE — "has this entry already become a GitHub issue?"
#     A false negative files the same finding twice; a false positive silently
#     drops a finding on the floor (bin/worktree-notes-triage.js).
#   - SEVERITY_MARKER_RE — "is this entry severity:high?" Strict, canonical-form
#     only. A false positive dumps a full-text entry into the Final Report and
#     re-opens the CPR-UO blow-up of #1886; a false negative merely compresses
#     (fail-safe), which is why the non-canonical spellings are pinned as null.
#   - TRAILING_MARKER_RE — body stripping. Lenient by design (any kind, any
#     order). A miss leaks a raw `<!-- ... -->` marker into the Final Report and
#     into GitHub issue titles created from entry text.
#
# The table is then handed to bin/mutation-probe.sh as its test command: the
# probe breaks each regex constant in the module in turn and requires this file
# to fail for every one of them. A table that still passes against a broken
# constant is a table that is not testing that regex, and the probe says so with
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
const {
  parseSectionEntries,
  extractSection,
  markEntryPromoted,
  entryBody,
  scanSection,
  PROMOTED_MARKER_RE,
} = lib;

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

// severity|hasMarker|body of the first entry — the three per-entry verdicts the
// Final Report compression branches on (bin/render-final-report/notes.js).
function sevOf(entries) {
  if (entries.length === 0) return "0";
  const e = entries[0];
  return [
    e.severity === null || e.severity === undefined ? "null" : e.severity,
    e.hasMarker ? "T" : "F",
    e.body,
  ].join(":");
}

// entries|strayCount|stoppedAtSubHeading|subHeading. subHeading is normalized to
// "-" when absent so that null/undefined/"" all read the same in the table; the
// assertion that matters is the populated case.
function scanOf(s) {
  return [
    s.entries.length,
    s.strayCount,
    String(s.stoppedAtSubHeading),
    s.subHeading ? s.subHeading : "-",
  ].join(":");
}

const S = (body) => `# Worktree Notes\nBranch: t\n\n${body}\n`;
const B = (body) => S(`## BugsFound\n${body}`);
const sev = (line) => sevOf(parseSectionEntries(B(line), "BugsFound"));

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

  // --- SEVERITY_MARKER_RE (strict canonical-form recognition) -------------
  // Canonical form is `- <body> <!-- severity: high --> <!-- promoted: #N -->`.
  // Recognition is strict (anything else is null = compressed = fail-safe);
  // stripping is lenient (see entryBody cases below). The asymmetry is
  // deliberate — see the header.
  "sev-canonical": () => sev("- body <!-- severity: high -->"),
  "sev-with-promoted": () =>
    sev("- body <!-- severity: high --> <!-- promoted: #12 -->"),

  // Reversed order is NOT canonical: severity is not recognized (fail-safe to
  // compression) and promoted is not at EOL, but the body must still come out
  // clean because TRAILING_MARKER_RE strips in a loop regardless of kind.
  "sev-reversed": () =>
    sev("- body <!-- promoted: #12 --> <!-- severity: high -->"),

  "sev-no-inner-spaces": () => sev("- body <!--severity: high-->"),
  "sev-capitalized": () => sev("- body <!-- Severity: High -->"),
  "sev-no-space-after-colon": () => sev("- body <!-- severity:high -->"),
  "sev-uppercase-value": () => sev("- body <!-- severity: HIGH -->"),
  "sev-mid-line": () => sev("- a <!-- severity: high --> b"),
  "sev-unknown-value-medium": () => sev("- body <!-- severity: medium -->"),
  // `low` is an accepted CLI input value but is never written as a marker, so
  // the read side must treat it as an unknown value, not as a severity.
  "sev-unknown-value-low": () => sev("- body <!-- severity: low -->"),
  // The leading `(?:(?!<!--).)*` guard: any earlier HTML comment kills the match.
  "sev-preceded-by-comment": () =>
    sev("- a <!-- x --> b <!-- severity: high -->"),
  "sev-absent": () => sev("- body"),
  "sev-canonical-crlf": () =>
    sevOf(parseSectionEntries(CRLF(B("- body <!-- severity: high -->")), "BugsFound")),

  // --- PROMOTED_MARKER_RE capture group ----------------------------------
  "promoted-capture": () => {
    const m = PROMOTED_MARKER_RE.exec("- a <!-- promoted: #77 -->");
    return m === null ? "nomatch" : m[1];
  },

  // --- entryBody (lenient stripping) -------------------------------------
  "eb-both-markers": () =>
    entryBody("- x <!-- severity: high --> <!-- promoted: #3 -->"),
  "eb-promoted-only": () => entryBody("- x <!-- promoted: #3 -->"),
  "eb-severity-only": () => entryBody("- x <!-- severity: high -->"),
  "eb-reversed": () =>
    entryBody("- x <!-- promoted: #3 --> <!-- severity: high -->"),
  "eb-no-marker": () => entryBody("- x"),
  // An issue reference in the prose is body text, not a marker: keep it.
  "eb-keeps-issue-ref": () =>
    entryBody("- fix thing (#42) <!-- promoted: #42 -->"),

  // --- heading match rule (trimEnd) --------------------------------------
  // A trailing space on the heading used to make the whole section vanish
  // silently. `line.trimEnd() === "## " + heading` fixes that.
  "heading-trailing-space": () =>
    summarize(parseSectionEntries(S("## BugsFound \n- bug one\n"), "BugsFound")),
  // Extra space BEFORE the heading word is deliberately NOT accepted.
  "heading-leading-extra-space": () =>
    summarize(parseSectionEntries(S("##  BugsFound\n- bug one\n"), "BugsFound")),

  // --- scanSection -------------------------------------------------------
  "scan-stray-count": () =>
    scanOf(scanSection(B("- e1\nprose one\nprose two\n- (none)"), "BugsFound")),
  "scan-stray-count-crlf": () =>
    scanOf(scanSection(CRLF(B("- e1\nprose one\nprose two\n- (none)")), "BugsFound")),
  "scan-sub-heading": () =>
    scanOf(scanSection(B("- e1\n### Repro\n- e2"), "BugsFound")),
  "scan-missing-section": () =>
    scanOf(scanSection(S("## RelatedTasks\n- x"), "BugsFound")),
  "scan-duplicate-headings-merge": () =>
    scanOf(scanSection(
      S("## BugsFound\n- first block\n\n## BugsFound\n- second block"), "BugsFound")),
  "scan-heading-trailing-space": () =>
    scanOf(scanSection(S("## BugsFound \n- e1\n"), "BugsFound")),
  // parseSectionEntries must be a thin wrapper over scanSection().entries.
  "scan-matches-parse": () => {
    const doc = B("- one <!-- promoted: #1 -->\nprose\n- two <!-- severity: high -->");
    const a = JSON.stringify(scanSection(doc, "BugsFound").entries);
    const b = JSON.stringify(parseSectionEntries(doc, "BugsFound"));
    return String(a === b);
  },
  // N2: no unconsumed fields may creep back into the return shape.
  "scan-key-set": () =>
    Object.keys(scanSection(B("- e1"), "BugsFound")).sort().join(","),

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
sev-canonical|high:F:body
sev-with-promoted|high:T:body
sev-reversed|null:F:body
sev-no-inner-spaces|null:F:body
sev-capitalized|null:F:body
sev-no-space-after-colon|null:F:body
sev-uppercase-value|null:F:body
sev-mid-line|null:F:a <!-- severity: high --> b
sev-unknown-value-medium|null:F:body
sev-unknown-value-low|null:F:body
sev-preceded-by-comment|null:F:a <!-- x --> b
sev-absent|null:F:body
sev-canonical-crlf|high:F:body
promoted-capture|77
eb-both-markers|x
eb-promoted-only|x
eb-severity-only|x
eb-reversed|x
eb-no-marker|x
eb-keeps-issue-ref|fix thing (#42)
heading-trailing-space|1:- bug one:5:F
heading-leading-extra-space|0
scan-stray-count|1:2:false:-
scan-stray-count-crlf|1:2:false:-
scan-sub-heading|1:0:true:### Repro
scan-missing-section|0:0:false:-
scan-duplicate-headings-merge|2:0:false:-
scan-heading-trailing-space|1:0:false:-
scan-matches-parse|true
scan-key-set|entries,stoppedAtSubHeading,strayCount,subHeading
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
# re-implementation of it (CPR-SSOT — one owner for "how a mutation is applied").
# It rewrites each single-line `const NAME = /regex/;` in the target to a
# never-matching regex and requires the test command to FAIL for each one.
#
# --test-cmd is mandatory here: the probe's auto-detect resolves the test file
# from the `# Tests:` header, which is THIS file, and the child would run the
# probe again. MP_CHILD=1 makes the child run the table only.
#
# Threshold is 100, not the tool's default 80: the target declares exactly three
# regex constants (PROMOTED_MARKER_RE / SEVERITY_MARKER_RE / TRAILING_MARKER_RE),
# and 80% would let one of the three survive unkilled — which is exactly the
# state "we renamed/added a constant and forgot to test it" produces. Each
# constant owns a distinct, silent failure mode (see the header), so partial
# credit is not acceptable here. Adding a fourth constant to the module means
# adding both a case for it and a `^KILLED:` line below.
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
    # Every named regex constant in the module must die against this table.
    # Named individually (not just via the score) so a rename shows up as the
    # specific constant that lost coverage rather than as an opaque -33%.
    local rc_name
    for rc_name in PROMOTED_MARKER_RE SEVERITY_MARKER_RE TRAILING_MARKER_RE; do
        printf '%s\n' "$out" | grep -q "^KILLED: $rc_name" \
            || missing="$missing $rc_name-not-killed"
    done
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
