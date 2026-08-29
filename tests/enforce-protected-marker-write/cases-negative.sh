#!/usr/bin/env bash
# Tests: hooks/enforce-protected-marker-write.js, hooks/lib/protected-basenames.js
# Tags: protected-marker, workflow-off, false-positive, classifier, interpreter-gate, scope:issue-specific, pwsh-not-required
# Part of tests/enforce-protected-marker-write.sh (rules/coding/file-split.md).
# Section N - FALSE POSITIVES. The docs and the skill that DESCRIBE the escape hatch
# must never be mistaken for the hatch itself: blocking them would push sessions
# toward the very bypass this guard exists to prevent (CPR-UO/CPR-E2E). Two mechanisms
# must both stay clear, and they fail differently - the basename classifier (a suffix
# match not anchored at the basename tail hits `workflow-off.md`), and the interpreter
# Tier-1 MENTION gate (an unanchored mention regex arms the fail-closed interpreter
# path for any command line that merely names the rule file).

run_N_false_positive() {
    local rule="$LINKED_WT/rules/workflow-off.md"
    local skill="$LINKED_WT/skills/enforce-workflow-off/SKILL.md"
    local skillscript="$LINKED_WT/skills/enforce-workflow-off/scripts/run.sh"

    # --- the rule document ---------------------------------------------------
    assert_approve "N1 Edit rules/workflow-off.md"          "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Edit  "$LINKED_WT" file_path "$rule")")"
    assert_approve "N1 Write rules/workflow-off.md"         "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Write "$LINKED_WT" file_path "$rule")")"
    assert_approve "N1 MultiEdit edits[] rules/workflow-off.md" "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_edits_input MultiEdit "$LINKED_WT" file_path "$rule")")"
    assert_approve "N1 cat rules/workflow-off.md"           "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "cat rules/workflow-off.md" "$LINKED_WT")")"
    assert_approve "N1 grep rules/workflow-off.md"          "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "grep -n sentinel rules/workflow-off.md" "$LINKED_WT")")"
    # The mention gate specifically: an interpreter invocation whose body names
    # the RULE file must not be dragged into the fail-closed path.
    assert_approve "N2 node one-liner reading rules/workflow-off.md" \
        "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "node -e \"console.log(require('fs').readFileSync('rules/workflow-off.md','utf8'))\"" "$LINKED_WT")")"

    # --- the skill directory -------------------------------------------------
    assert_approve "N3 Edit skills/enforce-workflow-off/SKILL.md"  "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Edit "$LINKED_WT" file_path "$skill")")"
    assert_approve "N3 Write skills/enforce-workflow-off/scripts/run.sh" "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Write "$LINKED_WT" file_path "$skillscript")")"
    assert_approve "N3 sed -i on skills/enforce-workflow-off/SKILL.md" \
        "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "sed -i s/a/b/ skills/enforce-workflow-off/SKILL.md" "$LINKED_WT")")"
    assert_approve "N4 node one-liner reading skills/enforce-workflow-off/SKILL.md" \
        "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "node -e \"console.log(require('fs').readFileSync('skills/enforce-workflow-off/SKILL.md','utf8'))\"" "$LINKED_WT")")"

    # --- ordinary work in the worktree, and ordinary scratch writes ----------
    # The everyday case: if these ever block, the guard has stopped the session
    # from doing its job at all.
    assert_approve "N5 ordinary source edit"    "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Edit  "$LINKED_WT" file_path "$LINKED_WT/hooks/lib/session-markers.js")")"
    assert_approve "N5 ordinary source write"   "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Write "$LINKED_WT" file_path "$LINKED_WT/docs/history.md")")"
    assert_approve "N5 ordinary scratch write"  "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "echo hi > /tmp/scratch/notes.txt" "$LINKED_WT")")"
    assert_approve "N5 ordinary test run"       "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "bash tests/enforce-worktree.sh" "$LINKED_WT")")"

    # A file merely NAMED after a marker kind but not a session marker: the
    # protected form is `<sid>.<kind>`, so a plain `workflow-off.txt` note or a
    # `notes-workflow-off.md` write is ordinary content, not a clearance grant.
    assert_approve "N6 plain note file named workflow-off.txt" \
        "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Write "$LINKED_WT" file_path "$LINKED_WT/notes/workflow-off.txt")")"

    # N7 (#2108) - the same principle one step further: a basename that ENDS in a
    # protected kind but whose stem is not the session id. session-markers.js and
    # gh-env-state.js open exactly `<dir>/<sid>.<kind>`, so none of these names can
    # ever be read as clearance - yet the suffix-only classifier blocked all of them,
    # leaving a subagent with no legal filename for its survey artifact. The Edit/Write
    # spelling carries the stem verbatim, so exact matching is safe on this path.
    assert_approve "N7 survey artifact issue-2108-survey.gh-env" \
        "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Write "$LINKED_WT" file_path "$LINKED_WT/artifacts/issue-2108-survey.gh-env")")"
    assert_approve "N7 dated report report.2026-08-25.gh-env" \
        "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Write "$LINKED_WT" file_path "$LINKED_WT/artifacts/report.2026-08-25.gh-env")")"
    assert_approve "N7 dedupe artifact duplicate-check.gh-login" \
        "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Edit "$LINKED_WT" file_path "$LINKED_WT/artifacts/duplicate-check.gh-login")")"
    assert_approve "N7 snapshot-2026-08-25.gh-auth-dirty" \
        "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_edits_input MultiEdit "$LINKED_WT" file_path "$LINKED_WT/artifacts/snapshot-2026-08-25.gh-auth-dirty")")"
    assert_approve "N7 survey artifact issue-2108-survey.workflow-off" \
        "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Write "$LINKED_WT" file_path "$LINKED_WT/artifacts/issue-2108-survey.workflow-off")")"

    # N7 counterweight (CPR-ORTH): the real marker spelling must still block, or N7
    # would be passing because the guard stopped working rather than because it
    # learned the stem rule. `wsid` is the session id mk_tool_input embeds.
    assert_block "N7 counterweight: wsid.gh-env still blocks" \
        "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Write "$LINKED_WT" file_path "$LINKED_WT/artifacts/wsid.gh-env")")"
}
