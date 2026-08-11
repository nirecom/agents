# shellcheck shell=bash
# Tests: hooks/workflow-state/state-io/core.js, bin/workflow/lib/next-step/steps.js, hooks/workflow-gate.js
# Tags: TL2, workflow, write-code, next-step, scope:issue-specific, pwsh-not-required
#
# Shared helpers + fixture builders for the feature-1665-write-code-step dispatcher.
# Sourced by tests/feature-1665-write-code-step.sh and by the case-group files
# in this folder. Owns nothing assertion-side; every case lives in a-*.sh .. e-*.sh.

PASS=0
FAIL=0

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
  else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then pass "$desc"
  else fail "$desc -- expected [$expected] got [$actual]"; fi
}

check_contains() {
  local desc="$1" needle="$2" hay="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then pass "$desc"
  else fail "$desc -- expected [$needle] in: $hay"; fi
}

check_not_contains() {
  local desc="$1" needle="$2" hay="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then fail "$desc -- did NOT expect [$needle] in: $hay"
  else pass "$desc"; fi
}

# The 16-step vocabulary this issue introduces: write_code sits between
# review_tests and run_tests. Fixtures are built from THIS list on purpose — a
# fixture that enumerates the old 15 steps could never observe the new one.
STEPS_16="workflow_init clarify_intent research outline detail branching_complete write_tests review_tests write_code run_tests review_security docs user_verification cleanup pre_final_report_gate final_report"

# build_state <sid> <default-status> <overrides> [extra-top-level-json-prefix]
#   overrides: "step=status;step=status"; the pseudo-status `absent` omits the
#   key entirely (projection then defaults it to pending — that is the legacy
#   state-file shape c-legacy-state.sh depends on).
build_state() {
  local sid="$1" def="$2" ov="${3:-}" extra="${4:-}"
  local entries="" s st pair
  for s in $STEPS_16; do
    st="$def"
    for pair in ${ov//;/ }; do
      case "$pair" in "$s="*) st="${pair#*=}" ;; esac
    done
    [ "$st" = "absent" ] && continue
    entries="$entries,\"$s\":{\"status\":\"$st\"}"
  done
  entries="${entries#,}"
  printf '{%s"steps":{%s},"closes_issues":[1665]}' "$extra" "$entries" > "$WORKFLOW_DIR/${sid}.json"
}

# stamp_step_at <sid> <step> — give one already-built step entry an explicit
# `updated_at`.
#
# WHY a fixture needs this: build_state writes v1 entries with no timestamp, and
# the v1->v2 migration DROPS a `pending` entry that carries neither a timestamp
# nor an annotation — such an entry says nothing beyond the projection default.
# The dropped step is then indistinguishable from one whose writer never knew the
# step existed, which is exactly what the v2->v3 backfill (#1665) treats as a
# legacy gap. A fixture that means "this session genuinely recorded the step as
# pending" must therefore stamp it, so the migration keeps it and emits a real
# step_status event.
stamp_step_at() {
  local sid="$1" step="$2"
  STAMP_SID="$sid" STAMP_STEP="$step" run_with_timeout node -e '
const fs = require("fs"), path = require("path");
const p = path.join(process.env.CLAUDE_WORKFLOW_DIR, process.env.STAMP_SID + ".json");
const st = JSON.parse(fs.readFileSync(p, "utf8"));
st.steps[process.env.STAMP_STEP].updated_at = "2026-01-01T12:00:00.000Z";
fs.writeFileSync(p, JSON.stringify(st));
' 2>&1
}

run_next_step() { run_with_timeout node "$NEXT_STEP_N" "$@"; }

# Real PreToolUse payload for a sentinel `echo` Bash call, routed through the
# real workflow-mark hook (the only writer of RESET_FROM / MARK_STEP sentinels).
run_mark_hook() {
  local sid="$1" cmd="$2" esc
  esc=${cmd//\\/\\\\}
  esc=${esc//\"/\\\"}
  printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$sid" "$esc" \
    | run_with_timeout node "$WORKFLOW_MARK_N" 2>&1 || true
}

# Real PreToolUse payload for `git -C <repo> commit`. `-C` is Tier 1 of
# resolveRepoDir, so the gate judges the fixture repo deterministically.
run_gate_commit() {
  local sid="$1" repo="$2"
  printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"x\\"","cwd":"%s"}}' \
    "$sid" "$repo" "$repo" \
    | run_with_timeout node "$GATE_HOOK_N" 2>/dev/null || true
}

# Projected status of one step, read through the real readState() projection.
# Reuses the #1644 read-only probe (CPR-SSOT: one fixture-state reader).
step_field() {
  PROBE_SID="$1" PROBE_STEP="$2" PROBE_FIELD="$3" \
    run_with_timeout node "$PROBE_N" field 2>/dev/null || echo "PROBE_FAIL"
}
