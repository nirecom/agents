# tests/feat-1699-meta-parent-guard/guard-pathological.sh
# Tests: bin/github-issues/lib/require-meta-parent.sh
# Tags: issue-create, meta-parent, guard, fail-closed, validation, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - What a real `gh issue view` returns for issue #0 or a number beyond GitHub's own
#   range, and what a real auth/network fault writes to stderr.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# Group G — the guard under pathological input
#
# Group A establishes the guard's four verdicts on well-formed input. This group asks the
# only question that matters for a fail-CLOSED component: can any input make it exit 0
# without having confirmed both conditions? Every case below therefore asserts the exact
# non-zero code AND, separately, that the code is not 0 — because "not eligible" is the
# safety property, and the specific code is the contract on top of it.
#
# The four verdicts are not interchangeable at the caller: the dispatcher maps 3 → rc 2
# ("this parent is wrong, pick another") and everything else → rc 1 ("could not tell").
# Collapsing them would turn an unanswerable lookup into a confident rejection.

# gp_run <args…> — guard invocation with rc/stderr captured into GP_RC / GP_ERR.
gp_run() {
    bash "$RWT" 30 bash "$GUARD" "$@" >"$TMP/gp.out" 2>"$TMP/gp.err"
    GP_RC=$?
    GP_ERR="$(cat "$TMP/gp.err")"
    GP_OUT="$(cat "$TMP/gp.out")"
}

# assert_guard_rc <case-id> <want-rc> <args…>
assert_guard_rc() {
    local cid="$1" want="$2"; shift 2
    gp_run "$@"
    if [ "$GP_RC" -eq "$want" ]; then
        pass "G-${cid}-rc${want}"
    else
        fail "G-${cid}-rc${want}" "want rc=$want (got: $GP_RC); stderr: $GP_ERR"
    fi
    # Stated as its own assertion rather than folded into the one above: if the expected
    # code ever changes, this line still holds the line that matters — never eligible.
    if [ "$GP_RC" -ne 0 ]; then
        pass "G-${cid}-not-eligible"
    else
        fail "G-${cid}-not-eligible" "the guard exited 0 (ELIGIBLE) for pathological input — this is the fail-OPEN case the guard exists to prevent"
    fi
}

# --- G1: argv shapes the regex must refuse (rc 2, usage) --------------------------------
setup_mock
export GH_MOCK_LABELS_99="type:task,meta"
export GH_MOCK_TITLE_99="Group: platform hardening"

# A negative number, a signed one, and a decimal: all numeric-looking, none an issue
# number. `-5` additionally tests that a leading dash is not parsed as a flag.
assert_guard_rc "1a-negative" 2 -5
assert_guard_rc "1b-explicit-plus" 2 +5
assert_guard_rc "1c-decimal" 2 5.0
assert_guard_rc "1d-non-numeric" 2 abc
assert_guard_rc "1e-empty-string" 2 ""
assert_guard_rc "1f-leading-space" 2 " 99"
assert_guard_rc "1g-trailing-newline" 2 "$(printf '99\n99')"
# Command-injection shaped input. `grep -qxF`-style literal handling is not available
# here — the value is interpolated into a gh command line — so the regex IS the defence.
assert_guard_rc "1h-shell-semicolon" 2 "99; rm -rf /"
assert_guard_rc "1i-command-substitution" 2 '99$(id)'
# Arity: the guard takes exactly one argument. Two would let a caller smuggle a second
# issue number past the one that was checked.
assert_guard_rc "1j-no-arguments" 2
assert_guard_rc "1k-two-arguments" 2 99 42
# No gh call may be made for any of the above — validation precedes the lookup.
if [ "$(grep -c 'issue view' "$GH_MOCK_ARGS_LOG" 2>/dev/null || true)" -eq 0 ]; then
    pass "G1z-usage-errors-make-no-gh-call"
else
    fail "G1z-usage-errors-make-no-gh-call" "a malformed issue number reached a gh command line: $(grep 'issue view' "$GH_MOCK_ARGS_LOG")"
fi
teardown_mock

# --- G2: numerically valid but nonsensical issue numbers --------------------------------
# `0` and a 21-digit number both satisfy ^[0-9]+$, so the regex admits them and the
# forge is asked. The mock has no such issue, so both come back with neither condition
# met. Pinned as rc 3 (ineligible) rather than rc 2: the guard deliberately does not
# second-guess which numbers GitHub considers real — that is the forge's answer to give.
setup_mock
assert_guard_rc "2a-issue-zero" 3 0
teardown_mock

setup_mock
assert_guard_rc "2b-very-large-number" 3 999999999999999999999
teardown_mock

setup_mock
assert_guard_rc "2c-leading-zeros" 3 0099
teardown_mock

# Wired back through the dispatcher, because rc 3 and rc 4 are only meaningful as the
# rc 2 / rc 1 the caller reports — and zero issues must exist either way.
setup_mock
run_dispatch --verdict sub-of --parent 0 -- --title "child" --body "$(printf "$CANONICAL_BODY")"
if [ "$RC" -eq 2 ] && [ "$(count_creates)" -eq 0 ]; then
    pass "G2d-dispatcher-maps-issue-zero-to-rc2-with-no-creates"
else
    fail "G2d-dispatcher-maps-issue-zero-to-rc2-with-no-creates" "want dispatcher rc 2 with 0 creates for --parent 0 (rc=$RC, creates=$(count_creates)); stderr: $ERR"
fi
teardown_mock

# --- G3: gh absent from PATH → indeterminate, never eligible ----------------------------
# The distinction this case protects: "I cannot ask" must not read as "the answer is no"
# (rc 3 would tell the operator to fix a parent that may be perfectly fine) and must
# certainly not read as "the answer is yes".
setup_mock
mkdir -p "$TMP/empty-bin"
# $BASH, not `bash`: the PATH override is what is under test, so the interpreter cannot
# be looked up through it.
PATH="$TMP/empty-bin" "$BASH" "$GUARD" 99 >"$TMP/gp.out" 2>"$TMP/gp.err"
rc=$?
GP_ERR="$(cat "$TMP/gp.err")"
if [ "$rc" -eq 4 ]; then
    pass "G3-gh-missing-rc4-indeterminate"
else
    fail "G3-gh-missing-rc4-indeterminate" "want rc 4 when gh is not on PATH (got: $rc); stderr: $GP_ERR"
fi
if printf '%s' "$GP_ERR" | grep -qi 'indeterminate'; then
    pass "G3b-gh-missing-says-indeterminate"
else
    fail "G3b-gh-missing-says-indeterminate" "stderr must distinguish an unanswerable lookup from a rejection (got: '$GP_ERR')"
fi
teardown_mock

# --- G4: a SUCCESSFUL lookup whose payload cannot be parsed -----------------------------
# rc=0 from gh, garbage on stdout. The `if ! RAW=$(…)` check passes, so the true/false
# validation is the only thing standing between the payload and an eligibility verdict.
# Each row is a different way the two-line boolean pair can be wrong.
setup_mock
while IFS='|' read -r cid payload; do
    [ -z "$cid" ] && continue
    export GH_MOCK_VIEW_GARBAGE="$payload"
    assert_guard_rc "4-${cid}" 4 99
done <<'GARBAGE_TABLE'
a-plain-prose|not a boolean at all
b-single-line-true|true
c-json-object|{"labels":[],"title":"x"}
d-yes-no|yes
e-numeric-booleans|1
f-capitalised|True
GARBAGE_TABLE
unset GH_MOCK_VIEW_GARBAGE
teardown_mock

# A well-formed pair that says "no" is NOT indeterminate — this row is what keeps G4 from
# passing on a guard that simply returned 4 for everything.
setup_mock
export GH_MOCK_VIEW_GARBAGE="$(printf 'false\nfalse')"
assert_guard_rc "4h-well-formed-false-pair-is-rc3-not-rc4" 3 99
unset GH_MOCK_VIEW_GARBAGE
teardown_mock

# …and a well-formed "yes" pair still reaches rc 0. Without this the whole group could be
# satisfied by a guard that never returns 0 at all, which would be a different bug.
setup_mock
export GH_MOCK_VIEW_GARBAGE="$(printf 'true\ntrue')"
gp_run 99
if [ "$GP_RC" -eq 0 ]; then
    pass "G4i-well-formed-true-pair-still-eligible"
else
    fail "G4i-well-formed-true-pair-still-eligible" "want rc 0 (got: $GP_RC) — the guard must still be able to say yes; stderr: $GP_ERR"
fi
unset GH_MOCK_VIEW_GARBAGE
teardown_mock

# --- Paired gaps (Pattern 3, skills/_shared/test-design/protection-fix-tests.md) ---------
# SKIPPED: what github.com itself returns for issue #0 or a 21-digit number.
# Because: the mock answers every number identically; only a live API distinguishes
#          "no such issue" (which would be an rc 4 candidate) from "exists, ineligible".
# L3 gap:  if the real API errors on #0, the observed verdict shifts from rc 3 to rc 4 —
#          both fail-closed, so the safety property holds either way.
