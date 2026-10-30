#!/bin/bash
# tests/hooks/feature-2099-complexity-stage-routing/_lib.sh — sourced by the feature-2099-complexity-stage-routing*.sh entrypoints; NOT a test file.
# Fixtures + helpers shared by every #2099 group entrypoint (#2723 split).

# TL3 gap (what these tests do NOT catch):
# - The literal Agent-tool call (consumer-orchestration-cases.sh and E2E-1..E2E-4 in
#   live-e2e-cases.sh cover everything up to it).
# - Whether clarify-intent's real agent emits a parseable `SIGNALS:` line (PI-5 covers
#   the adversarial half under RUN_TL3).
# Closest-to-action mitigation: bin/check-verification-gate.sh category: skill-orchestration.

_D2099_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SCRIPT_CHECKOUT_ROOT and AGENTS_MAIN_ROOT are assigned by each entrypoint before this is sourced.
# tests/lib/harness.sh is already sourced by the entrypoint (before its pin); the local
# helpers below keep their own semantics (ERRORS counter, <desc> <want> <got> assert_eq,
# fixed-120s run_with_timeout) and override harness's.
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }
# Documented non-runnable scenario (rules/test.md Pattern 3). Never an error:
# it records that the gap is known, and the reasoning lives at the call site.
skip() { echo "SKIP: $1"; }
# A closed RUN_TL3 gate SKIPs on an ordinary run, but the RUN_TL3-ON lane
# (tests/skills/TL3-complexity-stage-routing-live-judge.sh, which exports
# D2099_REQUIRE_LIVE=1) exists precisely to execute those cases: a gate that is
# still closed THERE is the silent-opt-out false green, so it fails instead.
gated_skip() {
    if [ "${D2099_REQUIRE_LIVE:-0}" = "1" ]; then
        fail "$1 — the required-live lane ran with this gate CLOSED; it must be open there"
    else
        skip "$1"
    fi
}

# Portable timeout wrapper (macOS has no `timeout`); rules/test.md mandates 120s.
run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

to_node_path() {
    cygpath -m "$1" 2>/dev/null || echo "$1"
}

# --- fixture isolation ------------------------------------------------------
# TMPDIR_BASE, WORKFLOW_STATE_DIR, WORKFLOW_PLANS_DIR and AGENTS_STATE_DIR are pinned
# by each entrypoint at its own top level (check-plans-dir-isolation reads the pin there).

# Model-producer aliases used by #2100 model= line tests. Exported so every
# child node process (BIN_DERIVE, BIN_READ) inherits them regardless of what
# a developer's .env sets.
export PRODUCER_HIGH_MODEL=opus
export PRODUCER_LOW_MODEL=sonnet

# Do not inherit the outer Claude Code session into resolveSessionId().
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true

# --- module / CLI paths -----------------------------------------------------
CR_MOD_N="$(to_node_path "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state/complexity-routing.js")"
BARREL_N="$(to_node_path "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state.js")"
RESOLVER_N="$(to_node_path "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state/skip-signal-resolver.js")"
SESSION_FIELDS_N="$(to_node_path "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state/state-io/session-fields.js")"
export CR_MOD_N BARREL_N RESOLVER_N SESSION_FIELDS_N

BIN_RECORD="$SCRIPT_CHECKOUT_ROOT/bin/workflow/record-complexity-evaluation"
BIN_READ="$SCRIPT_CHECKOUT_ROOT/bin/workflow/read-complexity-evaluation"
BIN_DERIVE="$SCRIPT_CHECKOUT_ROOT/bin/workflow/derive-complexity-level"
RUBRIC="$SCRIPT_CHECKOUT_ROOT/skills/_shared/judge-task-complexity.md"

# --- assertion helpers ------------------------------------------------------
# `want` comes from the case table; `got` always from a real invocation — never
# two literals (bin/check-false-green.sh pattern 2).
assert_eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$desc"
    else
        fail "$desc — want: [$want], got: [$got]"
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) pass "$desc" ;;
        *) fail "$desc — expected to contain [$needle], got: [$haystack]" ;;
    esac
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) fail "$desc — expected NOT to contain [$needle], got: [$haystack]" ;;
        *) pass "$desc" ;;
    esac
}

# Compare multi-line actual output against an expected block read from stdin.
assert_block() {
    local desc="$1" actual="$2"
    local expected
    expected="$(cat)"
    if [ "$expected" = "$actual" ]; then
        pass "$desc"
    else
        fail "$desc — output differs from expected table"
        diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed 's/^/    /' || true
    fi
}

# Run a JS snippet under the pinned fixture env. stderr folds into stdout so a
# missing-implementation failure is visible in the assertion message.
run_node() {
    run_with_timeout node -e "$1" 2>&1
}

# Node exit status for a snippet, without capturing stdout.
node_rc() {
    local rc=0
    run_with_timeout node -e "$1" >/dev/null 2>&1 || rc=$?
    echo "$rc"
}

# Which interpreter a bin/workflow entry point needs, read from its OWN shebang
# rather than assumed. Dispatching a bash entry point through `node` dies on a
# syntax error BEFORE the script's own validation runs, so every "it rejected
# the hostile input" assertion would measure Node's parser (round-7 C4/C6).
d2099_cli_runner() {
    case "$(head -1 "$1" 2>/dev/null)" in
        *node*) echo node ;;
        *bash*|*/sh) echo bash ;;
        *) echo node ;;
    esac
}

# Creates an initialized workflow session ON DISK and echoes its id.
# createInitialState() is a PURE constructor (state-io/core.js): persisting is
# writeState's job, so a seeder that stopped early left NO file (round-9 C3).
new_session() {
    local sid="s2099-${1:-x}-$$-$RANDOM"
    BARREL="$BARREL_N" SID="$sid" run_with_timeout node -e '
const b = require(process.env.BARREL);
const sid = process.env.SID;
b.writeState(sid, b.createInitialState(sid));
' >/dev/null 2>&1 || true
    echo "$sid"
}

# The zero-signal translation, owned in ONE place (CPR-SSOT).
# `none` is the JUDGE's output-protocol marker for "no signal matched" (detail.md
# D5), not a signal id; the CLIs' zero-signal value is `--signals ""`. Passing the
# literal `none` routes to undecidable_level=HIGH (D1 step 5) - the inversion the
# marker exists to prevent. Every path carrying a judge line into `--signals`
# goes through here. `S0-undecidable` is a real reserved token: never translated.
d2099_csv_for_cli() {
    case "$1" in
        none|NONE|None|'') printf '' ;;
        *) printf '%s' "$1" ;;
    esac
}

# --- bounded skill-section extraction ---------------------------------------
# Every cross-module wiring case pulls a command line out of a SKILL.md. An
# unbounded whole-file grep takes the FIRST match ANYWHERE (round-10 C1), so
# these helpers bound every extraction to the named step's OWN section, and
# d2099_assert_section_cli_unique makes zero-or-duplicate a named failure.

# Which step OWNS a given CLI inside a given skill (detail.md P4/P5).
d2099_section_step() {
    case "$1:$2" in
        make-detail-plan:read-complexity-evaluation|make-detail-plan:derive-complexity-level) echo "MDP-3" ;;
        # #2102 moved write-tests' and write-code's stored-evaluation read OUT of
        # the level step: WT-0 / WCD-0 now make ONE bundled `read-session-facts`
        # call whose record carries COMPLEXITY_LEVEL_<stage> / COMPLEXITY_SIGNALS.
        # The NONE-fallback `derive-complexity-level` call stays in WT-6 / WCD-3,
        # so the two CLIs now own two DIFFERENT sections in those two skills.
        write-tests:read-session-facts) echo "WT-0" ;;
        write-code:read-session-facts) echo "WCD-0" ;;
        write-tests:derive-complexity-level) echo "WT-6" ;;
        write-code:derive-complexity-level) echo "WCD-3" ;;
        *) echo "" ;;
    esac
}

# d2099_step_anchors, d2099_skill_section and the other SKILL.md section readers
# are shared with feature-2460-jev-call-sites-static.sh.
# shellcheck source=./skill-section-helpers.sh
. "$_D2099_LIB_DIR/skill-section-helpers.sh"

d2099_skill_dir_name() { basename "$(dirname "$1")"; }

d2099_section_for_cli() {
    local step
    step=$(d2099_section_step "$(d2099_skill_dir_name "$1")" "$2")
    [ -n "$step" ] || return 0
    d2099_skill_section "$1" "$step"
}

d2099_section_cli_count() {
    local sec
    sec=$(d2099_section_for_cli "$1" "$2")
    [ -n "$sec" ] || { echo 0; return; }
    printf '%s\n' "$sec" | grep -cF -- "$2"
}

# The ONE command line, or "" when the section holds none or several — no caller
# may extract an arbitrary one out of many.
d2099_section_cli_line() {
    [ "$(d2099_section_cli_count "$1" "$2")" = "1" ] || return 0
    d2099_section_for_cli "$1" "$2" | grep -m1 -F -- "$2"
}

d2099_section_has_re() {
    if d2099_skill_section "$1" "$2" | grep -qE -- "$3"; then echo "yes"; else echo "no"; fi
}

# The named failures C1 asks for: unregistered anchor, anchor that matches
# nothing, zero commands in the section, duplicates in the section.
d2099_assert_section_cli_unique() {
    local id="$1" label="$2" f="$3" cli="$4" skill step sec n
    skill=$(d2099_skill_dir_name "$f")
    step=$(d2099_section_step "$skill" "$cli")
    if [ -z "$step" ]; then
        fail "$id $label: no section anchor is registered for [$cli] in $skill/SKILL.md — the wiring cases cannot bound their extraction"
        return 1
    fi
    sec=$(d2099_skill_section "$f" "$step")
    if [ -z "$sec" ]; then
        fail "$id $label: the $step section anchor matched nothing in $skill/SKILL.md — the step was renamed or removed, so any extraction would read some other part of the file"
        return 1
    fi
    n=$(printf '%s\n' "$sec" | grep -cF -- "$cli")
    case "$n" in
        1) pass "$id $label names [$cli] exactly once inside its own $step section" ;;
        0) fail "$id $label: the $step section carries NO [$cli] command line — the required step is unwired, and a match elsewhere in the file is not this step"
           return 1 ;;
        *) fail "$id $label: the $step section carries $n [$cli] lines — a bounded extraction cannot choose between them, so one of them is stale"
           return 1 ;;
    esac
}

# State probes shared by the record/read, hardening, traversal and signals-file suites.
# shellcheck source=./state-probe-helpers.sh
. "$_D2099_LIB_DIR/state-probe-helpers.sh"

CASE_DIR="$_D2099_LIB_DIR"

# Shared tail of every group entrypoint: result banner and exit code.
d2099_finish() {
    echo ""
    echo "=== Results ==="
    if [ "$ERRORS" -eq 0 ]; then
        echo "All tests passed!"
    else
        echo "$ERRORS test(s) failed"
        exit 1
    fi
}
