#!/bin/bash
# I-series: integration invariants
# Tests: skills/worktree-end/SKILL.md, skills/worktree-end/scripts/detect-restart.sh
#
# (R/T renderer tests removed in #771; I3–I6 kept since they test SKILL.md
# structural invariants that are still relevant.)
#
# Sourced helpers: feature-405-final-report/helpers.sh

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

test_I3_skill_md_grep_invariant() {
    require_skill_md "I3_skill_md_grep_invariant" || return
    local count
    count="$(grep '^7\. \*\*Final report' "$SKILL_MD" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$count" = "0" ]; then
        pass "I3: SKILL.md Step 7 Final report heading correctly absent (moved to /session-close)"
    else
        fail "I3: expected 0 occurrences of '7. **Final report' (Step 7 removed in #608), got $count"
    fi
}

test_I4_skill_md_has_step_5_5() {
    require_skill_md "I4_skill_md_has_step_5_5" || return
    local ln8 ln9 ln10
    ln8="$(grep -n '^### Step WE-8' "$SKILL_MD" | head -1 | cut -d: -f1)"
    ln9="$(grep -n '^### Step WE-9' "$SKILL_MD" | head -1 | cut -d: -f1)"
    ln10="$(grep -n '^### Step WE-10' "$SKILL_MD" | head -1 | cut -d: -f1)"
    if [ -n "$ln8" ] && [ -n "$ln9" ] && [ -n "$ln10" ] \
       && [ "$ln8" -lt "$ln9" ] && [ "$ln9" -lt "$ln10" ]; then
        pass "I4: Step WE-9 (capture) sits between Step WE-8 (line $ln8) and Step WE-10 (line $ln10) at line $ln9"
    else
        fail "I4: ordering wrong (WE-8=$ln8 WE-9=$ln9 WE-10=$ln10)"
    fi
}

test_I5_no_eval_in_skill_md() {
    require_skill_md "I5_no_eval_in_skill_md" || return
    local ln9 ln10
    ln9="$(grep -n '^### Step WE-9'  "$SKILL_MD" | head -1 | cut -d: -f1)"
    ln10="$(grep -n '^### Step WE-10' "$SKILL_MD" | head -1 | cut -d: -f1)"
    if [ -z "$ln9" ] || [ -z "$ln10" ]; then
        fail "I5: could not locate Step WE-9 or Step WE-10 in SKILL.md"
        return
    fi
    local region
    region="$(awk -v a="$ln9" -v b="$ln10" 'NR>=a && NR<b' "$SKILL_MD")"
    if echo "$region" | grep -qE '\beval\b'; then
        fail "I5: Step WE-9 region contains 'eval' (unsafe pattern)"
    else
        pass "I5: no 'eval' in Step WE-9 region"
    fi
}

test_I6_backup_vars_defined_in_step5() {
    require_skill_md "I6_backup_vars_defined_in_step5" || return
    local ln8 ln9
    ln8="$(grep -n '^### Step WE-8' "$SKILL_MD" | head -1 | cut -d: -f1)"
    ln9="$(grep -n '^### Step WE-9' "$SKILL_MD" | head -1 | cut -d: -f1)"
    if [ -z "$ln8" ] || [ -z "$ln9" ]; then
        fail "I6: could not locate Step WE-8 or Step WE-9 in SKILL.md"
        return
    fi
    local region
    region="$(awk -v a="$ln8" -v b="$ln9" 'NR>=a && NR<b' "$SKILL_MD")"
    if echo "$region" | grep -qF "BACKUP_DIR=" \
       && echo "$region" | grep -qF "BACKUP_MANIFEST_PATH="; then
        pass "I6: Step WE-8 region defines BACKUP_DIR= and BACKUP_MANIFEST_PATH="
    else
        fail "I6: BACKUP_DIR= and/or BACKUP_MANIFEST_PATH= missing from Step WE-8 region"
    fi
}

# detect-restart.sh failsafe + rules-reason — still relevant; not touched by #771
test_I12_detect_restart_failsafe() {
    local detect_sh="$AGENTS_DIR/skills/worktree-end/scripts/detect-restart.sh"
    if [ ! -f "$detect_sh" ]; then
        skip "I12_detect_restart_failsafe (detect-restart.sh not found)"
        return
    fi
    local out
    out="$(run_with_timeout 30 bash -c 'unset AGENTS_CONFIG_DIR; PR_NUMBER="" bash "$1" ""' _ "$detect_sh" 2>/dev/null)"
    local lines; lines="$(printf '%s\n' "$out" | grep -cE '^(cc_restart|vscode_reload|installer_rerun|os_reboot)=not_required\|$')"
    if [ "$lines" = "4" ]; then
        pass "I12: detect-restart.sh fail-safe outputs all 4 categories as not_required|"
    else
        fail "I12: expected 4 not_required| lines, got $lines
$out"
    fi
}

_make_mock_gh() {
    local mock_dir="$1" body="$2"
    mkdir -p "$mock_dir"
    printf '#!/bin/bash\n%s\n' "$body" > "$mock_dir/gh"
    chmod +x "$mock_dir/gh"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$mock_dir"
    else
        printf '%s' "$mock_dir"
    fi
}

test_I13_detect_restart_rules_reason() {
    local detect_sh="$AGENTS_DIR/skills/worktree-end/scripts/detect-restart.sh"
    if [ ! -f "$detect_sh" ]; then
        skip "I13_detect_restart_rules_reason (detect-restart.sh not found)"
        return
    fi
    local mock_dir="$TMPDIR_BASE/mock-gh-i13"
    local mock_posix; mock_posix="$(_make_mock_gh "$mock_dir" 'echo "rules/workflow-off.md"')"

    local out
    out="$(run_with_timeout 30 \
           env PATH="$mock_posix:$PATH" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
           bash "$detect_sh" "999" 2>/dev/null)"

    if printf '%s\n' "$out" | grep -qF 'cc_restart=required|rules/ modified in PR (rules/ content loads into the effective CLAUDE.md ruleset)'; then
        pass "I13: detect-restart.sh rules/ file → cc_restart=required|rules/ modified in PR (rules/ content loads into the effective CLAUDE.md ruleset)"
    else
        fail "I13: expected 'cc_restart=required|rules/ modified in PR (rules/ content loads into the effective CLAUDE.md ruleset)', got:
$out"
    fi
}

test_I13b_detect_restart_rules_and_claude_priority() {
    local detect_sh="$AGENTS_DIR/skills/worktree-end/scripts/detect-restart.sh"
    if [ ! -f "$detect_sh" ]; then
        skip "I13b_detect_restart_rules_and_claude_priority (detect-restart.sh not found)"
        return
    fi
    local mock_dir="$TMPDIR_BASE/mock-gh-i13b"
    local mock_posix; mock_posix="$(_make_mock_gh "$mock_dir" 'printf "CLAUDE.md\nrules/workflow-off.md\n"')"

    local out
    out="$(run_with_timeout 30 \
           env PATH="$mock_posix:$PATH" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
           bash "$detect_sh" "999" 2>/dev/null)"

    if printf '%s\n' "$out" | grep -qF 'cc_restart=required|CLAUDE.md modified in PR'; then
        pass "I13b: CLAUDE.md + rules/ → CLAUDE.md arm takes priority"
    else
        fail "I13b: expected 'cc_restart=required|CLAUDE.md modified in PR', got:
$out"
    fi
}

test_I14_dispatcher_propagates_crashed_child_exit_code() {
    local dispatcher="$AGENTS_DIR/tests/feature-405-final-report.sh"
    if [ ! -f "$dispatcher" ]; then
        skip "I14_dispatcher_propagates_crashed_child_exit_code (dispatcher not found)"
        return
    fi

    local work_dir="$TMPDIR_BASE/i14-dispatcher"
    mkdir -p "$work_dir"

    # A synthetic child suite that crashes before printing any PASS:/FAIL:
    # lines (simulates a syntax error / missing dependency / uncaught throw).
    local crashing_child="$work_dir/crashing-child.sh"
    printf '#!/bin/bash\nexit 7\n' > "$crashing_child"
    chmod +x "$crashing_child"

    # Copy the real dispatcher and point its single run_sub call at the
    # crashing child, so the fix under test (run_sub's exit-code capture) is
    # exercised against the actual dispatcher source, not a reimplementation.
    local test_dispatcher="$work_dir/dispatcher.sh"
    awk -v child="$crashing_child" '
        /^run_sub "\$TESTS_DIR\/feature-405-final-report\// {
            if (!done) { print "run_sub \"" child "\""; done=1 }
            next
        }
        { print }
    ' "$dispatcher" > "$test_dispatcher"

    local out rc
    out="$(run_with_timeout 20 bash "$test_dispatcher" 2>&1)"
    rc=$?

    if [ "$rc" -eq 0 ]; then
        fail "I14: dispatcher exited 0 despite a crashing child (exit 7, no PASS:/FAIL: output) — false green; got:
$out"
        return
    fi
    if ! printf '%s\n' "$out" | grep -qF 'FAIL:'; then
        fail "I14: dispatcher exited nonzero ($rc) but printed no FAIL: line for the crashed child; got:
$out"
        return
    fi
    pass "I14: dispatcher exits nonzero and reports a FAIL: line when a child crashes with no output (rc=$rc)"
}

test_I11_skill_md_step5_5_node_json_write() {
    require_skill_md "I11_skill_md_step5_5_node_json_write" || return
    local region
    region="$(awk '/^### .*Step WE-11/{found=1;next} found{if(/^### /){exit}print}' "$SKILL_MD")"
    if [ -z "$region" ]; then
        skip "I11_skill_md_step5_5_node_json_write (Step WE-11 region not found)"
        return
    fi
    local has_capture=0 has_json=0
    if echo "$region" | grep -qF "capture-env.sh"; then has_capture=1; fi
    if echo "$region" | grep -qF "final-report-env.json"; then has_json=1; fi
    if [ "$has_capture" = "1" ] && [ "$has_json" = "1" ]; then
        pass "I11: SKILL.md Step WE-11 invokes capture-env.sh and references final-report-env.json"
    else
        fail "I11: Step WE-11 missing capture-env.sh(=$has_capture) or final-report-env.json(=$has_json)"
    fi
}

# ============ Run all ============

test_I3_skill_md_grep_invariant
test_I4_skill_md_has_step_5_5
test_I5_no_eval_in_skill_md
test_I6_backup_vars_defined_in_step5

test_I12_detect_restart_failsafe
test_I13_detect_restart_rules_reason
test_I13b_detect_restart_rules_and_claude_priority

test_I11_skill_md_step5_5_node_json_write
test_I14_dispatcher_propagates_crashed_child_exit_code

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $FAIL
