#!/bin/bash
# tests/lib/glossary-check-record.sh — sourced helper (#2529 T6-8).
# glossary_check_record <sid> <repo> [stage...]: runs the checkout's own
# `bin/check-glossary-drift --session <sid> --stage <stage> --record` against <repo>'s index for
# each R-S stage (default: tests code docs), as a session does before committing.
# The root comes from this file, never $AGENTS_MAIN_ROOT (a decoy under tests/lib/harness.sh).
# A failed record goes to stderr and never aborts the caller: the gate assertion that follows
# is the judge, where a record that did not land shows as a glossary-check-missing block.

GLOSSARY_CHECK_RECORD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

glossary_check_record() {
    local sid="$1" repo="$2"; shift 2
    local stages=("$@") stage rc
    [ "${#stages[@]}" -gt 0 ] || stages=(tests code docs)
    for stage in "${stages[@]}"; do
        rc=0
        (cd "$repo" && env CLAUDE_PROJECT_DIR="$repo" node "$GLOSSARY_CHECK_RECORD_ROOT/bin/check-glossary-drift" \
            --session "$sid" --stage "$stage" --record >/dev/null 2>&1) || rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "glossary_check_record: --stage $stage --record exited $rc (sid=$sid repo=$repo)" >&2
        fi
    done
    return 0
}
