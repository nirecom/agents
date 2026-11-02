#!/bin/bash
# tests/lib/glossary-check-record.sh — sourced helper (#2529 T6-8).
# glossary_check_record <sid> <repo> [step...]: runs the checkout's own
# `bin/check-glossary-drift --session <sid> --step <step> --record` against <repo>'s index for
# each R-S step (default: review_tests review_security review_docs), as a session does before committing.
# A legacy stage name argument (intent / tests / code / docs) is read as its step, so older callers keep working.
# The root comes from this file, never $AGENTS_MAIN_ROOT (a decoy under tests/lib/harness.sh).
# A failed record goes to stderr and never aborts the caller: the gate assertion that follows
# is the judge, where a record that did not land shows as a glossary-check-missing block.

GLOSSARY_CHECK_RECORD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

glossary_check_record() {
    local sid="$1" repo="$2"; shift 2
    local steps=("$@") step rc
    [ "${#steps[@]}" -gt 0 ] || steps=(review_tests review_security review_docs)
    for step in "${steps[@]}"; do
        case "$step" in
            intent) step=clarify_intent ;; tests) step=review_tests ;;
            code) step=review_security ;; docs) step=review_docs ;;
        esac
        rc=0
        (cd "$repo" && env CLAUDE_PROJECT_DIR="$repo" node "$GLOSSARY_CHECK_RECORD_ROOT/bin/check-glossary-drift" \
            --session "$sid" --step "$step" --record >/dev/null 2>&1) || rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "glossary_check_record: --step $step --record exited $rc (sid=$sid repo=$repo)" >&2
        fi
    done
    return 0
}
