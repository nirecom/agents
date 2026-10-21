# Part of tests/bin/feature-review-code-codex/path-priority.sh (sourced, not standalone).
# Tests: bin/review-code-codex, bin/resolve-merge-base.sh, bin/run-codex-review-loop, skills/review-code-security/scripts/run-quality-gates.sh
# Tags: codex, review, exclusion, stop-at-first-skip, cross-reference, path-encoding, scope:issue-specific, pwsh-not-required, TL2, working-tree, merge-base, priority
# lang-check: ignore — P15 fixture uses a non-ASCII filename intentionally, to test that git's octal-escaping of such names doesn't drop them from the priority set.
# P10-P16 (#1976 / #1750): WHICH paths are judged, not how many lines fit. P17-P19 (E24 redefinition, origin #1702): merge-base anchoring, four-kind adoption order, degraded-state untracked withholding with a committed diff. Split out of path-priority.sh at the 500-line hard limit; fixtures/helpers/shared vars come from path-priority/helpers.sh, path-priority.sh, and the suite entrypoint respectively.
# TL3 gap: real codex CLI arg/stdin handling and live model context limits are untested; P8/P12 stub resolve-merge-base.sh so `warn` is an asserted input; P15's non-ASCII path encoding is only exercised as this runner's own filesystem happens to encode it. Mitigation: WORKFLOW_USER_VERIFIED preflight, category merge-base-suspect.

# P10 — a path can be in the committed range AND still carry a staged edit on top. The review
#       target is the working tree vs merge-base (E24 redefinition), so the staged edit must be
#       in the body and no EXCLUDED line is printed. Small enough that nothing truncates.
PP_R10="$(pp_new_repo pp-p10)"
pp_gen "$PP_R10/mixed.txt" 10 "pp-p10-committed"
git -C "$PP_R10" add mixed.txt
git -C "$PP_R10" commit -q -m "committed change to mixed.txt"
echo "pp-p10-staged-on-top" >> "$PP_R10/mixed.txt"
git -C "$PP_R10" add mixed.txt

PP_ENV=(CODEX_REVIEW_MAX_DIFF_LINES=5000)
PP_OUT="$(pp_run "$PP_R10" --base main --no-log)"
PP_ENV=()
if [ ! -s "$PP_CAPTURE" ]; then
    fail "P10-no-caveat: no prompt was captured, so the absence of an exclusion caveat proves nothing"
elif grep -qF -e "were excluded from this review" -e "EXCLUDED SCOPE" "$PP_CAPTURE"; then
    fail "P10-no-caveat: the prompt still carries an exclusion SCOPE CAVEAT although nothing is excluded"
else
    pass "P10-no-caveat: the prompt carries no exclusion SCOPE CAVEAT"
fi
if pp_has "$PP_OUT" "^## Codex Review Scope: TRUNCATED"; then
    fail "P10: the fixture truncated, so a missing staged edit here could be the budget rather than the target. Output: $PP_OUT"
elif pp_has "$PP_OUT" "^## Codex Review Scope: EXCLUDED"; then
    fail "P10: an EXCLUDED line was printed although the working tree is the review target. Output: $PP_OUT"
elif pp_diff_body "$PP_CAPTURE" | grep -q "pp-p10-staged-on-top"; then
    pass "P10: the staged edit on top of a committed path is in the reviewed body, and no EXCLUDED line is printed"
else
    fail "P10: the staged edit on top of mixed.txt is missing from the reviewed body. Output: $PP_OUT"
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

pp_10b_staged="$(pp_diff_body "$PP_CAPTURE" | grep -c "pp-p10b-staged-on-top" || true)"
if pp_has "$PP_OUT" "^## Codex Review Scope: EXCLUDED"; then
    fail "P10b-no-excluded: an EXCLUDED line was printed although the working tree is the review target. Output: $PP_OUT"
elif [ "$pp_10b_staged" = "1" ]; then
    pass "P10b-no-excluded: no EXCLUDED line, and mixed.txt's staged-on-top content appears exactly once in the body"
else
    fail "P10b-no-excluded: mixed.txt's staged-on-top content appears $pp_10b_staged time(s) in the body (want exactly 1). Output: $PP_OUT"
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
# --base-state RESOLVED: the chunks are untracked, and UNKNOWN withholds untracked content (H1).
PP_OUT="$(pp_run "$PP_R11" --base main --base-state RESOLVED --no-log)"

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

# P12/P13 — two independent readers of one warn value: run-quality-gates.sh prints
#       `## merge-base: NOTE`, and review-code-codex — reached since #2276 through
#       `run-codex-review-loop --format security-code` rather than from the gate script —
#       decides PRIORITY-UNTRUSTED. If they can disagree, the reader is told two different
#       things about one baseline. P13 keeps the ordering claim inside the reviewer's own
#       report, where both lines still live: a caveat after the finding reads as an
#       afterthought.
PP_GATE_DIR="$TMPDIR_BASE/pp-gates-agents"
# run-codex-review-loop and run-quality-gates.sh resolve their ENTIRE toolchain — the reviewer,
# build-codex-context, the ledger CLI, the merge-base resolver, and every library each of them
# sources — from the script checkout they themselves live in. A curated subset always
# leaves one more dependency missing (the loop dies at a pre-flight `source` or a tool lookup
# before review-code-codex is ever reached, and P12/P13 see an empty report), so the fixture
# is a wholesale fake script checkout and both entrypoints are launched from inside it. The
# resolver stub written per-iteration below then overlays bin/resolve-merge-base.sh on top of
# this copy to drive the merge-base warn value.
mkdir -p "$PP_GATE_DIR/rules"
script_checkout_fixture_copy "$PP_GATE_DIR"
# run-codex-review-loop pre-flight requires rules/core-principles.md in its script checkout as
# mandatory context (bin/run-codex-review-loop:39-40); build-codex-context reads it too.
cp "$AGENTS_ROOT/rules/core-principles.md" "$PP_GATE_DIR/rules/core-principles.md"
PP_GATES="$PP_GATE_DIR/skills/review-code-security/scripts/run-quality-gates.sh"
PP_SECLOOP="$PP_GATE_DIR/bin/run-codex-review-loop"
PP_SECLOOP_SEQ=0

pp_run_gates() { # <repo> ; prints the combined gate-runner output
    (cd "$1" && _timeout env PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" \
        bash "$PP_GATES" 2>/dev/null) || true
}

pp_run_secloop() { # <repo> ; prints the security-code loop's reviewer report
    PP_SECLOOP_SEQ=$((PP_SECLOOP_SEQ + 1))
    local plans="$TMPDIR_BASE/pp-secloop-plans-$PP_SECLOOP_SEQ"
    local tradeoffs="$TMPDIR_BASE/pp-secloop-tradeoffs.md"
    mkdir -p "$plans"
    printf 'none\n' > "$tradeoffs"
    (cd "$1" && _timeout env PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" \
        bash "$PP_SECLOOP" --format security-code \
        --session-id "ppsec$PP_SECLOOP_SEQ" --plans-dir "$plans" \
        --cap 2 --max-extensions 1 --extensions-used 0 \
        --accepted-tradeoffs "$tradeoffs" --repo-root "$1" 2>/dev/null) || true
}

PP_REVIEW_OUT_WARN=""
for pp_warn in post-session-head none; do
    pp_write_resolver_stub "$PP_GATE_DIR" "$pp_warn"
    pp_gate_out="$(pp_run_gates "$PP_BIG")"
    pp_review_out="$(pp_run_secloop "$PP_BIG")"
    [ "$pp_warn" = "post-session-head" ] && PP_REVIEW_OUT_WARN="$pp_review_out"
    # An agreement of two silences is not agreement: if the loop never reached the reviewer,
    # both readers report "no" by default and P12 would pass on a row that proves nothing.
    if ! pp_has "$pp_review_out" "^## Codex Review: PERFORMED"; then
        fail "P12[warn=$pp_warn]: the codex review was not PERFORMED, so this row cannot prove NOTE/PRIORITY-UNTRUSTED agreement. Output: $pp_review_out"
        continue
    fi
    # The counterpart of the move: the gate must not be a second reviewer call site.
    if pp_has "$pp_gate_out" "^## Codex Review: "; then
        fail "P12[warn=$pp_warn]: run-quality-gates.sh still runs a codex review of its own, so the diff is reviewed twice. Output: $pp_gate_out"
        continue
    fi
    pp_note=no; pp_untrusted=no
    pp_has "$pp_gate_out" "^## merge-base: NOTE" && pp_note=yes
    pp_has "$pp_review_out" "^## Codex Review Scope: PRIORITY-UNTRUSTED" && pp_untrusted=yes
    if [ "$pp_note" = "$pp_untrusted" ]; then
        pass "P12[warn=$pp_warn]: the gate runner's NOTE ($pp_note) and review-code-codex's PRIORITY-UNTRUSTED ($pp_untrusted) agree about one baseline"
    else
        fail "P12[warn=$pp_warn]: the two independent readers of warn=$pp_warn disagree — NOTE=$pp_note, PRIORITY-UNTRUSTED=$pp_untrusted. Gate: $pp_gate_out Review: $pp_review_out"
    fi
done

pp_unt_line="$(printf '%s\n' "$PP_REVIEW_OUT_WARN" | grep -n -m1 "^## Codex Review Scope: PRIORITY-UNTRUSTED" | cut -d: -f1 || true)"
pp_verdict_line="$(printf '%s\n' "$PP_REVIEW_OUT_WARN" | grep -n -m1 "^## Codex Review: " | cut -d: -f1 || true)"
if [ -z "$pp_unt_line" ] || [ -z "$pp_verdict_line" ]; then
    fail "P13: the reviewer report is missing the PRIORITY-UNTRUSTED line ($pp_unt_line) or the verdict header ($pp_verdict_line), so their order cannot be asserted"
elif [ "$pp_unt_line" -lt "$pp_verdict_line" ]; then
    pass "P13: the baseline caveat precedes the verdict header it qualifies"
else
    fail "P13: PRIORITY-UNTRUSTED is at line $pp_unt_line, after the verdict header at line $pp_verdict_line"
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
pp_exec "$PP_R14A" --base main --base-state RECORDED --no-log  # trusted state: only then may SKIPPED claim "no untracked files"
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
    # --base-state RESOLVED: both files are untracked, and UNKNOWN withholds their content (H1).
    PP_OUT="$(pp_run "$PP_R15" --base main --base-state RESOLVED --no-log)"
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

# ---------------------------------------------------------------------------
# P17 — committed paths diff from merge-base(BASE, HEAD) to the working tree, never from BASE's
#       tip. BASE advances past the branch point with a new file AND a hunk in a file the branch
#       also edits; diffing from BASE's tip would surface both as reverse changes the session
#       never made. The branch's committed hunk and a staged edit on top of it must be present.
# ---------------------------------------------------------------------------
PP_R17="$(pp_new_base_repo pp-p17)"
pp_gen "$PP_R17/shared.txt" 30 "pp-p17-shared"
git -C "$PP_R17" add shared.txt
git -C "$PP_R17" commit -q -m "seed shared.txt at the branch point"
git -C "$PP_R17" checkout -q -b feature-pp-p17
echo "pp-p17-branch-hunk" >> "$PP_R17/shared.txt"
git -C "$PP_R17" commit -q -am "branch edits the tail of shared.txt"
git -C "$PP_R17" checkout -q main
{ echo "pp-p17-base-hunk"; tail -n +2 "$PP_R17/shared.txt"; } > "$PP_R17/shared.tmp"
mv "$PP_R17/shared.tmp" "$PP_R17/shared.txt"
pp_gen "$PP_R17/base-only.txt" 5 "pp-p17-base-only"
git -C "$PP_R17" add shared.txt base-only.txt
git -C "$PP_R17" commit -q -m "base advances: head hunk in shared.txt plus a base-only file"
git -C "$PP_R17" checkout -q feature-pp-p17
echo "pp-p17-staged-on-top" >> "$PP_R17/shared.txt"
git -C "$PP_R17" add shared.txt

PP_ENV=(CODEX_REVIEW_MAX_DIFF_LINES=5000)
PP_OUT="$(pp_run "$PP_R17" --base main --base-state RECORDED --no-log)"
PP_ENV=()
pp_17_body="$(pp_diff_body "$PP_CAPTURE")"
if [ -z "$pp_17_body" ]; then
    fail "P17: no reviewed body was captured, so merge-base anchoring cannot be asserted. Output: $PP_OUT"
else
    if pp_has "$pp_17_body" "pp-p17-base-hunk" || pp_has "$pp_17_body" "pp-p17-base-only"; then
        fail "P17-base-only: a change made only on BASE after the branch point reached the body — committed paths were diffed from BASE's tip, not merge-base"
    else
        pass "P17-base-only: neither the base-only file nor the base-only hunk in the shared file reaches the body"
    fi
    if pp_has "$pp_17_body" "^+pp-p17-branch-hunk"; then
        pass "P17-branch: the branch's own committed hunk is in the body"
    else
        fail "P17-branch: the branch's committed hunk is missing from the body. Output: $PP_OUT"
    fi
    if pp_has "$pp_17_body" "^+pp-p17-staged-on-top"; then
        pass "P17-staged: the staged edit on top of the committed path is in the body"
    else
        fail "P17-staged: the staged edit on top of shared.txt is missing from the body. Output: $PP_OUT"
    fi
fi

# ---------------------------------------------------------------------------
# P18 — adoption order across the four kinds of path: committed paths still being edited, then
#       uncommitted-only, then untracked-only, then the remaining committed paths. File names
#       sort in the REVERSE of that order, so git's own ordering cannot satisfy the row.
# ---------------------------------------------------------------------------
PP_R18="$(pp_new_base_repo pp-p18)"
pp_gen "$PP_R18/c-unc.txt" 5 "pp-p18-unc-base"
git -C "$PP_R18" add c-unc.txt
git -C "$PP_R18" commit -q -m "seed the file the branch edits without committing"
git -C "$PP_R18" checkout -q -b feature-pp-p18
pp_gen "$PP_R18/a-rest.txt" 5 "pp-p18-rest"
pp_gen "$PP_R18/d-edited.txt" 5 "pp-p18-edited"
git -C "$PP_R18" add a-rest.txt d-edited.txt
git -C "$PP_R18" commit -q -m "two committed paths"
echo "pp-p18-edited-on-top" >> "$PP_R18/d-edited.txt"
echo "pp-p18-unc-edit" >> "$PP_R18/c-unc.txt"
pp_gen "$PP_R18/b-untracked.txt" 5 "pp-p18-untracked"

PP_ENV=(CODEX_REVIEW_MAX_DIFF_LINES=5000)
PP_OUT="$(pp_run "$PP_R18" --base main --base-state RECORDED --no-log)"
PP_ENV=()
pp_18_order=""
for pp_18_p in d-edited.txt c-unc.txt b-untracked.txt a-rest.txt; do
    pp_18_n="$(pp_diff_body "$PP_CAPTURE" | grep -n -m1 "^diff --git a/$pp_18_p " | cut -d: -f1 || true)"
    pp_18_order="$pp_18_order ${pp_18_n:-missing}"
done
pp_18_prev=0
pp_18_ok=1
for pp_18_n in $pp_18_order; do
    if [ "$pp_18_n" = "missing" ] || [ "$pp_18_n" -le "$pp_18_prev" ]; then pp_18_ok=0; break; fi
    pp_18_prev="$pp_18_n"
done
if [ "$pp_18_ok" = "1" ]; then
    pass "P18: chunks are adopted committed-still-edited, uncommitted-only, untracked-only, remaining-committed (body lines:$pp_18_order)"
else
    fail "P18: chunk order is wrong or a chunk is missing — want d-edited, c-unc, b-untracked, a-rest; body lines:$pp_18_order. Output: $PP_OUT"
fi

# ---------------------------------------------------------------------------
# P19 — a non-empty committed diff does not lift degraded-state untracked withholding: under
#       SUSPECT/FALLBACK/UNRESOLVED the untracked file stays out of prompt and report, while the
#       committed change is still reviewed. RECORDED is the symmetric verdict: the same fixture
#       sends the untracked content, so the withholding is targeted, not blanket.
# ---------------------------------------------------------------------------
PP_R19="$(pp_new_repo pp-p19)"
pp_gen "$PP_R19/committed.txt" 5 "pp-p19-committed"
git -C "$PP_R19" add committed.txt
git -C "$PP_R19" commit -q -m "committed change"
echo "pp-p19-tracked-unstaged-append" >> "$PP_R19/committed.txt"
# Named plain-*, not secret-*: a credential-shaped name is withheld under every state (H2), which
# would make the RECORDED row below fail for a reason unrelated to the base state.
pp_gen "$PP_R19/plain-untracked.txt" 5 "pp-p19-untracked-secret"

PP_ENV=(CODEX_REVIEW_MAX_DIFF_LINES=5000)
PP_19_LOG_DIR="$TMPDIR_BASE/.claude/projects/codex-review"
for pp_state in SUSPECT FALLBACK UNRESOLVED; do
    # Logging stays on so the withheld marker can be looked for in stderr and the JSONL log too.
    rm -rf "$PP_19_LOG_DIR"
    pp_exec "$PP_R19" --base main --base-state "$pp_state"
    PP_OUT="$PP_OUT_TEXT"
    if [ ! -d "$PP_19_LOG_DIR" ] || [ -z "$(ls -A "$PP_19_LOG_DIR" 2>/dev/null)" ]; then
        fail "P19-channels[$pp_state]: no log file was written, so a clean JSONL log proves nothing"
    elif pp_has_fixed "$PP_ERR_TEXT" "pp-p19-untracked-secret" || grep -rqF "pp-p19-untracked-secret" "$PP_19_LOG_DIR" 2>/dev/null; then
        fail "P19-channels[$pp_state]: the withheld untracked content leaked into stderr or the JSONL log"
    else
        pass "P19-channels[$pp_state]: the withheld untracked content is in neither stderr nor the JSONL log"
    fi
    if pp_diff_body "$PP_CAPTURE" | grep -q "^+pp-p19-tracked-unstaged-append"; then
        pass "P19-tracked[$pp_state]: the tracked unstaged append is reviewed under a degraded base state — only untracked files are withheld"
    else
        fail "P19-tracked[$pp_state]: the tracked unstaged append to committed.txt is missing from the body under a degraded base state. Output: $PP_OUT"
    fi
    if [ -f "$PP_CAPTURE" ] && grep -q "pp-p19-untracked-secret" "$PP_CAPTURE"; then
        fail "P19[$pp_state]: untracked raw content was sent to the model under a degraded base state despite a committed diff"
    elif pp_has "$PP_OUT" "plain-untracked.txt"; then
        fail "P19[$pp_state]: the untracked path was named in the report while degraded. Output: $PP_OUT"
    elif ! pp_diff_body "$PP_CAPTURE" | grep -q "pp-p19-committed"; then
        fail "P19[$pp_state]: the committed change never reached the body, so the withholding proves nothing. Output: $PP_OUT"
    else
        pass "P19[$pp_state]: with a committed diff, the untracked file is still withheld from prompt and report while the committed change is reviewed"
    fi
done
PP_OUT="$(pp_run "$PP_R19" --base main --base-state RECORDED --no-log)"
if [ -f "$PP_CAPTURE" ] && grep -q "pp-p19-untracked-secret" "$PP_CAPTURE"; then
    pass "P19[RECORDED]: a trustworthy base state reviews the untracked file alongside the committed diff"
else
    fail "P19[RECORDED]: the untracked file was withheld although the base state is trustworthy. Output: $PP_OUT"
fi
PP_ENV=()
