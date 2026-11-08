#!/bin/bash
# tests/tests/feature-689-run-all-all-flag/guard-cases.sh — sourced by the dispatcher.
# Tests: tests/run-all.sh
# Tags: bin, tests, scope:issue-specific
# C5a-C7: the timeout helper, the recursion and contract-pollution guards, and the ambient
# sanitization. "$SELF" is the dispatcher and every part concatenated (see the dispatcher).

# C5(a): the timeout helper delegates to the canonical wrapper — no private
# perl tier, no unbounded bare-exec fallback.
test_C5a_timeout_helper_delegates() {
    local alarm_word="alarm"
    local shift_word="shift"
    local ok=1
    ! grep -qE "$alarm_word[[:space:]]+$shift_word" "$SELF" || ok=0
    ! grep -qE '^[[:space:]]*"\$@"[[:space:]]*$' "$SELF" || ok=0
    grep -qF 'bin/run-with-timeout.sh' "$SELF" || ok=0
    if [ "$ok" = "1" ]; then
        pass "C5a_timeout_helper_delegates: no private perl tier, no unbounded bare-exec tier, canonical wrapper referenced"
    else
        fail "C5a_timeout_helper_delegates: this file still carries a private timeout ladder or does not reference bin/run-with-timeout.sh"
    fi
}

# C5(b): the helper actually bounds a long-running command.
test_C5b_timeout_helper_bounds() {
    local start end elapsed rc
    start=$(date +%s)
    run_with_timeout 2 sleep 20 >/dev/null 2>&1
    rc=$?
    end=$(date +%s)
    elapsed=$((end - start))
    if [ "$rc" != "0" ] && [ "$elapsed" -lt 10 ]; then
        pass "C5b_timeout_helper_bounds: run_with_timeout 2 sleep 20 aborted after ${elapsed}s (rc=$rc)"
    else
        fail "C5b_timeout_helper_bounds: rc=$rc elapsed=${elapsed}s (want non-zero rc within 10s)"
    fi
}

# C6(a): static recursion guard — every launch of the repository runner pins a
# non-empty TESTS_DIR, a non-empty `RUN_ALL_TARGET_ROOT` (#2473), or names a positional file.
test_C6a_no_unpinned_launch() {
    local launch_lines total bad=0 line
    launch_lines="$(grep -nE 'bash "\$RUN_ALL"' "$SELF" || true)"
    total="$(printf '%s\n' "$launch_lines" | grep -c '.' || true)"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        printf '%s\n' "$line" | grep -qE 'TESTS_DIR="[^"]+"' && continue
        printf '%s\n' "$line" | grep -qE 'RUN_ALL_TARGET_ROOT="[^"]+"' && continue
        printf '%s\n' "$line" | grep -qE 'bash "\$RUN_ALL" "' && continue
        bad=$((bad + 1))
        echo "    ! unpinned launch: $line"
    done <<< "$launch_lines"
    if [ "$total" -ge 4 ] && [ "$bad" = "0" ]; then
        pass "C6a_no_unpinned_launch: all $total repository-runner launches pin TESTS_DIR or name a file"
    else
        fail "C6a_no_unpinned_launch: total=$total unpinned=$bad (want at least 4 launches and 0 unpinned)"
    fi
}

# C6(b): static contract-pollution guard — captured runner output only ever
# reaches stdout through diag(), which masks and truncates it.
test_C6b_captured_output_masked() {
    local refs total bad=0 line diag_calls body_ok=0
    refs="$(grep -nE '"\$[a-z_]*out"' "$SELF" || true)"
    total="$(printf '%s\n' "$refs" | grep -c '.' || true)"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in
            *'="$('*) continue ;;
            *'count_lines '*) continue ;;
            *'has_line '*) continue ;;
            *'has_fixed '*) continue ;;
            *'diag "$'*) continue ;;
        esac
        bad=$((bad + 1))
        echo "    ! unmasked output reference: $line"
    done <<< "$refs"
    diag_calls="$(grep -cE '^[[:space:]]+diag "\$' "$SELF" || true)"
    if grep -E '^diag\(\)' "$SELF" | grep -q 'mask_contract' \
       && grep -E '^diag\(\)' "$SELF" | grep -q 'tail -20'; then
        body_ok=1
    fi
    if [ "$total" -ge 5 ] && [ "$bad" = "0" ] && [ "$diag_calls" -ge 1 ] && [ "$body_ok" = "1" ]; then
        pass "C6b_captured_output_masked: $total captured-output references, none unmasked; diag() truncates and masks"
    else
        fail "C6b_captured_output_masked: refs=$total unmasked=$bad diag_calls=$diag_calls diag_body_ok=$body_ok"
    fi
}

# C6(c): behavioural contract-pollution guard — mask_contract removes every
# line-initial contract marker from real captured runner output.
test_C6c_mask_contract_strips_marker() {
    local raw_out masked_out
    raw_out="$(run_with_timeout 60 bash "$FIXTURE_RUNNER" --all 2>&1)"
    if ! has_line '^[[:space:]]*RUN_CONTRACT:' "$raw_out"; then
        fail "C6c_mask_contract_strips_marker: fixture run emitted no contract line, so the mask assertion would be vacuous"
        diag "$raw_out"
        return
    fi
    masked_out="$(printf '%s\n' "$raw_out" | mask_contract)"
    if has_line '^[[:space:]]*RUN_CONTRACT:' "$masked_out"; then
        fail "C6c_mask_contract_strips_marker: masked output still carries a line-initial contract marker"
        diag "$raw_out"
    else
        pass "C6c_mask_contract_strips_marker: every line-initial contract marker is neutralised"
    fi
}

# C7: the ambient sanitization is asserted, not assumed — a hostile value for
# any of the five runner knobs must reach neither the child env nor the verdict.
test_C7_ambient_sanitized() {
    local probe="$TMPROOT/ambient-probe.sh" got want v ok=1 hostile_out
    {
        printf '#!/bin/bash\n'
        printf 'for v in %s; do printf "%%s=%%s " "$v" "${!v-<unset>}"; done\n' "$AMBIENT_VARS"
    } > "$probe"
    want=""; for v in $AMBIENT_VARS; do want="$want$v=<unset> "; done
    got="$(TEST_MAX_JOBS_PER_RUN=hostile RUN_ALL_DEADLINE=1 RUN_ALL_PROGRESS=hostile \
        RUN_ALL_REAP=hostile FEATURE_644_PHASE=9 senv bash "$probe" 2>/dev/null)"
    [ "$got" = "$want" ] || ok=0
    # Behavioural half: the fixture sweep's verdict must not move under a
    # hostile ambient environment. Pinned to the literal EXECUTED=4 / rc=1, so a
    # launch that silently ran nothing cannot satisfy it either.
    export TEST_MAX_JOBS_PER_RUN=hostile RUN_ALL_DEADLINE=1 RUN_ALL_PROGRESS=hostile
    export RUN_ALL_REAP=hostile FEATURE_644_PHASE=9
    hostile_out="$(run_with_timeout 60 bash "$FIXTURE_RUNNER" --all 2>&1)"
    local hostile_rc=$?
    unset TEST_MAX_JOBS_PER_RUN RUN_ALL_DEADLINE RUN_ALL_PROGRESS RUN_ALL_REAP FEATURE_644_PHASE
    has_line 'EXECUTED=4 UNRUNNABLE=0 TIMEOUT=0$' "$hostile_out" || ok=0
    has_line 'MARKER_T1' "$hostile_out" || ok=0
    [ "$hostile_rc" = "1" ] || ok=0
    if [ "$ok" = "1" ]; then
        pass "C7_ambient_sanitized: hostile RUN_ALL_*/FEATURE_644_PHASE values reach neither the child env nor the verdict"
    else
        fail "C7_ambient_sanitized: child env='$got' (want '$want'), hostile-run rc=$hostile_rc (want EXECUTED=4 + MARKER_T1 + rc=1)"
        diag "$hostile_out"
    fi
}
