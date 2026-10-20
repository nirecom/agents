#!/usr/bin/env bash
# tests/hooks/feat-2218-inheritance-equivalence/gen-golden.sh
# Tests: hooks/workflow-state/inheritance/apply.js
# Tags: session-inherit, golden-generator, regression-2218, scope:issue-specific, regression-2304, feature-2297
# Regenerates E1's EXPECTED_POST in ../feat-2218-inheritance-equivalence.sh from
# the current applyInheritance behaviour (opts omitted, upstream sid signature):
# the events after upstream_copy_seq, normalized the same way E1 does. Run only
# for an approved, intentional change to the automatic inheritance path — never
# to silence a regression. Usage: bash tests/hooks/feat-2218-inheritance-equivalence/gen-golden.sh

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
SCRIPT_CHECKOUT_ROOT_NODE="$(node_path "$SCRIPT_CHECKOUT_ROOT")"

tmp="$(mktemp -d 2>/dev/null || mktemp -d -t 'wf2218gen')"
tn="$(node_path "$tmp")"
# isolation (#2512): pin state and plans dirs script-wide under $tmp; the per-call pins below still override them.
mkdir -p "$tmp/isolation/workflow-state" "$tmp/isolation/plans" "$tmp/cfg" "$tmp/transcripts"
export WORKFLOW_STATE_DIR="$tn/isolation/workflow-state" WORKFLOW_PLANS_DIR="$tn/isolation/plans"
# Same CONFIRM_DETAIL waiver as the test, so detail completes the same way.
printf 'CONFIRM_DETAIL=off\n' > "$tmp/cfg/.env"
export AGENTS_MAIN_ROOT="$tn/cfg" CLAUDE_TRANSCRIPT_BASE_DIR="$tn/transcripts"

# Same fixture upstream/downstream pair and OMIT-opts call as project_stream('OMIT')
# in ../feat-2218-inheritance-equivalence.sh — keep the two in sync.
out=$(cd "$tmp" && env -u CLAUDE_CODE_SESSION_ID \
    WORKFLOW_STATE_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" \
    HOME="$tn/home" USERPROFILE="$tn/home" \
    "$RWT" 60 node -e "
const fs = require('fs'), path = require('path');
const { writeState, createInitialState, markStep } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io');
const { applyInheritance } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/inheritance');
const donorSid = 'donor-2218-eq';
writeState(donorSid, createInitialState(donorSid, { cwd: '/fixture/repo', git_branch: 'feature/x' }));
markStep(donorSid, 'workflow_init', 'complete');
require('$SCRIPT_CHECKOUT_ROOT_NODE/tests/lib/plan-approval-fixture').approveLive(donorSid, 'clarify_intent');
markStep(donorSid, 'clarify_intent', 'complete');
markStep(donorSid, 'outline', 'skipped', { skip_reason: 'trivial' });
markStep(donorSid, 'detail', 'complete');
markStep(donorSid, 'branching_complete', 'complete');
markStep(donorSid, 'write_tests', 'complete');
markStep(donorSid, 'review_tests', 'complete');
markStep(donorSid, 'run_tests', 'pending', { reset_reason: 'flaky-rerun' });
const heirSid = 'heir-2218-eq';
writeState(heirSid, createInitialState(heirSid, { cwd: '/fixture/repo', git_branch: 'feature/x' }));
applyInheritance(heirSid, '2026-03-01T00:00:00.000Z', donorSid);
const heir = JSON.parse(fs.readFileSync(path.join(process.env.WORKFLOW_STATE_DIR, heirSid + '.json'), 'utf8'));
const b = heir.upstream_copy_seq;
const post = heir.events.filter((e) => !(e.seq <= b)).map((e) => [
  e.kind, e.step, e.status || '', e.key || '',
  e.value === undefined ? '' : (typeof e.value === 'string' ? e.value : JSON.stringify(e.value)),
  e.origin, e.provenance,
].join('|'));
process.stdout.write('EXPECTED_POST=\"' + post.join('\n') + '\"\n');
" 2>&1)
rm -rf "$tmp" 2>/dev/null || true

printf '%s\n' "$out"
