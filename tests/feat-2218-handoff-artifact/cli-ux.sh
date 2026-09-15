# cli-ux.sh — H12-H17: handoff-append as a COMMAND. Sourced by the main file.
# Tests: bin/workflow/handoff-append
# Tags: handoff, handoff-artifact, cli-ux, discoverability, regression-2279, scope:issue-specific, pwsh-not-required, TL2

# rules/handoff-emergency-flush.md tells a context-pressured session to run this
# CLI with seven flags from memory. That session cannot afford to read the
# source, so the command must answer for itself: --help must work, and a
# rejection must name the field it rejected.

# _hoff <args...> — run the CLI against a private PLANS_DIR; sets HO_OUT/HO_ERR/HO_RC.
_hoff() {
    local tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    mkdir -p "$tmp/wf" "$tmp/home"
    HO_OUT=$(env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="h-cli" \
        CLAUDE_WORKFLOW_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" \
        HOME="$tn/home" USERPROFILE="$tn/home" \
        "$RWT" 60 node "$AGENTS_DIR/$CLI" "$@" 2>"$tmp/err")
    HO_RC=$?
    HO_ERR=$(cat "$tmp/err" 2>/dev/null || true)
    rm -rf "$tmp" 2>/dev/null || true
}

# H12 — --help. Every other CLI in bin/ answers it (resume-session-detect T20,
# adopt-session-state), so a user who learned the convention hits an error here
# for using it correctly (CPR-ORTH).
run_H12() {
    local problems=""
    _hoff --help
    [ "$HO_RC" -eq 0 ] || problems="$problems [exit $HO_RC, want 0]"
    case "$HO_OUT" in
        *[Uu]sage*) : ;;
        *) problems="$problems [stdout carries no usage line: '${HO_OUT:-<empty>}']" ;;
    esac
    case "$HO_ERR" in
        *"unknown argument"*) problems="$problems [--help is being parsed as an unknown argument]" ;;
    esac
    if [ -z "$problems" ]; then
        pass "H12: handoff-append --help prints usage on stdout and exits 0"
    else
        fail "H12: --help is not supported;$problems"
    fi
}

# H13 — -h, the same request spelled the other way. Split from H12 so a fix that
# wires only the long form is visible.
run_H13() {
    _hoff -h
    if [ "$HO_RC" -eq 0 ]; then
        case "$HO_OUT" in
            *[Uu]sage*) pass "H13: the short form -h prints usage and exits 0 too" ; return ;;
        esac
    fi
    fail "H13: -h exited $HO_RC with stdout '${HO_OUT:-<empty>}' / stderr '${HO_ERR:-<empty>}'"
}

# H14 — an unknown flag must say what IS accepted. Naming the offender alone
# leaves the caller guessing, which is the state a pressured session is in.
run_H14() {
    local problems=""
    _hoff --clas E --step write_tests --key k --summary s
    [ "$HO_RC" -ne 0 ] || problems="$problems [exit 0 for an unknown flag]"
    case "$HO_ERR" in
        *"--clas"*) : ;;
        *) problems="$problems [stderr does not quote the rejected flag]" ;;
    esac
    case "$HO_ERR$HO_OUT" in
        *"--class"*) : ;;
        *) problems="$problems [nothing tells the caller the accepted flags]" ;;
    esac
    if [ -z "$problems" ]; then
        pass "H14: an unknown flag is rejected with both the offender and the accepted flag list"
    else
        fail "H14: the unknown-flag error is not actionable;$problems"
    fi
}

# H15 — an out-of-vocabulary --class. One generic sentence covers the session id
# and all six entry fields today, so the caller cannot tell which one it is.
run_H15() {
    local problems=""
    _hoff --class Z --step write_tests --key k --summary s --pointer - --origin flush
    [ "$HO_RC" -ne 0 ] || problems="$problems [exit 0 for an out-of-vocabulary --class]"
    case "$HO_ERR" in
        *class*) : ;;
        *) problems="$problems [the rejection never names the class field: '$HO_ERR']" ;;
    esac
    if [ -z "$problems" ]; then
        pass "H15: an out-of-vocabulary --class is rejected with a message naming the class field"
    else
        fail "H15: the rejection does not say which field was wrong;$problems"
    fi
}

# H16 — the same for --origin (CPR-ORTH: two fields of one class, one treatment).
run_H16() {
    local problems=""
    _hoff --class A --step write_tests --key k --summary s --pointer - --origin not-an-origin
    [ "$HO_RC" -ne 0 ] || problems="$problems [exit 0 for an out-of-vocabulary --origin]"
    case "$HO_ERR" in
        *origin*) : ;;
        *) problems="$problems [the rejection never names the origin field: '$HO_ERR']" ;;
    esac
    if [ -z "$problems" ]; then
        pass "H16: an out-of-vocabulary --origin is rejected with a message naming the origin field"
    else
        fail "H16: the origin rejection is as opaque as the class one;$problems"
    fi
}

# H17 — the non-regression pair: a well-formed call still writes, and a flag
# given without a value still fails loudly. Any fix above must leave both alone.
run_H17() {
    local problems=""
    _hoff --class A --step write_tests --key k17 --summary "a summary" --pointer - --origin flush
    case "$HO_OUT" in
        *"WRITTEN=1"*) : ;;
        *) problems="$problems [a well-formed append printed '${HO_OUT:-<empty>}' (rc=$HO_RC, stderr='$HO_ERR')]" ;;
    esac
    _hoff --class
    [ "$HO_RC" -ne 0 ] || problems="$problems [a value-less --class exited 0]"
    case "$HO_ERR" in
        *"--class"*) : ;;
        *) problems="$problems [a value-less --class did not name the flag: '$HO_ERR']" ;;
    esac
    if [ -z "$problems" ]; then
        pass "H17: a well-formed append still writes, and a value-less flag still fails naming itself"
    else
        fail "H17: the CLI's working paths regressed;$problems"
    fi
}
