#!/bin/bash
# tests/refactor-enforce-worktree-positive-allow.sh
#
# Tests for refactor/enforce-worktree-positive-allow.
#
# The refactor:
#   1. Removes 4 bypass functions from hooks/enforce-worktree.js:
#      - isAllowedHistoryWriteViaIssueCloseSkill
#      - isAllowedHistoryPushViaIssueCloseSkill
#      - isAllowedHistoryWriteViaComposeDocAppendSkill
#      - isAllowedHistoryPushViaComposeDocAppendSkill
#   2. Replaces ISSUE_CLOSE_SKILL=1 / COMPOSE_DOC_APPEND_SKILL=1 bypass paths
#      with positive-allow: writes from main worktree go through GitHub Contents
#      API + Git Data API helpers, not local git commands.
#   3. Introduces three new helpers under bin/lib/:
#      - github-contents-validate.sh
#      - github-contents-write.sh
#      - github-git-data-write.sh
#   4. Tightens enforce-worktree.js: when Bash CWD is non-git and the command
#      is write-classified, BLOCK instead of fail-open. (Edit/Write to a
#      non-git path remains fail-open.)
#
# The tests deliberately fail meaningfully against the current source. They
# express the post-refactor contract.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
GUARD_JS="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"
VALIDATE_SH="${AGENTS_DIR}/bin/lib/github-contents-validate.sh"
CONTENTS_WRITE_SH="${AGENTS_DIR}/bin/lib/github-contents-write.sh"
GIT_DATA_WRITE_SH="${AGENTS_DIR}/bin/lib/github-git-data-write.sh"
STEP_E_SH="${AGENTS_DIR}/skills/issue-close-finalize/scripts/step-e.sh"
COMPOSE_DOC_APPEND_BIN="${AGENTS_DIR}/bin/compose-doc-append-entry"
ISSUE_CREATE_SKILL="${AGENTS_DIR}/skills/issue-create/SKILL.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'reft-positive-allow-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

FIXTURES_DIR="${AGENTS_DIR}/tests/fixtures/gh-mock"
mkdir -p "$FIXTURES_DIR"

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# Returns 0 if allow, 1 if block.
guard_decision() {
    local out="$1"
    if echo "$out" | grep -q '"decision":"block"'; then
        return 1
    fi
    return 0
}

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

# Returns "<main_repo>|<wt_path>"
setup_linked_worktree() {
    local name="$1"
    local main; main="$(setup_main_checkout "$name-main")"
    local wt="$TMPDIR_BASE/$name-wt"
    git -C "$main" worktree add -q -b "feature/$name" "$wt" 2>/dev/null
    echo "$main|$wt"
}

# Run the enforce-worktree guard for a Bash tool. Args: command cwd [env-VAR=val ...]
run_bash_guard() {
    local cmd="$1"; shift
    local cwd="$1"; shift
    local payload
    payload="$(node -e "
      const j = { session_id:'test', tool_name:'Bash', tool_input:{ command: process.argv[1] } };
      console.log(JSON.stringify(j));
    " -- "$cmd" 2>/dev/null)"
    if [ -n "$cwd" ]; then
        (cd "$cwd" && echo "$payload" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null)
    else
        echo "$payload" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null
    fi
}

# Run the enforce-worktree guard for an Edit/Write/MultiEdit tool. Args: toolName filePath cwd [env-VAR=val ...]
run_edit_guard() {
    local tool_name="$1"; shift
    local file_path="$1"; shift
    local cwd="$1"; shift
    local payload
    payload="$(node -e "
      const j = { session_id:'test', tool_name: process.argv[1], tool_input:{ file_path: process.argv[2] } };
      console.log(JSON.stringify(j));
    " -- "$tool_name" "$file_path" 2>/dev/null)"
    if [ -n "$cwd" ]; then
        (cd "$cwd" && echo "$payload" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null)
    else
        echo "$payload" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null
    fi
}

# Inspect hook module exports. Args: name → echoes "function" or "undefined"
get_export_kind() {
    local name="$1"
    run_with_timeout 15 node -e "
        const m = require('$GUARD_JS');
        console.log(typeof m['$name']);
    " 2>/dev/null
}

require_file() {
    local file="$1" label="$2"
    if [ ! -f "$file" ]; then
        fail "$label (precondition missing: $file)"
        return 1
    fi
    return 0
}

# ============================================================================
# L1 unit — enforce-worktree.js bypass-function removal (cases 1–8)
# ============================================================================

test_l1_1_bypass_functions_not_exported() {
    require_file "$GUARD_JS" "test_l1_1_bypass_functions_not_exported" || return
    local fns=(
        isAllowedHistoryWriteViaIssueCloseSkill
        isAllowedHistoryPushViaIssueCloseSkill
        isAllowedHistoryWriteViaComposeDocAppendSkill
        isAllowedHistoryPushViaComposeDocAppendSkill
    )
    local all_removed=1
    for fn in "${fns[@]}"; do
        local kind; kind="$(get_export_kind "$fn")"
        if [ "$kind" = "function" ]; then
            fail "L1.1 bypass function $fn still exported (refactor removes it)"
            all_removed=0
        fi
    done
    [ "$all_removed" = "1" ] && pass "L1.1 all 4 bypass functions removed from module.exports"
}

test_l1_2_issue_close_skill_inline_blocked_in_main() {
    require_file "$GUARD_JS" "test_l1_2_issue_close_skill_inline_blocked_in_main" || return
    local repo; repo="$(setup_main_checkout "l1-2-main")"
    local cmd='ISSUE_CLOSE_SKILL=1 git add docs/history.md docs/history/'
    local out
    out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "L1.2 ISSUE_CLOSE_SKILL=1 git add from main: should block (no bypass)"
    else
        pass "L1.2 ISSUE_CLOSE_SKILL=1 git add from main: blocks (no bypass)"
    fi
}

test_l1_3_compose_doc_append_skill_inline_blocked_in_main() {
    require_file "$GUARD_JS" "test_l1_3_compose_doc_append_skill_inline_blocked_in_main" || return
    local repo; repo="$(setup_main_checkout "l1-3-main")"
    local cmd='COMPOSE_DOC_APPEND_SKILL=1 git add CHANGELOG.md'
    local out
    out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "L1.3 COMPOSE_DOC_APPEND_SKILL=1 git add from main: should block"
    else
        pass "L1.3 COMPOSE_DOC_APPEND_SKILL=1 git add from main: blocks"
    fi
}

test_l1_4_bash_in_non_git_cwd_blocks() {
    # Change ④: Bash write command in a non-git CWD is now BLOCK, not allow.
    # The previous fail-open allowed echo/cp/mv outside any repo, which masked
    # mis-targeted writes. The Edit/Write fail-open remains (test L1.5).
    require_file "$GUARD_JS" "test_l1_4_bash_in_non_git_cwd_blocks" || return
    local d="$TMPDIR_BASE/nongit-bash-$$"
    mkdir -p "$d"
    local out
    out="$(run_bash_guard "echo x > $d/foo" "$d" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "L1.4 Bash write in non-git CWD: should BLOCK (Change ④)"
    else
        pass "L1.4 Bash write in non-git CWD: blocks (Change ④)"
    fi
}

test_l1_5_edit_to_non_git_path_allows() {
    # The Edit/Write fail-open for non-git paths remains. Only Bash flips.
    require_file "$GUARD_JS" "test_l1_5_edit_to_non_git_path_allows" || return
    local d="$TMPDIR_BASE/nongit-edit-$$"
    mkdir -p "$d"
    local out
    out="$(run_edit_guard "Write" "$d/foo.txt" "$d" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L1.5 Write tool to non-git path: allows (fail-open maintained)"
    else
        fail "L1.5 Write tool to non-git path: should allow (Edit fail-open) ($out)"
    fi
}

test_l1_6_linked_worktree_feature_branch_allows() {
    require_file "$GUARD_JS" "test_l1_6_linked_worktree_feature_branch_allows" || return
    local pair; pair="$(setup_linked_worktree "l1-6")"
    local wt="${pair#*|}"
    local out
    out="$(run_bash_guard "echo x > $wt/foo" "$wt" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L1.6 linked worktree + feature branch: allows (positive-allow)"
    else
        fail "L1.6 linked worktree + feature branch: should allow ($out)"
    fi
}

test_l1_7_main_worktree_denies() {
    require_file "$GUARD_JS" "test_l1_7_main_worktree_denies" || return
    local repo; repo="$(setup_main_checkout "l1-7")"
    local out
    out="$(run_bash_guard "echo x > $repo/foo" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "L1.7 main worktree write: should deny ($out)"
    else
        pass "L1.7 main worktree write: denies"
    fi
}

test_l1_8_existing_lifecycle_exceptions_intact() {
    require_file "$GUARD_JS" "test_l1_8_existing_lifecycle_exceptions_intact" || return

    # isAllowedFastForwardMerge still works (main + git merge --ff-only).
    local repo; repo="$(setup_main_checkout "l1-8-ff")"
    local out
    out="$(run_bash_guard "git merge --ff-only origin/feature" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L1.8a isAllowedFastForwardMerge: still allows from main"
    else
        fail "L1.8a fast-forward merge: should allow from main ($out)"
    fi

    # isAllowedWorktreeCommand still works (git worktree list).
    local pair; pair="$(setup_linked_worktree "l1-8-wt")"
    local main="${pair%|*}"
    out="$(run_bash_guard "git worktree list --porcelain" "$main" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L1.8b isAllowedWorktreeCommand: still allows from main"
    else
        fail "L1.8b git worktree list: should allow from main ($out)"
    fi
}

# ============================================================================
# L1 unit — github-contents-validate.sh (cases 9–14)
# ============================================================================

# Build a well-formed history.md fixture.
make_valid_history() {
    local out="$1"
    {
        echo "### Initial entry (2026-05-31, abcdef1)"
        echo "Background: test fixture."
        echo "Changes: initial."
        echo ""
        echo "### Issue #1 (2026-05-31, 1234567)"
        echo "Background: closes the issue."
        echo "Changes: added X."
        echo ""
        echo ""
    } > "$out"
}

run_validate() {
    local subject="$1" path_arg="$2" file_arg="$3"
    run_with_timeout 30 bash "$VALIDATE_SH" \
        --path "$path_arg" \
        --file "$file_arg" \
        --commit-subject "$subject" 2>&1
}

test_l1_9_validate_accepts_well_formed_history() {
    require_file "$VALIDATE_SH" "test_l1_9_validate_accepts_well_formed_history" || return
    local f="$TMPDIR_BASE/hist-valid.md"
    make_valid_history "$f"
    local out exit_code
    out="$(run_validate "docs(history): record issue #1" "docs/history.md" "$f")"
    exit_code=$?
    if [ "$exit_code" = "0" ]; then
        pass "L1.9 well-formed history validates (exit 0)"
    else
        fail "L1.9 well-formed history: expected exit 0 got $exit_code ($out)"
    fi
}

test_l1_10_validate_rejects_empty_file() {
    require_file "$VALIDATE_SH" "test_l1_10_validate_rejects_empty_file" || return
    local f="$TMPDIR_BASE/hist-empty.md"
    : > "$f"
    local out exit_code
    out="$(run_validate "docs(history): record issue #1" "docs/history.md" "$f")"
    exit_code=$?
    if [ "$exit_code" = "2" ]; then
        pass "L1.10 empty file: exit 2"
    else
        fail "L1.10 empty file: expected exit 2 got $exit_code ($out)"
    fi
}

test_l1_11_validate_rejects_over_hard_limit() {
    require_file "$VALIDATE_SH" "test_l1_11_validate_rejects_over_hard_limit" || return
    local f="$TMPDIR_BASE/hist-over.md"
    # 801 lines — over the 800-line hard limit.
    yes "filler line content" 2>/dev/null | head -n 801 > "$f"
    local out exit_code
    out="$(run_validate "docs(history): record issue #1" "docs/history.md" "$f")"
    exit_code=$?
    if [ "$exit_code" = "2" ]; then
        pass "L1.11 >800 lines: exit 2 (hard limit)"
    else
        fail "L1.11 >800 lines: expected exit 2 got $exit_code ($out)"
    fi
}

test_l1_12_validate_rejects_wrong_commit_subject() {
    require_file "$VALIDATE_SH" "test_l1_12_validate_rejects_wrong_commit_subject" || return
    local f="$TMPDIR_BASE/hist-wrong-subject.md"
    make_valid_history "$f"
    local out exit_code
    out="$(run_validate "feat: add something" "docs/history.md" "$f")"
    exit_code=$?
    if [ "$exit_code" = "2" ]; then
        pass "L1.12 wrong commit subject format: exit 2"
    else
        fail "L1.12 wrong commit subject: expected exit 2 got $exit_code ($out)"
    fi
}

test_l1_13_validate_rejects_no_trailing_newline() {
    require_file "$VALIDATE_SH" "test_l1_13_validate_rejects_no_trailing_newline" || return
    local f="$TMPDIR_BASE/hist-no-newline.md"
    make_valid_history "$f"
    # Strip trailing newline(s).
    printf '%s' "$(cat "$f")" > "$f"
    local out exit_code
    out="$(run_validate "docs(history): record issue #1" "docs/history.md" "$f")"
    exit_code=$?
    if [ "$exit_code" = "2" ]; then
        pass "L1.13 no trailing newline: exit 2"
    else
        fail "L1.13 no trailing newline: expected exit 2 got $exit_code ($out)"
    fi
}

test_l1_14_validate_warns_on_non_ascii_english() {
    require_file "$VALIDATE_SH" "test_l1_14_validate_warns_on_non_ascii_english" || return
    local f="$TMPDIR_BASE/hist-non-ascii.md"
    {
        echo "### Issue #1 (2026-05-31, 1234567)"
        echo "Background: closes the issue 日本語テキスト多めに含めるテスト用文字列です。"
        echo "Changes: 追加された機能の説明文をここに記述する必要があります。"
        echo "もっと日本語を追加して10%以上にする必要があります。"
        echo "さらに日本語追加で確実に閾値を超えるようにします。"
        echo ""
    } > "$f"
    local out exit_code
    out="$(PLAN_LANG=english run_with_timeout 30 bash "$VALIDATE_SH" \
        --path "docs/history.md" \
        --file "$f" \
        --commit-subject "docs(history): record issue #1" 2>&1)"
    exit_code=$?
    if [ "$exit_code" = "0" ]; then
        # Must still warn on stderr / mixed output.
        if echo "$out" | grep -qi "warn\|non-ascii\|english"; then
            pass "L1.14 PLAN_LANG=english + non-ASCII: exit 0 + warning"
        else
            fail "L1.14 PLAN_LANG=english + non-ASCII: exit 0 but no warning ($out)"
        fi
    else
        fail "L1.14 PLAN_LANG=english + non-ASCII: should not block (exit 0); got $exit_code ($out)"
    fi
}

# ============================================================================
# L1 unit — github-contents-write.sh (cases 15–18)
# ============================================================================

# Build a stub gh that records calls and returns scripted responses.
# Args: scenario-name
make_gh_stub() {
    local scenario="$1"
    local dir="$TMPDIR_BASE/gh-stub-$scenario"
    mkdir -p "$dir"
    local log="$dir/calls.log"
    : > "$log"
    cat > "$dir/gh" <<EOF
#!/bin/bash
# gh stub for scenario: $scenario
# Records every invocation, replays a scripted sequence.
echo "\$@" >> "$log"
LOG="$log"
SCEN="$scenario"
EOF
    chmod +x "$dir/gh"
    echo "$dir"
}

run_contents_write() {
    local stubdir="$1"; shift
    PATH="$stubdir:$PATH" run_with_timeout 30 bash "$CONTENTS_WRITE_SH" "$@" 2>&1
}

test_l1_15_contents_write_success() {
    require_file "$CONTENTS_WRITE_SH" "test_l1_15_contents_write_success" || return
    local stubdir; stubdir="$(make_gh_stub "ok")"
    # Stub: GET returns sha; PUT returns success.
    cat >> "$stubdir/gh" <<'EOF'
cmd="$*"
if echo "$cmd" | grep -q 'api .*-X GET\|api repos/.*/contents/' && ! echo "$cmd" | grep -q '\-X PUT'; then
    echo '{"sha":"abc123"}'
    exit 0
fi
if echo "$cmd" | grep -q '\-X PUT'; then
    echo '{"commit":{"sha":"def456"}}'
    exit 0
fi
exit 0
EOF
    local f="$TMPDIR_BASE/hist-put.md"
    make_valid_history "$f"
    local out exit_code
    out="$(run_contents_write "$stubdir" \
        --owner test --repo demo \
        --path docs/history.md \
        --file "$f" \
        --message "docs(history): record issue #1" \
        --branch main)"
    exit_code=$?
    if [ "$exit_code" = "0" ]; then
        pass "L1.15 successful PUT with sha: exit 0"
    else
        fail "L1.15 successful PUT: expected exit 0 got $exit_code ($out)"
    fi
}

test_l1_16_contents_write_409_retries() {
    require_file "$CONTENTS_WRITE_SH" "test_l1_16_contents_write_409_retries" || return
    local stubdir; stubdir="$(make_gh_stub "409-retry")"
    cat >> "$stubdir/gh" <<'EOF'
cmd="$*"
GET_COUNT_F="$LOG.get_count"
PUT_COUNT_F="$LOG.put_count"
[ -f "$GET_COUNT_F" ] || echo 0 > "$GET_COUNT_F"
[ -f "$PUT_COUNT_F" ] || echo 0 > "$PUT_COUNT_F"
if echo "$cmd" | grep -q '\-X PUT'; then
    n=$(cat "$PUT_COUNT_F"); n=$((n+1)); echo $n > "$PUT_COUNT_F"
    if [ "$n" = "1" ]; then
        echo "HTTP 409 conflict" >&2
        exit 1
    fi
    echo '{"commit":{"sha":"def456"}}'
    exit 0
fi
# GET
n=$(cat "$GET_COUNT_F"); n=$((n+1)); echo $n > "$GET_COUNT_F"
echo "{\"sha\":\"fresh-sha-$n\"}"
exit 0
EOF
    local f="$TMPDIR_BASE/hist-409.md"
    make_valid_history "$f"
    local out exit_code
    out="$(run_contents_write "$stubdir" \
        --owner test --repo demo \
        --path docs/history.md \
        --file "$f" \
        --message "docs(history): record issue #1" \
        --branch main)"
    exit_code=$?
    if [ "$exit_code" = "0" ]; then
        # Verify GET was called at least twice (one for initial, one for refresh on 409).
        local get_n; get_n=$(cat "$stubdir/calls.log.get_count" 2>/dev/null || echo 0)
        if [ "$get_n" -ge 2 ]; then
            pass "L1.16 409 then retry: succeeds with fresh sha (get_count=$get_n)"
        else
            fail "L1.16 409 retry: did not refetch sha (get_count=$get_n)"
        fi
    else
        fail "L1.16 409 then retry: expected exit 0 got $exit_code ($out)"
    fi
}

test_l1_17_contents_write_422_exhausted() {
    require_file "$CONTENTS_WRITE_SH" "test_l1_17_contents_write_422_exhausted" || return
    local stubdir; stubdir="$(make_gh_stub "422-exhausted")"
    cat >> "$stubdir/gh" <<'EOF'
cmd="$*"
if echo "$cmd" | grep -q '\-X PUT'; then
    echo "HTTP 422 unprocessable entity" >&2
    exit 1
fi
echo '{"sha":"abc123"}'
exit 0
EOF
    local f="$TMPDIR_BASE/hist-422.md"
    make_valid_history "$f"
    local out exit_code
    out="$(run_contents_write "$stubdir" \
        --owner test --repo demo \
        --path docs/history.md \
        --file "$f" \
        --message "docs(history): record issue #1" \
        --branch main)"
    exit_code=$?
    if [ "$exit_code" = "11" ]; then
        if echo "$out" | grep -qi "422\|unprocessable\|exhausted\|retr"; then
            pass "L1.17 422 on all retries: exit 11 with stderr message"
        else
            fail "L1.17 422 exhausted: exit 11 but missing stderr message ($out)"
        fi
    else
        fail "L1.17 422 exhausted: expected exit 11 got $exit_code ($out)"
    fi
}

test_l1_18_contents_write_base64_no_newlines() {
    require_file "$CONTENTS_WRITE_SH" "test_l1_18_contents_write_base64_no_newlines" || return
    local stubdir; stubdir="$(make_gh_stub "base64-check")"
    # Capture the PUT body so we can inspect encoded content.
    cat >> "$stubdir/gh" <<'EOF'
cmd="$*"
if echo "$cmd" | grep -q '\-X PUT'; then
    # Dump all args; gh api -F content=@- reads stdin separately. Save stdin to file.
    cat > "$LOG.put_body"
    echo "$@" >> "$LOG.put_args"
    echo '{"commit":{"sha":"def456"}}'
    exit 0
fi
echo '{"sha":"abc123"}'
exit 0
EOF
    # Use a larger input that would trigger newline-wrapping in base64.
    local f="$TMPDIR_BASE/hist-large.md"
    {
        for i in $(seq 1 50); do
            echo "### Issue #$i (2026-05-31, abcdef$i)"
            echo "Background: filler line $i for base64 width test."
            echo "Changes: more filler content to ensure long base64."
            echo ""
        done
        echo ""
    } > "$f"
    local out exit_code
    out="$(run_contents_write "$stubdir" \
        --owner test --repo demo \
        --path docs/history.md \
        --file "$f" \
        --message "docs(history): record issue #1" \
        --branch main)"
    exit_code=$?
    # Check args/body for any base64 content with embedded \n.
    local put_args="$stubdir/calls.log.put_args"
    local put_body="$stubdir/calls.log.put_body"
    if [ ! -f "$put_args" ] && [ ! -f "$put_body" ]; then
        fail "L1.18 base64 newline check: no PUT was issued (exit $exit_code)"
        return
    fi
    # Look for base64 sections (content= or content":") and ensure each is a single line.
    local has_newlines=0
    for ff in "$put_args" "$put_body"; do
        [ -f "$ff" ] || continue
        # Look for base64-like blob with a newline embedded between base64 chars.
        if grep -aP 'content[="][^"]*[A-Za-z0-9+/]\n[A-Za-z0-9+/]' "$ff" >/dev/null 2>&1; then
            has_newlines=1
        fi
    done
    if [ "$has_newlines" = "0" ]; then
        pass "L1.18 base64 content has no embedded newlines"
    else
        fail "L1.18 base64 content contains embedded newlines (macOS tr -d '\\n' missing)"
    fi
}

# ============================================================================
# L1 unit — github-git-data-write.sh (cases 19–23)
# ============================================================================

run_git_data_write() {
    local stubdir="$1"; shift
    PATH="$stubdir:$PATH" run_with_timeout 30 bash "$GIT_DATA_WRITE_SH" "$@" 2>&1
}

# Make a stub that always succeeds for git data API.
make_gh_stub_git_data_ok() {
    local scenario="$1"
    local stubdir; stubdir="$(make_gh_stub "$scenario")"
    cat >> "$stubdir/gh" <<'EOF'
cmd="$*"
# Categorise calls.
LOG_ORDER="$LOG.order"
if echo "$cmd" | grep -q 'git/blobs'; then
    echo "blobs" >> "$LOG_ORDER"
    echo '{"sha":"blob-sha-'"$RANDOM"'"}'
    exit 0
fi
if echo "$cmd" | grep -q 'git/trees'; then
    # Capture body for inspection.
    cat > "$LOG.tree_body" 2>/dev/null || true
    echo "trees" >> "$LOG_ORDER"
    echo '{"sha":"tree-sha-1"}'
    exit 0
fi
if echo "$cmd" | grep -q 'git/commits'; then
    echo "commits" >> "$LOG_ORDER"
    echo '{"sha":"commit-sha-1"}'
    exit 0
fi
if echo "$cmd" | grep -q 'git/refs\|git/ref/'; then
    echo "refs" >> "$LOG_ORDER"
    echo '{"ref":"refs/heads/main","object":{"sha":"commit-sha-1"}}'
    exit 0
fi
echo '{}'
exit 0
EOF
    echo "$stubdir"
}

test_l1_19_git_data_call_order_single_file() {
    require_file "$GIT_DATA_WRITE_SH" "test_l1_19_git_data_call_order_single_file" || return
    local stubdir; stubdir="$(make_gh_stub_git_data_ok "order-single")"
    local f="$TMPDIR_BASE/single.md"
    make_valid_history "$f"
    local out exit_code
    out="$(run_git_data_write "$stubdir" \
        --owner test --repo demo \
        --branch main \
        --message "docs(history): record issue #1" \
        --file "docs/history.md=$f")"
    exit_code=$?
    local order_file="$stubdir/calls.log.order"
    if [ ! -f "$order_file" ]; then
        fail "L1.19 call order: no order log (exit $exit_code, out=$out)"
        return
    fi
    # Expected: blobs → trees → commits → refs
    local actual; actual="$(tr '\n' ',' < "$order_file" | sed 's/,$//')"
    if [ "$actual" = "blobs,trees,commits,refs" ]; then
        pass "L1.19 single-file call order: blobs → trees → commits → refs"
    else
        fail "L1.19 single-file: expected blobs,trees,commits,refs got '$actual'"
    fi
}

test_l1_20_git_data_blobs_before_tree() {
    require_file "$GIT_DATA_WRITE_SH" "test_l1_20_git_data_blobs_before_tree" || return
    local stubdir; stubdir="$(make_gh_stub_git_data_ok "blobs-before-tree")"
    local f1="$TMPDIR_BASE/m1.md" f2="$TMPDIR_BASE/m2.md" f3="$TMPDIR_BASE/m3.md"
    echo "file 1" > "$f1"; echo "file 2" > "$f2"; echo "file 3" > "$f3"
    local out exit_code
    out="$(run_git_data_write "$stubdir" \
        --owner test --repo demo \
        --branch main \
        --message "multi" \
        --file "a.md=$f1" --file "b.md=$f2" --file "c.md=$f3")"
    exit_code=$?
    local order_file="$stubdir/calls.log.order"
    if [ ! -f "$order_file" ]; then
        fail "L1.20 multi-file call order: no order log (exit $exit_code)"
        return
    fi
    # Count blobs lines before the first trees line.
    local blob_count=0
    local tree_seen=0
    while IFS= read -r line; do
        if [ "$tree_seen" = "0" ] && [ "$line" = "blobs" ]; then
            blob_count=$((blob_count + 1))
        fi
        if [ "$line" = "trees" ]; then
            tree_seen=1
        fi
    done < "$order_file"
    if [ "$blob_count" = "3" ]; then
        pass "L1.20 3 files: all 3 blobs created before tree POST"
    else
        fail "L1.20 expected 3 blobs before tree, got $blob_count"
    fi
}

test_l1_21_git_data_tree_entry_payload() {
    require_file "$GIT_DATA_WRITE_SH" "test_l1_21_git_data_tree_entry_payload" || return
    local stubdir; stubdir="$(make_gh_stub_git_data_ok "tree-payload")"
    local f="$TMPDIR_BASE/payload.md"
    echo "content" > "$f"
    local out exit_code
    out="$(run_git_data_write "$stubdir" \
        --owner test --repo demo \
        --branch main \
        --message "msg" \
        --file "docs/x.md=$f")"
    exit_code=$?
    local tree_body="$stubdir/calls.log.tree_body"
    if [ ! -f "$tree_body" ]; then
        # Alternative: payload may be embedded in args; check args log instead.
        local args="$stubdir/calls.log"
        if grep -q '"mode":"100644"' "$args" 2>/dev/null && grep -q '"type":"blob"' "$args" 2>/dev/null; then
            pass "L1.21 tree entry has mode 100644 + type blob (in args)"
            return
        fi
        fail "L1.21 tree payload not captured (no body file, no args match)"
        return
    fi
    local mode_ok=0 type_ok=0
    if grep -q '"mode"[[:space:]]*:[[:space:]]*"100644"' "$tree_body"; then mode_ok=1; fi
    if grep -q '"type"[[:space:]]*:[[:space:]]*"blob"' "$tree_body"; then type_ok=1; fi
    if [ "$mode_ok" = "1" ] && [ "$type_ok" = "1" ]; then
        pass "L1.21 tree entry has mode 100644 + type blob"
    else
        fail "L1.21 tree entry: mode_ok=$mode_ok type_ok=$type_ok"
    fi
}

test_l1_22_git_data_ref_patch_422_exhausted() {
    require_file "$GIT_DATA_WRITE_SH" "test_l1_22_git_data_ref_patch_422_exhausted" || return
    local stubdir; stubdir="$(make_gh_stub "ref-422-exhausted")"
    cat >> "$stubdir/gh" <<'EOF'
cmd="$*"
if echo "$cmd" | grep -q 'git/blobs'; then
    echo '{"sha":"blob1"}'; exit 0
fi
if echo "$cmd" | grep -q 'git/trees'; then
    echo '{"sha":"tree1"}'; exit 0
fi
if echo "$cmd" | grep -q 'git/commits'; then
    echo '{"sha":"commit1"}'; exit 0
fi
if echo "$cmd" | grep -q '\-X GET.*git/ref/'; then
    echo '{"object":{"sha":"parent-'"$RANDOM"'"}}'
    exit 0
fi
if echo "$cmd" | grep -q '\-X PATCH.*git/refs'; then
    echo "HTTP 422" >&2; exit 1
fi
echo '{}'; exit 0
EOF
    local f="$TMPDIR_BASE/ref422.md"
    echo "x" > "$f"
    local out exit_code
    out="$(run_git_data_write "$stubdir" \
        --owner test --repo demo \
        --branch main \
        --message "msg" \
        --file "docs/x.md=$f")"
    exit_code=$?
    if [ "$exit_code" = "11" ]; then
        pass "L1.22 ref PATCH 422 on all 3 retries: exit 11"
    else
        fail "L1.22 expected exit 11 got $exit_code ($out)"
    fi
}

test_l1_23_git_data_ref_patch_422_then_success() {
    require_file "$GIT_DATA_WRITE_SH" "test_l1_23_git_data_ref_patch_422_then_success" || return
    local stubdir; stubdir="$(make_gh_stub "ref-422-then-ok")"
    cat >> "$stubdir/gh" <<'EOF'
cmd="$*"
LOG_PATCH="$LOG.patch_count"
LOG_GET="$LOG.get_ref_count"
[ -f "$LOG_PATCH" ] || echo 0 > "$LOG_PATCH"
[ -f "$LOG_GET" ] || echo 0 > "$LOG_GET"
if echo "$cmd" | grep -q 'git/blobs'; then
    echo '{"sha":"blob1"}'; exit 0
fi
if echo "$cmd" | grep -q 'git/trees'; then
    echo '{"sha":"tree1"}'; exit 0
fi
if echo "$cmd" | grep -q 'git/commits'; then
    echo '{"sha":"commit1"}'; exit 0
fi
if echo "$cmd" | grep -q 'git/ref/' && ! echo "$cmd" | grep -q '\-X PATCH'; then
    n=$(cat "$LOG_GET"); n=$((n+1)); echo $n > "$LOG_GET"
    echo "{\"object\":{\"sha\":\"parent-$n\"}}"; exit 0
fi
if echo "$cmd" | grep -q '\-X PATCH'; then
    n=$(cat "$LOG_PATCH"); n=$((n+1)); echo $n > "$LOG_PATCH"
    if [ "$n" = "1" ]; then
        echo "HTTP 422" >&2; exit 1
    fi
    echo '{"ref":"refs/heads/main"}'; exit 0
fi
echo '{}'; exit 0
EOF
    local f="$TMPDIR_BASE/ref422ok.md"
    echo "x" > "$f"
    local out exit_code
    out="$(run_git_data_write "$stubdir" \
        --owner test --repo demo \
        --branch main \
        --message "msg" \
        --file "docs/x.md=$f")"
    exit_code=$?
    local get_n; get_n=$(cat "$stubdir/calls.log.get_ref_count" 2>/dev/null || echo 0)
    if [ "$exit_code" = "0" ] && [ "$get_n" -ge 2 ]; then
        pass "L1.23 422 once then retry with fresh parent: exit 0 (get_ref called $get_n times)"
    else
        fail "L1.23 422-then-ok: exit=$exit_code get_ref=$get_n ($out)"
    fi
}

# ============================================================================
# L2 integration — hook behaviour (cases 24–30)
# ============================================================================

test_l2_24_main_issue_close_skill_add_history_blocked() {
    # Use the EXACT bypassed shape from step-e.sh — two args including the
    # trailing-slash directory. The current bypass matches this verbatim; the
    # refactor must remove that bypass so this command blocks from main.
    require_file "$GUARD_JS" "test_l2_24_main_issue_close_skill_add_history_blocked" || return
    local repo; repo="$(setup_main_checkout "l2-24")"
    local cmd='ISSUE_CLOSE_SKILL=1 git add docs/history.md docs/history/'
    local out
    out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "L2.24 main + ISSUE_CLOSE_SKILL=1 git add docs/history.md docs/history/: should block (bypass removed)"
    else
        pass "L2.24 main + ISSUE_CLOSE_SKILL=1 git add: bypass removed → blocks"
    fi
}

test_l2_25_linked_worktree_normal_bash_write_allowed() {
    require_file "$GUARD_JS" "test_l2_25_linked_worktree_normal_bash_write_allowed" || return
    local pair; pair="$(setup_linked_worktree "l2-25")"
    local wt="${pair#*|}"
    local out
    out="$(run_bash_guard "echo body > $wt/notes.txt" "$wt" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L2.25 linked worktree + normal bash write: allowed"
    else
        fail "L2.25 linked worktree write: should allow ($out)"
    fi
}

test_l2_26_main_gh_api_put_contents_allowed() {
    # gh api -X PUT contents from main is allowed via gh Group B session-scope.
    require_file "$GUARD_JS" "test_l2_26_main_gh_api_put_contents_allowed" || return
    local repo; repo="$(setup_main_checkout "l2-26")"
    local cmd='gh api -X PUT repos/owner/demo/contents/docs/history.md -f message=msg'
    local out
    out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L2.26 main + gh api -X PUT contents: allow (gh Group B session-scope)"
    else
        fail "L2.26 main + gh api PUT: should allow ($out)"
    fi
}

test_l2_27_non_git_cwd_bash_blocked() {
    require_file "$GUARD_JS" "test_l2_27_non_git_cwd_bash_blocked" || return
    local d="$TMPDIR_BASE/nongit-l2-27-$$"
    mkdir -p "$d"
    local out
    out="$(run_bash_guard "echo x > $d/foo" "$d" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "L2.27 non-git CWD + Bash write: should block (Change ④)"
    else
        pass "L2.27 non-git CWD + Bash write: blocks (Change ④)"
    fi
}

test_l2_28_non_git_path_write_tool_allowed() {
    require_file "$GUARD_JS" "test_l2_28_non_git_path_write_tool_allowed" || return
    local d="$TMPDIR_BASE/nongit-l2-28-$$"
    mkdir -p "$d"
    local out
    out="$(run_edit_guard "Write" "$d/foo.txt" "$d" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L2.28 non-git path + Write tool: allows"
    else
        fail "L2.28 non-git path + Write tool: should allow ($out)"
    fi
}

test_l2_29_linked_worktree_gh_api_post_blob_allowed() {
    require_file "$GUARD_JS" "test_l2_29_linked_worktree_gh_api_post_blob_allowed" || return
    local pair; pair="$(setup_linked_worktree "l2-29")"
    local wt="${pair#*|}"
    local cmd='gh api -X POST repos/owner/demo/git/blobs -f content=xyz -f encoding=base64'
    local out
    out="$(run_bash_guard "$cmd" "$wt" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L2.29 linked worktree + gh api POST git/blobs: allowed"
    else
        fail "L2.29 linked worktree + gh api POST blobs: should allow ($out)"
    fi
}

test_l2_30_main_git_push_origin_main_blocked() {
    require_file "$GUARD_JS" "test_l2_30_main_git_push_origin_main_blocked" || return
    local repo; repo="$(setup_main_checkout "l2-30")"
    local out
    out="$(run_bash_guard "git push origin main" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "L2.30 main + git push origin main: should block"
    else
        pass "L2.30 main + git push origin main: blocks"
    fi
}

# ============================================================================
# L3 E2E — Subsumes scenarios (cases 31–35)
# ============================================================================

test_l3_31_issue_672_step_e_no_local_git_writes() {
    # #672: step-e.sh under the positive-allow refactor must NOT issue
    # `ISSUE_CLOSE_SKILL=1 git add/commit/push`. Instead it should call the
    # Contents-API helper.
    require_file "$STEP_E_SH" "test_l3_31_issue_672_step_e_no_local_git_writes" || return
    if grep -E '^[^#]*ISSUE_CLOSE_SKILL=1[[:space:]]+git[[:space:]]+(add|commit|push)' "$STEP_E_SH" >/dev/null; then
        fail "L3.31 #672: step-e.sh still issues 'ISSUE_CLOSE_SKILL=1 git add/commit/push' (refactor moves to Contents API)"
    else
        pass "L3.31 #672: step-e.sh no longer issues local ISSUE_CLOSE_SKILL git writes"
    fi
}

test_l3_32_issue_600_issue_create_skill_guards_main_worktree() {
    # #600: /issue-create from main worktree must be guarded.
    # The SKILL.md must contain a guard / abort instruction for main worktree.
    require_file "$ISSUE_CREATE_SKILL" "test_l3_32_issue_600_issue_create_skill_guards_main_worktree" || return
    if grep -iE 'main worktree|mainCheckout|ENFORCE_WORKTREE' "$ISSUE_CREATE_SKILL" >/dev/null; then
        pass "L3.32 #600: /issue-create SKILL.md references main worktree guard"
    else
        fail "L3.32 #600: /issue-create SKILL.md missing main worktree guard text"
    fi
}

test_l3_33_issue_527_gh_api_patch_refs_from_linked_worktree() {
    require_file "$GUARD_JS" "test_l3_33_issue_527_gh_api_patch_refs_from_linked_worktree" || return
    local pair; pair="$(setup_linked_worktree "l3-33")"
    local wt="${pair#*|}"
    local cmd='gh api -X PATCH repos/owner/demo/git/refs/heads/main -f sha=abc'
    local out
    out="$(run_bash_guard "$cmd" "$wt" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L3.33 #527: gh api PATCH git/refs from linked worktree: allowed"
    else
        fail "L3.33 #527: gh api PATCH refs from linked worktree: should allow ($out)"
    fi
}

test_l3_34_issue_419_write_tool_to_workflow_plans() {
    # #419: Write tool to ~/.workflow-plans/ (non-git path) must still be allowed.
    require_file "$GUARD_JS" "test_l3_34_issue_419_write_tool_to_workflow_plans" || return
    local p="$TMPDIR_BASE/workflow-plans-$$"
    mkdir -p "$p"
    local out
    out="$(run_edit_guard "Write" "$p/intent.md" "$TMPDIR_BASE" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L3.34 #419: Write to non-git ~/.workflow-plans path: allowed (fail-open)"
    else
        fail "L3.34 #419: Write to non-git path: should allow ($out)"
    fi
}

test_l3_35_issue_359_stderr_devnull_in_command_subst() {
    # #359: stderr-redirect-to-/dev/null inside command substitution should
    # not be flagged as a write target.
    require_file "$GUARD_JS" "test_l3_35_issue_359_stderr_devnull_in_command_subst" || return
    local pair; pair="$(setup_linked_worktree "l3-35")"
    local wt="${pair#*|}"
    # Inner 2>/dev/null inside a $() — this is a read-classified pattern.
    local cmd='OUT=$(git rev-parse HEAD 2>/dev/null)'
    local out
    out="$(run_bash_guard "$cmd" "$wt" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L3.35 #359: 2>/dev/null in \$() not flagged as write — allowed"
    else
        fail "L3.35 #359: 2>/dev/null inside cmd subst false-positive ($out)"
    fi
}

# ============ Run all ============

# L1 — enforce-worktree.js
test_l1_1_bypass_functions_not_exported
test_l1_2_issue_close_skill_inline_blocked_in_main
test_l1_3_compose_doc_append_skill_inline_blocked_in_main
test_l1_4_bash_in_non_git_cwd_blocks
test_l1_5_edit_to_non_git_path_allows
test_l1_6_linked_worktree_feature_branch_allows
test_l1_7_main_worktree_denies
test_l1_8_existing_lifecycle_exceptions_intact

# L1 — github-contents-validate.sh
test_l1_9_validate_accepts_well_formed_history
test_l1_10_validate_rejects_empty_file
test_l1_11_validate_rejects_over_hard_limit
test_l1_12_validate_rejects_wrong_commit_subject
test_l1_13_validate_rejects_no_trailing_newline
test_l1_14_validate_warns_on_non_ascii_english

# L1 — github-contents-write.sh
test_l1_15_contents_write_success
test_l1_16_contents_write_409_retries
test_l1_17_contents_write_422_exhausted
test_l1_18_contents_write_base64_no_newlines

# L1 — github-git-data-write.sh
test_l1_19_git_data_call_order_single_file
test_l1_20_git_data_blobs_before_tree
test_l1_21_git_data_tree_entry_payload
test_l1_22_git_data_ref_patch_422_exhausted
test_l1_23_git_data_ref_patch_422_then_success

# L2 — integration
test_l2_24_main_issue_close_skill_add_history_blocked
test_l2_25_linked_worktree_normal_bash_write_allowed
test_l2_26_main_gh_api_put_contents_allowed
test_l2_27_non_git_cwd_bash_blocked
test_l2_28_non_git_path_write_tool_allowed
test_l2_29_linked_worktree_gh_api_post_blob_allowed
test_l2_30_main_git_push_origin_main_blocked

# L3 — E2E / subsumes
test_l3_31_issue_672_step_e_no_local_git_writes
test_l3_32_issue_600_issue_create_skill_guards_main_worktree
test_l3_33_issue_527_gh_api_patch_refs_from_linked_worktree
test_l3_34_issue_419_write_tool_to_workflow_plans
test_l3_35_issue_359_stderr_devnull_in_command_subst

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
