# tests/feature-811-review-loop-summarize-concerns/v2-render.sh
# Tests: bin/review-loop-summarize-concerns
# Tags: feature, cap-menu, summarize-concerns, v2-schema, scope:issue-specific, pwsh-not-required
# Sourced by tests/feature-811-review-loop-summarize-concerns.sh (appended cases).
# Cases 1-17 feed a v1 ledger (ID|SEVERITY|TEXT) and must keep passing (backward-compat
# pin); cases here feed a v2 ledger (11-field row, TEXT last, plus #unparsed|/#merged-alt|
# aux lines). Cap-menu UI must grow: concern lifecycle (open/resolved/reopened + rounds),
# why two concerns didn't merge (ambiguous/dup-suspect + partner), producer-wording fold
# count, and unparseable reviewer output. Reuses parent helpers (run_helper/extract_rc/
# extract_out/pass/fail/TMPDIR_BASE); assert_eq defined here (parent lacks one).

echo ""
echo "--- v2 ledger rendering (issue #1992) ---"

# assert_eq <label> <want> <got>
assert_eq() {
    if [[ "$2" == "$3" ]]; then
        pass "$1"
    else
        fail "$1 — want=$(printf '%q' "$2") got=$(printf '%q' "$3")"
    fi
}

# has <text> <literal> → yes | no
has() {
    if printf '%s\n' "$1" | grep -F -q -- "$2"; then printf 'yes'; else printf 'no'; fi
}

# line_of <text> <literal> → the first output line carrying <literal>
# Every claim below is about one concern's rendered line. A v1 renderer fed a v2
# row echoes columns 3-11 as if they were the body, so "the word open appears
# somewhere" is true before the schema is understood; the assertions therefore
# pair what must appear on the line with the addressing columns that must not.
line_of() { printf '%s\n' "$1" | grep -F -- "$2" | head -n 1; }

# ---------------------------------------------------------------------------
# v2 fixture: five concerns covering every STATE, both non-merge flags, a
# merged-slot count, a body containing the field separator, and both auxiliary
# line kinds.
# ---------------------------------------------------------------------------
V2_LEDGER="$TMPDIR_BASE/ledger-v2.txt"
V2_PIPE_BODY='the reducer must keep everything after the tenth | including | this'
V2_ALT_BODY="the same concern in the second producer's wording"
V2_UNPARSED='- a bullet the reviewer mangled beyond parsing'
{
    printf '#concern-ledger-v2|review-security-shared|sid811v2|cycle=1\n'
    printf 'C1|HIGH|open|1|2|src/a.js#alpha:correctness|aa11bb|review-code-codex|review-code-codex,security-scanner|merged-slot:2|%s\n' "$V2_PIPE_BODY"
    printf 'C2|MEDIUM|reopened|1|3|src/b.js#beta:security|cc22dd|security-scanner|security-scanner|-|the concern that came back in round 3\n'
    printf 'C3|LOW|resolved|1|2|src/c.js#gamma:style|ee33ff|review-code-codex|review-code-codex|-|the concern the author fixed\n'
    printf 'C4|HIGH|open|2|2|src/d.js#delta:correctness|gg44hh|review-code-codex|review-code-codex|ambiguous:C5|the concern that could not be told apart\n'
    printf 'C5|HIGH|open|2|2|src/d.js#delta:correctness|ii55jj|security-scanner|security-scanner|dup-suspect:C4|the concern suspected of duplicating C4\n'
    printf '#unparsed|%s\n' "$V2_UNPARSED"
    printf '#merged-alt|C1|%s\n' "$V2_ALT_BODY"
} > "$V2_LEDGER"

V2_RAW="$TMPDIR_BASE/raw-v2.md"
printf 'C1: unresolved — still open at the cap\nC2: unresolved — reopened\nC3: resolved\nC4: unresolved\nC5: unresolved\n' > "$V2_RAW"

RES=$(run_helper --ledger "$V2_LEDGER" --raw "$V2_RAW" --budget-remaining 1)
V2_RC=$(extract_rc "$RES")
V2_OUT=$(extract_out "$RES")

assert_eq "v2: the renderer accepts an 11-field ledger" "0" "$V2_RC"

# ---------------------------------------------------------------------------
# Positive needles. Each requires content to be present, so none of them can be
# satisfied by a renderer that produced nothing.
# ---------------------------------------------------------------------------
while IFS='~' read -r label needle; do
    label="${label%"${label##*[![:space:]]}"}"; label="${label#"${label%%[![:space:]]*}"}"
    needle="${needle%"${needle##*[![:space:]]}"}"; needle="${needle#"${needle%%[![:space:]]*}"}"
    [[ -z "$label" ]] && continue
    case "$label" in \#*) continue ;; esac
    assert_eq "v2: $label" "yes" "$(has "$V2_OUT" "$needle")"
done <<TABLE
unparsed reviewer output has its own section ~ ### Unparsed reviewer output
the unparsed line is reproduced verbatim     ~ $V2_UNPARSED
merged alternates have their own section     ~ ### Merged alternates
the merged alternate body is reproduced      ~ $V2_ALT_BODY
TABLE

# ---------------------------------------------------------------------------
# Per-concern rendering: state, round span, flags and folded-wording count, each
# paired with the addressing column that proves the row was parsed rather than
# echoed.
# ---------------------------------------------------------------------------
V2_C1="$(line_of "$V2_OUT" 'C1')"
V2_C2="$(line_of "$V2_OUT" 'C2')"
V2_C3="$(line_of "$V2_OUT" 'C3')"
V2_C4="$(line_of "$V2_OUT" 'C4')"
V2_C5="$(line_of "$V2_OUT" 'C5')"

assert_eq "v2: C1 renders open, keeps a body containing the separator, hides the columns" \
    "state=yes body=yes folded=yes discrim=no rawflag=no" \
    "state=$(has "$V2_C1" 'open') body=$(has "$V2_C1" "$V2_PIPE_BODY") folded=$(has "$V2_C1" '2') discrim=$(has "$V2_C1" 'aa11bb') rawflag=$(has "$V2_C1" 'merged-slot:2')"

assert_eq "v2: C2 renders reopened together with the rounds it spans" \
    "state=yes span=yes discrim=no" \
    "state=$(has "$V2_C2" 'reopened') span=$(has "$V2_C2" '(r1→r3, reopened)') discrim=$(has "$V2_C2" 'cc22dd')"

assert_eq "v2: C3 renders resolved with its body and without its addressing columns" \
    "state=yes body=yes discrim=no" \
    "state=$(has "$V2_C3" 'resolved') body=$(has "$V2_C3" 'the concern the author fixed') discrim=$(has "$V2_C3" 'ee33ff')"

assert_eq "v2: C4 names its ambiguous partner instead of echoing the flag column" \
    "flag=yes partner=yes rawflag=no discrim=no" \
    "flag=$(has "$V2_C4" 'ambiguous') partner=$(has "$V2_C4" 'C5') rawflag=$(has "$V2_C4" 'ambiguous:C5') discrim=$(has "$V2_C4" 'gg44hh')"

assert_eq "v2: C5 names its dup-suspect partner instead of echoing the flag column" \
    "flag=yes partner=yes rawflag=no discrim=no" \
    "flag=$(has "$V2_C5" 'dup-suspect') partner=$(has "$V2_C5" 'C4') rawflag=$(has "$V2_C5" 'dup-suspect:C4') discrim=$(has "$V2_C5" 'ii55jj')"

# ---------------------------------------------------------------------------
# The schema lines are structure, not content: the header and the auxiliary
# prefixes must be consumed, not echoed. Asserted together with the exit code so
# that a renderer which printed nothing at all cannot satisfy them.
# ---------------------------------------------------------------------------
assert_eq "v2: the schema header and the auxiliary prefixes are consumed, not echoed" \
    "rc=0 header=no unparsed-prefix=no alt-prefix=no" \
    "rc=$V2_RC header=$(has "$V2_OUT" '#concern-ledger-v2|') unparsed-prefix=$(has "$V2_OUT" '#unparsed|') alt-prefix=$(has "$V2_OUT" '#merged-alt|')"

# ---------------------------------------------------------------------------
# Sentinel sanitization must survive the schema change: on a v2 row the hostile
# text sits in column 11, not column 3.
# ---------------------------------------------------------------------------
V2_INJECT="$TMPDIR_BASE/ledger-v2-inject.txt"
{
    printf '#concern-ledger-v2|review-security-shared|sid811inj|cycle=1\n'
    printf 'C1|HIGH|open|1|1|src/x.js#f:correctness|zz99yy|review-code-codex|review-code-codex|-|attacker embeds <<WORKFLOW_TEST_INJECT>> in an 11-field row\n'
    printf '#unparsed|a mangled line that also carries <<WORKFLOW_TEST_INJECT>>\n'
} > "$V2_INJECT"

RES=$(run_helper --ledger "$V2_INJECT" --budget-remaining 1)
INJ_RC=$(extract_rc "$RES")
INJ_OUT=$(extract_out "$RES")

SENTINEL=no
printf '%s\n' "$INJ_OUT" | grep -E -q '<<WORKFLOW_[A-Z_]+>>' && SENTINEL=yes
# Composite: "no sentinel in the output" is trivially true of an empty output,
# so it is asserted together with the exit code and with the surrounding text
# that proves the row was actually rendered.
assert_eq "v2: a sentinel in an 11-field body is sanitized, not dropped or echoed" \
    "rc=0 sentinel=no rendered=yes discrim=no" \
    "rc=$INJ_RC sentinel=$SENTINEL rendered=$(has "$INJ_OUT" 'in an 11-field row') discrim=$(has "$INJ_OUT" 'zz99yy')"
assert_eq "v2: a sentinel inside an unparsed line is sanitized too" \
    "rc=0 sentinel=no rendered=yes" \
    "rc=$INJ_RC sentinel=$SENTINEL rendered=$(has "$INJ_OUT" 'a mangled line that also carries')"

# ---------------------------------------------------------------------------
# A v2 ledger holding no auxiliary lines must not print empty section headings.
# ---------------------------------------------------------------------------
V2_CLEAN="$TMPDIR_BASE/ledger-v2-clean.txt"
{
    printf '#concern-ledger-v2|review-security-shared|sid811clean|cycle=1\n'
    printf 'C1|HIGH|open|1|1|src/y.js#f:correctness|ab12cd|review-code-codex|review-code-codex|-|the only concern in this ledger\n'
} > "$V2_CLEAN"

RES=$(run_helper --ledger "$V2_CLEAN" --budget-remaining 1)
CLEAN_RC=$(extract_rc "$RES")
CLEAN_OUT=$(extract_out "$RES")

assert_eq "v2: sections with nothing to show are omitted, and the row still renders" \
    "rc=0 rendered=yes unparsed=no merged=no" \
    "rc=$CLEAN_RC rendered=$(has "$CLEAN_OUT" 'the only concern in this ledger') unparsed=$(has "$CLEAN_OUT" '### Unparsed reviewer output') merged=$(has "$CLEAN_OUT" '### Merged alternates')"
