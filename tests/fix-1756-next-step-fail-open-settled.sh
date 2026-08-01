#!/usr/bin/env bash
# filename: tests/fix-1756-next-step-fail-open-settled.sh
# Tests: bin/workflow/next-step, bin/workflow/lib/next-step/, hooks/workflow-state/state-io/core.js
# Tags: workflow, next-step, fail-open, settled-status, TL2, scope:common
#
# #1756: the fail-open terminal branch in bin/workflow/next-step re-invokes
# /write-tests whenever an approval-gated step (outline / detail) is recorded
# `skipped`, and only bails out when write_tests is literally `"skipped"`.
# `write_tests: "complete"` — the normal path (tests written, reviewed, passed) —
# is not recognised as settled, so the session can never reach ACTION=done and
# the workflow nags forever after session-close.
#
# RED: F1 / F2 / F3 / F5 and every S1 / S2 assertion fail against the unmodified
# sources (the F cases return ACTION=invoke / NEXT_SKILL=write-tests instead of
# ACTION=done; the S cases have no helper to call yet). F4 / F6 / X1-X3 / L1-L4 /
# CHAR-1 are guards and baselines: they pass before AND after the fix.
#
# DISPATCHER. This file owns every shared helper, fixture fragment and counter;
# the cases live in tests/fix-1756-next-step-fail-open-settled/ and are sourced
# (not executed) so they share this file's helpers and PASS/FAIL counters.
# Split per rules/coding/file-split.md (Pattern A HARD limit).
#
# TL3 gap (what this test does NOT catch):
# - Real CLAUDE_SESSION_ID propagation from a live `claude -p` session into the
#   next-step invocation (here the session id is always passed explicitly).
# - The next-step verdict actually being consumed by the Claude Code host after
#   a real skill completes.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

# NOTE: `set -u` only, deliberately NOT `set -euo pipefail` — X3 captures nonzero
# exit codes on purpose, and the RED cases must all run to completion.
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NEXT_STEP="$AGENTS_DIR/bin/workflow/next-step"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

check_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then pass "$desc"
    else fail "$desc -- expected [$expected] got [$actual]"; fi
}

check_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then pass "$desc"
    else fail "$desc -- expected [$needle] in: $haystack"; fi
}

check_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        fail "$desc -- did NOT expect [$needle] in: $haystack"
    else pass "$desc"; fi
}

# Lower-bound check: the call-site count may legitimately grow (the later file
# split can add one), so pin a floor rather than an exact number.
check_min() {
    local desc="$1" floor="$2" actual="$3"
    case "$actual" in
        ''|*[!0-9]*) fail "$desc -- expected a number >= $floor, got [$actual]"; return;;
    esac
    if [ "$actual" -ge "$floor" ]; then pass "$desc"
    else fail "$desc -- expected >= $floor, got [$actual]"; fi
}

check_nonzero_rc() {
    local desc="$1" rc="$2"
    if [ "$rc" -ne 0 ]; then pass "$desc"
    else fail "$desc -- expected a nonzero exit code, got [$rc]"; fi
}

# ---------------------------------------------------------------------------
# Windows-compatible tmpdir shared between bash and Node.js
# ---------------------------------------------------------------------------
_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || echo "")
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
    _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
    _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
    TMPDIR_BASE=$(mktemp -d "/${_DRIVE}${_REST}/cctests1756.XXXXXXXX")
else
    TMPDIR_BASE=$(mktemp -d)
fi
trap 'rm -rf "$TMPDIR_BASE"' EXIT

to_node_path() { echo "$1" | sed 's|^/\([a-zA-Z]\)/|\1:/|'; }

WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR"
export CLAUDE_WORKFLOW_DIR="$(to_node_path "$WORKFLOW_DIR")"
export WORKFLOW_PLANS_DIR="$(to_node_path "$PLANS_DIR")"

setup_repo() {
    local repo="$TMPDIR_BASE/repo-$RANDOM-$$"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath ""
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial" --no-verify
    echo "$repo"
}

# Pin the evidence repo: without this, evidence predicates resolve against the
# agents repo itself and the fixtures would depend on the developer's index.
EVIDENCE_REPO="$(setup_repo)"
export CLAUDE_PROJECT_DIR="$(to_node_path "$EVIDENCE_REPO")"

# write_state <sid> <overrides-json> [closes-issues-json] [workflow-type]
# overrides-json maps step name -> partial step object (status, skip_reason, ...).
# Every unnamed step defaults to pending. plan_approvals is always populated for
# outline/detail so the #1133 approval invariant never turns a fixture into a
# false ACTION=blocked (detail plan R-9).
write_state() {
    local sid="$1" overrides="$2" issues="${3:-[1756]}" wtype="${4:-wf-code}"
    node -e '
const [sid, overrides, issues, wtype, out] = process.argv.slice(1);
const STEPS = ["workflow_init","clarify_intent","research","outline","detail",
  "branching_complete","write_tests","review_tests","run_tests","review_security",
  "docs","user_verification","cleanup","pre_final_report_gate"];
const o = JSON.parse(overrides);
const now = new Date().toISOString();
const steps = {};
for (const s of STEPS) {
  steps[s] = Object.assign({ status: "pending", updated_at: null }, o[s] || {});
  if (steps[s].status !== "pending") steps[s].updated_at = steps[s].updated_at || now;
}
const approval = (step) => ({ source: "confirm-flag-off", reason: "test fixture",
  artifact_sha256: null, artifact_session_id: sid,
  artifact_hash_status: "not-applicable", recorded_at: now });
const state = { version: 1, session_id: sid, git_branch: "main", is_bugfix: true,
  workflow_type: wtype, created_at: now, steps, closes_issues: JSON.parse(issues),
  plan_approvals: { outline: approval("outline"), detail: approval("detail") } };
require("fs").writeFileSync(out, JSON.stringify(state, null, 2), "utf8");
' "$sid" "$overrides" "$issues" "$wtype" "$(to_node_path "$WORKFLOW_DIR/$sid.json")"
}

raw_step_field() {
    local sid="$1" step="$2" field="$3"
    # Read through the canonical API: since #1733 `steps` is a PROJECTION over the
    # on-disk event stream, not a persisted top-level key.
    (cd "$AGENTS_DIR" && node -e '
const [sid, step, field] = process.argv.slice(1);
try {
  const s = require("./hooks/workflow-state").readState(sid);
  const v = s && s.steps && s.steps[step] && s.steps[step][field];
  process.stdout.write(v === undefined || v === null ? "" : String(v));
} catch (e) { process.stdout.write("MISSING"); }
' "$sid" "$step" "$field")
}

state_hash() {
    local sid="$1"
    node -e '
const f = process.argv[1];
try {
  const buf = require("fs").readFileSync(f);
  process.stdout.write(require("crypto").createHash("sha256").update(buf).digest("hex"));
} catch (e) { process.stdout.write("MISSING"); }
' "$(to_node_path "$WORKFLOW_DIR/$sid.json")"
}

run_next_step() { run_with_timeout 120 node "$NEXT_STEP" "$@" 2>/dev/null || true; }

# rc-aware sibling of run_next_step: keeps the REAL exit code instead of
# swallowing it with `|| true`. Sets RC_OUT (stdout) and RC_CODE (exit status),
# so a crash that still dumps partial stdout cannot false-green an assertion.
RC_OUT=""; RC_CODE=""
run_next_step_rc() {
    RC_OUT="$(run_with_timeout 120 node "$NEXT_STEP" "$@" 2>/dev/null)"
    RC_CODE=$?
}

# Marker column of `--list`: first 3 characters of every rendered line, joined
# with "|". Deliberately NOT a full-text compare — step descriptions are free to
# change without invalidating this characterization.
list_markers() {
    run_next_step "$@" | sed '/^$/d' | cut -c1-3 | paste -sd'|' -
}

new_sid() { printf '%s-%04x%04x' "$1" $RANDOM $RANDOM; }

# ---- Shared fixture fragments ---------------------------------------------
RV_OUTLINE='"outline":{"status":"skipped","skip_reason":"recorded-verdict: so_c1+so_c2 met"}'
RV_DETAIL='"detail":{"status":"skipped","skip_reason":"recorded-verdict: sd_c1+sd_c2+sd_c3 met"}'
SPEC_OUTLINE='"outline":{"status":"skipped","skip_reason":"speculative"}'
HEAD_COMPLETE='"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"}'
# Everything from branching_complete onward, all complete (write_tests included).
TAIL_COMPLETE='"branching_complete":{"status":"complete"},"write_tests":{"status":"complete"},"review_tests":{"status":"complete"},"run_tests":{"status":"complete"},"review_security":{"status":"complete"},"docs":{"status":"complete"},"user_verification":{"status":"complete"},"cleanup":{"status":"complete"},"pre_final_report_gate":{"status":"complete"}'
# Same, but write_tests carries an unrecognized status (must never read settled).
TAIL_WTS_BOGUS='"branching_complete":{"status":"complete"},"write_tests":{"status":"bogus"},"review_tests":{"status":"complete"},"run_tests":{"status":"complete"},"review_security":{"status":"complete"},"docs":{"status":"complete"},"user_verification":{"status":"complete"},"cleanup":{"status":"complete"},"pre_final_report_gate":{"status":"complete"}'
# Same, but write_tests still in flight (the negative branch of the predicate).
# The steps AFTER write_tests are left pending on purpose: a completed later step
# would trip the inconsistency scan / review_tests-ordering recovery (ACTION=abort)
# before any settled-status check is reached, and the probe would prove nothing.
TAIL_WTS_IN_PROGRESS='"branching_complete":{"status":"complete"},"write_tests":{"status":"in_progress"}'
# Same, but write_tests explicitly skipped (session opted out of tests).
TAIL_WTS_SKIPPED='"branching_complete":{"status":"complete"},"write_tests":{"status":"skipped","skip_reason":"tests not needed"},"review_tests":{"status":"complete"},"run_tests":{"status":"complete"},"review_security":{"status":"complete"},"docs":{"status":"complete"},"user_verification":{"status":"complete"},"cleanup":{"status":"complete"},"pre_final_report_gate":{"status":"complete"}'

# ---- Shared module probe (consumed by the S cases) -------------------------
# One guarded node run answers both the predicate-behavior table (S1) and the
# extraction-structure questions (S2). require() failures and a missing export
# degrade to NO-HELPER / "no" values instead of throwing, so the absent helper
# produces clean per-assertion FAIL lines rather than aborting the run.
# The source scan covers bin/workflow/next-step UNION every .js under
# bin/workflow/lib/next-step/ (created by the later file split; absent today and
# handled as an empty contribution).
# The two `=== "skipped"` comparisons that must SURVIVE the fix are deliberately
# not matchable by these regexes — see settled-predicate.sh for the analysis.
PROBE_OUT="$(run_with_timeout 60 node -e '
const [core, barrel, outer, entry, libdir] = process.argv.slice(1);
const fs = require("fs");
const req = (p) => { try { return require(p); } catch (_e) { return null; } };
const C = req(core), B = req(barrel), O = req(outer);
const isFn = (m) => !!(m && typeof m.isSettledStatus === "function");
const say = (k, v) => process.stdout.write(k + "=" + v + "\n");
const rows = [["complete","complete"],["skipped","skipped"],["pending","pending"],
  ["in_progress","in_progress"],["undefined",undefined],["null",null],
  ["empty",""],["bogus","bogus"]];
for (const [label, input] of rows) {
  if (!isFn(O)) { say(label, "NO-HELPER"); continue; }
  let r;
  try { r = O.isSettledStatus(input); } catch (e) { r = "THREW:" + e.message; }
  say(label, r === true ? "true" : (r === false ? "false" : "NON-BOOLEAN:" + String(r)));
}
say("core_export", isFn(C) ? "yes" : "no");
say("barrel_export", isFn(B) ? "yes" : "no");
say("outer_export", isFn(O) ? "yes" : "no");
say("same_ref", (isFn(C) && isFn(O) && C.isSettledStatus === O.isSettledStatus) ? "yes" : "no");
let src = "";
try { src += fs.readFileSync(entry, "utf8"); } catch (_e) { /* entry always exists */ }
try {
  for (const f of fs.readdirSync(libdir)) {
    if (f.endsWith(".js")) src += fs.readFileSync(libdir + "/" + f, "utf8");
  }
} catch (_e) { /* lib dir absent before the split — contributes nothing */ }
const count = (re) => (src.match(re) || []).length;
say("callsites", count(/isSettledStatus\(/g));
say("inline_pair", count(/!==\s*"complete"[^\n]{0,60}!==\s*"skipped"/g));
say("inline_terminal", count(/\.status\s*===\s*"skipped"\s*\)\s*continue/g));
' "$(to_node_path "$AGENTS_DIR/hooks/workflow-state/state-io/core.js")" \
  "$(to_node_path "$AGENTS_DIR/hooks/workflow-state/state-io.js")" \
  "$(to_node_path "$AGENTS_DIR/hooks/workflow-state")" \
  "$(to_node_path "$NEXT_STEP")" \
  "$(to_node_path "$AGENTS_DIR/bin/workflow/lib/next-step")" 2>/dev/null || true)"

s1_row() { printf '%s\n' "$PROBE_OUT" | awk -F= -v k="$1" '$1==k{print $2; found=1} END{if(!found) print "NO-OUTPUT"}'; }

echo "=== fix-1756: fail-open terminal branch must honor settled write_tests (TL2) ==="

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fix-1756-next-step-fail-open-settled"

# shellcheck source=./fix-1756-next-step-fail-open-settled/fail-open-cases.sh
. "$CASE_DIR/fail-open-cases.sh"
# shellcheck source=./fix-1756-next-step-fail-open-settled/settled-predicate.sh
. "$CASE_DIR/settled-predicate.sh"
# shellcheck source=./fix-1756-next-step-fail-open-settled/baselines.sh
. "$CASE_DIR/baselines.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
