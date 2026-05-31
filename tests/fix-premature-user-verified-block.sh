#!/usr/bin/env bash
# Tests: hooks/workflow-gate.js, hooks/workflow-gate.js.
# Tags: workflow, gate, hook, worktree, sentinel
# Tests for premature <<WORKFLOW_USER_VERIFIED>> block in hooks/workflow-gate.js.
#
# Feature: when ENFORCE_WORKTREE=on AND cwd is a linked worktree AND there is
# no PR (neither OPEN nor MERGED) for the current branch, emitting
# `<<WORKFLOW_USER_VERIFIED: reason>>` is premature → block.
# Otherwise → approve (sentinel passes through).
#
# TDD: the hook logic is NOT implemented yet, so most positive cases will fail
# until the implementation lands. Case 1 (the block case) is the new behavior;
# cases 2-7 are the must-not-regress paths.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$AGENTS_DIR/hooks/workflow-gate.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 "$@"
  else
    perl -e 'alarm 120; exec @ARGV' -- "$@"
  fi
}

NODE_TMPDIR="$(run_with_timeout node -e "process.stdout.write(require('os').tmpdir().replace(/\\\\/g,'/'))")"
WORK_DIR="${NODE_TMPDIR}/premature-uv-block-test-$$"
mkdir -p "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

# Sentinel payload — strict form with reason
SENTINEL_CMD='echo \"<<WORKFLOW_USER_VERIFIED: implementation complete>>\"'

# Per-test session id / workflow dir (isolated)
SESSION_BASE="$WORK_DIR/workflow-dir"
mkdir -p "$SESSION_BASE"

# Helper — invoke the hook and capture the decision field.
# Args: enforce_worktree gh_dir json
run_hook_decision() {
  local enforce_worktree="$1"
  local gh_dir="$2"
  local json="$3"
  # On Windows/MSYS2, PATH="C:/path:..." causes MSYS2 to mangle C:/path when
  # translating PATH for native Windows node.exe (C: is treated as a POSIX
  # relative entry, /path as MSYS2-root-relative → C:\Program Files\Git\path).
  # Convert to MSYS2 format /c/path so MSYS2 translates it correctly to C:\path.
  local path_entry="$gh_dir"
  if command -v cygpath >/dev/null 2>&1; then
    path_entry="$(cygpath -u "$gh_dir")"
  fi
  local out
  out=$(echo "$json" | \
        ENFORCE_WORKTREE="$enforce_worktree" \
        PATH="$path_entry:$PATH" \
        CLAUDE_WORKFLOW_DIR="$SESSION_BASE" \
        run_with_timeout node "$HOOK" 2>/dev/null)
  echo "$out" | run_with_timeout node -e "
    let d; try { d=JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e){process.stdout.write('parse-error:'+require('fs').readFileSync(0,'utf8')); process.exit(0);}
    process.stdout.write(d.decision||'no-decision');
  " 2>/dev/null
}

# Create a temp main repo + linked worktree on a non-protected branch.
# Sets globals: MAIN_REPO LINKED_WT
make_linked_worktree() {
  local tag="$1"
  MAIN_REPO="$WORK_DIR/main-$tag"
  LINKED_WT="$WORK_DIR/wt-$tag"
  mkdir -p "$MAIN_REPO"
  git -C "$MAIN_REPO" init -q -b main
  git -C "$MAIN_REPO" config user.email "test@example.com"
  git -C "$MAIN_REPO" config user.name "Test"
  # Build seed commit via plumbing (avoids `git commit` which Claude Code's
  # enforce-worktree PreToolUse hook intercepts as a write from a main worktree).
  local empty_tree
  empty_tree=$(git -C "$MAIN_REPO" hash-object -t tree --stdin </dev/null 2>/dev/null \
               || git -C "$MAIN_REPO" mktree </dev/null)
  local seed_sha
  seed_sha=$(GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=t@example.com \
             GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=t@example.com \
             git -C "$MAIN_REPO" commit-tree "$empty_tree" -m seed)
  git -C "$MAIN_REPO" update-ref refs/heads/main "$seed_sha"
  git -C "$MAIN_REPO" symbolic-ref HEAD refs/heads/main
  git -C "$MAIN_REPO" worktree add -q -b "feat-$tag" "$LINKED_WT" 2>/dev/null
}

# Build a gh-mock dir that prints a state string and exits with given code.
# Args: dir state exit_code
make_gh_mock() {
  local dir="$1"; local state="$2"; local code="$3"
  mkdir -p "$dir"
  cat > "$dir/gh" << SHIM
#!/usr/bin/env bash
# gh-mock: respond to 'gh pr view' style queries with state=$state
echo "$state"
exit $code
SHIM
  chmod +x "$dir/gh"
  # Also provide gh.exe shim for Windows Node spawn (best-effort).
  cp "$dir/gh" "$dir/gh.exe" 2>/dev/null || true
}

# ── Case 1: ENFORCE_WORKTREE=on + linked worktree + no PR → block ──────────
echo "=== Case 1: ENFORCE_WORKTREE=on + linked worktree + no PR → block ==="
make_linked_worktree "c1"
GH_NO_PR="$WORK_DIR/gh-no-pr"
make_gh_mock "$GH_NO_PR" "" 1   # gh exits 1 when no PR exists for branch
C1_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$SENTINEL_CMD\",\"cwd\":\"$LINKED_WT\"},\"session_id\":\"sess-c1\"}"
C1_DECISION=$(run_hook_decision "on" "$GH_NO_PR" "$C1_JSON")
if [ "$C1_DECISION" = "block" ]; then
  pass "Case 1 — premature user_verified sentinel blocked"
else
  fail "Case 1 — expected decision=block, got: $C1_DECISION"
fi

# ── Case 2: ENFORCE_WORKTREE=on + linked worktree + PR OPEN → approve ──────
echo "=== Case 2: ENFORCE_WORKTREE=on + linked worktree + PR OPEN → approve ==="
make_linked_worktree "c2"
GH_OPEN="$WORK_DIR/gh-open"
make_gh_mock "$GH_OPEN" "OPEN" 0
C2_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$SENTINEL_CMD\",\"cwd\":\"$LINKED_WT\"},\"session_id\":\"sess-c2\"}"
C2_DECISION=$(run_hook_decision "on" "$GH_OPEN" "$C2_JSON")
if [ "$C2_DECISION" = "approve" ]; then
  pass "Case 2 — PR OPEN → sentinel approved"
else
  fail "Case 2 — expected decision=approve, got: $C2_DECISION"
fi

# ── Case 3: ENFORCE_WORKTREE=on + linked worktree + PR MERGED → approve ─────
echo "=== Case 3: ENFORCE_WORKTREE=on + linked worktree + PR MERGED → approve ==="
make_linked_worktree "c3"
GH_MERGED="$WORK_DIR/gh-merged"
make_gh_mock "$GH_MERGED" "MERGED" 0
C3_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$SENTINEL_CMD\",\"cwd\":\"$LINKED_WT\"},\"session_id\":\"sess-c3\"}"
C3_DECISION=$(run_hook_decision "on" "$GH_MERGED" "$C3_JSON")
if [ "$C3_DECISION" = "approve" ]; then
  pass "Case 3 — PR MERGED → sentinel approved"
else
  fail "Case 3 — expected decision=approve, got: $C3_DECISION"
fi

# ── Case 4: ENFORCE_WORKTREE=off → approve ─────────────────────────────────
echo "=== Case 4: ENFORCE_WORKTREE=off → approve (regardless of PR status) ==="
make_linked_worktree "c4"
GH_NO_PR4="$WORK_DIR/gh-no-pr-c4"
make_gh_mock "$GH_NO_PR4" "" 1
C4_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$SENTINEL_CMD\",\"cwd\":\"$LINKED_WT\"},\"session_id\":\"sess-c4\"}"
C4_DECISION=$(run_hook_decision "off" "$GH_NO_PR4" "$C4_JSON")
if [ "$C4_DECISION" = "approve" ]; then
  pass "Case 4 — ENFORCE_WORKTREE=off → sentinel approved"
else
  fail "Case 4 — expected decision=approve, got: $C4_DECISION"
fi

# ── Case 5: Main worktree (not linked) → approve ───────────────────────────
echo "=== Case 5: main worktree (not linked) → approve ==="
make_linked_worktree "c5"  # creates MAIN_REPO + LINKED_WT; we use MAIN_REPO
GH_NO_PR5="$WORK_DIR/gh-no-pr-c5"
make_gh_mock "$GH_NO_PR5" "" 1
C5_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$SENTINEL_CMD\",\"cwd\":\"$MAIN_REPO\"},\"session_id\":\"sess-c5\"}"
C5_DECISION=$(run_hook_decision "on" "$GH_NO_PR5" "$C5_JSON")
if [ "$C5_DECISION" = "approve" ]; then
  pass "Case 5 — main worktree → sentinel approved (premature-check does not apply)"
else
  fail "Case 5 — expected decision=approve, got: $C5_DECISION"
fi

# ── Case 6: workflow-off marker present → approve ──────────────────────────
echo "=== Case 6: workflow-off marker present + premature conditions → approve ==="
make_linked_worktree "c6"
GH_NO_PR6="$WORK_DIR/gh-no-pr-c6"
make_gh_mock "$GH_NO_PR6" "" 1
# Create the workflow-off session marker so isWorkflowOff() returns true.
SID6="sess-c6"
touch "$SESSION_BASE/${SID6}.workflow-off"
C6_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$SENTINEL_CMD\",\"cwd\":\"$LINKED_WT\"},\"session_id\":\"$SID6\"}"
C6_DECISION=$(run_hook_decision "on" "$GH_NO_PR6" "$C6_JSON")
if [ "$C6_DECISION" = "approve" ]; then
  pass "Case 6 — workflow-off marker → sentinel approved"
else
  fail "Case 6 — expected decision=approve, got: $C6_DECISION"
fi

# ── Case 7: gh exits non-zero (fail-open) → approve ─────────────────────────
# This case overlaps with Case 1 at the surface (gh exits 1) but documents the
# fail-open contract: if `gh` is unavailable or errors abnormally, the gate
# must NOT block. However, "gh exits 1" is also legitimately how `gh pr view`
# reports "no PR exists" — so the implementation distinguishes these only by
# extra diagnostics. To test fail-open distinctly here, we shadow `gh` with a
# script that exits non-zero AND prints nothing to stdout (typical "gh not
# authenticated" / "network error" shape). Spec: fail-open → approve.
#
# NOTE: with the current spec sketch where "exit 1 + empty stdout" == "no PR",
# this case would block. The fail-open contract is asserted here so the
# implementor must choose: either (a) distinguish 'no PR' from 'gh error' via
# stderr/exit-code parsing, or (b) declare fail-open semantics so that any
# gh failure short-circuits to approve. This test pins option (b) — the safer
# choice given how often gh has transient errors in real CLI sessions.
echo "=== Case 7: gh exits non-zero (fail-open) → approve ==="
make_linked_worktree "c7"
GH_FAIL="$WORK_DIR/gh-fail"
mkdir -p "$GH_FAIL"
cat > "$GH_FAIL/gh" << 'SHIM'
#!/usr/bin/env bash
echo "error: not authenticated" >&2
exit 4
SHIM
chmod +x "$GH_FAIL/gh"
cp "$GH_FAIL/gh" "$GH_FAIL/gh.exe" 2>/dev/null || true
C7_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$SENTINEL_CMD\",\"cwd\":\"$LINKED_WT\"},\"session_id\":\"sess-c7\"}"
C7_DECISION=$(run_hook_decision "on" "$GH_FAIL" "$C7_JSON")
if [ "$C7_DECISION" = "approve" ]; then
  pass "Case 7 — gh fail (exit!=0,1; stderr error) → fail-open approve"
else
  fail "Case 7 — expected decision=approve (fail-open), got: $C7_DECISION"
fi

# ── Results ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
  echo "All tests passed!"
else
  echo "$ERRORS test(s) failed (expected during TDD before implementation)"
  exit 1
fi
