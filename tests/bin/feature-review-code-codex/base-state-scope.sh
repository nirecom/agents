# Part of tests/bin/feature-review-code-codex.sh (sourced, not standalone).
# Tests: bin/review-code-codex
# Tags: codex, review, merge-base, base-state, truncation, boundary, prompt-order, scope:issue-specific, pwsh-not-required, TL2
# Y (#1638) covers what X1-X6 (SUSPECT/RESOLVED) cannot: the remaining base states FALLBACK/UNRESOLVED/RECORDED (Y3-Y5, each a different review-coverage caveat), the exact `>` vs `>=` truncation boundary (Y1-Y2, built to an exact `wc -l`), and whether the scope warning precedes the adversarial preamble (Y6) — a caveat appended after the instruction is read as material, not constraint.
# TL3 gap: codex CLI is mocked (only enough to make PROMPT observable); merge-base states are injected via --base-state, not produced by the real resolver. Mitigation: WORKFLOW_USER_VERIFIED preflight, category merge-base-suspect.

# The y_* helpers and the exact-size Y_AT_REPO / Y_OVER_REPO fixtures (shared with -path-priority).
# shellcheck source=./y-fixtures.sh
. "$AGENTS_ROOT/tests/bin/feature-review-code-codex/y-fixtures.sh"

if [ -z "$Y_AT_REPO" ] || [ -z "$Y_OVER_REPO" ]; then
    # The premise. Without exact fixtures the two rows would be asserting approximate sizes and
    # could not distinguish `>` from `>=` at all, which is the only thing they exist for.
    fail "Y1/Y2: could not build diffs of exactly 5000 and 5001 lines, so the truncation boundary cannot be tested"
else
    Y_OUT="$(y_run "$Y_AT_REPO" --base main --no-log)"
    if echo "$Y_OUT" | grep -q "^## Codex Review Scope: TRUNCATED"; then
        fail "Y1: a diff of exactly 5000 lines — the cap, not past it — was announced as TRUNCATED. Output: $Y_OUT"
    else
        pass "Y1: a diff of exactly 5000 lines is reviewed whole and carries no TRUNCATED line"
    fi
    # Vacuity guard: the absence of a TRUNCATED line only means "not truncated" if the review
    # actually ran. A run that aborted would satisfy Y1 by printing nothing at all.
    if echo "$Y_OUT" | grep -q "^## Codex Review: "; then
        pass "Y1-verdict: and the at-the-cap run produced a verdict"
    else
        fail "Y1-verdict: the at-the-cap run produced no verdict, so Y1's silence proves nothing. Output: $Y_OUT"
    fi

    Y_OUT="$(y_run "$Y_OVER_REPO" --base main --no-log)"
    if echo "$Y_OUT" | grep -q "^## Codex Review Scope: TRUNCATED"; then
        pass "Y2: one line past the cap is announced as TRUNCATED"
    else
        fail "Y2: a diff of 5001 lines was truncated without a TRUNCATED scope line. Output: $Y_OUT"
    fi
    # The word the reader acts on. "TRUNCATED" alone describes the mechanism; the line has to
    # say the review is INCOMPLETE, because that is the part that changes what the reader does
    # with a PERFORMED verdict.
    if echo "$Y_OUT" | grep -E "^## Codex Review Scope: TRUNCATED" | grep -qi "INCOMPLETE"; then
        pass "Y2-incomplete: and the line says the review is incomplete, not merely that a diff was cut"
    else
        fail "Y2-incomplete: the TRUNCATED line does not tell the reader the review is INCOMPLETE. Output: $Y_OUT"
    fi
fi

# --- Y3-Y5: the states X3/X4 leave out. Two are caveats; one is not.
for y_state in FALLBACK UNRESOLVED; do
    Y_OUT="$(y_run "$REPO" --base main --base-state "$y_state" --no-log)"
    if echo "$Y_OUT" | grep -q "^## Codex Review Scope: BASE-$y_state"; then
        pass "Y3[$y_state]: an untrustworthy base is declared as BASE-$y_state next to the verdict"
    else
        fail "Y3[$y_state]: no 'BASE-$y_state' scope line. Output: $Y_OUT"
    fi
done

# RECORDED is the state the #1638 fix makes ordinary. It is a FACT, not a guess, so it must be
# on the silent side with RESOLVED — a caveat printed on every ordinary run is a caveat the
# reader stops seeing, which is how the SUSPECT line loses its meaning.
Y_OUT="$(y_run "$REPO" --base main --base-state RECORDED --no-log)"
if echo "$Y_OUT" | grep -q "^## Codex Review Scope: BASE-"; then
    fail "Y4: --base-state RECORDED printed a BASE- caveat although a recorded baseline is a fact. Output: $Y_OUT"
else
    pass "Y4: --base-state RECORDED carries no caveat — the recorded base is trustworthy"
fi
if echo "$Y_OUT" | grep -q "^## Codex Review: "; then
    pass "Y4-verdict: and the review still ran"
else
    fail "Y4-verdict: no verdict line, so Y4's silence proves nothing. Output: $Y_OUT"
fi

# --- Y6: inside the prompt, the caveat must come BEFORE the instruction it qualifies.
y_install_capturing_mock
rm -f "$Y_CAPTURE"
y_run "$REPO" --base main --base-state SUSPECT --no-log >/dev/null

if [ ! -f "$Y_CAPTURE" ]; then
    fail "Y6: no prompt was captured, so its ordering cannot be checked"
else
    # `|| true` on every grep: the parent runs under `set -e`, and a grep that finds nothing is
    # the expected pre-fix result, not a reason to abort the whole suite.
    y_warn_line="$(grep -n -i -m1 -E "SUSPECT|not trustworthy|scope warning" "$Y_CAPTURE" | cut -d: -f1 || true)"
    y_preamble_line="$(grep -n -m1 "authored by Claude" "$Y_CAPTURE" | cut -d: -f1 || true)"
    if [ -z "$y_warn_line" ]; then
        fail "Y6: the prompt sent to codex contains no scope warning at all — the caveat exists only on stdout, where the model never sees it"
    elif [ -z "$y_preamble_line" ]; then
        fail "Y6: the adversarial preamble is missing from the captured prompt, so ordering cannot be asserted"
    elif [ "$y_warn_line" -lt "$y_preamble_line" ]; then
        pass "Y6: the scope warning precedes the adversarial preamble, so it constrains the task rather than reading as part of the diff"
    else
        fail "Y6: the scope warning is at line $y_warn_line, AFTER the preamble at line $y_preamble_line — a caveat that arrives after the instruction is read as material, not as a constraint"
    fi
fi

# The truncation caveat has the same obligation and a different trigger, so it is a separate
# row: an implementation can inject the base-state warning correctly and still append the
# truncation notice to the end of the prompt.
if [ -n "$Y_OVER_REPO" ]; then
    rm -f "$Y_CAPTURE"
    y_run "$Y_OVER_REPO" --base main --no-log >/dev/null
    if [ ! -f "$Y_CAPTURE" ]; then
        fail "Y7: no prompt was captured for the truncated run"
    else
        y_trunc_line="$(grep -n -i -m1 -E "truncat|incomplete" "$Y_CAPTURE" | cut -d: -f1 || true)"
        y_preamble_line="$(grep -n -m1 "authored by Claude" "$Y_CAPTURE" | cut -d: -f1 || true)"
        if [ -z "$y_trunc_line" ]; then
            fail "Y7: the prompt for a truncated diff never says the diff was cut — the model reviews a partial diff believing it is whole"
        elif [ -z "$y_preamble_line" ]; then
            fail "Y7: the adversarial preamble is missing from the captured prompt, so ordering cannot be asserted"
        elif [ "$y_trunc_line" -lt "$y_preamble_line" ]; then
            pass "Y7: the truncation notice also precedes the preamble"
        else
            fail "Y7: the truncation notice is at line $y_trunc_line, after the preamble at line $y_preamble_line"
        fi
    fi
fi

# SKIPPED: a real codex CLI call.
# Because: every row here replaces codex with a mock, which is what makes the PROMPT
#          observable at all; a real call costs a billed model invocation per row.
# TL3 gap: a prompt that is well-ordered but too large for the real model's context, and the
#          real CLI's own argument handling. Neither is reproducible with a shell mock.
