#!/bin/bash
# tests/fix-2098-extract-field-error-branch.sh
# Tests: bin/github-issues/lib/extract-field.sh, bin/github-issues/issue-to-history.sh
# Tags: github, issues, extract-field, history, error-branch, scope:issue-specific, layer:TL2
#
# extract_field_or_marker()'s rc=3 branch: when extract_field itself FAILS, the
# helper must stay silent on stdout and emit NO marker — a parse failure is not
# the fact "unrecorded", and printing the marker would fabricate exactly what
# #2098 removes. E2 pins the call-path consequence: issue-to-history.sh must
# propagate that failure instead of swallowing it in a command substitution.

set -u

PASS=0
FAIL=0

# TL3 gap (what this test does NOT catch):
# - Real `gh` JSON / real bin/doc-append.py argument handling (E2 uses stubs).
# - The deployed ~/.claude/ copy of extract-field.sh (the in-repo path is sourced).
# - GitHub's hosted renderer deciding the body shape awk actually receives.
# Closest-to-action mitigation: bin/check-verification-gate.sh has no category
# covering bin/github-issues/**, so no preflight ask fires; the residue is
# closed by the plan's manual render check before merge.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$AGENTS_DIR/bin/github-issues/lib/extract-field.sh"
SCRIPT="$AGENTS_DIR/bin/github-issues/issue-to-history.sh"
MOCK_DIR="$AGENTS_DIR/tests/fixtures/gh-mock"

# Documented marker recipe (SSOT: extract-field.sh, extract_field_or_marker()).
MARKER_ERE='\(no (Background|Changes|Cause|Fix) recorded\)'

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

TMP="$(mktemp -d)"
cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; }
trap cleanup EXIT

if [ ! -f "$LIB" ]; then
    fail "precondition missing — $LIB"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi
# shellcheck disable=SC1090
. "$LIB"

REAL_EXTRACT_FIELD="$(declare -f extract_field)"

# ---------------------------------------------------------------------------
# E1 (Error case, TL1) — extract_field fails for every one of the four field
# names. Table-driven: one logical path, four inputs; a per-field regression
# (a `case` arm returning the marker anyway) hides behind a single-field test.
# ---------------------------------------------------------------------------
extract_field() {
    printf 'STUB-DIAGNOSTIC: forced extract_field failure for %s\n' "$1" >&2
    return 1
}

while IFS='|' read -r name field; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; field="${field//[[:space:]]/}"

    BODY="### ${field}"$'\n\n'"some text" \
        extract_field_or_marker "$field" >"$TMP/e1.out" 2>"$TMP/e1.err"
    rc=$?
    out="$(cat "$TMP/e1.out")"
    err="$(cat "$TMP/e1.err")"

    assert_eq "E1-$name-rc" "3" "$rc"
    assert_eq "E1-$name-stdout-empty" "" "$out"

    if printf '%s\n' "$err" | grep -q "$field"; then
        pass "E1-$name-stderr-names-field"
    else
        fail "E1-$name-stderr-names-field — stderr did not mention '$field': '$err'"
    fi

    if printf '%s\n%s\n' "$out" "$err" | grep -qE "$MARKER_ERE"; then
        fail "E1-$name-no-marker — marker leaked on the failure path: out='$out' err='$err'"
    else
        pass "E1-$name-no-marker"
    fi
done <<'TABLE'
background | Background
changes    | Changes
cause      | Cause
fix        | Fix
TABLE

# Restore the real implementation for every case below.
unset -f extract_field
eval "$REAL_EXTRACT_FIELD"

if [ "$(BODY=$'### Background\n\nreal' extract_field Background)" = "real" ]; then
    pass "E1-restore real extract_field is back in effect"
else
    fail "E1-restore — the stub was not removed; E3/S1/S2 below would be meaningless"
fi

# ---------------------------------------------------------------------------
# E3 (Classifier/guard counterpart, CPR-ORTH) — same four fields, real
# extract_field, body genuinely lacking them: rc=0 plus the marker. rc=3
# (parse failed) and rc=0+marker (genuinely unrecorded) are distinct verdicts.
# ---------------------------------------------------------------------------
NO_FIELDS_BODY='just prose with no labeled fields at all'

while IFS='|' read -r name field want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; field="${field//[[:space:]]/}"
    want="${want#"${want%%[![:space:]]*}"}"; want="${want%"${want##*[![:space:]]}"}"

    BODY="$NO_FIELDS_BODY" extract_field_or_marker "$field" \
        >"$TMP/e3.out" 2>"$TMP/e3.err"
    rc=$?
    assert_eq "E3-$name-rc" "0" "$rc"
    assert_eq "E3-$name-marker" "$want" "$(cat "$TMP/e3.out")"
    assert_eq "E3-$name-stderr-silent" "" "$(cat "$TMP/e3.err")"
done <<'TABLE'
background | Background | (no Background recorded)
changes    | Changes    | (no Changes recorded)
cause      | Cause      | (no Cause recorded)
fix        | Fix        | (no Fix recorded)
TABLE

# Unknown field name — the third verdict (rc=2, stderr, no stdout, no marker).
extract_field_or_marker Synopsis >"$TMP/e3u.out" 2>"$TMP/e3u.err"
rc=$?
assert_eq "E3-unknown-rc" "2" "$rc"
assert_eq "E3-unknown-stdout-empty" "" "$(cat "$TMP/e3u.out")"
if grep -qE "$MARKER_ERE" "$TMP/e3u.out" "$TMP/e3u.err"; then
    fail "E3-unknown-no-marker — marker leaked for an unknown field name"
else
    pass "E3-unknown-no-marker"
fi

# ---------------------------------------------------------------------------
# S1 (Edge — extremely long string, live path). 20000 characters through the
# sourced helper and the real subprocess. Length AND checksum are compared,
# never a prefix: a truncating regression keeps every prefix assertion green.
# ---------------------------------------------------------------------------
LONG="$(head -c 20000 /dev/zero | tr '\0' 'x')"
assert_eq "S1-fixture-length" "20000" "${#LONG}"
LONG_CK="$(printf '%s' "$LONG" | cksum)"

S1_BODY="### Background"$'\n\n'"$LONG"$'\n\n'"### Changes"$'\n\n'"short changes"
S1_GOT="$(BODY="$S1_BODY" extract_field_or_marker Background)"
assert_eq "S1-helper-length" "20000" "${#S1_GOT}"
assert_eq "S1-helper-checksum" "$LONG_CK" "$(printf '%s' "$S1_GOT" | cksum)"

# Same value through the real script's DRY_RUN branch (explicitly pinned).
S1_OUT="$(DRY_RUN=1 ISSUE_BODY="$S1_BODY" ISSUE_TITLE="long field" \
    ISSUE_CATEGORY=FEATURE run_with_timeout 30 bash "$SCRIPT" 42 2>&1)"
S1_ARG="$(printf '%s\n' "$S1_OUT" | sed -n 's/.*--background \([^ ]*\) --changes.*/\1/p')"
assert_eq "S1-subprocess-length" "20000" "${#S1_ARG}"
assert_eq "S1-subprocess-checksum" "$LONG_CK" "$(printf '%s' "$S1_ARG" | cksum)"

# ---------------------------------------------------------------------------
# S2 (Edge — minimal strings). Single character passes through verbatim;
# whitespace-only is empty after extraction and must become the marker.
# ---------------------------------------------------------------------------
while IFS='|' read -r name field body want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; field="${field//[[:space:]]/}"
    want="${want#"${want%%[![:space:]]*}"}"; want="${want%"${want##*[![:space:]]}"}"
    body="$(printf '%b' "${body#"${body%%[![:space:]]*}"}")"
    got="$(BODY="$body" extract_field_or_marker "$field")"
    rc=$?
    assert_eq "S2-$name" "$want" "$got"
    assert_eq "S2-$name-rc" "0" "$rc"
done <<'TABLE'
single-char-bg      | Background | ### Background\n\na\n\n### Changes\n\nb\n     | a
single-char-changes | Changes    | ### Background\n\na\n\n### Changes\n\nb\n     | b
single-char-cause   | Cause      | ### Cause\n\nq\n\n### Fix\n\nr\n              | q
single-char-fix     | Fix        | ### Cause\n\nq\n\n### Fix\n\nr\n              | r
blank-only-bg       | Background | ### Background\n\n   \n\n### Changes\n\nb\n   | (no Background recorded)
blank-only-changes  | Changes    | ### Background\n\na\n\n### Changes\n\n \t \n  | (no Changes recorded)
blank-only-cause    | Cause      | ### Cause\n\n   \n\n### Fix\n\nr\n            | (no Cause recorded)
blank-only-fix      | Fix        | ### Cause\n\nq\n\n### Fix\n\n \t \n           | (no Fix recorded)
TABLE

# ---------------------------------------------------------------------------
# S3 (Security — input injection, CWE-78). Issue bodies are attacker-supplied.
# A field value full of shell metacharacters must travel through the awk parser
# and into the doc-append argument as inert data: verbatim, nothing executed.
# Both runs happen with cwd inside $TMP so a successful injection would leave
# its artefact where the assertion can see it, not in the repo.
# ---------------------------------------------------------------------------
SEC_PAYLOAD='$(touch PWNED-CMDSUB); `touch PWNED-BACKTICK`; rm -rf .; a && b || c | tee PWNED-PIPE'
SEC_BODY="### Background"$'\n\n'"$SEC_PAYLOAD"$'\n\n'"### Changes"$'\n\n'"safe"

SEC_GOT="$(cd "$TMP" && BODY="$SEC_BODY" extract_field_or_marker Background)"
assert_eq "S3-helper-verbatim" "$SEC_PAYLOAD" "$SEC_GOT"

SEC_OUT="$(cd "$TMP" && DRY_RUN=1 ISSUE_BODY="$SEC_BODY" ISSUE_TITLE="sec probe" \
    ISSUE_CATEGORY=FEATURE run_with_timeout 30 bash "$SCRIPT" 42 2>&1)"
case "$SEC_OUT" in
    *"--background $SEC_PAYLOAD --changes safe"*)
        pass "S3-subprocess-verbatim metacharacters reach --background as inert data" ;;
    *)
        fail "S3-subprocess-verbatim — payload was altered on the way to --background: $SEC_OUT" ;;
esac

if compgen -G "$TMP/PWNED*" >/dev/null 2>&1 || compgen -G "$AGENTS_DIR/PWNED*" >/dev/null 2>&1; then
    fail "S3-no-execution — the injected payload EXECUTED: $(ls -d "$TMP"/PWNED* "$AGENTS_DIR"/PWNED* 2>/dev/null)"
else
    pass "S3-no-execution no artefact from the injected payload exists"
fi

# ---------------------------------------------------------------------------
# E2 (Integration / call-path error case, TL2) — a forced extract_field failure
# must abort issue-to-history.sh: non-zero exit, no doc-append call, byte-
# identical history file. Forced WITHOUT touching source, via a failing `awk`
# on PATH (extract_field's only implementation is an awk pipeline). The probe
# proves that really breaks extract_field, so a green E2 cannot mean "the stub
# silently did nothing".
# ---------------------------------------------------------------------------
E2_BIN="$TMP/e2bin"
mkdir -p "$E2_BIN"
cat >"$E2_BIN/awk" <<'AWK_STUB'
#!/bin/bash
echo "STUB awk: forced failure" >&2
exit 7
AWK_STUB
# Records the call AND writes, like the real doc-append: a stub that only
# records would make the byte-identical assertion below true for free.
cat >"$E2_BIN/doc-append" <<'DA_STUB'
#!/bin/bash
printf 'invoked\n' >>"$DOC_APPEND_CALL_LOG"
printf '\n### STUB doc-append entry\n' >>"${1:-/dev/null}"
exit 0
DA_STUB
chmod +x "$E2_BIN/awk" "$E2_BIN/doc-append"

# Probe: with this PATH, does extract_field actually fail?
PROBE_RC=0
PATH="$E2_BIN:$PATH" bash -c '
    . "$1"
    BODY="### Background

text"
    extract_field Background >/dev/null 2>&1
' _ "$LIB" || PROBE_RC=$?
if [ "$PROBE_RC" -ne 0 ]; then
    pass "E2-probe forced awk failure makes extract_field return non-zero (rc=$PROBE_RC)"
else
    fail "E2-probe — extract_field still returned 0 under the failing awk; E2 below cannot be trusted"
fi

E2_HOME="$TMP/e2home"
mkdir -p "$E2_HOME/docs/history"
printf '# History\n\n### #1: seed entry (2026-01-01)\n' >"$E2_HOME/docs/history.md"
E2_BEFORE="$(cksum <"$E2_HOME/docs/history.md")"
E2_LOG="$TMP/doc-append-calls.log"
: >"$E2_LOG"

E2_RC=0
PATH="$E2_BIN:$MOCK_DIR:$PATH" \
    DOC_APPEND_CALL_LOG="$E2_LOG" \
    AGENTS_CONFIG_DIR="$E2_HOME" \
    GH_MOCK_SCENARIO=issue_task_post_fix \
    DRY_RUN= \
    run_with_timeout 30 bash "$SCRIPT" 42 --commit abc1234 \
    >"$TMP/e2.out" 2>"$TMP/e2.err" || E2_RC=$?

if [ "$E2_RC" -ne 0 ]; then
    pass "E2-exit issue-to-history.sh exits non-zero when extract_field fails"
else
    fail "E2-exit issue-to-history.sh exits non-zero when extract_field fails — want rc!=0, got rc=0 (extract_field_or_marker's rc=3 is discarded by the assignment's command substitution)"
fi

if [ -s "$E2_LOG" ]; then
    fail "E2-no-append doc-append is not invoked when extract_field fails — want 0 invocations, got $(wc -l <"$E2_LOG")"
else
    pass "E2-no-append doc-append is not invoked when extract_field fails"
fi

assert_eq "E2-history-unchanged history.md is byte-identical after the failed run" \
    "$E2_BEFORE" "$(cksum <"$E2_HOME/docs/history.md")"

if grep -qE "$MARKER_ERE" "$E2_HOME/docs/history.md"; then
    fail "E2-no-marker — a marker was written to history.md on the parse-failure path"
else
    pass "E2-no-marker"
fi

# ---------------------------------------------------------------------------
# E4 (Integration / SELECTIVE error case, TL2) — E2 above makes EVERY awk call
# fail, so only the FIRST field's extraction is ever reached and a per-field
# regression in the second require_field call hides behind it. Here the stub
# keys off the `-v F=<Field>` argument extract_field carries: exactly one field
# fails, its sibling succeeds, and every other awk use in the script (the RS
# splitting of the gh JSON) is delegated to the real awk. Both category branches
# and both orderings are covered — CPR-ORTH.
# ---------------------------------------------------------------------------
E4_BIN="$TMP/e4bin"
mkdir -p "$E4_BIN"
REAL_AWK="$(command -v awk)"

cat >"$E4_BIN/awk" <<E4_AWK_STUB
#!/bin/bash
# Fails only for the extract_field invocation whose -v F=<Field> matches
# \$SELECTIVE_FAIL_FIELD; everything else runs the real awk.
_field=""
for _a in "\$@"; do
    case "\$_a" in F=*) _field="\${_a#F=}" ;; esac
done
if [ -n "\$_field" ] && [ "\$_field" = "\${SELECTIVE_FAIL_FIELD:-}" ]; then
    echo "STUB awk: selective forced failure for \$_field" >&2
    exit 7
fi
exec "$REAL_AWK" "\$@"
E4_AWK_STUB
cat >"$E4_BIN/doc-append" <<'E4_DA_STUB'
#!/bin/bash
printf 'invoked\n' >>"$DOC_APPEND_CALL_LOG"
printf '\n### STUB doc-append entry\n' >>"${1:-/dev/null}"
exit 0
E4_DA_STUB
chmod +x "$E4_BIN/awk" "$E4_BIN/doc-append"

# Probe: the stub must really be asymmetric. Without this, a green E4 could
# equally mean "the stub failed nothing" or "the stub failed everything".
probe_field() {  # probe_field <fail-field> <field-to-extract> ; echoes rc
    local rc=0
    PATH="$E4_BIN:$PATH" SELECTIVE_FAIL_FIELD="$1" run_with_timeout 30 bash -c '
        . "$1"
        BODY="### Background

bg text

### Changes

ch text"
        extract_field "$2" >/dev/null 2>&1
    ' _ "$LIB" "$2" || rc=$?
    printf '%s' "$rc"
}
assert_eq "E4-probe-fails the stub fails the targeted field" "7" "$(probe_field Changes Changes)"
assert_eq "E4-probe-succeeds the stub passes the sibling field through" "0" "$(probe_field Changes Background)"
assert_eq "E4-probe-orthogonal the asymmetry follows the targeted field" "7" "$(probe_field Background Background)"

# name | gh-mock scenario | field whose extraction fails | sibling field
while IFS='|' read -r name scenario failfield sibling; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; scenario="${scenario//[[:space:]]/}"
    failfield="${failfield//[[:space:]]/}"; sibling="${sibling//[[:space:]]/}"

    E4_HOME="$TMP/e4home-$name"
    mkdir -p "$E4_HOME/docs/history"
    printf '# History\n\n### #1: seed entry (2026-01-01)\n' >"$E4_HOME/docs/history.md"
    E4_BEFORE="$(cksum <"$E4_HOME/docs/history.md")"
    E4_LOG="$TMP/e4-doc-append-$name.log"
    : >"$E4_LOG"

    E4_RC=0
    PATH="$E4_BIN:$MOCK_DIR:$PATH" \
        SELECTIVE_FAIL_FIELD="$failfield" \
        DOC_APPEND_CALL_LOG="$E4_LOG" \
        AGENTS_CONFIG_DIR="$E4_HOME" \
        GH_MOCK_SCENARIO="$scenario" \
        DRY_RUN= \
        run_with_timeout 30 bash "$SCRIPT" 42 --commit abc1234 \
        >"$TMP/e4-$name.out" 2>"$TMP/e4-$name.err" || E4_RC=$?

    if [ "$E4_RC" -ne 0 ]; then
        pass "E4-$name-exit a failed $failfield extraction aborts the script (rc=$E4_RC)"
    else
        fail "E4-$name-exit — want rc!=0 when $failfield fails ($sibling still extractable), got rc=0"
    fi

    if [ -s "$E4_LOG" ]; then
        fail "E4-$name-no-append — doc-append ran $(wc -l <"$E4_LOG") time(s) despite the $failfield failure"
    else
        pass "E4-$name-no-append doc-append is never invoked"
    fi

    if grep -qE "$MARKER_ERE" "$TMP/e4-$name.out" "$TMP/e4-$name.err" "$E4_HOME/docs/history.md"; then
        fail "E4-$name-no-marker — a '(no <Field> recorded)' marker was emitted on the parse-failure path"
    else
        pass "E4-$name-no-marker"
    fi

    assert_eq "E4-$name-history-unchanged history.md is byte-identical" \
        "$E4_BEFORE" "$(cksum <"$E4_HOME/docs/history.md")"
done <<'TABLE'
task-first     | issue_task_post_fix     | Background | Changes
task-second    | issue_task_post_fix     | Changes    | Background
incident-first | issue_incident_post_fix | Cause      | Fix
incident-second| issue_incident_post_fix | Fix        | Cause
TABLE

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
