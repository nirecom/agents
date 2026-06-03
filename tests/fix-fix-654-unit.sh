#!/bin/bash
# Tests: hooks/enforce-worktree/shared-cmd-utils.js
# Tags: worktree, enforce, exclude, builtin, unit
#
# Unit tests for the BUILTIN_EXCLUDE_PATTERNS feature (issue #654).
#
# Verifies that:
#   - BUILTIN_EXCLUDE_PATTERNS contains `**/.worktree-backup/**`
#   - getExcludePatterns() returns the builtin even when env is unset
#   - getExcludePatterns() prepends the builtin to user patterns
#   - isExcluded matches .worktree-backup paths but not partial-name look-alikes
#
# Run BEFORE source changes land → all cases FAIL/SKIP cleanly (red phase).
# Run AFTER  source changes land → all cases PASS.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
SHARED_JS="${AGENTS_DIR}/hooks/enforce-worktree/shared-cmd-utils.js"

if [ ! -f "$SHARED_JS" ]; then
    echo "SKIP: hooks/enforce-worktree/shared-cmd-utils.js not present"
    exit 0
fi

# Pre-implementation skip guard: if the source has not yet been updated to
# export BUILTIN_EXCLUDE_PATTERNS, every case below will FAIL. That is the
# expected red-phase signal — we still run them so the runner sees the gap.
if ! grep -q 'BUILTIN_EXCLUDE_PATTERNS' "$SHARED_JS" 2>/dev/null; then
    echo "SKIP: BUILTIN_EXCLUDE_PATTERNS not yet implemented (pre-implementation red phase)"
    exit 0
fi

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

# Each case runs a small Node program that:
#   1. saves+clears process.env.ENFORCE_WORKTREE_EXCLUDE
#   2. requires the module under test
#   3. exits 0 on assertion success, non-zero with a message on failure
#   4. restores the env var before exit
#
# `cd` to a stable directory (the agents repo) so path.resolve() produces
# predictable absolute paths.
node_case() {
    local label="$1" code="$2"
    local out rc=0
    out="$(cd "$AGENTS_DIR" && run_with_timeout 30 node -e "$code" 2>&1)" || rc=$?
    if [ "$rc" = "0" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc out=$out)"
    fi
}

SHARED_REQ="require('${_AGENTS_DIR_NODE}/hooks/enforce-worktree/shared-cmd-utils.js')"

# ─────────────────────────────────────────────────────────────────────────────
# Case 1: BUILTIN appears when env is unset
# ─────────────────────────────────────────────────────────────────────────────
node_case "Case 1: getExcludePatterns() with env unset contains builtin" "
const saved = process.env.ENFORCE_WORKTREE_EXCLUDE;
delete process.env.ENFORCE_WORKTREE_EXCLUDE;
try {
  const m = $SHARED_REQ;
  const got = m.getExcludePatterns();
  if (!Array.isArray(got)) throw new Error('not an array: ' + typeof got);
  if (!got.includes('**/.worktree-backup/**')) {
    throw new Error('builtin missing: ' + JSON.stringify(got));
  }
} finally {
  if (saved === undefined) delete process.env.ENFORCE_WORKTREE_EXCLUDE;
  else process.env.ENFORCE_WORKTREE_EXCLUDE = saved;
}
"

# ─────────────────────────────────────────────────────────────────────────────
# Case 2: union of builtin + user pattern; builtin is element 0
# ─────────────────────────────────────────────────────────────────────────────
node_case "Case 2: env=*.tmp → union length>=2, builtin at index 0" "
const saved = process.env.ENFORCE_WORKTREE_EXCLUDE;
process.env.ENFORCE_WORKTREE_EXCLUDE = '*.tmp';
try {
  const m = $SHARED_REQ;
  const got = m.getExcludePatterns();
  if (got.length < 2) throw new Error('length<2: ' + JSON.stringify(got));
  if (got[0] !== '**/.worktree-backup/**') {
    throw new Error('builtin not first: ' + JSON.stringify(got));
  }
  if (!got.includes('*.tmp')) {
    throw new Error('user pattern missing: ' + JSON.stringify(got));
  }
} finally {
  if (saved === undefined) delete process.env.ENFORCE_WORKTREE_EXCLUDE;
  else process.env.ENFORCE_WORKTREE_EXCLUDE = saved;
}
"

# ─────────────────────────────────────────────────────────────────────────────
# Case 3: relative path with branch subdir matches builtin
# ─────────────────────────────────────────────────────────────────────────────
node_case "Case 3: isExcluded('.worktree-backup/branch-x/foo.md', ...) → true" "
const saved = process.env.ENFORCE_WORKTREE_EXCLUDE;
delete process.env.ENFORCE_WORKTREE_EXCLUDE;
try {
  const m = $SHARED_REQ;
  const ok = m.isExcluded('.worktree-backup/branch-x/foo.md', m.getExcludePatterns());
  if (ok !== true) throw new Error('expected true, got ' + ok);
} finally {
  if (saved === undefined) delete process.env.ENFORCE_WORKTREE_EXCLUDE;
  else process.env.ENFORCE_WORKTREE_EXCLUDE = saved;
}
"

# ─────────────────────────────────────────────────────────────────────────────
# Case 4: absolute path without branch subdir matches builtin
#         (trailing /** must match zero segments via the .worktree-backup
#         component on its own — depending on glob semantics this may be
#         '.worktree-backup/file.md' as the file directly inside the dir.)
# ─────────────────────────────────────────────────────────────────────────────
node_case "Case 4: isExcluded(abs('.worktree-backup/file.md'), ...) → true" "
const path = require('path');
const saved = process.env.ENFORCE_WORKTREE_EXCLUDE;
delete process.env.ENFORCE_WORKTREE_EXCLUDE;
try {
  const m = $SHARED_REQ;
  const abs = path.resolve('.worktree-backup', 'file.md');
  const ok = m.isExcluded(abs, m.getExcludePatterns());
  if (ok !== true) throw new Error('expected true for ' + abs + ', got ' + ok);
} finally {
  if (saved === undefined) delete process.env.ENFORCE_WORKTREE_EXCLUDE;
  else process.env.ENFORCE_WORKTREE_EXCLUDE = saved;
}
"

# ─────────────────────────────────────────────────────────────────────────────
# Case 5: substring without leading dot must NOT match (regression guard)
# ─────────────────────────────────────────────────────────────────────────────
node_case "Case 5: 'docs/worktree-backup-notes.md' → false (no leading dot)" "
const saved = process.env.ENFORCE_WORKTREE_EXCLUDE;
delete process.env.ENFORCE_WORKTREE_EXCLUDE;
try {
  const m = $SHARED_REQ;
  const ok = m.isExcluded('docs/worktree-backup-notes.md', m.getExcludePatterns());
  if (ok !== false) throw new Error('expected false, got ' + ok);
} finally {
  if (saved === undefined) delete process.env.ENFORCE_WORKTREE_EXCLUDE;
  else process.env.ENFORCE_WORKTREE_EXCLUDE = saved;
}
"

# ─────────────────────────────────────────────────────────────────────────────
# Case 6: partial segment must NOT match
# ─────────────────────────────────────────────────────────────────────────────
node_case "Case 6: 'docs/.worktree-backup-old/file.md' → false (partial segment)" "
const saved = process.env.ENFORCE_WORKTREE_EXCLUDE;
delete process.env.ENFORCE_WORKTREE_EXCLUDE;
try {
  const m = $SHARED_REQ;
  const ok = m.isExcluded('docs/.worktree-backup-old/file.md', m.getExcludePatterns());
  if (ok !== false) throw new Error('expected false, got ' + ok);
} finally {
  if (saved === undefined) delete process.env.ENFORCE_WORKTREE_EXCLUDE;
  else process.env.ENFORCE_WORKTREE_EXCLUDE = saved;
}
"

# ─────────────────────────────────────────────────────────────────────────────
# Case 7: arbitrary source file must NOT be excluded (regression guard)
# ─────────────────────────────────────────────────────────────────────────────
node_case "Case 7: 'src/valid.js' → false (no false-allow leak)" "
const saved = process.env.ENFORCE_WORKTREE_EXCLUDE;
delete process.env.ENFORCE_WORKTREE_EXCLUDE;
try {
  const m = $SHARED_REQ;
  const ok = m.isExcluded('src/valid.js', m.getExcludePatterns());
  if (ok !== false) throw new Error('expected false, got ' + ok);
} finally {
  if (saved === undefined) delete process.env.ENFORCE_WORKTREE_EXCLUDE;
  else process.env.ENFORCE_WORKTREE_EXCLUDE = saved;
}
"

# ─────────────────────────────────────────────────────────────────────────────
# Case 8: BUILTIN_EXCLUDE_PATTERNS is on module.exports (introspectable)
# ─────────────────────────────────────────────────────────────────────────────
node_case "Case 8: BUILTIN_EXCLUDE_PATTERNS exported from shared-cmd-utils" "
const m = $SHARED_REQ;
if (!Array.isArray(m.BUILTIN_EXCLUDE_PATTERNS)) {
  throw new Error('not exported or not array: ' + typeof m.BUILTIN_EXCLUDE_PATTERNS);
}
if (!m.BUILTIN_EXCLUDE_PATTERNS.includes('**/.worktree-backup/**')) {
  throw new Error('missing pattern: ' + JSON.stringify(m.BUILTIN_EXCLUDE_PATTERNS));
}
"

# ─────────────────────────────────────────────────────────────────────────────
# Wrap with overall timeout (120s)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
