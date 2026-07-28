#!/bin/bash
# tests/fix-1630-config-dir-resolver.sh
# Tests: hooks/lib/agents-config-dir.js, hooks/enforce-worktree/main-worktree-allows/worker-script.js, hooks/lib/load-env.js
# Tags: hook, worktree, config-dir, resolver, enforce, security, scope:issue-specific
#
# STATUS: RED until C4 lands (hooks/lib/agents-config-dir.js +
# worker-script.js switching from `process.env.AGENTS_CONFIG_DIR` to
# resolveAgentsConfigDir()).
#
# Dispatcher. Case groups live in tests/fix-1630-config-dir-resolver/:
#   seams.sh          — T4a stale AGENTS_CONFIG_DIR, T4b missing AGENTS_CONFIG_DIR
#   resolver-units.sh — T4c candidate ordering + 2-point marker validation via
#                       the _resolveFromCandidates seam with an injected existsSync
#   debug-and-cache.sh — AGENTS_HOOK_DEBUG fall-through message + _resetCacheForTest
#   standard-predicates.sh — the same four env states (valid/missing/stale/attacker)
#                       applied directly to isAllowedComposeDocAppend and
#                       isAllowedClarifyGuardLoop, so all three resolver call
#                       sites are covered symmetrically
#
# Why the seams are driven through the hook against a SYNTHETIC repo fixture
# rather than a bare `env -u AGENTS_CONFIG_DIR` run inside the real repo:
# a bare unset run cannot distinguish "the resolver worked" from "the value was
# never needed", because the module-relative fallback silently reaches the real
# checkout — the same caveat tests/fix-389-load-env-default-fallback.sh records
# at lines 85-86 ("existing repo .env may still be picked up via the
# file-relative fallback, so we only assert rc=0"). Pointing the sanctioned
# script paths at the REAL agents root while running the hook from a throwaway
# git repo makes the resolver's answer the only thing that can flip the verdict.
#
# TL3 gap (what this TL2 test does NOT catch):
# - a real Claude Code session whose environment genuinely lost
#   AGENTS_CONFIG_DIR (subagent / Bash-tool subprocess), reaching the hook via
#   the PreToolUse registration in settings.json
# - a real config dir that was moved or renamed on disk mid-session
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration.

set -u

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not found";  exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    AGENTS_DIR_NODE="$AGENTS_DIR"
fi
GUARD_JS="${AGENTS_DIR_NODE}/hooks/enforce-worktree.js"
PROBE_JS="${AGENTS_DIR_NODE}/tests/fixtures/agents-config-dir-probe.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

norm() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

assert_eq() {
    local name="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then pass "$name"
    else fail "$name (want=$want got=$got)"; fi
}

for f in "$GUARD_JS" "$PROBE_JS"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: precondition missing — $f"
        echo ""
        echo "Total: PASS=0 FAIL=1"
        exit 1
    fi
done

TMPDIR_BASE="$(mktemp -d 2>/dev/null || mktemp -d -t fix1630)"
trap 'rm -rf "$TMPDIR_BASE" 2>/dev/null' EXIT

# ── Synthetic repo fixture (main worktree + one linked worktree) ─────────────
REPO_RAW="$TMPDIR_BASE/repo"
mkdir -p "$REPO_RAW"
git -C "$REPO_RAW" init -q -b main
git -C "$REPO_RAW" config user.email "test@example.com"
git -C "$REPO_RAW" config user.name "Test"
git -C "$REPO_RAW" config core.hooksPath /dev/null
echo init > "$REPO_RAW/README.md"
git -C "$REPO_RAW" add README.md
git -C "$REPO_RAW" commit -q --no-verify -m initial
git -C "$REPO_RAW" worktree add -q -b feature/x "$REPO_RAW/.wt/x" >/dev/null
REPO="$(norm "$REPO_RAW")"

# A directory that LOOKS like a config dir path but carries neither marker.
STALE_RAW="$TMPDIR_BASE/stale-acd"
mkdir -p "$STALE_RAW"
STALE="$(norm "$STALE_RAW")"

PLANS_RAW="$TMPDIR_BASE/plans"
mkdir -p "$PLANS_RAW"
PLANS="$(norm "$PLANS_RAW")"

# Sanctioned script paths resolved against the REAL agents root — these are the
# paths the resolver must recover when the env var is stale or missing.
REAL_DISPATCH="$AGENTS_DIR_NODE/bin/github-issues/issue-create-dispatch.sh"
REAL_FSD="$AGENTS_DIR_NODE/skills/issue-close-finalize/scripts"

json_payload() {
    node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1]}}))' "$1"
}

# run_guard <command> [extra env assignments...] -> 0 ALLOW / 1 BLOCK / 2 CRASH
GUARD_OUT=""
run_guard() {
    local cmd="$1"; shift
    local payload rc=0
    payload="$(json_payload "$cmd")"
    GUARD_OUT="$(cd "$REPO_RAW" && printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE -u AGENTS_CONFIG_DIR \
        "ENFORCE_WORKTREE=on" \
        "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$REPO" \
        "WORKFLOW_PLANS_DIR=$PLANS" \
        "$@" \
        node "$GUARD_JS" 2>&1)" || rc=$?
    [ "$rc" -ne 0 ] && return 2
    echo "$GUARD_OUT" | grep -q '"decision":"block"' && return 1
    return 0
}

assert_guard() {
    local label="$1" want="$2" cmd="$3"; shift 3
    local rc=0
    run_guard "$cmd" "$@" || rc=$?
    case "$rc" in
        0) if [ "$want" = allow ]; then pass "$label"; else fail "$label (ALLOW — expected BLOCK)"; fi ;;
        1) if [ "$want" = block ]; then pass "$label"; else fail "$label (BLOCK — expected ALLOW)"; fi ;;
        *) fail "$label (CRASH; out=$GUARD_OUT)" ;;
    esac
}

probe() { run_with_timeout 30 node "$PROBE_JS" "$@" 2>&1; }

assert_probe() {
    local name="$1"; shift
    local want="${!#}"
    local args=("$@")
    unset 'args[${#args[@]}-1]'
    local got
    got="$(probe "${args[@]}")"
    assert_eq "$name" "$got" "$want"
}

# Table runner: columns  name|op|arg1|arg2|want
run_table() {
    local line name op a1 a2 want
    while IFS='|' read -r name op a1 a2 want; do
        name="$(_trim "$name")"
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        assert_probe "$name" "$(_trim "$op")" "$(_trim "$a1")" "$(_trim "$a2")" "$(_trim "$want")"
    done
}

# shellcheck source=tests/fix-1630-config-dir-resolver/seams.sh
. "$AGENTS_DIR/tests/fix-1630-config-dir-resolver/seams.sh"
# shellcheck source=tests/fix-1630-config-dir-resolver/resolver-units.sh
. "$AGENTS_DIR/tests/fix-1630-config-dir-resolver/resolver-units.sh"
# shellcheck source=tests/fix-1630-config-dir-resolver/standard-predicates.sh
. "$AGENTS_DIR/tests/fix-1630-config-dir-resolver/standard-predicates.sh"
# shellcheck source=tests/fix-1630-config-dir-resolver/debug-and-cache.sh
. "$AGENTS_DIR/tests/fix-1630-config-dir-resolver/debug-and-cache.sh"

run_seam_cases
run_resolver_unit_cases
run_standard_predicate_cases
run_debug_and_cache_cases

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
