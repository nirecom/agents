#!/bin/bash
# Tests: bin/resume-session-detect
# Tags: resume-session, 468
# Test suite for bin/resume-session-detect CLI.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$AGENTS_DIR/bin/resume-session-detect"
PASS=0
FAIL=0

fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

AGENTS_DIR_NATIVE="$AGENTS_DIR"
if command -v cygpath >/dev/null 2>&1; then
    AGENTS_DIR_NATIVE=$(cygpath -w "$AGENTS_DIR")
fi
# Inline SHA-256 computation of REPO_ID — getRepoId was retired in #503
# along with the pending-branch-delete marker mechanism. Path is forward-
# slash-normalised before hashing (matches the prior getRepoId algorithm).
# TODO(#503): if bin/resume-session-detect internally calls getRepoId from
# the (now-retired) module export, this REPO_ID may no longer match what the
# CLI computes. Verify after source-level changes land.
REPO_ID=$(AGENTS_DIR_NATIVE="$AGENTS_DIR_NATIVE" node -e 'const p=process.env.AGENTS_DIR_NATIVE.replace(/\\/g,"/");console.log(require("crypto").createHash("sha256").update(p).digest("hex"))' 2>/dev/null)

if [ -z "$REPO_ID" ] || [ "$REPO_ID" = "null" ]; then
    echo "FATAL: could not compute REPO_ID for $AGENTS_DIR"
    exit 2
fi

build_state_json() {
    local sid="$1" target="${2:-}"
    node -e "
      const sid = process.argv[1];
      const target = process.argv[2] || '';
      const steps = ['workflow_init','clarify_intent','research','outline','detail','branching_complete','write_tests','run_tests','review_security','docs','user_verification','cleanup'];
      const out = { version: 1, session_id: sid, created_at: '2026-05-23T00:00:00.000Z', steps: {} };
      for (const s of steps) {
        out.steps[s] = { status: (s === target ? 'in_progress' : 'pending'), updated_at: null };
      }
      process.stdout.write(JSON.stringify(out));
    " -- "$sid" "$target"
}

write_env_file() {
    local path="$1" sid="$2"
    printf 'CLAUDE_SESSION_ID=%s\n' "$sid" > "$path"
}

run_cli() {
    local subdir="$1" sid="$2" state_json="$3" marker="$4" extra="${5:-}"
    local root="$TMPDIR_BASE/$subdir"
    mkdir -p "$root/state" "$root/plans/worktree-end"
    local env_file=""
    if [ -n "$sid" ]; then
        env_file="$root/env"
        write_env_file "$env_file" "$sid"
        if [ -n "$state_json" ]; then
            printf '%s' "$state_json" > "$root/state/${sid}.json"
        fi
    fi
    if [ -n "$marker" ]; then
        : > "$root/plans/worktree-end/$marker"
    fi
    local out_file="$root/stdout" err_file="$root/stderr"
    if [ -n "$env_file" ]; then
        ( cd "$AGENTS_DIR" && CLAUDE_ENV_FILE="$env_file" CLAUDE_WORKFLOW_DIR="$root/state" WORKFLOW_PLANS_DIR="$root/plans" run_with_timeout node "$CLI" $extra >"$out_file" 2>"$err_file" ) && LAST_EXIT=0 || LAST_EXIT=$?
    else
        ( cd "$AGENTS_DIR" && unset CLAUDE_ENV_FILE && CLAUDE_WORKFLOW_DIR="$root/state" WORKFLOW_PLANS_DIR="$root/plans" run_with_timeout node "$CLI" $extra >"$out_file" 2>"$err_file" ) && LAST_EXIT=0 || LAST_EXIT=$?
    fi
    LAST_OUT=$(cat "$out_file" 2>/dev/null || true)
    LAST_ERR=$(cat "$err_file" 2>/dev/null || true)
}

assert_type() {
    local desc="$1" expected="$2"
    if printf '%s' "$LAST_OUT" | node -e "let b='';process.stdin.on('data',c=>b+=c);process.stdin.on('end',()=>{try{const d=JSON.parse(b);if(d.type===process.argv[1])process.exit(0);process.stderr.write('actual type='+JSON.stringify(d.type));process.exit(1);}catch(e){process.stderr.write('parse error: '+e.message);process.exit(1);}});" "$expected" >/dev/null 2>"$TMPDIR_BASE/.assert_err"; then
        pass "$desc"
    else
        local why=$(cat "$TMPDIR_BASE/.assert_err" 2>/dev/null || true)
        fail "$desc - expected type=$expected ($why); raw: $LAST_OUT"
    fi
}

assert_field() {
    local desc="$1" field="$2" expected="$3"
    if printf '%s' "$LAST_OUT" | node -e "let b='';process.stdin.on('data',c=>b+=c);process.stdin.on('end',()=>{try{const d=JSON.parse(b);if(d[process.argv[1]]===process.argv[2])process.exit(0);process.stderr.write('actual '+process.argv[1]+'='+JSON.stringify(d[process.argv[1]]));process.exit(1);}catch(e){process.stderr.write('parse error: '+e.message);process.exit(1);}});" "$field" "$expected" >/dev/null 2>"$TMPDIR_BASE/.assert_err"; then
        pass "$desc"
    else
        local why=$(cat "$TMPDIR_BASE/.assert_err" 2>/dev/null || true)
        fail "$desc - expected $field=$expected ($why); raw: $LAST_OUT"
    fi
}

assert_exit() {
    local desc="$1" expected="$2"
    if [ "$LAST_EXIT" = "$expected" ]; then
        pass "$desc"
    else
        fail "$desc - expected exit $expected, got $LAST_EXIT; stderr: $LAST_ERR"
    fi
}

assert_stderr_contains() {
    local desc="$1" needle="$2"
    local lower_err lower_needle
    lower_err=$(printf '%s' "$LAST_ERR" | tr '[:upper:]' '[:lower:]')
    lower_needle=$(printf '%s' "$needle" | tr '[:upper:]' '[:lower:]')
    if [[ "$lower_err" == *"$lower_needle"* ]]; then
        pass "$desc"
    else
        fail "$desc - expected $needle in stderr, got: $LAST_ERR"
    fi
}

assert_stdout_contains() {
    local desc="$1" needle="$2"
    if printf '%s' "$LAST_OUT" | grep -qF "$needle" 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc - expected $needle in stdout, got: $LAST_OUT"
    fi
}

echo "=== T1: none_when_no_envfile ==="
run_cli "t1" "" "" ""
assert_type "T1. type=none when CLAUDE_ENV_FILE unset" "none"
assert_exit "T1. exit 0 when CLAUDE_ENV_FILE unset" "0"

echo ""
echo "=== T2: none_when_envfile_lacks_sid ==="
T2_ROOT="$TMPDIR_BASE/t2"
mkdir -p "$T2_ROOT/state" "$T2_ROOT/plans/worktree-end"
printf 'SOMETHING_ELSE=foo\n' > "$T2_ROOT/env"
( cd "$AGENTS_DIR" && CLAUDE_ENV_FILE="$T2_ROOT/env" CLAUDE_WORKFLOW_DIR="$T2_ROOT/state" WORKFLOW_PLANS_DIR="$T2_ROOT/plans" run_with_timeout node "$CLI" >"$T2_ROOT/stdout" 2>"$T2_ROOT/stderr" ) || true
LAST_EXIT=$?
LAST_OUT=$(cat "$T2_ROOT/stdout" 2>/dev/null || true)
LAST_ERR=$(cat "$T2_ROOT/stderr" 2>/dev/null || true)
assert_type "T2. type=none when env file lacks CLAUDE_SESSION_ID" "none"
assert_exit "T2. exit 0 when env file lacks CLAUDE_SESSION_ID" "0"

echo ""
echo "=== T3: none_when_state_missing ==="
run_cli "t3" "test-session-001" "" ""
assert_type "T3. type=none when state file missing" "none"
assert_exit "T3. exit 0 when state file missing" "0"

echo ""
echo "=== T4: none_when_all_pending ==="
T4_JSON=$(build_state_json "test-session-001" "")
run_cli "t4" "test-session-001" "$T4_JSON" ""
assert_type "T4. type=none when all steps pending" "none"
assert_exit "T4. exit 0 when all steps pending" "0"

echo ""
echo "=== T5-T11: skill mapping ==="

run_skill_case() {
    local tname="$1" subdir="$2" step="$3" expected_skill="$4"
    local sid="sid-$subdir"
    local json
    json=$(build_state_json "$sid" "$step")
    run_cli "$subdir" "$sid" "$json" ""
    assert_type "$tname. type=skill when $step in_progress" "skill"
    assert_field "$tname. step=$step" "step" "$step"
    assert_field "$tname. skill=$expected_skill" "skill" "$expected_skill"
}

run_skill_case "T5"  "t5"  "clarify_intent" "clarify-intent"
run_skill_case "T6a" "t6a" "outline"        "make-outline-plan"
run_skill_case "T6b" "t6b" "detail"         "make-detail-plan"
run_skill_case "T7"  "t7"  "write_tests"    "write-tests"
run_skill_case "T8"  "t8"  "run_tests"      "run-tests"
run_skill_case "T9"  "t9"  "docs"           "update-docs"
run_skill_case "T10" "t10" "cleanup"        "worktree-end"
run_skill_case "T11" "t11" "workflow_init"  "workflow-init"

echo ""
echo "=== T12-T15: sentinel-wait steps ==="

run_sentinel_case() {
    local tname="$1" subdir="$2" step="$3"
    local sid="sid-$subdir"
    local json
    json=$(build_state_json "$sid" "$step")
    run_cli "$subdir" "$sid" "$json" ""
    assert_type "$tname. type=sentinel-wait when $step in_progress" "sentinel-wait"
    assert_field "$tname. step=$step" "step" "$step"
}

run_sentinel_case "T12" "t12" "user_verification"
run_sentinel_case "T13" "t13" "branching_complete"
run_sentinel_case "T14" "t14" "research"
run_sentinel_case "T15" "t15" "review_security"

echo ""
echo "=== T18: exit_code_always_zero ==="
run_cli "t18a" "missing-state-sid" "" ""
assert_exit "T18a. exit 0 (T3 case: no state)" "0"

T18B_JSON=$(build_state_json "sid-t18b" "clarify_intent")
run_cli "t18b" "sid-t18b" "$T18B_JSON" ""
assert_exit "T18b. exit 0 (T5 case: skill)" "0"

T18C_JSON=$(build_state_json "sid-t18c" "user_verification")
run_cli "t18c" "sid-t18c" "$T18C_JSON" ""
assert_exit "T18c. exit 0 (T12 case: sentinel-wait)" "0"

echo ""
echo "=== T19: exit_code_unknown_flag ==="
run_cli "t19" "" "" "" "--bogus-flag"
assert_exit "T19. exit 1 for unknown flag" "1"
assert_stderr_contains "T19. stderr mentions unknown flag" "nknown"

echo ""
echo "=== T20: exit_code_help ==="
run_cli "t20" "" "" "" "--help"
assert_exit "T20. exit 0 for --help" "0"
assert_stdout_contains "T20. stdout contains Usage" "Usage"

echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed!"
    exit 0
else
    exit 1
fi
