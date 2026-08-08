#!/usr/bin/env bash
# tests/feature-1904-inheritance-origin-stamp.sh
# Tests: hooks/workflow-state/inheritance/apply.js, hooks/workflow-state/state-io/migrations/v1-to-v2.js
# Tags: session-inherit, provenance, regression-1904, scope:issue-specific, pwsh-not-required, TL1, TL2
#
# Regression for #1904: applyInheritance stamps every inherited event with
# origin:"session-inherit", provenance:"backfilled", inherited_from:<donor sid>
# and at:<heir created_at> — regardless of whether the donor's OWN events carry
# a different origin. Case A proves this against a donor whose events were
# produced by migrateV1ToV2 (origin "migration-v1-to-v2"): if applyInheritance
# ever started passing a donor event's own `origin` through unstamped, this is
# the shape that would catch it (a mark-step donor's events already carry
# origin "mark-step", which is a WEAKER signal since it differs from
# session-inherit in only one of the two relevant fields; migration-v1-to-v2
# additionally differs in `provenance` for status events, making it the
# stronger anchor). Case B is a control group proving the same invariant holds
# for the ordinary mark-step donor shape.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS_COUNT=0; FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'wf1904'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"

# ---------------------------------------------------------------------------
# run_1904a: v1-shaped donor migrated in-flight via migrateV1ToV2, then
# inherited. Asserts positive anchors on the donor (migration actually ran and
# produced the expected origin/kinds) before asserting the heir's inherited
# events all carry the four session-inherit fields.
# ---------------------------------------------------------------------------
run_1904a() {
    local tmp tn out
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"

    out=$(env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        CLAUDE_WORKFLOW_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" \
        HOME="$tn/home" USERPROFILE="$tn/home" \
        "$RWT" 60 node -e "
const fs = require('fs');
const path = require('path');
const wfDir = process.env.CLAUDE_WORKFLOW_DIR;
fs.mkdirSync(wfDir, { recursive: true });

const { readState, writeState, createInitialState } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const { applyInheritance } = require('$AGENTS_DIR_NODE/hooks/workflow-state/inheritance');

const donorSid = 'donor-1904a';
const heirSid = 'heir-1904a';

// Plant a v1-shaped file directly with fs.writeFileSync — writeState cannot be
// used here because serializeStateForPersist strips the projection key
// 'steps', which is exactly the v1 shape this case needs to plant.
const v1Donor = {
  session_id: donorSid,
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
fs.writeFileSync(path.join(wfDir, donorSid + '.json'), JSON.stringify(v1Donor), 'utf8');

// readState triggers normalizeStateVersion -> migrateV1ToV2 in memory.
const donor = readState(donorSid);

const problems = [];
if (donor === null) problems.push('donor-null');
if (donor) {
  const statusEvents = donor.events.filter((e) => e.kind === 'step_status');
  const annotationEvents = donor.events.filter((e) => e.kind === 'step_annotation');
  if (statusEvents.length < 1) problems.push('donor-no-step-status-events');
  const badOrigin = statusEvents.filter((e) => e.origin !== 'migration-v1-to-v2');
  if (badOrigin.length > 0) problems.push('donor-status-wrong-origin:' + badOrigin.map((e) => e.step).join(','));
  if (annotationEvents.length < 1) problems.push('donor-no-annotation-events');
}

const heirCreatedAt = '2026-01-01T00:00:00.000Z';
writeState(heirSid, createInitialState(heirSid, { cwd: '/heir', git_branch: null }));
applyInheritance(heirSid, heirCreatedAt, donor);

const heir = readState(heirSid);
const inherited = heir.events.filter((e) => e.inherited_from === donorSid);
if (inherited.length < 1) problems.push('heir-no-inherited-events');
const inheritedAnnotations = inherited.filter((e) => e.kind === 'step_annotation');
if (inheritedAnnotations.length < 1) problems.push('heir-no-inherited-annotations');

const badOriginHeir = inherited.filter((e) => e.origin !== 'session-inherit');
const badProvenance = inherited.filter((e) => e.provenance !== 'backfilled');
const badInheritedFrom = inherited.filter((e) => e.inherited_from !== donorSid);
const badAt = inherited.filter((e) => e.at !== heirCreatedAt);
if (badOriginHeir.length > 0) problems.push('bad-origin:' + JSON.stringify(badOriginHeir.map((e) => [e.kind, e.step, e.origin])));
if (badProvenance.length > 0) problems.push('bad-provenance:' + JSON.stringify(badProvenance.map((e) => [e.kind, e.step, e.provenance])));
if (badInheritedFrom.length > 0) problems.push('bad-inherited-from:' + JSON.stringify(badInheritedFrom.map((e) => [e.kind, e.step, e.inherited_from])));
if (badAt.length > 0) problems.push('bad-at:' + JSON.stringify(badAt.map((e) => [e.kind, e.step, e.at])));

process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "1904a: v1-shaped donor migrated via migrateV1ToV2 -> all inherited events stamp origin/provenance/inherited_from/at correctly"
    else
        fail "1904a: expected 'OK', got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# run_1904b: mark-step donor (control group). Same four-field assertion, using
# an ordinary origin:"mark-step" donor to demonstrate the invariant holds
# independent of the donor's own event origin.
# ---------------------------------------------------------------------------
run_1904b() {
    local tmp tn out
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"

    out=$(env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        CLAUDE_WORKFLOW_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" \
        HOME="$tn/home" USERPROFILE="$tn/home" \
        "$RWT" 60 node -e "
const { readState, writeState, createInitialState, markStep } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const { applyInheritance } = require('$AGENTS_DIR_NODE/hooks/workflow-state/inheritance');

const donorSid = 'donor-1904b';
const heirSid = 'heir-1904b';

writeState(donorSid, createInitialState(donorSid, { cwd: '/donor', git_branch: null }));
markStep(donorSid, 'workflow_init', 'complete');
markStep(donorSid, 'clarify_intent', 'skipped', { skip_reason: 'docs-only-short-circuit' });

const donor = readState(donorSid);
const problems = [];
if (donor === null) problems.push('donor-null');

const heirCreatedAt = '2026-01-02T00:00:00.000Z';
writeState(heirSid, createInitialState(heirSid, { cwd: '/heir', git_branch: null }));
applyInheritance(heirSid, heirCreatedAt, donor);

const heir = readState(heirSid);
const inherited = heir.events.filter((e) => e.inherited_from === donorSid);
if (inherited.length < 1) problems.push('heir-no-inherited-events');

const badOrigin = inherited.filter((e) => e.origin !== 'session-inherit');
const badProvenance = inherited.filter((e) => e.provenance !== 'backfilled');
const badInheritedFrom = inherited.filter((e) => e.inherited_from !== donorSid);
const badAt = inherited.filter((e) => e.at !== heirCreatedAt);
if (badOrigin.length > 0) problems.push('bad-origin:' + JSON.stringify(badOrigin.map((e) => [e.kind, e.step, e.origin])));
if (badProvenance.length > 0) problems.push('bad-provenance:' + JSON.stringify(badProvenance.map((e) => [e.kind, e.step, e.provenance])));
if (badInheritedFrom.length > 0) problems.push('bad-inherited-from:' + JSON.stringify(badInheritedFrom.map((e) => [e.kind, e.step, e.inherited_from])));
if (badAt.length > 0) problems.push('bad-at:' + JSON.stringify(badAt.map((e) => [e.kind, e.step, e.at])));

process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "1904b: mark-step donor (control) -> all inherited events stamp origin/provenance/inherited_from/at correctly"
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
