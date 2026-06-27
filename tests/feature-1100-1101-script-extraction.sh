#!/usr/bin/env bash
# Tests: skills/issue-close-stage/scripts/run-stage-chain.sh, skills/issue-close-finalize/scripts/run-initial.sh, skills/issue-close-finalize/scripts/run-finalize-terminal.sh, skills/issue-close-finalize/scripts/run-loop-step.js, agents/issue-close-stage-worker.md, agents/issue-close-finalize-worker.md
# Tags: issue-close, stage, finalize, worker, script-extraction
set -euo pipefail

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 30 "$@"
    else
        perl -e 'alarm 30; exec @ARGV' -- "$@"
    fi
}

cd "$(git rev-parse --show-toplevel)"

PASS=0
FAIL=0
FAILED_TESTS=()

assert() {
    local name="$1"
    local result="$2"
    if [ "$result" -eq 0 ]; then
        PASS=$((PASS + 1))
        echo "PASS: $name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        echo "FAIL: $name"
    fi
}

run() {
    local name="$1"
    local fn="$2"
    local rc=0
    "$fn" || rc=$?
    assert "$name" "$rc"
}

# Write a valid state JSON file via node (avoids heredoc shell-quoting issues).
# Usage: _write_state <file> <schema_version> <g5_3a_completed_bool> <g5_history_empty_bool>
# g5_history_empty_bool: "true" writes [], "false" writes one default entry
_write_state() {
    local file="$1"
    local sv="${2:-3}"
    local g5_3a="${3:-false}"
    local empty_history="${4:-false}"
    node -e "
const fs = require('fs');
const sv = Number(process.argv[1]);
const g5_3a = process.argv[2] === 'true';
const emptyHist = process.argv[3] === 'true';
const hist = emptyHist ? [] : [{
  iteration: 1, issue_number: '42', proposal_status: 'ok',
  proposal_parent: 7, user_decision: null,
  g5_3a_completed: g5_3a, recursion_completed: false
}];
const state = {
  schema_version: sv,
  root_issue_number: 42, current_issue_number: 42,
  owner_repo: 'owner/repo',
  agents_config_dir: '/tmp/x', main_worktree_path: '/tmp/x',
  phase: 'init_done', triage_action: 'resume_h',
  g5_loop_iteration: 0, g5_history: hist,
  proposal_counters: {accepted: 0, declined: 0, skipped: 0}
};
fs.writeFileSync(process.argv[4], JSON.stringify(state, null, 2));
" "$sv" "$g5_3a" "$empty_history" "$file"
}

# Read a field from a state JSON file via node
_read_state_field() {
    local file="$1"
    local field="$2"
    node -e "
const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
const parts = process.argv[2].split('.');
let v = s;
for (const p of parts) v = v[p];
process.stdout.write(String(v));
" "$file" "$field" 2>/dev/null || echo ""
}

# ---------------- Group 1: Existence + executable checks ----------------

test_e1_run_stage_chain_exists_executable() {
    local f="skills/issue-close-stage/scripts/run-stage-chain.sh"
    [ -f "$f" ] && [ -x "$f" ]
}

test_e2_run_initial_exists_executable() {
    local f="skills/issue-close-finalize/scripts/run-initial.sh"
    [ -f "$f" ] && [ -x "$f" ]
}

test_e3_run_finalize_terminal_exists_executable() {
    local f="skills/issue-close-finalize/scripts/run-finalize-terminal.sh"
    [ -f "$f" ] && [ -x "$f" ]
}

test_e4_run_loop_step_exists() {
    [ -f "skills/issue-close-finalize/scripts/run-loop-step.js" ]
}

# ---------------- Group 2: run-loop-step.js — pure state mutations ----------------

test_l1_decline_decision() {
    local TMP rc=0
    TMP=$(mktemp -d)
    local STATE="$TMP/state.json"
    _write_state "$STATE" 3 false false

    local OUTPUT
    OUTPUT=$(AGENTS_CONFIG_DIR=/tmp/x FINALIZE_SCRIPTS_DIR=/tmp/x \
        node skills/issue-close-finalize/scripts/run-loop-step.js \
        "$STATE" "decline" 2>/dev/null || true)

    local FAILED=0
    if ! echo "$OUTPUT" | grep -q 'STATUS=terminal'; then
        echo "  expected STATUS=terminal in stdout, got: $OUTPUT"
        FAILED=1
    fi

    local phase declined
    phase=$(_read_state_field "$STATE" "phase")
    declined=$(_read_state_field "$STATE" "proposal_counters.declined")

    if [ "$phase" != "terminal" ]; then
        echo "  expected phase=terminal in state, got: $phase"
        FAILED=1
    fi
    if [ "$declined" != "1" ]; then
        echo "  expected proposal_counters.declined=1, got: $declined"
        FAILED=1
    fi

    rm -rf "$TMP"
    return $FAILED
}

test_l2_llm_declined_decision() {
    local TMP
    TMP=$(mktemp -d)
    local STATE="$TMP/state.json"
    _write_state "$STATE" 3 false false

    local OUTPUT
    OUTPUT=$(AGENTS_CONFIG_DIR=/tmp/x FINALIZE_SCRIPTS_DIR=/tmp/x \
        node skills/issue-close-finalize/scripts/run-loop-step.js \
        "$STATE" "llm_declined" 2>/dev/null || true)

    local FAILED=0
    if ! echo "$OUTPUT" | grep -q 'STATUS=terminal'; then
        echo "  expected STATUS=terminal in stdout, got: $OUTPUT"
        FAILED=1
    fi

    local phase declined
    phase=$(_read_state_field "$STATE" "phase")
    declined=$(_read_state_field "$STATE" "proposal_counters.declined")

    if [ "$phase" != "terminal" ]; then
        echo "  expected phase=terminal in state, got: $phase"
        FAILED=1
    fi
    if [ "$declined" != "1" ]; then
        echo "  expected proposal_counters.declined=1, got: $declined"
        FAILED=1
    fi

    rm -rf "$TMP"
    return $FAILED
}

test_l3_unknown_g5_decision() {
    local TMP
    TMP=$(mktemp -d)
    local STATE="$TMP/state.json"
    _write_state "$STATE" 3 false false

    local OUTPUT
    OUTPUT=$(AGENTS_CONFIG_DIR=/tmp/x FINALIZE_SCRIPTS_DIR=/tmp/x \
        node skills/issue-close-finalize/scripts/run-loop-step.js \
        "$STATE" "bogus_decision" 2>/dev/null || true)

    local FAILED=0
    if ! echo "$OUTPUT" | grep -q 'STATUS=failed'; then
        echo "  expected STATUS=failed in stdout, got: $OUTPUT"
        FAILED=1
    fi

    rm -rf "$TMP"
    return $FAILED
}

test_l4_missing_state_file() {
    local OUTPUT
    OUTPUT=$(AGENTS_CONFIG_DIR=/tmp/x FINALIZE_SCRIPTS_DIR=/tmp/x \
        node skills/issue-close-finalize/scripts/run-loop-step.js \
        "/nonexistent/path/state.json" "decline" 2>/dev/null || true)

    local FAILED=0
    if ! echo "$OUTPUT" | grep -q 'STATUS=failed'; then
        echo "  expected STATUS=failed for missing state file, got: $OUTPUT"
        FAILED=1
    fi
    return $FAILED
}

test_l5_wrong_schema_version() {
    local TMP
    TMP=$(mktemp -d)
    local STATE="$TMP/state.json"
    _write_state "$STATE" 2 false false

    local OUTPUT
    OUTPUT=$(AGENTS_CONFIG_DIR=/tmp/x FINALIZE_SCRIPTS_DIR=/tmp/x \
        node skills/issue-close-finalize/scripts/run-loop-step.js \
        "$STATE" "decline" 2>/dev/null || true)

    local FAILED=0
    if ! echo "$OUTPUT" | grep -q 'STATUS=failed'; then
        echo "  expected STATUS=failed for schema_version=2, got: $OUTPUT"
        FAILED=1
    fi

    rm -rf "$TMP"
    return $FAILED
}

test_l6_empty_g5_history() {
    local TMP
    TMP=$(mktemp -d)
    local STATE="$TMP/state.json"
    _write_state "$STATE" 3 false true  # empty_history=true

    local OUTPUT
    OUTPUT=$(AGENTS_CONFIG_DIR=/tmp/x FINALIZE_SCRIPTS_DIR=/tmp/x \
        node skills/issue-close-finalize/scripts/run-loop-step.js \
        "$STATE" "decline" 2>/dev/null || true)

    local FAILED=0
    if ! echo "$OUTPUT" | grep -q 'STATUS=failed'; then
        echo "  expected STATUS=failed for empty g5_history, got: $OUTPUT"
        FAILED=1
    fi

    rm -rf "$TMP"
    return $FAILED
}

# ---------------- Group 3: Syntax checks ----------------

test_s1_run_stage_chain_syntax() {
    bash -n skills/issue-close-stage/scripts/run-stage-chain.sh
}

test_s2_run_initial_syntax() {
    bash -n skills/issue-close-finalize/scripts/run-initial.sh
}

test_s3_run_finalize_terminal_syntax() {
    bash -n skills/issue-close-finalize/scripts/run-finalize-terminal.sh
}

test_s4_run_loop_step_syntax() {
    node --check skills/issue-close-finalize/scripts/run-loop-step.js
}

# ---------------- Group 4: Worker dispatch pattern checks ----------------

test_w1_stage_worker_references_run_stage_chain() {
    grep -q 'run-stage-chain.sh' agents/issue-close-stage-worker.md
}

test_w2_finalize_worker_references_all_scripts() {
    local FAILED=0
    if ! grep -q 'run-initial.sh' agents/issue-close-finalize-worker.md; then
        echo "  run-initial.sh not referenced in finalize-worker.md"
        FAILED=1
    fi
    if ! grep -q 'run-loop-step.js' agents/issue-close-finalize-worker.md; then
        echo "  run-loop-step.js not referenced in finalize-worker.md"
        FAILED=1
    fi
    if ! grep -q 'run-finalize-terminal.sh' agents/issue-close-finalize-worker.md; then
        echo "  run-finalize-terminal.sh not referenced in finalize-worker.md"
        FAILED=1
    fi
    return $FAILED
}

test_w3_workers_no_mktemp() {
    local FAILED=0
    if grep -qE 'mktemp|tmpfile' agents/issue-close-stage-worker.md; then
        echo "  mktemp/tmpfile found in issue-close-stage-worker.md"
        FAILED=1
    fi
    if grep -qE 'mktemp|tmpfile' agents/issue-close-finalize-worker.md; then
        echo "  mktemp/tmpfile found in issue-close-finalize-worker.md"
        FAILED=1
    fi
    return $FAILED
}

# W4: verify that eval dispatch pattern exists — eval and script are on adjacent lines
# so we check for eval "$( on one line, with the script file on a nearby line (within 5)
_lines_near_each_other() {
    local file="$1"
    local pattern_a="$2"
    local pattern_b="$3"
    local max_dist="${4:-5}"

    local line_a line_b dist
    line_a=$(grep -n "$pattern_a" "$file" | head -1 | cut -d: -f1)
    line_b=$(grep -n "$pattern_b" "$file" | head -1 | cut -d: -f1)
    if [ -z "$line_a" ] || [ -z "$line_b" ]; then
        return 1
    fi
    dist=$(( line_b - line_a ))
    [ "$dist" -lt 0 ] && dist=$(( -dist ))
    [ "$dist" -le "$max_dist" ]
}

test_w4_workers_use_eval_dispatch() {
    local FAILED=0
    # stage-worker: eval "$( on one line, run-stage-chain.sh within 5 lines
    if ! _lines_near_each_other agents/issue-close-stage-worker.md 'eval' 'run-stage-chain\.sh' 5; then
        echo "  eval dispatch near run-stage-chain.sh not found in stage-worker.md"
        FAILED=1
    fi
    # finalize-worker: eval "$( on one line, run-initial.sh within 5 lines
    if ! _lines_near_each_other agents/issue-close-finalize-worker.md 'eval' 'run-initial\.sh' 5; then
        echo "  eval dispatch near run-initial.sh not found in finalize-worker.md"
        FAILED=1
    fi
    return $FAILED
}

# ---------------- Group 5: run-loop-step.js — accept case with mock ----------------

test_a1_accept_g5_3a_not_completed() {
    local TMP
    TMP=$(mktemp -d)
    local STATE="$TMP/state.json"
    _write_state "$STATE" 3 false false  # g5_3a_completed=false

    # Write mock step-g5-loop.sh that exits 0
    printf '#!/bin/bash\nexit 0\n' > "$TMP/step-g5-loop.sh"
    chmod +x "$TMP/step-g5-loop.sh"

    local OUTPUT
    OUTPUT=$(AGENTS_CONFIG_DIR="$TMP" FINALIZE_SCRIPTS_DIR="$TMP" \
        node skills/issue-close-finalize/scripts/run-loop-step.js \
        "$STATE" "accept" 2>/dev/null || true)

    local FAILED=0
    if ! echo "$OUTPUT" | grep -q 'STATUS=awaiting_recursion'; then
        echo "  expected STATUS=awaiting_recursion, got: $OUTPUT"
        FAILED=1
    fi

    local phase g5_3a
    phase=$(_read_state_field "$STATE" "phase")
    g5_3a=$(_read_state_field "$STATE" "g5_history.0.g5_3a_completed")

    if [ "$phase" != "awaiting_recursion" ]; then
        echo "  expected phase=awaiting_recursion in state, got: $phase"
        FAILED=1
    fi
    if [ "$g5_3a" != "true" ]; then
        echo "  expected g5_3a_completed=true in state, got: $g5_3a"
        FAILED=1
    fi

    rm -rf "$TMP"
    return $FAILED
}

test_a2_accept_g5_3a_already_completed_idempotent() {
    local TMP
    TMP=$(mktemp -d)
    local STATE="$TMP/state.json"
    local MARKER="$TMP/mock-was-called"
    _write_state "$STATE" 3 true false  # g5_3a_completed=true

    # Write mock step-g5-loop.sh that writes a marker file if called
    printf '#!/bin/bash\ntouch %s\nexit 0\n' "$MARKER" > "$TMP/step-g5-loop.sh"
    chmod +x "$TMP/step-g5-loop.sh"

    local OUTPUT
    OUTPUT=$(AGENTS_CONFIG_DIR="$TMP" FINALIZE_SCRIPTS_DIR="$TMP" \
        node skills/issue-close-finalize/scripts/run-loop-step.js \
        "$STATE" "accept" 2>/dev/null || true)

    local FAILED=0
    if ! echo "$OUTPUT" | grep -q 'STATUS=awaiting_recursion'; then
        echo "  expected STATUS=awaiting_recursion, got: $OUTPUT"
        FAILED=1
    fi
    if [ -f "$MARKER" ]; then
        echo "  step-g5-loop.sh was called but should have been skipped (g5_3a_completed=true)"
        FAILED=1
    fi

    rm -rf "$TMP"
    return $FAILED
}

# ---------------- Runner ----------------

run "E1: run-stage-chain.sh exists+exec"            test_e1_run_stage_chain_exists_executable
run "E2: run-initial.sh exists+exec"                test_e2_run_initial_exists_executable
run "E3: run-finalize-terminal.sh exists+exec"      test_e3_run_finalize_terminal_exists_executable
run "E4: run-loop-step.js exists"                   test_e4_run_loop_step_exists

run "L1: loop_step decline → STATUS=terminal, declined=1"      test_l1_decline_decision
run "L2: loop_step llm_declined → STATUS=terminal, declined=1" test_l2_llm_declined_decision
run "L3: unknown g5_decision → STATUS=failed"                  test_l3_unknown_g5_decision
run "L4: missing state file → STATUS=failed"                   test_l4_missing_state_file
run "L5: schema_version=2 → STATUS=failed"                     test_l5_wrong_schema_version
run "L6: empty g5_history → STATUS=failed"                     test_l6_empty_g5_history

run "S1: run-stage-chain.sh bash -n syntax check"       test_s1_run_stage_chain_syntax
run "S2: run-initial.sh bash -n syntax check"           test_s2_run_initial_syntax
run "S3: run-finalize-terminal.sh bash -n syntax check" test_s3_run_finalize_terminal_syntax
run "S4: run-loop-step.js node --check syntax"          test_s4_run_loop_step_syntax

run "W1: stage-worker references run-stage-chain.sh"            test_w1_stage_worker_references_run_stage_chain
run "W2: finalize-worker references all 3 dispatch scripts"     test_w2_finalize_worker_references_all_scripts
run "W3: workers contain no mktemp/tmpfile"                     test_w3_workers_no_mktemp
run "W4: workers use eval dispatch pattern"                     test_w4_workers_use_eval_dispatch

run "A1: accept g5_3a_completed=false → mock called, phase=awaiting_recursion" test_a1_accept_g5_3a_not_completed
run "A2: accept g5_3a_completed=true → mock NOT called (idempotent)"           test_a2_accept_g5_3a_already_completed_idempotent

echo ""
echo "==== Summary ===="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do
        echo "  - $t"
    done
    exit 1
fi
exit 0
