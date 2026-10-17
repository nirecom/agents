# shellcheck shell=bash
# tests/bin/feature-2431-run-tests-baseline/cli-accept.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, cli, accept, scope:issue-specific, pwsh-not-required, TL2
# Sourced by the dispatcher; never run standalone.
# #2517: step 0 of bin/run-tests-baseline consumes the user's grant (baseline_accept) through
# `run-tests-baseline-evidence accept`. A valid grant completes run_tests without running the base
# again (`BASELINE_ACCEPTED: kind=<kind>`, exit 0); without one, every earlier verdict is unchanged.

# isolation (#2512): re-pin to helpers.sh's private dirs (a sibling's pin is invisible to the scanner).
: "${WF_DIR:?helpers.sh must be sourced first}" "${PLANS_DIR:?helpers.sh must be sourced first}"
export WORKFLOW_STATE_DIR="$(np "$WF_DIR")" WORKFLOW_PLANS_DIR="$(np "$PLANS_DIR")"
declare -F harness_assert_isolated >/dev/null || . "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
harness_assert_isolated

CA_FORM="WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED"

# ca-grant.js <agents> <sid> <kind> — the annotation the workflow-mark handler writes, bound to
# the run as it stands now (updated_seq, outcome_source, run_outcome).
cat >"$TMPROOT/ca-grant.js" <<'EOF'
"use strict";
const [agents, sid, kind] = process.argv.slice(2);
const S = require(agents + "/hooks/workflow-state");
const e = S.readState(sid).steps.run_tests;
require(agents + "/hooks/workflow-state/state-io/events").appendEvents(sid, [{
  kind: "step_annotation", step: "run_tests", key: "baseline_accept", provenance: "declared",
  origin: "workflow-mark-run-tests-baseline-accept",
  value: { reason: "fails on main too", kind, run_seq: e.updated_seq,
    outcome_source: e.outcome_source === undefined ? null : e.outcome_source, accepted_run_outcome: e.run_outcome },
}]);
process.stdout.write("ok");
EOF

# ca-nolist.js <agents> <sid> — a failing run that recorded no failing list (the exit-3 entry).
cat >"$TMPROOT/ca-nolist.js" <<'EOF'
"use strict";
const [agents, sid] = process.argv.slice(2);
const ev = (o) => Object.assign({ step: "run_tests", provenance: "observed", origin: "run-tests-hook" }, o);
require(agents + "/hooks/workflow-state/state-io/events").appendEvents(sid, [
  ev({ kind: "step_status", status: "pending" }),
  ev({ kind: "step_annotation", key: "run_outcome", value: "fail" }),
  ev({ kind: "step_annotation", key: "unrunnable_count", value: 0 }),
]);
process.stdout.write("ok");
EOF

# ca-mark-payload.js <command> <sid> <cwd> — the PostToolUse payload workflow-mark.js reads (as
# tests/hooks/feature-2517-run-tests-baseline-accept/_lib.sh builds it).
cat >"$TMPROOT/ca-mark-payload.js" <<'EOF'
"use strict";
const [command, sid, cwd] = process.argv.slice(2);
process.stdout.write(JSON.stringify({ tool_name: "Bash", session_id: sid, transcript_path: null,
  tool_input: { command, cwd }, tool_response: { exit_code: 0, stdout: "" } }));
EOF

ca_grant() { run_with_timeout 20 node "$(np "$TMPROOT/ca-grant.js")" "$AGENTS_WIN" "$1" "$2" 2>/dev/null; }
# ca_mark <sid> <cwd> <reason> — the user's sentinel through the real workflow-mark.js hook.
ca_mark() {
  node "$(np "$TMPROOT/ca-mark-payload.js")" "echo \"<<$CA_FORM: $3>>\"" "$1" "$(np "$2")" >"$TMPROOT/ca-mark-in.json"
  run_with_timeout 30 node "$AGENTS_WIN/hooks/workflow-mark.js" <"$TMPROOT/ca-mark-in.json" 2>&1 | tr -d '\r'
}
ca_has() { printf '%s\n' "$RTB_CLI_OUT" | grep -qE -- "$1"; }
ca_ck() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — want=[$2] got=[$3]"; fi; }

run_cli_accept_cases() {
  if [ ! -f "$BASELINE_CLI" ]; then
    fail "CA: bin/run-tests-baseline not found"
    return
  fi
  local repo="$TMPROOT/repo-accept" t_skip="tests/bin/test-skip.sh" t_brk="tests/bin/test-broken.sh"
  local ran="$TMPROOT/accept-base-ran" sid
  mk_fixture_repo "$repo" >/dev/null
  # The base copy of the skip test leaves a file when it runs, so a base re-run is observable.
  git -C "$repo" checkout -q main
  printf '#!/usr/bin/env bash\ntouch "%s"\nexit 77\n' "$(np "$ran")" > "$repo/$t_skip"
  git -C "$repo" add "$t_skip"
  git -C "$repo" commit -q -m "skip test with run sentinel"
  git -C "$repo" checkout -q feature
  git -C "$repo" merge -q --no-edit main

  # ---- CA1: no grant — undetermined stays exit 1, exactly as before ----
  sid="ca-u-$$"
  seed_failing "$sid" "$t_skip"
  rtb_cli_run "$(cli_case_cache ca1)" "$repo" "$sid"
  ca_ck "CA1: without a grant, undetermined exits 1" "1" "$RTB_CLI_RC"
  [ -e "$ran" ] && pass "CA1: control — the base ran" || fail "CA1: control — the base did not run"
  ca_has '^BASELINE_ACCEPTED' && fail "CA1: BASELINE_ACCEPTED printed without a grant" \
    || pass "CA1: no BASELINE_ACCEPTED without a grant"
  ca_has "$CA_FORM" && pass "CA1: the undetermined verdict points at $CA_FORM" \
    || fail "CA1: no $CA_FORM guidance on an undetermined-only exit 1 ($(cli_baseline_lines))"

  # ---- CA2: grant seeded — the re-run consumes it and never touches the base ----
  rm -f "$ran"
  ca_ck "CA2: fixture — grant seeded" "ok" "$(ca_grant "$sid" undetermined)"
  rtb_cli_run "$(cli_case_cache ca2)" "$repo" "$sid"
  ca_ck "CA2: grant consumed, exit 0" "0" "$RTB_CLI_RC"
  ca_has '^BASELINE_ACCEPTED: kind=undetermined$' && pass "CA2: BASELINE_ACCEPTED: kind=undetermined" \
    || fail "CA2: no BASELINE_ACCEPTED: kind=undetermined line (out: $RTB_CLI_OUT)"
  ca_has '^BASELINE_SUMMARY' && fail "CA2: the base was classified again (BASELINE_SUMMARY)" \
    || pass "CA2: no new classification"
  [ -e "$ran" ] && fail "CA2: the base test ran again" || pass "CA2: the base test did not run"
  ca_ck "CA2: run_tests complete" '"complete"' "$(read_step_field "$sid" run_tests status)"
  ca_ck "CA2: completion_basis" '"baseline-user-accepted"' "$(read_step_field "$sid" run_tests completion_basis)"

  # ---- CA3: no failing list — exit 3 names the sentinel; a grant completes it ----
  sid="ca-nl-$$"
  ca_ck "CA3: fixture — list-less failing run" "ok" \
    "$(run_with_timeout 20 node "$(np "$TMPROOT/ca-nolist.js")" "$AGENTS_WIN" "$sid" 2>/dev/null)"
  rtb_cli_run "$(cli_case_cache ca3)" "$repo" "$sid"
  ca_ck "CA3: without a grant, exit 3" "3" "$RTB_CLI_RC"
  ca_has "$CA_FORM" && pass "CA3: exit 3 points at $CA_FORM" \
    || fail "CA3: no $CA_FORM guidance on exit 3 (out: $RTB_CLI_OUT)"
  ca_ck "CA3: fixture — grant seeded" "ok" "$(ca_grant "$sid" failing-list-unrecorded)"
  rtb_cli_run "$(cli_case_cache ca3b)" "$repo" "$sid"
  ca_ck "CA3: with a grant, exit 0" "0" "$RTB_CLI_RC"
  ca_has '^BASELINE_ACCEPTED: kind=failing-list-unrecorded$' \
    && pass "CA3: BASELINE_ACCEPTED: kind=failing-list-unrecorded" \
    || fail "CA3: no BASELINE_ACCEPTED: kind=failing-list-unrecorded line (out: $RTB_CLI_OUT)"
  ca_ck "CA3: run_tests complete" '"complete"' "$(read_step_field "$sid" run_tests status)"

  # ---- CA4: broken — a grant (however it got there) never completes the run ----
  sid="ca-b-$$"
  seed_failing "$sid" "$t_brk"
  rtb_cli_run "$(cli_case_cache ca4)" "$repo" "$sid"
  ca_ck "CA4: control — broken exits 1" "1" "$RTB_CLI_RC"
  ca_ck "CA4: fixture — grant seeded" "ok" "$(ca_grant "$sid" undetermined)"
  rtb_cli_run "$(cli_case_cache ca4b)" "$repo" "$sid"
  ca_ck "CA4: broken with a grant still exits 1" "1" "$RTB_CLI_RC"
  ca_has '^BASELINE_ACCEPTED' && fail "CA4: BASELINE_ACCEPTED printed for a broken run" \
    || pass "CA4: no BASELINE_ACCEPTED for a broken run"
  ca_ck "CA4: run_tests stays pending" '"pending"' "$(read_step_field "$sid" run_tests status)"
  ca_ck "CA4: no completion_basis" "(absent)" "$(read_step_field "$sid" run_tests completion_basis)"

  # ---- CA5: wiring — the real sentinel through workflow-mark.js, then the CLI consumes it ----
  sid="ca-w-$$"
  seed_failing "$sid" "$t_skip"
  rtb_cli_run "$(cli_case_cache ca5)" "$repo" "$sid"
  ca_ck "CA5: control — undetermined exits 1 before the sentinel" "1" "$RTB_CLI_RC"
  ca_mark "$sid" "$repo" "these fail on main too" >/dev/null
  ca_ck "CA5: the hook recorded the grant" '"undetermined"' \
    "$(read_step_field "$sid" run_tests baseline_accept | sed -n 's/.*"kind":\("[^"]*"\).*/\1/p')"
  rm -f "$ran"
  rtb_cli_run "$(cli_case_cache ca5b)" "$repo" "$sid"
  ca_ck "CA5: sentinel then CLI, exit 0" "0" "$RTB_CLI_RC"
  ca_has '^BASELINE_ACCEPTED: kind=undetermined$' && pass "CA5: BASELINE_ACCEPTED: kind=undetermined" \
    || fail "CA5: no BASELINE_ACCEPTED: kind=undetermined line (out: $RTB_CLI_OUT)"
  [ -e "$ran" ] && fail "CA5: the base test ran again" || pass "CA5: the base test did not run"
  ca_ck "CA5: completion_basis" '"baseline-user-accepted"' "$(read_step_field "$sid" run_tests completion_basis)"
}
