#!/bin/bash
# tests/feature-1071-tier2-worktree-copy-worker.sh
# Tests: agents/worktree-copy-worker.md, skills/worktree-start/SKILL.md
# Tags: static, agent, worker, worktree-copy, worktree-start, scope:issue-specific
#
# Tier 2 static contract test for issue #1071 (skill/agent fork+worker audit).
# Verifies the new worktree-copy-worker agent and associated worktree-start changes.
# Expected RED until #1071 creates agents/worktree-copy-worker.md and updates
# skills/worktree-start/SKILL.md.
#
# L3 gap (what this test does NOT catch):
# - actual worker invocation (requires real claude -p agent dispatch)
# - runtime copy correctness for gitignored files
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKER_MD="${AGENTS_DIR}/agents/worktree-copy-worker.md"
WS_MD="${AGENTS_DIR}/skills/worktree-start/SKILL.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }

# ── Test 1: worker file exists ────────────────────────────────────────────────
test_worker_exists() {
    if [ -f "$WORKER_MD" ]; then
        pass "1: agents/worktree-copy-worker.md exists"
    else
        fail "1: agents/worktree-copy-worker.md missing"
    fi
}

# ── Test 2: output contract has exactly 3 lines (status/summary/artifact_path) ─
test_output_contract_lines() {
    if [ ! -f "$WORKER_MD" ]; then
        fail "2: worker missing — cannot check output contract"
        return
    fi
    local has_status has_summary has_artifact
    has_status=0; has_summary=0; has_artifact=0
    grep -qE '^status:' "$WORKER_MD" && has_status=1
    grep -qE '^summary:' "$WORKER_MD" && has_summary=1
    grep -qE '^artifact_path:' "$WORKER_MD" && has_artifact=1
    if [ "$has_status" -eq 1 ] && [ "$has_summary" -eq 1 ] && [ "$has_artifact" -eq 1 ]; then
        pass "2: output contract has status:/summary:/artifact_path: lines"
    else
        fail "2: output contract incomplete" "status=$has_status summary=$has_summary artifact_path=$has_artifact"
    fi
}

# ── Test 3: status enum documents complete|partial|failed ─────────────────────
test_status_enum() {
    if [ ! -f "$WORKER_MD" ]; then
        fail "3: worker missing — cannot check status enum"
        return
    fi
    local has_complete has_partial has_failed
    has_complete=0; has_partial=0; has_failed=0
    grep -qF 'complete' "$WORKER_MD" && has_complete=1
    grep -qF 'partial'  "$WORKER_MD" && has_partial=1
    grep -qF 'failed'   "$WORKER_MD" && has_failed=1
    if [ "$has_complete" -eq 1 ] && [ "$has_partial" -eq 1 ] && [ "$has_failed" -eq 1 ]; then
        pass "3: status enum documents complete, partial, failed"
    else
        fail "3: status enum missing variants" "complete=$has_complete partial=$has_partial failed=$has_failed"
    fi
}

# ── Test 4: no sentinels, AskUserQuestion, or skill invocations in worker ─────
test_no_sentinels_no_ask_no_skills() {
    if [ ! -f "$WORKER_MD" ]; then
        fail "4: worker missing — cannot check prohibited content"
        return
    fi
    local found_sentinel found_ask found_skill_invoke
    found_sentinel=0; found_ask=0; found_skill_invoke=0
    grep -qE '<<WORKFLOW_' "$WORKER_MD" && found_sentinel=1
    grep -qF 'AskUserQuestion' "$WORKER_MD" && found_ask=1
    # skill invocation pattern: /skill-name or Skill tool call
    grep -qE '`/[a-z]' "$WORKER_MD" && found_skill_invoke=1
    if [ "$found_sentinel" -eq 0 ] && [ "$found_ask" -eq 0 ] && [ "$found_skill_invoke" -eq 0 ]; then
        pass "4: worker has no sentinels, AskUserQuestion, or skill invocations"
    else
        fail "4: worker contains prohibited content" "sentinels=$found_sentinel ask=$found_ask skill_invoke=$found_skill_invoke"
    fi
}

# ── Test 5: input contract has all 6 required fields ─────────────────────────
test_input_contract_fields() {
    if [ ! -f "$WORKER_MD" ]; then
        fail "5: worker missing — cannot check input contract"
        return
    fi
    local fields="main_root worktree_path branch session_id agents_config_dir artifact_dir"
    local missing=""
    for field in $fields; do
        if ! grep -qF "$field" "$WORKER_MD"; then
            missing="$missing $field"
        fi
    done
    if [ -z "$missing" ]; then
        pass "5: input contract has all 6 required fields"
    else
        fail "5: input contract missing fields:$missing"
    fi
}

# ── Test 6: worktree-start SKILL.md references worktree-copy-worker ──────────
test_ws_references_worker() {
    if [ ! -f "$WS_MD" ]; then
        fail "6: skills/worktree-start/SKILL.md missing"
        return
    fi
    if grep -qF 'worktree-copy-worker' "$WS_MD"; then
        pass "6: worktree-start SKILL.md references worktree-copy-worker"
    else
        fail "6: worktree-start SKILL.md missing reference to worktree-copy-worker"
    fi
}

# ── Test 7: worktree-start has CONFIRM_WORKTREE=ON path with AskUserQuestion ──
test_ws_confirm_worktree_ask() {
    if [ ! -f "$WS_MD" ]; then
        fail "7: skills/worktree-start/SKILL.md missing"
        return
    fi
    local has_confirm has_ask
    has_confirm=0; has_ask=0
    grep -qF 'CONFIRM_WORKTREE' "$WS_MD" && has_confirm=1
    grep -qF 'AskUserQuestion' "$WS_MD" && has_ask=1
    if [ "$has_confirm" -eq 1 ] && [ "$has_ask" -eq 1 ]; then
        pass "7: worktree-start has CONFIRM_WORKTREE check and AskUserQuestion"
    else
        fail "7: worktree-start missing CONFIRM_WORKTREE or AskUserQuestion" "confirm=$has_confirm ask=$has_ask"
    fi
}

# ── Test 8: WS-10 and WS-11 step labels no longer both present (renumbered) ──
# After the split, the step that was WS-11 should shift. Either WS-11 is gone
# (renumbered up), or only a single WS-11 exists (the new final step).
# We assert that WS-10 is no longer the WORKTREE_NOTES step (it moved earlier
# to accommodate the new copy-worker step), detected by checking that
# WS-9b no longer uses bin/worktree-copy-include.js inline shell pipe
# (the worker replaced that inline logic).
test_ws_inline_copy_replaced() {
    if [ ! -f "$WS_MD" ]; then
        fail "8: skills/worktree-start/SKILL.md missing"
        return
    fi
    # After #1071: WS-9b dispatches to the worker agent, not the inline pipe
    # The old inline invocation piped to bin/worktree-copy-include.js
    if grep -qF 'worktree-copy-include.js' "$WS_MD"; then
        fail "8: worktree-start still uses inline bin/worktree-copy-include.js (not replaced by worker)"
    else
        pass "8: worktree-start no longer uses inline bin/worktree-copy-include.js (replaced by worker)"
    fi
}

test_worker_exists
test_output_contract_lines
test_status_enum
test_no_sentinels_no_ask_no_skills
test_input_contract_fields
test_ws_references_worker
test_ws_confirm_worktree_ask
test_ws_inline_copy_replaced

# ── Tests 9-10: worktree-copy-include.js argv form + legacy stdin backward-compat ──
# Added for #1102: bin/worktree-copy-include.js gained a new argv form
# (--main-root / --worktree-path / --include-file) while keeping legacy stdin JSON.
# Both forms must produce a JSON object with {copied, skipped, denied, errors}.

COPY_INCLUDE_SCRIPT="${AGENTS_DIR}/bin/worktree-copy-include.js"

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

_TMPDIR_1071="$(mktemp -d)"
trap 'rm -rf "$_TMPDIR_1071"' EXIT

# Create a minimal git-repo fixture (main worktree) with a .worktreeinclude file
# and a gitignored file that should be copied.
_MAIN_ROOT="$_TMPDIR_1071/main"
_WORKTREE_PATH="$_TMPDIR_1071/wt"
mkdir -p "$_MAIN_ROOT" "$_WORKTREE_PATH"
git -C "$_MAIN_ROOT" -c init.defaultBranch=main init --quiet
git -C "$_MAIN_ROOT" config user.email "test@example.com"
git -C "$_MAIN_ROOT" config user.name "Test"
git -C "$_MAIN_ROOT" config core.hooksPath /dev/null
# Track a source file.
printf 'tracked\n' > "$_MAIN_ROOT/tracked.md"
git -C "$_MAIN_ROOT" add tracked.md
git -C "$_MAIN_ROOT" commit --quiet -m "init"
# Create a gitignored file by adding it to .gitignore.
printf '*.secret\n' > "$_MAIN_ROOT/.gitignore"
printf 'secret content\n' > "$_MAIN_ROOT/config.secret"
git -C "$_MAIN_ROOT" add .gitignore
git -C "$_MAIN_ROOT" commit --quiet -m "add gitignore"
# Write .worktreeinclude to include *.secret files.
printf '*.secret\n' > "$_MAIN_ROOT/.worktreeinclude"

# Helper: check JSON output has the four expected keys.
_has_result_keys() {
    node -e "
      try {
        const o = JSON.parse(process.argv[1]);
        const ok = ['copied','skipped','denied','errors'].every(k => Array.isArray(o[k]));
        process.stdout.write(ok ? 'yes' : 'no');
      } catch(e) { process.stdout.write('no: ' + e.message); }
    " "$1" 2>/dev/null
}

# ── Test 9: argv form runs and produces expected output ───────────────────────
test_argv_form() {
    if [ ! -f "$COPY_INCLUDE_SCRIPT" ]; then
        fail "9: bin/worktree-copy-include.js missing"
        return
    fi
    local out rc
    out=$(run_with_timeout 30 node "$COPY_INCLUDE_SCRIPT" \
        --main-root "$_MAIN_ROOT" \
        --worktree-path "$_WORKTREE_PATH" 2>/dev/null)
    rc=$?
    local has_keys
    has_keys=$(_has_result_keys "$out")
    # config.secret should be in copied[] (matched by .worktreeinclude, gitignored).
    local copied
    copied=$(node -e "
      try {
        const o = JSON.parse(process.argv[1]);
        process.stdout.write(JSON.stringify(o.copied));
      } catch(e) { process.stdout.write('[]'); }
    " "$out" 2>/dev/null)
    # Content assertion (anti-false-green): config.secret (gitignored, matched by
    # .worktreeinclude) MUST appear in copied[]. A silently-broken copy that emits
    # an empty copied[] now FAILS instead of passing on key-presence alone.
    local has_secret
    has_secret=$(node -e "
      try {
        const o = JSON.parse(process.argv[1]);
        const found = Array.isArray(o.copied) &&
          o.copied.some(p => /(^|[\\\\/])config\.secret$/.test(String(p)));
        process.stdout.write(found ? 'yes' : 'no');
      } catch(e) { process.stdout.write('no'); }
    " "$out" 2>/dev/null)
    if [ "$rc" -eq 0 ] && [ "$has_keys" = "yes" ] && [ "$has_secret" = "yes" ]; then
        pass "9: argv form copies gitignored config.secret into copied[] (rc=0, has_keys=yes, copied=$copied)"
    else
        fail "9: argv form" "rc=$rc has_keys=$has_keys has_secret=$has_secret out='$out'"
    fi
}

# ── Test 10: legacy stdin JSON form still works (backward-compat) ─────────────
test_legacy_stdin_form() {
    if [ ! -f "$COPY_INCLUDE_SCRIPT" ]; then
        fail "10: bin/worktree-copy-include.js missing"
        return
    fi
    # Use a fresh destination to avoid interference from test 9.
    local wt2="$_TMPDIR_1071/wt2"
    mkdir -p "$wt2"
    local json_input
    json_input=$(node -e "process.stdout.write(JSON.stringify({mainRoot: process.argv[1], worktreePath: process.argv[2], includeFile: null}))" \
        "$_MAIN_ROOT" "$wt2" 2>/dev/null)
    local out rc
    out=$(printf '%s' "$json_input" | run_with_timeout 30 node "$COPY_INCLUDE_SCRIPT" 2>/dev/null)
    rc=$?
    local has_keys
    has_keys=$(_has_result_keys "$out")
    # Content assertion (anti-false-green): same as T9 — config.secret must be copied.
    local has_secret
    has_secret=$(node -e "
      try {
        const o = JSON.parse(process.argv[1]);
        const found = Array.isArray(o.copied) &&
          o.copied.some(p => /(^|[\\\\/])config\.secret$/.test(String(p)));
        process.stdout.write(found ? 'yes' : 'no');
      } catch(e) { process.stdout.write('no'); }
    " "$out" 2>/dev/null)
    if [ "$rc" -eq 0 ] && [ "$has_keys" = "yes" ] && [ "$has_secret" = "yes" ]; then
        pass "10: legacy stdin JSON form copies gitignored config.secret into copied[] (backward-compat)"
    else
        fail "10: legacy stdin form" "rc=$rc has_keys=$has_keys has_secret=$has_secret out='$out'"
    fi
}

test_argv_form
test_legacy_stdin_form

# ── Tests 11-13: SECURITY — CWE-22 path-traversal guard (hasTraversal gate) ───
# bin/worktree-copy-include.js rejects any path field whose normalized form
# contains a `..` segment (lines: hasTraversal + exit 1). Each test supplies a
# `..` segment in one field and asserts rc != 0. The argv branch is only taken
# when --main-root is present, so the worktree-path and include-file cases keep a
# valid --main-root and inject the traversal into the field under test.

# ── Test 11: --main-root with `..` traversal → exit non-zero ──────────────────
test_traversal_main_root() {
    if [ ! -f "$COPY_INCLUDE_SCRIPT" ]; then
        fail "11: bin/worktree-copy-include.js missing"
        return
    fi
    local rc
    run_with_timeout 30 node "$COPY_INCLUDE_SCRIPT" \
        --main-root "$_TMPDIR_1071/../etc/passwd" \
        --worktree-path "$_WORKTREE_PATH" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        pass "11: SECURITY — --main-root with '..' traversal → rc=$rc (non-zero)"
    else
        fail "11: traversal main-root not rejected" "rc=$rc (expected non-zero)"
    fi
}

# ── Test 12: --worktree-path with `..` traversal → exit non-zero ──────────────
test_traversal_worktree_path() {
    if [ ! -f "$COPY_INCLUDE_SCRIPT" ]; then
        fail "12: bin/worktree-copy-include.js missing"
        return
    fi
    local rc
    run_with_timeout 30 node "$COPY_INCLUDE_SCRIPT" \
        --main-root "$_MAIN_ROOT" \
        --worktree-path "$_TMPDIR_1071/../evil/wt" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        pass "12: SECURITY — --worktree-path with '..' traversal → rc=$rc (non-zero)"
    else
        fail "12: traversal worktree-path not rejected" "rc=$rc (expected non-zero)"
    fi
}

# ── Test 13: --include-file with `..` traversal → exit non-zero ───────────────
# Source guards includeFile too: `if (input.includeFile && hasTraversal(...))`.
test_traversal_include_file() {
    if [ ! -f "$COPY_INCLUDE_SCRIPT" ]; then
        fail "13: bin/worktree-copy-include.js missing"
        return
    fi
    local rc
    run_with_timeout 30 node "$COPY_INCLUDE_SCRIPT" \
        --main-root "$_MAIN_ROOT" \
        --worktree-path "$_WORKTREE_PATH" \
        --include-file "$_TMPDIR_1071/../evil/.worktreeinclude" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        pass "13: SECURITY — --include-file with '..' traversal → rc=$rc (non-zero)"
    else
        fail "13: traversal include-file not rejected" "rc=$rc (expected non-zero)"
    fi
}

test_traversal_main_root
test_traversal_worktree_path
test_traversal_include_file

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
