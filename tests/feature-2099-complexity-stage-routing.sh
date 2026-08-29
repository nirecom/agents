#!/bin/bash
# tests/feature-2099-complexity-stage-routing.sh
# Tests: hooks/workflow-state/complexity-routing.js, hooks/workflow-state/complexity-routing/secret-shape.js, hooks/workflow-state.js, hooks/workflow-state/state-io/session-fields.js, hooks/workflow-state/state-io/events.js, hooks/workflow-state/state-io/projection.js, hooks/workflow-state/state-io/migrations/v1-to-v2.js, hooks/workflow-state/skip-signal-resolver.js, hooks/workflow-state/skip-signal-resolver/complexity.js, hooks/workflow-state/skip-signal-resolver/condition-schemas.js, bin/workflow/record-complexity-evaluation, bin/workflow/read-complexity-evaluation, bin/workflow/derive-complexity-level, bin/workflow/record-complexity-and-skip, skills/_shared/judge-task-complexity.md, skills/clarify-intent/SKILL.md, skills/workflow-init/SKILL.md, skills/make-detail-plan/SKILL.md, skills/write-tests/SKILL.md, skills/write-code/SKILL.md
# Tags: complexity, routing, stage, workflow-state, cli, fail-open, scope:issue-specific
# Serial: writes complexity_evaluation events into a pinned CLAUDE_WORKFLOW_DIR
# Issue #2099 — per-stage complexity routing. Dispatcher: fixtures + helpers,
# then sources the case files in feature-2099-complexity-stage-routing/.
set -uo pipefail

# TL3 gap (what this test does NOT catch):
# - The Agent-tool call itself. consumer-orchestration-cases.sh runs each skill's OWN
#   documented command and derives the model it would pass, and E2E-1..E2E-4 in
#   live-e2e-cases.sh drive judge -> write point -> store -> reader -> model in one
#   session under RUN_TL3; only the literal Agent invocation stays unobservable.
# - Whether clarify-intent's real agent emits a `SIGNALS:` line the rubric parses
#   (PI-5 in prompt-injection-cases.sh covers the adversarial half under RUN_TL3).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }
# Documented non-runnable scenario (rules/test.md Pattern 3). Never an error:
# it records that the gap is known, and the reasoning lives at the call site.
skip() { echo "SKIP: $1"; }
# A closed RUN_TL3 gate SKIPs on an ordinary run, but the RUN_TL3-ON lane
# (tests/TL3-complexity-stage-routing-live-judge.sh, which exports
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
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_DIR"
export CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR"

WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_PLANS_DIR"
export WORKFLOW_PLANS_DIR

export AGENTS_CONFIG_DIR="$AGENTS_DIR"

# Do not inherit the outer Claude Code session into resolveSessionId().
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
unset CLAUDE_SESSION_ID 2>/dev/null || true

# --- module / CLI paths -----------------------------------------------------
CR_MOD_N="$(to_node_path "$AGENTS_DIR/hooks/workflow-state/complexity-routing.js")"
BARREL_N="$(to_node_path "$AGENTS_DIR/hooks/workflow-state.js")"
RESOLVER_N="$(to_node_path "$AGENTS_DIR/hooks/workflow-state/skip-signal-resolver.js")"
SESSION_FIELDS_N="$(to_node_path "$AGENTS_DIR/hooks/workflow-state/state-io/session-fields.js")"
export CR_MOD_N BARREL_N RESOLVER_N SESSION_FIELDS_N

BIN_RECORD="$AGENTS_DIR/bin/workflow/record-complexity-evaluation"
BIN_READ="$AGENTS_DIR/bin/workflow/read-complexity-evaluation"
BIN_DERIVE="$AGENTS_DIR/bin/workflow/derive-complexity-level"
BIN_RECORD_SKIP="$AGENTS_DIR/bin/workflow/record-complexity-and-skip"
RUBRIC="$AGENTS_DIR/skills/_shared/judge-task-complexity.md"

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
# rather than assumed. `record-complexity-and-skip` is a bash script while its
# siblings are node ones, and dispatching it through `node` dies on a syntax
# error BEFORE the script's own validation runs — every "it rejected the hostile
# input" / "it refused the unwritable file" assertion downstream would then be
# measuring Node's parser instead of the wrapper (round-7 C4/C6).
d2099_cli_runner() {
    case "$(head -1 "$1" 2>/dev/null)" in
        *node*) echo node ;;
        *bash*|*/sh) echo bash ;;
        *) echo node ;;
    esac
}

# Creates an initialized workflow session ON DISK and echoes its id.
#
# createInitialState() is a PURE constructor (state-io/core.js): it returns an
# in-memory record and writes nothing — persisting is writeState's job. A seeder
# that stopped at createInitialState left NO file, so every case snapshotting the
# state file around a call compared an absent file with an absent file (round-9 C3).
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
#
# `none` is the JUDGE's output-protocol marker for "no signal matched" (detail.md
# D5), not a signal id; the CLIs' zero-signal value is `--signals ""` (detail.md
# items 8/10/11). Passing the literal `none` puts a token outside SIGNAL_IDS on the
# line, which D1 step 5 routes to undecidable_level=HIGH — the exact inversion the
# marker exists to prevent. Every path carrying a judge line into a `--signals`
# argument routes through here. `S0-undecidable` is a real reserved token: never
# translated.
d2099_csv_for_cli() {
    case "$1" in
        none|NONE|None|'') printf '' ;;
        *) printf '%s' "$1" ;;
    esac
}

# --- bounded skill-section extraction ---------------------------------------
# Every cross-module wiring case pulls a command line out of a SKILL.md. An
# unbounded whole-file grep takes the FIRST match ANYWHERE, so an earlier
# example, a stale duplicate reference or unrelated prose naming the same CLI is
# extracted and validated while the required step itself goes unchecked (round-10
# C1). These helpers bound every extraction to the named step's OWN section, and
# d2099_assert_section_cli_unique makes zero-or-duplicate a distinct, named
# failure rather than an arbitrary pick.

# Which step OWNS a given CLI inside a given skill (detail.md P4/P5).
d2099_section_step() {
    case "$1:$2" in
        make-detail-plan:read-complexity-evaluation|make-detail-plan:derive-complexity-level) echo "MDP-3" ;;
        write-tests:read-complexity-evaluation|write-tests:derive-complexity-level) echo "WT-5" ;;
        write-code:read-complexity-evaluation|write-code:derive-complexity-level) echo "WCD-3" ;;
        clarify-intent:record-complexity-and-skip) echo "CI-C1b" ;;
        workflow-init:record-complexity-and-skip) echo "A3a" ;;
        *) echo "" ;;
    esac
}

# `<start regex>|<regex that ENDS the section>` per step id, read off the real
# structure of each SKILL.md: make-detail-plan uses `### Step MDP-n —` headings,
# write-tests/write-code bare `WT-n.` / `WCD-n.` labels at column 0 (their
# sub-steps are indented, so they do not terminate the section), clarify-intent
# `CI-Cn.` labels and workflow-init `- An.` bullets.
d2099_step_anchors() {
    case "$1" in
        MDP-3)  echo '^### Step MDP-3 |^### Step ' ;;
        MDP-4)  echo '^### Step MDP-4 |^### Step ' ;;
        WT-5)   echo '^WT-5\.|^WT-[0-9]' ;;
        WT-6)   echo '^WT-6\.|^WT-[0-9]' ;;
        WCD-3)  echo '^WCD-3\.|^WCD-[0-9]' ;;
        WCD-4)  echo '^WCD-4\.|^WCD-[0-9]' ;;
        CI-C1b) echo '^CI-C1b\.|^CI-C[0-9]' ;;
        A3a)    echo '^- A3a\.|^- A[0-9]' ;;
        *) echo "" ;;
    esac
}

d2099_skill_dir_name() { basename "$(dirname "$1")"; }

# One step's section: its own label line through to (not including) the next
# sibling label. Prints nothing when the anchor matches nothing at all.
d2099_skill_section() {
    local f="$1" step="$2" spec start end
    spec=$(d2099_step_anchors "$step")
    [ -n "$spec" ] || return 0
    start="${spec%%|*}"; end="${spec#*|}"
    awk -v s="$start" -v e="$end" '
        !inside && $0 ~ s { inside = 1; print; next }
        inside && $0 ~ e { exit }
        inside { print }
    ' "$f" 2>/dev/null
}

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
# nothing, zero commands in the section, duplicates in the section. Each is
# reported as itself instead of surfacing later as an empty measurement.
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

CASE_DIR="$(dirname "$0")/feature-2099-complexity-stage-routing"

# shellcheck source=./feature-2099-complexity-stage-routing/derivation-cases.sh
. "$CASE_DIR/derivation-cases.sh"
# shellcheck source=./feature-2099-complexity-stage-routing/validate-table-cases.sh
. "$CASE_DIR/validate-table-cases.sh"
# shellcheck source=./feature-2099-complexity-stage-routing/combination-escalation-cases.sh
. "$CASE_DIR/combination-escalation-cases.sh"
# The routing module's own extracted classifier, exercised directly rather than
# through canonicalizeSignalsForPersistence (its only consumer).
# shellcheck source=./feature-2099-complexity-stage-routing/secret-shape-classifier-cases.sh
. "$CASE_DIR/secret-shape-classifier-cases.sh"
# The per-stage output modes of the derive CLI, and the flag combinations the
# module-level derivation suite above cannot reach.
# shellcheck source=./feature-2099-complexity-stage-routing/derive-cli-output-mode-cases.sh
. "$CASE_DIR/derive-cli-output-mode-cases.sh"
# shellcheck source=./feature-2099-complexity-stage-routing/record-read-cases.sh
. "$CASE_DIR/record-read-cases.sh"
# Sourced after record-read-cases.sh: all three reuse its state-probe helpers.
# shellcheck source=./feature-2099-complexity-stage-routing/record-read-readback-cases.sh
. "$CASE_DIR/record-read-readback-cases.sh"
# shellcheck source=./feature-2099-complexity-stage-routing/record-read-history-cases.sh
. "$CASE_DIR/record-read-history-cases.sh"
# Sourced after them too: the malformed-levels half of the same read path —
# what the projection, the reader and the migration do with a `levels` map that
# is already on disk. Reuses d2099_inject_raw_event and the byte snapshot.
# shellcheck source=./feature-2099-complexity-stage-routing/invalid-levels-atomicity-cases.sh
. "$CASE_DIR/invalid-levels-atomicity-cases.sh"
# shellcheck source=./feature-2099-complexity-stage-routing/writer-api-arg-cases.sh
. "$CASE_DIR/writer-api-arg-cases.sh"
# shellcheck source=./feature-2099-complexity-stage-routing/line-injection-cases.sh
. "$CASE_DIR/line-injection-cases.sh"
# shellcheck source=./feature-2099-complexity-stage-routing/cli-hardening-cases.sh
. "$CASE_DIR/cli-hardening-cases.sh"
# Sourced after it: the H-PERM half of the same hardening axis, split at the
# 500-line HARD limit (rules/coding/file-split.md Pattern A).
# shellcheck source=./feature-2099-complexity-stage-routing/cli-hardening-perm-cases.sh
. "$CASE_DIR/cli-hardening-perm-cases.sh"
# The third member of that axis: a flag passed TWICE, which those two never do.
# shellcheck source=./feature-2099-complexity-stage-routing/cli-duplicate-flag-cases.sh
. "$CASE_DIR/cli-duplicate-flag-cases.sh"
# shellcheck source=./feature-2099-complexity-stage-routing/skip-aggregate-cases.sh
. "$CASE_DIR/skip-aggregate-cases.sh"
# Sourced after it: the same resolver from the SSOT side — that its decision is
# DELEGATED to isZeroSignalLow, not re-implemented beside it. Reuses d2099s_resolve.
# shellcheck source=./feature-2099-complexity-stage-routing/skip-delegation-cases.sh
. "$CASE_DIR/skip-delegation-cases.sh"
# Sourced after both: the same skip decision seen from the WRAPPER's argv — the
# --so-c1/--so-c2 override that outranks whatever those two resolve.
# shellcheck source=./feature-2099-complexity-stage-routing/skip-boolean-guard-cases.sh
. "$CASE_DIR/skip-boolean-guard-cases.sh"
# shellcheck source=./feature-2099-complexity-stage-routing/traversal-attack-cases.sh
. "$CASE_DIR/traversal-attack-cases.sh"
# Sourced after it: the same paths-as-input axis from the other side — valid
# directory names that merely LOOK hostile. Reuses its snapshot + canary tree.
# shellcheck source=./feature-2099-complexity-stage-routing/path-charset-cases.sh
. "$CASE_DIR/path-charset-cases.sh"
# Sourced after both: the third member of the paths-as-input axis — the only
# #2099 argument that names a FILE, and so the only one whose value decides which
# bytes are read. Reuses d2099t_snapshot and the canary-tree convention.
# shellcheck source=./feature-2099-complexity-stage-routing/signals-file-security-cases.sh
. "$CASE_DIR/signals-file-security-cases.sh"
# The other #2099 CLI change: review-plan-codex's plan-truncation threshold,
# exercised as a real subprocess against a stubbed codex.
# shellcheck source=./feature-2099-complexity-stage-routing/review-plan-codex-threshold-cases.sh
. "$CASE_DIR/review-plan-codex-threshold-cases.sh"
# shellcheck source=./feature-2099-complexity-stage-routing/rubric-table-consistency.sh
. "$CASE_DIR/rubric-table-consistency.sh"
# shellcheck source=./feature-2099-complexity-stage-routing/fail-open-cases.sh
. "$CASE_DIR/fail-open-cases.sh"
# shellcheck source=./feature-2099-complexity-stage-routing/consumers-static.sh
. "$CASE_DIR/consumers-static.sh"
# shellcheck source=./feature-2099-complexity-stage-routing/consumer-dispatch-cases.sh
. "$CASE_DIR/consumer-dispatch-cases.sh"
# shellcheck source=./feature-2099-complexity-stage-routing/consumer-orchestration-cases.sh
. "$CASE_DIR/consumer-orchestration-cases.sh"
# Sourced after it: reuses its command-extraction and model-mapping helpers.
# shellcheck source=./feature-2099-complexity-stage-routing/consumer-fallback-cases.sh
. "$CASE_DIR/consumer-fallback-cases.sh"
# The other half of what each consumer reads: the `signals=` line, and where it
# is forwarded to. Reuses the orchestration helpers, so it follows them.
# shellcheck source=./feature-2099-complexity-stage-routing/consumer-signal-forwarding-cases.sh
. "$CASE_DIR/consumer-signal-forwarding-cases.sh"
# Same forwarding question on the NONE fallback leg, where the list travels by
# per-stage FILE instead of by a reader's signals= line. Uses d2099sf_read above.
# shellcheck source=./feature-2099-complexity-stage-routing/consumer-fallback-forwarding-cases.sh
. "$CASE_DIR/consumer-fallback-forwarding-cases.sh"
# shellcheck source=./feature-2099-complexity-stage-routing/producer-orchestration-cases.sh
. "$CASE_DIR/producer-orchestration-cases.sh"
# shellcheck source=./feature-2099-complexity-stage-routing/legacy-record-cases.sh
. "$CASE_DIR/legacy-record-cases.sh"
# shellcheck source=./feature-2099-complexity-stage-routing/prompt-injection-cases.sh
. "$CASE_DIR/prompt-injection-cases.sh"
# shellcheck source=./feature-2099-complexity-stage-routing/judge-threshold-live-cases.sh
. "$CASE_DIR/judge-threshold-live-cases.sh"
# The next two reuse every d2099j_* helper defined above, so they follow it.
# shellcheck source=./feature-2099-complexity-stage-routing/judge-boundary-live-cases.sh
. "$CASE_DIR/judge-boundary-live-cases.sh"
# live-e2e also needs the producer and consumer helpers sourced further up.
# shellcheck source=./feature-2099-complexity-stage-routing/live-e2e-cases.sh
. "$CASE_DIR/live-e2e-cases.sh"
# Sourced last: it re-sources the two live case files inside a harness.
# shellcheck source=./feature-2099-complexity-stage-routing/tl3-gate-cases.sh
. "$CASE_DIR/tl3-gate-cases.sh"

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
