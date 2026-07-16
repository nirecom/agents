#!/bin/bash
# Tests: bin/workflow/workflow-init-driver, bin/workflow/lib/workflow-init/phases/wip-check.js
# Tags: workflow-init, wip-check, driver, early-claim, clarify-intent, scope:issue-specific
#
# Feature 1117 — WIP check behavior in the workflow-init driver.
#
# The retired wip-set-resume.sh early-claim behavior (NEEDS_CLARIFY) has been
# absorbed into the driver's wip-check phase. The driver uses wip-state.sh
# directly (not wip-set-single.sh) and processes labels in route-decision (not
# wip-check). Tests here verify the driver's directive output for the key WIP
# scenarios that the old script covered.
#
# L3 gap (what these tests do NOT catch):
# - Whether the real Projects v2 API accepts the WIP claim
# - Whether wip-state.sh actually flips Status=In Progress in live GitHub
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER="$AGENTS_DIR/bin/workflow/workflow-init-driver"
TIMEOUT_WRAP="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$DRIVER" ]; then
    echo "FAIL: precondition — $DRIVER missing"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

to_native() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi
}

ROOT_TMP="$(to_native "$(mktemp -d)")"
trap 'rm -rf "$ROOT_TMP"' EXIT
ORIG_PATH="$PATH"
_CASE_N=0

setup_case() {
    SID="$1"
    _CASE_N=$((_CASE_N + 1))
    CASE_DIR="$ROOT_TMP/case-$_CASE_N"
    PLANS="$CASE_DIR/plans"
    CFG="$CASE_DIR/agents-config"
    MOCKBIN="$CASE_DIR/mock-bin"
    RESP="$CASE_DIR/gh-responses"
    WIPD="$CASE_DIR/wip"
    GH_LOG="$CASE_DIR/gh-calls.log"
    mkdir -p "$PLANS" "$MOCKBIN" "$RESP" "$WIPD" \
        "$CFG/bin/github-issues" "$CFG/hooks/lib" "$CFG/skills/workflow-init/scripts"
    _write_gh_mock
    _write_wip_mock
    _write_cfg_prims
    export WORKFLOW_PLANS_DIR="$PLANS"
    export AGENTS_CONFIG_DIR="$CFG"
    export CLAUDE_SESSION_ID="$SID"
    unset NON_GITHUB CLAUDE_ENV_FILE 2>/dev/null || true
    export PATH="$MOCKBIN:$ORIG_PATH"
}

teardown_case() {
    export PATH="$ORIG_PATH"
    unset WORKFLOW_PLANS_DIR AGENTS_CONFIG_DIR CLAUDE_SESSION_ID NON_GITHUB 2>/dev/null || true
}

_write_gh_mock() {
    cat > "$MOCKBIN/gh" <<MOCKGH1
#!/bin/bash
echo "\$*" >> "$GH_LOG"
RESP="$RESP"
MOCKGH1
    cat >> "$MOCKBIN/gh" <<'MOCKGH2'
cmd="${1:-}"; sub="${2:-}"
if [ "$cmd" = "issue" ] && [ "$sub" = "view" ]; then
    shift 2; N=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --repo|--json|--jq) if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
            -*) shift ;;
            *) [ -z "$N" ] && N="$1"; shift ;;
        esac
    done
    N="${N#\#}"
    rc=0; [ -f "$RESP/issue-view-$N.rc" ] && rc="$(cat "$RESP/issue-view-$N.rc")"
    if [ "$rc" != "0" ]; then echo "mock-gh: forced failure for issue $N" >&2; exit "$rc"; fi
    if [ -f "$RESP/issue-view-$N.json" ]; then cat "$RESP/issue-view-$N.json"; exit 0; fi
    echo "mock-gh: no fixture for issue $N" >&2; exit 1
fi
if [ "$cmd" = "issue" ] && [ "$sub" = "reopen" ]; then exit 0; fi
if [ "$cmd" = "repo" ] && [ "$sub" = "view" ]; then
    if printf '%s' "$*" | grep -q -- "--jq"; then echo "mockorg/mockrepo"
    else echo '{"nameWithOwner":"mockorg/mockrepo"}'; fi
    exit 0
fi
if [ "$cmd" = "api" ]; then echo "[]"; exit 0; fi
echo "mock-gh: unhandled args: $*" >&2
exit 1
MOCKGH2
    chmod +x "$MOCKBIN/gh"
}

_write_wip_mock() {
    cat > "$CFG/bin/github-issues/wip-state.sh" <<MOCKWIP1
#!/bin/bash
WIPD="$WIPD"
MOCKWIP1
    cat >> "$CFG/bin/github-issues/wip-state.sh" <<'MOCKWIP2'
VERB=""; N=""
while [ $# -gt 0 ]; do
    case "$1" in
        --session-id|--repo) if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
        -*) shift ;;
        *) if [ -z "$VERB" ]; then VERB="$1"; elif [ -z "$N" ]; then N="$1"; fi; shift ;;
    esac
done
N="${N#\#}"
echo "$VERB $N" >> "$WIPD/calls.log"
case "$VERB" in
    check)
        rc=0
        [ -f "$WIPD/check-rc" ] && rc="$(cat "$WIPD/check-rc")"
        [ -f "$WIPD/check-rc-$N" ] && rc="$(cat "$WIPD/check-rc-$N")"
        if [ "$rc" != "0" ]; then echo "wip-state mock: forced check error for #$N" >&2; exit "$rc"; fi
        if [ -f "$WIPD/state-$N" ]; then cat "$WIPD/state-$N"; else echo "none"; fi
        exit 0 ;;
    set)
        rc=0
        [ -f "$WIPD/set-rc" ] && rc="$(cat "$WIPD/set-rc")"
        [ -f "$WIPD/set-rc-$N" ] && rc="$(cat "$WIPD/set-rc-$N")"
        if [ "$rc" = "0" ]; then echo "same" > "$WIPD/state-$N"; fi
        exit "$rc" ;;
    clear|abandon) exit 0 ;;
esac
echo "wip-state mock: unhandled verb '$VERB'" >&2
exit 2
MOCKWIP2
    chmod +x "$CFG/bin/github-issues/wip-state.sh"
}

_write_cfg_prims() {
    printf '#!/bin/bash\necho "${CLAUDE_SESSION_ID:-mock-sid}"\n' > "$CFG/bin/resolve-session-id"
    cp "$AGENTS_DIR/bin/parse-issue-tokens" "$CFG/bin/parse-issue-tokens"
    cp "$AGENTS_DIR/hooks/lib/parse-closes-issues.js" "$CFG/hooks/lib/parse-closes-issues.js"
    cat > "$CFG/skills/workflow-init/scripts/filter-init-candidates.sh" <<'FILT'
#!/bin/bash
# Passthrough filter: emit every issue-number arg back as '#N'.
while [ $# -gt 0 ]; do
    case "$1" in
        --repo-map) if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
        -*) shift ;;
        *) echo "#${1#\#}"; shift ;;
    esac
done
exit 0
FILT
    chmod +x "$CFG/bin/resolve-session-id" "$CFG/bin/parse-issue-tokens" \
        "$CFG/skills/workflow-init/scripts/filter-init-candidates.sh"
}

mock_issue() {
    local n="$1" state="$2" labels_csv="${3:-}" labels="" l
    local IFS=','
    for l in $labels_csv; do labels="$labels{\"name\":\"$l\"},"; done
    labels="[${labels%,}]"
    printf '{"number":%s,"title":"Issue %s","body":"Body","labels":%s,"state":"%s","createdAt":"2026-07-01T00:00:00Z"}\n' \
        "$n" "$n" "$labels" "$state" > "$RESP/issue-view-$n.json"
}
set_wip() { echo "$2" > "$WIPD/state-$1"; }
set_wip_set_rc() { echo "$1" > "$WIPD/set-rc"; }
set_wip_check_rc() { echo "$1" > "$WIPD/check-rc"; }

run_driver() {
    local errf="$CASE_DIR/driver-stderr.log"
    DRIVER_OUT="$(cd "$CASE_DIR" && "$TIMEOUT_WRAP" 30 node "$DRIVER" "$@" 2>"$errf")"
    DRIVER_RC=$?
    DRIVER_ERR=""
    [ -f "$errf" ] && DRIVER_ERR="$(cat "$errf")"
    return 0
}

get_kv() {
    local key="$1" val
    val="$(printf '%s\n' "$DRIVER_OUT" | grep -m1 "^${key}=")" || { printf ''; return 1; }
    val="${val#"${key}"=}"
    val="${val%$'\r'}"
    case "$val" in \'*\') val="${val#\'}"; val="${val%\'}" ;; esac
    printf '%s' "$val"
}

wip_set_calls() {
    if [ -f "$WIPD/calls.log" ]; then grep '^set ' "$WIPD/calls.log" || true; else printf ''; fi
}

# WR-1: OPEN non-meta N lacking intent:clarified, wip=none →
#        driver sets WIP, force_path_b=true, ACTION=done PATH_DECISION=B
setup_case wr1
mock_issue 401 OPEN "type:task"
# wip=none (default) → driver will set wip → force_path_b=true → PATH_DECISION=B
run_driver '#401'
ACT="$(get_kv ACTION)" || true
PD="$(get_kv PATH_DECISION)" || true
if [ "$ACT" = "done" ] && [ "$PD" = "B" ] && wip_set_calls | grep -q '^set 401$'; then
    pass "WR-1: wip=none unclarified issue → wip set, force_path_b=true, PATH_DECISION=B"
else
    fail "WR-1: expected ACTION=done PATH_DECISION=B + set call; got ACT=$ACT PD=$PD calls=[$(wip_set_calls | tr '\n' ';')]"
fi
teardown_case

# WR-2: CLOSED issue, wip=same → ask_user closed_reopen_N
setup_case wr2
mock_issue 402 CLOSED "type:task"
set_wip 402 same
run_driver '#402'
ACT="$(get_kv ACTION)" || true
AID="$(get_kv ASK_ID)" || true
if [ "$ACT" = "ask_user" ] && [ "$AID" = "closed_reopen_402" ]; then
    pass "WR-2: CLOSED issue → ask_user closed_reopen_N"
else
    fail "WR-2: expected ask_user closed_reopen_402; got ACT=$ACT AID=$AID"
fi
teardown_case

# WR-3: wip-state check error → ask_user wip_error (graceful degradation)
setup_case wr3
mock_issue 403 OPEN "type:task"
set_wip_check_rc 1
run_driver '#403'
ACT="$(get_kv ACTION)" || true
AID="$(get_kv ASK_ID)" || true
if [ "$ACT" = "ask_user" ] && [ "$AID" = "wip_error" ]; then
    pass "WR-3: wip-state check error → ask_user wip_error"
else
    fail "WR-3: expected ask_user wip_error; got ACT=$ACT AID=$AID"
fi
teardown_case

# WR-4: meta issue, wip=same → PATH_DECISION=META (no sub-issues → META path)
setup_case wr4
mock_issue 404 OPEN "meta"
set_wip 404 same
run_driver '#404'
ACT="$(get_kv ACTION)" || true
PD="$(get_kv PATH_DECISION)" || true
if [ "$ACT" = "done" ] && [ "$PD" = "META" ]; then
    pass "WR-4: meta issue wip=same → PATH_DECISION=META (no WIP set re-attempt)"
else
    fail "WR-4: expected done PATH_DECISION=META; got ACT=$ACT PD=$PD"
fi
teardown_case

# WR-5: wip-state set rc=2 (wip=none path attempted) → ask_user wip_rc2
setup_case wr5
mock_issue 405 OPEN "type:task"
set_wip_set_rc 2
run_driver '#405'
ACT="$(get_kv ACTION)" || true
AID="$(get_kv ASK_ID)" || true
if [ "$ACT" = "ask_user" ] && [ "$AID" = "wip_rc2" ]; then
    pass "WR-5: wip-state set rc=2 → ask_user wip_rc2"
else
    fail "WR-5: expected ask_user wip_rc2; got ACT=$ACT AID=$AID"
fi
teardown_case

# WR-REG: all issues clarified (intent:clarified), wip=none → set called, ACTION=done
setup_case wr-reg
mock_issue 501 OPEN "type:task,intent:clarified"
mock_issue 502 OPEN "type:task,intent:clarified"
run_driver '#501' '#502'
ACT="$(get_kv ACTION)" || true
if [ "$ACT" = "done" ] && wip_set_calls | grep -q '^set 501$' && wip_set_calls | grep -q '^set 502$'; then
    pass "WR-REG: all clarified + wip=none → wip set for all, ACTION=done"
else
    fail "WR-REG: expected done + set calls for 501+502; got ACT=$ACT calls=[$(wip_set_calls | tr '\n' ';')]"
fi
teardown_case

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
