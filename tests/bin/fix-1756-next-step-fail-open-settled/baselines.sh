#!/usr/bin/env bash
# filename: tests/fix-1756-next-step-fail-open-settled/baselines.sh
# Tests: bin/workflow/next-step, bin/workflow/lib/next-step/
# Tags: workflow, next-step, exit-code, idempotency, characterization, TL2, scope:common
#
# Case file — sourced by tests/fix-1756-next-step-fail-open-settled.sh, which
# owns every helper and fixture fragment used here. Do not run standalone.
#
# X1-X3 (exit codes / idempotency / argument-parsing error paths), L1-L4
# (`--list` characterization) and CHAR-1 (wf-meta characterization). All of these
# pass against the unmodified source and must keep passing after the fix.

# ---------------------------------------------------------------------------
# X0: the row-count and marker-column baselines below are derived from
# VALID_STEPS_COUNT (see the dispatcher). Prove the probe actually resolved,
# otherwise an empty value would compare equal to a crashed `--list` and
# false-green X1 / L1 / L2 / L4 all at once.
# ---------------------------------------------------------------------------
case "$VALID_STEPS_COUNT" in
    ''|*[!0-9]*) fail "X0: VALID_STEPS_COUNT probe -- expected a number, got [$VALID_STEPS_COUNT]";;
    *) if [ "$VALID_STEPS_COUNT" -ge 15 ]; then pass "X0: VALID_STEPS_COUNT probe resolved ($VALID_STEPS_COUNT)"
       else fail "X0: VALID_STEPS_COUNT implausibly small [$VALID_STEPS_COUNT]"; fi;;
esac

# marker_run <marker> <count> -> "|<marker>" repeated <count> times.
# Only the LEADING marker positions are pinned by each fixture; the tail is
# "every remaining step", so it is generated rather than spelled out.
marker_run() {
    local m="$1" n="$2" out="" i
    for ((i = 0; i < n; i++)); do out="$out|$m"; done
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# X1: exit-code baseline. Every other case reads stdout through a helper that
# discards the exit status, so without this a crashing binary that still printed
# a partial ACTION= line would look green. Both the verdict path and the --list
# path must exit 0.
# ---------------------------------------------------------------------------
X1_SID="$(new_sid x1)"
write_state "$X1_SID" "{$HEAD_COMPLETE,$RV_OUTLINE,\"detail\":{\"status\":\"complete\"},$TAIL_COMPLETE}"
run_next_step_rc --session "$X1_SID"
check_eq "X1: verdict path exits 0" "0" "$RC_CODE"
check_contains "X1: verdict path still emits an ACTION line" "ACTION=" "$RC_OUT"
run_next_step_rc --list --session "$X1_SID"
check_eq "X1: --list path exits 0" "0" "$RC_CODE"
check_eq "X1: --list emits one row per VALID_STEPS entry" "$VALID_STEPS_COUNT" "$(printf '%s\n' "$RC_OUT" | sed '/^$/d' | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
# X2 (idempotency): computing a verdict is a READ. Running it twice over the
# same state.json must produce identical stdout and must not touch the file —
# byte-identical before, between, and after both runs.
# ---------------------------------------------------------------------------
X2_SID="$(new_sid x2)"
write_state "$X2_SID" "{$HEAD_COMPLETE,$RV_OUTLINE,\"detail\":{\"status\":\"complete\"},$TAIL_WTS_SKIPPED}"
X2_HASH_BEFORE="$(state_hash "$X2_SID")"
X2_RUN1="$(run_next_step --session "$X2_SID")"
X2_HASH_MID="$(state_hash "$X2_SID")"
X2_RUN2="$(run_next_step --session "$X2_SID")"
X2_HASH_AFTER="$(state_hash "$X2_SID")"
check_eq "X2: second verdict run is byte-identical to the first" "$X2_RUN1" "$X2_RUN2"
check_eq "X2: state.json unchanged after the first run" "$X2_HASH_BEFORE" "$X2_HASH_MID"
check_eq "X2: state.json unchanged after the second run" "$X2_HASH_BEFORE" "$X2_HASH_AFTER"

# ---------------------------------------------------------------------------
# X3 (error paths, table-driven): every invocation below is one parseArgs
# rejection branch (bin/workflow/next-step:136-187) or the --session format
# check that follows it. Each must exit nonzero AND leave state.json untouched —
# a rejected argument list must never be half-applied.
# ---------------------------------------------------------------------------
X3_SID="$(new_sid x3)"
write_state "$X3_SID" "{$HEAD_COMPLETE,$RV_OUTLINE,\"detail\":{\"status\":\"complete\"},$TAIL_COMPLETE}"
X3_ROWS=(
    "--reset with no step argument|--session|$X3_SID|--reset"
    "--reset with an unknown step name|--session|$X3_SID|--reset|not_a_step"
    "--mark with no status argument|--session|$X3_SID|--mark|write_tests"
    "--mark with a non-complete status|--session|$X3_SID|--mark|write_tests|bogus"
    "--mark with an unknown step name|--session|$X3_SID|--mark|not_a_step|complete"
    "unknown option|--session|$X3_SID|--bogus"
    "--session with no value|--session"
    "--session with an illegal value|--session|../evil"
)
for row in "${X3_ROWS[@]}"; do
    IFS='|' read -r X3_DESC X3_A1 X3_A2 X3_A3 X3_A4 X3_A5 <<< "$row"
    X3_ARGS=()
    for a in "$X3_A1" "$X3_A2" "$X3_A3" "$X3_A4" "$X3_A5"; do
        [ -n "$a" ] && X3_ARGS+=("$a")
    done
    X3_HASH_BEFORE="$(state_hash "$X3_SID")"
    run_with_timeout 60 node "$NEXT_STEP" "${X3_ARGS[@]}" >/dev/null 2>&1
    X3_RC=$?
    X3_HASH_AFTER="$(state_hash "$X3_SID")"
    check_nonzero_rc "X3: $X3_DESC → nonzero exit" "$X3_RC"
    check_eq "X3: $X3_DESC → state.json not mutated" "$X3_HASH_BEFORE" "$X3_HASH_AFTER"
done

# ---------------------------------------------------------------------------
# L1-L4: `--list` characterization. Extracting the settled/current marker column
# pins exactly what the settled-status unification is allowed to affect, without
# coupling the test to step description text.
# ---------------------------------------------------------------------------
L1_SID="$(new_sid l1)"
write_state "$L1_SID" '{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"skipped","skip_reason":"not needed"},"outline":{"status":"complete"},"detail":{"status":"pending"}}'
check_eq "L1: mixed complete/skipped/current/pending marker column" \
    "[x]|[x]|[-]|[x]|[*]$(marker_run '[ ]' $((VALID_STEPS_COUNT - 5)))" \
    "$(list_markers --list --session "$L1_SID")"

L2_SID="$(new_sid l2)"
write_state "$L2_SID" "{$HEAD_COMPLETE,$RV_OUTLINE,\"detail\":{\"status\":\"complete\"},$TAIL_COMPLETE}"
check_eq "L2: terminal state renders skipped [-] beside complete [x]" \
    "[x]|[x]|[x]|[-]$(marker_run '[x]' $((VALID_STEPS_COUNT - 5)))|[ ]" \
    "$(list_markers --list --session "$L2_SID")"

L3_SID="$(new_sid l3)"
write_state "$L3_SID" '{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"pending"}}' '[]'
L3_MARKERS="$(list_markers --list --session "$L3_SID")"
check_eq "L3: empty closes_issues + clarify_intent current → second marker is [!]" \
    '[!]' "$(printf '%s' "$L3_MARKERS" | cut -d'|' -f2)"

# L4 compares two renderings for equality, so it must first prove each rendering
# is real: two empty outputs (or two crashes) would otherwise compare equal and
# false-green the fallback contract.
run_next_step_rc --list
L4_PLAIN="$RC_OUT"
check_eq "L4: --list (no session) exits 0" "0" "$RC_CODE"
check_eq "L4: --list (no session) renders one row per VALID_STEPS entry" \
    "$VALID_STEPS_COUNT" "$(printf '%s\n' "$L4_PLAIN" | sed '/^$/d' | wc -l | tr -d ' ')"
run_next_step_rc --list --session "missing-$(printf '%04x' $RANDOM)"
L4_MISSING="$RC_OUT"
check_eq "L4: --list with an unknown session exits 0" "0" "$RC_CODE"
check_eq "L4: --list with an unknown session renders one row per VALID_STEPS entry" \
    "$VALID_STEPS_COUNT" "$(printf '%s\n' "$L4_MISSING" | sed '/^$/d' | wc -l | tr -d ' ')"
check_eq "L4: --list with an unknown session falls back to the plain list" \
    "$L4_PLAIN" "$L4_MISSING"

# ---------------------------------------------------------------------------
# CHAR-1 (characterization only — NOT an endorsement):
# In a wf-meta session write_tests is recorded `pending` and only becomes
# `skipped` through the effective-state derivation, while the terminal branch
# reads the RAW record. So the fail-open branch still fires here and returns
# ACTION=invoke / NEXT_SKILL=write-tests even though a wf-meta session has no
# tests to write. This case records CURRENT BEHAVIOR, not correctness: it is to
# be corrected to ACTION=done by follow-up issue O-3, and this case MUST be
# updated at that time.
# ---------------------------------------------------------------------------
CHAR1_SID="$(new_sid char1)"
write_state "$CHAR1_SID" "{$HEAD_COMPLETE,\"outline\":{\"status\":\"skipped\",\"skip_reason\":\"recorded-verdict: so_c1+so_c2 met\"},\"pre_final_report_gate\":{\"status\":\"complete\"}}" '[1756]' 'wf-meta'
ACTION=""; NEXT_SKILL=""; REASON=""; NEXT_HINT=""
CHAR1_OUT="$(run_next_step --session "$CHAR1_SID")"
eval "$CHAR1_OUT" 2>/dev/null || true
check_eq "CHAR-1: wf-meta + outline skipped + raw write_tests pending → ACTION=invoke (current behavior, see O-3)" \
    "invoke" "${ACTION:-}"
check_eq "CHAR-1: NEXT_SKILL=write-tests (current behavior, see O-3)" \
    "write-tests" "${NEXT_SKILL:-}"
check_eq "CHAR-1: on-disk write_tests.status still literally pending (no rewrite)" \
    "pending" "$(raw_step_field "$CHAR1_SID" "write_tests" "status")"
