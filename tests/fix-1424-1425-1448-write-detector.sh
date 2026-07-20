#!/bin/bash
# tests/fix-1424-1425-1448-write-detector.sh
# Tests: hooks/lib/bash-write-patterns/patterns.js, hooks/lib/bash-write-targets.js, hooks/enforce-worktree/bash-write-scope.js, hooks/enforce-worktree/universal-target-allow.js, hooks/enforce-worktree.js
# Tags: worktree, enforce, hook, write-detector, gh-write, newline-injection, sequenced, scope:issue-specific
#
# Tests for three write-detector bug fixes:
#   #1424 — isGhWriteIR per-segment evaluation: break → continue so ALL segments
#            are checked (not just the first gh segment). False-negatives like
#            `gh status && gh pr merge 123` must fire.
#   #1425 — isNewlineInjectedWriteIR backslash fold: lines joined by `\` + LF
#            continuation must not be split as if they were separate commands.
#            A supervisor-report call with `bash -c` in quoted args must NOT fire.
#   #1448 — sequenced outside-scope allow:
#     Sub-bug A: `; echo RC=$?` suffix causes otherwise-read-only compound to block.
#     Sub-bug B: non-git-repo redirect target blocks even when target is outside repo.
#
# Cases marked "(expected to fail before fix)" will fail until the fix is applied.
#
# L3 gap (what this test does NOT catch):
# - real Claude Code session where enforce-worktree.js runs as PreToolUse hook
# - actual hook payload flowing through the full hook process end-to-end
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

PATTERNS_JS="${_AGENTS_DIR_NODE}/hooks/lib/bash-write-patterns/patterns.js"
TARGETS_JS="${_AGENTS_DIR_NODE}/hooks/lib/bash-write-targets.js"
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

# ─────────────────────────────────────────────────────────────────────────────
# Fixture: minimal git repo (for full-hook tests)
# ─────────────────────────────────────────────────────────────────────────────
TMPDIR_BASE="$(mktemp -d 2>/dev/null || mktemp -d -t fix1424test)"
trap 'rm -rf "$TMPDIR_BASE" 2>/dev/null' EXIT

REPO="$TMPDIR_BASE/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"
git -C "$REPO" config core.hooksPath /dev/null
git -C "$REPO" commit --allow-empty --no-verify -q -m init
if command -v cygpath >/dev/null 2>&1; then REPO_N="$(cygpath -m "$REPO")"; else REPO_N="$REPO"; fi

# Non-git directory for #1448 sub-bug B tests
NONGIT_DIR="$TMPDIR_BASE/nongit"
mkdir -p "$NONGIT_DIR"
if command -v cygpath >/dev/null 2>&1; then NONGIT_N="$(cygpath -m "$NONGIT_DIR")"; else NONGIT_N="$NONGIT_DIR"; fi

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

# Helper: call isGhWriteIR on a raw command string
is_gh_write() {
    local cmd="$1"
    node -e "
      const {parse} = require('${_AGENTS_DIR_NODE}/hooks/lib/command-ir');
      const {isGhWriteIR} = require('${PATTERNS_JS}');
      const ir = parse(process.argv[1]);
      console.log(isGhWriteIR(ir) ? 'true' : 'false');
    " -- "$cmd" 2>/dev/null
}


# ─────────────────────────────────────────────────────────────────────────────
# Section 1: #1424 — isGhWriteIR per-segment evaluation
#
# Bug: isGhWriteIR loops over segments with `break` after the first gh segment.
#      When the first segment is a read-only gh command (e.g. `gh status`), the
#      loop breaks and returns false, missing a write in a later segment.
# Fix: replace `break` with `continue` so ALL gh segments are evaluated.
# ─────────────────────────────────────────────────────────────────────────────

echo "=== Section 1: #1424 isGhWriteIR per-segment evaluation ==="

# G1a — MUST-FIRE: second gh segment is a write (break bug)
# Expected to FAIL before fix (break exits after read-only first segment)
got="$(is_gh_write 'gh status && gh pr merge 123')"
if [ "$got" = "true" ]; then
    pass "G1a isGhWriteIR('gh status && gh pr merge 123') → true (write in second segment)"
else
    fail "G1a isGhWriteIR('gh status && gh pr merge 123') expected true, got $got (fix not yet applied — #1424)"
fi

# G1b — MUST-FIRE: semicolon separator, write in second segment
# Expected to FAIL before fix
got="$(is_gh_write 'gh api /rate_limit; gh pr merge 5')"
if [ "$got" = "true" ]; then
    pass "G1b isGhWriteIR('gh api /rate_limit; gh pr merge 5') → true"
else
    fail "G1b isGhWriteIR('gh api /rate_limit; gh pr merge 5') expected true, got $got (fix not yet applied — #1424)"
fi

# G1c — MUST-FIRE: single-segment write (regression guard; should pass before and after fix)
got="$(is_gh_write 'gh pr merge 123')"
if [ "$got" = "true" ]; then
    pass "G1c isGhWriteIR('gh pr merge 123') → true (single segment, regression guard)"
else
    fail "G1c isGhWriteIR('gh pr merge 123') expected true, got $got"
fi

# G1d — MUST-NOT-FIRE: both segments are read-only
got="$(is_gh_write 'gh status && gh pr view 123')"
if [ "$got" = "false" ]; then
    pass "G1d isGhWriteIR('gh status && gh pr view 123') → false (both read-only)"
else
    fail "G1d isGhWriteIR('gh status && gh pr view 123') expected false, got $got"
fi

# G1e — MUST-NOT-FIRE: single read-only command
got="$(is_gh_write 'gh auth status')"
if [ "$got" = "false" ]; then
    pass "G1e isGhWriteIR('gh auth status') → false (auth status is read-only)"
else
    fail "G1e isGhWriteIR('gh auth status') expected false, got $got"
fi

# G1f — MUST-FIRE: write in first segment (regression guard; passes before and after fix)
got="$(is_gh_write 'gh pr merge 5 && gh pr view 6')"
if [ "$got" = "true" ]; then
    pass "G1f isGhWriteIR('gh pr merge 5 && gh pr view 6') → true (write in first segment)"
else
    fail "G1f isGhWriteIR('gh pr merge 5 && gh pr view 6') expected true, got $got"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Section 2: #1425 — isNewlineInjectedWriteIR backslash fold
#
# Bug: the function splits on /[\r\n]+/ which also splits backslash-continuation
#      lines (`\` + LF). A supervisor-report invocation spanning multiple lines
#      with continuation characters has `bash -c` inside a single-quoted arg;
#      after the (incorrect) split that becomes a bare `bash -c` command line,
#      firing a false write detection.
# Fix: join backslash-continuation lines before splitting on newline.
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Section 2: #1425 isNewlineInjectedWriteIR backslash fold ==="

# N1a — MUST-FIRE: genuine newline injection (real LF between echo and rm)
# Should fire both before and after the fix (regression guard).
got="$(node -e "
const nl = '\n';
const cmd = 'echo clean' + nl + 'rm /tmp/testfile';
const {parse} = require('${_AGENTS_DIR_NODE}/hooks/lib/command-ir');
const {isNewlineInjectedWriteIR} = require('${TARGETS_JS}');
const ir = parse(cmd);
console.log(isNewlineInjectedWriteIR(ir) ? 'true' : 'false');
" 2>/dev/null)"
if [ "$got" = "true" ]; then
    pass "N1a isNewlineInjectedWriteIR(genuine LF injection: echo LF rm) → true"
else
    fail "N1a isNewlineInjectedWriteIR(genuine LF injection) expected true, got $got"
fi

# N1b — MUST-NOT-FIRE: backslash continuation where bash -c is the VALUE of --detail,
# split to its own line by the \ + LF continuation format.
# When split on LF (without the fix), the third line 'bash -c ...' appears as
# a standalone command and fires isInterpreterCWriteIR → false positive.
# After the fix (join \ + LF before splitting), the three lines merge into one
# command: node supervisor-report --detail bash -c '...' → cmd0=node → no fire.
# Expected to FAIL before fix (incorrect split yields bare `bash -c ...` line).
got="$(node -e "
const bs = String.fromCharCode(92);
const nl = '\n';
const cmd =
  'node bin/supervisor-report ' + bs + nl +
  '  --detail ' + bs + nl +
  \"  bash -c 'git status'\";
const {parse} = require('${_AGENTS_DIR_NODE}/hooks/lib/command-ir');
const {isNewlineInjectedWriteIR} = require('${TARGETS_JS}');
const ir = parse(cmd);
console.log(isNewlineInjectedWriteIR(ir) ? 'true' : 'false');
" 2>/dev/null)"
if [ "$got" = "false" ]; then
    pass "N1b isNewlineInjectedWriteIR(backslash-continuation: bash -c as arg value on own line) → false"
else
    fail "N1b isNewlineInjectedWriteIR(backslash-continuation) expected false, got $got (fix not yet applied — #1425)"
fi

# N1c — MUST-NOT-FIRE: pure read-only multi-line (no writes anywhere)
got="$(node -e "
const nl = '\n';
const cmd = 'git status' + nl + 'git log --oneline -5';
const {parse} = require('${_AGENTS_DIR_NODE}/hooks/lib/command-ir');
const {isNewlineInjectedWriteIR} = require('${TARGETS_JS}');
const ir = parse(cmd);
console.log(isNewlineInjectedWriteIR(ir) ? 'true' : 'false');
" 2>/dev/null)"
if [ "$got" = "false" ]; then
    pass "N1c isNewlineInjectedWriteIR(git status LF git log) → false (both read-only)"
else
    fail "N1c isNewlineInjectedWriteIR(pure read multi-line) expected false, got $got"
fi

# N1d — MUST-FIRE: write on second line with no continuation (regression guard)
# Real newline between two commands where the second writes to a file.
got="$(node -e "
const nl = '\n';
const cmd = 'git status' + nl + 'rm /tmp/test-1425-file';
const {parse} = require('${_AGENTS_DIR_NODE}/hooks/lib/command-ir');
const {isNewlineInjectedWriteIR} = require('${TARGETS_JS}');
const ir = parse(cmd);
console.log(isNewlineInjectedWriteIR(ir) ? 'true' : 'false');
" 2>/dev/null)"
if [ "$got" = "true" ]; then
    pass "N1d isNewlineInjectedWriteIR(git status LF rm ...) → true (write on second line)"
else
    fail "N1d isNewlineInjectedWriteIR(write on second line) expected true, got $got"
fi

# N1e — MUST-NOT-FIRE: DQ body containing a real embedded newline (not backslash-continuation).
# A command like `gh issue create --body "line1\nline2"` where \n is a literal newline
# INSIDE a double-quoted string must NOT trigger write detection.
# The DQ span is not a command separator — it is data inside quotes.
# stripDqPreservingCmdSubst must blank out the DQ contents so the embedded LF
# does not become a spurious second command line.
# Expected: isNewlineInjectedWriteIR returns false (fix in stripDqPreservingCmdSubst).
got="$(node -e "
const nl = '\n';
// Construct: gh issue create --body \"line1<LF>rm -rf /\nline3\"
// The body text contains real newlines but is wrapped in double quotes.
const body = 'line1' + nl + 'rm -rf /' + nl + 'line3';
const cmd = 'gh issue create --body \"' + body + '\"';
const {parse} = require('${_AGENTS_DIR_NODE}/hooks/lib/command-ir');
const {isNewlineInjectedWriteIR} = require('${TARGETS_JS}');
const ir = parse(cmd);
console.log(isNewlineInjectedWriteIR(ir) ? 'true' : 'false');
" 2>/dev/null)"
if [ "$got" = "false" ]; then
    pass "N1e isNewlineInjectedWriteIR(DQ body with real embedded newlines) → false (newlines inside DQ are data, not command separators)"
else
    fail "N1e isNewlineInjectedWriteIR(DQ body with embedded newlines) expected false, got $got (false-positive: DQ body contents not stripped)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Section 3: #1448 — sequenced outside-scope allow via full hook
#
# Sub-bug A: `; echo RC=$?` suffix causes an otherwise-clean compound to block.
#   hasCommandSequencing returns true → sequenced fast-path skipped →
#   falls through to main-checkout block.
#   Fix: new areAllWriteSegmentsOutsideSessionScope check handles sequences
#   where write-segment targets are all outside session scope.
#
# Sub-bug B: non-git-repo redirect target blocks even when the target is
#   outside any git repo, because repoRoot is null (non-git CWD) and the
#   current guard at line ~324 requires repoRoot for the outside-scope allow.
#   Fix: relax the repoRoot requirement when targets are provably outside repos.
#
# These tests run the full hook with ENFORCE_WORKTREE=on from the main worktree.
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Section 3: #1448 sequenced outside-scope allow ==="

# S1 — MUST-ALLOW: git log > /tmp/out; echo RC=$?
# The write target (/tmp/out) is outside any session repo. `echo RC=$?` is
# a read-only command. The `;` causes hasCommandSequencing=true which
# currently prevents the outside-scope allow → falls through to block.
# Expected to FAIL before fix (#1448A).
S1_CMD="git log --oneline -5 > /tmp/fix1424-s1.txt; echo RC=\$?"
payload="$(hook_payload_bash "$S1_CMD")"
out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$REPO_N")"
case "$out" in
    *'"decision":"block"'*) fail "S1 'git log > /tmp/out; echo RC=\$?' expected ALLOW; got block (fix not yet applied — #1448A)" ;;
    *) pass "S1 'git log > /tmp/out; echo RC=\$?' → ALLOW (write target outside session scope, echo is read-only)" ;;
esac

# S2 — MUST-BLOCK: echo x > /tmp/out; git commit -a
# git commit is a write against the session repo — must block regardless.
S2_CMD="echo x > /tmp/fix1424-s2.txt; git commit -a -m test"
payload="$(hook_payload_bash "$S2_CMD")"
out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$REPO_N")"
case "$out" in
    *'"decision":"block"'*) pass "S2 'echo x > /tmp/out; git commit -a' → BLOCK (git commit writes to session repo)" ;;
    *) fail "S2 'echo x > /tmp/out; git commit -a' expected BLOCK; got: $out" ;;
esac

# S3 — MUST-BLOCK: echo x > /tmp/out; rm -rf /repo/README.md
# rm targeting a session-repo file must block even when the first segment
# writes outside scope. The sequenced allow path must NOT skip the rm segment.
S3_CMD="echo x > /tmp/fix1424-s3.txt; rm -rf ${REPO_N}/README.md"
payload="$(hook_payload_bash "$S3_CMD")"
out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$REPO_N")"
case "$out" in
    *'"decision":"block"'*) pass "S3 'echo > /tmp/out; rm /repo/README.md' → BLOCK (rm targets in-session file)" ;;
    *) fail "S3 'echo > /tmp/out; rm /repo/README.md' expected BLOCK; got: $out" ;;
esac

# S4 — MUST-ALLOW: single non-git redirect target (regression guard; should
# pass before and after the fix — no sequencing involved).
S4_CMD="echo hello > /tmp/fix1424-s4.txt"
payload="$(hook_payload_bash "$S4_CMD")"
out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$REPO_N")"
case "$out" in
    *'"decision":"block"'*) fail "S4 simple redirect to /tmp (no sequencing) expected ALLOW; got block: $out" ;;
    *) pass "S4 simple redirect to /tmp (no sequencing) → ALLOW (regression guard)" ;;
esac

# S5 — MUST-ALLOW: redirect to /tmp from non-git CWD (sub-bug B)
# CWD is not a git repo → repoRoot is null. Current code at line ~324 gates
# the non-sequenced outside-scope allow on `repoRoot` being truthy.
# /tmp is outside any git repo → should be allowed.
# Expected to FAIL before fix (#1448B).
S5_CMD="echo hello > /tmp/fix1424-s5.txt"
payload="$(hook_payload_bash "$S5_CMD")"
out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$NONGIT_N")"
case "$out" in
    *'"decision":"block"'*) fail "S5 redirect to /tmp from non-git CWD expected ALLOW; got block (fix not yet applied — #1448B)" ;;
    *) pass "S5 redirect to /tmp from non-git CWD → ALLOW (non-git CWD, target outside all repos)" ;;
esac

# S6 — MUST-BLOCK: redirect INTO session repo from non-git CWD
# Even though CWD is non-git, writing INTO the session repo must block.
S6_CMD="echo hello > ${REPO_N}/injected.txt"
payload="$(hook_payload_bash "$S6_CMD")"
out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$NONGIT_N")"
case "$out" in
    *'"decision":"block"'*) pass "S6 redirect into session repo from non-git CWD → BLOCK (target is in-session)" ;;
    *) fail "S6 redirect into session repo from non-git CWD expected BLOCK; got: $out" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
