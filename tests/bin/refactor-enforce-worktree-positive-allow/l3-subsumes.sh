
# ============================================================================
# L3 E2E — Subsumes scenarios (cases 31–35)
# ============================================================================

# Returns 0 when any file under $1 pairs ISSUE_CLOSE_SKILL=1 with a git add/commit/push.
# Catches the same-line form and `export ISSUE_CLOSE_SKILL=1` plus a git write on a later line.
l3_31_detect() {
    local dir="$1" f
    if grep -rE '^[^#]*ISSUE_CLOSE_SKILL=1[[:space:]]+git[[:space:]]+(add|commit|push)' "$dir" >/dev/null; then
        return 0
    fi
    while IFS= read -r f; do
        if awk '/^[^#]*ISSUE_CLOSE_SKILL=1/ {s=1} s && /^[^#]*(^|[^[:alnum:]_-])git([[:space:]]+-C[[:space:]]+("[^"]*"|\047[^\047]*\047|[^[:space:]]+))?[[:space:]]+(add|commit|push)([[:space:]]|$)/ {f=1} END {exit !f}' "$f"; then
            return 0
        fi
    done < <(find "$dir" -type f)
    return 1
}

# Runs in a subshell (own EXIT trap) so the file-wide TMPDIR_BASE trap is left intact.
# Prints "<fixture>=<hit|miss>" lines.
l3_31_fixture_verdicts() (
    readonly L3_31_ROOT="$(mktemp -d)"
    trap 'rm -rf "$L3_31_ROOT"' EXIT
    local name
    for name in a b c d e; do mkdir -p "$L3_31_ROOT/$name"; done
    printf '%s\n' '#!/bin/bash' 'export ISSUE_CLOSE_SKILL=1' 'echo prep' 'git -C "path with spaces" add .' > "$L3_31_ROOT/a/s.sh"
    printf '%s\n' '#!/bin/bash' 'ISSUE_CLOSE_SKILL=1 git commit -m x' > "$L3_31_ROOT/b/s.sh"
    printf '%s\n' '#!/bin/bash' 'export ISSUE_CLOSE_SKILL=1' 'echo prep' 'git push' > "$L3_31_ROOT/c/s.sh"
    printf '%s\n' '#!/bin/bash' 'git status' 'git log --oneline -3' > "$L3_31_ROOT/d/s.sh"
    printf '%s\n' '#!/bin/bash' 'git add .' > "$L3_31_ROOT/e/s.sh"
    for name in a b c d e; do
        if l3_31_detect "$L3_31_ROOT/$name"; then echo "$name=hit"; else echo "$name=miss"; fi
    done
)

test_l3_31_issue_672_step_e_no_local_git_writes() {
    # #672: no issue-close-finalize script (step-e.sh was split into scripts/) may issue
    # `ISSUE_CLOSE_SKILL=1 git add/commit/push`; it should call the Contents-API helper.
    require_file "$FINALIZE_SCRIPTS_DIR/run-finalize-terminal.sh" "test_l3_31_issue_672_step_e_no_local_git_writes" || return
    local l3_31_verdicts l3_31_pair l3_31_want
    l3_31_verdicts="$(l3_31_fixture_verdicts)"
    for l3_31_pair in a=hit b=hit c=hit d=miss e=miss; do
        l3_31_want="${l3_31_pair#*=}"
        if printf '%s\n' "$l3_31_verdicts" | grep -qx "$l3_31_pair"; then
            pass "L3.31 #672 detector fixture ${l3_31_pair%%=*}: $l3_31_want"
        else
            fail "L3.31 #672 detector fixture ${l3_31_pair%%=*}: expected $l3_31_want (verdicts: $(printf '%s' "$l3_31_verdicts" | tr '\n' ' '))"
        fi
    done
    local l3_31_hit=0
    if l3_31_detect "$FINALIZE_SCRIPTS_DIR"; then
        l3_31_hit=1
    fi
    if [ "$l3_31_hit" -eq 1 ]; then
        fail "L3.31 #672: issue-close-finalize scripts still issue 'ISSUE_CLOSE_SKILL=1 git add/commit/push' (refactor moves to Contents API)"
    else
        pass "L3.31 #672: issue-close-finalize scripts no longer issue local ISSUE_CLOSE_SKILL git writes"
    fi
}

test_l3_32_issue_713_issue_create_skill_no_main_worktree_abort() {
    # #713: /issue-create SKILL.md Step 0 main-worktree abort must be REMOVED.
    # After #713, /issue-create is callable from main worktree — no abort guard needed.
    require_file "$ISSUE_CREATE_SKILL" "test_l3_32_issue_713_issue_create_skill_no_main_worktree_abort" || return
    if grep -iE 'Step 0 — Main-worktree pre-flight|must be invoked from a linked worktree' "$ISSUE_CREATE_SKILL" >/dev/null; then
        fail "L3.32 #713: /issue-create SKILL.md still has main-worktree abort guard (Step 0 should be deleted)"
    else
        pass "L3.32 #713: /issue-create SKILL.md main-worktree abort removed"
    fi
}

test_l3_33_issue_527_gh_api_patch_refs_from_linked_worktree() {
    require_file "$GUARD_JS" "test_l3_33_issue_527_gh_api_patch_refs_from_linked_worktree" || return
    local pair; pair="$(setup_linked_worktree "l3-33")"
    local wt="${pair#*|}"
    local cmd='gh api -X PATCH repos/owner/demo/git/refs/heads/main -f sha=abc'
    local out
    out="$(run_bash_guard "$cmd" "$wt" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L3.33 #527: gh api PATCH git/refs from linked worktree: allowed"
    else
        fail "L3.33 #527: gh api PATCH refs from linked worktree: should allow ($out)"
    fi
}

test_l3_34_issue_419_write_tool_to_workflow_plans() {
    # #419: Write tool to ~/.workflow-plans/ (non-git path) must still be allowed.
    require_file "$GUARD_JS" "test_l3_34_issue_419_write_tool_to_workflow_plans" || return
    local p="$TMPDIR_BASE/workflow-plans-$$"
    mkdir -p "$p"
    local out
    out="$(run_edit_guard "Write" "$p/intent.md" "$TMPDIR_BASE" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L3.34 #419: Write to non-git ~/.workflow-plans path: allowed (fail-open)"
    else
        fail "L3.34 #419: Write to non-git path: should allow ($out)"
    fi
}

test_l3_35_issue_359_stderr_devnull_in_command_subst() {
    # #359: stderr-redirect-to-/dev/null inside command substitution should
    # not be flagged as a write target.
    require_file "$GUARD_JS" "test_l3_35_issue_359_stderr_devnull_in_command_subst" || return
    local pair; pair="$(setup_linked_worktree "l3-35")"
    local wt="${pair#*|}"
    # Inner 2>/dev/null inside a $() — this is a read-classified pattern.
    local cmd='OUT=$(git rev-parse HEAD 2>/dev/null)'
    local out
    out="$(run_bash_guard "$cmd" "$wt" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L3.35 #359: 2>/dev/null in \$() not flagged as write — allowed"
    else
        fail "L3.35 #359: 2>/dev/null inside cmd subst false-positive ($out)"
    fi
}
