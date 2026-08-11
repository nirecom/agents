# shellcheck shell=bash
# tests/feature-1665-run-outcome/j-worker-verdict-ssot.sh
# Tests: hooks/workflow-run-tests/outcome.js, hooks/workflow-run-tests.js
# Tags: workflow, run-outcome, ssot, parser, grep-pin, static-analysis, TL1, scope:issue-specific
#
# TL1 — static source pin plus a behavioural equivalence check.
#
# WHY (CPR-WPH / CPR-SSOT): before this change the `status:` line was parsed for
# exactly one purpose — deciding whether the worker VETOES a completion. The change
# adds a second consumer: the same line becomes the run_outcome value. The obvious
# implementation is a second regex next to the first, and the two then drift on the
# next tweak (someone allows a trailing comment, or stops lowercasing, in one site
# only) — at which point the hook can veto a completion while recording "pass", or
# record "fail" while completing the step. Both halves would still look locally
# correct.
#
# R7 therefore makes parseWorkerVerdict() the SINGLE parse site: it returns
# { status, exitCode } and workerVerdictVetoes() becomes a thin wrapper over it.
# The pin below is on the source text because that is the only place the constraint
# is expressible — one regex literal, in the module that owns the parse.
#
# The pin is grep-based and therefore blunt. It is paired with a behavioural check
# (J5) so a passing grep with a broken parser cannot read as green.

run_j_worker_verdict_ssot_cases() {
    echo ""
    echo "=== j-worker-verdict-ssot (TL1: one parse site) ==="

    local hook_src="$AGENTS_DIR/hooks/workflow-run-tests.js"
    local outcome_src="$AGENTS_DIR/hooks/workflow-run-tests/outcome.js"

    # --- J1: the module exists and owns the parse --------------------------
    if [ -f "$outcome_src" ]; then pass "J1/outcome.js-exists"
    else fail "J1/outcome.js-exists" "expected $outcome_src"; fi

    assert_eq "J2/parseWorkerVerdict-is-exported" "yes" \
        "$(run_with_timeout 30 node -e '
try {
  const m = require(process.argv[1] + "/hooks/workflow-run-tests/outcome.js");
  process.stdout.write(typeof m.parseWorkerVerdict === "function" ? "yes" : "no");
} catch (e) { process.stdout.write("no"); }
' "$AGENTS_WIN" 2>/dev/null || echo "no")"

    # --- J3: exactly ONE `^status:` regex literal across both files --------
    # Counted over the pair, not per file: the constraint is "one site anywhere in
    # the worker-verdict path", and which file holds it is asserted separately by
    # J4 so a failure says which half broke.
    local files=("$hook_src")
    [ -f "$outcome_src" ] && files+=("$outcome_src")

    local n_status n_exit n_hook
    n_status="$(grep -c -- '\^status:' "${files[@]}" 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')"
    assert_eq "J3/single-status-regex-literal" "1" "$n_status"

    # The exit_code line is parsed by the same function and is subject to the same
    # drift (CPR-ORTH: the sibling field of the same parse).
    n_exit="$(grep -c -- '\^exit_code:' "${files[@]}" 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')"
    assert_eq "J3b/single-exit_code-regex-literal" "1" "$n_exit"

    # --- J4: the hook holds NONE of them -----------------------------------
    # This is the direction that actually fails when someone copies the regex back
    # into the hook rather than importing the parser.
    n_hook="$(grep -c -- '\^status:\|\^exit_code:' "$hook_src" 2>/dev/null | awk '{s+=$1} END {print s+0}')"
    assert_eq "J4/hook-has-no-inline-verdict-regex" "0" "$n_hook"

    # --- J5: the veto wrapper and the parser cannot disagree ---------------
    # The grep pin is structural; this is the semantic half. Every header that
    # parses to a non-"pass" status, or to a non-zero exit code, must veto — and
    # the sanctioned one must not. If workerVerdictVetoes ever stops delegating,
    # one of these rows breaks even while the grep still shows one literal.
    local name header want got json
    while IFS='|' read -r name header want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"; want="${want//[[:space:]]/}"
        header="${header#"${header%%[![:space:]]*}"}"
        header="$(printf '%b' "$header")"
        json="$(run_with_timeout 30 node -e 'process.stdout.write(JSON.stringify({header: process.argv[1]}))' "$header" 2>/dev/null)"
        got="$(probe parse "$json")"
        assert_eq "J5/$name" "$want" "$got"
    done <<'TABLE'
sanctioned      | status: pass\nexit_code: 0\n   | pass|0
non-pass-word   | status: fail\nexit_code: 0\n   | fail|0
pass-but-nonzero| status: pass\nexit_code: 7\n   | pass|7
unknown-word    | status: weird\n                 | weird|(null)
TABLE
}
