#!/usr/bin/env bash
# Tests: hooks/workflow-state/state-io/events.js, hooks/workflow-state/record-step-verdict.js, hooks/workflow-state/effective-state.js, hooks/workflow-state/lifecycle.js, hooks/workflow-mark/mark-step-handler.js, bin/workflow/lib/next-step/advance-shared.js
# Tags: tl2, workflow, provenance, audit, effective-state, door-parity, scope:issue-specific, pwsh-not-required

# INV-3 (#2102): migrating a door changes the AUDIT pair it records -- sentinel writes
# observed/mark-step, the CLI writes declared/next-step-advance -- while the projected
# effective state must stay identical. Both values must remain GENUINE_PROVENANCE, read
# from events.js rather than retyped, so a future value rename cannot pass silently.

# TL3 gap (what this test does NOT catch): whether downstream consumers of the audit pair
# (report rendering, supervisor review) present the migrated origin correctly in a live
# session. Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight,
# bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not available"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
AGENTS_DIR_N="$(nrm "$AGENTS_DIR")"
NS="$AGENTS_DIR_N/bin/workflow/next-step"
MARK_HOOK="$AGENTS_DIR_N/hooks/workflow-mark.js"
PROBE="$AGENTS_DIR_N/tests/feature-1644-advance-transaction/state-probe.js"
WFSTATE_MODULE="$AGENTS_DIR_N/hooks/workflow-state"; export WFSTATE_MODULE
EVENTS_MOD="$AGENTS_DIR_N/hooks/workflow-state/state-io/events.js"; export EVENTS_MOD
RSV_MOD="$AGENTS_DIR_N/hooks/workflow-state/record-step-verdict.js"; export RSV_MOD
LIFECYCLE_MOD="$AGENTS_DIR_N/hooks/workflow-state/lifecycle.js"; export LIFECYCLE_MOD

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
WORKFLOW_DIR="$TMPDIR_BASE/wf"; PLANS_DIR="$TMPDIR_BASE/plans"; NEUTRAL="$TMPDIR_BASE/neutral"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR" "$NEUTRAL"
CLAUDE_WORKFLOW_DIR="$(nrm "$WORKFLOW_DIR")"; export CLAUDE_WORKFLOW_DIR
WORKFLOW_PLANS_DIR="$(nrm "$PLANS_DIR")"; export WORKFLOW_PLANS_DIR
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
CONFIG_EMPTY="$TMPDIR_BASE/cfg"; mkdir -p "$CONFIG_EMPTY"; : > "$CONFIG_EMPTY/.env"
AGENTS_CONFIG_DIR="$(nrm "$CONFIG_EMPTY")"; export AGENTS_CONFIG_DIR

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -- expected [$2] got [$3]"; fi; }
check_contains() {
  case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 -- expected [$2] in: $3" ;; esac
}
check_not_contains() {
  case "$3" in *"$2"*) fail "$1 -- did NOT expect [$2] in: $3" ;; *) pass "$1" ;; esac
}
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
  else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

MAIN="$TMPDIR_BASE/main"; LINKED="$TMPDIR_BASE/linked"
git init -q "$MAIN" >/dev/null 2>&1
git -C "$MAIN" config core.hooksPath /dev/null
git -C "$MAIN" config user.email "t@example.com"
git -C "$MAIN" config user.name "t"
printf 'seed\n' > "$MAIN/README.md"
git -C "$MAIN" add README.md >/dev/null 2>&1
git -C "$MAIN" commit -qm seed >/dev/null 2>&1
git -C "$MAIN" worktree add -q -b wt2102p "$LINKED" >/dev/null 2>&1
git -C "$LINKED" config core.hooksPath /dev/null
mkdir -p "$LINKED/tests"
printf '# fixture test\n' > "$LINKED/tests/fixture-2102.sh"
git -C "$LINKED" add tests/ >/dev/null 2>&1
LINKED_N="$(nrm "$LINKED")"
CLAUDE_PROJECT_DIR="$(nrm "$MAIN")"; export CLAUDE_PROJECT_DIR

STEPS_ALL="workflow_init clarify_intent research outline detail branching_complete write_tests review_tests write_code run_tests review_security docs user_verification cleanup pre_final_report_gate final_report"
# A session parked ON $2: every earlier step complete, it and everything after pending.
mk_state_at() {
  local sid="$1" upto="$2" json='{"steps":{' first=1 s st done=1
  for s in $STEPS_ALL; do
    [ "$s" = "$upto" ] && done=0
    st="pending"; [ $done -eq 1 ] && st="complete"
    [ $first -eq 1 ] || json="$json,"; first=0
    json="$json\"$s\":{\"status\":\"$st\"}"
  done
  printf '%s' "$json},\"closes_issues\":[2102]}" > "$WORKFLOW_DIR/${sid}.json"
}
at_write_tests() { mk_state_at "$1" write_tests; }
at_research() { mk_state_at "$1" research; }
last_event() {
  PROBE_SID="$1" PROBE_STEP="$2" run_with_timeout node "$PROBE" lastevent 2>/dev/null || echo "PROBE_FAIL"
}
ev_field() {
  PROBE_SID="$1" PROBE_STEP="$2" FIELD="$3" run_with_timeout node -e '
    const fs = require("fs"), path = require("path");
    const p = path.join(process.env.CLAUDE_WORKFLOW_DIR, process.env.PROBE_SID + ".json");
    const raw = JSON.parse(fs.readFileSync(p, "utf8"));
    const evs = (raw.events || []).filter(
      (e) => e.kind === "step_status" && e.step === process.env.PROBE_STEP);
    const last = evs.length ? evs[evs.length - 1] : null;
    process.stdout.write(last ? String(last[process.env.FIELD]) : "NONE");
  ' 2>/dev/null || echo "PROBE_FAIL"
}

# --- doors ------------------------------------------------------------------
ERRF="$TMPDIR_BASE/err.txt"
at_write_tests p_cli
(cd "$LINKED" && run_with_timeout node "$NS" --session p_cli --advance --step write_tests --complete >/dev/null 2>"$ERRF")
CLI_RC=$?
at_write_tests p_sent
SID=p_sent ICWD="$LINKED_N" node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"echo \"<<WORKFLOW_MARK_STEP_write_tests_complete>>\""},tool_response:{exit_code:0},session_id:process.env.SID,cwd:process.env.ICWD}))' > "$TMPDIR_BASE/payload.json"
(cd "$NEUTRAL" && run_with_timeout node "$MARK_HOOK" < "$TMPDIR_BASE/payload.json" >/dev/null 2>&1)
SENT_RC=$?

echo "=== P1: both doors record the completion ==="
check "P1a: the CLI door exits 0" 0 "$CLI_RC"
check "P1b: the sentinel door exits 0" 0 "$SENT_RC"

echo ""
echo "=== P2: the audit pair each door writes ==="
check "P2a: sentinel provenance is observed" "observed" "$(ev_field p_sent write_tests provenance)"
check "P2b: sentinel origin is mark-step" "mark-step" "$(ev_field p_sent write_tests origin)"
check "P2c: CLI provenance is declared" "declared" "$(ev_field p_cli write_tests provenance)"
# The origin string is owned by ADVANCE_ORIGINS, keyed by the CLI's own binary name.
# Reading it back from the module keeps this pin honest if the mapping is renamed.
EXPECTED_ORIGIN="$(run_with_timeout node -e '
  const m = require(process.env.RSV_MOD);
  process.stdout.write(String((m.ADVANCE_ORIGINS || {})["next-step"]));' 2>/dev/null || echo "MODULE_LOAD_FAILED")"
check "P2d: CLI origin is ADVANCE_ORIGINS[next-step]" "$EXPECTED_ORIGIN" "$(ev_field p_cli write_tests origin)"
check "P2e: that mapping is the expected spelling" "next-step-advance" "$EXPECTED_ORIGIN"
check_contains "P2f: the probe's lastevent view agrees for the CLI door" \
  "\"provenance\":\"declared\"" "$(last_event p_cli write_tests)"
check_contains "P2g: the probe's lastevent view agrees for the sentinel door" \
  "\"provenance\":\"observed\"" "$(last_event p_sent write_tests)"

echo ""
echo "=== P3: both provenance values stay inside GENUINE_PROVENANCE ==="
# Read from events.js (SSOT), never retyped: the assertion must break when the
# allow-list changes, not silently keep testing a stale literal.
GP="$(run_with_timeout node -e '
  const m = require(process.env.EVENTS_MOD);
  process.stdout.write((m.GENUINE_PROVENANCE || []).join(","));' 2>/dev/null || echo "MODULE_LOAD_FAILED")"
check_contains "P3a: GENUINE_PROVENANCE carries the sentinel door's value" \
  "$(ev_field p_sent write_tests provenance)" "$GP"
check_contains "P3b: GENUINE_PROVENANCE carries the CLI door's value" \
  "$(ev_field p_cli write_tests provenance)" "$GP"
check_not_contains "P3c: GENUINE_PROVENANCE excludes backfilled (the list is a real filter)" \
  "backfilled" "$GP"
check_contains "P3d: PROVENANCE_VALUES still carries backfilled (P3c is not vacuous)" \
  "backfilled" "$(run_with_timeout node -e '
    const m = require(process.env.EVENTS_MOD);
    process.stdout.write((m.PROVENANCE_VALUES || []).join(","));' 2>/dev/null || echo "MODULE_LOAD_FAILED")"

echo ""
echo "=== P4: the projected effective state is door-independent ==="
# The audit pair differs by design; the state a consumer reads must not. Compared as
# the full per-step status map so a divergence anywhere in the walk is visible.
eff_state() {
  PROBE_SID="$1" run_with_timeout node -e '
    const wf = require(process.env.WFSTATE_MODULE);
    const sid = process.env.PROBE_SID;
    const state = wf.readState(sid);
    const snap = wf.reconcileEffectiveState(state, sid, { isWfMeta: false });
    const steps = (snap && snap.steps) || {};
    process.stdout.write(wf.VALID_STEPS.map(
      (s) => s + "=" + ((steps[s] || {}).status || "pending")).join(";"));
  ' 2>/dev/null || echo "PROBE_FAIL"
}
EFF_CLI="$(eff_state p_cli)"; EFF_SENT="$(eff_state p_sent)"
check_contains "P4a: the effective snapshot is readable" "write_tests=complete" "$EFF_CLI"
check "P4b: both doors project the identical effective state" "$EFF_SENT" "$EFF_CLI"

echo ""
echo "=== P5: lifecycle adoption is NOT door-independent (pinned, not fixed) ==="
# hasSelfRecordedStepSettlement adopts only ADOPTION_ORIGINS; `next-step-advance` is
# not among them, so a session that completed via the CLI door reads as "not started".
# Pinned as observed behaviour: #2102 migrates the door, not the adoption list.
ADOPT="$(run_with_timeout node -e '
  const m = require(process.env.LIFECYCLE_MOD);
  process.stdout.write((m.ADOPTION_ORIGINS || ["<unexported>"]).join(","));' 2>/dev/null || echo "MODULE_LOAD_FAILED")"
started() {
  PROBE_SID="$1" run_with_timeout node -e '
    const wf = require(process.env.WFSTATE_MODULE);
    process.stdout.write(String(wf.isWorkflowStarted(process.env.PROBE_SID) === true));
  ' 2>/dev/null || echo "PROBE_FAIL"
}
check "P5a: the sentinel door's origin makes the session read as started" "true" "$(started p_sent)"
check "P5b: the CLI door's origin does not" "false" "$(started p_cli)"
check_contains "P5c: mark-step is on the adoption list" "mark-step" "$ADOPT"
check_not_contains "P5d: next-step-advance is not (the cause of P5b)" "next-step-advance" "$ADOPT"

echo ""
echo "=== P6: the same audit and parity properties for the RESEARCH door pair ==="
# P1-P4 all target write_tests, so a research-specific migration regression -- research
# is the second door #2102 migrates -- would be invisible. P5 is deliberately excluded:
# the adoption asymmetry it pins is a property of ADOPTION_ORIGINS, not of the step, and
# is already recorded as pinned-not-fixed.
at_research p_cli_r
(cd "$LINKED" && run_with_timeout node "$NS" --session p_cli_r --advance --step research --complete >/dev/null 2>"$ERRF")
CLI_RC_R=$?
at_research p_sent_r
SID=p_sent_r ICWD="$LINKED_N" node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"echo \"<<WORKFLOW_MARK_STEP_research_complete>>\""},tool_response:{exit_code:0},session_id:process.env.SID,cwd:process.env.ICWD}))' > "$TMPDIR_BASE/payload-r.json"
(cd "$NEUTRAL" && run_with_timeout node "$MARK_HOOK" < "$TMPDIR_BASE/payload-r.json" >/dev/null 2>&1)
SENT_RC_R=$?
check "P6a: the research CLI door exits 0" 0 "$CLI_RC_R"
check "P6b: the research sentinel door exits 0" 0 "$SENT_RC_R"
check "P6c: sentinel provenance is observed" "observed" "$(ev_field p_sent_r research provenance)"
check "P6d: sentinel origin is mark-step" "mark-step" "$(ev_field p_sent_r research origin)"
check "P6e: CLI provenance is declared" "declared" "$(ev_field p_cli_r research provenance)"
check "P6f: CLI origin is ADVANCE_ORIGINS[next-step]" "$EXPECTED_ORIGIN" "$(ev_field p_cli_r research origin)"
check_contains "P6g: GENUINE_PROVENANCE carries the research sentinel value" \
  "$(ev_field p_sent_r research provenance)" "$GP"
check_contains "P6h: GENUINE_PROVENANCE carries the research CLI value" \
  "$(ev_field p_cli_r research provenance)" "$GP"
EFF_CLI_R="$(eff_state p_cli_r)"; EFF_SENT_R="$(eff_state p_sent_r)"
check_contains "P6i: the research effective snapshot is readable" "research=complete" "$EFF_CLI_R"
check "P6j: both research doors project the identical effective state" "$EFF_SENT_R" "$EFF_CLI_R"
# Settling research must not drag a later step with it -- otherwise P6j would hold for a
# build that simply completed everything.
check_contains "P6k: the research pair leaves write_tests pending" "write_tests=pending" "$EFF_CLI_R"

echo ""
echo "=== P7: the two doors driven against the SAME session, both orderings ==="
# P1-P6 use disjoint session ids per door, but the PR's stated design is coexistence
# ("sentinel dispatch remains a hook-level recovery fallback") -- so a live session can
# see either order. P7a is sentinel-then-CLI (CLI is the advance gate and short-circuits
# on an identical repeat -- see idempotency.sh I1). P7b is CLI-then-sentinel (the
# sentinel gate never short-circuits -- I2 -- so it re-writes over the CLI's own record).
run_sentinel_step() {
  local sid="$1" step="$2"
  SID="$sid" STEP="$step" ICWD="$LINKED_N" node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"echo \"<<WORKFLOW_MARK_STEP_"+process.env.STEP+"_complete>>\""},tool_response:{exit_code:0},session_id:process.env.SID,cwd:process.env.ICWD}))' \
    > "$TMPDIR_BASE/payload-p7.json"
  (cd "$NEUTRAL" && run_with_timeout node "$MARK_HOOK" < "$TMPDIR_BASE/payload-p7.json" >"$TMPDIR_BASE/sentinel-p7-out.txt" 2>&1)
}
run_cli_step() {
  local sid="$1" step="$2"
  (cd "$LINKED" && run_with_timeout node "$NS" --session "$sid" --advance --step "$step" --complete >"$TMPDIR_BASE/cli-p7-out.txt" 2>&1)
}

echo "--- P7a: sentinel completes write_tests, then the CLI door is re-issued ---"
at_write_tests p7a
run_sentinel_step p7a write_tests
SENTINEL_P7A_RC=$?
check "P7a: the sentinel hook call itself exits 0" 0 "$SENTINEL_P7A_RC"
check "P7a: after the sentinel call, provenance is observed" "observed" "$(ev_field p7a write_tests provenance)"
check "P7a: after the sentinel call, origin is mark-step" "mark-step" "$(ev_field p7a write_tests origin)"
run_cli_step p7a write_tests
CLI_P7A_RC=$?
CLI_P7A_OUT="$(cat "$TMPDIR_BASE/cli-p7-out.txt" 2>/dev/null)"
check "P7a: the CLI re-issue itself exits 0 (not a crash/refusal masquerading as a no-op)" 0 "$CLI_P7A_RC"
check_contains "P7a: the CLI re-issue's own output proves it actually ran and short-circuited" "already=true" "$CLI_P7A_OUT"
check_contains "P7a: the CLI re-issue reports the expected step/status pair" "ADVANCED=write_tests status=complete" "$CLI_P7A_OUT"
P7A_EVCOUNT="$(PROBE_SID=p7a PROBE_STEP=write_tests PROBE_FIELD=step_status run_with_timeout node "$PROBE" eventcount 2>/dev/null || echo "PROBE_FAIL")"
check "P7a: exactly one step_status event survives (the CLI repeat appended nothing)" 1 "$P7A_EVCOUNT"
check "P7a: the audit trail keeps the sentinel's pair -- provenance stays observed" \
  "observed" "$(ev_field p7a write_tests provenance)"
check "P7a: the audit trail keeps the sentinel's pair -- origin stays mark-step" \
  "mark-step" "$(ev_field p7a write_tests origin)"

echo ""
echo "--- P7b: CLI completes write_tests, then the sentinel fallback fires ---"
at_write_tests p7b
run_cli_step p7b write_tests
CLI_P7B_RC=$?
check "P7b: the initial CLI call itself exits 0" 0 "$CLI_P7B_RC"
check "P7b: after the CLI call, provenance is declared" "declared" "$(ev_field p7b write_tests provenance)"
check "P7b: after the CLI call, origin is ADVANCE_ORIGINS[next-step]" "$EXPECTED_ORIGIN" "$(ev_field p7b write_tests origin)"
STARTED_BEFORE="$(started p7b)"
check "P7b: before the sentinel fires, isWorkflowStarted is false (next-step-advance is not on ADOPTION_ORIGINS)" \
  "false" "$STARTED_BEFORE"
run_sentinel_step p7b write_tests
SENTINEL_P7B_RC=$?
check "P7b: the sentinel fallback hook call itself exits 0" 0 "$SENTINEL_P7B_RC"
P7B_EVCOUNT="$(PROBE_SID=p7b PROBE_STEP=write_tests PROBE_FIELD=step_status run_with_timeout node "$PROBE" eventcount 2>/dev/null || echo "PROBE_FAIL")"
check "P7b: the sentinel fallback DOES append a second step_status event (sentinel gate never short-circuits)" \
  2 "$P7B_EVCOUNT"
check "P7b: the last event's provenance flips declared -> observed" "observed" "$(ev_field p7b write_tests provenance)"
check "P7b: the last event's origin flips next-step-advance -> mark-step" "mark-step" "$(ev_field p7b write_tests origin)"
check "P7b: isWorkflowStarted flips false -> true once the sentinel's origin lands (P5 asymmetry made observable)" \
  "true" "$(started p7b)"
check_contains "P7b: the projected status is still complete either way" "write_tests=complete" "$(eff_state p7b)"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
