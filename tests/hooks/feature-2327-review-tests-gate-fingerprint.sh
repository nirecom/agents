#!/bin/bash
# Tests: hooks/workflow-gate/review-tests-checker.js, hooks/workflow-gate/review-tests-evidence.js
# Tags: scope:issue-specific review-tests fingerprint gate
#
# Gate judgment tests for the new fingerprint-based review_tests check (#2327).
# Covers: gate judgments 1-9, evaluateReviewScopeFreshness mapping, old-token
# block, calc-error block, impl-only stale block, and static digest-isolation check.
#
# TDD: tests FAIL until plan-2327 stage-2 implementation lands.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$AGENTS_DIR/tests/lib/harness.sh"

CHECKER="$AGENTS_DIR/hooks/workflow-gate/review-tests-checker.js"
EVIDENCE="$AGENTS_DIR/hooks/workflow-gate/review-tests-evidence.js"
CHECKER_N="$(np "$CHECKER")"
EVIDENCE_N="$(np "$EVIDENCE")"

TMPDIR_BASE="$(make_tmp)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
harness_isolate "$TMPDIR_BASE"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true

setup_repo() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    harness_git_init "$repo"
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.autocrlf false
    printf 'init\n' > "$repo/init.txt"
    git -C "$repo" add init.txt
    git -C "$repo" commit -q -m "initial"
    echo "$repo"
}

stage_file() {
    local repo="$1" relpath="$2" content="${3:-content}"
    mkdir -p "$(dirname "$repo/$relpath")"
    printf '%s\n' "$content" > "$repo/$relpath"
    git -C "$repo" add "$relpath"
}

# ============================================================================
case_begin "gate-judgments-1-4-unchanged" "hooks/workflow-gate/review-tests-checker.js"
# ============================================================================

echo "=== Gate judgments 1-4 (unchanged behavior) ==="

# G1: docsOnly → skip
G1_OUT=$(run_with_timeout 10 node -e "
try {
  var m = require('$CHECKER_N');
  var r = m.checkReviewTests('review_tests', null, {docsOnly:true, writeTestsEvidenceBypassed:false, repoDir:'.'});
  process.stdout.write(r.action === 'skip' ? 'PASS' : 'FAIL:'+r.action);
}
catch(e) { process.stdout.write('ERROR:'+e.message); }
" 2>/dev/null)
[ "$G1_OUT" = "PASS" ] && pass "G1: docsOnly → skip" || fail "G1: docsOnly" "$G1_OUT"

# G2: skipped + bugfix → block (existing test maintained)
G2_OUT=$(run_with_timeout 10 node -e "
try {
  var m = require('$CHECKER_N');
  var r = m.checkReviewTests('review_tests', {status:'skipped'}, {docsOnly:false, writeTestsEvidenceBypassed:false, repoDir:'.'});
  process.stdout.write(r.action === 'skip' || r.action === 'block' ? 'PASS' : 'FAIL:'+r.action);
}
catch(e) { process.stdout.write('ERROR:'+e.message); }
" 2>/dev/null)
[ "$G2_OUT" = "PASS" ] && pass "G2: skipped status handled (skip or block)" || fail "G2: skipped" "$G2_OUT"

# G3: status != complete → block
G3_OUT=$(run_with_timeout 10 node -e "
try {
  var m = require('$CHECKER_N');
  var r = m.checkReviewTests('review_tests', {status:'pending'}, {docsOnly:false, writeTestsEvidenceBypassed:false, repoDir:'.'});
  process.stdout.write(r.action === 'block' ? 'PASS' : 'FAIL:'+r.action);
}
catch(e) { process.stdout.write('ERROR:'+e.message); }
" 2>/dev/null)
[ "$G3_OUT" = "PASS" ] && pass "G3: pending status → block" || fail "G3: pending" "$G3_OUT"

# G4: warnings_summary set → block/warnings-pending
G4_OUT=$(run_with_timeout 10 node -e "
try {
  var m = require('$CHECKER_N');
  var r = m.checkReviewTests('review_tests', {status:'complete',warnings_summary:'gaps'}, {docsOnly:false, writeTestsEvidenceBypassed:false, repoDir:'.'});
  process.stdout.write(r.action === 'block' && r.reason === 'warnings-pending' ? 'PASS' : 'FAIL:'+JSON.stringify(r));
}
catch(e) { process.stdout.write('ERROR:'+e.message); }
" 2>/dev/null)
[ "$G4_OUT" = "PASS" ] && pass "G4: warnings_summary → block/warnings-pending" || fail "G4: warnings_summary" "$G4_OUT"

case_end

# ============================================================================
case_begin "gate-judgment-5-fingerprint-unavailable" "hooks/workflow-gate/review-tests-checker.js"
# ============================================================================

echo "=== G5: calc error → block/fingerprint-unavailable ==="

# non-existent repoDir → computeReviewScopeFingerprint returns ok:false → unavailable
G5_OUT=$(run_with_timeout 15 node -e "
try {
  var m = require('$CHECKER_N');
  var stepState = {status:'complete', review_scope_manifest:{v:1,files:{}}};
  var r = m.checkReviewTests('review_tests', stepState, { docsOnly:false, writeTestsEvidenceBypassed:false,
    repoDir:'/nonexistent/path/g5test'
  });
  process.stdout.write(r.action === 'block' && r.reason === 'fingerprint-unavailable' ? 'PASS' : 'FAIL:'+JSON.stringify(r));
}
catch(e) { process.stdout.write('ERROR:'+e.message); }
" 2>/dev/null)
[ "$G5_OUT" = "PASS" ] && pass "G5: git error → block/fingerprint-unavailable" || fail "G5: unavailable" "$G5_OUT"

case_end

# ============================================================================
case_begin "gate-judgment-6-no-tests-skip" "hooks/workflow-gate/review-tests-checker.js"
# ============================================================================

echo "=== G6: no staged tests → skip ==="

REPO_G6="$(setup_repo "g6")"
REPO_G6_N="$(np "$REPO_G6")"
# No staged test files (only non-test staged file)
stage_file "$REPO_G6" "hooks/impl.js" "module.exports={}"

G6_OUT=$(run_with_timeout 15 node -e "
try {
  var m = require('$CHECKER_N');
  var stepState = {status:'complete', review_scope_manifest:{v:1,files:{}}};
  var r = m.checkReviewTests('review_tests', stepState, { docsOnly:false, writeTestsEvidenceBypassed:false,
    repoDir:'$REPO_G6_N'
  });
  process.stdout.write(r.action === 'skip' ? 'PASS' : 'FAIL:'+JSON.stringify(r));
}
catch(e) { process.stdout.write('ERROR:'+e.message); }
" 2>/dev/null)
[ "$G6_OUT" = "PASS" ] && pass "G6: no staged tests → skip" || fail "G6: no-tests" "$G6_OUT"

case_end

# ============================================================================
case_begin "gate-judgment-7-fingerprint-missing-old-token" "hooks/workflow-gate/review-tests-checker.js"
# ============================================================================

echo "=== G7: old-token-only state → block/fingerprint-missing ==="

REPO_G7="$(setup_repo "g7")"
REPO_G7_N="$(np "$REPO_G7")"
stage_file "$REPO_G7" "tests/foo.sh" "echo test"

G7_OUT=$(run_with_timeout 15 node -e "
try {
  var m = require('$CHECKER_N');
  // Old-format state: has token but no review_scope_manifest
  var stepState = {status:'complete', token:'abc123def456abcd'};
  var r = m.checkReviewTests('review_tests', stepState, { docsOnly:false, writeTestsEvidenceBypassed:false,
    repoDir:'$REPO_G7_N'
  });
  process.stdout.write(r.action === 'block' && r.reason === 'fingerprint-missing' ? 'PASS' : 'FAIL:'+JSON.stringify(r));
}
catch(e) { process.stdout.write('ERROR:'+e.message); }
" 2>/dev/null)
[ "$G7_OUT" = "PASS" ] && pass "G7: old-token-only complete state → block/fingerprint-missing" || fail "G7: fingerprint-missing" "$G7_OUT"

# Also test: no token, no manifest, status=complete → fingerprint-missing
G7B_OUT=$(run_with_timeout 15 node -e "
try {
  var m = require('$CHECKER_N');
  var stepState = {status:'complete'};
  var r = m.checkReviewTests('review_tests', stepState, { docsOnly:false, writeTestsEvidenceBypassed:false,
    repoDir:'$REPO_G7_N'
  });
  process.stdout.write(r.action === 'block' && r.reason === 'fingerprint-missing' ? 'PASS' : 'FAIL:'+JSON.stringify(r));
}
catch(e) { process.stdout.write('ERROR:'+e.message); }
" 2>/dev/null)
[ "$G7B_OUT" = "PASS" ] && pass "G7b: no manifest, complete → block/fingerprint-missing" || fail "G7b: fingerprint-missing no manifest" "$G7B_OUT"

case_end

# ============================================================================
case_begin "gate-judgment-8-match-skip" "hooks/workflow-gate/review-tests-checker.js"
# ============================================================================

echo "=== G8: matching manifest → skip ==="

REPO_G8="$(setup_repo "g8")"
REPO_G8_N="$(np "$REPO_G8")"
stage_file "$REPO_G8" "tests/foo.sh" "echo test"

# Compute current manifest and use it as stored manifest
G8_OUT=$(run_with_timeout 15 node -e "
try {
  var m = require('$CHECKER_N');
  var e = require('$EVIDENCE_N');
  if(typeof e.computeReviewScopeManifest !== 'function') {
    process.stdout.write('MISSING_FN'); process.exit(0);
  }
  var manifest = e.computeReviewScopeManifest('$REPO_G8_N');
  if(!manifest.ok) { process.stdout.write('FAIL:manifest-err'); process.exit(0); }
  // Stored = current manifest → should match → skip
  var stepState = {status:'complete', review_scope_manifest:{v:1, files:manifest.files}};
  var r = m.checkReviewTests('review_tests', stepState, { docsOnly:false, writeTestsEvidenceBypassed:false,
    repoDir:'$REPO_G8_N'
  });
  process.stdout.write(r.action === 'skip' ? 'PASS' : 'FAIL:'+JSON.stringify(r));
}
catch(e) { process.stdout.write('ERROR:'+e.message); }
" 2>/dev/null)
[ "$G8_OUT" = "PASS" ] && pass "G8: matching manifest → skip" || fail "G8: match" "$G8_OUT"

case_end

# ============================================================================
case_begin "gate-judgment-9-stale-fingerprint-impl-change" "hooks/workflow-gate/review-tests-checker.js"
# ============================================================================

echo "=== G9: stale fingerprint (impl-only change) → block/stale-fingerprint ==="

REPO_G9="$(setup_repo "g9")"
REPO_G9_N="$(np "$REPO_G9")"
stage_file "$REPO_G9" "tests/foo.sh" "echo test"
stage_file "$REPO_G9" "hooks/impl.js" "v1"

# Compute manifest BEFORE (only tests/foo.sh + hooks/impl.js v1)
G9_OUT=$(run_with_timeout 15 node -e "
try {
  var m = require('$CHECKER_N');
  var e = require('$EVIDENCE_N');
  if(typeof e.computeReviewScopeManifest !== 'function') {
    process.stdout.write('MISSING_FN'); process.exit(0);
  }
  // Stored manifest: current state
  var stored = e.computeReviewScopeManifest('$REPO_G9_N');
  if(!stored.ok) { process.stdout.write('FAIL:manifest-err'); process.exit(0); }
  var stepState = {status:'complete', review_scope_manifest:{v:1, files:stored.files}};
  // Return stored stepState and current state for use in bash
  process.stdout.write(JSON.stringify({ok:true, files:stored.files}));
}
catch(err) { process.stdout.write('ERROR:'+err.message); }
" 2>/dev/null)

if echo "$G9_OUT" | grep -q '"ok":true'; then
    # Now change the impl file (impl-only change → should be stale)
    stage_file "$REPO_G9" "hooks/impl.js" "v2-changed"

    G9_STALE_OUT=$(run_with_timeout 15 node -e "
try {
  var m = require('$CHECKER_N');
  var e = require('$EVIDENCE_N');
  var storedFiles = JSON.parse(process.argv[2]).files;
  var stepState = {status:'complete', review_scope_manifest:{v:1, files:storedFiles}};
  var r = m.checkReviewTests('review_tests', stepState, { docsOnly:false, writeTestsEvidenceBypassed:false,
    repoDir:process.argv[1]
  });
  process.stdout.write(r.action === 'block' && r.reason === 'stale-fingerprint' ? 'PASS' : 'FAIL:'+JSON.stringify(r));
}
catch(err) { process.stdout.write('ERROR:'+err.message); }
" -- "$REPO_G9_N" "$G9_OUT" 2>/dev/null)
    [ "$G9_STALE_OUT" = "PASS" ] && pass "G9: impl-only change → block/stale-fingerprint" || fail "G9: stale-fingerprint" "$G9_STALE_OUT"
else
    fail "G9 setup: could not compute initial manifest" "$G9_OUT"
fi

case_end

# ============================================================================
case_begin "evaluate-freshness-mapping-table" "hooks/workflow-gate/review-tests-evidence.js"
# ============================================================================

echo "=== evaluateReviewScopeFreshness: mapping table ==="

REPO_EF="$(setup_repo "freshness")"
REPO_EF_N="$(np "$REPO_EF")"
stage_file "$REPO_EF" "tests/bar.sh" "echo bar"

EF_OUT=$(run_with_timeout 15 node -e "
try {
  var e = require('$EVIDENCE_N');
  if(typeof e.evaluateReviewScopeFreshness !== 'function') {
    process.stdout.write('MISSING_FN'); process.exit(0);
  }
  var compute = e.computeReviewScopeFingerprint;
  if(typeof compute !== 'function') { process.stdout.write('MISSING_FN:computeReviewScopeFingerprint'); process.exit(0); }
  var cur = compute('$REPO_EF_N');
  if(!cur.ok) { process.stdout.write('FAIL:compute-err'); process.exit(0); }
  var fails = [];
  // unavailable: ok:false
  var r1 = e.evaluateReviewScopeFreshness({status:'complete',review_scope_manifest:{v:1,files:{}}}, {ok:false});
  if(r1.fresh || r1.reason !== 'unavailable') fails.push('unavailable:'+JSON.stringify(r1));
  // no-tests: testCount===0
  var r2 = e.evaluateReviewScopeFreshness({status:'complete',review_scope_manifest:{v:1,files:{}}}, {ok:true,fingerprint:null,testCount:0});
  if(!r2.fresh || r2.reason !== 'no-tests') fails.push('no-tests:'+JSON.stringify(r2));
  // missing: no review_scope_manifest
  var r3 = e.evaluateReviewScopeFreshness({status:'complete', token:'abc'}, cur);
  if(r3.fresh || r3.reason !== 'missing') fails.push('missing:'+JSON.stringify(r3));
  // match: stored matches current
  var r4 = e.evaluateReviewScopeFreshness({status:'complete', review_scope_manifest:{v:1,files:cur.files||{}}}, cur);
  if(!r4.fresh || r4.reason !== 'match') fails.push('match:'+JSON.stringify(r4));
  // stale: stored has different files
  var r5 = e.evaluateReviewScopeFreshness({status:'complete', review_scope_manifest:{v:1,files:{'other.js':'oid1'}}}, cur);
  if(r5.fresh || r5.reason !== 'stale') fails.push('stale:'+JSON.stringify(r5));
  process.stdout.write(fails.length === 0 ? 'PASS' : 'FAIL:' + fails.join('; '));
}
catch(err) { process.stdout.write('ERROR:'+err.message); }
" 2>/dev/null)
[ "$EF_OUT" = "PASS" ] && pass "evaluateReviewScopeFreshness: all 5 reason mappings correct" || fail "evaluateReviewScopeFreshness mapping" "$EF_OUT"

case_end

# ============================================================================
case_begin "static-checker-no-digest-comparison" "hooks/workflow-gate/review-tests-checker.js"
# ============================================================================

echo "=== Static: review-tests-checker.js does not compare digests directly ==="

if [ ! -f "$CHECKER" ]; then
    fail "static-no-digest: checker file not found (impl pending)"
else
    # Must call evaluateReviewScopeFreshness (new implementation)
    if grep -q 'evaluateReviewScopeFreshness' "$CHECKER" 2>/dev/null; then
        # Must NOT contain direct digest comparison
        if grep -qE 'createHash|fingerprintOfManifest|\.fingerprint\s*===' "$CHECKER" 2>/dev/null; then
            fail "checker.js compares digests directly — must delegate to evaluateReviewScopeFreshness"
        else
            pass "checker.js delegates digest comparison to evaluateReviewScopeFreshness"
        fi
    else
        fail "checker.js does not call evaluateReviewScopeFreshness (impl pending)"
    fi
fi

case_end

# ============================================================================
echo ""
TOTAL=$((PASS + FAIL))
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
[ "$FAIL" -eq 0 ]
