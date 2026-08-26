#!/bin/bash
# tests/feature-2099-complexity-stage-routing/path-charset-cases.sh
# Tests: bin/workflow/record-complexity-and-skip, bin/workflow/record-complexity-evaluation, bin/workflow/read-complexity-evaluation, bin/workflow/derive-complexity-level, hooks/workflow-state.js
# Tags: complexity, routing, cli, quoting, unicode, paths, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh AFTER
# traversal-attack-cases.sh — d2099t_snapshot and the canary tree come from there.
# The complement of that file: those paths are HOSTILE and must be refused; these
# are ORDINARY and must work. "C:/Users/Ana Lopez/プロジェクト (v2)" is a real home
# directory, and an unquoted "$dir" inside the CLI breaks it the same way it
# breaks an attack — but silently, as a wrong-directory write.
# lang-check: ignore -- fixture path deliberately uses a non-ASCII (Japanese) directory name

D2099PC_PARENT="$TMPDIR_BASE/charset-parent"

# One name carrying every class at once: space, non-ASCII (CJK + combining-prone
# Latin), and the metacharacters a shell would act on. `"` `\` `*` `?` `<` `>` `|`
# `:` are omitted — Windows rejects them in a filename, so a valid-path case
# cannot use them. The command substitutions are the execution canary: they name
# files that must never appear.
D2099PC_NAME='pc $(touch d2099pc-pwned-a) `touch d2099pc-pwned-b` ;touch d2099pc-pwned-c& 日本語 café (v2) '\''q'\'' #1'

# Every child process runs with BOTH dirs re-pinned (rules/test/fixture-isolation.md
# forbids pinning one alone) and nothing else changed.
d2099pc_run() {
    local wf="$1" pl="$2"
    shift 2
    (
        # Same cygpath -m requirement as the H-ENV cases: native-Windows node
        # misresolves an untranslated POSIX path against the wrong drive root.
        export CLAUDE_WORKFLOW_DIR="$(to_node_path "$wf")"
        export WORKFLOW_PLANS_DIR="$(to_node_path "$pl")"
        run_with_timeout "$@"
    )
}

d2099pc_new_session() {
    local wf="$1" pl="$2" sid="s2099-pc-$$-$RANDOM"
    BARREL="$BARREL_N" SID="$sid" d2099pc_run "$wf" "$pl" node -e '
const b = require(process.env.BARREL);
const sid = process.env.SID;
// writeState, not createInitialState alone: the latter is a pure constructor and
// materializes no file (state-io/core.js). Mirrors new_session (round-9 C3).
b.writeState(sid, b.createInitialState(sid));
' >/dev/null 2>&1 || true
    echo "$sid"
}

d2099pc_valid_path_roundtrip() {
    local wf pl sid out rc kids before_out after_out pwned state_files

    mkdir -p "$D2099PC_PARENT"
    if ! mkdir -p "$D2099PC_PARENT/$D2099PC_NAME/state" 2>/dev/null; then
        skip "PC-1 this filesystem refuses the mixed space/Unicode/metacharacter directory name, so the valid-path round trip cannot be staged here"
        return
    fi
    mkdir -p "$D2099PC_PARENT/$D2099PC_NAME/plans"
    wf="$D2099PC_PARENT/$D2099PC_NAME/state"
    pl="$D2099PC_PARENT/$D2099PC_NAME/plans"

    # Word-splitting canary: the parent holds EXACTLY one child. If any layer
    # splits the name on its spaces, the extra directories land right here.
    kids=$(find "$D2099PC_PARENT" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
    assert_eq "PC-1 the parent of the awkward directory has exactly one child before anything runs" "1" "$kids"

    before_out=$(d2099t_snapshot "$D2099T_OUTSIDE")
    sid=$(d2099pc_new_session "$wf" "$pl")

    # The wrapper first: it is the bash member of the family, so it is where an
    # unquoted expansion is most likely, and its answer is a whole-pipeline one.
    rc=0
    out=$(d2099pc_run "$wf" "$pl" "$(d2099_cli_runner "$BIN_RECORD_SKIP")" "$BIN_RECORD_SKIP" \
        --session "$sid" --signals "S2-architecture" --target outline 2>/dev/null) || rc=$?
    assert_eq "PC-2 record-complexity-and-skip resolves normally with a space/Unicode/metacharacter state dir" "judgment" "$out"
    assert_eq "PC-3 ... on a clean exit" "0" "$rc"

    # Read back through the OTHER entry point: written by the wrapper's delegate,
    # read by the reader, both resolving the same awkward path independently.
    out=$(d2099pc_run "$wf" "$pl" node "$BIN_READ" --session "$sid" --stage detail 2>/dev/null)
    assert_eq "PC-4 read-complexity-evaluation --stage returns the level that was persisted under that path" \
        "level=high" "$(printf '%s\n' "$out" | head -1)"
    assert_contains "PC-5 ... together with the signal list it was recorded with" "S2-architecture" "$out"

    out=$(d2099pc_run "$wf" "$pl" node "$BIN_DERIVE" --stage write_code --signals "S2-architecture" 2>/dev/null | head -1)
    assert_eq "PC-6 derive-complexity-level answers identically when launched from that environment" "level=high" "$out"

    # The record must live INSIDE the pinned dir, not in a truncated sibling that
    # a half-quoted path would produce.
    state_files=$(find "$wf" -type f -name '*.json' | wc -l | tr -d ' ')
    assert_eq "PC-7 the session's state file really is stored under the awkward directory" "1" "$state_files"

    kids=$(find "$D2099PC_PARENT" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
    assert_eq "PC-8 the whole round trip created nothing beside the awkward directory" "1" "$kids"

    # The metacharacters were data, not code: had any layer evaluated the name,
    # these files would exist somewhere under the fixture root.
    pwned=$(find "$TMPDIR_BASE" -name 'd2099pc-pwned-*' | head -5)
    assert_eq "PC-9 no command substitution embedded in the directory name was ever executed" "" "$pwned"

    after_out=$(d2099t_snapshot "$D2099T_OUTSIDE")
    assert_eq "PC-10 the out-of-tree canary is byte-identical after the round trip" "$before_out" "$after_out"
}

d2099pc_valid_path_roundtrip
