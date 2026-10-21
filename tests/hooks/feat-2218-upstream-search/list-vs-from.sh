# list-vs-from.sh — U14-U16: one fixture, both paths. Sourced by
# tests/hooks/feat-2218-upstream-search.sh.
# Tests: hooks/workflow-state/upstream-search.js, bin/lib/resume-session/upstream-view.js
# Tags: session-upstream, upstream-search, resume-session, adoptability, granularity, cross-check, regression-2279, scope:issue-specific, pwsh-not-required, TL2, regression-2297

_u14_run() {
    env -u CLAUDE_CODE_SESSION_ID \
        WORKFLOW_STATE_DIR="$TMP/u14/wf" WORKFLOW_PLANS_DIR="$TMP/u14/wf" \
        CLAUDE_TRANSCRIPT_BASE_DIR="$TMP/u14/transcripts" \
        HOME="$TMP/home" USERPROFILE="$TMP/home" \
        "$RWT" 60 node -e "$1" 2>&1
}

# U8/U9/U13 each pin ONE listing verdict against a hand-written expectation and
# none of them runs `--from`, so a preview computing its grain from anything but
# decideGranularity would keep passing while the two paths drifted apart.
#
# Two donors land on DIFFERENT rungs (same cwd -> full, no cwd -> degraded),
# with one heir clone per donor: `--from` writes into the heir it adopts for, so
# a shared heir would let the first adoption change the second one's input.
# Every clone records the cwd the listing is given, so both paths judge the same
# heir context. A stranger intent.md with no state supplies the search-only row.
_u14_fixture() {
    _u14_run "
const fs = require('fs');
const path = require('path');
const { writeState, createInitialState, markStep } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io');
const NL = String.fromCharCode(10);
const dir = '$TMP_NODE/u14/wf';
fs.mkdirSync(dir, { recursive: true });
const donors = [['fulldonor-sess-14', '$HEIR_CWD'], ['legacydonor-sess-14', null]];
for (const [sid, cwd] of donors) {
  fs.writeFileSync(path.join(dir, sid + '-intent.md'), '**Title:** ' + sid + NL + 'Cross-check donor, #2279.' + NL);
  writeState(sid, createInitialState(sid, { cwd, git_branch: 'feature/donor' }));
  markStep(sid, 'workflow_init', 'complete');
  require('$SCRIPT_CHECKOUT_ROOT_NODE/tests/lib/plan-approval-fixture').approveLive(sid, 'clarify_intent'); // #2277
  markStep(sid, 'clarify_intent', 'complete');
  writeState('heirclone-' + sid, createInitialState('heirclone-' + sid, { cwd: '$HEIR_CWD', git_branch: 'feature/donor' }));
}
writeState('heir-sess-14', createInitialState('heir-sess-14', { cwd: '$HEIR_CWD', git_branch: 'feature/donor' }));
fs.writeFileSync(path.join(dir, 'stranger-sess-14-intent.md'), '**Title:** Stranger' + NL + 'Cross-check bystander, #2279.' + NL);
const encoded = String('$HEIR_CWD').toLowerCase().replace(/[^a-zA-Z0-9]/g, '-');
const tdir = path.join('$TMP_NODE/u14/transcripts', encoded);
fs.mkdirSync(tdir, { recursive: true });
const rows = [JSON.stringify({ sessionId: 'heir-sess-14', type: 'user' })];
for (const [sid] of donors) {
  rows.push(JSON.stringify({ sessionId: 'heir-sess-14', attachment: { exitCode: 0, hookEvent: 'SessionStart', stdout: 'Current workflow session_id: ' + sid } }));
}
fs.writeFileSync(path.join(tdir, 'heir-sess-14.jsonl'), rows.join(NL) + NL);
" >/dev/null 2>&1
}

run_U14() {
    require_module "$TARGET" || return 0
    local out
    _u14_fixture
    out="$(_u14_run "
$PRELUDE
const view = require('$SCRIPT_CHECKOUT_ROOT_NODE/bin/lib/resume-session/upstream-view.js');
const problems = [];
const merged = rows(search.listUpstreamCandidates({ heirSid: 'heir-sess-14', ctx: { cwd: '$HEIR_CWD', git_branch: 'feature/donor' } }));
const grains = [];
for (const rec of merged) {
  if (rec.adoptable !== true) {
    if (rec.adoptable_granularity !== null) problems.push('non-adoptable-claims-grain:' + rec.sid);
    continue;
  }
  const v = view.buildUpstreamView({ heirSid: 'heirclone-' + rec.sid, upstreamSid: rec.sid });
  const ir = (v && v.inherit_result) || {};
  if (ir.attempted !== true || ir.ok !== true) {
    problems.push('from-refused:' + rec.sid + ':' + JSON.stringify(ir.reason || ir.error));
    continue;
  }
  if (ir.granularity !== rec.adoptable_granularity) {
    problems.push('list-vs-from:' + rec.sid + ':list=' + JSON.stringify(rec.adoptable_granularity) + ':from=' + JSON.stringify(ir.granularity));
  }
  grains.push(rec.sid + '=' + String(ir.granularity));
}
// Anchors: agreement proves nothing if the fixture exercised one rung, or if
// no record was ever listed as non-adoptable.
if (grains.indexOf('fulldonor-sess-14=full') === -1) problems.push('no-full-rung:' + JSON.stringify(grains));
if (grains.indexOf('legacydonor-sess-14=context-independent-only') === -1) problems.push('no-degraded-rung:' + JSON.stringify(grains));
if (merged.filter((x) => x.adoptable !== true).length === 0) problems.push('no-non-adoptable-record-in-fixture');
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "U14: on one shared fixture, every granularity --list advertises is the one --from's own decideGranularity ladder reaches — on both rungs, for the same donors"
    else
        fail "U14: expected 'OK', got '${out:-<err>}'"
    fi
}

# U15 — the heir U14 never has: one whose ONLY recorded progress is
# session_start_context (no top-level cwd, no step_status event at all). U14
# hands the listing an explicit ctx, so the fallback `--from` relies on is never
# the input the listing is judged from; a `--list` reading only top-level
# state.cwd therefore loses this heir's donors while `--from` adopts them
# happily. Detail plan S-9(e) step 7 / S-6a. One fixture, both paths.

_u15_run() {
    env -u CLAUDE_CODE_SESSION_ID \
        WORKFLOW_STATE_DIR="$TMP/u15/wf" WORKFLOW_PLANS_DIR="$TMP/u15/wf" \
        CLAUDE_TRANSCRIPT_BASE_DIR="$TMP/u15/transcripts" \
        HOME="$TMP/home" USERPROFILE="$TMP/home" \
        "$RWT" 60 node -e "$1" 2>&1
}

# createInitialState records the cwd under session_start_context and writes no
# top-level cwd, which is exactly the shape under test — so the heir is left
# precisely as SessionStart made it, with no step ever marked.
_u15_fixture() {
    _u15_run "
const fs = require('fs');
const path = require('path');
const { writeState, createInitialState, markStep } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io');
const NL = String.fromCharCode(10);
const dir = '$TMP_NODE/u15/wf';
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(path.join(dir, 'sscdonor-sess-15-intent.md'), '**Title:** SSC donor' + NL + 'session_start_context-only heir, #2279.' + NL);
writeState('sscdonor-sess-15', createInitialState('sscdonor-sess-15', { cwd: '$HEIR_CWD', git_branch: 'feature/donor' }));
markStep('sscdonor-sess-15', 'workflow_init', 'complete');
require('$SCRIPT_CHECKOUT_ROOT_NODE/tests/lib/plan-approval-fixture').approveLive('sscdonor-sess-15', 'clarify_intent'); // #2277
markStep('sscdonor-sess-15', 'clarify_intent', 'complete');
writeState('sscheir-sess-15', createInitialState('sscheir-sess-15', { cwd: '$HEIR_CWD', git_branch: 'feature/donor' }));
const encoded = String('$HEIR_CWD').toLowerCase().replace(/[^a-zA-Z0-9]/g, '-');
const tdir = path.join('$TMP_NODE/u15/transcripts', encoded);
fs.mkdirSync(tdir, { recursive: true });
const trows = [
  JSON.stringify({ sessionId: 'sscheir-sess-15', type: 'user' }),
  JSON.stringify({ sessionId: 'sscheir-sess-15', attachment: { exitCode: 0, hookEvent: 'SessionStart', stdout: 'Current workflow session_id: sscdonor-sess-15' } }),
];
fs.writeFileSync(path.join(tdir, 'sscheir-sess-15.jsonl'), trows.join(NL) + NL);
" >/dev/null 2>&1
}

run_U15() {
    require_module "$TARGET" || return 0
    local out
    _u15_fixture
    out="$(_u15_run "
$PRELUDE
const view = require('$SCRIPT_CHECKOUT_ROOT_NODE/bin/lib/resume-session/upstream-view.js');
const { readState } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io');
const { isAllPending } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/inheritance/adopt.js');
const problems = [];
// Fixture anchors: without them a passing verdict could be about an heir that
// carries a top-level cwd (the shape already covered) or recorded steps.
// The RECORD on disk, not the projection: readState synthesizes a top-level
// cwd out of session_start_context, so only the raw file shows the shape.
let raw = null;
try { raw = JSON.parse(require('fs').readFileSync('$TMP_NODE/u15/wf/sscheir-sess-15.json', 'utf8')); }
catch (e) { problems.push('heir-file-unreadable:' + e.message); }
if (raw && raw.cwd) problems.push('heir-record-has-top-level-cwd:' + JSON.stringify(raw.cwd));
const heir = readState('sscheir-sess-15');
if (!heir) problems.push('heir-state-missing');
else {
  if (!heir.session_start_context || heir.session_start_context.cwd !== '$HEIR_CWD') {
    problems.push('heir-session_start_context:' + JSON.stringify(heir.session_start_context));
  }
  const stepEvents = ((heir.events) || []).filter((e) => e && e.kind === 'step_status');
  if (stepEvents.length !== 0) problems.push('heir-has-step-events:' + stepEvents.length);
  if (isAllPending(heir) !== true) problems.push('heir-not-adoptable-by-isAllPending');
}
// --list, given only the heir SID: the ctx must come out of the same resolver
// --from uses, or the two paths are answering about different heirs.
const ctx = view.heirContextOf({ heirSid: 'sscheir-sess-15' });
if (!ctx || ctx.cwd !== '$HEIR_CWD') problems.push('heir-ctx-not-resolved-from-session_start_context:' + JSON.stringify(ctx));
const merged = rows(search.listUpstreamCandidates({ heirSid: 'sscheir-sess-15', ctx }));
const rec = merged.find((x) => x.sid === 'sscdonor-sess-15');
if (!rec) problems.push('donor-not-listed:' + JSON.stringify(merged.map((x) => x.sid)));
else {
  if ((rec.sources || []).indexOf('context') === -1) problems.push('donor-not-found-by-the-context-route:' + JSON.stringify(rec.sources));
  if (rec.adoptable !== true) problems.push('list-says-not-adoptable:' + JSON.stringify(rec.adoptable_reason));
  if (rec.adoptable_granularity === null) problems.push('list-claims-no-granularity');
  // --from, on the very same heir the listing was built for.
  const v = view.buildUpstreamView({ heirSid: 'sscheir-sess-15', upstreamSid: 'sscdonor-sess-15' });
  const ir = (v && v.inherit_result) || {};
  if (ir.attempted !== true || ir.ok !== true) problems.push('from-refused:' + JSON.stringify(ir.reason || ir.error));
  else if (ir.granularity !== rec.adoptable_granularity) {
    problems.push('list-vs-from:list=' + JSON.stringify(rec.adoptable_granularity) + ':from=' + JSON.stringify(ir.granularity));
  }
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "U15: an heir whose only record is session_start_context is judged the same by both paths — --list finds the donor through the context route at the grain --from then actually adopts it at"
    else
        fail "U15: expected 'OK', got '${out:-<err>}'"
    fi
}

# U16 — U15's question asked of the REAL CLI. Every case above calls
# heirContextOf() and listUpstreamCandidates() itself, so runList()'s own wiring
# in bin/resume-session-detect is asserted by nothing: drop the heirContextOf()
# call there, or pass the listing a ctx the --from path does not use, and U14/U15
# stay green while `--list` in a real session silently loses exactly the donors
# this heir shape depends on. Spawned as a subprocess, the way the skill runs it.

_U16_CLI="$SCRIPT_CHECKOUT_ROOT/bin/resume-session-detect"

_u16_run() {
    env -u CLAUDE_CODE_SESSION_ID \
        WORKFLOW_STATE_DIR="$TMP/u16/wf" WORKFLOW_PLANS_DIR="$TMP/u16/wf" \
        CLAUDE_TRANSCRIPT_BASE_DIR="$TMP/u16/transcripts" \
        HOME="$TMP/home" USERPROFILE="$TMP/home" \
        "$RWT" 60 node -e "$1" 2>&1
}

# The CLI resolves its own heir id, so it is named through the environment
# (CLAUDE_CODE_SESSION_ID) rather than an argument.
_u16_cli() {
    local sid="$1"
    shift
    env CLAUDE_CODE_SESSION_ID="$sid" \
        WORKFLOW_STATE_DIR="$TMP/u16/wf" WORKFLOW_PLANS_DIR="$TMP/u16/wf" \
        CLAUDE_TRANSCRIPT_BASE_DIR="$TMP/u16/transcripts" \
        HOME="$TMP/home" USERPROFILE="$TMP/home" \
        "$RWT" 60 node "$_U16_CLI" "$@" 2>/dev/null
}

_u16_fixture() {
    _u16_run "
const fs = require('fs');
const path = require('path');
const { writeState, createInitialState, markStep } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io');
const NL = String.fromCharCode(10);
const dir = '$TMP_NODE/u16/wf';
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(path.join(dir, 'clidonor-sess-16-intent.md'), '**Title:** CLI donor' + NL + 'runList heir-context wiring, #2279.' + NL);
writeState('clidonor-sess-16', createInitialState('clidonor-sess-16', { cwd: '$HEIR_CWD', git_branch: 'feature/donor' }));
markStep('clidonor-sess-16', 'workflow_init', 'complete');
require('$SCRIPT_CHECKOUT_ROOT_NODE/tests/lib/plan-approval-fixture').approveLive('clidonor-sess-16', 'clarify_intent'); // #2277
markStep('clidonor-sess-16', 'clarify_intent', 'complete');
writeState('cliheir-sess-16', createInitialState('cliheir-sess-16', { cwd: '$HEIR_CWD', git_branch: 'feature/donor' }));
const encoded = String('$HEIR_CWD').toLowerCase().replace(/[^a-zA-Z0-9]/g, '-');
const tdir = path.join('$TMP_NODE/u16/transcripts', encoded);
fs.mkdirSync(tdir, { recursive: true });
const trows = [
  JSON.stringify({ sessionId: 'cliheir-sess-16', type: 'user' }),
  JSON.stringify({ sessionId: 'cliheir-sess-16', attachment: { exitCode: 0, hookEvent: 'SessionStart', stdout: 'Current workflow session_id: clidonor-sess-16' } }),
];
fs.writeFileSync(path.join(tdir, 'cliheir-sess-16.jsonl'), trows.join(NL) + NL);
" >/dev/null 2>&1
}

run_U16() {
    require_module "$TARGET" || return 0
    local out
    _u16_fixture
    # --list first: --from ADOPTS into the heir, so running it first would change
    # the very input the listing is judged from.
    _u16_cli cliheir-sess-16 --list > "$TMP/u16/list.json"
    _u16_cli cliheir-sess-16 --from clidonor-sess-16 > "$TMP/u16/from.json"
    out="$(_u16_run "
const fs = require('fs');
const problems = [];
// Fixture anchor: the heir must carry NO top-level cwd, or runList could reach
// the donor without ever consulting session_start_context.
let raw = null;
try { raw = JSON.parse(fs.readFileSync('$TMP_NODE/u16/wf/cliheir-sess-16.json', 'utf8')); }
catch (e) { problems.push('heir-file-unreadable:' + e.message); }
if (raw && raw.cwd) problems.push('heir-record-has-top-level-cwd:' + JSON.stringify(raw.cwd));
if (raw && (!raw.session_start_context || raw.session_start_context.git_branch !== 'feature/donor')) {
  problems.push('heir-session_start_context-branch:' + JSON.stringify(raw && raw.session_start_context));
}
let list = null;
let from = null;
try { list = JSON.parse(fs.readFileSync('$TMP_NODE/u16/list.json', 'utf8')); }
catch (e) { problems.push('cli-list-emitted-no-json:' + e.message); }
try { from = JSON.parse(fs.readFileSync('$TMP_NODE/u16/from.json', 'utf8')); }
catch (e) { problems.push('cli-from-emitted-no-json:' + e.message); }
if (list) {
  if (list.type !== 'list') problems.push('cli-list-type:' + JSON.stringify(list.type));
  const ids = (list.candidates || []).map((x) => x.sid);
  const rec = (list.candidates || []).find((x) => x.sid === 'clidonor-sess-16');
  if (!rec) problems.push('cli-list-lost-the-donor:' + JSON.stringify(ids));
  else {
    if ((rec.sources || []).indexOf('context') === -1) problems.push('donor-not-found-by-the-context-route:' + JSON.stringify(rec.sources));
    if (rec.adoptable !== true) problems.push('cli-list-says-not-adoptable:' + JSON.stringify(rec.adoptable_reason));
    if (rec.adoptable_granularity === null) problems.push('cli-list-claims-no-granularity');
    const ir = (from && from.inherit_result) || {};
    if (ir.attempted !== true || ir.ok !== true) problems.push('cli-from-refused:' + JSON.stringify(ir.reason || ir.error));
    else if (ir.granularity !== rec.adoptable_granularity) {
      problems.push('cli-list-vs-from:list=' + JSON.stringify(rec.adoptable_granularity) + ':from=' + JSON.stringify(ir.granularity));
    }
  }
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "U16: the real 'resume-session-detect --list' subprocess offers a session_start_context-only heir's donor as adoptable, at the same granularity the real --from subprocess then adopts it at"
    else
        fail "U16: expected 'OK', got '${out:-<err>}'"
    fi
}
