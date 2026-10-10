# tests/hooks/fix-1679-worker-eval-segment-composition/in-ad-cases.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/worker-script.js, hooks/enforce-worktree.js
# Tags: enforce-worktree, allowlist, security, TL1, TL2, pwsh-not-required, scope:issue-specific
#
# Sourced by tests/hooks/fix-1679-worker-eval-segment-composition.sh.
# IN1679-* = real logged blocked forms (every one but IN1679-6 was RED before the
# #1679 fix); AD1679-* = adversarial segment compositions.

test_in_cases() {
    echo "=== IN: real logged blocked command forms ==="
    local cmd rc

    # IN1679-1 — the single most-observed blocked form (leading `cd` segment).
    cmd="$(printf 'cd "%s" && %s && echo "OWNER_REPO=$OWNER_REPO"' "$REPO" "$(pf_eval "$PF_RESOLVED")")"
    rc=0; guard "$cmd" || rc=$?
    assert_allow "IN1679-1: cd <repo> && pre-flight eval && echo OWNER_REPO → ALLOW (RED before fix)" "$rc"

    # IN1679-2 — the form that blocked the #1679 filing session itself.
    cmd="$(printf '%s || exit 0; echo "OWNER_REPO=$OWNER_REPO"' "$(pf_eval "$PF_RESOLVED")")"
    rc=0; guard "$cmd" || rc=$?
    assert_allow "IN1679-2: pre-flight eval || exit 0; echo OWNER_REPO → ALLOW (RED before fix)" "$rc"

    # IN1679-3 — same as IN1679-2 but the path is still an unexpanded variable.
    # The guard cannot confirm which file would run, so it blocks with a hint (#2561).
    cmd="$(printf '%s || exit 0; echo "OWNER_REPO=$OWNER_REPO"' "$(pf_eval "$PF_VARIABLE")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "IN1679-3: variable-path pre-flight eval || exit 0; echo → BLOCK (#2561)" "$rc"
    if printf '%s' "$GUARD_OUT" | grep -qF 'but this command names it through $AGENTS_MAIN_ROOT'; then
        pass "IN1679-3-hint: block reason names the variable the script was reached through"
    else
        fail "IN1679-3-hint: block reason lacks the variable-path hint (out: $GUARD_OUT)"
    fi

    # IN1679-4 — fd-dup between the sanctioned segment and the companion segment.
    cmd="$(printf '%s 2>&1 && echo "OWNER_REPO=$OWNER_REPO"' "$(pf_eval "$PF_RESOLVED")")"
    rc=0; guard "$cmd" || rc=$?
    assert_allow "IN1679-4: pre-flight eval 2>&1 && echo OWNER_REPO → ALLOW (RED before fix)" "$rc"

    # IN1679-5 — S-6 2-argument run-initial.sh plus a trailing echo companion.
    # #1673 deleted finalize-worker-overlay.js, the only match for a literal
    # `eval "$(... bash ".../run-initial.sh" ...)"` Bash-tool string — run-initial.sh
    # is now reached exclusively as a spawnSync child of bin/worker-dispatch.js
    # (shell:false, no eval). No segment composition of this shape can ALLOW any
    # more; retired-capability pin (same treatment as #1673's other eval-path suites).
    cmd="$(printf 'eval "$(AGENTS_MAIN_ROOT="%s" FINALIZE_SCRIPTS_DIR="%s" TARGET_MAIN_ROOT="%s" bash "%s/run-initial.sh" "1234" "1234")"; echo "STATUS=$STATUS"' \
        "$GUARD_CHECKOUT" "$SCRIPTS" "$REPO" "$SCRIPTS")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "IN1679-5: run-initial 2-arg eval; echo STATUS → BLOCK — eval path retired (#1673)" "$rc"

    # IN1679-6 — the bare eval shape, no companion segment.
    # Already allowed by the #1484 eval-unwrap; pinned here as the no-regression anchor.
    cmd="$(pf_eval "$PF_RESOLVED")"
    rc=0; guard "$cmd" || rc=$?
    assert_allow "IN1679-6: bare pre-flight eval, no companion segment → ALLOW (no regression)" "$rc"
}

# ============================================================================
# AD — adversarial compositions. BLOCK before AND after the S-8 widening.
# Every row carries the verifiable path, so the companion is the only reason to block.
# ============================================================================

test_ad_cases() {
    echo "=== AD: adversarial segment compositions (must stay BLOCK) ==="
    local cmd rc

    # AD1679-1: companion segment on a NEW LINE performing a real write.
    cmd="$(printf '%s || exit 0\nrm -f README.md' "$(pf_eval "$PF_RESOLVED")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-1: pre-flight + newline + rm -f README.md → BLOCK" "$rc"

    # AD1679-2: companion segment redirects into the main worktree.
    cmd="$(printf '%s && echo x > out.txt' "$(pf_eval "$PF_RESOLVED")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-2: pre-flight + echo x > out.txt → BLOCK" "$rc"

    # AD1679-3: write hidden inside a command substitution in the companion.
    cmd="$(printf '%s && echo "$(rm -f x)"' "$(pf_eval "$PF_RESOLVED")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-3: pre-flight + echo \"\$(rm -f x)\" → BLOCK" "$rc"

    # AD1679-4: opaque dynamic eval as the companion segment.
    cmd="$(printf '%s ; eval "$DYNAMIC"' "$(pf_eval "$PF_RESOLVED")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-4: pre-flight + eval \"\$DYNAMIC\" → BLOCK" "$rc"

    # AD1679-5: git write as the companion segment.
    cmd="$(printf '%s && git commit -m x' "$(pf_eval "$PF_RESOLVED")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-5: pre-flight + git commit -m x → BLOCK" "$rc"

    # AD1679-6: TWO sanctioned segments — the rule admits exactly one.
    cmd="$(printf '%s && %s' "$(pf_eval "$PF_RESOLVED")" "$(pf_eval "$PF_RESOLVED")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-6: pre-flight eval chained twice → BLOCK" "$rc"

    # AD1679-7: eval of a non-sanctioned script under script checkout root, with a read companion.
    cmd="$(printf 'eval "$(bash "%s/bin/evil.sh")" ; echo hi' "$GUARD_CHECKOUT")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-7: eval of non-allowlisted <script-checkout-root>/bin/evil.sh ; echo hi → BLOCK" "$rc"

    # AD1679-8: pipe into a writer whose target lands in the main worktree.
    # The plan wrote this row as `| tee /tmp/x`, but that target is OUTSIDE
    # session scope, and ENFORCE_WORKTREE deliberately guards only writes into
    # the main worktree — so `/tmp/x` is allowed by design and cannot express the
    # boundary at TL2. A main-worktree-relative target expresses the same intent
    # (a writer must not ride along on the sanctioned segment) observably.
    cmd="$(printf '%s | tee out.txt' "$(pf_eval "$PF_RESOLVED")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-8: pre-flight + | tee out.txt (main-worktree target) → BLOCK" "$rc"

    # AD1679-8b: the plan's literal form, pinned with its correct expectation so
    # the in-scope/out-of-scope distinction above stays explicit rather than
    # silently dropped. This is ENFORCE_WORKTREE's documented scope, not a gap.
    cmd="$(printf '%s | tee /tmp/x' "$(pf_eval "$PF_RESOLVED")")"
    rc=0; guard "$cmd" || rc=$?
    assert_allow "AD1679-8b: pre-flight + | tee /tmp/x (out-of-scope target) → ALLOW by design" "$rc"

    # ---- Confused-deputy guards (ENV_MUTATION_RE / ASSIGN_RE) ---------------
    # Each of the four leading segments below is classified read (null) by
    # detectWritePredicate, so a write-only composition rule would admit them.

    # AD1679-9: export repoints AGENTS_MAIN_ROOT before the sanctioned segment.
    cmd="$(printf 'export AGENTS_MAIN_ROOT=/evil; %s' "$(pf_eval "$PF_RESOLVED")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-9: export AGENTS_MAIN_ROOT=/evil; + pre-flight → BLOCK (env mutation)" "$rc"

    # AD1679-10: bare assignment, same effect.
    cmd="$(printf 'AGENTS_MAIN_ROOT=/evil ; %s' "$(pf_eval "$PF_RESOLVED")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-10: AGENTS_MAIN_ROOT=/evil ; + pre-flight → BLOCK (assignment)" "$rc"

    # AD1679-11: unset of the settings-root variable.
    cmd="$(printf 'unset AGENTS_MAIN_ROOT; %s' "$(pf_eval "$PF_RESOLVED")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-11: unset AGENTS_MAIN_ROOT; + pre-flight → BLOCK (env mutation)" "$rc"

    # AD1679-12: `source` can mutate the environment arbitrarily and opaquely.
    cmd="$(printf 'source /tmp/x.sh && %s' "$(pf_eval "$PF_RESOLVED")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-12: source /tmp/x.sh && + pre-flight → BLOCK (opaque env mutation)" "$rc"
}
