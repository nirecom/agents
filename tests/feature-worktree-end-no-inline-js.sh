#!/bin/bash
# tests/feature-worktree-end-no-inline-js.sh
# Tests: skills/worktree-end/SKILL.md, skills/worktree-end/scripts, skills/worktree-end/scripts/
# Tags: worktree-end-no-inline-js
#
# Verifies the worktree-end SKILL.md shrink (#611):
#   - All inline `node -e` invocations are extracted to skills/worktree-end/scripts/*.
#   - SKILL.md is <= 200 lines.
#   - New helper scripts behave per contract (extract-pr-fields, read-notes-path,
#     write-env-json, capture-env).
#
# Test-first: the helper scripts and the shrunk SKILL.md do not exist yet.
# Tests are expected to FAIL prior to implementation; they must not produce
# bash syntax errors.

set -u

# ---- AGENTS_CONFIG_DIR resolution + early SKIP guard --------------------
if [ -z "${AGENTS_CONFIG_DIR:-}" ]; then
    # Fall back to the repo containing this test file (worktree root).
    AGENTS_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

if [ ! -d "$AGENTS_CONFIG_DIR" ]; then
    echo "SKIP: AGENTS_CONFIG_DIR not set / not a directory"
    exit 0
fi

if command -v cygpath >/dev/null 2>&1; then
    AGENTS_CONFIG_DIR_NODE="$(cygpath -m "$AGENTS_CONFIG_DIR")"
else
    AGENTS_CONFIG_DIR_NODE="$AGENTS_CONFIG_DIR"
fi

SKILL_MD="$AGENTS_CONFIG_DIR/skills/worktree-end/SKILL.md"
SCRIPTS_DIR="$AGENTS_CONFIG_DIR/skills/worktree-end/scripts"
SCRIPTS_DIR_NODE="$AGENTS_CONFIG_DIR_NODE/skills/worktree-end/scripts"

CAPTURE_ENV="$SCRIPTS_DIR/capture-env.sh"
WRITE_ENV_JSON="$SCRIPTS_DIR_NODE/write-env-json.js"
EXTRACT_PR_FIELDS="$SCRIPTS_DIR_NODE/extract-pr-fields.js"
READ_NOTES_PATH="$SCRIPTS_DIR_NODE/read-notes-path.js"

PASS=0; FAIL=0; SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout "$1" "${@:2}"
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift; exec @ARGV' "$@"
    else
        "${@:2}"
    fi
}

# ---- Test 1: no `node -e` in SKILL.md -----------------------------------
test_no_inline_node_e() {
    if [ ! -f "$SKILL_MD" ]; then
        fail "T1: SKILL.md not found at $SKILL_MD"
        return
    fi
    if grep -nE 'node[[:space:]]+-e' "$SKILL_MD" >/dev/null 2>&1; then
        fail "T1: SKILL.md still contains 'node -e' patterns"
        return
    fi
    pass "T1: SKILL.md has no inline 'node -e'"
}

# ---- Test 2: SKILL.md line count <= 200 ---------------------------------
test_skill_md_line_count() {
    if [ ! -f "$SKILL_MD" ]; then
        fail "T2: SKILL.md not found"
        return
    fi
    local lines
    lines=$(wc -l < "$SKILL_MD")
    # Strip whitespace
    lines=$(echo "$lines" | tr -d '[:space:]')
    if [ "$lines" -le 200 ]; then
        pass "T2: SKILL.md is $lines lines (<=200)"
    else
        fail "T2: SKILL.md is $lines lines (>200)"
    fi
}

# ---- Test 3: 4 lib scripts exist; capture-env.sh executable ------------
test_lib_scripts_present() {
    local missing=0
    for f in capture-env.sh write-env-json.js extract-pr-fields.js read-notes-path.js; do
        if [ ! -f "$SCRIPTS_DIR/$f" ]; then
            fail "T3: missing $SCRIPTS_DIR/$f"
            missing=1
        fi
    done
    if [ "$missing" -eq 1 ]; then
        return
    fi
    if [ ! -x "$CAPTURE_ENV" ]; then
        fail "T3: capture-env.sh not executable"
        return
    fi
    pass "T3: 4 lib scripts present; capture-env.sh executable"
}

# ---- Test 4: extract-pr-fields.js --fields title,url,state -------------
test_extract_pr_fields() {
    if [ ! -f "$EXTRACT_PR_FIELDS" ]; then
        skip "T4: extract-pr-fields.js not implemented yet"
        return
    fi
    local out
    out=$(printf '{"title":"hello","url":"https://x","state":"OPEN"}' \
          | run_with_timeout 30 node "$EXTRACT_PR_FIELDS" --fields title,url,state 2>&1) || {
        fail "T4: extract-pr-fields exited non-zero: $out"
        return
    }
    local err=0
    echo "$out" | grep -qx 'title=hello' || { fail "T4: missing 'title=hello' in output"; err=1; }
    echo "$out" | grep -qx 'url=https://x' || { fail "T4: missing 'url=https://x' in output"; err=1; }
    echo "$out" | grep -qx 'state=OPEN' || { fail "T4: missing 'state=OPEN' in output"; err=1; }
    [ "$err" -eq 0 ] && pass "T4: extract-pr-fields returns 3 fields in one call"
}

# ---- Test 5: read-notes-path.js 4 branches -----------------------------
test_read_notes_path() {
    if [ ! -f "$READ_NOTES_PATH" ]; then
        skip "T5: read-notes-path.js not implemented yet"
        return
    fi
    local tmp out err=0
    # (a) missing file
    out=$(run_with_timeout 30 node "$READ_NOTES_PATH" /nonexistent/path/x.json 2>/dev/null || true)
    if [ -n "$out" ]; then
        fail "T5(a): missing file should return empty; got '$out'"
        err=1
    fi
    # (b) malformed JSON
    tmp=$(mktemp)
    printf '{not json' > "$tmp"
    out=$(run_with_timeout 30 node "$READ_NOTES_PATH" "$tmp" 2>/dev/null || true)
    if [ -n "$out" ]; then
        fail "T5(b): malformed JSON should return empty; got '$out'"
        err=1
    fi
    # (c) missing field
    printf '{}' > "$tmp"
    out=$(run_with_timeout 30 node "$READ_NOTES_PATH" "$tmp" 2>/dev/null || true)
    if [ -n "$out" ]; then
        fail "T5(c): missing field should return empty; got '$out'"
        err=1
    fi
    # (d) happy path
    printf '{"NOTES_BACKUP_PATH":"/x/y"}' > "$tmp"
    out=$(run_with_timeout 30 node "$READ_NOTES_PATH" "$tmp" 2>/dev/null || true)
    # Strip trailing newline / whitespace
    out=$(printf '%s' "$out" | tr -d '\r\n')
    if [ "$out" != "/x/y" ]; then
        fail "T5(d): happy path expected '/x/y'; got '$out'"
        err=1
    fi
    rm -f "$tmp"
    [ "$err" -eq 0 ] && pass "T5: read-notes-path fail-safe branches OK"
}

# ---- Test 6: write-env-json.js completeness + no BRANCH_DELETED --------
test_write_env_json() {
    if [ ! -f "$WRITE_ENV_JSON" ]; then
        skip "T6: write-env-json.js not implemented yet"
        return
    fi
    local tmp
    tmp=$(mktemp)
    PR_NUMBER=1 PR_TITLE=t PR_URL=u PR_STATE=OPEN BRANCH=b WORKTREE_PATH=/w \
    CREATED_DATE=2026-05-29 BACKUP_MANIFEST_PATH=m NOTES_BACKUP_PATH=n \
    CLAUDE_CODE_RESTART_REQUIRED=no CC_RESTART_REQUIRED=not_required CC_RESTART_REASON= \
    VSCODE_RELOAD_REQUIRED=not_required VSCODE_RELOAD_REASON= \
    INSTALLER_RERUN_REQUIRED=not_required INSTALLER_RERUN_REASON= \
    OS_REBOOT_REQUIRED=not_required OS_REBOOT_REASON= \
        run_with_timeout 30 node "$WRITE_ENV_JSON" "$tmp" 2>&1 >/dev/null || {
        fail "T6: write-env-json.js exited non-zero"
        rm -f "$tmp"
        return
    }
    local err=0
    for field in PR_NUMBER PR_TITLE PR_URL PR_STATE BRANCH WORKTREE_PATH CREATED_DATE \
                 BACKUP_MANIFEST_PATH NOTES_BACKUP_PATH CC_RESTART_REQUIRED \
                 VSCODE_RELOAD_REQUIRED INSTALLER_RERUN_REQUIRED OS_REBOOT_REQUIRED; do
        if ! grep -q "\"$field\"" "$tmp"; then
            fail "T6: missing field '$field' in env JSON"
            err=1
        fi
    done
    if grep -q '"BRANCH_DELETED"' "$tmp"; then
        fail "T6: BRANCH_DELETED field must NOT be present"
        err=1
    fi
    rm -f "$tmp"
    [ "$err" -eq 0 ] && pass "T6: write-env-json fields complete; no BRANCH_DELETED"
}

# ---- Test 7: load-bearing invariants grep-asserts ----------------------
test_load_bearing_invariants() {
    local err=0
    if [ ! -f "$SKILL_MD" ]; then
        fail "T7: SKILL.md not found"
        return
    fi
    if ! grep -q 'WORKTREE_END_SKILL=1' "$SKILL_MD"; then
        fail "T7: WORKTREE_END_SKILL=1 missing from SKILL.md"
        err=1
    fi
    if ! grep -q 'WORKFLOW_MARK_STEP_final_report_complete' "$SKILL_MD"; then
        fail "T7: Step 7 sentinel WORKFLOW_MARK_STEP_final_report_complete missing from SKILL.md"
        err=1
    fi
    if [ ! -f "$CAPTURE_ENV" ]; then
        fail "T7: capture-env.sh not present (cannot check BRANCH_DELETED / atomicity)"
        err=1
    else
        if ! grep -q 'BRANCH_DELETED' "$CAPTURE_ENV"; then
            fail "T7: BRANCH_DELETED invariant comment missing from capture-env.sh"
            err=1
        fi
        if ! grep -qE '(atomicity|single Bash call|one Bash)' "$CAPTURE_ENV"; then
            fail "T7: atomicity contract comment missing from capture-env.sh"
            err=1
        fi
    fi
    [ "$err" -eq 0 ] && pass "T7: load-bearing invariants preserved"
}

# ---- Test 8: capture-env.sh E2E smoke (gh stub) ------------------------
test_capture_env_e2e() {
    if [ ! -x "$CAPTURE_ENV" ]; then
        skip "T8: capture-env.sh not executable / not present yet"
        return
    fi

    local stub_dir tmp_wt tmp_backup plans_dir
    stub_dir=$(mktemp -d)
    tmp_wt=$(mktemp -d)
    tmp_backup=$(mktemp -d)
    plans_dir=$(mktemp -d)

    # Create gh stub that returns a JSON PR view regardless of args.
    cat > "$stub_dir/gh" <<'STUB'
#!/bin/bash
# Stub gh: emit a fixed JSON for any `pr view`-ish invocation.
case "$*" in
    *"pr view"*|*"pr list"*)
        printf '{"number":42,"title":"stub-pr","url":"https://example.com/pr/42","state":"OPEN"}'
        ;;
    *)
        # Default to empty JSON object
        printf '{}'
        ;;
esac
exit 0
STUB
    chmod +x "$stub_dir/gh"

    # Initialize tmp_wt as a minimal git repo so any `git -C` calls succeed.
    (cd "$tmp_wt" && git init -q 2>/dev/null && \
        git -c user.email=t@e -c user.name=t commit --allow-empty -q -m init 2>/dev/null) || true

    local env_json
    env_json="$plans_dir/testsession-final-report-env.json"

    local out rc
    out=$(PATH="$stub_dir:$PATH" PLANS_DIR="$plans_dir" \
          run_with_timeout 60 bash "$CAPTURE_ENV" \
              "$tmp_wt" owner/repo "$tmp_backup" testsession 2>&1)
    rc=$?

    if [ "$rc" -ne 0 ]; then
        fail "T8: capture-env.sh exited $rc; output: $out"
        rm -rf "$stub_dir" "$tmp_wt" "$tmp_backup" "$plans_dir"
        return
    fi

    if [ ! -f "$env_json" ]; then
        fail "T8: expected env JSON not produced at $env_json"
        rm -rf "$stub_dir" "$tmp_wt" "$tmp_backup" "$plans_dir"
        return
    fi

    local err=0
    for field in PR_NUMBER PR_TITLE PR_URL PR_STATE BRANCH WORKTREE_PATH; do
        if ! grep -q "\"$field\"" "$env_json"; then
            fail "T8: env JSON missing field '$field'"
            err=1
        fi
    done

    rm -rf "$stub_dir" "$tmp_wt" "$tmp_backup" "$plans_dir"
    [ "$err" -eq 0 ] && pass "T8: capture-env.sh E2E smoke OK"
}

# ---- Run all -----------------------------------------------------------
test_no_inline_node_e
test_skill_md_line_count
test_lib_scripts_present
test_extract_pr_fields
test_read_notes_path
test_write_env_json
test_load_bearing_invariants
test_capture_env_e2e

echo
echo "Summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

if [ "$FAIL" -gt 0 ]; then
    echo "FAIL: $FAIL test(s) failed"
    exit 1
fi

TOTAL=$((PASS + SKIP))
echo "PASS: all $TOTAL tests passed (skips counted as pass)"
exit 0
