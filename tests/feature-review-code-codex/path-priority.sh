# Part of tests/feature-review-code-codex.sh (sourced, not standalone).
# Tests: bin/review-code-codex, bin/resolve-merge-base.sh, skills/review-code-security/scripts/run-quality-gates.sh
# Tags: codex, review, truncation, priority, path-ordering, budget, merge-base, scope:issue-specific, pwsh-not-required, TL2
# P (#1976 / #1750): X/Y pin that a diff past the cap is ANNOUNCED, not WHICH lines survive — `head -n` over a concatenated diff can drop all three edited files behind an unrelated committed one (#1976) and counts the diff one line short (#1750). Rows below target the NOT-yet-implemented fix: priority file set, per-path chunks, stop-at-first-skip, configurable budget, EXCLUDED and PRIORITY-UNTRUSTED reports — expected to fail until it lands. Sourced last, after base-state-scope.sh, to reuse its Y1/Y2 fixtures and 6000-line BIG_REPO.
# TL3 gap: real codex CLI arg/stdin handling and live model context limits are untested; P8 stubs resolve-merge-base.sh so `warn` is an asserted input, not a real branching sentinel. Mitigation: WORKFLOW_USER_VERIFIED preflight, category merge-base-suspect.

# The fixture builders and the prompt/breakdown observation helpers, shared with the sibling
# parts sourced at the bottom of this file. Sourced FIRST because every row below uses them.
# shellcheck source=./path-priority/helpers.sh
. "$AGENTS_ROOT/tests/feature-review-code-codex/path-priority/helpers.sh"

pp_install_capturing_mock

# ---------------------------------------------------------------------------
# P1 — the ordering itself, on the path that matters most: a file the session is still
#      actively editing, sitting behind a file that alone exhausts the budget, and sorting
#      AFTER it so that byte order cannot rescue it. Under `head -n` over a concatenated diff
#      the surviving 5000 lines are all a-huge.txt and the session's own file is never seen.
#      Priority ordering is the only thing that can put z-staged.txt in front of it.
# ---------------------------------------------------------------------------
PP_R1="$(pp_new_repo pp-p1)"
pp_gen "$PP_R1/a-huge.txt" 6000 "pp-p1-huge-marker"
pp_gen "$PP_R1/z-staged.txt" 5 "pp-p1-staged-marker"
git -C "$PP_R1" add a-huge.txt z-staged.txt
git -C "$PP_R1" commit -q -m "both files committed"
# The staged edit on top is what marks z-staged.txt as a file this session is still working
# on — the signal the priority set is derived from.
echo "pp-p1-staged-on-top" >> "$PP_R1/z-staged.txt"
git -C "$PP_R1" add z-staged.txt

PP_ENV=()
PP_OUT="$(pp_run "$PP_R1" --base main --no-log)"

if [ -f "$PP_CAPTURE" ] && pp_diff_body "$PP_CAPTURE" | grep -q "pp-p1-staged-marker"; then
    pass "P1: the session's own staged file is reviewed even though it sorts after a file that alone exhausts the budget"
else
    fail "P1: the staged file's content never reached the reviewed body — the budget went to the oversized file that happens to sort first. Output: $PP_OUT"
fi
if printf '%s\n' "$PP_OUT" | grep -E "^Dropped \(" | grep -q "a-huge.txt"; then
    pass "P1: and the over-budget file is named on a Dropped line rather than silently cut"
else
    fail "P1: no 'Dropped (' line naming a-huge.txt. Output: $PP_OUT"
fi

# The same ordering question on the uncommitted-fallback path, where every changed path is the
# session's own and the only ordering that matters is size against budget.
PP_R1F="$(pp_new_repo pp-p1f)"
pp_gen "$PP_R1F/a-small.txt" 5 "pp-p1f-small-marker"
pp_gen "$PP_R1F/z-huge.txt" 6000 "pp-p1f-huge-marker"
PP_OUT="$(pp_run "$PP_R1F" --base main --no-log)"
if [ -f "$PP_CAPTURE" ] && pp_diff_body "$PP_CAPTURE" | grep -q "pp-p1f-small-marker"; then
    pass "P1-fallback: with no committed range, the small changed file still survives alongside an over-budget one"
else
    fail "P1-fallback: the small file's content is absent from the reviewed body. Output: $PP_OUT"
fi

# ---------------------------------------------------------------------------
# P2 — determinism. A breakdown that reorders between runs cannot be diffed, and a reader
#      who re-runs to check a claim gets a different answer to the same question. The summary
#      text alone is not enough: it could match while the actual diff content sent to the model
#      differs between runs (a different reviewed-file subset, or the same files in a different
#      order), so the [DIFF START]..[DIFF END] body is captured and compared byte-for-byte too.
#      Captured BEFORE the second run, because pp_run overwrites $PP_CAPTURE on every call.
# ---------------------------------------------------------------------------
PP_OUT_A="$(pp_run "$PP_R1" --base main --no-log)"
PP_BODY_A="$(pp_diff_body "$PP_CAPTURE")"
PP_BODY_A_LINES="$(pp_diff_body_lines "$PP_CAPTURE")"
PP_OUT_B="$(pp_run "$PP_R1" --base main --no-log)"
PP_BODY_B="$(pp_diff_body "$PP_CAPTURE")"
PP_BODY_B_LINES="$(pp_diff_body_lines "$PP_CAPTURE")"
PP_BD_A="$(printf '%s\n' "$PP_OUT_A" | grep -E "^(Reviewed|Dropped) \(" || true)"
PP_BD_B="$(printf '%s\n' "$PP_OUT_B" | grep -E "^(Reviewed|Dropped) \(" || true)"
if [ -z "$PP_BD_A" ]; then
    fail "P2: no Reviewed/Dropped breakdown lines at all, so determinism cannot be asserted. Output: $PP_OUT_A"
elif [ "$PP_BD_A" = "$PP_BD_B" ]; then
    pass "P2: the Reviewed/Dropped breakdown is byte-identical across two runs of one fixture"
else
    fail "P2: the breakdown differs between two identical runs. A: $PP_BD_A B: $PP_BD_B"
fi
if [ -z "$PP_BODY_A" ]; then
    fail "P2-body: no [DIFF START]..[DIFF END] body was captured for the first run, so byte-identity of the actual reviewed content cannot be asserted"
elif [ "$PP_BODY_A" = "$PP_BODY_B" ]; then
    pass "P2-body: the full diff body handed to the model is byte-identical across two runs ($PP_BODY_A_LINES lines both times)"
else
    fail "P2-body: the diff body differs between two identical runs even though the summary may match — same claim, different actual content (A: $PP_BODY_A_LINES lines, B: $PP_BODY_B_LINES lines)"
fi

# ---------------------------------------------------------------------------
# P3 — quiescence. Every line P1/P2 assert must be ABSENT on an ordinary in-budget review,
#      or they become decoration the reader learns to skip past.
# ---------------------------------------------------------------------------
PP_R3="$(pp_new_repo pp-p3)"
pp_gen "$PP_R3/small.txt" 20 "pp-p3-marker"
git -C "$PP_R3" add small.txt
git -C "$PP_R3" commit -q -m "small committed change"

PP_ENV=()
PP_OUT="$(pp_run "$PP_R3" --base main --no-log)"
if printf '%s\n' "$PP_OUT" | grep -qE "^## Codex Review Scope: (TRUNCATED|EXCLUDED)|^(Reviewed|Dropped) \(|^Partially reviewed:"; then
    fail "P3: an in-budget review with nothing excluded still printed a scope/breakdown line. Output: $PP_OUT"
else
    pass "P3: an in-budget review with nothing excluded prints no scope or breakdown line"
fi
if pp_has "$PP_OUT" "^## Codex Review: PERFORMED"; then
    pass "P3-verdict: and the quiet run is quiet because it succeeded, not because it aborted"
else
    fail "P3-verdict: the quiet run produced no PERFORMED verdict, so P3's silence proves nothing. Output: $PP_OUT"
fi

# ---------------------------------------------------------------------------
# P4 — one file, alone past the budget. Adoption cannot take it whole and there is nothing
#      else to adopt, so the honest outcome is a partial review that says it is partial —
#      not an empty prompt, which would be a review of nothing reported as PERFORMED.
# ---------------------------------------------------------------------------
PP_R4="$(pp_new_repo pp-p4)"
pp_gen "$PP_R4/only-huge.txt" 6000 "pp-p4-marker"
git -C "$PP_R4" add only-huge.txt
git -C "$PP_R4" commit -q -m "one oversized file"

PP_ENV=()
PP_OUT="$(pp_run "$PP_R4" --base main --no-log)"
if pp_has "$PP_OUT" "^## Codex Review: PERFORMED"; then
    pass "P4: a single file larger than the whole budget is still reviewed (PERFORMED)"
else
    fail "P4: the single-oversized-file case did not reach a PERFORMED verdict. Output: $PP_OUT"
fi
if pp_has "$PP_OUT" "^Partially reviewed:"; then
    pass "P4: and the outcome is declared partial rather than passed off as whole"
else
    fail "P4: no 'Partially reviewed:' line for a file that could only be partly adopted. Output: $PP_OUT"
fi
if [ -f "$PP_CAPTURE" ] && grep -q "pp-p4-marker" "$PP_CAPTURE"; then
    pass "P4: the partial adoption carries real diff content, not an empty prompt"
else
    fail "P4: the prompt contains none of the file's content — the full-stop path produced an empty review"
fi
# The cap is a cap, not a label. Measured on the material actually sent, so an implementation
# that announces 5000 and forwards 6007 lines cannot satisfy this row.
PP_BODY_N="$(pp_diff_body_lines "$PP_CAPTURE")"
if [ -z "$PP_BODY_N" ] || [ "$PP_BODY_N" -eq 0 ]; then
    fail "P4-budget: no reviewable body was delimited in the prompt at all"
elif [ "$PP_BODY_N" -le 5000 ]; then
    pass "P4-budget: the body between [DIFF START] and [DIFF END] is $PP_BODY_N lines — inside the 5000 default"
else
    fail "P4-budget: the body is $PP_BODY_N lines, past the 5000 cap the run announced"
fi

# ---------------------------------------------------------------------------
# P5 — the same full-stop path at the smallest threshold that can exist. A budget of 1 makes
#      EVERY chunk oversized, which is where an off-by-one or a `head -n 0` shows up as an
#      empty prompt reported as a completed review.
# ---------------------------------------------------------------------------
PP_ENV=(CODEX_REVIEW_MAX_DIFF_LINES=1)
PP_OUT="$(pp_run "$PP_R3" --base main --no-log)"
if pp_has "$PP_OUT" "^## Codex Review Scope: TRUNCATED"; then
    pass "P5: a budget of 1 line announces TRUNCATED"
else
    fail "P5: a budget of 1 line produced no TRUNCATED line. Output: $PP_OUT"
fi
PP_BODY_N="$(pp_diff_body_lines "$PP_CAPTURE")"
if [ "${PP_BODY_N:-0}" = "1" ]; then
    pass "P5: exactly one line of diff was sent — the budget was enforced, not merely announced"
else
    fail "P5: a budget of 1 sent $PP_BODY_N lines of diff body. Output: $PP_OUT"
fi
if [ -f "$PP_CAPTURE" ] && pp_diff_body "$PP_CAPTURE" | grep -q "^diff --git"; then
    pass "P5: and the one adopted line is real diff content, so the prompt is not empty"
else
    fail "P5: the prompt carries no diff line at a budget of 1 — the review was of nothing. Output: $PP_OUT"
fi
PP_ENV=()

# ---------------------------------------------------------------------------
# P6 — degraded-state suppression, tested where it can actually fail. The committed range is
#      EMPTY here, so the untracked file is a genuine review candidate under every state and
#      its absence means suppression rather than "the committed diff took priority anyway".
#      Both halves are asserted: the three degraded states must withhold the content, and the
#      two trustworthy ones must include it — a blanket suppression would satisfy the first
#      half forever while quietly costing every ordinary run its untracked files.
# ---------------------------------------------------------------------------
PP_R6="$(pp_new_repo pp-p6)"
echo "pp-p6-tracked-edit" >> "$PP_R6/README.md"
pp_gen "$PP_R6/secret-untracked.txt" 10 "pp-p6-untracked-marker"

for pp_state in SUSPECT FALLBACK UNRESOLVED; do
    PP_OUT="$(pp_run "$PP_R6" --base main --base-state "$pp_state" --no-log)"
    if [ -f "$PP_CAPTURE" ] && grep -q "pp-p6-untracked-marker" "$PP_CAPTURE"; then
        fail "P6[$pp_state]: an untracked file's raw content was sent to the model under a degraded base state"
    elif pp_has "$PP_OUT" "secret-untracked.txt"; then
        fail "P6[$pp_state]: the untracked path was named in the scope report while degraded. Output: $PP_OUT"
    elif ! pp_has "$PP_OUT" "^## Codex Review: "; then
        fail "P6[$pp_state]: the run produced no verdict, so its silence about the untracked file proves nothing. Output: $PP_OUT"
    else
        pass "P6[$pp_state]: the untracked file stays out of both the prompt and the report, and the review still ran"
    fi
done

for pp_state in RECORDED RESOLVED; do
    PP_OUT="$(pp_run "$PP_R6" --base main --base-state "$pp_state" --no-log)"
    if [ -f "$PP_CAPTURE" ] && grep -q "pp-p6-untracked-marker" "$PP_CAPTURE"; then
        pass "P6[$pp_state]: a trustworthy base state still reviews the untracked file — suppression is targeted, not blanket"
    else
        fail "P6[$pp_state]: the untracked file was withheld although the base state is trustworthy. Output: $PP_OUT"
    fi
done

# ---------------------------------------------------------------------------
# P7 — the budget is a configuration value, not a constant. A repo whose review genuinely
#      needs a different cap must be able to set one, and a malformed setting must not
#      silently become a cap of zero.
# ---------------------------------------------------------------------------
PP_R7="$(pp_new_repo pp-p7)"
pp_gen "$PP_R7/mid.txt" 200 "pp-p7-marker"
git -C "$PP_R7" add mid.txt
git -C "$PP_R7" commit -q -m "200-line file"

PP_ENV=(CODEX_REVIEW_MAX_DIFF_LINES=50)
PP_OUT="$(pp_run "$PP_R7" --base main --no-log)"
if printf '%s\n' "$PP_OUT" | grep -E "^## Codex Review Scope: TRUNCATED" | grep -q "50"; then
    pass "P7: CODEX_REVIEW_MAX_DIFF_LINES=50 truncates a 200-line diff and names 50 as the cap"
else
    fail "P7: the configured cap of 50 was not applied or not reported. Output: $PP_OUT"
fi
PP_BODY_N="$(pp_diff_body_lines "$PP_CAPTURE")"
if [ -z "$PP_BODY_N" ] || [ "$PP_BODY_N" -eq 0 ]; then
    fail "P7-budget: the cap of 50 produced an empty reviewable body"
elif [ "$PP_BODY_N" -le 50 ]; then
    pass "P7-budget: $PP_BODY_N lines of diff were actually sent under a cap of 50"
else
    fail "P7-budget: the run announced a cap of 50 and sent $PP_BODY_N lines of diff body"
fi

PP_ENV=(CODEX_REVIEW_MAX_DIFF_LINES=abc)
PP_OUT="$(pp_run "$PP_R7" --base main --no-log)"
if pp_has "$PP_OUT" "^## Codex Review Scope: TRUNCATED"; then
    fail "P7-invalid: a non-numeric cap truncated a 200-line diff instead of falling back to the 5000 default. Output: $PP_OUT"
elif pp_has "$PP_OUT" "^## Codex Review: PERFORMED"; then
    pass "P7-invalid: a non-numeric cap falls back to the default and the review still runs"
else
    fail "P7-invalid: a non-numeric cap broke the run entirely. Output: $PP_OUT"
fi
PP_ENV=()

# ---------------------------------------------------------------------------
# P8 — priority ordering is only as trustworthy as the baseline it is derived from. When the
#      recorded baseline was created AFTER the session's first commit, "the session's own
#      files" is a set computed from the wrong starting point, and a truncated review ordered
#      by it can drop the very changes it claims to prioritise.
# ---------------------------------------------------------------------------
PP_STUB_DIR="$TMPDIR_BASE/pp-agents-stub"
PP_BIG="${BIG_REPO:-}"
if [ -z "$PP_BIG" ] || [ ! -d "$PP_BIG" ]; then
    PP_BIG="$(pp_new_repo pp-big)"
    pp_gen "$PP_BIG/big.txt" 6000 "pp-big-marker"
    git -C "$PP_BIG" add big.txt
    git -C "$PP_BIG" commit -q -m "big commit"
fi

pp_write_resolver_stub "$PP_STUB_DIR" "post-session-head"
PP_ENV=(AGENTS_CONFIG_DIR="$PP_STUB_DIR")
PP_OUT="$(pp_run "$PP_BIG" --base main --base-state RECORDED --no-log)"
if pp_has "$PP_OUT" "^## Codex Review Scope: PRIORITY-UNTRUSTED"; then
    pass "P8a: a contaminated recorded baseline plus a truncated review declares PRIORITY-UNTRUSTED"
else
    fail "P8a: no PRIORITY-UNTRUSTED line although the baseline warns post-session-head and the diff was truncated. Output: $PP_OUT"
fi
# The line has to send the reader somewhere. "The ordering cannot be trusted" with no pointer
# to the merge-base NOTE that explains WHY leaves the reader with a warning and no next step.
if printf '%s\n' "$PP_OUT" | grep -E "^## Codex Review Scope: PRIORITY-UNTRUSTED" | grep -qF "## merge-base: NOTE"; then
    pass "P8a-crossref: and it points at the '## merge-base: NOTE' line printed above it"
else
    fail "P8a-crossref: the PRIORITY-UNTRUSTED line never names the merge-base NOTE it depends on. Output: $PP_OUT"
fi

pp_write_resolver_stub "$PP_STUB_DIR" "none"
PP_OUT="$(pp_run "$PP_BIG" --base main --base-state RECORDED --no-log)"
if pp_has "$PP_OUT" "^## Codex Review Scope: PRIORITY-UNTRUSTED"; then
    fail "P8b: an uncontaminated baseline still printed PRIORITY-UNTRUSTED, so the line means nothing. Output: $PP_OUT"
else
    pass "P8b: a baseline with no warning prints no PRIORITY-UNTRUSTED line"
fi

rm -f "$PP_STUB_DIR/bin/resolve-merge-base.sh"
PP_OUT="$(pp_run "$PP_BIG" --base main --base-state RECORDED --no-log)"
if ! pp_has "$PP_OUT" "^## Codex Review: PERFORMED"; then
    fail "P8c: the resolver being absent cost the review itself. Output: $PP_OUT"
elif pp_has "$PP_OUT" "^## Codex Review Scope: PRIORITY-UNTRUSTED"; then
    fail "P8c: a missing resolver was reported as a contaminated baseline. Output: $PP_OUT"
else
    pass "P8c: a missing resolver is survived silently — the review completes and claims no contamination"
fi

# The symmetric half of P8a: same contaminated baseline, same RECORDED state, but a diff that
# fits. Nothing was dropped, so there is no priority decision to distrust and no line is owed.
pp_write_resolver_stub "$PP_STUB_DIR" "post-session-head"
PP_OUT="$(pp_run "$PP_R3" --base main --base-state RECORDED --no-log)"
if pp_has "$PP_OUT" "^## Codex Review Scope: PRIORITY-UNTRUSTED"; then
    fail "P8d: an in-budget review declared PRIORITY-UNTRUSTED although nothing was prioritised away. Output: $PP_OUT"
elif pp_has "$PP_OUT" "^## Codex Review: PERFORMED"; then
    pass "P8d: a contaminated baseline on an in-budget review prints no PRIORITY-UNTRUSTED line, and the review still ran"
else
    fail "P8d: the in-budget contaminated-baseline run produced no PERFORMED verdict, so its silence proves nothing. Output: $PP_OUT"
fi
PP_ENV=()

# ---------------------------------------------------------------------------
# P9 — the pins the rewrite must not move. X1/X2 and the exact-boundary Y rows are re-read
#      here rather than trusted, because per-path extraction changes the very number the
#      boundary is measured against.
# ---------------------------------------------------------------------------
PP_OUT="$(pp_run "$PP_BIG" --base main --no-log)"
if printf '%s\n' "$PP_OUT" | grep -E "^## Codex Review Scope: TRUNCATED" | grep -q "INCOMPLETE"; then
    pass "P9[X1]: an over-cap diff still announces TRUNCATED in the pinned INCOMPLETE wording"
else
    fail "P9[X1]: the pinned TRUNCATED/INCOMPLETE wording is gone. Output: $PP_OUT"
fi
PP_OUT="$(pp_run "$REPO" --base main --no-log)"
if pp_has "$PP_OUT" "^## Codex Review Scope: TRUNCATED"; then
    fail "P9[X2]: a small diff was reported TRUNCATED. Output: $PP_OUT"
else
    pass "P9[X2]: a small diff still carries no TRUNCATED line"
fi

if [ -z "${Y_AT_REPO:-}" ] || [ -z "${Y_OVER_REPO:-}" ]; then
    fail "P9[Y1/Y2]: the exact 5000/5001-line fixtures were not built by base-state-scope.sh, so the boundary pins cannot be re-checked"
else
    PP_OUT="$(pp_run "$Y_AT_REPO" --base main --no-log)"
    if pp_has "$PP_OUT" "^## Codex Review Scope: TRUNCATED"; then
        fail "P9[Y1]: a diff of exactly 5000 lines is still announced TRUNCATED. Output: $PP_OUT"
    elif pp_has "$PP_OUT" "^## Codex Review: "; then
        pass "P9[Y1]: a diff of exactly 5000 lines is reviewed whole, and the run produced a verdict"
    else
        fail "P9[Y1]: the at-the-cap run produced no verdict, so its silence proves nothing. Output: $PP_OUT"
    fi

    PP_OUT="$(pp_run "$Y_OVER_REPO" --base main --no-log)"
    if printf '%s\n' "$PP_OUT" | grep -E "^## Codex Review Scope: TRUNCATED" | grep -q "INCOMPLETE"; then
        pass "P9[Y2]: one line past the cap is still announced TRUNCATED and INCOMPLETE"
    else
        fail "P9[Y2]: 5001 lines was not announced as an incomplete truncated review. Output: $PP_OUT"
    fi
    if [ ! -f "$PP_CAPTURE" ]; then
        fail "P9[Y7]: no prompt was captured for the truncated run"
    else
        pp_t="$(grep -n -i -m1 -E "truncat|incomplete" "$PP_CAPTURE" | cut -d: -f1 || true)"
        pp_p="$(grep -n -m1 "authored by Claude" "$PP_CAPTURE" | cut -d: -f1 || true)"
        if [ -z "$pp_t" ] || [ -z "$pp_p" ]; then
            fail "P9[Y7]: the truncation notice ($pp_t) or the preamble ($pp_p) is missing from the prompt"
        elif [ "$pp_t" -lt "$pp_p" ]; then
            pass "P9[Y7]: the truncation notice still precedes the adversarial preamble in the prompt"
        else
            fail "P9[Y7]: the truncation notice at line $pp_t now follows the preamble at line $pp_p"
        fi
    fi
fi

# P10 onwards live in sourced parts: this file is at the 500-line hard split limit, and they
# reuse every helper and fixture above. Order is load-bearing only in that helpers.sh must
# already be sourced, which it is.
# shellcheck source=./path-priority/exclusion-and-cross-reference.sh
. "$AGENTS_ROOT/tests/feature-review-code-codex/path-priority/exclusion-and-cross-reference.sh"
# shellcheck source=./path-priority/budget-and-breakdown.sh
. "$AGENTS_ROOT/tests/feature-review-code-codex/path-priority/budget-and-breakdown.sh"
# shellcheck source=./path-priority/config-threshold.sh
. "$AGENTS_ROOT/tests/feature-review-code-codex/path-priority/config-threshold.sh"
# shellcheck source=./path-priority/path-edges-and-security.sh
. "$AGENTS_ROOT/tests/feature-review-code-codex/path-priority/path-edges-and-security.sh"
# shellcheck source=./path-priority/failure-and-leakage.sh
. "$AGENTS_ROOT/tests/feature-review-code-codex/path-priority/failure-and-leakage.sh"
# shellcheck source=./path-priority/concerns-file-parsing.sh
. "$AGENTS_ROOT/tests/feature-review-code-codex/path-priority/concerns-file-parsing.sh"
