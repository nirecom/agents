#!/bin/bash
# Tests: hooks/enforce-worktree/main-worktree-allows/standard.js
# Tags: worktree, enforce, hook, shell-chaining, supervisor, scope:issue-specific
#
# Verifies that isAllowedWorktreeCommand allows sanctioned git-worktree commands
# followed by a safe `&& cd <path>` tail (NEW behaviour in fix #982/#1095),
# while remaining fail-closed for dangerous tails and multi-level chaining.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _SCRIPT_CHECKOUT_ROOT_NODE="$(cygpath -m "$SCRIPT_CHECKOUT_ROOT")"
else
    _SCRIPT_CHECKOUT_ROOT_NODE="$SCRIPT_CHECKOUT_ROOT"
fi
MODULE="${_SCRIPT_CHECKOUT_ROOT_NODE}/hooks/enforce-worktree/main-worktree-allows/standard.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

assert_fn_result() {
    local desc="$1" got="$2" expected="$3"
    if [ "$got" = "$expected" ]; then
        pass "$desc"
    else
        fail "$desc: expected '$expected', got '$got'"
    fi
}

# call_worktree_cmd CMD [REPO_ROOT]
# Calls isAllowedWorktreeCommand(cmd, repoRoot) and prints "true" or "false".
call_worktree_cmd() {
    local cmd="$1"
    local repo_root="${2:-/tmp/fake-repo}"
    run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        const r = m.isAllowedWorktreeCommand(process.argv[1], process.argv[2]);
        console.log(String(r));
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$cmd" "$repo_root" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# L3 gap: these tests call isAllowedWorktreeCommand directly (unit/L2). They do
# not test the full enforce-worktree hook pipeline (PreToolUse event, linked-
# worktree detection, config loading). An L3 test would issue a real
# `git worktree add ... && cd ...` Bash tool call inside a Claude Code session
# and observe whether the hook blocks or passes it through.
# ─────────────────────────────────────────────────────────────────────────────

test_worktree_chaining() {
    # NEW BEHAVIOR (will fail until standard.js isAllowedWorktreeCommand is fixed):
    # Sanctioned git-worktree command followed by `&& cd <path>` → allowed.
    assert_fn_result '"git worktree add /tmp/wt && cd /tmp/wt" → true' \
        "$(call_worktree_cmd 'git worktree add /tmp/wt && cd /tmp/wt')" \
        'true'

    # git -C path worktree prune followed by `&& cd <path>` → allowed (NEW).
    # Use _SCRIPT_CHECKOUT_ROOT_NODE so the path is consistent across shell and node argv
    # (POSIX fake paths like /main get Git Bash-converted when passed as shell args
    # to node.exe on Windows, causing a path-mismatch in the -C validation).
    assert_fn_result '"git -C <repo> worktree prune && cd <repo>" → true (with -C)' \
        "$(call_worktree_cmd "git -C ${_SCRIPT_CHECKOUT_ROOT_NODE} worktree prune && cd ${_SCRIPT_CHECKOUT_ROOT_NODE}" "${_SCRIPT_CHECKOUT_ROOT_NODE}")" \
        'true'

    # git -C path worktree remove followed by `&& cd <path>` → allowed (NEW).
    assert_fn_result '"git -C <repo> worktree remove /tmp/old && cd <repo>" → true (with -C)' \
        "$(call_worktree_cmd "git -C ${_SCRIPT_CHECKOUT_ROOT_NODE} worktree remove /tmp/old && cd ${_SCRIPT_CHECKOUT_ROOT_NODE}" "${_SCRIPT_CHECKOUT_ROOT_NODE}")" \
        'true'

    # FAIL-CLOSED: dangerous tail (rm -rf) after sanctioned command → false.
    assert_fn_result '"git worktree add /tmp/wt && rm -rf /other" → false' \
        "$(call_worktree_cmd 'git worktree add /tmp/wt && rm -rf /other')" \
        'false'

    # FAIL-CLOSED: multi-level && chain (three segments) → false.
    assert_fn_result '"git worktree add /tmp/wt && cd /tmp/wt && git push" → false' \
        "$(call_worktree_cmd 'git worktree add /tmp/wt && cd /tmp/wt && git push')" \
        'false'

    # ── codex C1 [HIGH]: command-substitution / unsafe `&& cd` tail vectors ──
    # The `&& cd <path>` separation must run the chaining/interpreter guards on
    # the tail so a hidden-exec payload inside the cd target is rejected.
    # These return false both NOW (whole-command chaining block) and AFTER fix
    # (tail guard rejects the substitution/extra chaining) — stable fail-closed.

    # cd target is a command substitution $(...) → false.
    assert_fn_result '"git -C /main worktree prune && cd \"\$(rm -rf x)\"" → false' \
        "$(call_worktree_cmd 'git -C /main worktree prune && cd "$(rm -rf x)"' '/main')" \
        'false'

    # tail is not cd-only (cd then a second && rm) → false.
    assert_fn_result '"git worktree add /tmp/wt && cd /tmp/wt && rm -rf x" → false' \
        "$(call_worktree_cmd 'git worktree add /tmp/wt && cd /tmp/wt && rm -rf x')" \
        'false'

    # cd target is a backtick command substitution → false.
    assert_fn_result '"git worktree prune && cd \`whoami\`" → false' \
        "$(call_worktree_cmd 'git worktree prune && cd `whoami`' '/main')" \
        'false'

    # EXISTING BEHAVIOR (must pass now and after fix):
    # Plain git worktree remove (no chaining) → true.
    assert_fn_result '"git worktree remove /tmp/wt" → true' \
        "$(call_worktree_cmd 'git worktree remove /tmp/wt')" \
        'true'

    # Plain git worktree prune (no chaining) → true.
    assert_fn_result '"git worktree prune" → true' \
        "$(call_worktree_cmd 'git worktree prune')" \
        'true'

    # Plain git worktree add (no chaining) → true (path outside repo: /tmp/wt vs /tmp/fake-repo).
    assert_fn_result '"git worktree add /tmp/wt" (plain) → true' \
        "$(call_worktree_cmd 'git worktree add /tmp/wt')" \
        'true'

    # EXISTING BEHAVIOR (must pass now and after fix):
    # git worktree remove --force → false (force-remove discards uncommitted work
    # in the target worktree; blocked by hasWorktreeRemoveForceFlag).
    assert_fn_result '"git worktree remove --force /tmp/wt" → false' \
        "$(call_worktree_cmd 'git worktree remove --force /tmp/wt')" \
        'false'

    # git worktree remove -f (short form) → false (same force-remove block).
    assert_fn_result '"git worktree remove -f /tmp/wt" → false' \
        "$(call_worktree_cmd 'git worktree remove -f /tmp/wt')" \
        'false'

    # git -C path worktree remove --force → false (force flag still blocked with -C).
    assert_fn_result '"git -C /main worktree remove --force /tmp/old" → false' \
        "$(call_worktree_cmd 'git -C /main worktree remove --force /tmp/old' '/main')" \
        'false'

    # isPathOutsideRepo guard: git worktree add target INSIDE repoRoot → false
    # (blocked; a nested checkout under the repo is not a sanctioned worktree add).
    # Relative paths are used so MSYS argv path-mangling does not rewrite them
    # inconsistently between the embedded command path and the repoRoot arg.
    assert_fn_result '"git worktree add repo-root/nested" (inside repo) → false' \
        "$(call_worktree_cmd 'git worktree add repo-root/nested' 'repo-root')" \
        'false'

    # isPathOutsideRepo guard: git worktree add target equal to repoRoot → false (blocked).
    assert_fn_result '"git worktree add repo-root" (equals repo) → false' \
        "$(call_worktree_cmd 'git worktree add repo-root' 'repo-root')" \
        'false'

    # isPathOutsideRepo guard: git worktree add target OUTSIDE repoRoot → true (allowed).
    assert_fn_result '"git worktree add other-wt" (outside repo) → true' \
        "$(call_worktree_cmd 'git worktree add other-wt' 'repo-root')" \
        'true'
}

test_worktree_chaining

# call_supervisor_bin CMD
# Calls isAllowedSupervisorBinTool(cmd) (same standard.js module) and prints "true"/"false".
call_supervisor_bin() {
    local cmd="$1"
    run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        console.log(String(m.isAllowedSupervisorBinTool(process.argv[1])));
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$cmd" 2>/dev/null
}

# ── #929 (R3-C4): supervisor-findings-codex allowlisted from the main worktree ──
# #2589: the allow takes only the literal root of the hook's own checkout (supervisor-bin.js);
# the variable form `$AGENTS_MAIN_ROOT/bin/...` is no longer a literal path and is refused.
test_supervisor_findings_codex_allowlist() {
    local sup="$_SCRIPT_CHECKOUT_ROOT_NODE/bin"
    assert_fn_result '"bash <root>/bin/supervisor-findings-codex --mode alert" → true' \
        "$(call_supervisor_bin "bash $sup/supervisor-findings-codex --mode alert")" \
        'true'
    assert_fn_result '"bash <root>/bin/supervisor-findings-codex --mode audit" → true' \
        "$(call_supervisor_bin "bash $sup/supervisor-findings-codex --mode audit")" \
        'true'

    # CPR-ORTH: supervisor-write-alert stays allowed in the same literal-root form.
    assert_fn_result '"bash <root>/bin/supervisor-write-alert --ingest-generated-jsonl ..." → true' \
        "$(call_supervisor_bin "bash $sup/supervisor-write-alert --ingest-generated-jsonl /tmp/x.jsonl")" \
        'true'

    # Guard stays armed: a redirect to a non-/tmp target is refused even with the literal root.
    assert_fn_result '"bash <root>/bin/supervisor-write-alert ... > /home/x" (non-/tmp redirect) → false' \
        "$(call_supervisor_bin "bash $sup/supervisor-write-alert --json > /home/x")" \
        'false'

    # The variable form is refused (argv[0] is not a literal path).
    assert_fn_result '"bash $AGENTS_MAIN_ROOT/bin/supervisor-findings-codex --mode alert" → false' \
        "$(call_supervisor_bin 'bash $AGENTS_MAIN_ROOT/bin/supervisor-findings-codex --mode alert')" \
        'false'
}

test_supervisor_findings_codex_allowlist

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
