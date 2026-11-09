# list-vs-from.sh — U14-U16: one fixture, both paths. Sourced by
# tests/hooks/feat-2218-session-upstream-search.sh.
# Tests: hooks/workflow-state/session-upstream-search.js, bin/lib/resume-session/session-upstream-view.js
# Tags: session-upstream, upstream-search, resume-session, adoptability, granularity, cross-check, regression-2279, scope:issue-specific, pwsh-not-required, TL2, regression-2297, test-lang-exception:e2e

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
# Two upstreams land on DIFFERENT rungs (same cwd -> full, no cwd -> degraded),
# with one downstream clone per upstream: `--from` writes into the downstream it adopts for, so
# a shared downstream would let the first adoption change the second one's input.
# Every clone records the cwd the listing is given, so both paths judge the same
# downstream context. A stranger intent.md with no state supplies the search-only row.
_u14_fixture() {
    _u14_run "
const fs = require('fs');
const path = require('path');
const { writeState, createInitialState, markStep } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io');
const NL = String.fromCharCode(10);
const dir = '$TMP_NODE/u14/wf';
fs.mkdirSync(dir, { recursive: true });
const upstreams = [['fullupstream-sess-14', '$DOWNSTREAM_CWD'], ['legacyupstream-sess-14', null]];
for (const [sid, cwd] of upstreams) {
  fs.writeFileSync(path.join(dir, sid + '-intent.md'), '**Title:** ' + sid + NL + 'Cross-check upstream, #2279.' + NL);
  writeState(sid, createInitialState(sid, { cwd, git_branch: 'feature/upstream' }));
  markStep(sid, 'workflow_init', 'complete');
  require('$SCRIPT_CHECKOUT_ROOT_NODE/tests/lib/plan-approval-fixture').approveLive(sid, 'clarify_intent'); // #2277
  markStep(sid, 'clarify_intent', 'complete');
  writeState('downstreamclone-' + sid, createInitialState('downstreamclone-' + sid, { cwd: '$DOWNSTREAM_CWD', git_branch: 'feature/upstream' }));
}
writeState('downstream-sess-14', createInitialState('downstream-sess-14', { cwd: '$DOWNSTREAM_CWD', git_branch: 'feature/upstream' }));
fs.writeFileSync(path.join(dir, 'stranger-sess-14-intent.md'), '**Title:** Stranger' + NL + 'Cross-check bystander, #2279.' + NL);
const encoded = String('$DOWNSTREAM_CWD').toLowerCase().replace(/[^a-zA-Z0-9]/g, '-');
const tdir = path.join('$TMP_NODE/u14/transcripts', encoded);
fs.mkdirSync(tdir, { recursive: true });
const rows = [JSON.stringify({ sessionId: 'downstream-sess-14', type: 'user' })];
for (const [sid] of upstreams) {
  rows.push(JSON.stringify({ sessionId: 'downstream-sess-14', attachment: { exitCode: 0, hookEvent: 'SessionStart', stdout: 'Current workflow session_id: ' + sid } }));
}
fs.writeFileSync(path.join(tdir, 'downstream-sess-14.jsonl'), rows.join(NL) + NL);
" >/dev/null 2>&1
}

run_U14() {
    require_module "$TARGET" || return 0
    local out
    _u14_fixture
    out="$(_u14_run "
$PRELUDE
const view = require('$SCRIPT_CHECKOUT_ROOT_NODE/bin/lib/resume-session/session-upstream-view.js');
const problems = [];
const merged = rows(search.listUpstreamCandidates({ downstreamSid: 'downstream-sess-14', ctx: { cwd: '$DOWNSTREAM_CWD', git_branch: 'feature/upstream' } }));
const grains = [];
for (const rec of merged) {
  if (rec.adoptable !== true) {
    if (rec.adoptable_granularity !== null) problems.push('non-adoptable-claims-grain:' + rec.sid);
    continue;
  }
  const v = view.buildUpstreamView({ downstreamSid: 'downstreamclone-' + rec.sid, upstreamSid: rec.sid });
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
if (grains.indexOf('fullupstream-sess-14=full') === -1) problems.push('no-full-rung:' + JSON.stringify(grains));
if (grains.indexOf('legacyupstream-sess-14=context-independent-only') === -1) problems.push('no-degraded-rung:' + JSON.stringify(grains));
if (merged.filter((x) => x.adoptable !== true).length === 0) problems.push('no-non-adoptable-record-in-fixture');
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "U14: on one shared fixture, every granularity --list advertises is the one --from's own decideGranularity ladder reaches — on both rungs, for the same upstreams"
    else
        fail "U14: expected 'OK', got '${out:-<err>}'"
    fi
}

# U15 — the downstream U14 never has: one whose ONLY recorded progress is
# session_start_context (no top-level cwd, no step_status event at all). U14
# hands the listing an explicit ctx, so the fallback `--from` relies on is never
# the input the listing is judged from; a `--list` reading only top-level
# state.cwd therefore loses this downstream's upstreams while `--from` adopts them
# happily. Detail plan S-9(e) step 7 / S-6a. One fixture, both paths.

_u15_run() {
    env -u CLAUDE_CODE_SESSION_ID \
        WORKFLOW_STATE_DIR="$TMP/u15/wf" WORKFLOW_PLANS_DIR="$TMP/u15/wf" \
        CLAUDE_TRANSCRIPT_BASE_DIR="$TMP/u15/transcripts" \
        HOME="$TMP/home" USERPROFILE="$TMP/home" \
        "$RWT" 60 node -e "$1" 2>&1
}

# createInitialState records the cwd under session_start_context and writes no
# top-level cwd, which is exactly the shape under test — so the downstream is left
# precisely as SessionStart made it, with no step ever marked.
_u15_fixture() {
    _u15_run "
const fs = require('fs');
const path = require('path');
const { writeState, createInitialState, markStep } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io');
const NL = String.fromCharCode(10);
const dir = '$TMP_NODE/u15/wf';
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(path.join(dir, 'sscupstream-sess-15-intent.md'), '**Title:** SSC upstream' + NL + 'session_start_context-only downstream, #2279.' + NL);
writeState('sscupstream-sess-15', createInitialState('sscupstream-sess-15', { cwd: '$DOWNSTREAM_CWD', git_branch: 'feature/upstream' }));
markStep('sscupstream-sess-15', 'workflow_init', 'complete');
require('$SCRIPT_CHECKOUT_ROOT_NODE/tests/lib/plan-approval-fixture').approveLive('sscupstream-sess-15', 'clarify_intent'); // #2277
markStep('sscupstream-sess-15', 'clarify_intent', 'complete');
writeState('sscdownstream-sess-15', createInitialState('sscdownstream-sess-15', { cwd: '$DOWNSTREAM_CWD', git_branch: 'feature/upstream' }));
const encoded = String('$DOWNSTREAM_CWD').toLowerCase().replace(/[^a-zA-Z0-9]/g, '-');
const tdir = path.join('$TMP_NODE/u15/transcripts', encoded);
fs.mkdirSync(tdir, { recursive: true });
const trows = [
  JSON.stringify({ sessionId: 'sscdownstream-sess-15', type: 'user' }),
  JSON.stringify({ sessionId: 'sscdownstream-sess-15', attachment: { exitCode: 0, hookEvent: 'SessionStart', stdout: 'Current workflow session_id: sscupstream-sess-15' } }),
];
fs.writeFileSync(path.join(tdir, 'sscdownstream-sess-15.jsonl'), trows.join(NL) + NL);
" >/dev/null 2>&1
}

run_U15() {
    require_module "$TARGET" || return 0
    local out
    _u15_fixture
    out="$(_u15_run "
$PRELUDE
const view = require('$SCRIPT_CHECKOUT_ROOT_NODE/bin/lib/resume-session/session-upstream-view.js');
const { readState } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io');
const { isAllPending } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/inheritance/adopt.js');
const problems = [];
// Fixture anchors: without them a passing verdict could be about an downstream that
// carries a top-level cwd (the shape already covered) or recorded steps.
// The RECORD on disk, not the projection: readState synthesizes a top-level
// cwd out of session_start_context, so only the raw file shows the shape.
let raw = null;
try { raw = JSON.parse(require('fs').readFileSync('$TMP_NODE/u15/wf/sscdownstream-sess-15.json', 'utf8')); }
catch (e) { problems.push('downstream-file-unreadable:' + e.message); }
if (raw && raw.cwd) problems.push('downstream-record-has-top-level-cwd:' + JSON.stringify(raw.cwd));
const downstream = readState('sscdownstream-sess-15');
if (!downstream) problems.push('downstream-state-missing');
else {
  if (!downstream.session_start_context || downstream.session_start_context.cwd !== '$DOWNSTREAM_CWD') {
    problems.push('downstream-session_start_context:' + JSON.stringify(downstream.session_start_context));
  }
  const stepEvents = ((downstream.events) || []).filter((e) => e && e.kind === 'step_status');
  if (stepEvents.length !== 0) problems.push('downstream-has-step-events:' + stepEvents.length);
  if (isAllPending(downstream) !== true) problems.push('downstream-not-adoptable-by-isAllPending');
}
// --list, given only the downstream SID: the ctx must come out of the same resolver
// --from uses, or the two paths are answering about different downstreams.
const ctx = view.downstreamContextOf({ downstreamSid: 'sscdownstream-sess-15' });
if (!ctx || ctx.cwd !== '$DOWNSTREAM_CWD') problems.push('downstream-ctx-not-resolved-from-session_start_context:' + JSON.stringify(ctx));
const merged = rows(search.listUpstreamCandidates({ downstreamSid: 'sscdownstream-sess-15', ctx }));
const rec = merged.find((x) => x.sid === 'sscupstream-sess-15');
if (!rec) problems.push('upstream-not-listed:' + JSON.stringify(merged.map((x) => x.sid)));
else {
  if ((rec.sources || []).indexOf('context') === -1) problems.push('upstream-not-found-by-the-context-route:' + JSON.stringify(rec.sources));
  if (rec.adoptable !== true) problems.push('list-says-not-adoptable:' + JSON.stringify(rec.adoptable_reason));
  if (rec.adoptable_granularity === null) problems.push('list-claims-no-granularity');
  // --from, on the very same downstream the listing was built for.
  const v = view.buildUpstreamView({ downstreamSid: 'sscdownstream-sess-15', upstreamSid: 'sscupstream-sess-15' });
  const ir = (v && v.inherit_result) || {};
  if (ir.attempted !== true || ir.ok !== true) problems.push('from-refused:' + JSON.stringify(ir.reason || ir.error));
  else if (ir.granularity !== rec.adoptable_granularity) {
    problems.push('list-vs-from:list=' + JSON.stringify(rec.adoptable_granularity) + ':from=' + JSON.stringify(ir.granularity));
  }
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "U15: an downstream whose only record is session_start_context is judged the same by both paths — --list finds the upstream through the context route at the grain --from then actually adopts it at"
    else
        fail "U15: expected 'OK', got '${out:-<err>}'"
    fi
}

# U16 — U15's question asked of the REAL CLI. Every case above calls
# downstreamContextOf() and listUpstreamCandidates() itself, so runList()'s own wiring
# in bin/resume-session-detect is asserted by nothing: drop the downstreamContextOf()
# call there, or pass the listing a ctx the --from path does not use, and U14/U15
# stay green while `--list` in a real session silently loses exactly the upstreams
# this downstream shape depends on. Spawned as a subprocess, the way the skill runs it.

_U16_CLI="$SCRIPT_CHECKOUT_ROOT/bin/resume-session-detect"

_u16_run() {
    env -u CLAUDE_CODE_SESSION_ID \
        WORKFLOW_STATE_DIR="$TMP/u16/wf" WORKFLOW_PLANS_DIR="$TMP/u16/wf" \
        CLAUDE_TRANSCRIPT_BASE_DIR="$TMP/u16/transcripts" \
        HOME="$TMP/home" USERPROFILE="$TMP/home" \
        "$RWT" 60 node -e "$1" 2>&1
}

# The CLI resolves its own downstream id, so it is named through the environment
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
fs.writeFileSync(path.join(dir, 'cliupstream-sess-16-intent.md'), '**Title:** CLI upstream' + NL + 'runList downstream-context wiring, #2279.' + NL);
writeState('cliupstream-sess-16', createInitialState('cliupstream-sess-16', { cwd: '$DOWNSTREAM_CWD', git_branch: 'feature/upstream' }));
markStep('cliupstream-sess-16', 'workflow_init', 'complete');
require('$SCRIPT_CHECKOUT_ROOT_NODE/tests/lib/plan-approval-fixture').approveLive('cliupstream-sess-16', 'clarify_intent'); // #2277
markStep('cliupstream-sess-16', 'clarify_intent', 'complete');
writeState('clidownstream-sess-16', createInitialState('clidownstream-sess-16', { cwd: '$DOWNSTREAM_CWD', git_branch: 'feature/upstream' }));
const encoded = String('$DOWNSTREAM_CWD').toLowerCase().replace(/[^a-zA-Z0-9]/g, '-');
const tdir = path.join('$TMP_NODE/u16/transcripts', encoded);
fs.mkdirSync(tdir, { recursive: true });
const trows = [
  JSON.stringify({ sessionId: 'clidownstream-sess-16', type: 'user' }),
  JSON.stringify({ sessionId: 'clidownstream-sess-16', attachment: { exitCode: 0, hookEvent: 'SessionStart', stdout: 'Current workflow session_id: cliupstream-sess-16' } }),
];
fs.writeFileSync(path.join(tdir, 'clidownstream-sess-16.jsonl'), trows.join(NL) + NL);
" >/dev/null 2>&1
}

run_U16() {
    require_module "$TARGET" || return 0
    local out
    _u16_fixture
    # --list first: --from ADOPTS into the downstream, so running it first would change
    # the very input the listing is judged from.
    _u16_cli clidownstream-sess-16 --list > "$TMP/u16/list.json"
    _u16_cli clidownstream-sess-16 --from cliupstream-sess-16 > "$TMP/u16/from.json"
    out="$(_u16_run "
const fs = require('fs');
const problems = [];
// Fixture anchor: the downstream must carry NO top-level cwd, or runList could reach
// the upstream without ever consulting session_start_context.
let raw = null;
try { raw = JSON.parse(fs.readFileSync('$TMP_NODE/u16/wf/clidownstream-sess-16.json', 'utf8')); }
catch (e) { problems.push('downstream-file-unreadable:' + e.message); }
if (raw && raw.cwd) problems.push('downstream-record-has-top-level-cwd:' + JSON.stringify(raw.cwd));
if (raw && (!raw.session_start_context || raw.session_start_context.git_branch !== 'feature/upstream')) {
  problems.push('downstream-session_start_context-branch:' + JSON.stringify(raw && raw.session_start_context));
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
  const rec = (list.candidates || []).find((x) => x.sid === 'cliupstream-sess-16');
  if (!rec) problems.push('cli-list-lost-the-upstream:' + JSON.stringify(ids));
  else {
    if ((rec.sources || []).indexOf('context') === -1) problems.push('upstream-not-found-by-the-context-route:' + JSON.stringify(rec.sources));
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
        pass "U16: the real 'resume-session-detect --list' subprocess offers a session_start_context-only downstream's upstream as adoptable, at the same granularity the real --from subprocess then adopts it at"
    else
        fail "U16: expected 'OK', got '${out:-<err>}'"
    fi
}
