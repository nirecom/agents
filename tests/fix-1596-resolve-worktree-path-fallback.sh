#!/usr/bin/env bash
# Tests: hooks/workflow-state/resolve-worktree-path.js
# Tags: scope:issue-specific, pwsh-not-required, worktree, session-id, resolve-worktree-path
# Issue #1596 (C2): resolveSessionWorktreePath() must treat state.cwd and
# state.session_worktree as one ordered candidate list under a single predicate;
# today's early returns make a present-but-INVALID cwd skip the fallback.
# TL3 gap (not caught here): the resolver reached through a real Claude Code hook
# subprocess, and real /worktree-start writing state.session_worktree mid-session.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.

set -uo pipefail

AGENTS_WORKTREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_TIMEOUT="$AGENTS_WORKTREE/bin/run-with-timeout.sh"
RESOLVER_JS="$AGENTS_WORKTREE/hooks/workflow-state/resolve-worktree-path.js"

SID="fix-1596-test-sid"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

command -v node >/dev/null 2>&1 || { echo "node not found — check skipped"; exit 77; }
[[ -f "$RESOLVER_JS" ]] || { echo "resolve-worktree-path.js missing"; exit 1; }

# Disposable fixture: main worktree + two linked worktrees. Setup lines mirror
# tests/fix-882-resolve-worktree-path.sh (dual-pin, hooksPath, cygpath).
TMPDIR_BASE="$(mktemp -d 2>/dev/null || mktemp -d -t rwp1596)"
MAIN_REPO="$TMPDIR_BASE/main"
WTA="$TMPDIR_BASE/wtA"
WTB="$TMPDIR_BASE/wtB"
WF_DIR="$TMPDIR_BASE/workflow-state"
PLANS_DIR="$TMPDIR_BASE/plans"
EMPTY_TRANSCRIPTS="$TMPDIR_BASE/empty-transcripts"

cleanup() {
  git -C "$MAIN_REPO" worktree remove --force "$WTA" 2>/dev/null || true
  git -C "$MAIN_REPO" worktree remove --force "$WTB" 2>/dev/null || true
  rm -rf "$TMPDIR_BASE" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$MAIN_REPO" "$WF_DIR" "$PLANS_DIR" "$EMPTY_TRANSCRIPTS"
git -C "$MAIN_REPO" init -q
git -C "$MAIN_REPO" config core.hooksPath /dev/null 2>/dev/null || true
git -C "$MAIN_REPO" config user.email "test@example.com"
git -C "$MAIN_REPO" config user.name "Test"
touch "$MAIN_REPO/.gitkeep"
git -C "$MAIN_REPO" add .gitkeep
git -C "$MAIN_REPO" commit -q -m "init"
git -C "$MAIN_REPO" worktree add -q -b "wt-branch-a" "$WTA"
git -C "$MAIN_REPO" worktree add -q -b "wt-branch-b" "$WTB"

if command -v cygpath >/dev/null 2>&1; then
  to_node() { cygpath -m "$1"; }
else
  to_node() { printf '%s' "$1"; }
fi
WTA_NODE="$(to_node "$WTA")"
WTB_NODE="$(to_node "$WTB")"
MAIN_NODE="$(to_node "$MAIN_REPO")"
WF_DIR_NODE="$(to_node "$WF_DIR")"
PLANS_DIR_NODE="$(to_node "$PLANS_DIR")"
RESOLVER_JS_NODE="$(to_node "$RESOLVER_JS")"
TRANSCRIPTS_NODE="$(to_node "$EMPTY_TRANSCRIPTS")"
GONE_NODE="$(to_node "$TMPDIR_BASE")/deleted-worktree"

# $1: JSON fragment for the candidate fields (may be empty), e.g. '"cwd": "",'
write_state() {
  printf '{\n  "version": 1,\n  "session_id": "%s",\n  "created_at": "2026-09-09T00:00:00.000Z",\n  %s\n  "git_branch": "wt-branch-a",\n  "steps": {}\n}\n' \
    "$SID" "$1" > "$WF_DIR/$SID.json"
}

# Call resolveSessionWorktreePath(sid) with an EXPLICIT session id, so the env
# priority/inference chain is never entered. Sets RSWP_OUT (path, "" for null),
# RSWP_RC and RSWP_ERR: a corrupt candidate must be DROPPED by the per-candidate
# predicate, which a crash folded to null by the outer try/catch would fake.
RSWP_OUT=""
RSWP_RC=0
RSWP_ERR=""
run_rswp_checked() {
  local outf="$TMPDIR_BASE/rswp.out" errf="$TMPDIR_BASE/rswp.err"
  (
    cd "$TMPDIR_BASE" || exit 1
    env -u SESSION_ID -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_ENV_FILE \
      CLAUDE_WORKFLOW_DIR="$WF_DIR_NODE" \
      WORKFLOW_PLANS_DIR="$PLANS_DIR_NODE" \
      CLAUDE_TRANSCRIPT_BASE_DIR="$TRANSCRIPTS_NODE" \
      RSWP_MODULE="$RESOLVER_JS_NODE" \
      bash "$RUN_TIMEOUT" 30 node -e '
const { resolveSessionWorktreePath } = require(process.env.RSWP_MODULE);
const r = resolveSessionWorktreePath(process.argv[1]);
process.stdout.write(r === null || r === undefined ? "" : String(r));
' "$SID"
  ) >"$outf" 2>"$errf"
  RSWP_RC=$?
  RSWP_OUT="$(cat "$outf")"
  RSWP_ERR="$(cat "$errf")"
}

# Return-value-only view for the cases that predate the rc/stderr assertions.
run_rswp() {
  run_rswp_checked
  printf '%s' "$RSWP_OUT"
}

# $1 label, $2 want, $3 got
check() {
  if [[ "$2" == "$3" ]]; then pass "$1: got '$3'"; else fail "$1: got '$3', want '$2'"; fi
}

# $1 label, $2 want — asserts the value AND a clean exit (rc 0, no stderr).
check_clean() {
  run_rswp_checked
  if [[ "$RSWP_OUT" == "$2" && "$RSWP_RC" -eq 0 && -z "$RSWP_ERR" ]]; then
    pass "$1: got '$RSWP_OUT' with rc 0 and empty stderr"
  else
    fail "$1: got '$RSWP_OUT' rc=$RSWP_RC stderr='$RSWP_ERR', want '$2' rc=0 empty stderr"
  fi
}

# Q1-Q4 are fail-before-fix: each pairs an absent-or-invalid cwd with a valid
# session_worktree, which today's early returns collapse to null.
write_state "\"session_worktree\": \"$WTA_NODE\","
check "Q1 (cwd key absent -> session_worktree) [RED before C2]" "$WTA_NODE" "$(run_rswp)"

write_state "\"cwd\": \"\", \"session_worktree\": \"$WTA_NODE\","
check "Q2 (cwd empty string -> session_worktree) [RED before C2]" "$WTA_NODE" "$(run_rswp)"

write_state "\"cwd\": 12345, \"session_worktree\": \"$WTA_NODE\","
check "Q3 (cwd non-string -> session_worktree) [RED before C2]" "$WTA_NODE" "$(run_rswp)"

# Q3b-Q3g: corrupt state must be survived, not merely absorbed. Each candidate
# is judged on its own, so a non-string in one slot decides nothing about the
# other, and the node process still exits 0 with nothing on stderr.
# The #950 equivalence classes (valid strings) stay in cases-882-950.sh I/J/K/L.
write_state "\"cwd\": {\"a\": 1}, \"session_worktree\": \"$WTA_NODE\","
check_clean "Q3b (cwd object -> session_worktree)" "$WTA_NODE"

write_state "\"cwd\": null, \"session_worktree\": \"$WTA_NODE\","
check_clean "Q3c (cwd null -> session_worktree)" "$WTA_NODE"

write_state "\"cwd\": \"$WTA_NODE\", \"session_worktree\": {\"a\": 1},"
check_clean "Q3d (valid cwd + object session_worktree -> cwd)" "$WTA_NODE"

write_state "\"cwd\": \"$MAIN_NODE\", \"session_worktree\": 12345,"
check_clean "Q3e (cwd main + number session_worktree -> null)" ""

write_state "\"cwd\": \"$MAIN_NODE\", \"session_worktree\": null,"
check_clean "Q3f (cwd main + null session_worktree -> null)" ""

write_state "\"cwd\": [1, 2], \"session_worktree\": true,"
check_clean "Q3g (both candidates non-string -> null, no crash)" ""

# Q4 is the symmetric sibling of Q2/Q3: present but failing a different clause.
write_state "\"cwd\": \"$GONE_NODE\", \"session_worktree\": \"$WTA_NODE\","
check "Q4 (cwd deleted dir -> session_worktree) [RED before C2]" "$WTA_NODE" "$(run_rswp)"

# Q5-Q9 pin behavior that exists TODAY and must survive C2 unchanged.
# A failure below means the fixture is wrong, not the source.
write_state ""
check "Q5 (no candidates -> null)" "" "$(run_rswp)"

# Q6: main worktree is never returned as a session worktree (fail-closed).
write_state "\"session_worktree\": \"$MAIN_NODE\","
check "Q6 (session_worktree=main -> null)" "" "$(run_rswp)"

write_state "\"cwd\": \"$WTA_NODE\", \"session_worktree\": \"$WTB_NODE\","
check "Q7 (both valid -> cwd wins)" "$WTA_NODE" "$(run_rswp)"

# Q8 pins that the state===null early return (issue #2237) stays untouched.
rm -f "$WF_DIR/$SID.json"
check "Q8 (no state file -> null)" "" "$(run_rswp)"

# Q9 (idempotency): repeating Q7 returns the identical answer and writes nothing.
write_state "\"cwd\": \"$WTA_NODE\", \"session_worktree\": \"$WTB_NODE\","
q9_first="$(run_rswp)"
q9_second="$(run_rswp)"
q9_files="$(find "$WF_DIR" -type f | wc -l | tr -d ' ')"
if [[ "$q9_first" == "$q9_second" && "$q9_files" == "1" ]]; then
  pass "Q9 (idempotent, no side-effect writes): '$q9_first', state files=$q9_files"
else
  fail "Q9 (idempotent, no side-effect writes): '$q9_first' vs '$q9_second', files=$q9_files"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
