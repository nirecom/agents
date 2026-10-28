# tests/hooks/feature-883-resolve-workflow-session-id/cases-r0-r10.sh
# Test case function definitions for R0-R10 (priority order, charset guard, date sanity, depth score).
# Invocations live in the dispatcher.

run_r0() {
    require_function "resolveWorkflowSessionId" "R0: WORKTREE_NOTES.md Session-ID takes priority" || return
    local tmp out
    tmp="$(mktemp -d)"
    # Priority 1: WORKTREE_NOTES.md in CWD with a valid session ID.
    # Also add a context.md with a different id to confirm it is NOT picked.
    printf "Session-ID: %s-r0session\n" "$TODAY" > "$tmp/WORKTREE_NOTES.md"
    : > "$tmp/${TODAY}-other-context.md"
    out=$(call_resolve "$tmp" "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "${TODAY}-r0session" ]; then
        pass "R0: WORKTREE_NOTES.md Session-ID takes priority"
    else
        fail "R0: WORKTREE_NOTES.md Session-ID takes priority (out=$out)"
    fi
}

run_r0b() {
    require_function "resolveWorkflowSessionId" "R0b: WORKTREE_NOTES.md via git common-dir (linked worktree)" || return
    if ! command -v git >/dev/null 2>&1; then skip "R0b: git not available"; return; fi
    local main_repo linked_wt plans_tmp out sid
    main_repo="$(mktemp -d)"
    linked_wt="${main_repo}/linked-wt"
    plans_tmp="$(mktemp -d)"
    sid="${TODAY}-r0bsession"
    # Set up a minimal git repo with one commit so git worktree add works.
    (cd "$main_repo" && git init -q && git config core.hooksPath /dev/null && git config user.email "test@example.com" && \
        git config user.name "Test" && git commit -q --allow-empty -m "init") 2>/dev/null
    # Create linked worktree — no WORKTREE_NOTES.md there.
    (cd "$main_repo" && git worktree add -q "$linked_wt" -b "test-r0b") 2>/dev/null
    # WORKTREE_NOTES.md in main repo root (git common-dir parent).
    printf "Session-ID: %s\n" "$sid" > "$main_repo/WORKTREE_NOTES.md"
    # Run from linked worktree: CWD has no WORKTREE_NOTES.md; common-dir parent does.
    out=$(call_resolve "$plans_tmp" "$linked_wt")
    rm -rf "$main_repo" "$plans_tmp"
    if [ "$out" = "$sid" ]; then
        pass "R0b: WORKTREE_NOTES.md via git common-dir (linked worktree)"
    else
        fail "R0b: WORKTREE_NOTES.md via git common-dir (linked worktree) (out=$out)"
    fi
}

# R1 / R2 / R14 (env-file relay Priority 3) were retired with that priority in #1091.

run_r3() {
    require_function "resolveWorkflowSessionId" "R3: single same-day context.md" || return
    local tmp out
    tmp="$(mktemp -d)"
    : > "$tmp/${TODAY}-001252-context.md"
    out=$(call_resolve "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "${TODAY}-001252" ]; then
        pass "R3: single same-day context.md"
    else
        fail "R3: single same-day context.md (out=$out)"
    fi
}

run_r4() {
    require_function "resolveWorkflowSessionId" "R4: 3 same-day stubs, no env (no ccBucket=0) -> NULL" || return
    local tmp out
    tmp="$(mktemp -d)"
    : > "$tmp/${TODAY}-a-context.md"
    : > "$tmp/${TODAY}-b-context.md"
    : > "$tmp/${TODAY}-c-context.md"
    # b is newest (T-2); a is T-6; c is T-4. All ccBucket=1 (no env). Gate fires → NULL.
    set_mtimes \
        "$tmp/${TODAY}-a-context.md" -6 \
        "$tmp/${TODAY}-b-context.md" -2 \
        "$tmp/${TODAY}-c-context.md" -4
    out=$(call_resolve "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "NULL" ]; then
        pass "R4: 3 same-day stubs, no env (no ccBucket=0) -> NULL"
    else
        fail "R4: 3 same-day stubs, no env (no ccBucket=0) -> NULL (out=$out)"
    fi
}

run_r5() {
    require_function "resolveWorkflowSessionId" "R5: empty plans-dir -> null" || return
    local tmp out
    tmp="$(mktemp -d)"
    out=$(call_resolve "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "NULL" ]; then
        pass "R5: empty plans-dir -> null"
    else
        fail "R5: empty plans-dir -> null (out=$out)"
    fi
}

run_r6() {
    require_function "resolveWorkflowSessionId" "R6: nonexistent plans-dir -> null (no throw)" || return
    local tmp out bogus
    tmp="$(mktemp -d)"
    bogus="$tmp/does-not-exist"
    # work_dir=$tmp (exists) so cd succeeds; plans_dir=bogus so readdirSync returns null.
    out=$(call_resolve "$bogus" "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "NULL" ]; then
        pass "R6: nonexistent plans-dir -> null (no throw)"
    else
        fail "R6: nonexistent plans-dir -> null (no throw) (out=$out)"
    fi
}

run_r7() {
    require_function "resolveWorkflowSessionId" "R7: adversarial filename blocked by charset validator" || return
    local tmp out
    tmp="$(mktemp -d)"
    # '..' has dots — fails /^[A-Za-z0-9_-]+$/. Must NOT be returned.
    : > "$tmp/..-context.md"
    : > "$tmp/${TODAY}-good-context.md"
    set_mtimes \
        "$tmp/..-context.md" -2 \
        "$tmp/${TODAY}-good-context.md" -4
    # Note: even though '..' has newer mtime, the charset validator should drop it,
    # leaving only ${TODAY}-good as a valid candidate.
    out=$(call_resolve "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "${TODAY}-good" ]; then
        pass "R7: adversarial filename blocked by charset validator"
    else
        fail "R7: adversarial filename blocked by charset validator (out=$out)"
    fi
}

run_r8() {
    require_function "resolveWorkflowSessionId" "R8: date-sanity excludes yesterday; 2 today stubs (no ccBucket=0) -> NULL" || return
    local tmp out
    tmp="$(mktemp -d)"
    : > "$tmp/${TODAY}-090000-context.md"
    : > "$tmp/${TODAY}-100000-context.md"
    : > "$tmp/${YESTERDAY}-235959-context.md"
    # Yesterday file excluded by date-sanity guard. 2 today stubs remain; both ccBucket=1 (no env). Gate fires → NULL.
    set_mtimes \
        "$tmp/${TODAY}-090000-context.md" -6 \
        "$tmp/${TODAY}-100000-context.md" -4 \
        "$tmp/${YESTERDAY}-235959-context.md" -2
    out=$(call_resolve "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "NULL" ]; then
        pass "R8: date-sanity excludes yesterday; 2 today stubs (no ccBucket=0) -> NULL"
    else
        fail "R8: date-sanity excludes yesterday; 2 today stubs (no ccBucket=0) -> NULL (out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# R9 / R10: depth-score tie-breaker
# Active sessions (with intent.md or detail.md) MUST beat bare-stub sessions
# (context.md only) even when the stub has the newer mtime. This is the
# Priority 3 enhancement for issue #949 / #883 follow-up.
# ---------------------------------------------------------------------------

run_r9() {
    require_function "resolveWorkflowSessionId" "R9: active+stub, no env (both ccBucket=1) -> NULL" || return
    local tmp out
    tmp="$(mktemp -d)"
    # 'active' has context+intent+detail (depth=2), older mtime T-10.
    : > "$tmp/${TODAY}-active-context.md"
    : > "$tmp/${TODAY}-active-intent.md"
    : > "$tmp/${TODAY}-active-detail.md"
    # 'stub' has context.md only (depth=0), newer mtime T-2.
    : > "$tmp/${TODAY}-stub-context.md"
    # Both ccBucket=1 (no env): gate fires → NULL.
    set_mtimes \
        "$tmp/${TODAY}-active-context.md" -10 \
        "$tmp/${TODAY}-active-intent.md" -10 \
        "$tmp/${TODAY}-active-detail.md" -10 \
        "$tmp/${TODAY}-stub-context.md" -2
    out=$(call_resolve "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "NULL" ]; then
        pass "R9: active+stub, no env (both ccBucket=1) -> NULL"
    else
        fail "R9: active+stub, no env (both ccBucket=1) -> NULL (out=$out)"
    fi
}

run_r10() {
    require_function "resolveWorkflowSessionId" "R10: intonly+stub, no env (both ccBucket=1) -> NULL" || return
    local tmp out
    tmp="$(mktemp -d)"
    # 'intonly' has context+intent (depth=1), older mtime T-8.
    : > "$tmp/${TODAY}-intonly-context.md"
    : > "$tmp/${TODAY}-intonly-intent.md"
    # 'stub' has context.md only (depth=0), newer mtime T-2.
    : > "$tmp/${TODAY}-stub-context.md"
    # Both ccBucket=1 (no env): gate fires → NULL.
    set_mtimes \
        "$tmp/${TODAY}-intonly-context.md" -8 \
        "$tmp/${TODAY}-intonly-intent.md" -8 \
        "$tmp/${TODAY}-stub-context.md" -2
    out=$(call_resolve "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "NULL" ]; then
        pass "R10: intonly+stub, no env (both ccBucket=1) -> NULL"
    else
        fail "R10: intonly+stub, no env (both ccBucket=1) -> NULL (out=$out)"
    fi
}
