#!/usr/bin/env bash
# tests/feature-1733-state-event-stream/started-at-removed.sh
# Tests: hooks/workflow-state/state-io/core.js, hooks/workflow-state/state-io/events.js, hooks/workflow-state/step-timestamps.js
# Tags: workflow-state, event-stream, started-at, removal, config-toggle, scope:issue-specific, pwsh-not-required, TL2
#
# `started_at` + the RECORD_STEP_TIMESTAMPS toggle existed to reconstruct how long a step
# took. The event stream answers that from adjacent `at` values, so #1733 deletes both.
#
# A removal is only proven by the FEATURE'S OWN switches: migrating old v1 data (covered in
# migration-v1-v2.sh) shows the field is not carried forward, but says nothing about a
# fresh session whose environment still sets RECORD_STEP_TIMESTAMPS=on — which is exactly
# the state every existing installation is in the moment this ships. So every case here
# writes NEW state and asserts absence on all three surfaces: no event field, no `current`
# field, and no occurrence anywhere in the file's bytes.
#
# TL3 gap (what this file does NOT catch):
# - a real .env on the host setting RECORD_STEP_TIMESTAMPS; the toggle is injected as a
#   process env var here (which is how load-env surfaces it anyway).
# Closest-to-action mitigation: hook-registration category in bin/check-verification-gate.sh.

CASE_TAG="noSA"
# shellcheck source=tests/feature-1733-state-event-stream/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# Common body: mark one step twice (the transition that used to mint started_at), then
# report every surface the field could hide on.
SA_JS='
S.markStep(sid, "run_tests", "in_progress");
sleep(5);
S.markStep(sid, "run_tests", "complete");
const disk = rd();
const inEvents = disk.events.filter((e) => Object.prototype.hasOwnProperty.call(e, "started_at")).length;
const inCurrent = Object.keys(disk.current.steps || {}).filter(
  (s) => Object.prototype.hasOwnProperty.call(disk.current.steps[s], "started_at")).length;
const inBytes = raw().indexOf("started_at") !== -1;
console.log([
  "events_with_field=" + inEvents,
  "current_with_field=" + inCurrent,
  "in_bytes=" + inBytes,
  "status=" + disk.current.steps.run_tests.status,
].join(" "));
'
SA_WANT="events_with_field=0 current_with_field=0 in_bytes=false status=complete"

echo "== T1: RECORD_STEP_TIMESTAMPS=on -> the toggle is dead, no started_at anywhere =="
if run_case "T1/toggle-on"; then
    next_sid
    nodejs_env "RECORD_STEP_TIMESTAMPS=on" "$SID" "$PRE$SA_JS"
    assert_eq "T1/toggle-on" "$SA_WANT" "$NODE_OUT"
fi

echo "== T2: RECORD_STEP_TIMESTAMPS=off -> same result (the two branches have merged) =="
if run_case "T2/toggle-off"; then
    next_sid
    nodejs_env "RECORD_STEP_TIMESTAMPS=off" "$SID" "$PRE$SA_JS"
    assert_eq "T2/toggle-off" "$SA_WANT" "$NODE_OUT"
fi

echo "== T3: toggle unset -> same result =="
if run_case "T3/toggle-unset"; then
    next_sid
    nodejs "$SID" "$PRE$SA_JS"
    assert_eq "T3/toggle-unset" "$SA_WANT" "$NODE_OUT"
fi

echo "== T4: a garbage toggle value cannot resurrect the field =="
if run_case "T4/toggle-garbage"; then
    next_sid
    nodejs_env "RECORD_STEP_TIMESTAMPS=yes-please" "$SID" "$PRE$SA_JS"
    assert_eq "T4/toggle-garbage" "$SA_WANT" "$NODE_OUT"
fi

echo "== T5: a caller that explicitly supplies started_at cannot get it persisted =="
if run_case "T5/caller-supplied-started-at"; then
    next_sid
    # extraFields is caller-supplied, so this is the one route by which the field could
    # survive the deletion of the toggle: an old call site (or a stale hook on disk during
    # a partial deploy) still passing started_at through markStep.
    nodejs_env "RECORD_STEP_TIMESTAMPS=on" "$SID" "$PRE"'
let threw = "-";
try {
  S.markStep(sid, "run_tests", "in_progress", { started_at: "2020-01-01T00:00:00.000Z" });
} catch (e) { threw = e.name; }
// Either outcome is acceptable for the CALL (refuse, or accept-and-drop); what is not
// acceptable is the value reaching the file.
const disk = rd();
const anyEvent = disk.events.some((e) => Object.prototype.hasOwnProperty.call(e, "started_at")
  || (e.kind === "step_annotation" && e.key === "started_at"));
console.log([
  "event_carries=" + anyEvent,
  "in_bytes=" + (raw().indexOf("started_at") !== -1),
  "in_bytes_2020=" + (raw().indexOf("2020-01-01") !== -1),
  "threw=" + threw,
].join(" "));
'
    if printf '%s' "$NODE_OUT" | grep -q "^event_carries=false in_bytes=false in_bytes_2020=false threw="; then
        pass "T5/caller-supplied-started-at"
    else
        fail "T5/caller-supplied-started-at" "$NODE_OUT"
    fi
fi

echo "== T6: the toggle's implementation is gone from the code base, not just unused =="
if run_case "T6/module-and-export-removed"; then
    # A left-behind module is a live re-entry point: any hook that still requires it keeps
    # writing a field the schema no longer allows, and the allowlist would reject the write
    # at runtime rather than at review time.
    T6_MOD="present"
    [ -f "$AGENTS_DIR/hooks/workflow-state/step-timestamps.js" ] || T6_MOD="absent"
    T6_EXPORT="present"
    exports_have "./hooks/workflow-state/state-io" "recordStepTimestampsEnabled" || T6_EXPORT="absent"
    T6_REFS="$(cd "$AGENTS_DIR" && grep -rl "step-timestamps\|recordStepTimestampsEnabled\|applyStartedAt" \
        hooks bin skills 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "T6/module-removed" "absent" "$T6_MOD"
    assert_eq "T6/barrel-export-removed" "absent" "$T6_EXPORT"
    assert_eq "T6/no-remaining-references" "0" "$T6_REFS"
fi

feature_banner
finish "started-at-removed"
