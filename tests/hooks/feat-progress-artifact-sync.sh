#!/usr/bin/env bash
# tests/hooks/feat-progress-artifact-sync.sh
# Tests: hooks/lib/plans-artifact-registry.js, hooks/lib/plan-sync/allowlist.js, hooks/lib/plan-sync/project-host.js, bin/sweep-plans/retention-class.js, bin/check-plans-artifacts
# Tags: progress-file, plans, registry, plan-sync, project-host, sweep-plans, retention, scope:issue-specific, pwsh-not-required, TL1

# Issue #2594 stage 1 — <rootSid>-session-progress.md is a plans-dir artifact the model keeps across sessions. It must be a registered kind (or every lint and sweep treats it as unregistered), retained like a plan (sweep-plans deletes it only for an approved group), and synced like a plan (plan-sync's allowlist and the project-host record), all from one synced-kind list in the registry (CPR-SSOT). Its hook-side state file progress-pressure.json is a control-dir kind.

# TDD (write_code has not run): every case is expected to FAIL until the registry gains the progress kinds.

set -u
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP="$(make_tmp)"
readonly TMP
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT
mkdir -p "$TMP/plans" "$TMP/home" "$TMP/transcripts" "$TMP/neutral"
export WORKFLOW_STATE_DIR="$(np "$TMP/wf")" WORKFLOW_PLANS_DIR="$(np "$TMP/plans")"
export HOME="$(np "$TMP/home")" USERPROFILE="$(np "$TMP/home")"
export CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$TMP/transcripts")"
export AGENTS="$(np "$SCRIPT_CHECKOUT_ROOT")" PLANS="$WORKFLOW_PLANS_DIR"
unset CLAUDE_CODE_SESSION_ID
cd "$TMP/neutral" || exit 1

nj() { run_with_timeout 60 node "$(np "$TMP/$1")" "${@:2}" 2>&1; }
expect() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$3 got=${2:0:400}"; fi; }

cat > "$TMP/registry.js" <<'JS'
const path = require('path');
const R = require(process.env.AGENTS + '/hooks/lib/plans-artifact-registry.js');
const bad = [];
const p = R.parsePlansEntry('s1-session-progress.md');
if (!p || p.verdict !== 'artifact' || p.kind !== 'progress' || p.sid !== 's1') bad.push('session-progress.md:' + JSON.stringify(p));
const rc = R.retentionClassOf('s1-session-progress.md', 's1');
if (rc !== 'plan') bad.push('retention:' + rc);
// The pre-rename name is no longer the progress kind (it collided with *-progress.md topics).
const old = R.parsePlansEntry('s1-progress.md');
if (old && old.kind === 'progress') bad.push('old-name-still-progress:' + JSON.stringify(old));
let ap = null;
try { ap = R.getPlansArtifactPath('s1', 'progress', { plansDir: process.env.PLANS }); } catch (e) { bad.push('getPlansArtifactPath-threw:' + e.message); }
// A null (or any other) return fails: the kind must resolve to exactly <plansDir>/<sid>-session-progress.md.
if (ap !== path.join(process.env.PLANS, 's1-session-progress.md')) bad.push('path:' + String(ap));
const c = R.parsePlansEntry('s1-progress-pressure.json');
if (!c || c.verdict !== 'control' || c.kind !== 'progress-pressure') bad.push('progress-pressure:' + JSON.stringify(c));
// #2652 renamed the risk sidecar; how pre-rename leftovers are registered is the implementation's call (S6-4).
const rs = R.parsePlansEntry('s1-risk-signal.json');
if (!rs || rs.verdict !== 'control') bad.push('risk-signal-not-control:' + JSON.stringify(rs));

// One synced-kind list (the export name is the implementation's: any SYNCED* array).
const lists = Object.keys(R).filter((k) => /^SYNCED/.test(k) && Array.isArray(R[k]));
const synced = lists.map((k) => R[k]).find((a) => a.indexOf('progress') !== -1);
if (!synced) bad.push('no-synced-list-with-progress:' + lists.join(','));
else {
  for (const k of ['intent', 'outline', 'detail']) if (synced.indexOf(k) === -1) bad.push('synced-missing:' + k);
  if (synced.indexOf('context') !== -1) bad.push('context-synced');
}
if (R.retentionCoverageErrors().length) bad.push('coverage:' + R.retentionCoverageErrors().join(','));
process.stdout.write(bad.length ? 'BAD:' + bad.join(' | ') : 'OK');
JS

case_begin "registry-registers-progress-kinds" "hooks/lib/plans-artifact-registry.js"
expect "A1: session-progress.md is a plan-retained artifact kind, progress-pressure.json a control kind, old sidecars still registered, one synced list holds progress" "$(nj registry.js)" "OK"
case_end

cat > "$TMP/allowlist.js" <<'JS'
const A = require(process.env.AGENTS + '/hooks/lib/plan-sync/allowlist.js');
const bad = [];
if (A.isSyncTargetName('s1-session-progress.md') !== true) bad.push('progress-not-target');
for (const k of ['intent', 'outline', 'detail']) if (A.isSyncTargetName('s1-' + k + '.md') !== true) bad.push(k + '-lost');
for (const n of ['s1-context.md', 's1-progress-pressure.json', 's1-note-project-host-session-progress.json', 's1-progress.md']) {
  if (A.isSyncTargetName(n) !== false) bad.push('target:' + n);
}
if (A.isSyncTarget(process.env.PLANS, process.env.PLANS + '/s1-session-progress.md') !== true) bad.push('isSyncTarget-false');
if (A.isSyncTarget(process.env.PLANS, process.env.PLANS + '/s1-progress.md') !== false) bad.push('isSyncTarget-old-name');
const gi = A.renderGitignore().split('\n');
if (gi.indexOf('!/*-session-progress.md') === -1) bad.push('gitignore:' + JSON.stringify(gi));
if (gi.indexOf('!/*-progress.md') !== -1) bad.push('gitignore-old-name');
if (gi.indexOf('!/*-context.md') !== -1) bad.push('gitignore-context');
process.stdout.write(bad.length ? 'BAD:' + bad.join(' | ') : 'OK');
JS

case_begin "allowlist-syncs-progress" "hooks/lib/plan-sync/allowlist.js"
expect "A2: session-progress.md is a sync target (the old <sid>-progress.md is not) and the rendered .gitignore un-ignores /*-session-progress.md only" "$(nj allowlist.js)" "OK"
case_end

cat > "$TMP/record-path.js" <<'JS'
const path = require('path');
const H = require(process.env.AGENTS + '/hooks/lib/plan-sync/project-host.js');
const bad = [];
const d = process.env.PLANS;
const want = { 'session-progress': 's1-note-project-host-session-progress.json', intent: 's1-note-project-host-intent.json',
  outline: 's1-note-project-host-outline.json', detail: 's1-note-project-host-detail.json' };
for (const [k, name] of Object.entries(want)) {
  const got = H.recordPathFor(path.join(d, 's1-' + k + '.md'));
  if (got !== path.join(d, name)) bad.push(k + ':' + got);
}
if (H.recordPathFor(path.join(d, 's1-context.md')) !== null) bad.push('context-gets-a-record');
if (H.recordPathFor(path.join(d, 's1-progress.md')) !== null) bad.push('old-name-gets-a-record');
process.stdout.write(bad.length ? 'BAD:' + bad.join(' | ') : 'OK');
JS

case_begin "project-host-record-path-for-progress" "hooks/lib/plan-sync/project-host.js"
expect "A3: session-progress.md's record is <sid>-note-project-host-session-progress.json; the plan records keep their names; the old name gets none" "$(nj record-path.js)" "OK"
case_end

case_begin "sweep-retention-keeps-progress" "bin/sweep-plans/retention-class.js"
A4="$(printf 's1\000s1-session-progress.md\000s1\000s1-intent.md\000s1\000s1-note-x.md\000' | run_with_timeout 30 node "$SCRIPT_CHECKOUT_ROOT/bin/sweep-plans/retention-class.js" 2>&1 | tr -d '\r' | tr '\n' ',')"
# "plan" is the class sweep-plans deletes only for an approved group (delete-passes.sh).
expect "A4: sweep-plans classifies session-progress.md as plan (kept unless the group is approved)" "$A4" "plan,plan,non-plan,"
case_end

case_begin "plans-lint-accepts-progress" "bin/check-plans-artifacts"
mkdir -p "$TMP/lintdir"
printf 'x\n' > "$TMP/lintdir/s1-intent.md"
printf 'x\n' > "$TMP/lintdir/s1-session-progress.md"
A5="$(run_with_timeout 60 node "$SCRIPT_CHECKOUT_ROOT/bin/check-plans-artifacts" --dir "$(np "$TMP/lintdir")" 2>&1)"
A5_RC=$?
expect "A5: --dir on a plans dir holding <sid>-session-progress.md exits 0" "$A5_RC" "0"
case "$A5" in
  *"unregistered: 0"*) pass "A5: session-progress.md is not an unregistered name" ;;
  *) fail "A5: session-progress.md is not an unregistered name" "${A5:0:300}" ;;
esac
A6="$(run_with_timeout 120 node "$SCRIPT_CHECKOUT_ROOT/bin/check-plans-artifacts" --source "$(np "$SCRIPT_CHECKOUT_ROOT")" 2>&1)"
A6_RC=$?
expect "A6: the RC-4 source lint stays clean over the tree (no new exception for session-progress.md)" "$A6_RC" "0"
[ "$A6_RC" = "0" ] || echo "${A6:0:600}"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
