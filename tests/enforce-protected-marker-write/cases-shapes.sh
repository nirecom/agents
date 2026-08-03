#!/usr/bin/env bash
# Part of tests/enforce-protected-marker-write.sh (rules/coding/file-split.md).
# Sections S and R - the INPUT SHAPES a target path can arrive in.
#
# S (M-1): the Edit/Write/MultiEdit/editFiles family delivers its target in three
#   different payload keys depending on which client emits the tool call
#   (`file_path`, `path`, and per-edit `edits[].file_path` / `edits[].path`).
#   hooks/enforce-worktree/handle-edit-write.js already models all three, so a
#   guard that reads only `file_path` is bypassed by simply using a harness that
#   speaks one of the other two - no cleverness required. Each shape is asserted
#   INDEPENDENTLY (the protected path appears in that key and nowhere else) so a
#   regression in one cannot hide behind another key still carrying the value.
#
# R: Bash redirect targets that the static resolver CANNOT resolve. The resolver
#   returns "no targets" for those, which a naive caller reads as "nothing to
#   protect" - fail-OPEN on exactly the payloads an attacker controls. The rule
#   asserted here: an unresolvable target that LITERALLY spells a protected name
#   blocks; a genuinely dynamic target ($LOG, "$OUT", $TMPDIR/out.txt) does not.

# run_S_input_shapes - M-1
run_S_input_shapes() {
    local mk="$WFDIR/$SID.workflow-off"
    local tok="$WFDIR/$SID.off-clearance"

    # Shape 1: the conventional key.
    assert_block "S1 Edit file_path"   "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Edit  "$LINKED_WT" file_path "$mk")")"
    assert_block "S1 Write file_path"  "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Write "$LINKED_WT" file_path "$mk")")"

    # Shape 2: `path` only - `file_path` is absent from the payload entirely.
    assert_block "S2 Write path (no file_path key)"      "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Write "$LINKED_WT" path "$mk")")"
    assert_block "S2 Edit path (no file_path key)"       "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Edit  "$LINKED_WT" path "$mk")")"
    assert_block "S2 editFiles path -> token"           "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input editFiles "$LINKED_WT" path "$tok")")"

    # Shape 3: per-edit. The top-level file_path points at an INNOCENT file, so
    # only a guard that walks edits[] can see the protected target.
    assert_block "S3 MultiEdit edits[].file_path"        "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_edits_input MultiEdit "$LINKED_WT" file_path "$mk")")"
    assert_block "S3 MultiEdit edits[].path"             "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_edits_input MultiEdit "$LINKED_WT" path "$mk")")"
    assert_block "S3 editFiles edits[].file_path -> token" "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_edits_input editFiles "$LINKED_WT" file_path "$tok")")"

    # Control for S3: the same envelope with NO protected path anywhere must
    # pass, proving S3 blocks on the edits[] entry rather than on the shape.
    assert_approve "S4 MultiEdit edits[] with only innocent paths" \
        "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_edits_input MultiEdit "$LINKED_WT" file_path "$LINKED_WT/src/app.js")")"
}

# run_R_redirect - unresolvable-but-literal redirect targets
run_R_redirect() {
    local mk="$WFDIR/$SID.workflow-off"
    local tok="$WFDIR/$SID.off-clearance"

    # Literal spelling the static resolver cannot turn into a path (the `$DATA`
    # tail reads as an unset variable), yet the write lands on the real file.
    assert_block "R1 unresolvable redirect literally spelling a marker" \
        "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "echo x > $mk::\$DATA" "$LINKED_WT")")"
    assert_block "R1 unresolvable redirect literally spelling a token" \
        "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "echo x > $tok::\$DATA" "$LINKED_WT")")"
    # Append redirect is a write too - truncation is not the only forgery.
    assert_block "R2 append redirect '>>' onto a marker" \
        "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "echo x >> $mk" "$LINKED_WT")")"
    # Non-redirect writers that create/mutate a named file.
    assert_block "R3 tee onto a marker"  "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "echo x | tee $mk" "$LINKED_WT")")"
    assert_block "R3 cp onto a marker"   "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "cp /etc/hosts $mk" "$LINKED_WT")")"
    assert_block "R3 mv onto a marker"   "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "mv /tmp/a $mk" "$LINKED_WT")")"

    # --- CPR-5 counterpart: genuinely dynamic redirects stay approved --------
    # Blanket-blocking every unresolvable redirect would break ordinary logging.
    assert_approve "R4 dynamic redirect '> \$LOG'"            "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input 'echo x > $LOG' "$LINKED_WT")")"
    assert_approve "R4 dynamic redirect '> \"\$OUT\"'"        "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input 'echo x > "$OUT"' "$LINKED_WT")")"
    assert_approve "R4 dynamic redirect '> \$TMPDIR/out.txt'" "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input 'echo x > $TMPDIR/out.txt' "$LINKED_WT")")"
    assert_approve "R4 dynamic redirect '>> \${LOGDIR}/run.log'" "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input 'echo x >> ${LOGDIR}/run.log' "$LINKED_WT")")"

    # Interpreter route: a node one-liner writing the marker is not a redirect
    # at all, and must still be caught (defense against routing around Section R).
    assert_block "R5 interpreter one-liner writing a marker" \
        "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "node -e \"require('fs').writeFileSync('$mk','x')\"" "$LINKED_WT")")"
}
