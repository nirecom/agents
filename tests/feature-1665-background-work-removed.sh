#!/usr/bin/env bash
# tests/feature-1665-background-work-removed.sh
# Tests: hooks/lib/stop-exemption-policy.js, hooks/lib/session-markers.js, hooks/lib/sentinel-patterns.js, hooks/lib/protected-basenames.js, hooks/stop-premature-stop-guard.js, hooks/workflow-mark/enforce-override-handlers.js, hooks/workflow-state/state-io/zombie-cleanup.js, bin/workflow/lib/next-step/verdict.js, settings.json, rules/stop-guard-exemptions.md
# Tags: stop-hook, exemption, session-marker, sentinel, removal, background-work, write-code-in-flight, regression-1665, scope:issue-specific, pwsh-not-required, TL1
#
# #1665 commit 4 — the `.background-work` primitive is REMOVED and its C4 role
# is taken over by the state-derived `write-code-in-flight` exemption
# (write_code status=in_progress within a 4h TTL, hooks/workflow-state/lifecycle.js).
#
# Every case is paired with a counter-anchor on a sibling primitive that must
# survive (`next-step-paused`, `workflow-off`, `pre-workflow-init`). A removal
# that over-reaches — ripping out the whole marker family, the whole sentinel
# table, the whole zombie-sweep arm — fails the counter-anchor, so "0 hits" can
# never be reached by deleting the mechanism wholesale.
#
# TL3 gap (what this test does NOT catch):
# - Whether Claude Code itself still routes a stale `<<WORKFLOW_BACKGROUND_WORK_START>>`
#   typed by a user through the real PostToolUse chain (here only the pure
#   sentinel-patterns predicates are exercised)
# - Whether the real Stop hook, driven by Claude Code, silences C4 for an
#   in-flight write_code session (covered by feature-1665-seq-cascade i-c4-exemption)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

# rules/ may be a symlink owned by another repo, or absent from a linked
# worktree. Resolve worktree-first, then the deployed agents config.
RULES_DIR="$AGENTS_DIR/rules"
if [ ! -f "$RULES_DIR/stop-guard-exemptions.md" ]; then
    RULES_DIR="${AGENTS_CONFIG_DIR:-$HOME/.claude}/rules"
fi

# Fixture isolation (rules/test/fixture-isolation.md): never let a spawned node
# resolve the developer's live session or the real ~/.workflow-plans.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
FIXTURE_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t 'bgwork1665')"
mkdir -p "$FIXTURE_ROOT/wf" "$FIXTURE_ROOT/cwd"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
WF_NODE="$(node_path "$FIXTURE_ROOT/wf")"
export CLAUDE_WORKFLOW_DIR="$WF_NODE"
export WORKFLOW_PLANS_DIR="$WF_NODE"
cd "$FIXTURE_ROOT/cwd" || exit 1

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

POLICY_NODE="$_AGENTS_DIR_NODE/hooks/lib/stop-exemption-policy.js"
GUARD_NODE="$_AGENTS_DIR_NODE/hooks/stop-premature-stop-guard.js"
BASENAMES_NODE="$_AGENTS_DIR_NODE/hooks/lib/protected-basenames.js"
MARKERS_NODE="$_AGENTS_DIR_NODE/hooks/lib/session-markers.js"
PATTERNS_NODE="$_AGENTS_DIR_NODE/hooks/lib/sentinel-patterns.js"
STATEIO_NODE="$_AGENTS_DIR_NODE/hooks/workflow-state/state-io.js"

# scan_targets — every source tree the removal must reach. tests/ and docs/ are
# deliberately out of scope: docs/history.md records the primitive's life and
# must keep saying so.
scan_targets() {
    printf '%s\n' "$AGENTS_DIR/hooks" "$AGENTS_DIR/bin" "$AGENTS_DIR/settings.json" \
        "$RULES_DIR" "$AGENTS_DIR/skills"
}

# scan_for <extended-regex> — case-insensitive recursive scan over scan_targets,
# printing `path:line:text` for each hit (empty output = zero hits).
scan_for() {
    local pat="$1" t
    while IFS= read -r t; do
        [ -e "$t" ] || continue
        # -H is required: grep omits the filename when handed a single file
        # (settings.json), which would make the per-target anchors in G2 blind.
        grep -rHIniE -- "$pat" "$t" 2>/dev/null
    done < <(scan_targets)
}

BG_RE='background[-_]work|backgroundwork'

# ---------------------------------------------------------------------------
# G1: zero surviving references to the background-work family across hooks/,
#     bin/, settings.json, rules/ and skills/. All three spellings
#     (`background-work` marker suffix, `BACKGROUND_WORK` sentinel, the
#     `backgroundWork*` identifiers) are covered by one case-insensitive regex.
# ---------------------------------------------------------------------------
run_G1() {
    local hits count
    hits="$(scan_for "$BG_RE")"
    count="$(printf '%s' "$hits" | grep -c . )"
    if [ -z "$hits" ]; then
        pass "G1: no background-work / BACKGROUND_WORK / backgroundWork references remain in hooks|bin|settings.json|rules|skills"
    else
        fail "G1: $count surviving reference(s), first 15:
$(printf '%s\n' "$hits" | sed 's/^/    /' | head -15)"
    fi
}

# ---------------------------------------------------------------------------
# G2 (counter-anchor for G1): the SAME scanner still finds the sibling
#     `next-step-paused` primitive. Without this row a scanner that silently
#     matched nothing — bad path, unreadable dir, broken regex — would report
#     G1 as a pass forever.
# ---------------------------------------------------------------------------
run_G2() {
    local hits problems=""
    # `next[-_]step[-_]paus` deliberately stops before the final letter: the
    # marker suffix is `next-step-paused` but the sentinel is NEXT_STEP_PAUSE.
    hits="$(scan_for 'next[-_]step[-_]paus|nextStepPaus')"
    [ -n "$hits" ] || problems="$problems [scanner found no next-step-paused hits at all]"
    printf '%s\n' "$hits" | grep -q '/hooks/' || problems="$problems [no hits under hooks/]"
    printf '%s\n' "$hits" | grep -q 'settings\.json' || problems="$problems [no hits in settings.json]"
    if [ -z "$problems" ]; then
        pass "G2: the scanner is live — it still sees next-step-paused in hooks/ and settings.json"
    else
        fail "G2: scanner is not proving anything;$problems"
    fi
}

# ---------------------------------------------------------------------------
# M1: EXEMPTION_MATRIX — `background-work` row gone, `write-code-in-flight` row
#     present with the columns the plan fixes ({c4:true, c2:false,
#     nextStep:false}); nextStep:false is the deliberate difference from the
#     row it replaces. The three surviving siblings are asserted verbatim.
# ---------------------------------------------------------------------------
run_M1() {
    local out
    out=$("$RWT" 20 node -e "
const { EXEMPTION_MATRIX } = require('$POLICY_NODE');
const problems = [];
if ('background-work' in EXEMPTION_MATRIX) problems.push('background-work-row-still-present');
const row = EXEMPTION_MATRIX['write-code-in-flight'];
if (!row) {
  problems.push('write-code-in-flight-row-missing');
} else {
  if (row.c4 !== true) problems.push('write-code-in-flight:c4=' + row.c4);
  if (row.c2 !== false) problems.push('write-code-in-flight:c2=' + row.c2);
  if (row.nextStep !== false) problems.push('write-code-in-flight:nextStep=' + row.nextStep);
}
for (const id of ['workflow-off','next-step-paused','pre-workflow-init','delegated-reason']) {
  if (!EXEMPTION_MATRIX[id]) problems.push('sibling-row-lost:' + id);
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' ') : 'OK');" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "M1: EXEMPTION_MATRIX drops background-work, carries write-code-in-flight {c4:true,c2:false,nextStep:false}, keeps the 4 siblings"
    else
        fail "M1: matrix rows wrong; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# M2: the C4 consumer follows the matrix — same id set, same order, and the new
#     row occupies the slot the removed one vacated (directly after
#     pre-workflow-init), so first-match-wins precedence is unchanged.
#     buildExemptionDeps must supply the new predicate and no longer the old.
# ---------------------------------------------------------------------------
run_M2() {
    local out
    out=$("$RWT" 20 node -e "
const { EXEMPTION_MATRIX } = require('$POLICY_NODE');
const g = require('$GUARD_NODE');
const ids = g.C4_EXEMPTIONS.map((e) => e.id);
const problems = [];
if (ids.join(',') !== Object.keys(EXEMPTION_MATRIX).join(',')) {
  problems.push('drift table=' + ids.join(',') + ' matrix=' + Object.keys(EXEMPTION_MATRIX).join(','));
}
if (ids[ids.indexOf('pre-workflow-init') + 1] !== 'write-code-in-flight') {
  problems.push('slot=' + ids.join(','));
}
const row = g.C4_EXEMPTIONS.find((e) => e.id === 'write-code-in-flight');
if (!row || row.phase !== 'session') problems.push('phase=' + (row && row.phase));
const deps = g.buildExemptionDeps();
if (typeof deps.isWriteCodeInFlight !== 'function') problems.push('deps-missing-isWriteCodeInFlight');
if ('isBackgroundWorkInFlight' in deps) problems.push('deps-still-carry-isBackgroundWorkInFlight');
for (const k of ['isWorkflowOff','isNextStepPaused','isWorkflowStarted']) {
  if (typeof deps[k] !== 'function') problems.push('sibling-dep-lost:' + k);
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' ') : 'OK');" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "M2: C4_EXEMPTIONS matches the matrix, write-code-in-flight took the vacated slot, deps swapped predicates"
    else
        fail "M2: C4 consumer wiring wrong; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# K1: SESSION_MARKER_KINDS loses `background-work` and keeps the other five.
#     The derived PROTECTED_MARKER_SUFFIXES must follow automatically — a
#     surviving `.background-work` suffix would mean the protection list and
#     the marker list drifted apart.
# ---------------------------------------------------------------------------
run_K1() {
    local out
    out=$("$RWT" 20 node -e "
const p = require('$BASENAMES_NODE');
const problems = [];
if (p.SESSION_MARKER_KINDS.includes('background-work')) problems.push('kind-still-listed');
for (const k of ['workflow-off','worktree-off','issue-close-verified','next-step-paused','off-emergency-invoked']) {
  if (!p.SESSION_MARKER_KINDS.includes(k)) problems.push('sibling-kind-lost:' + k);
}
const suffixes = p.PROTECTED_MARKER_SUFFIXES || [];
if (suffixes.some((s) => /background-work/i.test(s))) problems.push('suffix-still-protected');
if (!suffixes.includes('.next-step-paused')) problems.push('sibling-suffix-lost');
process.stdout.write(problems.length ? 'BAD:' + problems.join(' ') : 'OK');" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "K1: SESSION_MARKER_KINDS drops background-work, keeps the 5 siblings, and the derived suffix list follows"
    else
        fail "K1: marker-kind list wrong; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# E1: session-markers.js no longer exports the pair that read the marker, and
#     still exports every sibling reader (the removal is scoped, not a purge).
# ---------------------------------------------------------------------------
run_E1() {
    local out
    out=$("$RWT" 20 node -e "
const sm = require('$MARKERS_NODE');
const problems = [];
for (const k of ['isBackgroundWorkInFlight','backgroundWorkNoticeText']) {
  if (k in sm) problems.push('still-exported:' + k);
}
for (const k of ['isWorkflowOff','isNextStepPaused','nextStepPausedNoticeText','isWorktreeOff','isIssueCloseVerified','readOffClearance']) {
  if (typeof sm[k] !== 'function') problems.push('sibling-export-lost:' + k);
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' ') : 'OK');" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "E1: session-markers.js drops the background-work reader pair and keeps every sibling reader"
    else
        fail "E1: session-markers exports wrong; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# S1: the sentinels themselves are gone from the recognizer. Both the strict
#     (`isStrictSentinel`) and the looks-like (`isSentinel`) verdicts must now
#     say "not a sentinel" for START/END, while the NEXT_STEP_PAUSE/RESUME pair
#     that inherits the use case stays recognized — the classifier's
#     non-targeted verdict is the CPR-ORTH counterpart of the targeted one.
# ---------------------------------------------------------------------------
run_S1() {
    local out
    out=$("$RWT" 20 node -e "
const sp = require('$PATTERNS_NODE');
const problems = [];
const gone = [
  'echo \"<<WORKFLOW_BACKGROUND_WORK_START: doing a long thing>>\"',
  'echo \"<<WORKFLOW_BACKGROUND_WORK_END: done>>\"',
  'echo \"<<WORKFLOW_BACKGROUND_WORK_START>>\"',
];
for (const cmd of gone) {
  if (sp.isSentinel(cmd)) problems.push('isSentinel-still-true:' + cmd);
  if (sp.isStrictSentinel(cmd)) problems.push('isStrictSentinel-still-true:' + cmd);
}
const kept = [
  'echo \"<<WORKFLOW_NEXT_STEP_PAUSE: waiting on a subagent>>\"',
  'echo \"<<WORKFLOW_NEXT_STEP_RESUME: subagent finished>>\"',
];
for (const cmd of kept) {
  if (!sp.isSentinel(cmd)) problems.push('sibling-unrecognized:' + cmd);
  if (!sp.isStrictSentinel(cmd)) problems.push('sibling-not-strict:' + cmd);
}
for (const k of Object.keys(sp)) {
  if (/background/i.test(k)) problems.push('export-survives:' + k);
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "S1: BACKGROUND_WORK_START/END are no longer sentinels (strict and looks-like), NEXT_STEP_PAUSE/RESUME still are"
    else
        fail "S1: sentinel recognizer wrong; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# P1: settings.json permission entries for the two sentinels are gone, and the
#     NEXT_STEP_PAUSE / NEXT_STEP_RESUME entries the migration points users at
#     are still there — a migration target that is not permitted would be
#     advice the user cannot follow.
# ---------------------------------------------------------------------------
run_P1() {
    local problems=""
    grep -q 'WORKFLOW_BACKGROUND_WORK_START' "$AGENTS_DIR/settings.json" &&
        problems="$problems [START permission entry survives]"
    grep -q 'WORKFLOW_BACKGROUND_WORK_END' "$AGENTS_DIR/settings.json" &&
        problems="$problems [END permission entry survives]"
    grep -q 'WORKFLOW_NEXT_STEP_PAUSE' "$AGENTS_DIR/settings.json" ||
        problems="$problems [NEXT_STEP_PAUSE permission entry missing]"
    grep -q 'WORKFLOW_NEXT_STEP_RESUME' "$AGENTS_DIR/settings.json" ||
        problems="$problems [NEXT_STEP_RESUME permission entry missing]"
    if [ -z "$problems" ]; then
        pass "P1: settings.json drops both BACKGROUND_WORK permissions and keeps the NEXT_STEP_PAUSE/RESUME pair"
    else
        fail "P1: permission wiring wrong;$problems"
    fi
}

# ---------------------------------------------------------------------------
# R1 (R6 of the plan): the removal is ANNOUNCED, not silent. The rule file must
#     name the replacement for the use case that is genuinely lost (non-write_code
#     long-running work) and must warn about the one property that changes —
#     NEXT_STEP_PAUSE has no TTL, so RESUME has to be issued by hand.
# ---------------------------------------------------------------------------
run_R1() {
    local f="$RULES_DIR/stop-guard-exemptions.md" problems=""
    if [ ! -f "$f" ]; then
        fail "R1: rules/stop-guard-exemptions.md not found (looked in $RULES_DIR)"
        return
    fi
    grep -q 'NEXT_STEP_PAUSE' "$f" || problems="$problems [no NEXT_STEP_PAUSE migration pointer]"
    grep -q 'NEXT_STEP_RESUME' "$f" || problems="$problems [no NEXT_STEP_RESUME reminder]"
    grep -qi 'TTL' "$f" || problems="$problems [no TTL note — the property change is unstated]"
    grep -qi 'write_code\|write-code' "$f" || problems="$problems [no write_code in-flight exemption described]"
    grep -qiE "$BG_RE" "$f" && problems="$problems [still documents the removed background-work primitive]"
    if [ -z "$problems" ]; then
        pass "R1: rules/stop-guard-exemptions.md announces the removal and points at NEXT_STEP_PAUSE (+ the missing-TTL caveat)"
    else
        fail "R1: migration guidance incomplete;$problems"
    fi
}

# ---------------------------------------------------------------------------
# Z1: cleanupZombies loses the `.background-work` arm without losing the arm
#     block. Behavioural, not textual: an aged `.next-step-paused` marker must
#     still be reclaimed, and a fresh one must survive.
# ---------------------------------------------------------------------------
run_Z1() {
    local tmp wf tn problems=""
    tmp="$(mktemp -d 2>/dev/null || mktemp -d -t 'bgz1665')"
    wf="$tmp/wf"; mkdir -p "$wf"
    tn="$(node_path "$wf")"
    : > "$wf/z1-old.next-step-paused"
    : > "$wf/z1-fresh.next-step-paused"
    P="$(node_path "$wf/z1-old.next-step-paused")" "$RWT" 15 node -e "
const fs = require('fs');
const t = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
fs.utimesSync(process.env.P, t, t);" >/dev/null 2>&1
    CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" "$RWT" 20 node -e "
require('$STATEIO_NODE').cleanupZombies();" >/dev/null 2>&1
    [ ! -f "$wf/z1-old.next-step-paused" ] || problems="$problems [stale next-step-paused marker survived the sweep]"
    [ -f "$wf/z1-fresh.next-step-paused" ] || problems="$problems [fresh next-step-paused marker was deleted]"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "Z1: the zombie sweep still reclaims aged sibling markers after the background-work arm is removed"
    else
        fail "Z1: sweep broken by the removal;$problems"
    fi
}

run_G1
run_G2
run_M1
run_M2
run_K1
run_E1
run_S1
run_P1
run_R1
run_Z1

cd / 2>/dev/null || true
rm -rf "$FIXTURE_ROOT" 2>/dev/null || true

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
