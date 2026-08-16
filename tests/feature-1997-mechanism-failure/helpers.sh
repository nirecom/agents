# helpers.sh
# Tests: hooks/lib/mechanism-failure.js, hooks/workflow-state/state-io.js, hooks/stop-premature-stop-guard.js
# Tags: mechanism-failure, stall-detection, supervisor-report, stall-reported, regression-1997, scope:issue-specific, pwsh-not-required, TL1, TL2
#
# State seeding, detector/reporter drivers and ledger readers for the #1997
# mechanism-failure suite. Sourced by tests/feature-1997-mechanism-failure.sh;
# expects AGENTS_DIR, _AGENTS_DIR_NODE, RWT and the pass/fail/skip counters.

MF_NODE="$_AGENTS_DIR_NODE/hooks/lib/mechanism-failure.js"
STATEIO_NODE="$_AGENTS_DIR_NODE/hooks/workflow-state/state-io.js"
BASENAMES_NODE="$_AGENTS_DIR_NODE/hooks/lib/protected-basenames.js"
GUARD_C4="$AGENTS_DIR/hooks/stop-premature-stop-guard.js"
TTL_MS=$((4 * 60 * 60 * 1000))

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'mechfail1997'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# seed_in_flight <tmp> <tn> <sid> <step> <ms-ago> — a real markStep, then the
# timestamp backdated so the age axis is exercised without sleeping.
seed_in_flight() {
    CLAUDE_WORKFLOW_DIR="$2" WORKFLOW_PLANS_DIR="$2" SID="$3" ST="$4" "$RWT" 15 node -e "
const wf = require('$STATEIO_NODE');
wf.markStep(process.env.SID, 'workflow_init', 'complete');
wf.markStep(process.env.SID, process.env.ST, 'in_progress');" >/dev/null 2>&1
    P="$(node_path "$1/$3.json")" ST="$4" MS="$5" "$RWT" 15 node -e "
const fs = require('fs');
const s = JSON.parse(fs.readFileSync(process.env.P, 'utf8'));
const at = new Date(Date.now() - Number(process.env.MS)).toISOString();
for (const e of s.events || []) { if (e.step === process.env.ST) e.at = at; }
fs.writeFileSync(process.env.P, JSON.stringify(s));" >/dev/null 2>&1
}

# detect <tn> <sid> — detectStalledSteps as a stable, comparable string:
# `step:kind` pairs sorted and joined, or `<empty>` for no findings. Prints
# `THREW:<msg>` when the total-function contract is broken, so a throw can never
# be mistaken for "no findings".
detect() {
    CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" SID="$2" "$RWT" 20 node -e "
const { detectStalledSteps } = require('$MF_NODE');
let out;
try { out = detectStalledSteps(process.env.SID); } catch (e) { process.stdout.write('THREW:' + e.message); process.exit(0); }
if (!Array.isArray(out)) { process.stdout.write('NOT-AN-ARRAY:' + typeof out); process.exit(0); }
process.stdout.write(out.length === 0 ? '<empty>' : out.map((f) => f.step + ':' + f.kind).sort().join(','));" 2>/dev/null
}

assert_detect() {
    local id="$1" desc="$2" want="$3" tn="$4" sid="$5" got
    got="$(detect "$tn" "$sid")"
    if [ "$got" = "$want" ]; then
        pass "$id: $desc"
    else
        fail "$id: $desc — expected '$want', got '${got:-<module-load-error>}'"
    fi
}

# report_once <tn> <sid> <step> <kind> — one reportMechanismFailureOnce call
# with the workflow dir and the plans dir pinned to the SAME fixture directory
# (the ordinary case), printing `<reported>|<reason>`.
report_once() { report_once_pd "$1" "$1" "$2" "$3" "$4"; }

# report_once_pd <wf-tn> <plans-tn> <sid> <step> <kind> — the same call with the
# two directories pinned SEPARATELY, so the supervisor destination can be made
# to fail while the ledger destination stays writable (the ordering case).
report_once_pd() {
    CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$2" SID="$3" ST="$4" KIND="$5" "$RWT" 25 node -e "
const { reportMechanismFailureOnce } = require('$MF_NODE');
let r;
try {
  r = reportMechanismFailureOnce(process.env.SID, { step: process.env.ST, kind: process.env.KIND });
} catch (e) { process.stdout.write('THREW|' + e.message); process.exit(0); }
process.stdout.write(String(r && r.reported) + '|' + String(r && r.reason));" 2>/dev/null
}

# reported_entries <tmp> <sid> — how many findings the stall-reported ledger
# holds. `<absent>` when the file was never written; `<unparseable>` when it is
# not the JSON the reporter is supposed to write.
reported_entries() {
    P="$(node_path "$1/$2.stall-reported")" "$RWT" 15 node -e "
const fs = require('fs');
let raw;
try { raw = fs.readFileSync(process.env.P, 'utf8'); } catch (e) { process.stdout.write('<absent>'); process.exit(0); }
let j;
try { j = JSON.parse(raw); } catch (e) { process.stdout.write('<unparseable>'); process.exit(0); }
const list = Array.isArray(j) ? j : (Array.isArray(j.findings) ? j.findings : null);
if (!list) { process.stdout.write('<no-findings-array>'); process.exit(0); }
process.stdout.write(String(list.length));" 2>/dev/null
}

# reported_keys <tmp> <sid> — the ledger's findings as sorted `step:kind` pairs,
# so "two entries" can be told apart from "the right two entries".
reported_keys() {
    P="$(node_path "$1/$2.stall-reported")" "$RWT" 15 node -e "
const fs = require('fs');
let j;
try { j = JSON.parse(fs.readFileSync(process.env.P, 'utf8')); } catch (e) { process.stdout.write('<absent-or-unparseable>'); process.exit(0); }
const list = Array.isArray(j) ? j : (Array.isArray(j.findings) ? j.findings : null);
if (!list) { process.stdout.write('<no-findings-array>'); process.exit(0); }
process.stdout.write(list.map((f) => String(f.step) + ':' + String(f.kind)).sort().join(','));" 2>/dev/null
}

# sup_state_path <plans-tmp> <sid> — the supervisor state file for a session.
sup_state_path() { printf '%s/%s-supervisor-state.json' "$1" "$2"; }

# run_c4 <tn> <sid> — the REAL C4 Stop guard as a child process, the fail-fast
# consumer that has to surface a mechanism failure rather than nudge past it.
# Sets C4_OUT / C4_RC (rc 0 = silent, rc 2 = blocked).
run_c4() {
    C4_OUT=$(echo "{\"stop_hook_active\":false,\"session_id\":\"$2\",\"transcript_path\":\"\"}" \
        | CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
          "$RWT" 25 node "$(node_path "$GUARD_C4")" 2>/dev/null)
    C4_RC=$?
}
