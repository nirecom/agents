#!/bin/bash
# Tests: hooks/workflow-gate/review-tests-evidence.js, bin/compute-review-scope-fingerprint.js
# Tags: scope:issue-specific review-tests fingerprint manifest
#
# Unit and integration tests for the review-scope fingerprint functions
# introduced in #2327: isReviewScopeExcludedPath, isReviewScopeTestPath,
# computeReviewScopeManifest, fingerprintOfManifest, computeReviewScopeFingerprint,
# and the CLI bin/compute-review-scope-fingerprint.js.
#
# TDD: all tests FAIL until the plan-2327 implementation lands.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$AGENTS_DIR/tests/lib/harness.sh"

REVIEW_TESTS_EVIDENCE="$AGENTS_DIR/hooks/workflow-gate/review-tests-evidence.js"
CLI="$AGENTS_DIR/bin/compute-review-scope-fingerprint.js"
EVIDENCE_N="$(np "$REVIEW_TESTS_EVIDENCE")"
CLI_N="$(np "$CLI")"

TMPDIR_BASE="$(make_tmp)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
harness_isolate "$TMPDIR_BASE"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true

# Setup a minimal git repo with one initial commit, returns repo path.
setup_repo() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    harness_git_init "$repo"
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.autocrlf false
    mkdir -p "$repo"
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
case_begin "isReviewScopeExcludedPath-both-verdicts" "hooks/workflow-gate/review-tests-evidence.js"
# ============================================================================

echo "=== isReviewScopeExcludedPath: table-driven both verdicts ==="

EXCL_OUT=$(run_with_timeout 15 node -e "
try {
  var m = require('$EVIDENCE_N');
  if(typeof m.isReviewScopeExcludedPath !== 'function') {
    process.stdout.write('MISSING_FN'); process.exit(0);
  }
  var f = m.isReviewScopeExcludedPath;
  // Should be excluded (true)
  var shouldExclude = [
    'docs/foo.md', 'docs/history/2026.md', 'docs/readme.md',
    'CHANGELOG.md', 'changelog/2026.md', 'pkg/CHANGELOG.md',
    'README.md'
  ];
  // Should be included (false)
  var shouldInclude = [
    'rules/docs/changelog.md', 'skills/x/README.md',
    'hooks/foo.js', 'bin/tool.js', 'tests/foo.sh',
    'skills/review-tests/SKILL.md'
  ];
  var fails = [];
  shouldExclude.forEach(function(p) { if (!f(p)) fails.push('excl:'+p); });
  shouldInclude.forEach(function(p) { if (f(p)) fails.push('incl:'+p); });
  process.stdout.write(fails.length === 0 ? 'PASS' : 'FAIL:' + fails.join(','));
}
catch(e) { process.stdout.write('ERROR:' + e.message); }
" 2>/dev/null)
if [ "$EXCL_OUT" = "PASS" ]; then
    pass "isReviewScopeExcludedPath: table-driven both verdicts"
else
    fail "isReviewScopeExcludedPath table" "$EXCL_OUT"
fi

case_end

# ============================================================================
case_begin "isReviewScopeTestPath-both-verdicts" "hooks/workflow-gate/review-tests-evidence.js"
# ============================================================================

echo "=== isReviewScopeTestPath: both verdicts ==="

TEST_PATH_OUT=$(run_with_timeout 10 node -e "
try {
  var m = require('$EVIDENCE_N');
  if(typeof m.isReviewScopeTestPath !== 'function') {
    process.stdout.write('MISSING_FN'); process.exit(0);
  }
  var f = m.isReviewScopeTestPath;
  var shouldTrue = ['tests/foo.sh', 'tests/hooks/bar.sh', 'test/x.py'];
  var shouldFalse = ['src/foo.js', 'docs/foo.md', 'hooks/gate.js', 'bin/tool.js'];
  var fails = [];
  shouldTrue.forEach(function(p) { if (!f(p)) fails.push('true:'+p); });
  shouldFalse.forEach(function(p) { if (f(p)) fails.push('false:'+p); });
  process.stdout.write(fails.length === 0 ? 'PASS' : 'FAIL:' + fails.join(','));
}
catch(e) { process.stdout.write('ERROR:' + e.message); }
" 2>/dev/null)
if [ "$TEST_PATH_OUT" = "PASS" ]; then
    pass "isReviewScopeTestPath: true for tests/ and test/, false otherwise"
else
    fail "isReviewScopeTestPath" "$TEST_PATH_OUT"
fi

case_end

# ============================================================================
case_begin "manifest-scope-included-excluded" "hooks/workflow-gate/review-tests-evidence.js"
# ============================================================================

echo "=== computeReviewScopeManifest: scope inclusion/exclusion ==="

REPO_M="$(setup_repo "manifest")"
REPO_M_N="$(np "$REPO_M")"

# Stage: included files
stage_file "$REPO_M" "tests/cat/name/x.sh" "echo test"
stage_file "$REPO_M" "test/bar.sh" "echo bar"
stage_file "$REPO_M" "hooks/gate/impl.js" "module.exports={}"
stage_file "$REPO_M" "skills/x/SKILL.md" "# skill"
# Stage: excluded files
stage_file "$REPO_M" "docs/history.md" "history"
stage_file "$REPO_M" "CHANGELOG.md" "changelog"
stage_file "$REPO_M" "changelog/2026.md" "rotated"
stage_file "$REPO_M" "README.md" "readme"
# Also stage a deleted file to test exclusion (commit first, then delete)
git -C "$REPO_M" commit -q -m "base"
stage_file "$REPO_M" "hooks/delete-me.js" "to-delete"
git -C "$REPO_M" commit -q -m "add deleteme"
git -C "$REPO_M" rm -q "hooks/delete-me.js"
# Re-stage every file: the manifest covers staged paths only, so a file that
# is merely committed on the base is out of scope by definition.
stage_file "$REPO_M" "tests/cat/name/x.sh" "echo test2"
stage_file "$REPO_M" "test/bar.sh" "echo bar2"
stage_file "$REPO_M" "hooks/gate/impl.js" "module.exports={v:2}"
stage_file "$REPO_M" "skills/x/SKILL.md" "# skill v2"
stage_file "$REPO_M" "docs/history.md" "history2"
stage_file "$REPO_M" "CHANGELOG.md" "changelog2"
stage_file "$REPO_M" "changelog/2026.md" "rotated2"
stage_file "$REPO_M" "README.md" "readme2"

MANIFEST_SCOPE_OUT=$(run_with_timeout 15 node -e "
try {
  var m = require('$EVIDENCE_N');
  if(typeof m.computeReviewScopeManifest !== 'function') {
    process.stdout.write('MISSING_FN'); process.exit(0);
  }
  var r = m.computeReviewScopeManifest('$REPO_M_N');
  if(!r || !r.ok) { process.stdout.write('FAIL:ok=false'); process.exit(0); }
  var files = r.files;
  var paths = Object.keys(files);
  var included = ['tests/cat/name/x.sh','test/bar.sh','hooks/gate/impl.js','skills/x/SKILL.md'];
  // init.txt: committed on the base but not staged → absent
  var excluded = ['docs/history.md','CHANGELOG.md','changelog/2026.md','README.md','hooks/delete-me.js','init.txt'];
  var fails = [];
  included.forEach(function(p) { if (!files[p]) fails.push('miss:'+p); });
  excluded.forEach(function(p) { if (files[p]) fails.push('present:'+p); });
  process.stdout.write(fails.length === 0 ? 'PASS' : 'FAIL:' + fails.join(','));
}
catch(e) { process.stdout.write('ERROR:' + e.message); }
" 2>/dev/null)
if [ "$MANIFEST_SCOPE_OUT" = "PASS" ]; then
    pass "computeReviewScopeManifest: includes tests/impl, excludes docs/CHANGELOG/README/deleted"
else
    fail "computeReviewScopeManifest scope" "$MANIFEST_SCOPE_OUT"
fi

# Verify staging CHANGELOG.md additionally does not change the digest
# Stage CHANGELOG.md in addition to current staged state
DIGEST_BEFORE=$(run_with_timeout 15 node -e "
try {
  var m = require('$EVIDENCE_N');
  if(typeof m.computeReviewScopeFingerprint !== 'function') {
    process.stdout.write('MISSING_FN'); process.exit(0);
  }
  var r = m.computeReviewScopeFingerprint('$REPO_M_N');
  process.stdout.write(r && r.ok ? (r.fingerprint || 'EMPTY') : 'ERR');
}
catch(e) { process.stdout.write('ERROR:'+e.message); }
" 2>/dev/null)

# Stage an extra CHANGELOG.md change
stage_file "$REPO_M" "CHANGELOG.md" "even-more-changelog"

DIGEST_AFTER=$(run_with_timeout 15 node -e "
try {
  var m = require('$EVIDENCE_N');
  if(typeof m.computeReviewScopeFingerprint !== 'function') {
    process.stdout.write('MISSING_FN'); process.exit(0);
  }
  var r = m.computeReviewScopeFingerprint('$REPO_M_N');
  process.stdout.write(r && r.ok ? (r.fingerprint || 'EMPTY') : 'ERR');
}
catch(e) { process.stdout.write('ERROR:'+e.message); }
" 2>/dev/null)

if [ "$DIGEST_BEFORE" = "MISSING_FN" ] || [ "$DIGEST_BEFORE" = "ERR" ] || [ "$DIGEST_BEFORE" = "ERROR"* ]; then
    fail "changelog-no-digest-change: computeReviewScopeFingerprint not available"
elif [ "$DIGEST_BEFORE" = "$DIGEST_AFTER" ]; then
    pass "staging CHANGELOG.md additionally does not change the digest"
else
    fail "staging CHANGELOG.md changed digest" "before=$DIGEST_BEFORE after=$DIGEST_AFTER"
fi

case_end

# ============================================================================
case_begin "exclusion-ssot-special-cases" "hooks/workflow-gate/review-tests-evidence.js"
# ============================================================================

echo "=== exclusion SSOT: EXCLUDED_PATTERNS allowed, nested pkg/CHANGELOG excluded ==="

SSOT_OUT=$(run_with_timeout 10 node -e "
try {
  var m = require('$EVIDENCE_N');
  if(typeof m.isReviewScopeExcludedPath !== 'function') {
    process.stdout.write('MISSING_FN'); process.exit(0);
  }
  var f = m.isReviewScopeExcludedPath;
  var fails = [];
  // EXCLUDED_PATTERNS (rules/docs/changelog.md) must be INCLUDED (false)
  if(f('rules/docs/changelog.md')) fails.push('rules/docs/changelog.md should be included');
  if(f('rules/docs/history.md')) fails.push('rules/docs/history.md should be included');
  // Non-root README.md must be INCLUDED (false)
  if(f('skills/x/README.md')) fails.push('skills/x/README.md should be included');
  // docs/README.md sits under docs/, which is excluded as a whole
  if(!f('docs/README.md')) fails.push('docs/README.md (under docs/) should be excluded');
  // Nested pkg/CHANGELOG.md must be EXCLUDED (true) — isProtectedPath covers it
  if(!f('pkg/CHANGELOG.md')) fails.push('pkg/CHANGELOG.md should be excluded');
  if(!f('CHANGELOG.MD')) fails.push('CHANGELOG.MD (case-insensitive) should be excluded');
  process.stdout.write(fails.length === 0 ? 'PASS' : 'FAIL:' + fails.join('; '));
}
catch(e) { process.stdout.write('ERROR:' + e.message); }
" 2>/dev/null)
if [ "$SSOT_OUT" = "PASS" ]; then
    pass "exclusion SSOT: EXCLUDED_PATTERNS included; nested CHANGELOG excluded; non-root README included"
else
    fail "exclusion SSOT special cases" "$SSOT_OUT"
fi

case_end

# ============================================================================
case_begin "fingerprint-determinism" "hooks/workflow-gate/review-tests-evidence.js"
# ============================================================================

echo "=== fingerprintOfManifest: determinism and order-independence ==="

DET_OUT=$(run_with_timeout 10 node -e "
var crypto = require('crypto');
try {
  var m = require('$EVIDENCE_N');
  if(typeof m.fingerprintOfManifest !== 'function') {
    process.stdout.write('MISSING_FN'); process.exit(0);
  }
  var f = m.fingerprintOfManifest;
  var files = { 'tests/b.sh': 'aaa', 'tests/a.sh': 'bbb', 'hooks/c.js': 'ccc' };
  var r1 = f(files);
  var r2 = f(files);
  // Independent oracle: sorted path\toid joined by \n, sha256 first 16 hex
  var rows = Object.keys(files).map(function(p) { return p + '\t' + files[p]; });
  rows.sort();
  var oracle = crypto.createHash('sha256').update(rows.join('\n')).digest('hex').slice(0, 16);
  if(r1 !== r2) { process.stdout.write('FAIL:not-idempotent r1='+r1+' r2='+r2); process.exit(0); }
  if(r1 !== oracle) { process.stdout.write('FAIL:oracle-mismatch got='+r1+' want='+oracle); process.exit(0); }
  if(!/^[0-9a-f]{16}$/.test(r1)) { process.stdout.write('FAIL:format r1='+r1); process.exit(0); }
  // Order-independence: insert in different order
  var files2 = { 'hooks/c.js': 'ccc', 'tests/a.sh': 'bbb', 'tests/b.sh': 'aaa' };
  var r3 = f(files2);
  process.stdout.write(r1 === r3 ? 'PASS' : 'FAIL:order-dependent r1='+r1+' r3='+r3);
}
catch(e) { process.stdout.write('ERROR:' + e.message); }
" 2>/dev/null)
if [ "$DET_OUT" = "PASS" ]; then
    pass "fingerprintOfManifest: deterministic, order-independent, matches oracle"
else
    fail "fingerprintOfManifest determinism" "$DET_OUT"
fi

case_end

# ============================================================================
case_begin "zero-files-vs-git-error" "hooks/workflow-gate/review-tests-evidence.js"
# ============================================================================

echo "=== computeReviewScopeManifest: 0-files vs git-error distinction ==="

REPO_Z="$(setup_repo "zero-files")"
REPO_Z_N="$(np "$REPO_Z")"
# No staged files → 0 files (not an error)

ZERO_OUT=$(run_with_timeout 15 node -e "
try {
  var m = require('$EVIDENCE_N');
  if(typeof m.computeReviewScopeManifest !== 'function') {
    process.stdout.write('MISSING_FN'); process.exit(0);
  }
  var r = m.computeReviewScopeManifest('$REPO_Z_N');
  // ok:true with empty files = 0 staged review-scope files
  if(!r || !r.ok) { process.stdout.write('FAIL:ok=false files=0 should be ok:true'); process.exit(0); }
  if(Object.keys(r.files).length !== 0) { process.stdout.write('FAIL:expected empty files'); process.exit(0); }
  // git error: non-existent dir → ok:false
  var r2 = m.computeReviewScopeManifest('/nonexistent/path/$$');
  if(!r2 || r2.ok !== false) { process.stdout.write('FAIL:git-error should be ok:false'); process.exit(0); }
  process.stdout.write('PASS');
}
catch(e) { process.stdout.write('ERROR:' + e.message); }
" 2>/dev/null)
if [ "$ZERO_OUT" = "PASS" ]; then
    pass "computeReviewScopeManifest: 0 files → ok:true files:{}, git error → ok:false"
else
    fail "zero-files vs git-error" "$ZERO_OUT"
fi

case_end

# ============================================================================
case_begin "cli-exit-codes" "bin/compute-review-scope-fingerprint.js"
# ============================================================================

echo "=== CLI: exit codes and output format ==="

if [ ! -f "$CLI" ]; then
    fail "cli-exit-0-normal: bin/compute-review-scope-fingerprint.js not found (impl pending)"
    fail "cli-exit-0-zero-files: bin/compute-review-scope-fingerprint.js not found"
    fail "cli-exit-1-error: bin/compute-review-scope-fingerprint.js not found"
else
    # Normal case: repo with staged test file → 16-hex stdout exit 0
    REPO_C="$(setup_repo "cli-normal")"
    stage_file "$REPO_C" "tests/foo.sh" "echo foo"
    REPO_C_N="$(np "$REPO_C")"
    CLI_NORMAL_OUT=$(run_with_timeout 15 node "$CLI_N" "$REPO_C_N" 2>/dev/null)
    CLI_NORMAL_RC=$?
    if [ $CLI_NORMAL_RC -eq 0 ] && printf '%s' "$CLI_NORMAL_OUT" | grep -qE '^[0-9a-f]{16}$'; then
        pass "CLI: normal case → 16-hex stdout exit 0"
    else
        fail "CLI normal" "rc=$CLI_NORMAL_RC out=$CLI_NORMAL_OUT"
    fi

    # Zero-files case: no staged review-scope files → empty stdout exit 0
    REPO_Z2="$(setup_repo "cli-zero")"
    REPO_Z2_N="$(np "$REPO_Z2")"
    CLI_ZERO_OUT=$(run_with_timeout 15 node "$CLI_N" "$REPO_Z2_N" 2>/dev/null)
    CLI_ZERO_RC=$?
    if [ $CLI_ZERO_RC -eq 0 ] && [ -z "$CLI_ZERO_OUT" ]; then
        pass "CLI: 0 review-scope files → empty stdout exit 0"
    else
        fail "CLI zero-files" "rc=$CLI_ZERO_RC out=$CLI_ZERO_OUT"
    fi

    # Error case: non-existent repo → exit 1 + stderr
    CLI_ERR_OUT=$(run_with_timeout 15 node "$CLI_N" "/nonexistent/repo/$$" 2>&1)
    CLI_ERR_RC=$?
    if [ $CLI_ERR_RC -eq 1 ]; then
        pass "CLI: non-existent repo → exit 1 + stderr"
    else
        fail "CLI error" "rc=$CLI_ERR_RC out=$CLI_ERR_OUT"
    fi
fi

case_end

# ============================================================================
case_begin "non-ascii-path" "hooks/workflow-gate/review-tests-evidence.js"
# ============================================================================

echo "=== Non-ASCII filename in manifest (quotePath must not break it) ==="

REPO_NA="$(setup_repo "non-ascii")"
REPO_NA_N="$(np "$REPO_NA")"

# Force the octal-quoting default explicitly: an implementation that parses
# newline-delimited output without -z would key the manifest by "\"tests/t\303\253st...\"".
git -C "$REPO_NA" config core.quotepath true
# UTF-8 bytes built from ASCII source so the fixture does not depend on the file encoding.
NA_REL="tests/$(printf 't\303\253st-\303\244\303\266\303\274.sh')"
stage_file "$REPO_NA" "$NA_REL" "echo non-ascii"
if git -C "$REPO_NA" ls-files -z --cached -- tests | grep -q "st-"; then
    pass "non-ascii-path: fixture staged the UTF-8 filename"
else
    fail "non-ascii-path: fixture failed to stage the UTF-8 filename"
fi

NON_ASCII_OUT=$(run_with_timeout 15 node -e "
try {
  var m = require('$EVIDENCE_N');
  if(typeof m.computeReviewScopeManifest !== 'function') {
    process.stdout.write('MISSING_FN'); process.exit(0);
  }
  var r = m.computeReviewScopeManifest('$REPO_NA_N');
  if(!r || !r.ok) { process.stdout.write('FAIL:ok=false'); process.exit(0); }
  var keys = Object.keys(r.files);
  var want = 'tests/tëst-äöü.sh';
  var exact = keys.length === 1 && keys[0] === want;
  process.stdout.write(exact ? 'PASS:' + Buffer.from(keys[0], 'utf8').toString('hex')
                             : 'FAIL:keys=' + JSON.stringify(keys));
}
catch(e) { process.stdout.write('ERROR:' + e.message); }
" 2>/dev/null)
# The manifest key must be byte-identical to the staged path ($NA_REL), not an ASCII fold.
NA_REL_HEX="$(printf '%s' "$NA_REL" | od -An -tx1 | tr -d ' \n')"
if [ "$NON_ASCII_OUT" = "PASS:$NA_REL_HEX" ]; then
    pass "Non-ASCII filename recorded as the exact staged UTF-8 path under core.quotepath=true"
else
    fail "non-ascii-path" "want=PASS:$NA_REL_HEX got=$NON_ASCII_OUT"
fi

case_end

# ============================================================================
echo ""
TOTAL=$((PASS + FAIL))
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
[ "$FAIL" -eq 0 ]
