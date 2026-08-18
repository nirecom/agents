#!/bin/bash
# tests/main-enforce-worktree-guard.sh
# Tests: hooks/enforce-worktree.js
# Tags: TL2, worktree, enforce, hook, bin, git, pre-commit, scope:common, enforce-worktree, workflow, supervisor, orphan-cwd, bash-c, fail-closed, context-populate, block-extras, axis-a, env, shell, windows, tests, merge, cross-repo, issue-525, feature-885
# Fragments in tests/main-enforce-worktree-guard/ are sourced into THIS shell,
# so every fragment-local name needs a short per-fragment prefix.
# TL3 gap: cases feed hand-built stdin to `node hooks/enforce-worktree.js`, so a
# dropped settings.json registration or a diverged host payload shape stays
# green. Covered elsewhere: tests/fix-1780-round4-write-tool-parity.sh section R
# (static registration) and bin/check-verification-gate.sh category
# hook-registration.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

to_node_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}

AGENTS_DIR_NODE="$(to_node_path "$AGENTS_DIR")"
GUARD_JS="${AGENTS_DIR_NODE}/hooks/enforce-worktree.js"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

require_guard() {
    if [ ! -f "$GUARD_JS" ]; then
        echo "SKIP: enforce-worktree.js not present at $GUARD_JS" >&2
        exit 77
    fi
}
require_guard

# rules/test/macos-timeout.md: `timeout` is absent on macOS.
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'mewg-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# rules/test/fixture-isolation.md: pin the workflow dir and the plans dir as a
# PAIR, or supervisor-emit.js resolves the developer's real ~/.workflow-plans/.
# Unset the inherited session ids for the same reason.
export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/workflow-plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

# ── decision helpers ────────────────────────────────────────────────────────
# Two-state: anything that is not an explicit block counts as allow. The one
# fragment that must distinguish a hook crash from an allow (repo-resolution)
# defines its own three-state variant.

guard_decision() {
    if echo "$1" | grep -q '"decision":"block"'; then return 1; fi
    return 0
}
guard_blocks() { ! guard_decision "$1"; }
guard_allows() { guard_decision "$1"; }

# assert_decision <allow|block> <guard-stdout> <pass-label> <fail-label>
# The fail branch appends " ($out)" — origin files interpolate the guard output
# into their FAIL text, and those strings are the case identifiers.
assert_decision() {
    local expect="$1" out="$2" pass_label="$3" fail_label="$4"
    if [ "$expect" = "allow" ]; then
        if guard_allows "$out"; then pass "$pass_label"; else fail "$fail_label ($out)"; fi
    else
        if guard_blocks "$out"; then pass "$pass_label"; else fail "$fail_label ($out)"; fi
    fi
}

# ── payload builders ────────────────────────────────────────────────────────
# The payload carries no `cwd` field on purpose: the hook resolves the repo
# from the real process CWD, so the runners below cd into it instead.

build_bash_payload() {
    node -e "
      const j = { session_id:'test', tool_name:'Bash', tool_input:{ command: process.argv[1] } };
      console.log(JSON.stringify(j));
    " -- "$1" 2>/dev/null
}

# build_guard_payload_write <session_id> <tool_name> <file_path>
build_guard_payload_write() {
    node -e "
      const j = { session_id: process.argv[1], tool_name: process.argv[2],
                  tool_input:{ file_path: process.argv[3], content:'x' } };
      console.log(JSON.stringify(j));
    " -- "$1" "$2" "$3" 2>/dev/null
}

# ── guard runners ───────────────────────────────────────────────────────────
# All take `cwd` plus trailing KEY=VAL pairs. ENFORCE_WORKTREE=on is applied
# first so a caller's own assignment for the same key wins (env: last wins).

run_guard_payload() {
    local payload="$1"; shift
    local cwd="$1"; shift
    if [ -n "$cwd" ]; then
        (cd "$cwd" && echo "$payload" | run_with_timeout 30 \
            env ENFORCE_WORKTREE=on "$@" node "$GUARD_JS" 2>/dev/null)
    else
        echo "$payload" | run_with_timeout 30 \
            env ENFORCE_WORKTREE=on "$@" node "$GUARD_JS" 2>/dev/null
    fi
}

run_bash_guard() {
    local cmd="$1"; shift
    run_guard_payload "$(build_bash_payload "$cmd")" "$@"
}

# Sanitized variant: an inherited ENFORCE_WORKTREE_* or session variable would
# change the very fail-closed default the orphan-cwd cases pin. The isolation
# pair is re-added on top of `env -i` because these cases all assert a block,
# and every block calls reportBlock() — with neither variable set the emitter
# reads "normal session", not "half-pinned test", and appends to the real
# ~/.workflow-plans/. enforce-worktree.js never reads either variable, so
# restoring them cannot move a decision. Both or neither: one alone trips the
# XOR guard (rules/test/fixture-isolation.md).
run_bash_guard_clean() {
    local cmd="$1"; shift
    local cwd="$1"; shift
    local payload; payload="$(build_bash_payload "$cmd")"
    (cd "$cwd" && echo "$payload" | run_with_timeout 30 \
        env -i "PATH=$PATH" "HOME=$HOME" \
        "CLAUDE_WORKFLOW_DIR=$CLAUDE_WORKFLOW_DIR" \
        "WORKFLOW_PLANS_DIR=$WORKFLOW_PLANS_DIR" \
        "$@" node "$GUARD_JS" 2>/dev/null)
}

run_edit_guard() {
    local fp="$1"; shift
    local payload
    payload="$(node -e "
      const j = { session_id:'test', tool_name:'Edit',
                  tool_input:{ file_path: process.argv[1], old_string:'x', new_string:'y' } };
      console.log(JSON.stringify(j));
    " -- "$fp" 2>/dev/null)"
    run_guard_payload "$payload" "$@"
}

run_write_guard() {
    local fp="$1"; shift
    run_guard_payload "$(build_guard_payload_write "test" "Write" "$fp")" "$@"
}

# edits_json is a JSON array of {file_path, old_string, new_string}.
run_multiedit_guard() {
    local edits_json="$1"; shift
    local payload
    payload="$(node -e "
      const edits = JSON.parse(process.argv[1]);
      const j = { session_id:'test', tool_name:'MultiEdit',
                  tool_input:{ file_path: (edits[0] && edits[0].file_path) || '', edits } };
      console.log(JSON.stringify(j));
    " -- "$edits_json" 2>/dev/null)"
    run_guard_payload "$payload" "$@"
}

# ── fixtures ────────────────────────────────────────────────────────────────
# TMPDIR_BASE already comes back from node in forward-slash form, so the RAW
# paths these return are Node-friendly as-is. Callers still wrap payload paths
# with to_node_path so the helpers stay correct on a mktemp -d fallback.

# core.hooksPath /dev/null: rules/test/fixture-isolation.md — otherwise the
# installed pre-commit hook fires inside the fixture.
make_git_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    git -C "$repo" commit -q --allow-empty -m "initial"
}

setup_main_checkout() {
    local repo="$TMPDIR_BASE/$1"
    make_git_repo "$repo"
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q --amend --no-edit
    echo "$repo"
}

# Echoes "<main_repo>|<wt_path>".
setup_linked_worktree() {
    local name="$1"
    local main; main="$(setup_main_checkout "$name-main")"
    local wt="$TMPDIR_BASE/$name-wt"
    git -C "$main" worktree add -q -b "feature/$name" "$wt" 2>/dev/null
    echo "$main|$wt"
}

# setup_repo_with_remote <name> [--no-upstream]
# A bare remote plus, by default, a tracking ref — the push-range cases need a
# resolvable <upstream>..HEAD; --no-upstream is the fail-closed fixture.
setup_repo_with_remote() {
    local name="$1" mode="${2:-}"
    local repo="$TMPDIR_BASE/$name"
    local bare="$TMPDIR_BASE/$name.git"
    make_git_repo "$repo"
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q --amend --no-edit
    mkdir -p "$bare"
    git -C "$bare" init -q --bare -b main
    git -C "$repo" remote add origin "$bare"
    # --no-upstream leaves the remote unpushed on purpose: with no tracking ref
    # the <upstream>..HEAD range is unresolvable, which is the fail-closed input.
    if [ "$mode" != "--no-upstream" ]; then
        git -C "$repo" push -q origin main >/dev/null 2>&1
        git -C "$repo" branch --set-upstream-to=origin/main main >/dev/null 2>&1 || true
    fi
    echo "$repo"
}

# The real main worktree of this repository — the target-extraction and
# block-reporting cases assert against a genuine main checkout, not a fixture.
main_worktree_dir() {
    git -C "$AGENTS_DIR" worktree list --porcelain 2>/dev/null \
        | awk '/^worktree /{print substr($0, 10); exit}'
}

BASELINE_REPO="$(setup_main_checkout "baseline")"
export BASELINE_REPO

# ── fragments ───────────────────────────────────────────────────────────────
FRAGMENT_DIR="$AGENTS_DIR/tests/main-enforce-worktree-guard"

# Completion ledger: every fragment's LAST line is `frag_done <its own basename>`.
# The `.` exit status cannot stand in for this — a bare `return` yields the status
# of the last command run, so a fragment that bails after its function definitions
# still sources "successfully" while its whole case family silently disappears.
FRAG_DONE=""
frag_done() { FRAG_DONE="${FRAG_DONE}$1
"; }

# shellcheck source=tests/main-enforce-worktree-guard/merge-gate.sh
. "$FRAGMENT_DIR/merge-gate.sh"
# shellcheck source=tests/main-enforce-worktree-guard/hooks-bypass-detection.sh
. "$FRAGMENT_DIR/hooks-bypass-detection.sh"
# shellcheck source=tests/main-enforce-worktree-guard/orphan-cwd-fail-closed.sh
. "$FRAGMENT_DIR/orphan-cwd-fail-closed.sh"
# shellcheck source=tests/main-enforce-worktree-guard/block-reporting.sh
. "$FRAGMENT_DIR/block-reporting.sh"
# shellcheck source=tests/main-enforce-worktree-guard/sanctioned-bypass.sh
. "$FRAGMENT_DIR/sanctioned-bypass.sh"
# shellcheck source=tests/main-enforce-worktree-guard/target-extraction.sh
. "$FRAGMENT_DIR/target-extraction.sh"
# shellcheck source=tests/main-enforce-worktree-guard/interpreter-readonly.sh
. "$FRAGMENT_DIR/interpreter-readonly.sh"
# shellcheck source=tests/main-enforce-worktree-guard/worktree-lifecycle.sh
. "$FRAGMENT_DIR/worktree-lifecycle.sh"
# shellcheck source=tests/main-enforce-worktree-guard/push-range-basic.sh
. "$FRAGMENT_DIR/push-range-basic.sh"
# shellcheck source=tests/main-enforce-worktree-guard/push-range-cross-repo.sh
. "$FRAGMENT_DIR/push-range-cross-repo.sh"
# shellcheck source=tests/main-enforce-worktree-guard/repo-resolution.sh
. "$FRAGMENT_DIR/repo-resolution.sh"
# shellcheck source=tests/main-enforce-worktree-guard/exclude-and-session-scope.sh
. "$FRAGMENT_DIR/exclude-and-session-scope.sh"

# ── fragment-set integrity ──────────────────────────────────────────────────
# The `. "$FRAGMENT_DIR/…"` lines above are the only wiring a fragment has, so a
# dropped line removes a whole behavioural family with the suite still green.
FRAG_PRESENT="$(ls -1 "$FRAGMENT_DIR" 2>/dev/null | grep '\.sh$' | sort)"
FRAG_SOURCED="$(sed -n 's|^\. "\$FRAGMENT_DIR/\(.*\.sh\)"$|\1|p' "${BASH_SOURCE[0]}" | sort)"

frag_only_in_first() {
    comm -23 <(printf '%s\n' "$1" | grep -v '^$') <(printf '%s\n' "$2" | grep -v '^$') \
        | tr '\n' ' ' | sed 's/ *$//'
}
FRAG_UNSOURCED="$(frag_only_in_first "$FRAG_PRESENT" "$FRAG_SOURCED")"
FRAG_ABSENT="$(frag_only_in_first "$FRAG_SOURCED" "$FRAG_PRESENT")"

if [ -z "$FRAG_UNSOURCED" ] && [ -z "$FRAG_ABSENT" ]; then
    pass "FRAG1 every fragment file is sourced and every sourced fragment exists"
else
    fail "FRAG1 fragment set mismatch — present-but-unsourced: [${FRAG_UNSOURCED:-none}] sourced-but-missing: [${FRAG_ABSENT:-none}]"
fi

# FRAG1 only proves the two NAME lists agree; it passes while a fragment returns
# early or fails to source. The ledger is what proves each one reached its end.
FRAG_DONE_SORTED="$(printf '%s' "$FRAG_DONE" | sort)"
FRAG_UNFINISHED="$(frag_only_in_first "$FRAG_SOURCED" "$FRAG_DONE_SORTED")"
FRAG_UNEXPECTED="$(frag_only_in_first "$FRAG_DONE_SORTED" "$FRAG_SOURCED")"

if [ -z "$FRAG_UNFINISHED" ] && [ -z "$FRAG_UNEXPECTED" ]; then
    pass "FRAG2 every sourced fragment ran through to its completion marker"
else
    fail "FRAG2 fragment completion mismatch — sourced-but-unfinished: [${FRAG_UNFINISHED:-none}] marked-but-not-sourced: [${FRAG_UNEXPECTED:-none}]"
fi

echo ""
# Deliberately not the `PASS: `/`FAIL: `/`SKIP: ` prefixes — those are reserved
# for case lines, and run-all's tallies would count this summary as three cases.
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
