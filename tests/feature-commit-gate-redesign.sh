#!/bin/bash
# tests/feature-commit-gate-redesign.sh
#
# Integration tests for upcoming commit-gate redesign:
#   - hooks/workflow-gate.js: merge gate + worktree commit skip for user_verification
#   - hooks/workflow-mark.js: feature-branch push does not reset user_verification
#   - bin/review-code-codex: staged diff fallback when there are no commits past base
#
# Source changes are NOT yet implemented. Tests will FAIL until the new behavior
# is wired up. That is expected.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE_HOOK="$AGENTS_DIR/hooks/workflow-gate.js"
MARK_HOOK="$AGENTS_DIR/hooks/workflow-mark.js"
CODEX_BIN="$AGENTS_DIR/bin/review-code-codex"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' -- "$secs" "$@"
    fi
}

# ---------------------------------------------------------------------------
# Tmpdir + state isolation
# ---------------------------------------------------------------------------
TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'cgr-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_DIR"
export CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

NOW_ISO="$(node -e "console.log(new Date().toISOString())" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")"

# ---------------------------------------------------------------------------
# Repo / worktree setup
# ---------------------------------------------------------------------------
setup_main_checkout() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
    echo "$repo"
}

# Returns "<main_repo>|<wt_path>" — worktree on a feature branch.
setup_linked_worktree() {
    local name="$1"
    local main; main="$(setup_main_checkout "$name-main")"
    local wt="$TMPDIR_BASE/$name-wt"
    git -C "$main" worktree add -q -b "feature/$name" "$wt" 2>/dev/null
    echo "$main|$wt"
}

# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------
write_state() {
    local sid="$1" json="$2"
    mkdir -p "$WORKFLOW_DIR"
    printf '%s' "$json" > "$WORKFLOW_DIR/${sid}.json"
}

read_state_step() {
    local sid="$1" step="$2"
    local f="$WORKFLOW_DIR/${sid}.json"
    [ -f "$f" ] || { echo "MISSING"; return; }
    node -e "
      try {
        const s = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
        const st = s.steps && s.steps['$step'];
        console.log(st && st.status ? st.status : 'MISSING');
      } catch(e){ console.log('MISSING'); }
    " "$f" 2>/dev/null || echo "MISSING"
}

read_state_field() {
    # Read top-level field (e.g. last_pushed_sha) — or "MISSING".
    local sid="$1" field="$2"
    local f="$WORKFLOW_DIR/${sid}.json"
    [ -f "$f" ] || { echo "MISSING"; return; }
    node -e "
      try {
        const s = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
        const v = s['$field'];
        console.log(v == null ? 'MISSING' : String(v));
      } catch(e){ console.log('MISSING'); }
    " "$f" 2>/dev/null || echo "MISSING"
}

# Build a state JSON.
# Args: sid branch uv-status [other-status: applies to research/plan/write_tests/review_security/run_tests/docs]
state_json() {
    local sid="$1" branch="$2" uv_status="$3" other="${4:-complete}"
    local branch_json
    if [ "$branch" = "null" ]; then branch_json="null"; else branch_json="\"$branch\""; fi
    cat <<EOF
{
  "version": 1, "session_id": "$sid", "git_branch": $branch_json,
  "created_at": "$NOW_ISO",
  "steps": {
    "research":          {"status": "$other", "updated_at": "$NOW_ISO"},
    "plan":              {"status": "$other", "updated_at": "$NOW_ISO"},
    "write_tests":       {"status": "$other", "updated_at": "$NOW_ISO"},
    "review_security":   {"status": "$other", "updated_at": "$NOW_ISO"},
    "run_tests":         {"status": "$other", "updated_at": "$NOW_ISO"},
    "docs":              {"status": "$other", "updated_at": "$NOW_ISO"},
    "user_verification": {"status": "$uv_status", "updated_at": "$NOW_ISO"},
    "cleanup":           {"status": "$other", "updated_at": "$NOW_ISO"}
  }
}
EOF
}

# Build a custom-step state JSON via inline overrides.
# Args: sid branch <step1> <status1> <step2> <status2> ...
# Defaults all unspecified steps to "complete".
state_json_custom() {
    local sid="$1" branch="$2"; shift 2
    local branch_json
    if [ "$branch" = "null" ]; then branch_json="null"; else branch_json="\"$branch\""; fi
    # defaults
    local research="complete" plan="complete" write_tests="complete"
    local review_security="complete" run_tests="complete" docs="complete"
    local user_verification="pending"
    local cleanup="complete"
    while [ $# -ge 2 ]; do
        case "$1" in
            research) research="$2";;
            plan) plan="$2";;
            write_tests) write_tests="$2";;
            review_security) review_security="$2";;
            run_tests) run_tests="$2";;
            docs) docs="$2";;
            user_verification) user_verification="$2";;
            cleanup) cleanup="$2";;
        esac
        shift 2
    done
    cat <<EOF
{
  "version": 1, "session_id": "$sid", "git_branch": $branch_json,
  "created_at": "$NOW_ISO",
  "steps": {
    "research":          {"status": "$research", "updated_at": "$NOW_ISO"},
    "plan":              {"status": "$plan", "updated_at": "$NOW_ISO"},
    "write_tests":       {"status": "$write_tests", "updated_at": "$NOW_ISO"},
    "review_security":   {"status": "$review_security", "updated_at": "$NOW_ISO"},
    "run_tests":         {"status": "$run_tests", "updated_at": "$NOW_ISO"},
    "docs":              {"status": "$docs", "updated_at": "$NOW_ISO"},
    "user_verification": {"status": "$user_verification", "updated_at": "$NOW_ISO"},
    "cleanup":           {"status": "$cleanup", "updated_at": "$NOW_ISO"}
  }
}
EOF
}

# Build gate JSON payload (PreToolUse Bash).
build_gate_json() {
    local cmd="$1" sid="$2" cwd="$3"
    node -e "
      const j = {
        tool_name: 'Bash',
        tool_input: { command: process.argv[1] },
        session_id: process.argv[2],
        cwd: process.argv[3]
      };
      console.log(JSON.stringify(j));
    " -- "$cmd" "$sid" "$cwd"
}

# Build mark hook JSON (PostToolUse Bash).
build_mark_json() {
    local cmd="$1" sid="$2" exit_code="${3:-0}" cwd="${4:-}"
    node -e "
      const j = {
        tool_name: 'Bash',
        tool_input: { command: process.argv[1] },
        tool_response: { exit_code: Number(process.argv[3]), stdout: '', stderr: '' },
        session_id: process.argv[2]
      };
      if (process.argv[4]) j.cwd = process.argv[4];
      console.log(JSON.stringify(j));
    " -- "$cmd" "$sid" "$exit_code" "$cwd"
}

run_gate() {
    local cwd="$1" json="$2"; shift 2
    echo "$json" | run_with_timeout 30 env CLAUDE_PROJECT_DIR="$cwd" \
        CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" "$@" node "$GATE_HOOK" 2>/dev/null
}

run_mark() {
    local cwd="$1" json="$2"; shift 2
    echo "$json" | run_with_timeout 30 env CLAUDE_PROJECT_DIR="$cwd" \
        CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" "$@" node "$MARK_HOOK" 2>/dev/null
}

is_block() { echo "$1" | grep -q '"block"'; }
is_approve() { echo "$1" | grep -q '"approve"'; }

# ============================================================================
# Section A: Normal — merge gate (6)
# ============================================================================
echo "=== Section A: Merge gate (normal) ==="

REPO_A="$(setup_main_checkout "secA-repo")"

# 1. gh pr merge --squash + uv:complete → approve
SID_1="a1-$$"
write_state "$SID_1" "$(state_json "$SID_1" "main" "complete" "complete")"
RES_1="$(run_gate "$REPO_A" "$(build_gate_json 'gh pr merge --squash' "$SID_1" "$REPO_A")")"
if is_approve "$RES_1"; then pass "A1. gh pr merge + uv:complete → approve"
else fail "A1. expected approve, got: $RES_1"; fi

# 2. git push origin main + uv:complete → approve
SID_2="a2-$$"
write_state "$SID_2" "$(state_json "$SID_2" "main" "complete" "complete")"
RES_2="$(run_gate "$REPO_A" "$(build_gate_json 'git push origin main' "$SID_2" "$REPO_A")")"
if is_approve "$RES_2"; then pass "A2. git push origin main + uv:complete → approve"
else fail "A2. expected approve, got: $RES_2"; fi

# 3. git push origin feature/foo + uv:pending → approve (not protected)
SID_3="a3-$$"
write_state "$SID_3" "$(state_json "$SID_3" "main" "pending" "complete")"
RES_3="$(run_gate "$REPO_A" "$(build_gate_json 'git push origin feature/foo' "$SID_3" "$REPO_A")")"
if is_approve "$RES_3"; then pass "A3. git push feature/foo + uv:pending → approve (not protected)"
else fail "A3. expected approve (feature push not protected), got: $RES_3"; fi

# 4. git commit in linked worktree + uv:pending, all others complete → approve (uv skipped in worktree)
PAIR_4="$(setup_linked_worktree "secA-wt4")"
WT_4="${PAIR_4#*|}"
SID_4="a4-$$"
write_state "$SID_4" "$(state_json "$SID_4" "feature/secA-wt4" "pending" "complete")"
echo "wt4-change" > "$WT_4/change.txt"
git -C "$WT_4" add change.txt
RES_4="$(run_gate "$WT_4" "$(build_gate_json 'git commit -m x' "$SID_4" "$WT_4")")"
if is_approve "$RES_4"; then pass "A4. git commit in worktree + uv:pending → approve (uv skipped)"
else fail "A4. expected approve (worktree uv-skip), got: $RES_4"; fi

# 5. git commit in main checkout + uv:pending → block
SID_5="a5-$$"
write_state "$SID_5" "$(state_json "$SID_5" "main" "pending" "complete")"
RES_5="$(run_gate "$REPO_A" "$(build_gate_json 'git commit -m x' "$SID_5" "$REPO_A")")"
if is_block "$RES_5"; then pass "A5. git commit in main checkout + uv:pending → block"
else fail "A5. expected block, got: $RES_5"; fi

# 6. gh pr merge + uv:pending → block, output mentions WORKFLOW_USER_VERIFIED
SID_6="a6-$$"
write_state "$SID_6" "$(state_json "$SID_6" "main" "pending" "complete")"
RES_6="$(run_gate "$REPO_A" "$(build_gate_json 'gh pr merge --squash' "$SID_6" "$REPO_A")")"
if is_block "$RES_6" && echo "$RES_6" | grep -q "WORKFLOW_USER_VERIFIED"; then
    pass "A6. gh pr merge + uv:pending → block w/ USER_VERIFIED hint"
else
    fail "A6. expected block+USER_VERIFIED hint, got: $RES_6"
fi

# ============================================================================
# Section B: Error — merge gate fail-safe (7)
# ============================================================================
echo ""
echo "=== Section B: Merge gate (error / fail-safe) ==="

# 7. gh pr merge + uv:missing entry → block
SID_7="b7-$$"
write_state "$SID_7" "$(cat <<EOF
{
  "version": 1, "session_id": "$SID_7", "git_branch": "main",
  "created_at": "$NOW_ISO",
  "steps": {
    "research":        {"status": "complete", "updated_at": "$NOW_ISO"},
    "plan":            {"status": "complete", "updated_at": "$NOW_ISO"},
    "write_tests":     {"status": "complete", "updated_at": "$NOW_ISO"},
    "review_security": {"status": "complete", "updated_at": "$NOW_ISO"},
    "run_tests":       {"status": "complete", "updated_at": "$NOW_ISO"},
    "docs":            {"status": "complete", "updated_at": "$NOW_ISO"}
  }
}
EOF
)"
RES_7="$(run_gate "$REPO_A" "$(build_gate_json 'gh pr merge --squash' "$SID_7" "$REPO_A")")"
if is_block "$RES_7"; then pass "B7. gh pr merge + uv missing → block (fail-safe)"
else fail "B7. expected block, got: $RES_7"; fi

# 8. gh pr merge + no session state at all → block
SID_8="b8-$$"
RES_8="$(run_gate "$REPO_A" "$(build_gate_json 'gh pr merge --squash' "$SID_8" "$REPO_A")")"
if is_block "$RES_8"; then pass "B8. gh pr merge + no state → block (fail-safe)"
else fail "B8. expected block, got: $RES_8"; fi

# 9. git push origin main + uv:skipped → block
SID_9="b9-$$"
write_state "$SID_9" "$(state_json "$SID_9" "main" "skipped" "complete")"
RES_9="$(run_gate "$REPO_A" "$(build_gate_json 'git push origin main' "$SID_9" "$REPO_A")")"
if is_block "$RES_9"; then pass "B9. git push origin main + uv:skipped → block"
else fail "B9. expected block (skipped != complete), got: $RES_9"; fi

# 10. git push --all origin + uv:pending → block
SID_10="b10-$$"
write_state "$SID_10" "$(state_json "$SID_10" "main" "pending" "complete")"
RES_10="$(run_gate "$REPO_A" "$(build_gate_json 'git push --all origin' "$SID_10" "$REPO_A")")"
if is_block "$RES_10"; then pass "B10. git push --all + uv:pending → block"
else fail "B10. expected block, got: $RES_10"; fi

# 11. git --no-pager push origin main + uv:pending → block
SID_11="b11-$$"
write_state "$SID_11" "$(state_json "$SID_11" "main" "pending" "complete")"
RES_11="$(run_gate "$REPO_A" "$(build_gate_json 'git --no-pager push origin main' "$SID_11" "$REPO_A")")"
if is_block "$RES_11"; then pass "B11. git --no-pager push origin main + uv:pending → block"
else fail "B11. expected block, got: $RES_11"; fi

# 12. git push --mirror origin + uv:pending → block
SID_12="b12-$$"
write_state "$SID_12" "$(state_json "$SID_12" "main" "pending" "complete")"
RES_12="$(run_gate "$REPO_A" "$(build_gate_json 'git push --mirror origin' "$SID_12" "$REPO_A")")"
if is_block "$RES_12"; then pass "B12. git push --mirror + uv:pending → block"
else fail "B12. expected block, got: $RES_12"; fi

# 13. ENFORCE_WORKTREE=off + gh pr merge + uv:pending → block (merge gate is unconditional)
SID_13="b13-$$"
write_state "$SID_13" "$(state_json "$SID_13" "main" "pending" "complete")"
RES_13="$(run_gate "$REPO_A" "$(build_gate_json 'gh pr merge --squash' "$SID_13" "$REPO_A")" ENFORCE_WORKTREE=off)"
if is_block "$RES_13"; then pass "B13. ENFORCE_WORKTREE=off + gh pr merge + uv:pending → block (unconditional)"
else fail "B13. expected block (merge gate unconditional), got: $RES_13"; fi

# ============================================================================
# Section C: Edge (4)
# ============================================================================
echo ""
echo "=== Section C: Merge gate (edge) ==="

# 14. Detached HEAD in worktree + git commit + uv:pending → block
PAIR_14="$(setup_linked_worktree "secC-wt14")"
WT_14="${PAIR_14#*|}"
SHA_14="$(git -C "$WT_14" rev-parse HEAD)"
git -C "$WT_14" checkout -q "$SHA_14"
SID_14="c14-$$"
write_state "$SID_14" "$(state_json "$SID_14" "null" "pending" "complete")"
RES_14="$(run_gate "$WT_14" "$(build_gate_json 'git commit -m x' "$SID_14" "$WT_14")")"
if is_block "$RES_14"; then pass "C14. detached HEAD in worktree + uv:pending → block"
else fail "C14. expected block (detached HEAD is not feature-branch worktree context), got: $RES_14"; fi

# 15. Linked worktree on protected branch (e.g. main) + git commit + uv:pending → block
PAIR_15="$(setup_linked_worktree "secC-wt15")"
MAIN_15="${PAIR_15%|*}"
WT_15="${PAIR_15#*|}"
git -C "$WT_15" checkout -q -b temp-redirect 2>/dev/null || true
git -C "$WT_15" checkout -q main 2>/dev/null || true
SID_15="c15-$$"
write_state "$SID_15" "$(state_json "$SID_15" "main" "pending" "complete")"
RES_15="$(run_gate "$WT_15" "$(build_gate_json 'git commit -m x' "$SID_15" "$WT_15")")"
if is_block "$RES_15"; then pass "C15. worktree on protected branch + uv:pending → block (only feature branches skip)"
else fail "C15. expected block (worktree on protected), got: $RES_15"; fi

# 16. git commit in worktree + uv:pending, docs:pending → block on docs (uv-skip independent)
PAIR_16="$(setup_linked_worktree "secC-wt16")"
WT_16="${PAIR_16#*|}"
SID_16="c16-$$"
write_state "$SID_16" "$(state_json_custom "$SID_16" "feature/secC-wt16" \
    docs pending user_verification pending)"
RES_16="$(run_gate "$WT_16" "$(build_gate_json 'git commit -m x' "$SID_16" "$WT_16")")"
if is_block "$RES_16" && echo "$RES_16" | grep -qi "docs"; then
    pass "C16. worktree commit + docs:pending → block on docs (uv-skip independent)"
else
    fail "C16. expected block-on-docs, got: $RES_16"
fi

# 17. Idempotency: gh pr merge + uv:pending twice → both block, state unchanged
SID_17="c17-$$"
write_state "$SID_17" "$(state_json "$SID_17" "main" "pending" "complete")"
SNAPSHOT_17_BEFORE="$(cat "$WORKFLOW_DIR/${SID_17}.json")"
RES_17A="$(run_gate "$REPO_A" "$(build_gate_json 'gh pr merge --squash' "$SID_17" "$REPO_A")")"
RES_17B="$(run_gate "$REPO_A" "$(build_gate_json 'gh pr merge --squash' "$SID_17" "$REPO_A")")"
SNAPSHOT_17_AFTER="$(cat "$WORKFLOW_DIR/${SID_17}.json")"
if is_block "$RES_17A" && is_block "$RES_17B" && [ "$SNAPSHOT_17_BEFORE" = "$SNAPSHOT_17_AFTER" ]; then
    pass "C17. gh pr merge x2 → both block; state unchanged (idempotent)"
else
    fail "C17. idempotency: a=$RES_17A b=$RES_17B state-equal=$([ "$SNAPSHOT_17_BEFORE" = "$SNAPSHOT_17_AFTER" ] && echo yes || echo no)"
fi

# ============================================================================
# Section D: workflow-mark.js push reset (4)
# ============================================================================
echo ""
echo "=== Section D: workflow-mark push reset ==="

REPO_D="$(setup_main_checkout "secD-repo")"

# 18. Feature branch push success → uv stays at "complete"
SID_18="d18-$$"
write_state "$SID_18" "$(state_json "$SID_18" "feature/x" "complete" "complete")"
run_mark "$REPO_D" "$(build_mark_json 'git push origin feature/x' "$SID_18" 0 "$REPO_D")" >/dev/null
UV_18="$(read_state_step "$SID_18" "user_verification")"
if [ "$UV_18" = "complete" ]; then
    pass "D18. feature branch push → uv stays complete"
else
    fail "D18. expected uv=complete, got: $UV_18"
fi

# 19. Protected branch push success → uv reset to "pending"
SID_19="d19-$$"
write_state "$SID_19" "$(state_json "$SID_19" "main" "complete" "complete")"
run_mark "$REPO_D" "$(build_mark_json 'git push origin main' "$SID_19" 0 "$REPO_D")" >/dev/null
UV_19="$(read_state_step "$SID_19" "user_verification")"
if [ "$UV_19" = "pending" ]; then
    pass "D19. protected branch push → uv reset to pending"
else
    fail "D19. expected uv=pending, got: $UV_19"
fi

# 20. Feature branch push success → last_pushed_sha NOT set (setLastPushedSha not called)
SID_20="d20-$$"
write_state "$SID_20" "$(state_json "$SID_20" "feature/x" "complete" "complete")"
SHA_20_BEFORE="$(read_state_field "$SID_20" "last_pushed_sha")"
run_mark "$REPO_D" "$(build_mark_json 'git push origin feature/x' "$SID_20" 0 "$REPO_D")" >/dev/null
SHA_20_AFTER="$(read_state_field "$SID_20" "last_pushed_sha")"
if [ "$SHA_20_BEFORE" = "$SHA_20_AFTER" ]; then
    pass "D20. feature branch push → last_pushed_sha unchanged"
else
    fail "D20. last_pushed_sha changed: before=$SHA_20_BEFORE after=$SHA_20_AFTER"
fi

# 21. gh pr merge success → uv reset to "pending", last_pushed_sha NOT changed
SID_21="d21-$$"
write_state "$SID_21" "$(state_json "$SID_21" "main" "complete" "complete")"
SHA_21_BEFORE="$(read_state_field "$SID_21" "last_pushed_sha")"
run_mark "$REPO_D" "$(build_mark_json 'gh pr merge --squash' "$SID_21" 0 "$REPO_D")" >/dev/null
UV_21="$(read_state_step "$SID_21" "user_verification")"
SHA_21_AFTER="$(read_state_field "$SID_21" "last_pushed_sha")"
if [ "$UV_21" = "pending" ] && [ "$SHA_21_BEFORE" = "$SHA_21_AFTER" ]; then
    pass "D21. gh pr merge success → uv=pending; last_pushed_sha unchanged"
else
    fail "D21. uv=$UV_21 sha_before=$SHA_21_BEFORE sha_after=$SHA_21_AFTER"
fi

# ============================================================================
# Section E: review-code-codex staged-diff fallback (3)
# ============================================================================
echo ""
echo "=== Section E: review-code-codex staged fallback ==="

if [ ! -f "$CODEX_BIN" ]; then
    fail "E22 (review-code-codex not found at $CODEX_BIN)"
    fail "E23 (review-code-codex not found)"
    fail "E24 (review-code-codex not found)"
else
    # Mock codex bin — use a Unix-style path so PATH parsing on Git Bash
    # does not split on the drive-letter colon (e.g. "C:/Users/...").
    if command -v cygpath >/dev/null 2>&1; then
        MOCK_BIN_PATH="$(cygpath -u "$TMPDIR_BASE/mock-bin")"
    else
        MOCK_BIN_PATH="$TMPDIR_BASE/mock-bin"
    fi
    MOCK_BIN="$TMPDIR_BASE/mock-bin"
    mkdir -p "$MOCK_BIN"
    SENTINEL_STAGED="STAGED_SENTINEL_X9Q3Z"
    SENTINEL_COMMIT="COMMIT_SENTINEL_W4P7M"
    CAPTURE="$TMPDIR_BASE/codex-capture.txt"

    write_codex_capture_mock() {
        cat > "$MOCK_BIN/codex" <<MOCK_EOF
#!/usr/bin/env bash
cat > "$CAPTURE"
echo "ok"
exit 0
MOCK_EOF
        chmod +x "$MOCK_BIN/codex"
    }

    # 22. Fresh branch (no commits past base) + staged content → PERFORMED, staged content forwarded
    REPO_22="$TMPDIR_BASE/codex-repo-22"
    mkdir -p "$REPO_22"
    git -C "$REPO_22" init -q -b main
    git -C "$REPO_22" config user.email "test@example.com"
    git -C "$REPO_22" config user.name "Test"
    git -C "$REPO_22" config core.hooksPath /dev/null
    echo "init" > "$REPO_22/README.md"
    git -C "$REPO_22" add README.md
    git -C "$REPO_22" commit -q -m "initial"
    # Branch but no commits past base
    git -C "$REPO_22" checkout -q -b feature-22
    echo "$SENTINEL_STAGED line" > "$REPO_22/staged.txt"
    git -C "$REPO_22" add staged.txt
    write_codex_capture_mock
    rm -f "$CAPTURE"
    OUT_22="$(cd "$REPO_22" && PATH="$MOCK_BIN_PATH:$PATH" HOME="$TMPDIR_BASE" \
        run_with_timeout 60 bash "$CODEX_BIN" --base main --no-log 2>&1 || true)"
    if echo "$OUT_22" | grep -q "## Codex Review: PERFORMED" && \
       [ -f "$CAPTURE" ] && grep -q "$SENTINEL_STAGED" "$CAPTURE"; then
        pass "E22. fresh branch + staged → PERFORMED with staged diff forwarded"
    else
        fail "E22. expected PERFORMED+staged-sentinel; capture-exists=$([ -f "$CAPTURE" ] && echo y || echo n) out: $OUT_22"
    fi

    # 23. Fresh branch, no commits, no staged → SKIPPED mentioning empty
    REPO_23="$TMPDIR_BASE/codex-repo-23"
    mkdir -p "$REPO_23"
    git -C "$REPO_23" init -q -b main
    git -C "$REPO_23" config user.email "test@example.com"
    git -C "$REPO_23" config user.name "Test"
    git -C "$REPO_23" config core.hooksPath /dev/null
    echo "init" > "$REPO_23/README.md"
    git -C "$REPO_23" add README.md
    git -C "$REPO_23" commit -q -m "initial"
    git -C "$REPO_23" checkout -q -b feature-23
    write_codex_capture_mock
    OUT_23="$(cd "$REPO_23" && PATH="$MOCK_BIN_PATH:$PATH" HOME="$TMPDIR_BASE" \
        run_with_timeout 60 bash "$CODEX_BIN" --base main --no-log 2>&1 || true)"
    if echo "$OUT_23" | grep -q "## Codex Review: SKIPPED" && echo "$OUT_23" | grep -qi "empty"; then
        pass "E23. fresh branch + no staged → SKIPPED (empty)"
    else
        fail "E23. expected SKIPPED+empty; got: $OUT_23"
    fi

    # 24. Branch has commits past base + also has staged → PERFORMED based on committed diff;
    #     staged sentinel NOT in prompt
    REPO_24="$TMPDIR_BASE/codex-repo-24"
    mkdir -p "$REPO_24"
    git -C "$REPO_24" init -q -b main
    git -C "$REPO_24" config user.email "test@example.com"
    git -C "$REPO_24" config user.name "Test"
    git -C "$REPO_24" config core.hooksPath /dev/null
    echo "init" > "$REPO_24/README.md"
    git -C "$REPO_24" add README.md
    git -C "$REPO_24" commit -q -m "initial"
    git -C "$REPO_24" checkout -q -b feature-24
    echo "$SENTINEL_COMMIT line" > "$REPO_24/committed.txt"
    git -C "$REPO_24" add committed.txt
    git -C "$REPO_24" commit -q -m "feature commit"
    # Add staged-only content with a different sentinel
    echo "$SENTINEL_STAGED line" > "$REPO_24/staged-only.txt"
    git -C "$REPO_24" add staged-only.txt
    write_codex_capture_mock
    rm -f "$CAPTURE"
    OUT_24="$(cd "$REPO_24" && PATH="$MOCK_BIN_PATH:$PATH" HOME="$TMPDIR_BASE" \
        run_with_timeout 60 bash "$CODEX_BIN" --base main --no-log 2>&1 || true)"
    if echo "$OUT_24" | grep -q "## Codex Review: PERFORMED" \
       && [ -f "$CAPTURE" ] \
       && grep -q "$SENTINEL_COMMIT" "$CAPTURE" \
       && ! grep -q "$SENTINEL_STAGED" "$CAPTURE"; then
        pass "E24. branch w/ commits + staged → PERFORMED on committed only (no staged sentinel)"
    else
        fail "E24. expected PERFORMED+commit-sentinel only; capture-exists=$([ -f "$CAPTURE" ] && echo y || echo n) out: $OUT_24"
    fi
fi

# ============================================================================
# Results
# ============================================================================
echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
