#!/bin/bash
# tests/bin/feature-commit-gate-redesign/_lib.sh — sourced by feature-commit-gate-redesign.sh; NOT a test file.
# Tests: bin/review-code-codex
# Tags: workflow, gate, hook, worktree, codex, scope:issue-specific
# Pins, repo/state helpers and gate/mark runners shared by section-a.sh .. section-f.sh.
# Also backs hooks/workflow-gate.js and hooks/workflow-mark.js (named in the dispatcher's header).
# The dispatcher sets SCRIPT_CHECKOUT_ROOT before sourcing this file.

GATE_HOOK="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-gate.js"
MARK_HOOK="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-mark.js"
CODEX_BIN="$SCRIPT_CHECKOUT_ROOT/bin/review-code-codex"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/fixture-template.sh"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/glossary-check-record.sh"

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
export WORKFLOW_STATE_DIR="$WORKFLOW_DIR"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Plans-dir isolation (#1799): supervisor-emit must never write into the
# developer's real ~/.workflow-plans/. Pinned alongside WORKFLOW_STATE_DIR.
WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_PLANS_DIR"
export WORKFLOW_PLANS_DIR

NOW_ISO="$(node -e "console.log(new Date().toISOString())" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")"

# ---------------------------------------------------------------------------
# Repo / worktree setup
# ---------------------------------------------------------------------------
# One committed `main` repo, built once; every fixture below is a whole-directory copy (#2723).
FIXTURE_MAIN_TEMPLATE="$TMPDIR_BASE/_template-main"
fixture_template_git_repo "$FIXTURE_MAIN_TEMPLATE" main

# setup_main_checkout <name> — echo a fresh committed repo on `main`.
setup_main_checkout() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    fixture_template_copy "$FIXTURE_MAIN_TEMPLATE" "$repo" || return 1
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
    # #2277: a complete plan stage without a verifying approval reads as pending; bind
    # approvals for the complete ones so the commit-gate cases reach the gate under test.
    node "$SCRIPT_CHECKOUT_ROOT/tests/lib/plan-approval-fixture.js" \
        inject-complete "$WORKFLOW_DIR/${sid}.json" clarify_intent outline detail >/dev/null 2>&1 || true
}

read_state_step() {
    local sid="$1" step="$2"
    local f="$WORKFLOW_DIR/${sid}.json"
    [ -f "$f" ] || { echo "MISSING"; return; }
    # Read through the canonical API: since #1733 `steps` is a PROJECTION over the
    # on-disk event stream, not a persisted top-level key.
    (cd "$SCRIPT_CHECKOUT_ROOT" && node -e "
      try {
        const s = require('./hooks/workflow-state').readState(process.argv[1]);
        const st = s && s.steps && s.steps['$step'];
        console.log(st && st.status ? st.status : 'MISSING');
      } catch(e){ console.log('MISSING'); }
    " "$sid" 2>/dev/null) || echo "MISSING"
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
# Args: sid branch uv-status [other-status: applies to research/outline/detail/write_tests/review_security/run_tests/docs]
state_json() {
    local sid="$1" branch="$2" uv_status="$3" other="${4:-complete}"
    local branch_json
    if [ "$branch" = "null" ]; then branch_json="null"; else branch_json="\"$branch\""; fi
    cat <<EOF
{
  "version": 1, "session_id": "$sid", "git_branch": $branch_json,
  "created_at": "$NOW_ISO",
  "steps": {
    "clarify_intent":     {"status": "$other", "updated_at": "$NOW_ISO"},
    "research":           {"status": "$other", "updated_at": "$NOW_ISO"},
    "outline":            {"status": "$other", "updated_at": "$NOW_ISO"},
    "detail":             {"status": "$other", "updated_at": "$NOW_ISO"},
    "branching_complete": {"status": "$other", "updated_at": "$NOW_ISO"},
    "write_tests":        {"status": "$other", "updated_at": "$NOW_ISO"},
    "review_tests":       {"status": "$other", "updated_at": "$NOW_ISO"},
    "review_security":    {"status": "$other", "updated_at": "$NOW_ISO"},
    "run_tests":          {"status": "$other", "updated_at": "$NOW_ISO"},
    "docs":               {"status": "$other", "updated_at": "$NOW_ISO"},
    "user_verification":  {"status": "$uv_status", "updated_at": "$NOW_ISO"},
    "cleanup":            {"status": "$other", "updated_at": "$NOW_ISO"}
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
    local clarify_intent="complete" research="complete" outline="complete" detail="complete"
    local branching_complete="complete" write_tests="complete" review_tests="complete"
    local review_security="complete" run_tests="complete" docs="complete"
    local user_verification="pending" cleanup="complete"
    while [ $# -ge 2 ]; do
        case "$1" in
            clarify_intent) clarify_intent="$2";;
            research) research="$2";;
            outline) outline="$2";;
            detail) detail="$2";;
            branching_complete) branching_complete="$2";;
            write_tests) write_tests="$2";;
            review_tests) review_tests="$2";;
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
    "clarify_intent":     {"status": "$clarify_intent", "updated_at": "$NOW_ISO"},
    "research":           {"status": "$research", "updated_at": "$NOW_ISO"},
    "outline":            {"status": "$outline", "updated_at": "$NOW_ISO"},
    "detail":             {"status": "$detail", "updated_at": "$NOW_ISO"},
    "branching_complete": {"status": "$branching_complete", "updated_at": "$NOW_ISO"},
    "write_tests":        {"status": "$write_tests", "updated_at": "$NOW_ISO"},
    "review_tests":       {"status": "$review_tests", "updated_at": "$NOW_ISO"},
    "review_security":    {"status": "$review_security", "updated_at": "$NOW_ISO"},
    "run_tests":          {"status": "$run_tests", "updated_at": "$NOW_ISO"},
    "docs":               {"status": "$docs", "updated_at": "$NOW_ISO"},
    "user_verification":  {"status": "$user_verification", "updated_at": "$NOW_ISO"},
    "cleanup":            {"status": "$cleanup", "updated_at": "$NOW_ISO"}
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

place_gate_copy() { # <fixture main worktree>
    local fixture_main_root="$1"
    [ -f "$fixture_main_root/hooks/workflow-gate.js" ] && return 0
    script_checkout_fixture_copy "$fixture_main_root" hooks bin
    printf '/hooks/\n/bin/\n' >> "$fixture_main_root/.git/info/exclude"
}

# The gate enforces only inside the repository it lives in, so it runs from a copy in the fixture.
run_gate() {
    local cwd="$1" json="$2"; shift 2
    local common_dir main_dir=""
    common_dir="$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null)" || common_dir=""
    if [ -n "$common_dir" ]; then
        main_dir="$(node -e "const p=require('path');process.stdout.write(p.dirname(p.resolve(process.argv[1],process.argv[2])))" -- "$cwd" "$common_dir" 2>/dev/null)" || main_dir=""
    fi
    local env_args=("CLAUDE_PROJECT_DIR=$cwd" "WORKFLOW_STATE_DIR=$WORKFLOW_DIR")
    local gate_hook="$GATE_HOOK"
    if [ -n "$main_dir" ]; then
        place_gate_copy "$main_dir"
        gate_hook="$main_dir/hooks/workflow-gate.js"
    fi
    echo "$json" | run_with_timeout 30 env "${env_args[@]}" "$@" node "$gate_hook" 2>/dev/null
}

run_mark() {
    local cwd="$1" json="$2"; shift 2
    echo "$json" | run_with_timeout 30 env CLAUDE_PROJECT_DIR="$cwd" \
        WORKFLOW_STATE_DIR="$WORKFLOW_DIR" "$@" node "$MARK_HOOK" 2>/dev/null
}

is_block() { echo "$1" | grep -q '"block"'; }
is_approve() { echo "$1" | grep -q '"approve"'; }
