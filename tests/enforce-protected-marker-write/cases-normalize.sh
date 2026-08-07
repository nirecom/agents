#!/usr/bin/env bash
# Part of tests/enforce-protected-marker-write.sh (rules/coding/file-split.md).
# Sections G and A - basename NORMALIZATION bypasses.
#
# Both sections attack the same seam from opposite directions: the guard compares
# a candidate BASENAME against the protected suffix set, so any spelling that the
# SHELL or the FILESYSTEM resolves onto a protected name, but that a naive string
# compare does not, is a complete bypass of a single-file-existence authorization.
#
#   G (H-3, glob):  the shell expands `<sid>.workflow-o?f` onto the real marker
#                   before the write ever happens. The hook sees the unexpanded
#                   literal, so it must reason about what the pattern COULD match.
#   A (H-4, ADS):   NTFS resolves `<file>::$DATA` to <file>'s default stream, so a
#                   trailing stream spec is a no-op suffix that hides the basename.
#
# Each section carries its CPR-ORTH counterpart in the same run: over-blocking every
# `*` or every `:` would break ordinary bulk file operations and every Windows
# drive-letter path, which is a real defect of equal weight, not a safe default.

# run_G_glob - H-3
run_G_glob() {
    local wf="$WFDIR" p

    # --- positives: patterns that CAN expand onto a protected basename -------
    # `?` inside the marker kind, `?` eating the token's last character, a
    # bracket class spelling one of the token's own letters, and a trailing `*`.
    p="$wf/$SID.workflow-o?f"
    assert_block "G1 glob '?' inside marker kind (Bash)"  "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "printf 'x' > $p" "$LINKED_WT")")"
    assert_block "G1 glob '?' inside marker kind (Write)" "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Write "$LINKED_WT" file_path "$p")")"

    p="$wf/$SID.workflow-of*"
    assert_block "G2 glob trailing '*' on marker (Bash)"  "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "printf 'x' > $p" "$LINKED_WT")")"

    p="$wf/$SID.off-clearanc?"
    assert_block "G3 glob '?' as token tail (Bash)"       "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "printf 'x' > $p" "$LINKED_WT")")"
    assert_block "G3 glob '?' as token tail (Write)"      "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Write "$LINKED_WT" file_path "$p")")"

    p="$wf/$SID.off-cleara[n]ce"
    assert_block "G4 glob bracket class inside token (Bash)"  "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "printf 'x' > $p" "$LINKED_WT")")"
    assert_block "G4 glob bracket class inside token (Write)" "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Write "$LINKED_WT" file_path "$p")")"

    # Deletion counts as a write: removing a `.claimed` receipt re-enables a
    # spent clearance, so the glob spelling must be caught on `rm` too.
    p="$wf/$SID.off-clearance.claime?"
    assert_block "G5 glob '?' on a .claimed receipt (rm)" "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "rm -f $p" "$LINKED_WT")")"

    # --- CPR-ORTH counterpart: ordinary bulk globs must still be approved -------
    # If these block, the guard has made routine build/log housekeeping
    # impossible - an over-block is as much a defect as an under-block.
    assert_approve "G6 ordinary glob 'rm -rf build/*'"     "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "rm -rf build/*" "$LINKED_WT")")"
    assert_approve "G6 ordinary glob 'cp dist/* out/'"     "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "cp dist/* out/" "$LINKED_WT")")"
    assert_approve "G6 ordinary glob 'rm -rf logs/2024*'"  "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "rm -rf logs/2024*" "$LINKED_WT")")"
    # A literal bracket in a real filename must not be mistaken for a class
    # that could expand onto something protected.
    assert_approve "G7 literal bracket 'echo x > out[1].txt'" "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "echo x > out[1].txt" "$LINKED_WT")")"
    assert_approve "G7 literal bracket 'cp a.txt out[1].txt'" "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "cp a.txt out[1].txt" "$LINKED_WT")")"
    assert_approve "G7 literal bracket (Write out[1].txt)"    "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Write "$LINKED_WT" file_path "$LINKED_WT/out[1].txt")")"
}

# run_A_ads - H-4
run_A_ads() {
    local wf="$WFDIR" p

    # --- positives: a stream spec must not shield the base file -------------
    # `::$DATA` is the canonical default-stream spelling; `:$DATA` and a named
    # `:alt` stream are the same trick with fewer characters. On NTFS all three
    # still resolve to (or alongside) the protected file.
    p="$wf/$SID.off-clearance::\$DATA"
    assert_block "A1 ADS '::\$DATA' on token (Bash)"  "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "printf 'x' > $p" "$LINKED_WT")")"
    assert_block "A1 ADS '::\$DATA' on token (Write)" "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Write "$LINKED_WT" file_path "$p")")"

    p="$wf/$SID.workflow-off:\$DATA"
    assert_block "A2 ADS ':\$DATA' on marker (Bash)"  "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "printf 'x' > $p" "$LINKED_WT")")"
    assert_block "A2 ADS ':\$DATA' on marker (Write)" "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Write "$LINKED_WT" file_path "$p")")"

    p="$wf/$SID.workflow-off:alt"
    assert_block "A3 ADS named stream ':alt' on marker (Bash)"  "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "printf 'x' > $p" "$LINKED_WT")")"
    assert_block "A3 ADS named stream ':alt' on marker (Write)" "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Write "$LINKED_WT" file_path "$p")")"

    # Emergency-provenance marker gets the same treatment (CPR-ORTH: it is a
    # marker kind like any other, and forging it fakes user attribution).
    p="$wf/$SID.off-emergency-invoked::\$DATA"
    assert_block "A4 ADS on .off-emergency-invoked (Write)" "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Write "$LINKED_WT" file_path "$p")")"

    # --- CPR-ORTH counterpart: the colon must stay legal where it means a drive -
    # Stripping every `:`-suffix would eat Windows drive letters, i.e. every
    # absolute path on the primary platform of this repo.
    assert_approve "A5 bare drive letter 'C:' (Bash)"        "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "echo x > C:" "$LINKED_WT")")"
    assert_approve "A5 ordinary drive path (Bash)"           "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "echo x > C:/path/file.txt" "$LINKED_WT")")"
    assert_approve "A5 ordinary drive path (Write)"          "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Write "$LINKED_WT" file_path 'C:\path\file.txt')")"
    assert_approve "A5 ordinary drive path backslash (Bash)" "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input 'cp a.txt C:\\tmp\\file.txt' "$LINKED_WT")")"
}
