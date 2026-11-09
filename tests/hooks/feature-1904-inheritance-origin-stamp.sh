#!/usr/bin/env bash
# tests/hooks/feature-1904-inheritance-origin-stamp.sh
# Tests: hooks/workflow-state/inheritance/apply.js, hooks/workflow-state/state-io/migrations/v1-to-v2.js
# Tags: session-inherit, provenance, regression-1904, scope:issue-specific, pwsh-not-required, TL1, TL2, regression-2304

# #1904 as revised by #2304: applyInheritance copies the upstream's events verbatim (origin, provenance, at)
# up to upstream_copy_seq and stamps origin:"session-inherit"/provenance:"backfilled" only on what it
# appends after the boundary; no event carries inherited_from. Case A uses a upstream migrated by
# migrateV1ToV2 (origin "migration-v1-to-v2"); Case B is the control for an ordinary mark-step upstream.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"

PASS_COUNT=0; FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'wf1904'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

SCRIPT_CHECKOUT_ROOT_NODE="$(node_path "$SCRIPT_CHECKOUT_ROOT")"

# isolation (#2512): pin state and plans dirs file-wide; the per-call pins below still override them.
_ISOLATION_TMP_ROOT="$(make_tmp)"; readonly _ISOLATION_TMP_ROOT
mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT

# Shared downstream check (#2304): events up to upstream_copy_seq equal the upstream's normalized events
# verbatim, and only the events after the boundary are session-inherit/backfilled.
BOUNDARY_CHECK_JS="
const downstreamRaw = JSON.parse(require('fs').readFileSync(require('path').join(process.env.WORKFLOW_STATE_DIR, downstreamSid + '.json'), 'utf8'));
const b = downstreamRaw.upstream_copy_seq;
if (typeof b !== 'number') problems.push('no-upstream_copy_seq');
if (downstreamRaw.upstream_session_id !== upstreamSid) problems.push('upstream_session_id:' + downstreamRaw.upstream_session_id);
const pre = downstreamRaw.events.filter((e) => e.seq <= b);
if (upstream && JSON.stringify(pre) !== JSON.stringify(upstream.events)) problems.push('pre-boundary-not-verbatim:' + JSON.stringify(pre.map((e) => [e.kind, e.step, e.origin])));
const post = downstreamRaw.events.filter((e) => !(e.seq <= b));
const badPost = post.filter((e) => e.origin !== 'session-inherit' || e.provenance !== 'backfilled');
if (badPost.length > 0) problems.push('bad-post:' + JSON.stringify(badPost.map((e) => [e.kind, e.step, e.origin, e.provenance])));
const named = downstreamRaw.events.filter((e) => Object.prototype.hasOwnProperty.call(e, 'inherited_from'));
if (named.length > 0) problems.push('inherited_from-present:' + named.length);
"

# ---------------------------------------------------------------------------
# run_1904a: v1-shaped upstream migrated in-flight via migrateV1ToV2, then
# inherited. Asserts positive anchors on the upstream (migration actually ran and
# produced the expected origin/kinds) before the downstream boundary check.
# ---------------------------------------------------------------------------
run_1904a() {
    local tmp tn out
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"

    out=$(env -u CLAUDE_CODE_SESSION_ID \
        WORKFLOW_STATE_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" \
        HOME="$tn/home" USERPROFILE="$tn/home" \
        "$RWT" 60 node -e "
const fs = require('fs');
const path = require('path');
const wfDir = process.env.WORKFLOW_STATE_DIR;
fs.mkdirSync(wfDir, { recursive: true });

const { readState, writeState, createInitialState } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io');
const { applyInheritance } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/inheritance');

const upstreamSid = 'upstream-1904a';
const downstreamSid = 'downstream-1904a';

// Plant a v1-shaped file directly with fs.writeFileSync — writeState cannot be
// used here because serializeStateForPersist strips the projection key
// 'steps', which is exactly the v1 shape this case needs to plant.
const v1Upstream = {
  session_id: upstreamSid,
  created_at: '2020-01-01T00:00:00.000Z',
  cwd: '/fixture',
  git_branch: null,
  steps: {
    workflow_init: { status: 'complete', updated_at: '2020-01-01T00:01:00.000Z' },
    clarify_intent: {
      status: 'skipped',
      updated_at: '2020-01-01T00:02:00.000Z',
      skip_reason: 'docs-only-short-circuit',
    },
  },
};
fs.writeFileSync(path.join(wfDir, upstreamSid + '.json'), JSON.stringify(v1Upstream), 'utf8');

// readState triggers normalizeStateVersion -> migrateV1ToV2 in memory.
const upstream = readState(upstreamSid);

const problems = [];
if (upstream === null) problems.push('upstream-null');
if (upstream) {
  const statusEvents = upstream.events.filter((e) => e.kind === 'step_status');
  const annotationEvents = upstream.events.filter((e) => e.kind === 'step_annotation');
  if (statusEvents.length < 1) problems.push('upstream-no-step-status-events');
  const badOrigin = statusEvents.filter((e) => e.origin !== 'migration-v1-to-v2');
  if (badOrigin.length > 0) problems.push('upstream-status-wrong-origin:' + badOrigin.map((e) => e.step).join(','));
  if (annotationEvents.length < 1) problems.push('upstream-no-annotation-events');
}

const downstreamCreatedAt = '2026-01-01T00:00:00.000Z';
writeState(downstreamSid, createInitialState(downstreamSid, { cwd: '/downstream', git_branch: null }));
applyInheritance(downstreamSid, downstreamCreatedAt, upstreamSid);
$BOUNDARY_CHECK_JS

process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "1904a: v1-shaped upstream migrated via migrateV1ToV2 -> migrated events copied verbatim up to upstream_copy_seq, session-inherit only after it"
    else
        fail "1904a: expected 'OK', got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# run_1904b: mark-step upstream (control group). Same boundary check, using an
# ordinary origin:"mark-step" upstream.
# ---------------------------------------------------------------------------
run_1904b() {
    local tmp tn out
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"

    out=$(env -u CLAUDE_CODE_SESSION_ID \
        WORKFLOW_STATE_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" \
        HOME="$tn/home" USERPROFILE="$tn/home" \
        "$RWT" 60 node -e "
const { readState, writeState, createInitialState, markStep } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io');
const { applyInheritance } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/inheritance');

const upstreamSid = 'upstream-1904b';
const downstreamSid = 'downstream-1904b';

writeState(upstreamSid, createInitialState(upstreamSid, { cwd: '/upstream', git_branch: null }));
markStep(upstreamSid, 'workflow_init', 'complete');
markStep(upstreamSid, 'clarify_intent', 'skipped', { skip_reason: 'docs-only-short-circuit' });

const upstream = readState(upstreamSid);
const problems = [];
if (upstream === null) problems.push('upstream-null');

const downstreamCreatedAt = '2026-01-02T00:00:00.000Z';
writeState(downstreamSid, createInitialState(downstreamSid, { cwd: '/downstream', git_branch: null }));
applyInheritance(downstreamSid, downstreamCreatedAt, upstreamSid);
$BOUNDARY_CHECK_JS

process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "1904b: mark-step upstream (control) -> mark-step events copied verbatim up to upstream_copy_seq, session-inherit only after it"
    else
        fail "1904b: expected 'OK', got '${out:-<err>}'"
    fi
}

run_1904a
run_1904b

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -gt 0 ] && exit 1
exit 0
