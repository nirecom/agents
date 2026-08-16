# Part of tests/feature-review-code-codex/path-priority.sh (sourced, not standalone).
# Tests: bin/review-code-codex, bin/resolve-merge-base.sh, skills/review-code-security/scripts/run-quality-gates.sh
# Tags: codex, review, exclusion, stop-at-first-skip, cross-reference, path-encoding, scope:issue-specific, pwsh-not-required, TL2
# lang-check: ignore — P15 fixture uses a non-ASCII filename intentionally, to test that git's octal-escaping of such names doesn't drop them from the priority set.
# P10-P16 (#1976 / #1750): WHICH paths are judged, not how many lines fit. Split out of path-priority.sh at the 500-line hard limit; fixtures/helpers/shared vars come from path-priority/helpers.sh, path-priority.sh, and the suite entrypoint respectively.
# TL3 gap: real codex CLI arg/stdin handling and live model context limits are untested; P8/P12 stub resolve-merge-base.sh so `warn` is an asserted input; P15's non-ASCII path encoding is only exercised as this runner's own filesystem happens to encode it. Mitigation: WORKFLOW_USER_VERIFIED preflight, category merge-base-suspect.

# ---------------------------------------------------------------------------
# P10 — a path can be in the committed range AND still carry changes the committed range
#       cannot show. Judging exclusion by "the path is absent from the body" gets this case
#       exactly backwards: the path IS in the body, and the staged edit on top of it is the
#       part nobody reviewed. Small enough that nothing is truncated, so the EXCLUDED report
#       has to stand on its own rather than riding along with TRUNCATED.
# ---------------------------------------------------------------------------
PP_R10="$(pp_new_repo pp-p10)"
pp_gen "$PP_R10/mixed.txt" 10 "pp-p10-committed"
git -C "$PP_R10" add mixed.txt
git -C "$PP_R10" commit -q -m "committed change to mixed.txt"
echo "pp-p10-staged-on-top" >> "$PP_R10/mixed.txt"
git -C "$PP_R10" add mixed.txt

PP_OUT="$(pp_run "$PP_R10" --base main --no-log)"
if pp_has "$PP_OUT" "^## Codex Review Scope: TRUNCATED"; then
    fail "P10: the fixture truncated, so an EXCLUDED line here would not prove it fires independently. Output: $PP_OUT"
elif printf '%s\n' "$PP_OUT" | grep -E "^## Codex Review Scope: EXCLUDED" | grep -q "mixed.txt"; then
    pass "P10: a path that is both in the committed body and separately staged is reported EXCLUDED"
else
    fail "P10: no EXCLUDED line naming mixed.txt — exclusion is being judged by absence from the body rather than per-path. Output: $PP_OUT"
fi

# ---------------------------------------------------------------------------
# P10b — the same dual membership, now asked as an arithmetic question. The changed-path set
#        is a UNION of three sources, and mixed.txt is a member of two of them. If the union
#        is built by concatenation rather than by deduplication, nothing visibly breaks: the
#        path is simply counted twice, its chunk is measured twice against the budget, and a
#        file at the far end of the queue is dropped to pay for a duplicate. The report stays
#        internally consistent while under-reviewing, which is why presence alone cannot catch
#        this and each of the three counts below is asserted separately.
# ---------------------------------------------------------------------------
PP_R10B="$(pp_new_repo pp-p10b)"
pp_gen "$PP_R10B/mixed.txt" 100 "pp-p10b-mixed"
pp_gen "$PP_R10B/other1.txt" 10 "pp-p10b-other1"
pp_gen "$PP_R10B/other2.txt" 10 "pp-p10b-other2"
pp_gen "$PP_R10B/zz-huge.txt" 6000 "pp-p10b-huge"
git -C "$PP_R10B" add mixed.txt other1.txt other2.txt zz-huge.txt
git -C "$PP_R10B" commit -q -m "four committed files"
# The second membership: mixed.txt is now in the committed set AND the staged set.
echo "pp-p10b-staged-on-top" >> "$PP_R10B/mixed.txt"
git -C "$PP_R10B" add mixed.txt

PP_ENV=(CODEX_REVIEW_MAX_DIFF_LINES=300)
PP_OUT="$(pp_run "$PP_R10B" --base main --no-log)"
PP_ENV=()

if printf '%s\n' "$PP_OUT" | grep -E "^## Codex Review Scope: TRUNCATED" | grep -q "3/4 changed files"; then
    pass "P10b-count: the dual-membership path is counted once — the headline reconciles as 3/4, not 3/5"
else
    fail "P10b-count: the changed-file total does not read 3/4, so the path in two sets was counted twice. Output: $PP_OUT"
fi

pp_10b_listed="$(pp_scope_paths "$PP_OUT" Reviewed | grep -cxF "mixed.txt" || true)"
if [ "$pp_10b_listed" = "1" ]; then
    pass "P10b-listed: it appears exactly once in the Reviewed breakdown"
else
    fail "P10b-listed: mixed.txt appears $pp_10b_listed time(s) on the Reviewed line. Output: $PP_OUT"
fi

pp_10b_chunks=0
if [ -f "$PP_CAPTURE" ]; then
    pp_10b_chunks="$(pp_diff_body "$PP_CAPTURE" | grep -c "^diff --git a/mixed.txt" || true)"
fi
if [ "$pp_10b_chunks" = "1" ]; then
    pass "P10b-budget: and its chunk was adopted exactly once, so duplicate membership cannot spend the budget twice"
else
    fail "P10b-budget: mixed.txt's chunk appears $pp_10b_chunks time(s) in the reviewed body"
fi

pp_10b_excl_block="$(printf '%s\n' "$PP_OUT" | grep -E "^## Codex Review Scope: EXCLUDED" -A 20 || true)"
pp_10b_excl="$(printf '%s\n' "$pp_10b_excl_block" | grep -oF "mixed.txt" | wc -l | tr -d '[:space:]' || true)"
if [ "$pp_10b_excl" = "1" ]; then
    pass "P10b-excluded: the EXCLUDED disclosure names it once rather than once per set it belongs to"
else
    fail "P10b-excluded: mixed.txt is named $pp_10b_excl time(s) in the EXCLUDED disclosure. Output: $PP_OUT"
fi

# ---------------------------------------------------------------------------
# P11 — stop-at-first-skip, and the tradeoff it makes on purpose. Greedy first-fit would
#       leapfrog the oversized chunk and adopt the small one behind it, which reads as a
#       review that covered "the small files" while the large change it skipped is the one
#       that mattered. Adoption therefore stops dead at the first chunk that does not fit,
#       and the leftover budget is deliberately left unspent — asserted here so the
#       unspent budget is recorded as a decision, not discovered later as a bug.
# ---------------------------------------------------------------------------
PP_R11="$(pp_new_repo pp-p11)"
pp_gen "$PP_R11/a-medium.txt" 100 "pp-p11-a-marker"
pp_gen "$PP_R11/b-large.txt" 300 "pp-p11-b-marker"
pp_gen "$PP_R11/c-small.txt" 5 "pp-p11-c-marker"

PP_A_LINES="$(pp_untracked_chunk_lines "$PP_R11" a-medium.txt)"
PP_C_LINES="$(pp_untracked_chunk_lines "$PP_R11" c-small.txt)"
PP_BUDGET=200
PP_LEFTOVER=$((PP_BUDGET - PP_A_LINES))

PP_ENV=(CODEX_REVIEW_MAX_DIFF_LINES="$PP_BUDGET")
PP_OUT="$(pp_run "$PP_R11" --base main --no-log)"

if [ "$PP_LEFTOVER" -le 0 ] || [ "$PP_C_LINES" -gt "$PP_LEFTOVER" ]; then
    # The premise: without room left for C, "C was not adopted" would be ordinary budgeting
    # and would say nothing about stop-at-first-skip.
    fail "P11: fixture premise broken — chunk A is $PP_A_LINES lines of a $PP_BUDGET budget, leaving $PP_LEFTOVER for a $PP_C_LINES-line chunk C"
else
    pass "P11-premise: chunk C ($PP_C_LINES lines) would fit the $PP_LEFTOVER lines left after chunk A, so skipping it is a choice"
    if [ -f "$PP_CAPTURE" ] && grep -q "pp-p11-a-marker" "$PP_CAPTURE"; then
        pass "P11: the first chunk, which fits, is adopted"
    else
        fail "P11: the first chunk was not adopted although it fits the budget. Output: $PP_OUT"
    fi
    if [ -f "$PP_CAPTURE" ] && grep -q "pp-p11-c-marker" "$PP_CAPTURE"; then
        fail "P11: adoption leapfrogged the oversized chunk B and took chunk C — this is greedy first-fit, not stop-at-first-skip"
    else
        pass "P11: adoption stops at the first chunk that does not fit; the later small chunk is not leapfrogged"
    fi
    if printf '%s\n' "$PP_OUT" | grep -E "^Dropped \(" | grep -q "c-small.txt"; then
        pass "P11: and the chunk that was passed over is reported dropped rather than left unmentioned"
    else
        fail "P11: c-small.txt is not named on a Dropped line. Output: $PP_OUT"
    fi
fi
PP_ENV=()

# ---------------------------------------------------------------------------
# P12/P13 — two independent readers of the same warn value. run-quality-gates.sh asks the
#       resolver and prints `## merge-base: NOTE`; review-code-codex asks it again for its own
#       PRIORITY-UNTRUSTED decision. Two call sites, one fact: if they can disagree, the
#       combined report tells the reader two different things about one baseline. P13 adds
#       the ordering, because a caveat that arrives after the finding it qualifies is read
#       as an afterthought.
# ---------------------------------------------------------------------------
PP_GATE_DIR="$TMPDIR_BASE/pp-gates-agents"
mkdir -p "$PP_GATE_DIR/bin/lib"
cp "$AGENTS_ROOT/bin/review-code-codex" "$PP_GATE_DIR/bin/review-code-codex"
cp "$AGENTS_ROOT/bin/lib/codex-core.sh" "$PP_GATE_DIR/bin/lib/codex-core.sh"
PP_GATES="$AGENTS_ROOT/skills/review-code-security/scripts/run-quality-gates.sh"

pp_run_gates() { # <repo> ; prints the combined gate-runner output
    (cd "$1" && _timeout env PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" \
        AGENTS_CONFIG_DIR="$PP_GATE_DIR" bash "$PP_GATES" 2>/dev/null) || true
}

PP_GATE_OUT_WARN=""
for pp_warn in post-session-head none; do
    pp_write_resolver_stub "$PP_GATE_DIR" "$pp_warn"
    pp_out="$(pp_run_gates "$PP_BIG")"
    [ "$pp_warn" = "post-session-head" ] && PP_GATE_OUT_WARN="$pp_out"
    pp_note=no; pp_untrusted=no
    pp_has "$pp_out" "^## merge-base: NOTE" && pp_note=yes
    pp_has "$pp_out" "^## Codex Review Scope: PRIORITY-UNTRUSTED" && pp_untrusted=yes
    if [ "$pp_note" = "$pp_untrusted" ]; then
        pass "P12[warn=$pp_warn]: the gate runner's NOTE ($pp_note) and review-code-codex's PRIORITY-UNTRUSTED ($pp_untrusted) agree about one baseline"
    else
        fail "P12[warn=$pp_warn]: the two independent readers of warn=$pp_warn disagree — NOTE=$pp_note, PRIORITY-UNTRUSTED=$pp_untrusted. Output: $pp_out"
    fi
done

pp_note_line="$(printf '%s\n' "$PP_GATE_OUT_WARN" | grep -n -m1 "^## merge-base: NOTE" | cut -d: -f1 || true)"
pp_unt_line="$(printf '%s\n' "$PP_GATE_OUT_WARN" | grep -n -m1 "^## Codex Review Scope: PRIORITY-UNTRUSTED" | cut -d: -f1 || true)"
if [ -z "$pp_note_line" ] || [ -z "$pp_unt_line" ]; then
    fail "P13: the combined output is missing the NOTE line ($pp_note_line) or the PRIORITY-UNTRUSTED line ($pp_unt_line), so their order cannot be asserted"
elif [ "$pp_note_line" -lt "$pp_unt_line" ]; then
    pass "P13: the baseline NOTE precedes the PRIORITY-UNTRUSTED line it explains"
else
    fail "P13: the NOTE is at line $pp_note_line, after PRIORITY-UNTRUSTED at line $pp_unt_line"
fi

# ---------------------------------------------------------------------------
# P14 — the two settings that turn a cap into a review of nothing. `head -n 0` prints
#       nothing at all, and a negative cap is not a number head takes; both would produce an
#       empty prompt behind a PERFORMED verdict, which is the exact failure this whole file
#       exists to prevent.
# ---------------------------------------------------------------------------
for pp_bad in 0 -1; do
    PP_ENV=(CODEX_REVIEW_MAX_DIFF_LINES="$pp_bad")
    PP_OUT="$(pp_run "$PP_BIG" --base main --no-log)"
    if printf '%s\n' "$PP_OUT" | grep -E "^## Codex Review Scope: TRUNCATED" | grep -q "5000"; then
        pass "P14[cap=$pp_bad]: a non-positive cap falls back to the 5000 default"
    else
        fail "P14[cap=$pp_bad]: the cap was not reported as the 5000 default. Output: $PP_OUT"
    fi
    if [ -f "$PP_CAPTURE" ] && grep -q "^diff --git" "$PP_CAPTURE"; then
        pass "P14[cap=$pp_bad]: and the prompt still carries diff content"
    else
        fail "P14[cap=$pp_bad]: the prompt carries no diff content — a non-positive cap produced an empty review"
    fi
done
PP_ENV=()

# ---------------------------------------------------------------------------
# P14a (C1, #1976 review gap) — the empty-collection edge: a clean repo with no committed
#      diff, no uncommitted changes and no untracked files at all. Every P-row above starts
#      from a fixture that has SOMETHING to review; none of them prove the opposite end of
#      the range — that when there is truly nothing to send, the script says so, says it
#      exactly once, spends nothing on codex, and never prints a scope/breakdown line that
#      would imply a review happened over an empty set.
# ---------------------------------------------------------------------------
PP_R14A="$(pp_new_repo pp-p14a)"

PP_ENV=()
pp_exec "$PP_R14A" --base main --no-log
if [ "$PP_RC" -eq 0 ]; then
    pass "P14a: a clean repo with no diff at all still exits 0"
else
    fail "P14a: a clean repo with no diff exited $PP_RC instead of 0"
fi
if [ "$PP_OUT_TEXT" = "## Codex Review: SKIPPED — empty diff (no committed changes vs main, no uncommitted changes, no untracked files)" ]; then
    pass "P14a: the output is exactly the empty-diff SKIPPED verdict, nothing else"
else
    fail "P14a: the output was not exactly the empty-diff SKIPPED verdict. Output: $PP_OUT_TEXT"
fi
if [ -f "$PP_CAPTURE" ]; then
    fail "P14a: codex was invoked (a prompt was captured) for a diff that has nothing to review"
else
    pass "P14a: codex was never invoked — no prompt was captured"
fi
if printf '%s\n' "$PP_OUT_TEXT" | grep -qE "^## Codex Review Scope:|^Reviewed \(|^Dropped \("; then
    fail "P14a: a scope/breakdown claim line appeared for a review that never ran. Output: $PP_OUT_TEXT"
else
    pass "P14a: no scope or breakdown claim line appears alongside the empty-diff skip"
fi

# ---------------------------------------------------------------------------
# P15 — paths are not words. A name with a space splits in two under any line-based read of
#       a name list, and a non-ASCII name comes back from git octal-escaped and quoted unless
#       core.quotePath is off — either one silently drops a real file out of the priority set
#       while the report still claims to have listed everything.
# ---------------------------------------------------------------------------
PP_R15="$(pp_new_repo pp-p15)"
PP_UNI='日本語 ファイル.txt'
pp_gen "$PP_R15/$PP_UNI" 5 "pp-p15-uni-marker"
pp_gen "$PP_R15/zz-huge.txt" 6000 "pp-p15-huge-marker"

if [ ! -f "$PP_R15/$PP_UNI" ]; then
    fail "P15: the fixture path with a space and non-ASCII characters could not be created on this filesystem"
else
    PP_OUT="$(pp_run "$PP_R15" --base main --no-log)"
    if [ -f "$PP_CAPTURE" ] && grep -q "pp-p15-uni-marker" "$PP_CAPTURE"; then
        pass "P15: the content of a path with a space and non-ASCII characters is extracted into the prompt"
    else
        fail "P15: the awkward path's content is missing from the prompt — it was mis-split or never classified. Output: $PP_OUT"
    fi
    if printf '%s\n' "$PP_OUT" | grep -E "^(Reviewed|Dropped) \(" | grep -qF "$PP_UNI"; then
        pass "P15: and the breakdown names it verbatim"
    else
        fail "P15: no breakdown line names the awkward path verbatim. Output: $PP_OUT"
    fi
    if printf '%s\n' "$PP_OUT" | grep -q '\\3[0-7][0-7]'; then
        fail "P15: the report carries octal-escaped path bytes — core.quotePath was left on. Output: $PP_OUT"
    else
        pass "P15: no octal-escaped path bytes reach the report"
    fi
fi

# ---------------------------------------------------------------------------
# P16 — the resolver the two cross-reference call sites both consult. If it can answer the
#       same question twice with two different answers against an unchanged tree, P12's
#       agreement is coincidence. Both calls happen in this one process against one state.
# ---------------------------------------------------------------------------
PP_R16="$(pp_new_repo pp-p16)"
echo "an uncommitted edit" >> "$PP_R16/README.md"
PP_RESOLVER="$AGENTS_ROOT/bin/resolve-merge-base.sh"
PP_KV1="$( (cd "$PP_R16" && _timeout bash "$PP_RESOLVER" --format kv --no-fetch 2>/dev/null) || true )"
PP_KV2="$( (cd "$PP_R16" && _timeout bash "$PP_RESOLVER" --format kv --no-fetch 2>/dev/null) || true )"
if [ -z "$PP_KV1" ]; then
    fail "P16: the resolver produced no kv output at all, so idempotency cannot be asserted"
elif [ "$PP_KV1" = "$PP_KV2" ]; then
    pass "P16: two consecutive resolver calls against one unchanged tree return byte-identical kv output"
else
    fail "P16: the resolver answered differently on a second call against an unchanged tree. First: $PP_KV1 Second: $PP_KV2"
fi
