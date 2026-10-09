#!/bin/bash
# tests/hooks/fix-1630-script-checkout-root-resolver.sh
# Tests: hooks/lib/script-checkout-root.js, hooks/enforce-worktree/main-worktree-allows/worker-script.js, hooks/enforce-worktree/main-worktree-allows/standard.js, hooks/enforce-worktree.js
# Tags: hook, worktree, agents-main-root, resolver, enforce, security, scope:issue-specific
# Dispatcher; the case groups are the parts under fix-1630-script-checkout-root-resolver/.
# The resolver takes no environment candidate, so the parts drive five AGENTS_MAIN_ROOT
# states (valid, missing, stale, attacker, both-marker forged) through all three
# predicates that call it, next to the resolver's own units.
# TL3 gap (what this test does NOT catch): a real session that lost AGENTS_MAIN_ROOT, or whose agents main root moved mid-session.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration.
set -u

if ! command -v node >/dev/null 2>&1; then
    echo "SKIP: node not found"
    exit 77
fi
if ! command -v git >/dev/null 2>&1; then
    echo "SKIP: git not found"
    exit 77
fi

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

# Both workflow dirs are pinned here, before any function that runs a hook is defined.
TMPDIR_BASE="$(make_tmp)"; readonly TMPDIR_BASE
harness_isolate "$TMPDIR_BASE"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

SCRIPT_CHECKOUT_ROOT_NODE="$(np "$SCRIPT_CHECKOUT_ROOT")"
GUARD_JS="${SCRIPT_CHECKOUT_ROOT_NODE}/hooks/enforce-worktree.js"
PROBE_JS="${SCRIPT_CHECKOUT_ROOT_NODE}/tests/fixtures/script-checkout-root-probe.js"

norm() {
    np "$1"
}

_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# expect_eq <name> <got> <want> — named, unlike the harness's two-argument form.
expect_eq() {
    local name="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        pass "$name"
    else
        fail "$name" "want=$want got=$got"
    fi
}

for f in "$GUARD_JS" "$PROBE_JS"; do
    if [ ! -f "$f" ]; then
        fail "precondition missing" "$f"
        echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
        exit 1
    fi
done

# ── Synthetic repo fixture (main worktree + one linked worktree) ─────────────
REPO_RAW="$TMPDIR_BASE/repo"
mkdir -p "$REPO_RAW"
git -C "$REPO_RAW" init -q -b main
git -C "$REPO_RAW" config core.hooksPath /dev/null
git -C "$REPO_RAW" config user.email "test@example.com"
git -C "$REPO_RAW" config user.name "Test"
echo init > "$REPO_RAW/README.md"
git -C "$REPO_RAW" add README.md
git -C "$REPO_RAW" commit -q --no-verify -m initial
git -C "$REPO_RAW" worktree add -q -b feature/x "$REPO_RAW/.wt/x" >/dev/null
REPO="$(norm "$REPO_RAW")"

# A directory that looks like an agents main root path but carries neither marker.
STALE_RAW="$TMPDIR_BASE/stale-script-checkout-root"
mkdir -p "$STALE_RAW"
STALE="$(norm "$STALE_RAW")"

PLANS="$(norm "$WORKFLOW_PLANS_DIR")"

# Sanctioned script paths under the checkout this test runs from.
REAL_DISPATCH="$SCRIPT_CHECKOUT_ROOT_NODE/bin/github-issues/issue-create-dispatch.sh"
REAL_FSD="$SCRIPT_CHECKOUT_ROOT_NODE/skills/issue-close-finalize/scripts"

json_payload() {
    node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1]}}))' "$1"
}

# guard_exec <payload> [env assignments...] — the real hook, from the fixture's main
# worktree, with the root variables and the session id cleared unless a row sets them.
# stdout is the verdict; stderr goes to a file so it can never be read as one.
GUARD_ERR="$TMPDIR_BASE/guard.stderr"
guard_exec() {
    local payload="$1"; shift
    cd "$REPO_RAW" || return 3
    printf '%s' "$payload" | run_with_timeout 30 env -u AGENTS_MAIN_ROOT -u AGENTS_HOOK_DEBUG \
        -u CLAUDE_CODE_SESSION_ID "ENFORCE_WORKTREE=on" "CLAUDE_PROJECT_DIR=$REPO" \
        "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$REPO" "$@" node "$GUARD_JS" 2>"$GUARD_ERR"
}

# run_guard <command> [env assignments...] -> 0 ALLOW / 1 BLOCK / 2 CRASH / 3 NEITHER
# ALLOW is exactly what the hook's done() prints on allow: `{}` on stdout with exit 0.
# Exit 0 with any other stdout (an early silent exit included) is not an allow.
GUARD_OUT=""
run_guard() {
    local cmd="$1"; shift
    local payload rc=0
    payload="$(json_payload "$cmd")"
    GUARD_OUT="$(guard_exec "$payload" "$@")" || rc=$?
    if [ "$rc" -ne 0 ]; then
        return 2
    fi
    if [ "$GUARD_OUT" = "{}" ]; then
        return 0
    fi
    if printf '%s\n' "$GUARD_OUT" | grep -q '"decision":"block"'; then
        return 1
    fi
    return 3
}

assert_guard() {
    local label="$1" want="$2" cmd="$3"; shift 3
    local rc=0 got
    run_guard "$cmd" "$@" || rc=$?
    case "$rc" in
        0) got=allow ;;
        1) got=block ;;
        2) got="crash; out=$GUARD_OUT; err=$(head -c 200 "$GUARD_ERR" 2>/dev/null)" ;;
        *) got="neither {} nor a block; out=$GUARD_OUT; err=$(head -c 200 "$GUARD_ERR" 2>/dev/null)" ;;
    esac
    expect_eq "$label" "$got" "$want"
}

# probe <op> [args...] — AGENTS_MAIN_ROOT is whatever the caller's row set.
probe() {
    run_with_timeout 30 env -u AGENTS_HOOK_DEBUG node "$PROBE_JS" "$@" 2>&1
}

# probe_env <NAME=value | -u NAME>... -- <op> [args...] — env(1) wants every -u before
# the first assignment, so the two kinds are collected apart.
probe_env() {
    local opts=() sets=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
        if [ "$1" = "-u" ]; then
            opts+=("-u" "$2")
            shift 2
        else
            sets+=("$1")
            shift
        fi
    done
    shift
    run_with_timeout 30 env -u AGENTS_HOOK_DEBUG ${opts[@]+"${opts[@]}"} ${sets[@]+"${sets[@]}"} \
        node "$PROBE_JS" "$@" 2>&1
}

assert_probe() {
    local name="$1"; shift
    local want="${!#}"
    local args=("$@")
    unset 'args[${#args[@]}-1]'
    local got
    got="$(probe "${args[@]}")"
    expect_eq "$name" "$got" "$want"
}

# Table runner: columns  name|op|arg1|arg2|want. RUN_TABLE_ROWS is the number of rows
# it asserted, so a caller can tell a table that ran from one that silently ran short.
RUN_TABLE_ROWS=0
run_table() {
    local name op a1 a2 want
    RUN_TABLE_ROWS=0
    while IFS='|' read -r name op a1 a2 want; do
        name="$(_trim "$name")"
        if [ -z "$name" ] || [ "${name:0:1}" = "#" ]; then
            continue
        fi
        RUN_TABLE_ROWS=$((RUN_TABLE_ROWS + 1))
        assert_probe "$name" "$(_trim "$op")" "$(_trim "$a1")" "$(_trim "$a2")" "$(_trim "$want")"
    done
}

# shellcheck source=tests/hooks/fix-1630-script-checkout-root-resolver/seams.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/hooks/fix-1630-script-checkout-root-resolver/seams.sh"
# shellcheck source=tests/hooks/fix-1630-script-checkout-root-resolver/resolver-units.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/hooks/fix-1630-script-checkout-root-resolver/resolver-units.sh"
# shellcheck source=tests/hooks/fix-1630-script-checkout-root-resolver/standard-predicates.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/hooks/fix-1630-script-checkout-root-resolver/standard-predicates.sh"
# shellcheck source=tests/hooks/fix-1630-script-checkout-root-resolver/debug-and-cache.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/hooks/fix-1630-script-checkout-root-resolver/debug-and-cache.sh"

case_begin "hook-level-seams" "hooks/enforce-worktree.js"
run_seam_cases
case_end
case_begin "worker-predicate-env-states" "hooks/enforce-worktree/main-worktree-allows/worker-script.js"
run_worker_module_cases
case_end
case_begin "resolver-units" "hooks/lib/script-checkout-root.js"
run_resolver_unit_cases
case_end
case_begin "standard-predicates-env-states" "hooks/enforce-worktree/main-worktree-allows/standard.js"
run_standard_predicate_cases
case_end
case_begin "predicates-fail-closed-on-null" "hooks/enforce-worktree/main-worktree-allows/standard.js"
run_fail_closed_cases
case_end
case_begin "debug-line-and-cache-reset" "hooks/lib/script-checkout-root.js"
run_debug_and_cache_cases
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
