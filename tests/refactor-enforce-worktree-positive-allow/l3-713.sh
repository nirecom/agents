
# ============================================================================
# L3 — #713: /issue-create callable from main worktree (T1–T10)
# ============================================================================

test_l3_36_issue_713_skill_inline_prefix_allowed_from_main() {
    require_file "$GUARD_JS" "test_l3_36_issue_713_skill_inline_prefix_allowed_from_main" || return
    local repo; repo="$(setup_main_checkout "l3-36")"
    local cmd='ISSUE_CREATE_SKILL=1 gh issue create --title T --body B'
    local out
    out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L3.36 #713: ISSUE_CREATE_SKILL=1 inline prefix from main: allowed"
    else
        fail "L3.36 #713: ISSUE_CREATE_SKILL=1 inline prefix from main should allow ($out)"
    fi
}

test_l3_37_issue_713_msys_plus_skill_prefix_allowed_from_main() {
    require_file "$GUARD_JS" "test_l3_37_issue_713_msys_plus_skill_prefix_allowed_from_main" || return
    local repo; repo="$(setup_main_checkout "l3-37")"
    local cmd='MSYS_NO_PATHCONV=1 ISSUE_CREATE_SKILL=1 gh issue create --title T --body B'
    local out
    out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L3.37 #713: MSYS_NO_PATHCONV=1 + ISSUE_CREATE_SKILL=1 from main: allowed"
    else
        fail "L3.37 #713: MSYS + SKILL prefix from main should allow ($out)"
    fi
}

test_l3_38_issue_713_bare_gh_issue_create_blocked_from_main() {
    require_file "$GUARD_JS" "test_l3_38_issue_713_bare_gh_issue_create_blocked_from_main" || return
    local repo; repo="$(setup_main_checkout "l3-38")"
    local cmd='gh issue create --title T --body B'
    local out
    out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "L3.38 #713: bare gh issue create from main should BLOCK ($out)"
    else
        if echo "$out" | grep -q '/issue-create'; then
            pass "L3.38 #713: bare gh issue create from main blocked with /issue-create reason"
        else
            fail "L3.38 #713: blocked but reason missing '/issue-create' ($out)"
        fi
    fi
}

test_l3_39_issue_713_bare_gh_issue_create_allowed_from_linked() {
    require_file "$GUARD_JS" "test_l3_39_issue_713_bare_gh_issue_create_allowed_from_linked" || return
    local pair; pair="$(setup_linked_worktree "l3-39")"
    local wt="${pair#*|}"
    local cmd='gh issue create --title T --body B'
    local out
    out="$(run_bash_guard "$cmd" "$wt" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L3.39 #713: bare gh issue create from linked worktree: allowed"
    else
        fail "L3.39 #713: bare gh issue create from linked worktree should allow ($out)"
    fi
}

test_l3_40_issue_713_skill_prefix_also_allowed_from_linked() {
    require_file "$GUARD_JS" "test_l3_40_issue_713_skill_prefix_also_allowed_from_linked" || return
    local pair; pair="$(setup_linked_worktree "l3-40")"
    local wt="${pair#*|}"
    local cmd='ISSUE_CREATE_SKILL=1 gh issue create --title T --body B'
    local out
    out="$(run_bash_guard "$cmd" "$wt" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L3.40 #713: ISSUE_CREATE_SKILL=1 from linked worktree: allowed"
    else
        fail "L3.40 #713: skill prefix from linked worktree should allow ($out)"
    fi
}

test_l3_41_issue_659_multiline_body_sanctioned_not_blocked_from_main() {
    require_file "$GUARD_JS" "test_l3_41_issue_659_multiline_body_sanctioned_not_blocked_from_main" || return
    local repo; repo="$(setup_main_checkout "l3-41")"
    local body; body="$(printf 'line1\nrm -rf /\nline3')"
    local cmd; cmd="ISSUE_CREATE_SKILL=1 gh issue create --title T --body \"$body\""
    local out
    out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L3.41 #659: multi-line BODY with rm-rf-like token + skill prefix from main: allowed"
    else
        fail "L3.41 #659: multi-line BODY false-positive — sanctioned create should allow ($out)"
    fi
}

test_l3_42_issue_659_multiline_body_bare_blocked_for_skill_reason_from_main() {
    require_file "$GUARD_JS" "test_l3_42_issue_659_multiline_body_bare_blocked_for_skill_reason_from_main" || return
    local repo; repo="$(setup_main_checkout "l3-42")"
    local body; body="$(printf 'line1\nrm -rf /\nline3')"
    local cmd; cmd="gh issue create --title T --body \"$body\""
    local out
    out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "L3.42 #659: bare gh issue create with multi-line body should BLOCK ($out)"
    else
        if echo "$out" | grep -q '/issue-create'; then
            pass "L3.42 #659: bare gh issue create blocked for /issue-create reason (not rm -rf)"
        else
            fail "L3.42 #659: blocked but reason missing '/issue-create' (write-pattern false positive?) ($out)"
        fi
    fi
}

test_l3_43_issue_713_process_env_alone_does_not_authorize() {
    require_file "$GUARD_JS" "test_l3_43_issue_713_process_env_alone_does_not_authorize" || return
    local repo; repo="$(setup_main_checkout "l3-43")"
    local cmd='gh issue create --title T --body B'
    local out
    out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on ISSUE_CREATE_SKILL=1)"
    if guard_decision "$out"; then
        fail "L3.43 #713: process.env ISSUE_CREATE_SKILL=1 alone should NOT authorize from main ($out)"
    else
        pass "L3.43 #713: process.env ISSUE_CREATE_SKILL=1 alone (no inline prefix) still blocks from main"
    fi
}

test_l3_44_issue_713_other_gh_kinds_unaffected_main_in_session() {
    require_file "$GUARD_JS" "test_l3_44_issue_713_other_gh_kinds_unaffected_main_in_session" || return
    local repo; repo="$(setup_main_checkout "l3-44")"
    local cmd='gh api -X PATCH repos/owner/repo/issues/1'
    local out
    out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L3.44 #713: gh api -X PATCH from main (in session-scope): allowed"
    else
        fail "L3.44 #713: gh api PATCH from main should allow (regression) ($out)"
    fi
}

test_l3_45_issue_713_other_gh_kinds_unaffected_linked() {
    require_file "$GUARD_JS" "test_l3_45_issue_713_other_gh_kinds_unaffected_linked" || return
    local pair; pair="$(setup_linked_worktree "l3-45")"
    local wt="${pair#*|}"
    local cmd='gh pr merge 1 --squash'
    local out
    out="$(run_bash_guard "$cmd" "$wt" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L3.45 #713: gh pr merge from linked worktree: allowed (regression)"
    else
        fail "L3.45 #713: gh pr merge from linked worktree should allow (regression) ($out)"
    fi
}
