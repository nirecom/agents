#!/usr/bin/env bash
# tests/feature-canary6a-pkgmgr-interpc/regression-allow-paths.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/bash-write-scope.js, hooks/enforce-worktree/main-worktree-allows/new-item.js, hooks/enforce-worktree/main-worktree-allows/worktree-command.js, hooks/lib/claude-scratchpad-base.js
# Tags: scope:issue-specific, pkg-mgr, interpreter-c, canary-6a, enforce-worktree, regression, hook-registration, pwsh-not-required
#
# PR #1459 regression guard for the #1411 pkg-mgr / interpreter-c IR migration.
# PR #1459 restored three sanctioned main-worktree allow paths that a prior IR
# migration (#1420) had regressed: scratchpad redirects, New-Item -ItemType
# Directory (external dir), and git worktree remove/prune. This part asserts those
# allow paths STILL work after the pkg-mgr / interpreter-c retire — i.e. adding the
# new predicates to the fast-allow gate must not re-block them. If a case goes RED,
# the pkg-mgr/interpreter-c wiring over-blocks a sanctioned command.
#
# L3 gap (what this test does NOT catch):
# - Real enforce-worktree hook invocation via the live Claude Code PreToolUse chain (these L2 cases drive node enforce-worktree.js via stdin JSON)
# - Session-scoped worktree path comparison in a real Claude session
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ── Fixtures (mirror fix-1441): main repo, non-git CWD, plans-dir, scratchpad ──
TMPBASE="$(run_with_timeout 30 node -e "var o=require('os'),p=require('path'),f=require('fs');var d=p.join(o.tmpdir(),'canary6a-reg-'+process.pid);f.mkdirSync(d,{recursive:true});process.stdout.write(d);" 2>/dev/null)"
[ -z "$TMPBASE" ] && { skip "could not create temp base"; report_totals; exit 0; }

MAIN_REPO="${TMPBASE}/repo"; mkdir -p "$MAIN_REPO"
git -C "$MAIN_REPO" init -q -b main
git -C "$MAIN_REPO" config user.email "test@example.com"
git -C "$MAIN_REPO" config user.name "Test"
git -C "$MAIN_REPO" config core.hooksPath /dev/null
echo "init" > "$MAIN_REPO/README.md"; git -C "$MAIN_REPO" add README.md; git -C "$MAIN_REPO" commit -q --no-verify -m "initial"

NONGIT_CWD="${TMPBASE}/nongit"; mkdir -p "$NONGIT_CWD"

if command -v cygpath >/dev/null 2>&1; then MAIN_REPO_NODE="$(cygpath -m "$MAIN_REPO")"; else MAIN_REPO_NODE="$MAIN_REPO"; fi

# Session scratchpad under <os-tmpdir>/claude/<slug>/<session-id>/scratchpad.
FAKE_SCRATCHPAD="$(run_with_timeout 30 node -e "var o=require('os'),p=require('path');process.stdout.write(p.join(o.tmpdir(),'claude','c--canary6a','sess-canary6a','scratchpad'));" 2>/dev/null)"
mkdir -p "$FAKE_SCRATCHPAD" 2>/dev/null || true
if command -v cygpath >/dev/null 2>&1; then FAKE_SCRATCHPAD_NODE="$(cygpath -m "$FAKE_SCRATCHPAD")"; else FAKE_SCRATCHPAD_NODE="$FAKE_SCRATCHPAD"; fi
SCRATCH_FWD="${FAKE_SCRATCHPAD_NODE//\\//}"

EXT_WORKTREE_WIN="${TMPBASE}\\worktrees\\some-task"
EXT_WORKTREE="${TMPBASE}/worktrees/some-task"

cleanup() { rm -rf "$TMPBASE" "$FAKE_SCRATCHPAD" 2>/dev/null || true; }
trap cleanup EXIT

_make_payload() { run_with_timeout 30 node -e "var o={tool_name:'Bash',tool_input:{command:process.argv[1]},session_id:'canary6a'};process.stdout.write(JSON.stringify(o));" -- "$1" 2>/dev/null; }
# run_hook <cmd> [ENV=val ...] → raw decision JSON (cwd = main repo).
run_hook() {
  local cmd="$1"; shift; local p; p="$(_make_payload "$cmd")"
  ( cd "$MAIN_REPO" || exit 1; for _kv in "$@"; do export "$_kv"; done
    ENFORCE_WORKTREE=on AGENTS_CONFIG_DIR="$MAIN_REPO_NODE" CLAUDE_SESSION_ID=canary6a MSYS_NO_PATHCONV=1 run_with_timeout 20 node "$GUARD_JS" <<< "$p" 2>/dev/null )
}
run_nongit() {
  local cmd="$1"; local p; p="$(_make_payload "$cmd")"
  ( cd "$NONGIT_CWD" && ENFORCE_WORKTREE=on AGENTS_CONFIG_DIR="$NONGIT_CWD" CLAUDE_SESSION_ID=canary6a MSYS_NO_PATHCONV=1 run_with_timeout 20 node "$GUARD_JS" <<< "$p" 2>/dev/null )
}
is_allow() { [ "$1" = "{}" ]; }

assert_allow() {
  local label="$1" got="$2"
  if is_allow "$got"; then pass "$label → allow"; else fail "$label → expected allow, got: $got"; fi
}

echo "=== RG: PR #1459 sanctioned allow paths still permitted after #1411 ==="

# 1) Scratchpad redirect from a git-rooted CWD (outside-session-scope + claude base).
assert_allow "RG-scratchpad-redirect: echo x > <scratchpad>/x.md (git CWD)" \
  "$(run_hook "echo x > \"${SCRATCH_FWD}/x.md\"")"

# 1b) Scratchpad redirect from a NON-git CWD (areAllBashTargetsUnderClaude path).
assert_allow "RG-scratchpad-nongit: echo x > <scratchpad>/x.md (non-git CWD)" \
  "$(run_nongit "echo x > \"${SCRATCH_FWD}/x.md\"")"

# 2) New-Item -ItemType Directory to an external (non-repo) path → allow.
assert_allow "RG-new-item-dir: New-Item -ItemType Directory -Force -Path <ext>" \
  "$(run_hook "New-Item -ItemType Directory -Force -Path \"${EXT_WORKTREE_WIN}\"")"

# 3) git worktree remove / prune from the main worktree → allow.
assert_allow "RG-worktree-remove: git worktree remove <ext>" \
  "$(run_hook "git worktree remove ${EXT_WORKTREE}")"
assert_allow "RG-worktree-prune: git worktree prune" \
  "$(run_hook "git worktree prune")"

report_totals
exit "$FAIL"
