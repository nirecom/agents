# helpers.sh
# Tests: hooks/stop-premature-stop-guard.js, hooks/supervisor-guard.js, hooks/workflow-mark.js, hooks/workflow-state/state-io.js, bin/workflow/next-step
# Tags: stop-hook, supervisor-guard, exemption, session-marker, regression-1794, scope:issue-specific, pwsh-not-required, TL2
#
# State/marker seeding and hook drivers for the #1794/#1665/#1685 stop-guard
# exemption suite. Sourced by tests/feature-1794-stop-guard-exemptions.sh.
# Expects AGENTS_DIR, _AGENTS_DIR_NODE, RWT, and the pass/fail/skip counters.

STATEIO_NODE="$_AGENTS_DIR_NODE/hooks/workflow-state/state-io.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"
PATTERNS_NODE="$_AGENTS_DIR_NODE/hooks/lib/sentinel-patterns.js"
POLICY_NODE="$_AGENTS_DIR_NODE/hooks/lib/stop-exemption-policy.js"
GUARD_C4="$AGENTS_DIR/hooks/stop-premature-stop-guard.js"
GUARD_C2="$AGENTS_DIR/hooks/supervisor-guard.js"
MARK_HOOK="$AGENTS_DIR/hooks/workflow-mark.js"
NEXT_STEP="$AGENTS_DIR/bin/workflow/next-step"

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'stopexempt1794'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# seed_started <tn> <sid> — workflow_init + clarify_intent complete, so
# next-step's current step is `research` → ACTION=invoke (C4 would normally block).
seed_started() {
    CLAUDE_WORKFLOW_DIR="$1" "$RWT" 15 node -e "
const wf = require('$STATEIO_NODE');
wf.markStep('$2', 'workflow_init', 'complete');
wf.markStep('$2', 'clarify_intent', 'complete');" >/dev/null 2>&1
}

# seed_preinit <tn> <sid> — state file exists, workflow_init still pending.
seed_preinit() {
    CLAUDE_WORKFLOW_DIR="$1" "$RWT" 15 node -e "
require('$STATEIO_NODE').markStep('$2', 'workflow_init', 'pending');" >/dev/null 2>&1
}

# seed_raw_state <tmp> <sid> <workflow_init_status> — writes the state file
# directly so statuses the normal markStep vocabulary refuses (e.g. `skipped`
# on a non-skippable step) can still be exercised by isWorkflowStarted.
seed_raw_state() {
    local tmp="$1" sid="$2" status="$3"
    TMPD="$(node_path "$tmp")" SID="$sid" ST="$status" "$RWT" 15 node -e "
const fs = require('fs'), path = require('path');
const now = new Date().toISOString();
const steps = {};
for (const s of ['workflow_init','clarify_intent','research','outline','detail','branching_complete','write_tests','review_tests','run_tests','review_security','docs','user_verification','cleanup','pre_final_report_gate']) {
  steps[s] = { status: 'pending', updated_at: null };
}
steps.workflow_init = { status: process.env.ST, updated_at: now };
fs.mkdirSync(process.env.TMPD, { recursive: true });
fs.writeFileSync(path.join(process.env.TMPD, process.env.SID + '.json'),
  JSON.stringify({ version: 1, session_id: process.env.SID, created_at: now, steps, workflow_type: 'wf-code', closes_issues: [1794] }));" >/dev/null 2>&1
}

# seed_corrupt_state <tmp> <sid> — state file exists but is not parseable JSON.
seed_corrupt_state() { printf '{ this is not json' > "$1/$2.json"; }

# seed_sup_armed <tn> <sid> — C2 scheduled-review trigger (alert_armed_at set).
seed_sup_armed() {
    WORKFLOW_PLANS_DIR="$1" "$RWT" 15 node -e "
const w = require('$WRITER_NODE'), s = require('$SCHEMA_NODE'), fs = require('fs');
const st = s.createEmptyState('$2');
st.alert.alert_armed_at = new Date().toISOString();
st.alert.alert_phase = 'pending';
fs.writeFileSync(w.getStatePath('$2'), JSON.stringify(st));" >/dev/null 2>&1
}

# seed_sup_error <tn> <sid> — C2 severity-escalation trigger (cumSev=error).
seed_sup_error() {
    WORKFLOW_PLANS_DIR="$1" "$RWT" 15 node -e "
const w = require('$WRITER_NODE'), s = require('$SCHEMA_NODE'), fs = require('fs');
const st = s.createEmptyState('$2');
st.alert.cumulative_severity = 'error';
st.alert.alert_phase = 'pending';
st.alert.findings = [{ categories: ['code'], severity: 'error', detail: 'blocking',
  reporter: 'workflow-gate', status: 'confirmed', timestamp: new Date().toISOString() }];
fs.writeFileSync(w.getStatePath('$2'), JSON.stringify(st));" >/dev/null 2>&1
}

# write_bg_marker <tmp> <sid> <expires_offset_ms|none|badjson>
write_bg_marker() {
    local tmp="$1" sid="$2" mode="$3"
    if [ "$mode" = "badjson" ]; then printf 'not json at all' > "$tmp/$sid.background-work"; return; fi
    MODE="$mode" OUTP="$(node_path "$tmp/$sid.background-work")" "$RWT" 15 node -e "
const fs = require('fs');
const payload = { reason: 'seeded by test', set_at: new Date().toISOString() };
if (process.env.MODE !== 'none') {
  payload.expires_at = new Date(Date.now() + Number(process.env.MODE)).toISOString();
}
fs.writeFileSync(process.env.OUTP, JSON.stringify(payload));" >/dev/null 2>&1
}

# age_file <path> <days> — backdate mtime so cleanupZombies() sees it as stale.
age_file() {
    P="$(node_path "$1")" D="$2" "$RWT" 15 node -e "
const fs = require('fs');
const t = new Date(Date.now() - Number(process.env.D) * 24 * 60 * 60 * 1000);
fs.utimesSync(process.env.P, t, t);" >/dev/null 2>&1
}

# run_c4 <tn> <sid> [transcript] — drives the real C4 Stop hook. Sets C4_OUT / C4_RC.
# <transcript> is optional and defaults to "" (the historical behaviour); pass a
# node_path-normalised path so the JSON payload needs no escaping.
run_c4() {
    C4_OUT=$(echo "{\"stop_hook_active\":false,\"session_id\":\"$2\",\"transcript_path\":\"${3:-}\"}" \
        | CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
          "$RWT" 25 node "$(node_path "$GUARD_C4")" 2>/dev/null)
    C4_RC=$?
}

# run_c2 <tn> <sid> [transcript] — drives the real C2 Stop hook as a child process.
# Sets C2_OUT / C2_RC / C2_ERR (stderr text). <transcript> is optional (default "")
# and is what the C1 sentinel-hang detector reads.
run_c2() {
    local errf
    errf="$(mktemp)"
    C2_OUT=$(echo "{\"stop_hook_active\":false,\"session_id\":\"$2\",\"transcript_path\":\"${3:-}\"}" \
        | CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
          "$RWT" 25 node "$(node_path "$GUARD_C2")" 2>"$errf")
    C2_RC=$?
    C2_ERR=$(cat "$errf" 2>/dev/null)
    rm -f "$errf" 2>/dev/null || true
}

# run_mark <tn> <sid> <command> — drives the real workflow-mark PostToolUse hook
# with a Bash tool_input, i.e. the same dispatch path a live sentinel takes.
run_mark() {
    MARK_OUT=$(CMD="$3" SID="$2" "$RWT" 15 node -e "
process.stdout.write(JSON.stringify({ tool_name: 'Bash', session_id: process.env.SID,
  transcript_path: '', tool_input: { command: process.env.CMD } }));" \
        | CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" \
          "$RWT" 20 node "$(node_path "$MARK_HOOK")" 2>/dev/null)
    MARK_RC=$?
}

# run_next_step <tn> <sid> — real bin/workflow/next-step run. Sets NS_OUT.
run_next_step() {
    NS_OUT=$(CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" \
        "$RWT" 20 node "$NEXT_STEP" --session "$2" 2>/dev/null)
}

# hostile_sid_probe <handler-module-abs-node-path> <export-name> <marker-suffix> <sentinel-command>
# Drives ONE enforce-override handler directly with a set of hostile session ids
# (path traversal, absolute paths, separators, NUL, empty, whitespace) and proves
# the SID guard holds: every hostile id must be refused with a fatal signal and
# must not create a file anywhere under the fixture root — neither inside the
# workflow dir nor beside it. An over-long but regex-VALID id is included as the
# containment row: it may be accepted, but whatever it writes must stay a direct
# child of the workflow dir. Prints OK or BAD:<problems>.
hostile_sid_probe() {
    local mod="$1" fn="$2" suffix="$3" cmd="$4" tmp root wf out
    tmp="$(make_tmp)"
    root="$(node_path "$tmp")"
    mkdir -p "$tmp/wf" "$tmp/outside"
    wf="$root/wf"
    out=$(MOD="$mod" FN="$fn" SUFFIX="$suffix" CMD="$cmd" ROOT="$root" \
        CLAUDE_WORKFLOW_DIR="$wf" WORKFLOW_PLANS_DIR="$wf" "$RWT" 20 node -e "
const fs = require('fs'), path = require('path');
const handler = require(process.env.MOD)[process.env.FN];
const root = process.env.ROOT, wf = path.join(root, 'wf');
const problems = [];
if (typeof handler !== 'function') { process.stdout.write('BAD:handler-not-exported'); process.exit(0); }
const walk = (d) => {
  let out = [];
  for (const n of fs.readdirSync(d)) {
    const p = path.join(d, n);
    let st; try { st = fs.lstatSync(p); } catch (e) { continue; }
    if (st.isDirectory()) out = out.concat(walk(p)); else out.push(p);
  }
  return out;
};
const hostile = [
  ['traversal-rel', '../../evil'],
  ['traversal-dotdot', '..'],
  ['traversal-mixed', 'ok/../../evil'],
  ['separator-fwd', 'a/b'],
  ['separator-back', 'a\\\\b'],
  ['absolute-posix', '/etc/passwd'],
  ['absolute-win', 'C:\\\\Windows\\\\evil'],
  ['nul-byte', 'a\\u0000b'],
  ['empty', ''],
  ['whitespace', '   '],
  ['dotfile-escape', '.' + path.sep + '..' + path.sep + 'evil'],
  ['glob', '*'],
  ['tilde', '~'],
];
for (const [label, sid] of hostile) {
  let fatal = null;
  let handled;
  try {
    handled = handler({
      cmd: process.env.CMD, sessionId: sid,
      pushMessage: () => {}, signalFatal: (m) => { fatal = m; },
    });
  } catch (e) {
    problems.push(label + ':threw(' + e.message + ')');
    continue;
  }
  if (handled !== true) problems.push(label + ':sentinel-not-handled');
  if (!fatal) problems.push(label + ':no-fatal-signal');
  const files = walk(root);
  if (files.length > 0) {
    problems.push(label + ':wrote(' + files.map((f) => path.relative(root, f)).join(',') + ')');
    for (const f of files) { try { fs.unlinkSync(f); } catch (e) {} }
  }
}
// containment row: a long but regex-valid sid is allowed, yet must stay inside
// the workflow dir (never escape it, never land beside it).
const longSid = 'z'.repeat(120);
try {
  handler({ cmd: process.env.CMD, sessionId: longSid, pushMessage: () => {}, signalFatal: () => {} });
} catch (e) { problems.push('long-sid:threw(' + e.message + ')'); }
for (const f of walk(root)) {
  if (path.dirname(path.resolve(f)) !== path.resolve(wf)) {
    problems.push('long-sid:escaped(' + path.relative(root, f) + ')');
  } else if (path.basename(f) !== longSid + process.env.SUFFIX) {
    problems.push('long-sid:unexpected-name(' + path.basename(f) + ')');
  }
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    printf '%s' "$out"
}

# no_new_finding <tmp> <sid> — true when C4 recorded nothing for this session:
# either no supervisor state file at all, or an empty findings array.
no_new_finding() {
    local f="$1/$2-supervisor-state.json"
    [ ! -f "$f" ] && return 0
    ! grep -q '"detail"' "$f" 2>/dev/null
}

# Session-inheritance fixtures for the #1794 adoption (I) cases live in their own
# file so neither exceeds the 300-line WARN threshold (rules/coding/file-split.md
# Pattern A). Sourced last: it depends on STATEIO_NODE / node_path above.
# shellcheck source=tests/feature-1794-stop-guard-exemptions/helpers/inheritance.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/inheritance.sh"
