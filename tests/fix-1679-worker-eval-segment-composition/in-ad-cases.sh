# tests/fix-1679-worker-eval-segment-composition/in-ad-cases.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/worker-script.js, hooks/enforce-worktree.js
# Tags: enforce-worktree, allowlist, security, TL1, TL2, pwsh-not-required, scope:issue-specific
#
# Sourced by tests/fix-1679-worker-eval-segment-composition.sh.
# Contains the IN1679-* (real logged blocked forms) and AD1679-* (adversarial
# segment compositions) test groups. See the entrypoint file's header comment
# for the full issue background.

# ============================================================================
# IN — real logged blocked forms. All are the documented pre-flight/run-initial
#      shapes; every one but IN1679-6 is RED before the fix.
# ============================================================================

test_in_cases() {
    echo "=== IN: real logged blocked command forms ==="
    local cmd rc

    # IN1679-1 — the single most-observed blocked form (leading `cd` segment).
    cmd="$(printf 'cd "%s" && %s && echo "OWNER_REPO=$OWNER_REPO"' "$REPO" "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_allow "IN1679-1: cd <repo> && pre-flight eval && echo OWNER_REPO → ALLOW (RED before fix)" "$rc"

    # IN1679-2 — the form that blocked the #1679 filing session itself.
    cmd="$(printf '%s || exit 0; echo "OWNER_REPO=$OWNER_REPO"' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_allow "IN1679-2: pre-flight eval || exit 0; echo OWNER_REPO → ALLOW (RED before fix)" "$rc"

    # IN1679-3 — same as IN1679-2 but with the acd already resolved.
    cmd="$(printf '%s || exit 0; echo "OWNER_REPO=$OWNER_REPO"' "$(pf_eval "$PF_RESOLVED")")"
    rc=0; guard "$cmd" || rc=$?
    assert_allow "IN1679-3: resolved-path pre-flight eval || exit 0; echo → ALLOW (RED before fix)" "$rc"

    # IN1679-4 — fd-dup between the sanctioned segment and the companion segment.
    cmd="$(printf '%s 2>&1 && echo "OWNER_REPO=$OWNER_REPO"' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_allow "IN1679-4: pre-flight eval 2>&1 && echo OWNER_REPO → ALLOW (RED before fix)" "$rc"

    # IN1679-5 — S-6 2-argument run-initial.sh plus a trailing echo companion.
    # #1673 deleted finalize-worker-overlay.js, the only match for a literal
    # `eval "$(... bash ".../run-initial.sh" ...)"` Bash-tool string — run-initial.sh
    # is now reached exclusively as a spawnSync child of bin/worker-dispatch.js
    # (shell:false, no eval). No segment composition of this shape can ALLOW any
    # more; retired-capability pin (same treatment as #1673's other eval-path suites).
    cmd="$(printf 'eval "$(AGENTS_CONFIG_DIR="%s" FINALIZE_SCRIPTS_DIR="%s" MAIN_WORKTREE_PATH="%s" bash "%s/run-initial.sh" "1234" "1234")"; echo "STATUS=$STATUS"' \
        "$ACD" "$SCRIPTS" "$REPO" "$SCRIPTS")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "IN1679-5: run-initial 2-arg eval; echo STATUS → BLOCK — eval path retired (#1673)" "$rc"

    # IN1679-6 — the bare shape documented in issue-close-finalize/SKILL.md.
    # Already allowed by the #1484 eval-unwrap; pinned here as the no-regression anchor.
    cmd="$(pf_eval "$PF_LITERAL")"
    rc=0; guard "$cmd" || rc=$?
    assert_allow "IN1679-6: bare pre-flight eval, no companion segment → ALLOW (no regression)" "$rc"
}

# ============================================================================
# AD — adversarial compositions. BLOCK before AND after the S-8 widening.
# ============================================================================

test_ad_cases() {
    echo "=== AD: adversarial segment compositions (must stay BLOCK) ==="
    local cmd rc

    # AD1679-1: companion segment on a NEW LINE performing a real write.
    cmd="$(printf '%s || exit 0\nrm -f README.md' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-1: pre-flight + newline + rm -f README.md → BLOCK" "$rc"

    # AD1679-2: companion segment redirects into the main worktree.
    cmd="$(printf '%s && echo x > out.txt' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-2: pre-flight + echo x > out.txt → BLOCK" "$rc"

    # AD1679-3: write hidden inside a command substitution in the companion.
    cmd="$(printf '%s && echo "$(rm -f x)"' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-3: pre-flight + echo \"\$(rm -f x)\" → BLOCK" "$rc"

    # AD1679-4: opaque dynamic eval as the companion segment.
    cmd="$(printf '%s ; eval "$DYNAMIC"' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-4: pre-flight + eval \"\$DYNAMIC\" → BLOCK" "$rc"

    # AD1679-5: git write as the companion segment.
    cmd="$(printf '%s && git commit -m x' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-5: pre-flight + git commit -m x → BLOCK" "$rc"

    # AD1679-6: TWO sanctioned segments — the rule admits exactly one.
    cmd="$(printf '%s && %s' "$(pf_eval "$PF_LITERAL")" "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-6: pre-flight eval chained twice → BLOCK" "$rc"

    # AD1679-7: eval of a non-sanctioned script under acd, with a read companion.
    cmd="$(printf 'eval "$(bash "%s/bin/evil.sh")" ; echo hi' "$ACD")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-7: eval of non-allowlisted <acd>/bin/evil.sh ; echo hi → BLOCK" "$rc"

    # AD1679-8: pipe into a writer whose target lands in the main worktree.
    # The plan wrote this row as `| tee /tmp/x`, but that target is OUTSIDE
    # session scope, and ENFORCE_WORKTREE deliberately guards only writes into
    # the main worktree — so `/tmp/x` is allowed by design and cannot express the
    # boundary at TL2. A main-worktree-relative target expresses the same intent
    # (a writer must not ride along on the sanctioned segment) observably.
    cmd="$(printf '%s | tee out.txt' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-8: pre-flight + | tee out.txt (main-worktree target) → BLOCK" "$rc"

    # AD1679-8b: the plan's literal form, pinned with its correct expectation so
    # the in-scope/out-of-scope distinction above stays explicit rather than
    # silently dropped. This is ENFORCE_WORKTREE's documented scope, not a gap.
    cmd="$(printf '%s | tee /tmp/x' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_allow "AD1679-8b: pre-flight + | tee /tmp/x (out-of-scope target) → ALLOW by design" "$rc"

    # ---- Confused-deputy guards (ENV_MUTATION_RE / ASSIGN_RE) ---------------
    # Each of the four leading segments below is classified read (null) by
    # detectWritePredicate, so a write-only composition rule would admit them —
    # and each can repoint the very variable the sanctioned segment resolves against.

    # AD1679-9: export repoints AGENTS_CONFIG_DIR before the sanctioned segment.
    cmd="$(printf 'export AGENTS_CONFIG_DIR=/evil; %s' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-9: export AGENTS_CONFIG_DIR=/evil; + pre-flight → BLOCK (env mutation)" "$rc"

    # AD1679-10: bare assignment, same effect.
    cmd="$(printf 'AGENTS_CONFIG_DIR=/evil ; %s' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-10: AGENTS_CONFIG_DIR=/evil ; + pre-flight → BLOCK (assignment)" "$rc"

    # AD1679-11: unset makes the literal prefix resolve against nothing.
    cmd="$(printf 'unset AGENTS_CONFIG_DIR; %s' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-11: unset AGENTS_CONFIG_DIR; + pre-flight → BLOCK (env mutation)" "$rc"

    # AD1679-12: `source` can mutate the environment arbitrarily and opaquely.
    cmd="$(printf 'source /tmp/x.sh && %s' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-12: source /tmp/x.sh && + pre-flight → BLOCK (opaque env mutation)" "$rc"
}
