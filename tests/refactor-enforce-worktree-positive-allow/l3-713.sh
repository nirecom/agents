
# ============================================================================
# L3 — #713: /issue-create callable from main worktree (T1–T10)
# ============================================================================
#
# foldDqNewlines coverage note (Gap 6):
# foldDqNewlines is a private helper inside worker-script.js. It is exercised
# INDIRECTLY via isAllowedWorkerScriptInvocation in L3.46 (dispatch.sh with a
# real-newline DQ body — the embedded LF is folded so the command is still
# recognised as a sanctioned pattern) and in L3.48 (ANSI-C quoting with skill
# prefix). No dedicated foldDqNewlines unit test is needed; L3.46 and L3.48
# already provide the closest-to-action coverage for this helper.

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

test_l3_46_issue_1533_dispatch_multiline_body_allowed_from_main() {
    require_file "$GUARD_JS" "test_l3_46_issue_1533_dispatch_multiline_body_allowed_from_main" || return
    local repo; repo="$(setup_main_checkout "l3-46")"
    local body; body="$(printf 'line1\nrm -rf /\nline3')"
    local cmd; cmd="ISSUE_CREATE_SKILL=1 bash \"$AGENTS_DIR/bin/github-issues/issue-create-dispatch.sh\" --body \"$body\""
    local out
    out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on AGENTS_CONFIG_DIR="$AGENTS_DIR")"
    if guard_decision "$out"; then
        pass "L3.46 #1533: dispatch.sh with real-newline body + ISSUE_CREATE_SKILL=1 from main: allowed"
    else
        fail "L3.46 #1533: dispatch.sh with real-newline body false-positive — should allow ($out)"
    fi
}

test_l3_47_issue_1533_dispatch_command_substitution_blocked_from_main() {
    require_file "$GUARD_JS" "test_l3_47_issue_1533_dispatch_command_substitution_blocked_from_main" || return
    local repo; repo="$(setup_main_checkout "l3-47")"
    local cmd; cmd='ISSUE_CREATE_SKILL=1 bash "'"$AGENTS_DIR"'/bin/github-issues/issue-create-dispatch.sh" --body "$(rm -rf /tmp/testfile)"'
    local out
    out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on AGENTS_CONFIG_DIR="$AGENTS_DIR")"
    if guard_decision "$out"; then
        fail "L3.47 #1533 security: \$() in argTail should BLOCK (fail-closed) ($out)"
    else
        # N/A: hook が PreToolUse でブロックするためコマンドは実行されない。
        # ブロック判定自体が「保護されたリソースが変更されない」保証を完全に担保する。
        if echo "$out" | grep -qE 'isCommandSubstWriteIR|argTail|commandSubst|\$\(\)'; then
            pass "L3.47 #1533 security: \$() in dispatch.sh argTail blocked with commandSubst reason"
        else
            pass "L3.47 #1533 security: \$() in dispatch.sh argTail correctly blocked"
        fi
    fi
}

test_l3_48_issue_1457_ansi_c_quote_allowed_from_main() {
    require_file "$GUARD_JS" "test_l3_48_issue_1457_ansi_c_quote_allowed_from_main" || return
    local repo; repo="$(setup_main_checkout "l3-48")"
    local cmd
    cmd="ISSUE_CREATE_SKILL=1 gh issue create --title T --body \$'it'\\''s fine'"
    local out
    out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L3.48 #1457: ANSI-C quoting \$'...' with skill prefix from main: allowed"
    else
        fail "L3.48 #1457: ANSI-C quoting false-positive — should allow ($out)"
    fi
}

test_l3_49_issue_1449_run_quality_gates_allowed_from_main() {
    require_file "$GUARD_JS" "test_l3_49_issue_1449_run_quality_gates_allowed_from_main" || return
    local repo; repo="$(setup_main_checkout "l3-49")"
    local cmd; cmd="bash \"$AGENTS_DIR/skills/review-code-security/scripts/run-quality-gates.sh\""
    local out
    out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on AGENTS_CONFIG_DIR="$AGENTS_DIR")"
    if guard_decision "$out"; then
        pass "L3.49 #1449: run-quality-gates.sh from main: allowed"
    else
        fail "L3.49 #1449: run-quality-gates.sh false-positive — should allow ($out)"
    fi
}

test_l3_50_issue_1191_var_prefix_bash_dispatch_allowed_from_main() {
    require_file "$GUARD_JS" "test_l3_50_issue_1191_var_prefix_bash_dispatch_allowed_from_main" || return
    local repo; repo="$(setup_main_checkout "l3-50")"
    local cmd; cmd="ISSUE_CREATE_SKILL=1 bash \"$AGENTS_DIR/bin/github-issues/issue-create-dispatch.sh\""
    local out
    out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on AGENTS_CONFIG_DIR="$AGENTS_DIR")"
    if guard_decision "$out"; then
        pass "L3.50 #1191: VAR=val prefix + bash dispatch.sh from main: allowed"
    else
        fail "L3.50 #1191: VAR=val prefix + bash dispatch.sh false-positive — should allow ($out)"
    fi
}

test_l3_51_issue_1385_bash_c_readonly_workflow_allowed_from_main() {
    require_file "$GUARD_JS" "test_l3_51_issue_1385_bash_c_readonly_workflow_allowed_from_main" || return
    local repo; repo="$(setup_main_checkout "l3-51")"
    local cmd; cmd="bash -c 'node \"$AGENTS_DIR/bin/workflow/read-complexity-evaluation\" --session sid'"
    local out
    out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on AGENTS_CONFIG_DIR="$AGENTS_DIR")"
    if guard_decision "$out"; then
        pass "L3.51 #1385: bash -c read-only workflow CLI from main: allowed"
    else
        fail "L3.51 #1385: bash -c read-only workflow CLI false-positive — should allow ($out)"
    fi
}

test_l3_52_issue_1385_bash_c_write_body_blocked_from_main() {
    require_file "$GUARD_JS" "test_l3_52_issue_1385_bash_c_write_body_blocked_from_main" || return
    local repo; repo="$(setup_main_checkout "l3-52")"
    local cmd; cmd="bash -c 'node \"$AGENTS_DIR/bin/workflow/read-complexity-evaluation\" && rm -rf /tmp/testfile'"
    local out
    out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on AGENTS_CONFIG_DIR="$AGENTS_DIR")"
    if guard_decision "$out"; then
        fail "L3.52 #1385 security: bash -c with write body should BLOCK (fail-closed) ($out)"
    else
        # N/A: hook が PreToolUse でブロックするためコマンドは実行されない。
        # ブロック判定自体が「保護されたリソースが変更されない」保証を完全に担保する。
        if echo "$out" | grep -qE 'isInterpreterCWriteIR|chaining|write'; then
            pass "L3.52 #1385 security: bash -c with && write body blocked with interpreter-C reason"
        else
            pass "L3.52 #1385 security: bash -c with && write body correctly blocked"
        fi
    fi
}
