#!/usr/bin/env bash
# tests/feat-2218-inheritance-equivalence/gen-golden.sh
# Tests: hooks/workflow-state/inheritance/apply.js
# Tags: session-inherit, golden-generator, regression-2218, scope:issue-specific
# Regenerates E1's GOLDEN_SHA/GOLDEN_COUNT in ../feat-2218-inheritance-equivalence.sh
# from the current applyInheritance behaviour (opts omitted). Run only for an
# approved, intentional change to the automatic inheritance path — never to
# silence a regression. Usage: bash tests/feat-2218-inheritance-equivalence/gen-golden.sh

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"

tmp="$(mktemp -d 2>/dev/null || mktemp -d -t 'wf2218gen')"
tn="$(node_path "$tmp")"

# Same fixture donor/heir pair and OMIT-opts call as project_stream('OMIT')
# in ../feat-2218-inheritance-equivalence.sh — keep the two in sync.
out=$(env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
    CLAUDE_WORKFLOW_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" \
    HOME="$tn/home" USERPROFILE="$tn/home" \
    "$RWT" 60 node -e "
const crypto = require('crypto');
const { readState, writeState, createInitialState, markStep } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const { applyInheritance } = require('$AGENTS_DIR_NODE/hooks/workflow-state/inheritance');
const donorSid = 'donor-2218-eq';
writeState(donorSid, createInitialState(donorSid, { cwd: '/fixture/repo', git_branch: 'feature/x' }));
markStep(donorSid, 'workflow_init', 'complete');
markStep(donorSid, 'clarify_intent', 'complete');
markStep(donorSid, 'outline', 'skipped', { skip_reason: 'trivial' });
markStep(donorSid, 'detail', 'complete');
markStep(donorSid, 'branching_complete', 'complete');
markStep(donorSid, 'write_tests', 'complete');
markStep(donorSid, 'review_tests', 'complete');
markStep(donorSid, 'run_tests', 'pending', { reset_reason: 'flaky-rerun' });
const donor = readState(donorSid);
const heirSid = 'heir-2218-eq';
const heirCreatedAt = '2026-03-01T00:00:00.000Z';
writeState(heirSid, createInitialState(heirSid, { cwd: '/other/repo', git_branch: 'main' }));
applyInheritance(heirSid, heirCreatedAt, donor);
const heir = readState(heirSid);
const norm = heir.events.filter((e) => e.origin === 'session-inherit').map((e) => [
  e.kind, e.step, e.status || '', e.key || '',
  typeof e.value === 'string' ? e.value : JSON.stringify(e.value === undefined ? null : e.value),
  e.origin, e.provenance, e.inherited_from, e.at,
].join('|'));
process.stdout.write('GOLDEN_COUNT=\"' + norm.length + '\"\n');
process.stdout.write('GOLDEN_SHA=\"' + crypto.createHash('sha256').update(norm.join('\n')).digest('hex') + '\"\n');
" 2>&1)
rm -rf "$tmp" 2>/dev/null || true

printf '%s\n' "$out"
