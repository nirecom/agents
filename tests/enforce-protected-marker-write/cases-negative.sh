#!/usr/bin/env bash
# Part of tests/enforce-protected-marker-write.sh (rules/coding/file-split.md).
# Section N - FALSE POSITIVES. The documentation and the skill that DESCRIBE the
# escape hatch must never be mistaken for the escape hatch itself.
#
# This is not a nicety. `rules/workflow-off.md` and `skills/enforce-workflow-off/`
# are the two files a session reads while deciding whether to use the sentinel, and
# `skills/enforce-workflow-off/` is where the sanctioned path is maintained. If the
# basename classifier or the interpreter MENTION gate treats them as protected,
# then reading the rule blocks, editing the skill blocks, and the only remaining
# way to make progress is to turn enforcement off wholesale - the guard would
# actively push sessions toward the bypass it exists to prevent (CPR-UO/CPR-E2E).
#
# Two distinct mechanisms must both stay clear, and they fail differently:
#   - the basename classifier: `workflow-off.md` ends in `.md`, so a suffix match
#     that is not anchored at the basename tail would hit it;
#   - the interpreter Tier-1 MENTION gate: it scans free command text for a
#     protected NAME, so an unanchored mention regex arms the fail-closed
#     interpreter path on any command line that merely names the rule file.

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
}
