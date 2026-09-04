#!/usr/bin/env bash
# tests/lib/clearance-hook-harness.sh — shared runner + STRICT verdict classifier.
# Tests: hooks/block-clearance-token-write.js
# Tags: anti-cheat, off-clearance, clearance-token, harness, shared-lib, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap: none of its own — this is a library; the suites that source it carry theirs.
# WHY THIS EXISTS (CPR-SSOT): the parent suite and every section file under
# tests/enforce-clearance-token-write/ drive the SAME hook and need the SAME verdict
# contract, and their private copies drifted — "no block string in stdout" scored as
# approve, so a crash, a timeout or a garbled payload counted as a PASS. classify()
# settles it: approve requires rc=0 AND an explicit approve decision. Caller sets
# AGENTS_DIR, _AGENTS_DIR_NODE, RWT and HOOK before sourcing.

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'clearancehook'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

HOOK_PRESENT=no; [ -f "$HOOK" ] && HOOK_PRESENT=yes

# run_hook <tmp_node> <hook-input-json> -> "<rc>|<stdout, newlines stripped>"
# WORKFLOW_PLANS_DIR is dual-pinned with CLAUDE_WORKFLOW_DIR (rules/test/fixture-isolation.md)
# so nothing reaches the developer's real ~/.workflow-plans. stderr is dropped on
# purpose: a crash is caught by rc, never by eyeballing a stack trace.
run_hook() {
    local tn="$1" input="$2" out rc
    [ "$HOOK_PRESENT" = "yes" ] || { printf 'absent|'; return; }
    mkdir -p "$tn/plans" 2>/dev/null || true
    out=$(CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn/plans" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
        "$RWT" 12 node "$HOOK" <<< "$input" 2>/dev/null)
    rc=$?
    printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr -d '\r\n')"
}
# hook_rc / hook_out — split a run_hook result for callers asserting on the payload.
hook_rc()  { printf '%s' "${1%%|*}"; }
hook_out() { printf '%s' "${1#*|}"; }

mk_bash_input() { "$RWT" 8 node -e "process.stdout.write(JSON.stringify({tool_name:'Bash',session_id:'wsid',tool_input:{command:process.argv[1]}}))" "$1"; }
mk_file_input() { "$RWT" 8 node -e "process.stdout.write(JSON.stringify({tool_name:process.argv[1],session_id:'wsid',tool_input:{file_path:process.argv[2]}}))" "$1" "$2"; }
# Same Bash payload plus tool_input.cwd: dispatch forwards cwd into bashHitsProtected's
# opts.cwd, and a slash-less target only resolves to the workflow dir through it.
mk_bash_input_cwd() { "$RWT" 8 node -e "process.stdout.write(JSON.stringify({tool_name:'Bash',session_id:'wsid',tool_input:{command:process.argv[1],cwd:process.argv[2]}}))" "$1" "$2"; }

# classify "<rc>|<out>" -> approve|block|timeout|crash:<rc>|empty|unrecognized|hook-absent
classify() {
    local raw="$1" rc out
    rc="${raw%%|*}"; out="${raw#*|}"
    case "$rc" in
        absent) printf 'hook-absent'; return ;;
        124)    printf 'timeout'; return ;;
        0)      ;;
        *)      printf 'crash:%s' "$rc"; return ;;
    esac
    [ -z "$out" ] && { printf 'empty'; return; }
    case "$out" in
        *'"decision":"block"'*)   printf 'block'; return ;;
        *'"decision":"approve"'*) printf 'approve'; return ;;
    esac
    case "$out" in
        *'"permissionDecision":"allow"'*) printf 'approve'; return ;;
        *'"continue":true'*)              printf 'approve'; return ;;
    esac
    printf 'unrecognized'
}

# assert_verdict <label> <want> <raw "rc|out">
assert_verdict() {
    local label="$1" want="$2" raw="$3" got
    got="$(classify "$raw")"
    if [ "$got" = "$want" ]; then pass "$label -> $got"
    else fail "$label want=$want got=$got  [raw=$(printf '%.220s' "$raw")]"; fi
}
assert_block()   { assert_verdict "$1" block "$2"; }
assert_approve() { assert_verdict "$1" approve "$2"; }
