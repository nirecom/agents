# Part of tests/feature-review-code-codex.sh (sourced, not standalone).
# Tests: bin/review-code-codex
# Tags: codex, review, merge-base, base-state, truncation, boundary, prompt-order, scope:issue-specific, pwsh-not-required, TL2
#
# Y (#1638) — THE REST OF THE STATES, THE EXACT TRUNCATION BOUNDARY, AND WHERE THE WARNING SITS
# INSIDE THE PROMPT.
#
# X1-X6 pin one alarming state (SUSPECT), one trustworthy one (RESOLVED), the absent flag, an
# injected value, and the verdict line's integrity. Three things they cannot see:
#
#   THE OTHER STATES (Y3-Y5). FALLBACK, UNRESOLVED and RECORDED are not decoration: each says
#   something different to a reader deciding how much the review is worth. FALLBACK means the
#   range is `HEAD~1`, so the review covers one commit of a branch that may have twenty.
#   UNRESOLVED means there was no range at all and the review fell back to uncommitted changes.
#   RECORDED means the base is a recorded fact and the review is worth exactly what it says.
#   An implementation that special-cases `SUSPECT` satisfies X3 and X4 and then prints nothing
#   for FALLBACK or UNRESOLVED — the two states where the reader is most likely to be looking
#   at a review of almost nothing while the verdict says PERFORMED.
#
#   THE BOUNDARY (Y1-Y2). 6000 lines is over the cap and 2 lines are under it; neither can tell
#   `>` from `>=`. The consequence of the wrong operator is small but it is the wrong KIND of
#   small: a diff of exactly 5000 lines reviewed in full but announced as TRUNCATED teaches the
#   reader to ignore the line, and a diff of 5001 truncated silently is a review that omitted
#   a line nobody knows about. The fixtures below are built to an EXACT `git diff | wc -l`,
#   which is the count the script itself uses, and the construction is verified rather than
#   assumed — a fixture that missed by one would invert both rows.
#
#   WHERE THE WARNING SITS (Y6). This is the row that decides whether the caveat has any effect
#   at all. The scope warning must precede the adversarial preamble in the prompt, because the
#   preamble is what sets the model's task ("review this diff adversarially"). A caveat that
#   arrives after the instruction — appended at the end, or attached to the diff — is read as
#   part of the material rather than as a constraint on the job, and the model reviews the
#   truncated diff as if it were the whole change. Nothing on stdout can reveal this: the scope
#   LINE can be perfectly correct while the PROMPT carries the warning in the wrong place. Only
#   the captured prompt shows it.

Y_CAPTURE="$TMPDIR_BASE/captured-scope-prompt.txt"

# A mock codex that records the prompt it was handed. Written fresh here because the parent's
# mock is overwritten several times and the rows below must not depend on which one is current.
y_install_capturing_mock() {
    cat > "$MOCK_BIN/codex" <<MOCK_EOF
#!/usr/bin/env bash
cat > "$Y_CAPTURE"
echo "HIGH: Something looks risky."
exit 0
MOCK_EOF
    chmod +x "$MOCK_BIN/codex"
}

y_install_quiet_mock() {
    cat > "$MOCK_BIN/codex" <<'MOCK_EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "No findings."
exit 0
MOCK_EOF
    chmod +x "$MOCK_BIN/codex"
}

y_run() { # <repo> [args...] ; prints stdout
    local repo="$1"
    shift
    (cd "$repo" && PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" "$@" 2>/dev/null) || true
}

# A repository whose `git diff main...HEAD` is EXACTLY <target> lines by `wc -l` — the same
# measurement the script performs. The per-file diff overhead (the `diff --git`, mode, index,
# ---/+++ and @@ lines) is measured from a probe commit rather than hard-coded, because it
# varies with git version and config, and then the file is amended to the required length.
y_make_exact_repo() { # <name> <target-lines> ; prints the repo path, or "" on failure
    local name="$1" target="$2" repo probe overhead k actual
    repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config core.hooksPath "$repo/.git/no-such-hooks"
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config commit.gpgsign false
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
    git -C "$repo" checkout -q -b "feature-$name"

    awk 'BEGIN { for (i = 0; i < 100; i++) print "generated line " i }' > "$repo/exact.txt"
    git -C "$repo" add exact.txt
    git -C "$repo" commit -q -m "probe"
    probe="$(git -C "$repo" diff "main...HEAD" | wc -l | tr -d '[:space:]')"
    overhead=$((probe - 100))
    k=$((target - overhead))
    if [ "$k" -lt 1 ]; then printf '%s' ""; return 0; fi
    awk -v n="$k" 'BEGIN { for (i = 0; i < n; i++) print "generated line " i }' > "$repo/exact.txt"
    git -C "$repo" add exact.txt
    git -C "$repo" commit -q --amend -m "exact $target"
    actual="$(git -C "$repo" diff "main...HEAD" | wc -l | tr -d '[:space:]')"
    if [ "$actual" != "$target" ]; then printf '%s' ""; return 0; fi
    printf '%s' "$repo"
}

# --- Y1/Y2: the cap is 5000 lines. AT the cap is not over it; one line past it is.
y_install_quiet_mock
Y_AT_REPO="$(y_make_exact_repo exact-5000 5000)"
Y_OVER_REPO="$(y_make_exact_repo exact-5001 5001)"

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
