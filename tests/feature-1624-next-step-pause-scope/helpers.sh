# helpers.sh
# Tests: hooks/lib/next-step-pause-marker.js, hooks/lib/session-markers.js, hooks/stop-premature-stop-guard.js, bin/workflow/next-step
# Tags: next-step-pause, marker-v2, for-step, ttl, audit, regression-1624, scope:issue-specific, pwsh-not-required, TL2
#
# Marker seeding, state seeding and the real-consumer drivers for the #1624
# scoped-pause suite. Sourced by tests/feature-1624-next-step-pause-scope.sh;
# expects AGENTS_DIR, _AGENTS_DIR_NODE, RWT and the pass/fail/skip counters.

PAUSE_NODE="$_AGENTS_DIR_NODE/hooks/lib/next-step-pause-marker.js"
MARKERS_NODE="$_AGENTS_DIR_NODE/hooks/lib/session-markers.js"
STATEIO_NODE="$_AGENTS_DIR_NODE/hooks/workflow-state/state-io.js"
MARK_HOOK="$AGENTS_DIR/hooks/workflow-mark.js"
NEXT_STEP="$AGENTS_DIR/bin/workflow/next-step"
GUARD_C4="$AGENTS_DIR/hooks/stop-premature-stop-guard.js"
PAUSE_TTL_MS=$((4 * 60 * 60 * 1000))

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'pausescope1624'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# trim <text> — strip surrounding spaces, so the case tables can be aligned for
# reading without the padding leaking into the values under test.
trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# write_pause <tn> <sid> <reason> — the real writePauseMarker. Sets WP_OUT to
# String(returned value) so a rejected session id can be told apart from a
# successful write that happened to land nowhere.
write_pause() {
    WP_OUT=$(CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" SID="$2" REASON="$3" "$RWT" 20 node -e "
let r;
try { r = require('$PAUSE_NODE').writePauseMarker(process.env.SID, { reason: process.env.REASON }); }
catch (e) { process.stdout.write('THREW:' + e.message); process.exit(0); }
process.stdout.write(typeof r === 'object' && r !== null ? JSON.stringify(r) : String(r));" 2>/dev/null)
}

# marker_path <tmp> <sid> — where the pause marker for <sid> belongs.
marker_path() { printf '%s/%s.next-step-paused' "$1" "$2"; }

# pause_active <tn> <sid> <currentStep> — String(isPauseActive(...)), from both
# the owning module and the session-markers facade the guards actually call.
# Printed as `<module>/<facade>` so a fix applied to only one of the two is named
# rather than passing on the half that was updated.
pause_active() {
    CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" SID="$2" STEP="$3" "$RWT" 20 node -e "
const m = require('$PAUSE_NODE');
const sm = require('$MARKERS_NODE');
const a = m.isPauseActive(process.env.SID, process.env.STEP);
const b = sm.isNextStepPaused(process.env.SID, process.env.STEP);
process.stdout.write(String(a) + '/' + String(b));" 2>/dev/null
}

assert_active() {
    local id="$1" desc="$2" want="$3" tn="$4" sid="$5" step="$6" got
    got="$(pause_active "$tn" "$sid" "$step")"
    if [ "$got" = "$want/$want" ]; then
        pass "$id: $desc"
    else
        fail "$id: $desc — expected '$want/$want' (module/facade), got '${got:-<module-load-error>}'"
    fi
}

# seed_started <tn> <sid> — workflow_init + clarify_intent complete, so the
# session's current step is `research`: next-step recommends it and C4 blocks,
# which is what makes an observed silence attributable to the pause marker.
seed_started() {
    CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" "$RWT" 15 node -e "
const wf = require('$STATEIO_NODE');
wf.markStep('$2', 'workflow_init', 'complete');
wf.markStep('$2', 'clarify_intent', 'complete');" >/dev/null 2>&1
}

# expire_marker <tmp> <sid> [ms-ago] — push expires_at into the past in place.
expire_marker() {
    P="$(node_path "$(marker_path "$1" "$2")")" MS="${3:-60000}" "$RWT" 15 node -e "
const fs = require('fs');
const m = JSON.parse(fs.readFileSync(process.env.P, 'utf8'));
m.expires_at = new Date(Date.now() - Number(process.env.MS)).toISOString();
fs.writeFileSync(process.env.P, JSON.stringify(m));" >/dev/null 2>&1
}

# patch_marker <tmp> <sid> <field> <js-literal> — set one field to an arbitrary
# JSON value (including null / a number / a non-ISO string), for the fail-CLOSED
# input classes that writePauseMarker itself would never emit.
patch_marker() {
    P="$(node_path "$(marker_path "$1" "$2")")" F="$3" "$RWT" 15 node -e "
const fs = require('fs');
const m = JSON.parse(fs.readFileSync(process.env.P, 'utf8'));
m[process.env.F] = $4;
fs.writeFileSync(process.env.P, JSON.stringify(m));" >/dev/null 2>&1
}

# run_c4 <tn> <sid> — the REAL C4 premature-stop guard as a child process.
# Sets C4_OUT / C4_RC. rc 0 = silent (exempt), rc 2 = blocked (nudge emitted).
run_c4() {
    C4_OUT=$(echo "{\"stop_hook_active\":false,\"session_id\":\"$2\",\"transcript_path\":\"\"}" \
        | CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
          "$RWT" 25 node "$(node_path "$GUARD_C4")" 2>/dev/null)
    C4_RC=$?
}

# run_next_step <tn> <sid> — the REAL bin/workflow/next-step. Sets NS_OUT.
run_next_step() {
    NS_OUT=$(CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" \
        "$RWT" 20 node "$NEXT_STEP" --session "$2" 2>/dev/null)
}

# ns_action <ns-out> — the ACTION value, or `<none>` when next-step produced no
# ACTION line at all (which must never be read as "not paused").
ns_action() {
    printf '%s\n' "$1" | grep -m1 '^ACTION=' | sed 's/^ACTION=//' || true
}

# sup_findings_text <tmp> <sid> — the supervisor state file's raw text, or
# `<absent>`. The audit trail assertion reads this rather than the marker.
sup_findings_text() {
    local f="$1/$2-supervisor-state.json"
    if [ -f "$f" ]; then cat "$f"; else printf '<absent>'; fi
}
