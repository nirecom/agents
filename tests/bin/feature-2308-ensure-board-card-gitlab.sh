#!/usr/bin/env bash
# tests/bin/feature-2308-ensure-board-card-gitlab.sh
# Tests: bin/github-issues/ensure-board-card.sh
# Tags: scope:issue-specific, gitlab, forge, ensure-board-card, board-card, TL2, dup-group-keep:size-hard-limit
# Issue #2308 — the GitLab skip path of ensure-board-card.sh. GitLab Free has no
# Projects v2 board (status labels are the board, owned by wip-state.sh), so on a
# gitlab remote the script skips board-card creation cleanly (exit 0) BEFORE it
# touches gh, and attempts no `gh project` mutation. Own file because the natural
# target is over the 500-line HARD limit. Forge is forced via a fake
# bin/detect-forge-type CLI; gh is a logging mock so any gh call is observable.
set -u

# # TL3 gap (what this test does NOT catch):
# - Real `node bin/detect-forge-type` resolving a live gitlab origin.
# - Real `gh project` refusal — the mock only records that gh was never called.
# Closest mitigation: WORKFLOW_USER_VERIFIED preflight (skill-orchestration).

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EBC_SCRIPT="$AGENTS_DIR/bin/github-issues/ensure-board-card.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

# Existence gate.
if [ ! -f "$EBC_SCRIPT" ]; then
    echo "FAIL: precondition missing — bin/github-issues/ensure-board-card.sh"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

_OLDPATH="$PATH"

# Fake detect-forge-type CLI (invoked via `node <path>`, so no exec bit is
# needed), keyed by SHIM_FORGE so each case fixes the resolved forge. gh is a
# logging mock: every invocation is appended to GH_LOG.
setup_ebc() {
    EBCTMP="$(mktemp -d)"
    mkdir -p "$EBCTMP/bin" "$EBCTMP/mockbin"
    export AGENTS_CONFIG_DIR="$EBCTMP"
    cat > "$EBCTMP/bin/detect-forge-type" <<'NODE'
"use strict";
const argv = process.argv;
function arg(n){const i=argv.indexOf(n);return i>=0&&i+1<argv.length?argv[i+1]:null;}
const field = arg("--field");
if (field === "type") process.stdout.write((process.env.SHIM_FORGE || "") + "\n");
else if (field === "project") process.stdout.write((process.env.SHIM_PROJECT || "acme/widgets") + "\n");
else process.stdout.write("\n");
NODE
    export GH_LOG="$EBCTMP/gh.log"
    : > "$GH_LOG"
    cat > "$EBCTMP/mockbin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
    "auth status"*) echo "Token scopes: 'project'"; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$EBCTMP/mockbin/gh"
    export PATH="$EBCTMP/mockbin:$PATH"
}

teardown_ebc() {
    export PATH="$_OLDPATH"
    if [ -n "${EBCTMP:-}" ] && [ -d "$EBCTMP" ]; then rm -rf "$EBCTMP"; fi
    unset AGENTS_CONFIG_DIR GH_LOG SHIM_FORGE SHIM_PROJECT EBCTMP
}

# run_ebc <args...> : run the real script from a neutral CWD; captures stderr
# into EBC_ERR and returns the exit code.
run_ebc() {
    local rc
    ( cd "$EBCTMP" && run_with_timeout 20 bash "$EBC_SCRIPT" "$@" ) >/tmp/ebc_out.$$ 2>/tmp/ebc_err.$$
    rc=$?
    EBC_OUT=$(cat /tmp/ebc_out.$$ 2>/dev/null)
    EBC_ERR=$(cat /tmp/ebc_err.$$ 2>/dev/null)
    rm -f /tmp/ebc_out.$$ /tmp/ebc_err.$$
    return $rc
}

SKIP_MSG="GitLab has no Projects v2 board"

# E1: gitlab remote -> clean skip (exit 0), skip message on stderr, gh untouched.
setup_ebc
SHIM_FORGE=gitlab run_ebc 42; RC=$?
if [ "$RC" -eq 0 ] && echo "$EBC_ERR" | grep -qF "$SKIP_MSG" && [ ! -s "$GH_LOG" ]; then
    pass "E1: gitlab remote -> skip (exit 0), skip message, gh never called"
else
    fail "E1: gitlab skip path" "rc=$RC gh_log=[$(cat "$GH_LOG" 2>/dev/null)] err=$EBC_ERR"
fi
teardown_ebc

# E2: gitlab skip must not attempt a `gh project` mutation specifically — the
# CPR-ORTH board-mutation counterpart of E1's "gh never called".
setup_ebc
SHIM_FORGE=gitlab run_ebc 42 >/dev/null 2>&1
if ! grep -q 'project' "$GH_LOG" 2>/dev/null; then
    pass "E2: gitlab skip attempts no 'gh project' mutation"
else
    fail "E2: gh project mutation attempted on skip path" "gh_log=[$(cat "$GH_LOG" 2>/dev/null)]"
fi
teardown_ebc

# E3 (CPR-ORTH negative): github remote must NOT take the gitlab skip path —
# proves the skip message is gitlab-specific, not emitted unconditionally.
setup_ebc
SHIM_FORGE=github run_ebc 42; RC=$?
if ! echo "$EBC_ERR" | grep -qF "$SKIP_MSG"; then
    pass "E3: github remote does not emit the gitlab skip message"
else
    fail "E3: github remote wrongly took the gitlab skip path" "rc=$RC err=$EBC_ERR"
fi
teardown_ebc

# E4 (edge): unknown/empty forge -> not the gitlab skip path either.
setup_ebc
SHIM_FORGE='' run_ebc 42; RC=$?
if ! echo "$EBC_ERR" | grep -qF "$SKIP_MSG"; then
    pass "E4: unknown/empty forge does not emit the gitlab skip message"
else
    fail "E4: unknown forge wrongly took the gitlab skip path" "rc=$RC err=$EBC_ERR"
fi
teardown_ebc

# E5 (edge, usage error): non-numeric N -> exit 2 (usage), BEFORE forge detection.
setup_ebc
SHIM_FORGE=gitlab run_ebc "42; touch /tmp/EBC_INJECT" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 2 ] && [ ! -f /tmp/EBC_INJECT ]; then
    pass "E5: non-numeric N -> exit 2 (usage), no shell injection"
else
    fail "E5: usage guard" "rc=$RC inject=$([ -f /tmp/EBC_INJECT ] && echo yes || echo no)"
    rm -f /tmp/EBC_INJECT 2>/dev/null
fi
teardown_ebc

# E6 (edge, usage error): missing N -> exit 2 (usage).
setup_ebc
SHIM_FORGE=gitlab run_ebc >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 2 ]; then
    pass "E6: missing N -> exit 2 (usage)"
else
    fail "E6: missing N should exit 2" "rc=$RC"
fi
teardown_ebc

# E7 (idempotency): re-running the gitlab skip is a no-op — both runs exit 0,
# both emit the skip message, and gh is never called across either run.
setup_ebc
SHIM_FORGE=gitlab run_ebc 42; RC1=$?
SHIM_FORGE=gitlab run_ebc 42; RC2=$?
if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] && echo "$EBC_ERR" | grep -qF "$SKIP_MSG" && [ ! -s "$GH_LOG" ]; then
    pass "E7: repeated gitlab skip is idempotent (exit 0, no gh side effect)"
else
    fail "E7: idempotency" "rc1=$RC1 rc2=$RC2 gh_log=[$(cat "$GH_LOG" 2>/dev/null)]"
fi
teardown_ebc

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
