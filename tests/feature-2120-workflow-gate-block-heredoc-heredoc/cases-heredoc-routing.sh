# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/universal-target-allow.js, hooks/enforce-worktree/handle-bash-write.js
# Tags: workflow-gate, enforce-worktree, heredoc, routing, scope:issue-specific
# M10-M11 — what hasHeredoc()'s verdict COSTS through a real enforce-worktree.js
# process: the narrow plans/scratchpad gate vs the broad out-of-scope allow, and
# the price the deliberate over-matches pinned in cases-hasheredoc-predicate.sh pay.
# Sourced by feature-2120-workflow-gate-block-heredoc-heredoc.sh.

run_M10() {
    # M10 (C6, test-review round 2) — REAL-HOOK end-to-end for the hasHeredoc()
    # routing fix. M9 pins the predicate; universal-target-allow.js Guard 5/6 and
    # handle-bash-write.js's Bug 2 branch are what CONSUME it, and neither had
    # coverage through an actual hook process. The discriminator is the (b2)/(c)
    # pair: the SAME out-of-session-scope target is BLOCKED when a heredoc carries
    # it (must clear the narrow plans-dir/scratchpad gate) and ALLOWED when it does
    # not (broad Guard 5 path, deliberately left untouched by the fix).
    # Verdict-only assertions: the routing is internal, the allow/block is what the
    # agent actually experiences.

    # (a) heredoc → plans dir: Guard 6 / the #2121 block in handle-bash-write.
    assert_allowed "M10a: heredoc write into the plans dir is ALLOWED (narrow gate clears it)" \
        "$MAIN" "$(bash_payload "$(hd "$PLANS_N/note.md")")"

    # (a2) CPR-ORTH sibling: the scratchpad is the other half of the same gate.
    if [ -n "$SCRATCH_N" ]; then
        assert_allowed "M10a2: heredoc write into the claude scratchpad is ALLOWED (narrow gate clears it)" \
            "$MAIN" "$(bash_payload "$(hd "$SCRATCH_N/note.md")")"
    else
        fail "M10a2: could not resolve the scratchpad base — the scratchpad half of the gate is UNTESTED"
    fi

    # (b) heredoc → an ordinary repo file: nothing to clear the narrow gate with.
    assert_blocked "M10b: heredoc write to a normal repo file still BLOCKS" \
        "$MAIN" "$(bash_payload "$(hd "$MAIN_N/README.md")")" "main worktree"

    # (b2) THE FIX, positively observed: target is outside session scope entirely,
    # so before the hasHeredoc() gating this rode the broad "all write targets
    # outside session scope" allow. It must now fall through to fail-closed.
    assert_blocked "M10b2: heredoc write outside session scope but NOT plans/scratchpad BLOCKS (narrow gate, not the broad allow)" \
        "$MAIN" "$(bash_payload "$(hd "$TMP_N/outside-heredoc.txt")")" "main worktree"

    # (c) The control that makes (b2) attributable to the heredoc and not to the
    # target: identical destination, no heredoc → still the broad Guard 5 allow.
    assert_allowed "M10c: NON-heredoc write to the same out-of-scope target is still ALLOWED (broad Guard 5 path intact)" \
        "$MAIN" "$(bash_payload "echo hi > $TMP_N/outside-plain.txt")"

    # (c2) …and with REAL sequencing, which routes through Guard 2's per-segment
    # arm rather than Guard 5 — the other non-heredoc path the fix must not touch.
    assert_allowed "M10c2: NON-heredoc SEQUENCED writes, all out of scope, still ALLOWED (Guard 2 segment arm intact)" \
        "$MAIN" "$(bash_payload "echo hi > $TMP_N/seq1.txt; echo hi > $TMP_N/seq2.txt")"
}

# M11 (C3, test-review round 3) — REAL-HOOK verdict for hasHeredoc()'s deliberate
# OVER-MATCHES. M9 pins them as `true` at the predicate; this section observes what
# that costs end-to-end. The routing comment in shared-cmd-utils.js calls
# over-matching "the safe side" because true only means "a trip through the
# NARROWER gate" — but Guard 6 / the #2121 branch admit ONLY plans-dir, scratchpad
# and workflow-dir targets, so for any other out-of-session-scope target the trip
# ends in a BLOCK the pre-#2121 broad Guard 5 allow would not have produced.
# These rows PIN THE ACTUAL OBSERVED BEHAVIOUR (they are not aspirational); each
# is paired with a control that removes only the pseudo-opener, so a block is
# attributable to the over-match and not to the target.
run_M11() {
    # (a) here-string: `<<<WORD` — the regex matches its trailing `<<WORD` slice.
    assert_blocked "M11a: here-string + out-of-scope redirect is BLOCKED (over-match routes to the narrow gate)" \
        "$MAIN" "$(bash_payload "grep foo <<<WORD > $TMP_N/m11-hs.txt")"
    assert_allowed "M11a-control: same redirect WITHOUT the here-string is ALLOWED (broad Guard 5)" \
        "$MAIN" "$(bash_payload "grep foo bar.txt > $TMP_N/m11-hs.txt")"

    # (a2) the concern's own example shape: a `tee` sink fed by a here-string.
    assert_blocked "M11a2: tee <out-of-scope> <<<WORD is BLOCKED (over-match routes to the narrow gate)" \
        "$MAIN" "$(bash_payload "tee $TMP_N/m11-tee.txt <<<WORD")"
    assert_allowed "M11a2-control: tee <out-of-scope> without the here-string is ALLOWED" \
        "$MAIN" "$(bash_payload "echo hi | tee $TMP_N/m11-tee.txt")"

    # (b) a heredoc opener that exists only as QUOTED TEXT — no heredoc runs at all.
    assert_blocked "M11b: quoted-literal pseudo-opener is BLOCKED (raw-input match, no real heredoc)" \
        "$MAIN" "$(bash_payload "echo 'cat <<EOF' > $TMP_N/m11-ql.txt")"
    assert_allowed "M11b-control: same write with the literal removed is ALLOWED" \
        "$MAIN" "$(bash_payload "echo 'cat' > $TMP_N/m11-ql.txt")"

    # (c) a heredoc opener inside a trailing COMMENT — likewise never executed.
    assert_blocked "M11c: commented-out pseudo-opener is BLOCKED (raw-input match, no real heredoc)" \
        "$MAIN" "$(bash_payload "echo hi > $TMP_N/m11-cm.txt # cat <<EOF")"
    assert_allowed "M11c-control: same write without the comment is ALLOWED" \
        "$MAIN" "$(bash_payload "echo hi > $TMP_N/m11-cm.txt")"

    # (d) the over-match is NOT fatal when the target already clears the narrow
    # gate — a here-string write into the plans dir is still allowed. This is the
    # boundary that makes (a)-(c) a scope cost, not a total loss of the path.
    assert_allowed "M11d: here-string write into the plans dir is still ALLOWED (narrow gate clears it)" \
        "$MAIN" "$(bash_payload "tee $PLANS_N/m11-hs.md <<<WORD")"
}
