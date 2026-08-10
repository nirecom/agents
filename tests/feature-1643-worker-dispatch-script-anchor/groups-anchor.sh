# Part of tests/feature-1643-worker-dispatch-script-anchor.sh — sourced, not run.
# Tests: bin/worker-dispatch/spawn.js, hooks/lib/worker-dispatch-registry.js, bin/worker-dispatch/workers/test-runner.js, bin/worker-dispatch/capability.js
# Tags: worker-dispatch, script-anchor, family-worktree, spawn, registry, regression, TL2, scope:issue-specific
#
# The script-anchor half of the suite: groups A, B+D, C, E and F, i.e. everything
# that is about WHICH ROOT a declared script resolves against. The buildEnv
# groups live in the two group-env-*.sh parts.

# ===========================================================================
# Group A — SCRIPT_ANCHORS is the vocabulary, and no worker escapes it
# ===========================================================================
group_a() {
    if impl_missing "registry/script-anchors-exported" "$REGISTRY_JS" "hooks/lib/worker-dispatch-registry.js"; then return; fi
    if ! probe registry; then
        fail "registry/script-anchors-exported — probe failed: $PROBE_OUT"
        return
    fi
    assert_eq "registry/script-anchors-exported" "array" "$(pv exported)"
    assert_eq "registry/script-anchors-exact-set" "acd,family-worktree,main-root" "$(pv sorted)"
    assert_eq "registry/script-anchors-count" "3" "$(pv count)"
    # Table-driven guard: a future worker declaring an unlisted anchor fails here
    # instead of failing silently at dispatch time with an unresolvable anchor.
    assert_eq "registry/no-unknown-anchor-declared" "" "$(pv unknown)"
    # Non-vacuity: the loop above must actually have scanned script declarations.
    if [ "$(pv scanned)" -ge 6 ] 2>/dev/null; then
        pass "registry/anchor-scan-non-vacuous"
    else
        fail "registry/anchor-scan-non-vacuous — scanned=$(pv scanned)"
    fi
    assert_eq "registry/test-runner-runall-family-anchored" "family-worktree" "$(pv tr_runall_anchor)"
    # Regression fence: "main-root" is the value that made a linked-worktree
    # dispatch run MAIN's tests/run-all.sh while reporting success.
    assert_ne "registry/test-runner-runall-not-main-root" "main-root" "$(pv tr_runall_anchor)"
}

# ===========================================================================
# Group B / D — resolveScript anchoring and anchorRoot's null verdict
# ===========================================================================
group_bd() {
    if impl_missing "resolve/family-anchored-under-cwd" "$SPAWN_JS" "bin/worker-dispatch/spawn.js"; then return; fi
    if ! probe resolve; then
        fail "resolve/family-anchored-under-cwd — probe failed: $PROBE_OUT"
        return
    fi
    assert_eq "resolve/family-anchored-under-cwd" "1" "$(pv fam_under_cwd)"
    assert_eq "resolve/main-anchored-under-mainroot" "1" "$(pv main_under_mainroot)"
    assert_eq "resolve/family-anchored-not-under-mainroot" "0" "$(pv fam_under_mainroot)"
    # The discriminator: same rel path, different anchor → different absolute
    # script. A test that passes under both anchors would be worthless here.
    assert_eq "resolve/anchors-yield-different-paths" "1" "$(pv differ)"
    case "$(pv bogus_err)" in
        *unresolvable\ anchor*) pass "anchorroot/unknown-token-unresolvable" ;;
        *) fail "anchorroot/unknown-token-unresolvable — got: $(pv bogus_err)" ;;
    esac
    case "$(pv fam_nocwd_err)" in
        *unresolvable\ anchor*) pass "anchorroot/family-without-cwd-unresolvable" ;;
        *) fail "anchorroot/family-without-cwd-unresolvable — got: $(pv fam_nocwd_err)" ;;
    esac
}

# ===========================================================================
# Group C — cwd must be a proven family member, and proven BEFORE resolution
# ===========================================================================
group_c() {
    if impl_missing "contain/exists-in-family" "$SPAWN_JS" "bin/worker-dispatch/spawn.js"; then return; fi
    if ! probe contain; then
        fail "contain/exists-in-family — probe failed: $PROBE_OUT"
        return
    fi
    # Positive counterparts first — without them the NULLs below prove nothing.
    assert_eq "contain/exists-in-family-linked" "PATH" "$(pv exists_family)"
    assert_eq "contain/exists-in-family-mainroot" "PATH" "$(pv exists_mainroot)"
    # Out-of-family cwds must not even be probeable for existence, although each
    # of these directories really does contain a tests/run-all.sh.
    assert_eq "contain/exists-outside-null" "NULL" "$(pv exists_outside)"
    assert_eq "contain/exists-alt-repo-null" "NULL" "$(pv exists_alt)"
    assert_eq "contain/exists-relative-null" "NULL" "$(pv exists_relative)"
    case "$(pv run_outside_err)" in
        *not\ a\ worktree\ of\ the\ main-root\ family*) pass "contain/run-rejects-outside" ;;
        *) fail "contain/run-rejects-outside — got: $(pv run_outside_err)" ;;
    esac
    case "$(pv run_alt_err)" in
        *not\ a\ worktree\ of\ the\ main-root\ family*) pass "contain/run-rejects-alt-repo" ;;
        *) fail "contain/run-rejects-alt-repo — got: $(pv run_alt_err)" ;;
    esac
    # Ordering: runAll is family-anchored, so if run() resolved the script before
    # validating cwd the failure would be an anchor/resolution error instead.
    case "$(pv run_outside_err)" in
        *anchor*|*could\ not\ be\ resolved*)
            fail "contain/cwd-validated-before-script-resolution — resolution error surfaced first: $(pv run_outside_err)" ;;
        *) pass "contain/cwd-validated-before-script-resolution" ;;
    esac
}

# ===========================================================================
# Group E — timeout_seconds bound (raised 3600 → 21600; default unchanged)
# ===========================================================================
group_e() {
    if impl_missing "timeout/max-21600-accepted" "$REGISTRY_JS" "hooks/lib/worker-dispatch-registry.js"; then return; fi
    if ! probe timeout; then
        fail "timeout/max-21600-accepted — probe failed: $PROBE_OUT"
        return
    fi
    assert_eq "timeout/120-accepted" "1" "$(pv ok_120)"
    assert_eq "timeout/3600-accepted" "1" "$(pv ok_3600)"
    assert_eq "timeout/max-21600-accepted" "1" "$(pv ok_21600)"
    assert_eq "timeout/off-by-one-21601-rejected" "0" "$(pv ok_21601)"
    assert_eq "timeout/zero-rejected" "0" "$(pv ok_0)"
    assert_eq "timeout/default-still-120" "120" "$(pv default)"
}

# ===========================================================================
# Group F — end-to-end: a dispatch targeting the LINKED worktree must run the
# LINKED tests/run-all.sh. Main's copy prints MAIN-SUITE, the linked copy prints
# LINKED-SUITE; under the pre-fix main-root anchor this run reported success
# while executing MAIN's suite.
# ===========================================================================
group_f() {
    if impl_missing "e2e/runs-linked-suite" "$DISPATCH_JS" "bin/worker-dispatch.js"; then
        fail "e2e/does-not-run-main-suite — implementation missing: bin/worker-dispatch.js"
        fail "e2e/status-pass — implementation missing: bin/worker-dispatch.js"
        return
    fi
    local pfile out rc status
    pfile="$PLANS_RAW/tr-linked.json"
    printf '%s' "{\"cwd\":\"$LINKED\",\"test_args\":[],\"timeout_seconds\":60}" > "$pfile"
    rc=0
    out="$(cd "$MAIN_RAW" && run_with_timeout 60 env "WORKFLOW_PLANS_DIR=$PLANS" "CLAUDE_WORKFLOW_DIR=$WFDIR" \
        node "$DISPATCH_JS" test-runner "$MAIN" "$(nodepath "$pfile")" 2>&1)" || rc=$?
    status="$(printf '%s\n' "$out" | sed -n 's/^status: *//p' | head -1)"
    assert_eq "e2e/exit0" "0" "$rc"
    assert_eq "e2e/status-pass" "pass" "$status"
    case "$out" in
        *LINKED-SUITE*) pass "e2e/runs-linked-suite" ;;
        *) fail "e2e/runs-linked-suite — output did not name the linked suite: $out" ;;
    esac
    case "$out" in
        *MAIN-SUITE*) fail "e2e/does-not-run-main-suite — main's tests/run-all.sh was executed instead" ;;
        *) pass "e2e/does-not-run-main-suite" ;;
    esac
}
