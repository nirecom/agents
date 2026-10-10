#!/usr/bin/env bash
# Tests: hooks/workflow-gate/staged-evidence.js, hooks/workflow-state/effective-state.js, hooks/workflow-state/evidence-resolver.js
# Tags: TL1, workflow, docs, evidence, write-code, review-tests, scope:issue-specific
#
# #2327 C1 regression: a `.md` staged by write-code (WCD-7) and recorded in
# write_code_scope_manifest must not auto-complete the docs step, while the SAME
# path re-staged with a different blob OID (snapshot drift) still counts as docs
# evidence. Covers the drift branch of hasStagedDocChanges and the end-to-end
# reconcileEffectiveState resolution that next-step persists.
# TDD: FAILs until the writeCodeSnapshot exclusion lands.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

TMPD="$(make_tmp)"
trap 'rm -rf "$TMPD"' EXIT
harness_isolate "$TMPD"
export WORKFLOW_STATE_DIR="$(np "$WORKFLOW_STATE_DIR")"
export WORKFLOW_PLANS_DIR="$(np "$WORKFLOW_PLANS_DIR")"
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR 2>/dev/null || true
cd "$TMPD" || exit 1

AGENTS_N="$(np "$SCRIPT_CHECKOUT_ROOT")"

REPO="$TMPD/repo"
harness_git_init "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
mkdir -p "$REPO/skills/x"
printf 'skill v1\n' > "$REPO/skills/x/SKILL.md"
git -C "$REPO" add skills/x/SKILL.md
OID_V1="$(git -C "$REPO" rev-parse :skills/x/SKILL.md)"
REPO_N="$(np "$REPO")"

# probe.js <agentsN> <mode> <repoN> <sid> <snapshotOid>
#   mode=staged    → hasStagedDocChanges(repo, {writeCodeSnapshot}) as true/false
#   mode=reconcile → seeds state (every step before docs complete, snapshot on
#                    write_code) and prints docs' reconciled status/resolved_from
cat > "$TMPD/probe.js" << 'JSEOF'
"use strict";
const [,, agents, mode, repo, sid, oid] = process.argv;
// oid "none" = legacy state with no manifest; "unavailable" = recorded-but-unavailable snapshot.
const snapshot = oid === "none" ? undefined
  : oid === "unavailable" ? { v: 1, unavailable: true }
  : { v: 1, files: { "skills/x/SKILL.md": oid } };
try {
  if (mode === "staged") {
    const { hasStagedDocChanges } = require(agents + "/hooks/workflow-gate/staged-evidence");
    process.stdout.write(String(hasStagedDocChanges(repo, { writeCodeSnapshot: snapshot })));
    process.exit(0);
  }
  const fs = require("fs"), path = require("path");
  const S = require(agents + "/hooks/workflow-state/state-io");
  const steps = {};
  const di = S.VALID_STEPS.indexOf("docs");
  S.VALID_STEPS.forEach((s, i) => { steps[s] = { status: i < di ? "complete" : "pending" }; });
  if (snapshot !== undefined) steps.write_code.write_code_scope_manifest = snapshot;
  fs.writeFileSync(path.join(process.env.WORKFLOW_STATE_DIR, sid + ".json"),
    JSON.stringify({ version: 1, session_id: sid, steps, closes_issues: [2327] }));
  const state = S.readState(sid);
  if (mode === "resolver") {
    const { hasCompletionEvidence } = require(agents + "/hooks/workflow-state/evidence-resolver");
    const hasKey = Object.prototype.hasOwnProperty.call(state.steps.write_code, "write_code_scope_manifest");
    process.stdout.write(String(hasCompletionEvidence("docs", sid, { repoDir: repo, state })) + "/manifest=" + hasKey);
    process.exit(0);
  }
  const { reconcileEffectiveState } = require(agents + "/hooks/workflow-state/effective-state");
  const r = reconcileEffectiveState(state, sid, { repoDir: repo });
  const d = r.steps.docs || {};
  const res = r.resolutions.some((x) => x.step === "docs") ? "resolved" : "unresolved";
  process.stdout.write(d.status + "/" + d.resolved_from + "/" + res);
} catch (e) { process.stdout.write("ERROR:" + e.message.split("\n")[0]); }
JSEOF
PROBE_N="$(np "$TMPD/probe.js")"
probe() { run_with_timeout 30 node "$PROBE_N" "$AGENTS_N" "$@" 2>/dev/null || echo "ERROR:crashed"; }

# ============================================================================
case_begin "staged-evidence-oid-drift" "hooks/workflow-gate/staged-evidence.js"
# ============================================================================

echo "=== staged-evidence: same path, snapshot OID vs re-staged OID ==="

# D1: staged OID equals the write_code snapshot → excluded → no docs evidence.
assert_eq "$(probe staged "$REPO_N" - "$OID_V1")" "false"
# D2: same path re-edited and re-staged after write_code (OID drift) → the file
# is new docs work, not write-code's, so it IS docs evidence again.
printf 'skill v2 edited after write_code\n' > "$REPO/skills/x/SKILL.md"
git -C "$REPO" add skills/x/SKILL.md
OID_V2="$(git -C "$REPO" rev-parse :skills/x/SKILL.md)"
if [ "$OID_V1" != "$OID_V2" ]; then pass "D2 precondition: OID changed"; else fail "D2 precondition: OID changed" "$OID_V1"; fi
assert_eq "$(probe staged "$REPO_N" - "$OID_V1")" "true"

case_end

# ============================================================================
case_begin "effective-state-docs-not-auto-completed" "hooks/workflow-state/effective-state.js"
# ============================================================================

echo "=== reconcileEffectiveState: write-code-staged .md never auto-completes docs ==="

# E1: restore the v1 content so the staged OID matches the snapshot again.
printf 'skill v1\n' > "$REPO/skills/x/SKILL.md"
git -C "$REPO" add skills/x/SKILL.md
assert_eq "$(git -C "$REPO" rev-parse :skills/x/SKILL.md)" "$OID_V1"
_e1="$(probe reconcile "$REPO_N" "dews-e1-$$" "$OID_V1")"
case "$_e1" in
    pending/state/unresolved) pass "E1/docs-stays-pending-no-evidence-resolution" ;;
    *) fail "E1/docs-stays-pending-no-evidence-resolution" "got=$_e1" ;;
esac

# E2 (positive control): the same path drifted past the snapshot → docs is
# resolved from evidence, proving E1 is not vacuous.
_e2="$(probe reconcile "$REPO_N" "dews-e2-$$" "0000000000000000000000000000000000000000")"
case "$_e2" in
    complete/evidence/resolved) pass "E2/drifted-md-resolves-docs-from-evidence" ;;
    *) fail "E2/drifted-md-resolves-docs-from-evidence" "got=$_e2" ;;
esac

case_end

# ============================================================================
case_begin "legacy-state-no-manifest-keeps-root-md-docs-evidence" "hooks/workflow-state/evidence-resolver.js"
# ============================================================================

echo "=== legacy state (no write_code_scope_manifest): root CHANGES.md stays docs evidence ==="

LREPO="$TMPD/legacy-repo"
harness_git_init "$LREPO"
printf 'changelog entry\n' > "$LREPO/CHANGES.md"
git -C "$LREPO" add CHANGES.md
LREPO_N="$(np "$LREPO")"

# L1: no snapshot at all → pre-snapshot behavior: any staged *.md counts.
assert_eq "$(probe staged "$LREPO_N" - none)" "true"
# L2: evidence-resolver docs branch on a seeded legacy state (manifest key absent).
assert_eq "$(probe resolver "$LREPO_N" "dews-l2-$$" none)" "true/manifest=false"
# L3: end-to-end reconcile resolves docs from evidence exactly as before #2327.
_l3="$(probe reconcile "$LREPO_N" "dews-l3-$$" none)"
case "$_l3" in
    complete/evidence/resolved) pass "L3/legacy-reconcile-resolves-docs-from-root-md" ;;
    *) fail "L3/legacy-reconcile-resolves-docs-from-root-md" "got=$_l3" ;;
esac
# L4 (contrast): a recorded-but-unavailable snapshot narrows evidence to docs/ only,
# proving L1/L2 exercise the distinct legacy branch rather than a shared path.
assert_eq "$(probe staged "$LREPO_N" - unavailable)" "false"
assert_eq "$(probe resolver "$LREPO_N" "dews-l4-$$" unavailable)" "false/manifest=true"

case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
