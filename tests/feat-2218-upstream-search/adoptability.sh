# adoptability.sh — U7-U13: what a listed record CLAIMS about adoptability vs
# what `--from` would actually manage. Sourced by feat-2218-upstream-search.sh.
# Tests: hooks/workflow-state/upstream-search.js, bin/lib/resume-session/upstream-view.js
# Tags: session-upstream, upstream-search, resume-session, adoptability, cost-cap, regression-2279, scope:issue-specific, pwsh-not-required, TL2

# #2279's secondary finding: `--list` answers adoptable yes/no, but `--from`
# answers at a finer grain and silently degrades, so a user picks from the list
# and gets less than it implied. The listing must carry the granularity the
# `--from` path would reach (CPR-E2E). U10-U12 fence the cost of saying so.

# U7 — the field itself. Every record, adoptable or not, must state how much
# would travel; a record that omits it cannot be cross-checked at all.
run_U7() {
    require_module "$TARGET" || return 0
    local out
    out="$(run_case "
$PRELUDE
const problems = [];
const merged = rows(search.listUpstreamCandidates({ heirSid: 'heir-sess-99', ctx: { cwd: '$HEIR_CWD', git_branch: 'feature/donor' } }));
if (merged.length === 0) problems.push('fixture-produced-no-records');
for (const rec of merged) {
  if (!Object.prototype.hasOwnProperty.call(rec, 'adoptable_granularity')) {
    problems.push('missing-adoptable_granularity:' + rec.sid);
    continue;
  }
  const g = rec.adoptable_granularity;
  if (g !== null && g !== 'full' && g !== 'context-independent-only') {
    problems.push('out-of-vocabulary:' + rec.sid + ':' + JSON.stringify(g));
  }
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "U7: every listed record states its adoptable_granularity (full / context-independent-only / null)"
    else
        fail "U7: expected 'OK', got '${out:-<err>}'"
    fi
}

# U8 — the positive claim. The context candidate ran in the heir's own cwd, so
# decideGranularity would return `full`; anything less understates the offer.
run_U8() {
    require_module "$TARGET" || return 0
    local out
    out="$(run_case "
$PRELUDE
const problems = [];
const merged = rows(search.listUpstreamCandidates({ heirSid: 'heir-sess-99', ctx: { cwd: '$HEIR_CWD', git_branch: 'feature/donor' } }));
const rec = merged.find((x) => x.sid === 'ctxdonor-sess-04');
if (!rec) problems.push('context-candidate-missing');
else {
  if (rec.adoptable !== true) problems.push('context-candidate-not-adoptable');
  if (rec.adoptable_granularity !== 'full') problems.push('granularity:' + JSON.stringify(rec.adoptable_granularity));
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "U8: a same-cwd context candidate is offered at full granularity, the grain --from would actually reach"
    else
        fail "U8: expected 'OK', got '${out:-<err>}'"
    fi
}

# U9 — the negative claim, paired with U8 (CPR-ORTH). A search-only hit has no
# evidence it may be adopted at all, so the honest granularity is null — not a
# missing field the caller has to interpret, and not a guess.
run_U9() {
    require_module "$TARGET" || return 0
    local out
    out="$(run_case "
$PRELUDE
const problems = [];
const merged = rows(search.listUpstreamCandidates({ heirSid: 'heir-sess-99', ctx: { cwd: '$HEIR_CWD', git_branch: 'feature/donor' } }));
const searchOnly = merged.filter((x) => x.adoptable === false);
if (searchOnly.length === 0) problems.push('no-search-only-records-in-fixture');
for (const rec of searchOnly) {
  if (rec.adoptable_granularity !== null) problems.push('non-null-granularity:' + rec.sid + ':' + JSON.stringify(rec.adoptable_granularity));
  if (typeof rec.adoptable_reason !== 'string' || rec.adoptable_reason.length === 0) {
    problems.push('no-reason:' + rec.sid);
  }
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "U9: a search-only record reports null granularity alongside its adoptable_reason (no unexplained refusal, no implied offer)"
    else
        fail "U9: expected 'OK', got '${out:-<err>}'"
    fi
}

# U10 — no context, no claim. Called without an heir context there is nothing to
# judge adoptability against, so every record must fall back to search-only.
run_U10() {
    require_module "$TARGET" || return 0
    local out
    out="$(run_case "
$PRELUDE
const problems = [];
const merged = rows(search.listUpstreamCandidates({ heirSid: 'heir-sess-99', ctx: null }));
for (const rec of merged) {
  if (rec.adoptable === true) problems.push('adoptable-claimed-without-context:' + rec.sid);
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "U10: a context-less listing claims nothing adoptable — the adoptability question has no evidence to answer it"
    else
        fail "U10: expected 'OK', got '${out:-<err>}'"
    fi
}

# U11 — the cost cap under a QUERY. U6 caps the query-less listing; a query is
# the path a user actually takes, and an uncapped one walks the whole PLANS_DIR
# (667 files in the real store) into the model's context.
run_U11() {
    require_module "$TARGET" || return 0
    local out
    out="$(run_case "
$PRELUDE
const problems = [];
const merged = rows(search.listUpstreamCandidates({ heirSid: 'heir-sess-99', ctx: { cwd: '$HEIR_CWD', git_branch: 'feature/donor' }, query: 'sess' }));
const searchOnly = merged.filter((x) => x.adoptable === false);
if (searchOnly.length > search.SEARCH_ONLY_CAP) {
  problems.push('query-listing-uncapped:' + searchOnly.length + '>' + search.SEARCH_ONLY_CAP);
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "U11: a query listing caps its search-only section at SEARCH_ONLY_CAP too, not just the query-less one"
    else
        fail "U11: expected 'OK', got '${out:-<err>}'"
    fi
}

# U12 — the cap is a published constant, so renderer and tests read the same
# number instead of each hard-coding 10 (CPR-SSOT).
run_U12() {
    require_module "$TARGET" || return 0
    local out
    out="$(run_case "
$PRELUDE
const problems = [];
if (typeof search.SEARCH_ONLY_CAP !== 'number') problems.push('cap-not-exported:' + typeof search.SEARCH_ONLY_CAP);
else if (search.SEARCH_ONLY_CAP !== 10) problems.push('cap-moved:' + search.SEARCH_ONLY_CAP);
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "U12: SEARCH_ONLY_CAP is exported and still 10 — callers read the constant rather than copying the number"
    else
        fail "U12: expected 'OK', got '${out:-<err>}'"
    fi
}

# U13 — the MIDDLE value. U8 pins `full` and U9 pins `null`, so a constant
# expression (`adoptable ? 'full' : null`) satisfies both while never once
# reaching decideGranularity. The donor here is adoptable — its recorded branch
# matches, so the context guard admits it — but it records no cwd, which is the
# input that makes decideGranularity degrade. The listing must say so, because
# `--from` on this donor really will hand over less than the whole state.
#
# Its own store: adding a second context candidate to the shared fixture would
# move U5/U6's leading record.
_u13_run() {
    env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        CLAUDE_WORKFLOW_DIR="$TMP/u13/wf" WORKFLOW_PLANS_DIR="$TMP/u13/wf" \
        CLAUDE_TRANSCRIPT_BASE_DIR="$TMP/u13/transcripts" \
        HOME="$TMP/home" USERPROFILE="$TMP/home" \
        "$RWT" 60 node -e "$1" 2>&1
}

_u13_fixture() {
    _u13_run "
const fs = require('fs');
const path = require('path');
const { writeState, createInitialState, markStep } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const NL = String.fromCharCode(10);
const dir = '$TMP_NODE/u13/wf';
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(path.join(dir, 'legacydonor-sess-13-intent.md'), '**Title:** Legacy donor' + NL + 'Granularity, #2218.' + NL);
writeState('legacydonor-sess-13', createInitialState('legacydonor-sess-13', { cwd: null, git_branch: 'feature/donor' }));
markStep('legacydonor-sess-13', 'workflow_init', 'complete');
markStep('legacydonor-sess-13', 'clarify_intent', 'complete');
const encoded = String('$HEIR_CWD').toLowerCase().replace(/[^a-zA-Z0-9]/g, '-');
const tdir = path.join('$TMP_NODE/u13/transcripts', encoded);
fs.mkdirSync(tdir, { recursive: true });
const rows = [
  JSON.stringify({ sessionId: 'heir-sess-99', type: 'user' }),
  JSON.stringify({ sessionId: 'heir-sess-99', attachment: { exitCode: 0, hookEvent: 'SessionStart', stdout: 'Current workflow session_id: legacydonor-sess-13' } }),
];
fs.writeFileSync(path.join(tdir, 'heir-sess-99.jsonl'), rows.join(NL) + NL);
" >/dev/null 2>&1
}

run_U13() {
    require_module "$TARGET" || return 0
    local out
    _u13_fixture
    out="$(_u13_run "
$PRELUDE
const problems = [];
const merged = rows(search.listUpstreamCandidates({ heirSid: 'heir-sess-99', ctx: { cwd: '$HEIR_CWD', git_branch: 'feature/donor' } }));
const rec = merged.find((x) => x.sid === 'legacydonor-sess-13');
if (!rec) problems.push('cwd-less-donor-not-listed:' + JSON.stringify(merged.map((x) => x.sid)));
else {
  if (rec.adoptable !== true) problems.push('donor-not-adoptable:' + String(rec.adoptable));
  if (rec.adoptable_granularity !== 'context-independent-only') {
    problems.push('granularity:' + JSON.stringify(rec.adoptable_granularity));
  }
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "U13: an adoptable donor whose recorded context would degrade the adoption is listed as context-independent-only, not as full"
    else
        fail "U13: expected 'OK', got '${out:-<err>}'"
    fi
}

# U17 — the DEGRADABLE resumability reason, the one rung U8/U9/U13 never reach.
# `intent-artifact-missing` is the single member of adopt.js's
# DEGRADABLE_RESUMABILITY_REASONS: `--from` does not refuse such a donor, it
# hands it over at context-independent-only. The listing asks the same donor a
# coarser question (eligible yes/no) through candidates.js, so the two paths can
# disagree about whether the donor may be adopted at all — and SKILL.md Step 2
# tells the user "only records with adoptable: true can carry state", which is
# then false for this donor. Asserted as a biconditional: whichever way the two
# paths are made to agree, they must agree.
_u17_run() {
    env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_ENV_FILE \
        CLAUDE_WORKFLOW_DIR="$TMP/u17/wf" WORKFLOW_PLANS_DIR="$TMP/u17/wf" \
        CLAUDE_TRANSCRIPT_BASE_DIR="$TMP/u17/transcripts" \
        HOME="$TMP/home" USERPROFILE="$TMP/home" \
        "$RWT" 60 node -e "$1" 2>&1
}

# clarify_intent genuinely settled but no <sid>-intent.md on disk — the exact
# input evaluateResumability answers `intent-artifact-missing` for. An
# outline.md is written so the donor is still reachable by the search generator,
# which keeps "did the listing drop it?" distinguishable from "was it ever
# indexed at all?".
_u17_fixture() {
    _u17_run "
const fs = require('fs');
const path = require('path');
const { writeState, createInitialState, markStep } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const NL = String.fromCharCode(10);
const dir = '$TMP_NODE/u17/wf';
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(path.join(dir, 'iamdonor-sess-17-outline.md'), '**Title:** Intent-artifact-missing donor' + NL + 'Degradable resumability reason, #2279.' + NL);
writeState('iamdonor-sess-17', createInitialState('iamdonor-sess-17', { cwd: '$HEIR_CWD', git_branch: 'feature/donor' }));
markStep('iamdonor-sess-17', 'workflow_init', 'complete');
markStep('iamdonor-sess-17', 'clarify_intent', 'complete');
writeState('iamheir-sess-17', createInitialState('iamheir-sess-17', { cwd: '$HEIR_CWD', git_branch: 'feature/donor' }));
const encoded = String('$HEIR_CWD').toLowerCase().replace(/[^a-zA-Z0-9]/g, '-');
const tdir = path.join('$TMP_NODE/u17/transcripts', encoded);
fs.mkdirSync(tdir, { recursive: true });
const trows = [
  JSON.stringify({ sessionId: 'iamheir-sess-17', type: 'user' }),
  JSON.stringify({ sessionId: 'iamheir-sess-17', attachment: { exitCode: 0, hookEvent: 'SessionStart', stdout: 'Current workflow session_id: iamdonor-sess-17' } }),
];
fs.writeFileSync(path.join(tdir, 'iamheir-sess-17.jsonl'), trows.join(NL) + NL);
" >/dev/null 2>&1
}

run_U17() {
    require_module "$TARGET" || return 0
    local out
    _u17_fixture
    out="$(_u17_run "
$PRELUDE
const view = require('$AGENTS_DIR_NODE/bin/lib/resume-session/upstream-view.js');
const { readState } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const { evaluateResumability } = require('$AGENTS_DIR_NODE/hooks/workflow-state/effective-state.js');
const problems = [];
// Fixture anchor: without it a passing verdict could be about any other donor
// shape, and the degradable reason would never have been exercised.
const verdict = evaluateResumability(readState('iamdonor-sess-17'));
if (!verdict || verdict.reason !== 'intent-artifact-missing') {
  problems.push('fixture-is-not-the-intent-artifact-missing-condition:' + JSON.stringify(verdict));
}
const ctx = view.heirContextOf({ heirSid: 'iamheir-sess-17' });
const merged = rows(search.listUpstreamCandidates({ heirSid: 'iamheir-sess-17', ctx }));
const rec = merged.find((x) => x.sid === 'iamdonor-sess-17') || null;
const listOffers = !!rec && rec.adoptable === true;
const v = view.buildUpstreamView({ heirSid: 'iamheir-sess-17', upstreamSid: 'iamdonor-sess-17' });
const ir = (v && v.inherit_result) || {};
const fromAdopts = ir.attempted === true && ir.ok === true;
if (listOffers !== fromAdopts) {
  problems.push('list-vs-from-disagree:list-offers=' + String(listOffers) +
    ':from-adopts=' + String(fromAdopts) +
    ':list-reason=' + JSON.stringify(rec && rec.adoptable_reason) +
    ':from-granularity=' + JSON.stringify(ir.granularity) +
    ':from-degraded_reason=' + JSON.stringify(ir.degraded_reason));
}
if (fromAdopts) {
  if (ir.granularity !== 'context-independent-only') problems.push('from-granularity:' + JSON.stringify(ir.granularity));
  if (ir.degraded_reason !== 'intent-artifact-missing') problems.push('from-degraded_reason:' + JSON.stringify(ir.degraded_reason));
}
if (listOffers && rec.adoptable_granularity !== 'context-independent-only') {
  problems.push('list-granularity:' + JSON.stringify(rec.adoptable_granularity));
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "U17: a donor whose only defect is a missing intent artifact is offered by --list exactly when --from adopts it, and at the degraded grain --from actually hands over"
    else
        fail "U17: expected 'OK', got '${out:-<err>}'"
    fi
}

# U18 — the SEARCH-ONLY donor `--from` would nonetheless adopt. U9 pins every
# search-only record at adoptable:false and U14-U16 cross-check only donors the
# CONTEXT route already found, so the one population where the paths can disagree
# is untested: reachable by artifact search alone (nothing announces it), yet its
# state records this heir's cwd/branch and is resumable. upstream-search.js's
# header fixes the direction — a search hit may never invite an adoption the
# workflow then refuses — so through the real CLI: never over-promise, explain
# the conservative refusal, and keep `--from` an escape hatch at a stated grain.
_U18_CLI="$AGENTS_DIR/bin/resume-session-detect"

_u18_run() {
    env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_ENV_FILE \
        CLAUDE_WORKFLOW_DIR="$TMP/u18/wf" WORKFLOW_PLANS_DIR="$TMP/u18/wf" \
        CLAUDE_TRANSCRIPT_BASE_DIR="$TMP/u18/transcripts" \
        HOME="$TMP/home" USERPROFILE="$TMP/home" \
        "$RWT" 60 node -e "$1" 2>&1
}

_u18_cli() {
    local sid="$1"
    shift
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_ENV_FILE \
        CLAUDE_SESSION_ID="$sid" \
        CLAUDE_WORKFLOW_DIR="$TMP/u18/wf" WORKFLOW_PLANS_DIR="$TMP/u18/wf" \
        CLAUDE_TRANSCRIPT_BASE_DIR="$TMP/u18/transcripts" \
        HOME="$TMP/home" USERPROFILE="$TMP/home" \
        "$RWT" 60 node "$_U18_CLI" "$@" 2>/dev/null
}

# The transcript directory is created EMPTY on purpose: that is what removes the
# donor from the lineage/context generator while leaving its intent.md indexed.
_u18_fixture() {
    _u18_run "
const fs = require('fs');
const path = require('path');
const { writeState, createInitialState, markStep } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const NL = String.fromCharCode(10);
const dir = '$TMP_NODE/u18/wf';
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(path.join(dir, 'searchonly-sess-18-intent.md'), '**Title:** Search-only donor' + NL + 'Adoptable but unannounced, #2279.' + NL);
writeState('searchonly-sess-18', createInitialState('searchonly-sess-18', { cwd: '$HEIR_CWD', git_branch: 'feature/donor' }));
markStep('searchonly-sess-18', 'workflow_init', 'complete');
markStep('searchonly-sess-18', 'clarify_intent', 'complete');
writeState('soheir-sess-18', createInitialState('soheir-sess-18', { cwd: '$HEIR_CWD', git_branch: 'feature/donor' }));
const encoded = String('$HEIR_CWD').toLowerCase().replace(/[^a-zA-Z0-9]/g, '-');
fs.mkdirSync(path.join('$TMP_NODE/u18/transcripts', encoded), { recursive: true });
" >/dev/null 2>&1
}

run_U18() {
    require_module "$TARGET" || return 0
    local out
    _u18_fixture
    # --list first: --from ADOPTS into the heir, so the listing must be taken
    # while the heir is still the untouched shell the listing describes.
    _u18_cli soheir-sess-18 --list > "$TMP/u18/list.json"
    _u18_cli soheir-sess-18 --from searchonly-sess-18 > "$TMP/u18/from.json"
    local from_rc=$?
    out="$(_u18_run "
const fs = require('fs');
const problems = [];
let list = null;
let from = null;
try { list = JSON.parse(fs.readFileSync('$TMP_NODE/u18/list.json', 'utf8')); }
catch (e) { problems.push('cli-list-emitted-no-json:' + e.message); }
try { from = JSON.parse(fs.readFileSync('$TMP_NODE/u18/from.json', 'utf8')); }
catch (e) { problems.push('cli-from-emitted-no-json:' + e.message); }
const rec = list ? (list.candidates || []).find((x) => x.sid === 'searchonly-sess-18') : null;
if (list && !rec) problems.push('donor-not-listed-at-all:' + JSON.stringify((list.candidates || []).map((x) => x.sid)));
// Fixture anchor: the donor must be reachable by the SEARCH generator only, or
// this is just another restatement of U16.
if (rec && (rec.sources || []).join(',') !== 'search') {
  problems.push('donor-was-found-by-the-context-route-too:' + JSON.stringify(rec.sources));
}
const ir = (from && from.inherit_result) || {};
const fromAdopts = ir.attempted === true && ir.ok === true;
// The escape hatch: --from must really adopt this donor, at a stated grain.
if (!fromAdopts) problems.push('from-refused-the-search-only-donor:' + JSON.stringify(ir.error || ir.reason));
else if (ir.granularity !== 'full') problems.push('from-granularity:' + JSON.stringify(ir.granularity));
if (rec) {
  // Never over-promise: a listing may only claim adoptable when --from delivers.
  if (rec.adoptable === true && !fromAdopts) problems.push('list-over-promised-adoptable');
  if (rec.adoptable === true && rec.adoptable_granularity !== ir.granularity) {
    problems.push('list-over-promised-grain:list=' + JSON.stringify(rec.adoptable_granularity) + ':from=' + JSON.stringify(ir.granularity));
  }
  // The deliberate under-promise must be EXPLAINED and carry no grain it did
  // not earn (upstream-search.js SEARCH_ONLY_REASON).
  if (rec.adoptable === false) {
    if (String(rec.adoptable_reason || '').indexOf('search-result-only') === -1) {
      problems.push('unexplained-refusal:' + JSON.stringify(rec.adoptable_reason));
    }
    if (rec.adoptable_granularity !== null) problems.push('non-adoptable-claims-grain:' + JSON.stringify(rec.adoptable_granularity));
  }
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ] && [ "$from_rc" -eq 0 ]; then
        pass "U18: a donor reachable by artifact search alone is never advertised as more adoptable than --from delivers, states the search-only reason for the gap, and is still adopted at full granularity when --from is asked directly"
    else
        fail "U18: expected 'OK' and --from exit 0, got '${out:-<err>}' (--from exit $from_rc)"
    fi
}
