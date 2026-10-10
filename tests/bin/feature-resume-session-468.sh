#!/bin/bash
# Tests: bin/resume-session-detect, skills/resume-session/SKILL.md
# Tags: session, resume, workflow, bin, tests, scope:common, pwsh-not-required, TL2, wi-10-lookahead, prompt-injection, security, regression-2279
# Test suite for bin/resume-session-detect CLI.
# Cases live in the sibling folder feature-resume-session-468/ (sourced below, never run standalone).
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$SCRIPT_CHECKOUT_ROOT/bin/resume-session-detect"

# Fixture isolation (rules/test/fixture-isolation.md): the parent Claude Code
# session exports this, and resolveSessionId() would then resolve the developer's
# live session — every case below would read it out of an empty fixture store
# and see only {"type":"none"}.
unset CLAUDE_CODE_SESSION_ID

# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
_ISOLATION_TMP_ROOT="$(make_tmp)"; readonly _ISOLATION_TMP_ROOT
harness_isolate "$_ISOLATION_TMP_ROOT"

# Overrides the harness run_with_timeout: callers here pass no seconds argument.
run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

SCRIPT_CHECKOUT_ROOT_NATIVE="$SCRIPT_CHECKOUT_ROOT"
if command -v cygpath >/dev/null 2>&1; then
    SCRIPT_CHECKOUT_ROOT_NATIVE=$(cygpath -w "$SCRIPT_CHECKOUT_ROOT")
fi
# Inline SHA-256 computation of REPO_ID — getRepoId was retired in #503
# along with the pending-branch-delete marker mechanism. Path is forward-
# slash-normalised before hashing (matches the prior getRepoId algorithm).
# TODO(#503): if bin/resume-session-detect internally calls getRepoId from
# the (now-retired) module export, this REPO_ID may no longer match what the
# CLI computes. Verify after source-level changes land.
REPO_ID=$(SCRIPT_CHECKOUT_ROOT_NATIVE="$SCRIPT_CHECKOUT_ROOT_NATIVE" node -e 'const p=process.env.SCRIPT_CHECKOUT_ROOT_NATIVE.replace(/\\/g,"/");console.log(require("crypto").createHash("sha256").update(p).digest("hex"))' 2>/dev/null)

if [ -z "$REPO_ID" ] || [ "$REPO_ID" = "null" ]; then
    echo "FATAL: could not compute REPO_ID for $SCRIPT_CHECKOUT_ROOT"
    exit 2
fi

# Worktree copy of the skill under test (LOCAL_SKILL_MD per fixture-isolation.md).
SKILL_MD_LOCAL="$SCRIPT_CHECKOUT_ROOT/skills/resume-session/SKILL.md"

# Node-facing module paths for the cases that seed a real store through markStep.
SCRIPT_CHECKOUT_ROOT_NODE="$SCRIPT_CHECKOUT_ROOT"
if command -v cygpath >/dev/null 2>&1; then
    SCRIPT_CHECKOUT_ROOT_NODE=$(cygpath -m "$SCRIPT_CHECKOUT_ROOT")
fi
SIO_NODE="$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io.js"
LIFECYCLE_NODE="$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/lifecycle.js"

build_state_json() {
    local sid="$1" target="${2:-}"
    node -e "
      const sid = process.argv[1];
      const target = process.argv[2] || '';
      const steps = ['workflow_init','clarify_intent','research','outline','detail','branching_complete','write_tests','review_tests','run_tests','review_security','docs','user_verification','cleanup'];
      const out = { version: 1, session_id: sid, created_at: '2026-05-23T00:00:00.000Z', steps: {} };
      for (const s of steps) {
        out.steps[s] = { status: (s === target ? 'in_progress' : 'pending'), updated_at: null };
      }
      process.stdout.write(JSON.stringify(out));
    " -- "$sid" "$target"
}

run_cli() {
    local subdir="$1" sid="$2" state_json="$3" marker="$4" extra="${5:-}"
    local root="$TMPDIR_BASE/$subdir"
    mkdir -p "$root/state" "$root/plans/worktree-end"
    if [ -n "$sid" ] && [ -n "$state_json" ]; then
        printf '%s' "$state_json" > "$root/state/${sid}.json"
    fi
    if [ -n "$marker" ]; then
        : > "$root/plans/worktree-end/$marker"
    fi
    local out_file="$root/stdout" err_file="$root/stderr"
    if [ -n "$sid" ]; then
        # CLAUDE_CODE_SESSION_ID is the supported env carrier
        # (docs/architecture/claude-code/session-id-resolution.md).
        ( cd "$SCRIPT_CHECKOUT_ROOT" && CLAUDE_CODE_SESSION_ID="$sid" WORKFLOW_STATE_DIR="$root/state" WORKFLOW_PLANS_DIR="$root/plans" run_with_timeout node "$CLI" $extra >"$out_file" 2>"$err_file" ) && LAST_EXIT=0 || LAST_EXIT=$?
    else
        ( cd "$SCRIPT_CHECKOUT_ROOT" && WORKFLOW_STATE_DIR="$root/state" WORKFLOW_PLANS_DIR="$root/plans" run_with_timeout node "$CLI" $extra >"$out_file" 2>"$err_file" ) && LAST_EXIT=0 || LAST_EXIT=$?
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

FRAG_DIR="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-resume-session-468"

case_begin "detect-routing" "bin/resume-session-detect"
if [[ ! -f "$FRAG_DIR/detect-routing.sh" ]]; then
    fail "fragment missing: $FRAG_DIR/detect-routing.sh"
else
    # shellcheck source=/dev/null
    . "$FRAG_DIR/detect-routing.sh"
fi
case_end

case_begin "skill-procedure-order" "skills/resume-session/SKILL.md"
if [[ ! -f "$FRAG_DIR/skill-procedure-order.sh" ]]; then
    fail "fragment missing: $FRAG_DIR/skill-procedure-order.sh"
else
    # shellcheck source=/dev/null
    . "$FRAG_DIR/skill-procedure-order.sh"
fi
case_end

case_begin "lookahead-origin" "bin/resume-session-detect"
if [[ ! -f "$FRAG_DIR/lookahead-origin.sh" ]]; then
    fail "fragment missing: $FRAG_DIR/lookahead-origin.sh"
else
    # shellcheck source=/dev/null
    . "$FRAG_DIR/lookahead-origin.sh"
fi
case_end

case_begin "cross-session-injection" "bin/resume-session-detect"
if [[ ! -f "$FRAG_DIR/cross-session-injection.sh" ]]; then
    fail "fragment missing: $FRAG_DIR/cross-session-injection.sh"
else
    # shellcheck source=/dev/null
    . "$FRAG_DIR/cross-session-injection.sh"
fi
case_end

case_begin "cross-session-skill-contract" "skills/resume-session/SKILL.md"
if [[ ! -f "$FRAG_DIR/cross-session-skill-contract.sh" ]]; then
    fail "fragment missing: $FRAG_DIR/cross-session-skill-contract.sh"
else
    # shellcheck source=/dev/null
    . "$FRAG_DIR/cross-session-skill-contract.sh"
fi
case_end

case_begin "from-boundary" "bin/resume-session-detect"
if [[ ! -f "$FRAG_DIR/from-boundary.sh" ]]; then
    fail "fragment missing: $FRAG_DIR/from-boundary.sh"
else
    # shellcheck source=/dev/null
    . "$FRAG_DIR/from-boundary.sh"
fi
case_end

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
