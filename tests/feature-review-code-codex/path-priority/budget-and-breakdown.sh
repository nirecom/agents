# Part of tests/feature-review-code-codex/path-priority.sh (sourced, not standalone).
# Tests: bin/review-code-codex
# Tags: codex, review, truncation, budget, breakdown, reviewed-dropped, scope:issue-specific, pwsh-not-required, TL2
#
# B — THE TWO CLAIMS THE TRUNCATION REPORT MAKES, CHECKED AGAINST WHAT WAS ACTUALLY SENT.
#
# "Truncated to N lines" and "K of T files were reviewed, these D were not" are the only
# things a reader has to go on when a review comes back clean. Both are claims about material
# the reader cannot see. Elsewhere in this suite they are checked by grepping for the label —
# which an implementation that announces a cap of 5000 and forwards all 6007 lines, or one
# that lists a path under Reviewed and never sent its chunk, passes without difficulty.
#
# The rows here read the captured prompt instead: B1 measures the diff body against every
# configured cap, and B2 reconciles the Reviewed/Dropped breakdown against the content that
# reached the model, path by path.
#
# TL3 gap (what this file does NOT catch):
# - The real codex CLI's own limits: a body inside the line budget can still exceed the live
#   model's context window, and the line count these rows measure says nothing about tokens.
# - Whether a human reading the Reviewed/Dropped breakdown draws the right conclusion from it.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: merge-base-suspect.

# ---------------------------------------------------------------------------
# B1 — the cap is enforced, not merely printed. Measured at several budgets on one oversized
#      fixture, because a hardcoded `head -n 5000` satisfies any single-cap assertion whose
#      cap happens to be 5000 and nothing else.
# ---------------------------------------------------------------------------
B_HUGE="$(pp_new_repo pp-b-huge)"
pp_gen "$B_HUGE/huge.txt" 6000 "pp-b-huge-marker"
git -C "$B_HUGE" add huge.txt
git -C "$B_HUGE" commit -q -m "6000-line file"

for b_cap in 10 137 1000 4999; do
    PP_ENV=(CODEX_REVIEW_MAX_DIFF_LINES="$b_cap")
    PP_OUT="$(pp_run "$B_HUGE" --base main --no-log)"
    b_n="$(pp_diff_body_lines "$PP_CAPTURE")"
    if [ -z "$b_n" ] || [ "$b_n" -eq 0 ]; then
        fail "B1[cap=$b_cap]: nothing reviewable was delimited in the prompt — the budget was enforced by sending an empty review. Output: $PP_OUT"
    elif [ "$b_n" -le "$b_cap" ]; then
        pass "B1[cap=$b_cap]: $b_n lines of diff body were actually sent, inside the configured cap"
    else
        fail "B1[cap=$b_cap]: $b_n lines of diff body were sent under a cap of $b_cap — the cap is a label, not a limit"
    fi
done
PP_ENV=()

# The default cap is subject to the same measurement: nothing configured, 6000 lines offered.
PP_OUT="$(pp_run "$B_HUGE" --base main --no-log)"
b_n="$(pp_diff_body_lines "$PP_CAPTURE")"
if [ "${b_n:-0}" -gt 0 ] && [ "$b_n" -le 5000 ]; then
    pass "B1-default: with nothing configured, $b_n lines were sent — inside the 5000 default"
else
    fail "B1-default: the default cap let $b_n lines of diff body through. Output: $PP_OUT"
fi

# ---------------------------------------------------------------------------
# B2 — the breakdown is exact. Four files, a cap that admits precisely the first two, and
#      stop-at-first-skip adoption in path order — so the expected split is known in advance
#      rather than read back off the implementation's own answer.
#
#      Four separate things are asserted because they fail separately: the declared counts,
#      the listed paths, the disjointness of the two lists, and whether the content behind
#      each list actually matches. A path can be listed under Reviewed with its chunk never
#      sent, which is the failure mode that costs a reader the most.
# ---------------------------------------------------------------------------
B_MIX="$(pp_new_repo pp-b-mix)"
pp_gen "$B_MIX/a-keep.txt" 10 "pp-b-a-marker"
pp_gen "$B_MIX/b-keep.txt" 10 "pp-b-b-marker"
pp_gen "$B_MIX/c-drop.txt" 500 "pp-b-c-marker"
pp_gen "$B_MIX/d-drop.txt" 500 "pp-b-d-marker"
git -C "$B_MIX" add a-keep.txt b-keep.txt c-drop.txt d-drop.txt
git -C "$B_MIX" commit -q -m "four files, two small two large"

PP_ENV=(CODEX_REVIEW_MAX_DIFF_LINES=200)
PP_OUT="$(pp_run "$B_MIX" --base main --no-log)"
PP_ENV=()

b_rc="$(pp_scope_count "$PP_OUT" Reviewed)"
b_dc="$(pp_scope_count "$PP_OUT" Dropped)"
b_rp="$(pp_scope_paths "$PP_OUT" Reviewed | sort | tr '\n' ' ')"
b_dp="$(pp_scope_paths "$PP_OUT" Dropped | sort | tr '\n' ' ')"

if [ -z "$b_rc" ] || [ -z "$b_dc" ]; then
    fail "B2-counts: the truncated four-file review printed no Reviewed/Dropped counts at all. Output: $PP_OUT"
elif [ "$b_rc" = "2" ] && [ "$b_dc" = "2" ]; then
    pass "B2-counts: the breakdown declares 2 reviewed and 2 dropped, matching the 4 changed files"
else
    fail "B2-counts: the breakdown declares $b_rc reviewed and $b_dc dropped, not 2 and 2. Output: $PP_OUT"
fi

if [ "$b_rp" = "a-keep.txt b-keep.txt " ]; then
    pass "B2-reviewed: Reviewed names exactly the two files the budget could take"
else
    fail "B2-reviewed: Reviewed lists [$b_rp], not 'a-keep.txt b-keep.txt'. Output: $PP_OUT"
fi
if [ "$b_dp" = "c-drop.txt d-drop.txt " ]; then
    pass "B2-dropped: Dropped names exactly the two files that did not fit"
else
    fail "B2-dropped: Dropped lists [$b_dp], not 'c-drop.txt d-drop.txt'. Output: $PP_OUT"
fi

# Disjointness is its own row: a path in both lists tells the reader it was reviewed and
# tells them it was not, and whichever half they act on, the other half was a lie.
b_both=""
for b_p in $(pp_scope_paths "$PP_OUT" Reviewed); do
    if pp_scope_paths "$PP_OUT" Dropped | grep -qxF -- "$b_p"; then b_both="$b_both $b_p"; fi
done
if [ -z "$b_both" ]; then
    pass "B2-disjoint: no path is listed as both reviewed and dropped"
else
    fail "B2-disjoint: these paths appear on both lines:$b_both. Output: $PP_OUT"
fi

# And the claim reconciled against the captured content — the half that a report generated
# independently of the adoption loop would fail.
b_body_ok=1
for b_m in pp-b-a-marker pp-b-b-marker; do
    if ! { [ -f "$PP_CAPTURE" ] && pp_diff_body "$PP_CAPTURE" | grep -q "$b_m"; }; then
        b_body_ok=0
        fail "B2-content: $b_m is listed under Reviewed but its content never reached the prompt"
    fi
done
for b_m in pp-b-c-marker pp-b-d-marker; do
    if [ -f "$PP_CAPTURE" ] && pp_diff_body "$PP_CAPTURE" | grep -q "$b_m"; then
        b_body_ok=0
        fail "B2-content: $b_m is listed under Dropped yet its content was sent to the model anyway"
    fi
done
if [ "$b_body_ok" = "1" ]; then
    pass "B2-content: every path listed under Reviewed has its content in the prompt, and every dropped one has none of it"
fi

# The totals have to close. K + D that does not equal T means some changed file was accounted
# for on neither line, which is exactly the file a reader would never think to ask about.
if printf '%s\n' "$PP_OUT" | grep -E "^## Codex Review Scope: TRUNCATED" | grep -q "2/4 changed files"; then
    pass "B2-total: the TRUNCATED headline reconciles as 2/4, agreeing with both breakdown lines"
else
    fail "B2-total: the TRUNCATED headline does not report 2/4 changed files. Output: $PP_OUT"
fi
