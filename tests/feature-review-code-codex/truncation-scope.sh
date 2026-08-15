# Part of tests/feature-review-code-codex.sh (sourced, not standalone).
# Tests: bin/review-code-codex
# Tags: codex, review, truncation, base-state, scope, verdict-family, scope:issue-specific, pwsh-not-required, TL2
# The X-series (#1638), moved verbatim out of the parent at the 500-line hard split limit. Reuses TMPDIR_BASE, REPO, MOCK_BIN, SCRIPT, _timeout, fail, pass from the parent; leaves BIG_REPO set for later parts.
# TL3 gap: codex is a shell mock, so a prompt correctly announced as truncated may still exceed the live model's context window, and the real CLI's arg/exit-code handling is unexercised; X rows pass --base-state directly rather than letting a real resolver derive it. Mitigation: WORKFLOW_USER_VERIFIED preflight, category merge-base-suspect.

# X (#1638) — `## Codex Review: PERFORMED` says a review ran, not that it saw the whole change.
#   1. TRUNCATION: the prompt is capped at MAX_DIFF_LINES; the dropped tail was only an stderr
#      warning while the verdict a reviewer reads still said PERFORMED — "nothing concerning"
#      on the first 5000 lines of a 280k-line diff is a finding about 2% of it.
#   2. AN UNTRUSTWORTHY RANGE: the diff was taken against a base someone else resolved; a wrong
#      base makes the review complete and correct about the wrong thing.
#   Both now get a line under the DISTINCT `## Codex Review Scope:` label rather than
#   `## Codex Review:` — X6 pins this separation, since callers parse the verdict label for
#   PERFORMED/SKIPPED/FAILED and a fourth value there would silently break them.

# A repository whose committed diff is comfortably past the cap, so truncation is real
# rather than simulated by an injected constant.
BIG_REPO="$TMPDIR_BASE/big-repo"
mkdir -p "$BIG_REPO"
git -C "$BIG_REPO" init -q
git -C "$BIG_REPO" config core.hooksPath "$BIG_REPO/.git/no-such-hooks"
git -C "$BIG_REPO" config user.email "test@example.com"
git -C "$BIG_REPO" config user.name "Test"
git -C "$BIG_REPO" config commit.gpgsign false
echo "init" > "$BIG_REPO/README.md"
git -C "$BIG_REPO" add README.md
git -C "$BIG_REPO" commit -q -m "initial"
git -C "$BIG_REPO" checkout -q -b feature-big
awk 'BEGIN { for (i = 0; i < 6000; i++) print "generated line " i }' > "$BIG_REPO/big.txt"
git -C "$BIG_REPO" add big.txt
git -C "$BIG_REPO" commit -q -m "big commit"

# The mock from case 4 is still on disk; make sure a PERFORMED verdict is what we get.
cat > "$MOCK_BIN/codex" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "Nothing concerning found."
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

# --- X1: a diff past the cap declares the truncation where the verdict is read.
X_OUT="$( (cd "$BIG_REPO" && PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" --base main --no-log 2>/dev/null) || true )"
if echo "$X_OUT" | grep -q "## Codex Review Scope: TRUNCATED"; then
    pass "X1: a diff past MAX_DIFF_LINES prints a TRUNCATED scope line on stdout"
else
    fail "X1: no '## Codex Review Scope: TRUNCATED' line. Output: $X_OUT"
fi
if echo "$X_OUT" | grep -q "INCOMPLETE"; then
    pass "X1-wording: and says the coverage is INCOMPLETE, not merely that truncation happened"
else
    fail "X1-wording: the truncation line does not say coverage is incomplete. Output: $X_OUT"
fi

# --- X2: the other half. A diff under the cap must carry no such line, or the line stops
#         meaning anything.
X_OUT="$( (cd "$REPO" && PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" --base main --no-log 2>/dev/null) || true )"
if echo "$X_OUT" | grep -q "## Codex Review Scope: TRUNCATED"; then
    fail "X2: a small diff was reported TRUNCATED. Output: $X_OUT"
else
    pass "X2: a diff under the cap carries no TRUNCATED line"
fi

# --- X3: an untrustworthy base is declared next to the verdict.
X_OUT="$( (cd "$REPO" && PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" --base main --base-state SUSPECT --no-log 2>/dev/null) || true )"
if echo "$X_OUT" | grep -q "## Codex Review Scope: BASE-SUSPECT"; then
    pass "X3: --base-state SUSPECT prints a BASE-SUSPECT scope line"
else
    fail "X3: no '## Codex Review Scope: BASE-SUSPECT' line. Output: $X_OUT"
fi

# --- X4: and a trustworthy base — or no state at all, which is every existing caller —
#         prints nothing. Without this row an unconditional line satisfies X3 forever and
#         every ordinary review grows a scary caveat it did not earn.
X_OUT="$( (cd "$REPO" && PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" --base main --base-state RESOLVED --no-log 2>/dev/null) || true )"
X_OUT2="$( (cd "$REPO" && PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" --base main --no-log 2>/dev/null) || true )"
if echo "$X_OUT" | grep -q "## Codex Review Scope: BASE-"; then
    fail "X4: --base-state RESOLVED still printed a BASE- caveat. Output: $X_OUT"
elif echo "$X_OUT2" | grep -q "## Codex Review Scope: BASE-"; then
    fail "X4: an invocation with no --base-state printed a BASE- caveat. Output: $X_OUT2"
else
    pass "X4: a trustworthy state, and the no-flag default, both print no BASE- caveat"
fi

# --- X5: the state is interpolated into a line that is printed, so an unvalidated value is
#         an injection point AND a way to fabricate a state that does not exist. It is
#         normalised, not echoed, and the run still exits 0 like every other path here.
X_RC=0
X_OUT="$( (cd "$REPO" && PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" --base main --base-state 'foo; touch /tmp/pwned-1638' --no-log 2>"$TMPDIR_BASE/x5err") || X_RC=$?; :)"
X5_ERR="$(cat "$TMPDIR_BASE/x5err" 2>/dev/null || true)"
if echo "$X_OUT" | grep -q "touch /tmp/pwned-1638"; then
    fail "X5: the raw --base-state value was echoed into stdout. Output: $X_OUT"
elif [ -e /tmp/pwned-1638 ]; then
    rm -f /tmp/pwned-1638
    fail "X5: the --base-state value was executed"
elif ! echo "$X_OUT" | grep -q "^## Codex Review: "; then
    # A usage error that aborts the run would satisfy "the value was not echoed" without
    # normalising anything. The contract is that the review still happens.
    fail "X5: the run produced no verdict — an invalid --base-state aborted it instead of being normalised. stdout: $X_OUT stderr: $X5_ERR"
elif echo "$X5_ERR" | grep -qi "base-state"; then
    pass "X5: an invalid --base-state is warned about, normalised, and never echoed — the review still runs"
else
    fail "X5: no warning about the invalid --base-state. stderr: $X5_ERR"
fi

# --- X6: the verdict family is untouched. `## Codex Review:` still carries exactly one of
#         PERFORMED/SKIPPED/FAILED, and the new lines live under a different label so a
#         caller grepping the verdict cannot pick them up.
X_OUT="$( (cd "$BIG_REPO" && PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" --base main --base-state SUSPECT --no-log 2>/dev/null) || true )"
verdict_lines="$(echo "$X_OUT" | grep -c "^## Codex Review: " || true)"
verdict_ok="$(echo "$X_OUT" | grep -cE "^## Codex Review: (PERFORMED|SKIPPED|FAILED)" || true)"
scope_lines="$(echo "$X_OUT" | grep -c "^## Codex Review Scope: " || true)"
if [ "$scope_lines" -lt 2 ]; then
    # The premise: this invocation is both truncated AND base-suspect, so BOTH scope lines
    # are owed. Without them the row would be asserting the ordinary verdict path and would
    # prove nothing about the separation it exists to protect.
    fail "X6: expected both scope lines (truncation + base state), found $scope_lines. Output: $X_OUT"
elif [ "$verdict_lines" = "1" ] && [ "$verdict_ok" = "1" ]; then
    pass "X6: with both scope lines present, the verdict line is still exactly one of PERFORMED/SKIPPED/FAILED"
else
    fail "X6: verdict family polluted — $verdict_lines '## Codex Review: ' lines, $verdict_ok well-formed. Output: $X_OUT"
fi
