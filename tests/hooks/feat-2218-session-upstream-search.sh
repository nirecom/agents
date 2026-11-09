#!/usr/bin/env bash
# tests/hooks/feat-2218-session-upstream-search.sh
# Tests: hooks/workflow-state/session-upstream-search.js, hooks/workflow-state/inheritance/candidates.js
# Tags: session-upstream, upstream-search, resume-session, plans-dir, dedup, regression-2218, scope:issue-specific, pwsh-not-required, TL2, test-lang-exception:e2e

# Issue #2218 Step 7 — two generators answer two different questions. Generator 1 ("can I adopt this here?") is left untouched and keeps owning the eligibility claim; generator 2 ("which sid was that?") reaches across PLANS_DIR with no cwd and no state file. The merge layer presents both and re-implements neither, so a record can never claim adoptable on generator 2's evidence.

# TL3 gap: the /resume-session --list rendering, and the skill-side LLM re-ranking of the shortlist, are not exercised here; neither is search latency against a real 667-file PLANS_DIR. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: workflow-state.

# TDD (write_code has not run): every case is expected to FAIL with "MODULE NOT FOUND: hooks/workflow-state/session-upstream-search.js".

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"

# pass/fail, make_tmp and the case markers. Loaded before $TMP is
# assigned: the harness pins TMP/TEMP/TMPDIR into its run root.
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

SCRIPT_CHECKOUT_ROOT_NODE="$(node_path "$SCRIPT_CHECKOUT_ROOT")"

TARGET="hooks/workflow-state/session-upstream-search.js"
DOWNSTREAM_CWD="/fixture/downstream/repo"

require_module() {
    if [ -f "$SCRIPT_CHECKOUT_ROOT/$1" ]; then return 0; fi
    fail "MODULE NOT FOUND: $1 — expected per issue #2218 Step 7, not yet implemented (write_code has not run)"
    return 1
}

TMP="$(make_tmp)"
TMP_NODE="$(node_path "$TMP")"
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT
# isolation (#2512): pin state and plans dirs file-wide under $TMP; the per-call pins below still override them.
mkdir -p "$TMP/isolation/workflow-state" "$TMP/isolation/plans"
export WORKFLOW_STATE_DIR="$TMP/isolation/workflow-state" WORKFLOW_PLANS_DIR="$TMP/isolation/plans"

# The fixture PLANS_DIR. Four upstream sessions, each covering one search key,
# plus 12 filler sessions so the "at most 10" cap on the reachable-only section
# is observable. alpha carries a `**Title:**` line, beta deliberately does not
# (only 108 of 667 real intent.md files have one — M4).
build_fixture() {
    env -u CLAUDE_CODE_SESSION_ID \
        WORKFLOW_STATE_DIR="$TMP/wf" WORKFLOW_PLANS_DIR="$TMP/wf" \
        CLAUDE_TRANSCRIPT_BASE_DIR="$TMP/transcripts" \
        HOME="$TMP/home" USERPROFILE="$TMP/home" \
        "$RWT" 60 node -e "
const fs = require('fs');
const path = require('path');
const { writeState, createInitialState, markStep } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io');
const dir = '$TMP_NODE/wf';
fs.mkdirSync(dir, { recursive: true });
const w = (name, body, ageMinutes) => {
  const p = path.join(dir, name);
  fs.writeFileSync(p, body);
  const t = new Date(Date.now() - ageMinutes * 60000);
  fs.utimesSync(p, t, t);
};
w('alpha-sess-01-intent.md', '**Title:** Handoff artifact schema' + String.fromCharCode(10) + 'Closes #2218. Defines the artifact grammar.' + String.fromCharCode(10), 30);
w('beta-sess-02-intent.md', 'Investigate #1305 and the inheritance granularity regression.' + String.fromCharCode(10), 20);
w('gamma-sess-03-intent.md', '**Title:** Gamma' + String.fromCharCode(10) + 'Unrelated work on #999.' + String.fromCharCode(10), 40);
w('gamma-sess-03-outline.md', 'outline body' + String.fromCharCode(10), 40);
w('gamma-sess-03-detail.md', 'detail body' + String.fromCharCode(10), 40);
w('gamma-sess-03-handoff.md', 'handoff_schema_version: 1' + String.fromCharCode(10), 40);
w('ctxupstream-sess-04-intent.md', '**Title:** Upstream' + String.fromCharCode(10) + 'Also about inheritance granularity, #2218.' + String.fromCharCode(10), 10);
for (let i = 0; i < 12; i++) {
  const n = String(100 + i);
  w('pad-sess-' + n + '-intent.md', 'padding session about granularity number ' + n + String.fromCharCode(10), 60 + i);
}
writeState('ctxupstream-sess-04', createInitialState('ctxupstream-sess-04', { cwd: '$DOWNSTREAM_CWD', git_branch: 'feature/upstream' }));
markStep('ctxupstream-sess-04', 'workflow_init', 'complete');
require('$SCRIPT_CHECKOUT_ROOT_NODE/tests/lib/plan-approval-fixture').approveLive('ctxupstream-sess-04', 'clarify_intent'); // #2277
markStep('ctxupstream-sess-04', 'clarify_intent', 'complete');
const encoded = String('$DOWNSTREAM_CWD').toLowerCase().replace(/[^a-zA-Z0-9]/g, '-');
const tdir = path.join('$TMP_NODE/transcripts', encoded);
fs.mkdirSync(tdir, { recursive: true });
const rows = [
  JSON.stringify({ sessionId: 'downstream-sess-99', type: 'user' }),
  JSON.stringify({ sessionId: 'downstream-sess-99', attachment: { exitCode: 0, hookEvent: 'SessionStart', stdout: 'Current workflow session_id: ctxupstream-sess-04' } }),
];
fs.writeFileSync(path.join(tdir, 'downstream-sess-99.jsonl'), rows.join(String.fromCharCode(10)) + String.fromCharCode(10));
" >/dev/null 2>&1
}

run_case() {
    env -u CLAUDE_CODE_SESSION_ID \
        WORKFLOW_STATE_DIR="$TMP/wf" WORKFLOW_PLANS_DIR="$TMP/wf" \
        CLAUDE_TRANSCRIPT_BASE_DIR="$TMP/transcripts" \
        HOME="$TMP/home" USERPROFILE="$TMP/home" \
        "$RWT" 60 node -e "$1" 2>&1
}

# Shared helper: normalize whatever container the search returns (array, or an
# object with a records/results array) to a plain array of records.
PRELUDE="
const search = require('$SCRIPT_CHECKOUT_ROOT_NODE/$TARGET');
function rows(r) {
  if (Array.isArray(r)) return r;
  if (r && Array.isArray(r.records)) return r.records;
  if (r && Array.isArray(r.results)) return r.results;
  return [];
}
function sids(r) { return rows(r).map((x) => x.sid); }
function matched(rec) { return (rec && Array.isArray(rec.matched_on)) ? rec.matched_on.join(',') : ''; }
"

# U1 — sid substring. The cheapest key and the one a user actually has: half a
# session id copied out of an old message.
run_U1() {
    require_module "$TARGET" || return 0
    local out
    out="$(run_case "
$PRELUDE
const problems = [];
const r = search.searchUpstreamSessions('beta-sess', {});
const found = sids(r);
if (found.indexOf('beta-sess-02') === -1) problems.push('beta-not-found:' + JSON.stringify(found));
if (found.indexOf('alpha-sess-01') !== -1) problems.push('unrelated-sid-matched');
const rec = rows(r).find((x) => x.sid === 'beta-sess-02');
if (rec && !/sid/.test(matched(rec))) problems.push('matched_on-does-not-name-the-sid-key:' + matched(rec));
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "U1: a partial sid reaches the session and matched_on names the sid key"
    else
        fail "U1: expected 'OK', got '${out:-<err>}'"
    fi
}

# U2 — issue number. Read out of the intent.md body, not out of state's
# closes_issues (only 28 of 667 sessions have it — M3).
run_U2() {
    require_module "$TARGET" || return 0
    local out
    out="$(run_case "
$PRELUDE
const problems = [];
const r = search.searchUpstreamSessions('#1305', {});
const found = sids(r);
if (found.indexOf('beta-sess-02') === -1) problems.push('issue-ref-not-found:' + JSON.stringify(found));
const rec = rows(r).find((x) => x.sid === 'beta-sess-02');
if (rec) {
  if (!/issue/.test(matched(rec))) problems.push('matched_on-does-not-name-the-issue-key:' + matched(rec));
  const issues = (rec.issues || []).map(String);
  if (issues.indexOf('1305') === -1) problems.push('issues-field:' + JSON.stringify(rec.issues));
}
const bare = sids(search.searchUpstreamSessions('1305', {}));
if (bare.indexOf('beta-sess-02') === -1) problems.push('bare-number-not-found:' + JSON.stringify(bare));
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "U2: an issue number reaches the session with or without the leading '#'"
    else
        fail "U2: expected 'OK', got '${out:-<err>}'"
    fi
}

# U3 — free keyword, and the Title-independence that M4 forces: beta's
# intent.md has no `**Title:**` line at all and must still be reachable.
run_U3() {
    require_module "$TARGET" || return 0
    local out
    out="$(run_case "
$PRELUDE
const problems = [];
const found = sids(search.searchUpstreamSessions('inheritance granularity', {}));
if (found.indexOf('beta-sess-02') === -1) problems.push('title-less-intent-not-reachable:' + JSON.stringify(found));
const rec = rows(search.searchUpstreamSessions('inheritance granularity', {})).find((x) => x.sid === 'beta-sess-02');
if (rec && rec.title !== null && typeof rec.title !== 'string') problems.push('title-field-shape:' + JSON.stringify(rec.title));
const none = sids(search.searchUpstreamSessions('zzz-no-such-token', {}));
if (none.length !== 0) problems.push('non-matching-query-returned:' + JSON.stringify(none));
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "U3: full-text keyword search works on an intent.md with no **Title:** line"
    else
        fail "U3: expected 'OK', got '${out:-<err>}'"
    fi
}

# U4 — the common record shape. Both generators normalize into it before the
# presentation layer sees anything, and generator 2 must never claim adoptable.
run_U4() {
    require_module "$TARGET" || return 0
    local out
    out="$(run_case "
$PRELUDE
const problems = [];
const KEYS = ['sid', 'adoptable', 'adoptable_reason', 'git_branch', 'cwd', 'last_activity', 'last_activity_source', 'matched_on', 'issues', 'title', 'artifacts', 'sources'];
const r = rows(search.searchUpstreamSessions('gamma', {}));
const rec = r.find((x) => x.sid === 'gamma-sess-03');
if (!rec) problems.push('gamma-not-found:' + JSON.stringify(sids(r)));
else {
  for (const k of KEYS) if (!(k in rec)) problems.push('missing-key:' + k);
  if (rec.adoptable !== false) problems.push('search-only-record-claims-adoptable:' + String(rec.adoptable));
  if (typeof rec.adoptable_reason !== 'string' || rec.adoptable_reason.length === 0) problems.push('adoptable_reason:' + JSON.stringify(rec.adoptable_reason));
  const a = rec.artifacts || {};
  for (const k of ['intent', 'outline', 'detail']) {
    if (!(k in a)) problems.push('artifacts-missing-key:' + k);
    else if (typeof a[k] !== 'string' || a[k].length === 0) problems.push('artifact-path-not-set:' + k + '=' + JSON.stringify(a[k]));
  }
  if ('handoff' in a) problems.push('handoff-is-still-an-artifact-kind:' + JSON.stringify(a.handoff));
  if (!rec.last_activity) problems.push('no-last_activity');
  if (typeof rec.last_activity_source !== 'string' || rec.last_activity_source.length === 0) problems.push('last_activity_source:' + JSON.stringify(rec.last_activity_source));
  if ((rec.sources || []).join(',') !== 'search') problems.push('sources:' + JSON.stringify(rec.sources));
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "U4: every record carries the 12-field shape, names its three plan artifacts (no handoff kind), and never claims adoptable from search evidence"
    else
        fail "U4: expected 'OK', got '${out:-<err>}'"
    fi
}

# U5 — merge. ctxupstream-sess-04 is reachable by BOTH generators; it must appear
# once, carry both sources, and sort ahead of the search-only hits because it is
# the only one the workflow would actually let you adopt.
run_U5() {
    require_module "$TARGET" || return 0
    local out
    out="$(run_case "
$PRELUDE
const problems = [];
const merged = rows(search.listUpstreamCandidates({ downstreamSid: 'downstream-sess-99', ctx: { cwd: '$DOWNSTREAM_CWD', git_branch: 'feature/upstream' }, query: 'granularity', limit: 20 }));
const ids = merged.map((x) => x.sid);
const dupes = ids.filter((s, i) => ids.indexOf(s) !== i);
if (dupes.length) problems.push('duplicate-sids:' + dupes.join(','));
const upstream = merged.find((x) => x.sid === 'ctxupstream-sess-04');
if (!upstream) problems.push('upstream-absent:' + JSON.stringify(ids));
else {
  if (upstream.sources.slice().sort().join(',') !== 'context,search') problems.push('sources:' + JSON.stringify(upstream.sources));
  if (upstream.adoptable !== true) problems.push('context-candidate-not-adoptable:' + String(upstream.adoptable));
  if (ids[0] !== 'ctxupstream-sess-04') problems.push('adoptable-not-first:' + JSON.stringify(ids.slice(0, 3)));
}
const searchOnly = merged.filter((x) => x.adoptable === false).map((x) => x.last_activity);
for (let i = 1; i < searchOnly.length; i++) {
  if (String(searchOnly[i - 1]) < String(searchOnly[i])) { problems.push('last_activity-not-descending:' + JSON.stringify(searchOnly)); break; }
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "U5: a sid found by both generators collapses to one record, sources ['context','search'], adoptable first then last_activity desc"
    else
        fail "U5: expected 'OK', got '${out:-<err>}'"
    fi
}

# U6 — the no-query shape. Without a query generator 1 leads and generator 2 is
# a bounded appendix (at most 10), so `--list` never turns into a dump of every
# session that ever ran on this machine.
run_U6() {
    require_module "$TARGET" || return 0
    local out
    out="$(run_case "
$PRELUDE
const problems = [];
const merged = rows(search.listUpstreamCandidates({ downstreamSid: 'downstream-sess-99', ctx: { cwd: '$DOWNSTREAM_CWD', git_branch: 'feature/upstream' } }));
const ids = merged.map((x) => x.sid);
if (ids.indexOf('ctxupstream-sess-04') === -1) problems.push('context-candidate-missing:' + JSON.stringify(ids));
if (ids[0] !== 'ctxupstream-sess-04') problems.push('context-candidate-not-leading:' + JSON.stringify(ids.slice(0, 3)));
const reachable = merged.filter((x) => x.adoptable === false);
if (reachable.length !== 10) problems.push('reachable-section-not-capped-at-10:' + reachable.length);
for (const rec of reachable) {
  if (matched(rec) !== '') problems.push('matched_on-set-without-a-query:' + rec.sid + ':' + matched(rec));
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "U6: query-less listing leads with the adoptable candidate and caps the reachable-only section at 10"
    else
        fail "U6: expected 'OK', got '${out:-<err>}'"
    fi
}

# U7-U17 live in sibling fragments (rules/coding/file-split.md Pattern A); they
# need $PRELUDE, run_case, require_module and $DOWNSTREAM_CWD, so they are sourced here
# rather than at the top of the file.
# shellcheck source=/dev/null
. "$SCRIPT_CHECKOUT_ROOT/tests/hooks/feat-2218-session-upstream-search/adoptability.sh"
# shellcheck source=/dev/null
. "$SCRIPT_CHECKOUT_ROOT/tests/hooks/feat-2218-session-upstream-search/list-vs-from.sh"

build_fixture
case_begin "search-by-partial-sid" "hooks/workflow-state/session-upstream-search.js"
run_U1
case_end
case_begin "search-by-issue-number" "hooks/workflow-state/session-upstream-search.js"
run_U2
case_end
case_begin "search-by-keyword-without-title" "hooks/workflow-state/session-upstream-search.js"
run_U3
case_end
case_begin "record-shape-never-claims-adoptable" "hooks/workflow-state/session-upstream-search.js"
run_U4
case_end
case_begin "merge-collapses-both-generators" "hooks/workflow-state/session-upstream-search.js"
run_U5
case_end
case_begin "query-less-listing-caps-search-only" "hooks/workflow-state/session-upstream-search.js"
run_U6
case_end
case_begin "every-record-states-granularity" "hooks/workflow-state/session-upstream-search.js"
run_U7
case_end
case_begin "same-cwd-candidate-offered-full" "hooks/workflow-state/inheritance/candidates.js"
run_U8
case_end
case_begin "search-only-record-null-granularity" "hooks/workflow-state/session-upstream-search.js"
run_U9
case_end
case_begin "context-less-listing-claims-nothing" "hooks/workflow-state/session-upstream-search.js"
run_U10
case_end
case_begin "query-listing-caps-search-only" "hooks/workflow-state/session-upstream-search.js"
run_U11
case_end
case_begin "search-only-cap-exported" "hooks/workflow-state/session-upstream-search.js"
run_U12
case_end
case_begin "degrading-context-listed-degraded" "hooks/workflow-state/inheritance/candidates.js"
run_U13
case_end
case_begin "list-granularity-matches-from-ladder" "hooks/workflow-state/session-upstream-search.js"
run_U14
case_end
case_begin "start-context-only-downstream-same-on-both-paths" "hooks/workflow-state/session-upstream-search.js"
run_U15
case_end
case_begin "cli-list-and-from-agree-on-start-context" "hooks/workflow-state/session-upstream-search.js"
run_U16
case_end
case_begin "missing-intent-offered-when-from-adopts" "hooks/workflow-state/session-upstream-search.js"
run_U17
case_end
case_begin "search-only-never-overadvertised" "hooks/workflow-state/session-upstream-search.js"
run_U18
case_end
# U19/U20 run as the fragment is sourced: its case markers must wrap the runs, not just the definitions.
# shellcheck source=/dev/null
. "$SCRIPT_CHECKOUT_ROOT/tests/hooks/feat-2218-session-upstream-search/list-injection.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
