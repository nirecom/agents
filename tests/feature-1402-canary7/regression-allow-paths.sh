#!/usr/bin/env bash
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/bash-write-scope.js, hooks/enforce-worktree/main-worktree-allows/new-item.js, hooks/enforce-worktree/main-worktree-allows/worktree-command.js, hooks/lib/claude-scratchpad-base.js
# Tags: scope:issue-specific, canary-7, ir-migration, enforce-worktree, regression, hook-registration, pwsh-not-required
#
# PR #1459 regression guard for the #1402 canary-7 IR migration.
# Asserts that the allow-paths regressed by #1420 (and restored by #1459) STILL
# work after the canary-7 retire: scratchpad writes, New-Item -ItemType Directory,
# and git worktree remove/prune must all be allowed from the main worktree.
#
# Also verifies that the new predicates do NOT over-block sanctioned commands:
# - isExtendedFileOpWriteIR must NOT fire for 'git worktree remove <path>'.
# - isEncodedCommandWriteIR must NOT fire for 'git worktree prune'.
#
# L3 gap (what this test does NOT catch):
# - Real enforce-worktree hook invocation via the live Claude Code PreToolUse chain
# - Session-scoped worktree path comparison in a real Claude session
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ── Fixtures: main repo, non-git CWD, session scratchpad ──
TMPBASE="$(run_with_timeout 30 node -e "
  var o=require('os'),p=require('path'),f=require('fs');
  var d=p.join(o.tmpdir(),'canary7-reg-'+process.pid);
  f.mkdirSync(d,{recursive:true});
  process.stdout.write(d);
" 2>/dev/null)"
[ -z "$TMPBASE" ] && { skip "could not create temp base"; report_totals; exit 0; }

MAIN_REPO="${TMPBASE}/repo"; mkdir -p "$MAIN_REPO"
git -C "$MAIN_REPO" init -q -b main
git -C "$MAIN_REPO" config user.email "test@example.com"
git -C "$MAIN_REPO" config user.name "Test"
git -C "$MAIN_REPO" config core.hooksPath /dev/null
echo "init" > "$MAIN_REPO/README.md"
git -C "$MAIN_REPO" add README.md
git -C "$MAIN_REPO" commit -q --no-verify -m "initial"

NONGIT_CWD="${TMPBASE}/nongit"; mkdir -p "$NONGIT_CWD"

if command -v cygpath >/dev/null 2>&1; then MAIN_REPO_NODE="$(cygpath -m "$MAIN_REPO")"; else MAIN_REPO_NODE="$MAIN_REPO"; fi

FAKE_SCRATCHPAD="$(run_with_timeout 30 node -e "
  var o=require('os'),p=require('path');
  process.stdout.write(p.join(o.tmpdir(),'claude','c--canary7','sess-canary7','scratchpad'));
" 2>/dev/null)"
mkdir -p "$FAKE_SCRATCHPAD" 2>/dev/null || true
if command -v cygpath >/dev/null 2>&1; then FAKE_SCRATCHPAD_NODE="$(cygpath -m "$FAKE_SCRATCHPAD")"; else FAKE_SCRATCHPAD_NODE="$FAKE_SCRATCHPAD"; fi
SCRATCH_FWD="${FAKE_SCRATCHPAD_NODE//\\//}"

EXT_WORKTREE_WIN="${TMPBASE}\\worktrees\\some-task"
EXT_WORKTREE="${TMPBASE}/worktrees/some-task"

cleanup() { rm -rf "$TMPBASE" "$FAKE_SCRATCHPAD" 2>/dev/null || true; }
trap cleanup EXIT

_make_payload() {
  run_with_timeout 30 node -e "
    var o={tool_name:'Bash',tool_input:{command:process.argv[1]},session_id:'canary7'};
    process.stdout.write(JSON.stringify(o));
  " -- "$1" 2>/dev/null
}

run_hook() {
  local cmd="$1"; shift; local p
  p="$(_make_payload "$cmd")"
  ( cd "$MAIN_REPO" || exit 1
    for _kv in "$@"; do export "$_kv"; done
    ENFORCE_WORKTREE=on AGENTS_CONFIG_DIR="$MAIN_REPO_NODE" CLAUDE_SESSION_ID=canary7 \
      MSYS_NO_PATHCONV=1 run_with_timeout 20 node "$GUARD_JS" <<< "$p" 2>/dev/null )
}
run_nongit() {
  local cmd="$1"; local p
  p="$(_make_payload "$cmd")"
  ( cd "$NONGIT_CWD" && ENFORCE_WORKTREE=on AGENTS_CONFIG_DIR="$NONGIT_CWD" \
      CLAUDE_SESSION_ID=canary7 MSYS_NO_PATHCONV=1 run_with_timeout 20 node "$GUARD_JS" <<< "$p" 2>/dev/null )
}
is_allow() { [ "$1" = "{}" ]; }

assert_allow() {
  local label="$1" got="$2"
  if is_allow "$got"; then pass "$label → allow"; else fail "$label → expected allow, got: $got"; fi
}

echo "=== RG: PR #1459 sanctioned allow paths still permitted after canary-7 ==="

# 1) Scratchpad redirect from a git-rooted CWD.
assert_allow "RG-scratchpad-redirect (git CWD)" \
  "$(run_hook "echo x > \"${SCRATCH_FWD}/x.md\"")"

# 1b) Scratchpad redirect from a NON-git CWD.
assert_allow "RG-scratchpad-nongit (non-git CWD)" \
  "$(run_nongit "echo x > \"${SCRATCH_FWD}/x.md\"")"

# 2) New-Item -ItemType Directory to an external path → allow.
assert_allow "RG-new-item-dir: New-Item -ItemType Directory -Force -Path <ext>" \
  "$(run_hook "New-Item -ItemType Directory -Force -Path \"${EXT_WORKTREE_WIN}\"")"

# 3) git worktree remove / prune from the main worktree → allow.
assert_allow "RG-worktree-remove: git worktree remove <ext>" \
  "$(run_hook "git worktree remove ${EXT_WORKTREE}")"
assert_allow "RG-worktree-prune: git worktree prune" \
  "$(run_hook "git worktree prune")"

echo "=== RG-FP: new predicates do NOT over-block sanctioned git commands ==="
# isExtendedFileOpWriteIR must return false for git worktree commands.
if file_op_module_present; then
  assert_eq "RG-FP-fileop-git-worktree-remove" "false" \
    "$(file_op_write_ir 'git worktree remove /path/to/wt')"
  assert_eq "RG-FP-fileop-git-worktree-prune" "false" \
    "$(file_op_write_ir 'git worktree prune')"
else
  skip "RG-FP-fileop: file-op.js not yet available (RED-pending)"
  skip "RG-FP-fileop: file-op.js not yet available (RED-pending)"
fi

# isEncodedCommandWriteIR must return false for git worktree commands.
if encoded_module_present; then
  assert_eq "RG-FP-encoded-git-worktree-remove" "false" \
    "$(encoded_write_ir 'git worktree remove /path/to/wt')"
  assert_eq "RG-FP-encoded-git-worktree-prune" "false" \
    "$(encoded_write_ir 'git worktree prune')"
else
  skip "RG-FP-encoded: encoded.js not yet available (RED-pending)"
  skip "RG-FP-encoded: encoded.js not yet available (RED-pending)"
fi

report_totals
exit "$FAIL"
