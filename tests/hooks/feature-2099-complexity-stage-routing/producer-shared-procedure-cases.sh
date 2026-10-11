#!/bin/bash
# tests/hooks/feature-2099-complexity-stage-routing/producer-shared-procedure-cases.sh
# Tests: skills/_shared/complexity-and-outline-skip.md, bin/workflow/normalize-judge-signals, bin/workflow/record-complexity-and-skip, bin/workflow/derive-complexity-level
# Tags: complexity, routing, producers, injection, integration, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh after producer-orchestration-cases.sh,
# whose d2099p_* helpers (COS-2/COS-3 extraction and runners) it reuses.
# Boundary under test: the judge's raw text reaches the CLI only through a FILE
# (COS-1) and the normalize step (COS-2); hostile bytes neither execute nor buy
# the cheap level.

# label | judge-produced csv. %NL% becomes a real newline, CANARY the canary path.
D2099P_INJECT='subshell|S1-multi-file,$(touch CANARY)
backtick|S1-multi-file,`touch CANARY`
semicolon|S1-multi-file; touch CANARY
amp|S1-multi-file && touch CANARY
pipe|S1-multi-file | touch CANARY
redirect|S1-multi-file > CANARY
newline|S1-multi-file%NL%touch CANARY
quote-break|S1-multi-file"; touch CANARY; :"'

# A payload that escapes runs its canary; one that is merely rejected does not.
# Either outcome is safe only if nothing shell-significant ran and no evaluation
# claims the cheap level (low) for a hostile judge line.
d2099ps_assert_safe() {
    local tag="$1" step="$2" label="$3" canary="$4" sid="$5" lvl
    if [ -e "$canary" ]; then
        fail "$tag-1 $step [$label] SHELL ESCAPE: the judge-produced csv executed the canary command"
    else
        pass "$tag-1 $step [$label] the hostile csv executed no injected command"
    fi
    lvl=$(d2099p_raw_event "$sid")
    case "$lvl" in
        __NO_EVENT__*) pass "$tag-2 $step [$label] ... and persisted nothing (a safe rejection)" ;;
        *level=high*) pass "$tag-2 $step [$label] ... or persisted a fail-high evaluation ($lvl)" ;;
        *) fail "$tag-2 $step [$label] a hostile csv produced [$lvl] — neither a rejection nor a fail-high" ;;
    esac
}

# PO-INJ-N: the real path. The payload is the judge's SIGNALS value in the raw
# file; COS-2 must reduce anything outside the id charset to S0-undecidable.
d2099ps_injection_via_normalize() {
    local name step target f label payload sid canary dir ctl
    dir="$TMPDIR_BASE/producer-injection-canary"
    mkdir -p "$dir"
    while IFS='|' read -r name step target; do
        [ -n "$name" ] || continue
        f=$(d2099p_skill_file "$name")
        while IFS='|' read -r label payload; do
            [ -n "$label" ] || continue
            canary="$dir/pwned-n-$name-$label"
            rm -f "$canary"
            payload=${payload//CANARY/$canary}
            payload=${payload//%NL%/$'\n'}
            sid=$(new_session "prodinjn-$name-$label")
            if [ "$(d2099p_run_raw "$f" "$sid" "SIGNALS: $payload")" = "__NO_COMMAND__" ]; then
                fail "PO-INJ-N0 $step [$label] unattributable: the COS chain is not runnable"
                continue
            fi
            d2099ps_assert_safe "PO-INJ-N" "$step" "$label" "$canary" "$sid"
            ctl=$(d2099n_control_path "$sid" complexity)
            assert_eq "PO-INJ-N3 $step [$label] normalize-judge-signals reduces the hostile line to S0-undecidable" \
                "S0-undecidable" "$(tr -d '[:space:]' < "$ctl" 2>/dev/null)"
        done <<INJ
$D2099P_INJECT
INJ
    done <<EOF
$D2099P_PRODUCERS
EOF
}

# PO-INJ-D: defense in depth. Bypass normalize, hand hostile bytes to COS-3 as the
# signals FILE; the CLI side alone must still execute nothing and not pick low.
d2099ps_injection_direct_file() {
    local name step target label payload sid canary dir sf
    dir="$TMPDIR_BASE/producer-injection-canary"
    mkdir -p "$dir"
    while IFS='|' read -r name step target; do
        [ -n "$name" ] || continue
        while IFS='|' read -r label payload; do
            [ -n "$label" ] || continue
            canary="$dir/pwned-d-$name-$label"
            rm -f "$canary"
            payload=${payload//CANARY/$canary}
            payload=${payload//%NL%/$'\n'}
            sid=$(new_session "prodinjd-$name-$label")
            sf="$(d2099p_plans_dir)/$sid-hostile-signals.txt"
            printf '%s\n' "$payload" > "$sf"
            local cos3_rc=0
            d2099p_cos3_run "$sid" "$sf" >/dev/null 2>&1 || cos3_rc=$?
            if [ "$cos3_rc" -eq 0 ] || d2099p_raw_event "$sid" | grep -q 'level=high'; then
                pass "PO-INJ-D3 $step [$label] COS-3 exit was safe (rc=$cos3_rc)"
            else
                fail "PO-INJ-D3 $step [$label] COS-3 exited $cos3_rc with no high-level event"
            fi
            d2099ps_assert_safe "PO-INJ-D" "$step" "$label" "$canary" "$sid"
        done <<INJ
$D2099P_INJECT
INJ
    done <<EOF
$D2099P_PRODUCERS
EOF
}

# PO-INJ-3: the prescribed WRITE step, pinned in the shared doc so a later edit
# cannot drop the Write-tool-not-Bash rule or the normalize substitution.
d2099ps_write_step_documented() {
    local cos cos1 para stripped
    local write_re='complexity-judge-raw\.txt` \(Write tool — untrusted text via file only\)'
    local redirect_re='>>?[[:space:]]*[^[:space:]]*complexity-judge-raw\.txt'
    cos=$(cat "$(d2099p_cos_file)")
    cos1=$(awk '/^## COS-1( |$)/ { inside = 1; next } inside && /^## / { exit } inside { print }' "$(d2099p_cos_file)")
    # The path and the Write-tool phrase wrap across lines of one paragraph: join it, then match both in one regex.
    para=$(printf '%s\n' "$cos1" | awk 'BEGIN { RS = "" } /complexity-judge-raw\.txt/ { gsub(/\n/, " "); print }')
    if [[ "$para" =~ $write_re ]]; then
        pass "PO-INJ-3 COS-1 raw path and (Write tool — untrusted text via file only) are named by the same step"
    else
        fail "PO-INJ-3 COS-1 raw path and (Write tool — untrusted text via file only) are not in the same step: [$para]"
    fi
    # Drop <PLACEHOLDER> tokens so their closing '>' cannot read as a redirect.
    stripped=$(printf '%s\n' "$cos1" | sed -E 's/<[A-Z_]+>//g')
    if [[ "$stripped" =~ $redirect_re ]] || [[ "$stripped" =~ (^|[^[:alnum:]_])tee([^[:alnum:]_]|$) ]]; then
        fail "PO-INJ-3d COS-1 offers a shell-write (redirect or tee) for the raw judge text"
    else
        pass "PO-INJ-3d COS-1 offers no shell-write (redirect or tee) for the raw judge text"
    fi
    assert_contains "PO-INJ-3c COS-1 section targets the raw file path" \
        "<PLANS_DIR>/<SESSION_ID>-complexity-judge-raw.txt" "$cos1"
    assert_contains "PO-INJ-3a COS-3 reads the value with no pipe and no capture (nothing is spliced into Bash)" \
        "no pipe, no capture" "$cos"
    assert_contains "PO-INJ-3b COS-2 routes the raw file through normalize-judge-signals (owner of the S0-undecidable substitution)" \
        "normalize-judge-signals" "$cos"
}

d2099ps_derived() {
    local csv="$1" st out acc=""
    for st in detail write_tests write_code; do
        out=$(run_with_timeout node "$BIN_DERIVE" --stage "$st" --signals "$csv" 2>/dev/null | head -1)
        acc="$acc${acc:+/}${out#level=}"
    done
    printf '%s' "$acc"
}

# PO-LIVE: judge-shaped inputs (zero, one, several signals) through the producer; the
# persisted event, the reader and the stateless derive CLI must tell one story.
d2099ps_live_shapes() {
    local name step target f label csv sid agg raw
    while IFS='|' read -r name step target; do
        [ -n "$name" ] || continue
        f=$(d2099p_skill_file "$name")
        while IFS='|' read -r label csv; do
            [ -n "$label" ] || continue
            csv=${csv//%EMPTY%/}
            sid=$(new_session "prodlive-$name-$label")
            d2099p_run_producer "$f" "$sid" "$csv" >/dev/null
            agg=high
            [ -z "$csv" ] && agg=low
            raw=$(d2099p_raw_event "$sid")
            assert_contains "PO-LIVE-1 $step [$label] one event at level $agg is persisted" "n=1 level=$agg " "$raw"
            assert_eq "PO-LIVE-2 $step [$label] the reader's stage levels equal the stateless derive CLI" \
                "$(d2099ps_derived "$csv")" "$(d2099p_stage_levels "$sid")"
        done <<LIVE
empty|%EMPTY%
single|S3-security
multi|S2-architecture,S6-long-plan
LIVE
    done <<EOF
$D2099P_PRODUCERS
EOF
}

case_begin "injection-via-normalize" "bin/workflow/normalize-judge-signals"
d2099ps_injection_via_normalize
case_end

case_begin "injection-direct-file" "bin/workflow/record-complexity-and-skip"
d2099ps_injection_direct_file
case_end

case_begin "write-step-documented" "skills/_shared/complexity-and-outline-skip.md"
d2099ps_write_step_documented
case_end

case_begin "live-shapes" "bin/workflow/derive-complexity-level"
d2099ps_live_shapes
case_end
