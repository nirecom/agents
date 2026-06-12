#!/bin/bash
# tests/fix-issue-739-enforce-worktree-sequenced-exclude.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/bash-write-scope.js, hooks/lib/bash-write-targets.js, hooks/lib/shell-segments.js
# Tags: worktree, enforce, hook, sequenced, backup, parsefailure, security
#
# Tests the sequenced-command exclusion fix for enforce-worktree (#739):
#   Gap 1: in sequenced commands (cmd1 && cmd2 / cmd1; cmd2), every WRITE segment
#          whose target matches BUILTIN_EXCLUDE_PATTERNS (.worktree-backup/**) must
#          be allowed even though earlier read-classified segments (e.g. mkdir) are
#          "transparent" in the existing fold logic.
#   Gap 2: `extractCpMvDestination` must resolve inline env-prefix assignments
#          (e.g. `BACKUP_DIR=... cp ... "$BACKUP_DIR/x"`) before glob-matching.
#
# Cases R2, R2a, R7 are expected to FAIL before the source fix is applied.
# All other cases must PASS now and after the fix.
#
# L3 gap (what this test does NOT catch):
# - real Claude Code session where enforce-worktree.js runs as PreToolUse hook
# - actual worktree-backup-worker subagent issuing mkdir+cp commands end-to-end
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
HOOK_SCRIPT="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm '"$1"'; exec @ARGV' -- "${@:2}"; fi
}

TMPDIR_BASE="$(mktemp -d 2>/dev/null || mktemp -d -t i739test)"
trap 'rm -rf "$TMPDIR_BASE" 2>/dev/null' EXIT

# Set up a minimal git repo (main worktree, no linked worktrees)
REPO="$TMPDIR_BASE/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"
git -C "$REPO" config core.hooksPath /dev/null
git -C "$REPO" commit --allow-empty --no-verify -q -m init
if command -v cygpath >/dev/null 2>&1; then REPO_N="$(cygpath -m "$REPO")"; else REPO_N="$REPO"; fi

# Pre-create the backup directory so R1 reflects a realistic existing-dir scenario.
mkdir -p "$REPO/.worktree-backup/branch"

# A source file outside the repo (cp source)
SRC_FILE="$TMPDIR_BASE/src.md"
echo "hello" > "$SRC_FILE"
if command -v cygpath >/dev/null 2>&1; then SRC_N="$(cygpath -m "$SRC_FILE")"; else SRC_N="$SRC_FILE"; fi

run_hook() {
    local payload="$1" cwd="$2"
    (cd "$cwd" && printf '%s' "$payload" | run_with_timeout 30 node "$HOOK_SCRIPT" 2>&1)
}

hook_payload_bash() {
    local cmd="$1"
    node -e "
      const c = process.argv[1];
      console.log(JSON.stringify({tool_name:'Bash', tool_input:{command:c}}));
    " -- "$cmd"
}

# ─────────────────────────────────────────────────────────────────────────────
# R1 — bare cp to existing .worktree-backup/ dir (regression guard for
#       BUILTIN_EXCLUDE_PATTERNS path). Should PASS before and after fix.
# ─────────────────────────────────────────────────────────────────────────────
R1_CMD="cp ${SRC_N} ${REPO_N}/.worktree-backup/branch/file"
payload="$(hook_payload_bash "$R1_CMD")"
out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$REPO_N")"
case "$out" in
    *'"decision":"block"'*) fail "R1 bare cp to .worktree-backup/ expected ALLOW; got: $out" ;;
    *) pass "R1 bare cp to .worktree-backup/ → ALLOW" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# R2 — mkdir -p && cp into .worktree-backup/ (Gap 1).
#       expected to FAIL before fix
# ─────────────────────────────────────────────────────────────────────────────
R2_CMD="mkdir -p ${REPO_N}/.worktree-backup/branch && cp ${SRC_N} ${REPO_N}/.worktree-backup/branch/file"
payload="$(hook_payload_bash "$R2_CMD")"
out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$REPO_N")"
case "$out" in
    *'"decision":"block"'*) fail "R2 mkdir && cp to .worktree-backup/ expected ALLOW; got block (fix not yet applied)" ;;
    *) pass "R2 mkdir && cp to .worktree-backup/ → ALLOW" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# R2a — same as R2 but with ';' separator (Gap 1, sibling separator).
#        expected to FAIL before fix
# ─────────────────────────────────────────────────────────────────────────────
R2a_CMD="mkdir -p ${REPO_N}/.worktree-backup/branch ; cp ${SRC_N} ${REPO_N}/.worktree-backup/branch/file"
payload="$(hook_payload_bash "$R2a_CMD")"
out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$REPO_N")"
case "$out" in
    *'"decision":"block"'*) fail "R2a mkdir ; cp to .worktree-backup/ expected ALLOW; got block (fix not yet applied)" ;;
    *) pass "R2a mkdir ; cp to .worktree-backup/ → ALLOW" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# R3 — mixed targets: backup dir + non-backup path → BLOCK.
# ─────────────────────────────────────────────────────────────────────────────
R3_CMD="mkdir -p ${REPO_N}/.worktree-backup/branch && cp ${SRC_N} ${REPO_N}/docs/x.md"
payload="$(hook_payload_bash "$R3_CMD")"
out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$REPO_N")"
case "$out" in
    *'"decision":"block"'*) pass "R3 mixed targets (backup + docs) → BLOCK" ;;
    *) fail "R3 mixed targets expected BLOCK; got: $out" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# R4 — mkdir && cp with unresolvable $DEST (no env-prefix) → parseFailure → BLOCK.
# ─────────────────────────────────────────────────────────────────────────────
R4_CMD="mkdir -p ${REPO_N}/.worktree-backup/branch && cp ${SRC_N} \"\$DEST\""
payload="$(hook_payload_bash "$R4_CMD")"
out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$REPO_N")"
case "$out" in
    *'"decision":"block"'*) pass "R4 parseFailure in write segment → BLOCK (fail-closed)" ;;
    *) fail "R4 expected BLOCK for parseFailure; got: $out" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# R5 — quoted && inside single quotes must NOT be split; redirect to excluded
#       target → ALLOW.
# ─────────────────────────────────────────────────────────────────────────────
R5_CMD="echo 'a && b' > ${REPO_N}/.worktree-backup/branch/x"
payload="$(hook_payload_bash "$R5_CMD")"
out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$REPO_N")"
case "$out" in
    *'"decision":"block"'*) fail "R5 quoted && + redirect to .worktree-backup expected ALLOW; got: $out" ;;
    *) pass "R5 quoted && + redirect to .worktree-backup → ALLOW" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# R6 — `false || rm -rf` short-circuit spoofing attempt; rm targets non-excluded
#       path → BLOCK.
# ─────────────────────────────────────────────────────────────────────────────
R6_CMD="false || rm -rf ${REPO_N}/docs"
payload="$(hook_payload_bash "$R6_CMD")"
out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$REPO_N")"
case "$out" in
    *'"decision":"block"'*) pass "R6 false || rm -rf /repo/docs → BLOCK" ;;
    *) fail "R6 expected BLOCK for rm -rf on non-excluded path; got: $out" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# R7 — env-prefix literal resolution (Gap 2).
#       BACKUP_DIR=... cp ... "$BACKUP_DIR/notes.md" → ALLOW.
#       expected to FAIL before fix
# ─────────────────────────────────────────────────────────────────────────────
R7_CMD="BACKUP_DIR=${REPO_N}/.worktree-backup/branch cp ${SRC_N} \"\$BACKUP_DIR/notes.md\""
payload="$(hook_payload_bash "$R7_CMD")"
out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$REPO_N")"
case "$out" in
    *'"decision":"block"'*) fail "R7 env-prefix BACKUP_DIR cp expected ALLOW; got block (fix not yet applied)" ;;
    *) pass "R7 env-prefix BACKUP_DIR cp → ALLOW" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# R8 — no env-prefix for $WORKTREE / $BRANCH → parseFailure → BLOCK.
#       (existing fail-closed behavior; should PASS before and after fix)
# ─────────────────────────────────────────────────────────────────────────────
R8_CMD='cp "/tmp/src.md" ".worktree-backup/$BRANCH/notes.md"'
payload="$(hook_payload_bash "$R8_CMD")"
out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$REPO_N")"
case "$out" in
    *'"decision":"block"'*) pass "R8 cp parseFailure without env-prefix → BLOCK" ;;
    *) fail "R8 expected BLOCK for unresolvable vars; got: $out" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# R9 — env-prefix with traversal (`..`) escaping .worktree-backup/ → BLOCK.
# ─────────────────────────────────────────────────────────────────────────────
R9_CMD="BACKUP_DIR=${REPO_N}/.worktree-backup/../secrets cp ${SRC_N} \"\$BACKUP_DIR/file\""
payload="$(hook_payload_bash "$R9_CMD")"
out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$REPO_N")"
case "$out" in
    *'"decision":"block"'*) pass "R9 env-prefix traversal escape → BLOCK" ;;
    *) fail "R9 expected BLOCK for env-prefix traversal; got: $out" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# R10 — deep traversal via env-prefix → BLOCK.
# ─────────────────────────────────────────────────────────────────────────────
R10_CMD="BACKUP_DIR=${REPO_N}/.worktree-backup/branch/../../secrets cp ${SRC_N} \"\$BACKUP_DIR/file\""
payload="$(hook_payload_bash "$R10_CMD")"
out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$REPO_N")"
case "$out" in
    *'"decision":"block"'*) pass "R10 env-prefix deep traversal → BLOCK" ;;
    *) fail "R10 expected BLOCK for env-prefix deep traversal; got: $out" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# R11 — env-prefix value containing '$' must be rejected by the resolver.
#        BACKUP_DIR='$HOME/.secrets' cp ... "$BACKUP_DIR/file"
#        Since the value starts with '$', the resolver must reject it →
#        destination "$BACKUP_DIR/file" remains unresolvable → parseFailure
#        → fail-closed → BLOCK. Prevents env-prefix spoofing via nested
#        variable expansion.
# ─────────────────────────────────────────────────────────────────────────────
R11_CMD='BACKUP_DIR='"'"'$HOME/.secrets'"'"' cp /src/file "$BACKUP_DIR/file"'
payload="$(hook_payload_bash "$R11_CMD")"
out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$REPO_N")"
case "$out" in
    *'"decision":"block"'*) pass "R11 env-prefix value containing '\$' → BLOCK (spoofing rejected)" ;;
    *) fail "R11 expected BLOCK for env-prefix value with '\$'; got: $out" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# R12 — sequenced command where the full string classifies as "write" (a
#        cross-segment match — `\bgit\b.*\bpush\b`), but each individual
#        segment classifies as "read". isEverySegmentExcluded must return
#        false (hasWriteSegment=false invariant), and the command must fall
#        through to the main-checkout block → BLOCK. The invariant: pure-
#        read segment sequences must NOT be allowed by the per-segment
#        excluded-targets fast-path — only sequences where every WRITE
#        segment targets excluded paths.
# ─────────────────────────────────────────────────────────────────────────────
R12_CMD="git status && echo push"
payload="$(hook_payload_bash "$R12_CMD")"
out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$REPO_N")"
case "$out" in
    *'"decision":"block"'*) pass "R12 cross-segment write match, all read segments → BLOCK (hasWriteSegment=false)" ;;
    *) fail "R12 expected BLOCK for cross-segment write classify with all-read segments; got: $out" ;;
esac

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
