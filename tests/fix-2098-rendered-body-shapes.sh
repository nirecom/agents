#!/bin/bash
# Tests: bin/github-issues/lib/extract-field.sh, bin/github-issues/issue-to-history.sh
# Tags: history, github, issues, issue-forms, extract-field, scope:common, layer:TL2
set -u
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$AGENTS_DIR/bin/github-issues/lib/extract-field.sh"
SCRIPT="$AGENTS_DIR/bin/github-issues/issue-to-history.sh"
MOCK_DIR="$AGENTS_DIR/tests/fixtures/gh-mock"

# Documented marker recipe (SSOT: extract-field.sh, extract_field_or_marker()).
MARKER_ERE='\(no (Background|Changes|Cause|Fix) recorded\)'

# TL3 gap (what this test does NOT catch):
# - GitHub's own Issue Forms renderer producing this body. The post-fix shape
#   asserted here is modelled, not observed: only a real submission proves the
#   heading level, blank-line placement and trailing whitespace match.
# - `gh` is tests/fixtures/gh-mock/gh and `doc-append` is that dir's stub, so no
#   real gh JSON contract and no bin/doc-append.py formatting runs.
# Closest-to-action mitigation: bin/check-verification-gate.sh has no category
# covering issue-form rendering (its categories are pwsh-required,
# hook-registration, skill-orchestration, installer, merge-base-suspect);
# closed instead by the plan's manual render check before merge.

if [ ! -f "$LIB" ]; then
    echo "FAIL: precondition missing — $LIB"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi
source "$LIB"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

# Trim only leading/trailing blanks: table `want` values contain internal
# spaces (extract_field joins continuation lines with a single space), so the
# whitespace-stripping variant of the shared table pattern cannot be used.
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# ---------------------------------------------------------------------------
# TL1 — post-fix rendered body: `### <Label>` heading + bare user text.
# No inline `Cause: ` label on the value line; that is what removing the
# template's `value:` prefill produces, and it is what every shipped issue
# will look like. Each row also asserts the marker never appears.
# ---------------------------------------------------------------------------
while IFS='|' read -r name field body want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="$(trim "$name")"; field="$(trim "$field")"; want="$(trim "$want")"
    body="$(printf '%b' "$(trim "$body")")"
    got="$(BODY="$body" extract_field "$field")"
    assert_eq "T-$name" "$want" "$got"
    if printf '%s\n' "$got" | grep -qE "$MARKER_ERE"; then
        fail "T-$name-nomarker — marker leaked into an extracted value: $got"
    else
        pass "T-$name-nomarker"
    fi
done <<'TABLE'
cause-plain      | Cause      | ### Cause\n\nthe login token expired\n\n### Fix\n\nrefresh the token on 401\n | the login token expired
fix-plain        | Fix        | ### Cause\n\nthe login token expired\n\n### Fix\n\nrefresh the token on 401\n | refresh the token on 401
background-plain | Background | ### Background\n\nthe docs drifted\n\n### Changes\n\nrewrote the setup guide\n   | the docs drifted
changes-plain    | Changes    | ### Background\n\nthe docs drifted\n\n### Changes\n\nrewrote the setup guide\n   | rewrote the setup guide
cause-multiline  | Cause      | ### Cause\n\nfirst line\nsecond line\n\n### Fix\n\nfixed it\n                     | first line second line
fix-multiline    | Fix        | ### Cause\n\nboom\n\n### Fix\n\nfirst line\nsecond line\n                        | first line second line
bg-multiline     | Background | ### Background\n\nfirst line\nsecond line\n\n### Changes\n\ndone\n                | first line second line
changes-multi    | Changes    | ### Background\n\nwhy\n\n### Changes\n\nfirst line\nsecond line\n                | first line second line
cause-paragraphs | Cause      | ### Cause\n\npara one\n\npara two\n\n### Fix\n\nfixed it\n                       | para one para two
cause-bullets    | Cause      | ### Cause\n\n- bullet one\n- bullet two\n\n### Fix\n\nfixed it\n                 | - bullet one - bullet two
changes-bullets  | Changes    | ### Background\n\nwhy\n\n### Changes\n\n- bullet one\n- bullet two\n             | - bullet one - bullet two
TABLE

# ---------------------------------------------------------------------------
# TL1 — no bleed into the neighbouring section. Without an inline label the
# only section boundary is the next heading; a regression that stops
# recognising headings would swallow the adjacent field's text.
# ---------------------------------------------------------------------------
while IFS='|' read -r name field body forbidden; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="$(trim "$name")"; field="$(trim "$field")"; forbidden="$(trim "$forbidden")"
    body="$(printf '%b' "$(trim "$body")")"
    got="$(BODY="$body" extract_field "$field")"
    case "$got" in
        *"$forbidden"*) fail "R-$name — '$forbidden' bled in: got='$got'" ;;
        *)              pass "R-$name" ;;
    esac
done <<'TABLE'
cause-vs-fix | Cause      | ### Cause\n\nthe login token expired\n\n### Fix\n\nrefresh the token on 401\n | refresh
fix-vs-cause | Fix        | ### Cause\n\nthe login token expired\n\n### Fix\n\nrefresh the token on 401\n | login
bg-vs-changes| Background | ### Background\n\nthe docs drifted\n\n### Changes\n\nrewrote the setup guide\n | rewrote
changes-vs-bg| Changes    | ### Background\n\nthe docs drifted\n\n### Changes\n\nrewrote the setup guide\n | drifted
TABLE

# ---------------------------------------------------------------------------
# TL1 — one section left empty in the post-fix shape. `required:` makes this
# unreachable through the hosted form, so this is a guard: the empty side must
# become the marker while the populated side keeps its real value (no
# field mix-up, no marker bleeding onto a populated field).
# ---------------------------------------------------------------------------
INCIDENT_HALF=$'### Cause\n\nreal cause here\n\n### Fix\n\n'
TASK_HALF=$'### Background\n\n\n\n### Changes\n\nreal changes here\n'

assert_eq "G1 populated Cause survives an empty Fix section" \
    "real cause here" "$(BODY="$INCIDENT_HALF" extract_field Cause)"
assert_eq "G2 empty Fix section extracts to empty" \
    "" "$(BODY="$INCIDENT_HALF" extract_field Fix)"
assert_eq "G3 populated Changes survives an empty Background section" \
    "real changes here" "$(BODY="$TASK_HALF" extract_field Changes)"
assert_eq "G4 empty Background section extracts to empty" \
    "" "$(BODY="$TASK_HALF" extract_field Background)"

if declare -f extract_field_or_marker >/dev/null 2>&1; then
    assert_eq "G5 empty Fix section becomes the Fix marker" \
        "(no Fix recorded)" "$(BODY="$INCIDENT_HALF" extract_field_or_marker Fix)"
    assert_eq "G6 populated Cause is untouched by the marker path" \
        "real cause here" "$(BODY="$INCIDENT_HALF" extract_field_or_marker Cause)"
    assert_eq "G7 empty Background section becomes the Background marker" \
        "(no Background recorded)" "$(BODY="$TASK_HALF" extract_field_or_marker Background)"
    assert_eq "G8 populated Changes is untouched by the marker path" \
        "real changes here" "$(BODY="$TASK_HALF" extract_field_or_marker Changes)"
else
    fail "G5-G8 extract_field_or_marker is not defined in $LIB (fail-before-fix: #2098 rename pending)"
fi

# ---------------------------------------------------------------------------
# TL2 — the post-fix body travelling through the real issue-to-history.sh
# subprocess into a real history.md. Two runs only (INCIDENT + task), because
# each is a subprocess; the shape matrix above stays at TL1.
# ---------------------------------------------------------------------------
run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then timeout "$1" "${@:2}"
    else perl -e 'alarm shift; exec @ARGV' "$@"; fi
}

setup_ith_tmp() {
    ITH_TMP=$(mktemp -d)
    mkdir -p "$ITH_TMP/docs/history"
    touch "$ITH_TMP/docs/history.md"
    export AGENTS_CONFIG_DIR="$ITH_TMP"
    export PATH="$MOCK_DIR:$PATH"
}

teardown_ith_tmp() {
    [ -n "${ITH_TMP:-}" ] && rm -rf "$ITH_TMP"
    unset AGENTS_CONFIG_DIR ITH_TMP
}

# scenario | label | expected line 1 | expected line 2
run_post_fix_case() {
    local scenario="$1" label="$2" want1="$3" want2="$4"
    setup_ith_tmp
    local rc content markers out
    # DRY_RUN is pinned EMPTY, never inherited: an ambient DRY_RUN would make
    # the script print and exit 0 before doc-append, and every assertion below
    # would then be checking an untouched file (#1133 class of false green).
    out=$(DRY_RUN= GH_MOCK_SCENARIO="$scenario" run_with_timeout 30 bash "$SCRIPT" 42 \
        --commit abc1234 2>&1)
    rc=$?
    content=$(cat "$ITH_TMP/docs/history.md" 2>/dev/null)
    # B3 — pin that the empty-DRY_RUN branch really took the gh/doc-append path.
    case "$out" in
        *"DRY_RUN:"*) fail "$label — empty DRY_RUN still took the dry-run print path: $out" ;;
        *"Appended issue #42"*) pass "$label takes the gh/doc-append path when DRY_RUN is empty" ;;
        *) fail "$label — neither the dry-run print nor the append confirmation appeared: $out" ;;
    esac
    markers=$(printf '%s\n' "$content" | grep -cE "$MARKER_ERE")
    if [ "$rc" -eq 0 ] \
        && printf '%s\n' "$content" | grep -qx "$want1" \
        && printf '%s\n' "$content" | grep -qx "$want2"; then
        pass "$label reaches history.md verbatim"
    else
        fail "$label — rc=$rc history.md='$content'"
    fi
    if [ "$markers" -eq 0 ]; then
        pass "$label emits no marker"
    else
        fail "$label — expected 0 marker lines, got $markers"
    fi
    teardown_ith_tmp
}

if [ -f "$SCRIPT" ]; then
    run_post_fix_case issue_incident_post_fix \
        "E1 post-fix INCIDENT body (heading + bare text)" \
        "Cause: the login token expired" "Fix: refresh the token on 401"
    run_post_fix_case issue_task_post_fix \
        "E2 post-fix task body (heading + bare text)" \
        "Background: the docs drifted" "Changes: rewrote the setup guide"
    # I1 (Idempotency, TL2) — a second run over the same history must be a
    # no-op: the `### #N` guard fires and nothing is appended twice.
    setup_ith_tmp
    DRY_RUN= GH_MOCK_SCENARIO=issue_task_post_fix run_with_timeout 30 \
        bash "$SCRIPT" 42 --commit abc1234 >/dev/null 2>&1
    IDEM_CK1="$(cksum <"$ITH_TMP/docs/history.md")"
    IDEM_OUT="$(DRY_RUN= GH_MOCK_SCENARIO=issue_task_post_fix run_with_timeout 30 \
        bash "$SCRIPT" 42 --commit abc1234 2>&1)"
    assert_eq "I1 re-run leaves history.md byte-identical" \
        "$IDEM_CK1" "$(cksum <"$ITH_TMP/docs/history.md")"
    case "$IDEM_OUT" in
        *"Already in history"*) pass "I1 re-run reports the idempotency skip" ;;
        *) fail "I1 re-run reports the idempotency skip — got: $IDEM_OUT" ;;
    esac
    teardown_ith_tmp
else
    fail "precondition missing — $SCRIPT"
fi

# ---------------------------------------------------------------------------
# B1 (Normal/E2E shape, TL1) — the body GitHub renders when task.yml's
# `Sub-tasks (optional)` textarea IS filled in. That third section is not one
# of the four field names, so nothing but a heading-boundary rule stops it from
# being swallowed into Changes and shipped into history.md as prose.
# ---------------------------------------------------------------------------
SUBTASKS_BODY=$'### Background\n\nthe docs drifted\n\n### Changes\n\nrewrote the setup guide\n\n### Sub-tasks (optional)\n\n- sub-issue #1\n- sub-issue #2\n'

B1_CHANGES="$(BODY="$SUBTASKS_BODY" extract_field_or_marker Changes)"
assert_eq "B1 Changes is the Changes prose only" "rewrote the setup guide" "$B1_CHANGES"

while IFS='|' read -r name forbidden; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="$(trim "$name")"; forbidden="$(trim "$forbidden")"
    case "$B1_CHANGES" in
        *"$forbidden"*) fail "B1-$name — '$forbidden' bled into Changes: '$B1_CHANGES'" ;;
        *)              pass "B1-$name" ;;
    esac
done <<'TABLE'
heading  | Sub-tasks
bullet-1 | - sub-issue #1
bullet-2 | - sub-issue #2
TABLE

assert_eq "B1 Background is unaffected by the third section" \
    "the docs drifted" "$(BODY="$SUBTASKS_BODY" extract_field_or_marker Background)"

# ---------------------------------------------------------------------------
# B2 / B4 (Config-dependent branch, TL2) — the same bodies through the real
# subprocess with DRY_RUN pinned to 1 on EVERY call, covering both category
# branches: TASK/FEATURE (--background/--changes) and INCIDENT (--cause/--fix).
# ---------------------------------------------------------------------------
dry_run_args() {
    DRY_RUN=1 ISSUE_BODY="$1" ISSUE_TITLE="${2:-subject}" ISSUE_CATEGORY="${3:-FEATURE}" \
        run_with_timeout 30 bash "$SCRIPT" 42 2>&1
}

arg_value() {  # arg_value <line> <flag> <next-flag>
    printf '%s\n' "$1" | sed -n "s/.*$2 \(.*\) $3 .*/\1/p"
}

if [ -f "$SCRIPT" ]; then
    B2_OUT="$(dry_run_args "$SUBTASKS_BODY" "Setup guide drift" FEATURE)"
    case "$B2_OUT" in
        "DRY_RUN: "*) pass "B2 DRY_RUN=1 takes the dry-run print path" ;;
        *) fail "B2 — DRY_RUN=1 did not print the dry-run line: $B2_OUT" ;;
    esac
    B2_CHANGES="$(arg_value "$B2_OUT" --changes --commits)"
    assert_eq "B2 --changes carries the Changes prose only" \
        "rewrote the setup guide" "$B2_CHANGES"
    while IFS='|' read -r name forbidden; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="$(trim "$name")"; forbidden="$(trim "$forbidden")"
        case "$B2_CHANGES" in
            *"$forbidden"*) fail "B2-$name — '$forbidden' reached --changes: '$B2_CHANGES'" ;;
            *)              pass "B2-$name" ;;
        esac
    done <<'TABLE'
heading  | Sub-tasks
bullet-1 | - sub-issue #1
bullet-2 | - sub-issue #2
TABLE

    # B4 — the CPR-ORTH counterpart branch, same explicit DRY_RUN=1 pin.
    B4_TASK="$(dry_run_args $'### Background\n\nthe docs drifted\n\n### Changes\n\nrewrote the setup guide\n' "Setup guide drift" FEATURE)"
    assert_eq "B4 FEATURE --background" "the docs drifted" \
        "$(arg_value "$B4_TASK" --background --changes)"
    assert_eq "B4 FEATURE --changes" "rewrote the setup guide" \
        "$(arg_value "$B4_TASK" --changes --commits)"

    B4_INC="$(dry_run_args $'### Cause\n\nthe login token expired\n\n### Fix\n\nrefresh the token on 401\n' "Login outage" INCIDENT)"
    case "$B4_INC" in
        *"--category INCIDENT"*) pass "B4 INCIDENT category branch is selected" ;;
        *) fail "B4 INCIDENT category branch is selected — got: $B4_INC" ;;
    esac
    assert_eq "B4 INCIDENT --cause" "the login token expired" \
        "$(arg_value "$B4_INC" --cause --fix)"
    assert_eq "B4 INCIDENT --fix" "refresh the token on 401" \
        "$(arg_value "$B4_INC" --fix --commits)"
fi

# ---------------------------------------------------------------------------
# R2 (Edge — duplicate field section, TL1). Both behaviours below are read off
# extract-field.sh's awk, not guessed:
#  - Bare heading repeat: NEITHER occurrence wins. Re-entering the target
#    heading only sets cap=1; the inline-label branch that resets `out` needs a
#    colon, so the two bodies CONCATENATE in document order.
#  - Inline label repeat: the LAST occurrence wins — `out = rest` DISCARDS
#    everything captured so far, the first occurrence's tail included.
# ---------------------------------------------------------------------------
while IFS='|' read -r name field body want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="$(trim "$name")"; field="$(trim "$field")"; want="$(trim "$want")"
    body="$(printf '%b' "$(trim "$body")")"
    assert_eq "R2-$name" "$want" "$(BODY="$body" extract_field "$field")"
done <<'TABLE'
heading-repeat        | Changes | ### Background\n\nwhy\n\n### Changes\n\nfirst prose\n\n### Changes\n\nsecond prose\n | first prose second prose
heading-repeat-multi  | Changes | ### Changes\n\nfirst a\nfirst b\n\n### Changes\n\nsecond a\n                        | first a first b second a
heading-repeat-sibling| Background | ### Background\n\nbg\n\n### Changes\n\none\n\n### Changes\n\ntwo\n                | bg
inline-repeat         | Changes | Background: why\n\nChanges: first prose\n\nChanges: second prose\n                   | second prose
inline-repeat-multi   | Changes | Changes: first prose\nfirst tail\n\nChanges: second prose\n                          | second prose
TABLE

# ---------------------------------------------------------------------------
# C1 (Edge — marker collision, TL1/TL2). `(no Changes recorded)` is a string a
# user can type; typed, it is USER CONTENT and flows through as an rc=0 success,
# verbatim. Absent, extract_field_or_marker SYNTHESISES the same string.
# KNOWN LIMITATION pinned deliberately: at the output boundary the two are
# byte-identical, so nothing downstream can tell "the user wrote this" from "we
# had nothing to record". That ambiguity is the price of never fabricating a
# value; distinguishing them would need a channel outside the field text, which
# #2098 did not add.
# ---------------------------------------------------------------------------
COLLIDE_BODY=$'### Background\n\nthe docs drifted\n\n### Changes\n\n(no Changes recorded)\n'
EMPTY_BODY=$'### Background\n\nthe docs drifted\n\n### Changes\n\n'

C1_TYPED="$(BODY="$COLLIDE_BODY" extract_field_or_marker Changes)"; C1_TYPED_RC=$?
C1_SYNTH="$(BODY="$EMPTY_BODY" extract_field_or_marker Changes)"; C1_SYNTH_RC=$?

assert_eq "C1-typed-rc user-typed marker text is a success, not an error" "0" "$C1_TYPED_RC"
assert_eq "C1-typed-value user-typed marker text passes through verbatim" \
    "(no Changes recorded)" "$C1_TYPED"
assert_eq "C1-typed-sibling the sibling field is unaffected by the collision" \
    "the docs drifted" "$(BODY="$COLLIDE_BODY" extract_field_or_marker Background)"
assert_eq "C1-synth-rc a genuinely empty field is also rc=0" "0" "$C1_SYNTH_RC"
assert_eq "C1-synth-value a genuinely empty field synthesises the marker" \
    "(no Changes recorded)" "$C1_SYNTH"
assert_eq "C1-indistinguishable typed and synthesised markers are byte-identical (known limitation)" \
    "$C1_TYPED" "$C1_SYNTH"

if [ -f "$SCRIPT" ]; then
    C1_TYPED_OUT="$(dry_run_args "$COLLIDE_BODY" "Marker collision" FEATURE)"
    C1_SYNTH_OUT="$(dry_run_args "$EMPTY_BODY" "Marker collision" FEATURE)"
    C1_TYPED_ARG="$(arg_value "$C1_TYPED_OUT" --changes --commits)"
    C1_SYNTH_ARG="$(arg_value "$C1_SYNTH_OUT" --changes --commits)"
    assert_eq "C1-subprocess-typed user-typed marker text reaches --changes unchanged" \
        "(no Changes recorded)" "$C1_TYPED_ARG"
    assert_eq "C1-subprocess-background --background is untouched by the collision" \
        "the docs drifted" "$(arg_value "$C1_TYPED_OUT" --background --changes)"
    assert_eq "C1-subprocess-indistinguishable --changes is identical for typed and synthesised (known limitation)" \
        "$C1_TYPED_ARG" "$C1_SYNTH_ARG"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
