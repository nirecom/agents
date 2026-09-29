#!/usr/bin/env bash
# Tests: bin/select-review-scope.js
# Tags: workflow, review-tests, scope-delta, cli, TL2, scope:issue-specific
#
# Tests for bin/select-review-scope.js:
#   output format, full vs delta, exit codes, path validation, SOURCE exclusions.

set -uo pipefail
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }

CLI="$AGENTS_DIR/bin/select-review-scope.js"
STATE_IO="$(np "$AGENTS_DIR/hooks/workflow-state/state-io.js")"

TMPDIR_BASE="$(make_tmp)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
harness_isolate "$TMPDIR_BASE"

# Fixture git repo
REPO="$TMPDIR_BASE/repo"
harness_git_init "$REPO"
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"

# Make an initial commit so index is non-empty
echo "init" > "$REPO/.gitkeep"
git -C "$REPO" add .gitkeep
git -C "$REPO" commit -q -m "init"

CLI_EXISTS=1
[ -f "$CLI" ] || CLI_EXISTS=0

# Helper: run CLI
run_cli() {
  run_with_timeout 15 node "$(np "$CLI")" "$@" 2>/dev/null
}
run_cli_err() {
  run_with_timeout 15 node "$(np "$CLI")" "$@" 2>&1
}

# Helper: write state with review_scope_manifest annotation via appendEvents
setup_state_with_manifest() {
  local sid="$1" files_json="$2"
  run_with_timeout 10 node "$(np "$AGENTS_DIR/hooks/workflow-state/state-io.js")" 2>/dev/null || true
  run_with_timeout 10 node - "$STATE_IO" "$sid" "$files_json" << 'JSEOF'
const [,, stateIoPath, sid, filesJson] = process.argv;
const m = require(stateIoPath);
const state = m.createInitialState(sid, { cwd: "." });
m.writeState(sid, state);
const files = JSON.parse(filesJson);
m.appendEvents(sid, [{
  kind: "step_annotation", step: "review_tests",
  key: "review_scope_manifest", value: { v: 1, files },
  provenance: "observed", origin: "review-tests-complete"
}]);
JSEOF
}

REPO_NP="$(np "$REPO")"

# ============================================================
# S1: no state → SCOPE=full REASON=no-state
# ============================================================
T_S1() {
  if [ "$CLI_EXISTS" -eq 0 ]; then fail "S1.no-state" "bin/select-review-scope.js not yet implemented"; return; fi
  local sid="s1-scope-$$"
  local out
  out=$(run_cli --session "$sid" --worktree "$REPO_NP" 2>/dev/null) || true
  if printf '%s\n' "$out" | grep -q "^SCOPE=full" && printf '%s\n' "$out" | grep -q "^REASON=no-state"; then
    pass "S1. no-state → SCOPE=full REASON=no-state"
  else
    fail "S1. no-state → SCOPE=full REASON=no-state" "$out"
  fi
}

# ============================================================
# S2: full scope (no manifest in state) — all staged tests in REVIEW
# ============================================================
T_S2() {
  if [ "$CLI_EXISTS" -eq 0 ]; then fail "S2.full-no-manifest" "bin/select-review-scope.js not yet implemented"; return; fi
  local sid="s2-scope-$$"
  # Create state (no manifest annotation)
  run_with_timeout 10 node - "$STATE_IO" "$sid" << 'JSEOF' 2>/dev/null
const [,, stateIoPath, sid] = process.argv;
const m = require(stateIoPath);
const state = m.createInitialState(sid, { cwd: "." });
m.writeState(sid, state);
JSEOF
  # Stage a test file and an impl file
  mkdir -p "$REPO/tests" "$REPO/hooks"
  echo "# test" > "$REPO/tests/alpha.sh"
  echo "impl" > "$REPO/hooks/code.js"
  git -C "$REPO" add tests/alpha.sh hooks/code.js
  local out
  out=$(run_cli --session "$sid" --worktree "$REPO_NP") || true
  local has_scope_full has_review_alpha has_source_code
  has_scope_full=$(printf '%s\n' "$out" | grep -c "^SCOPE=full" || true)
  has_review_alpha=$(printf '%s\n' "$out" | grep "^REVIEW" | grep -c "alpha.sh" || true)
  has_source_code=$(printf '%s\n' "$out" | grep "^SOURCE" | grep -c "code.js" || true)
  git -C "$REPO" rm -f --cached tests/alpha.sh hooks/code.js 2>/dev/null || true
  rm -f "$REPO/tests/alpha.sh" "$REPO/hooks/code.js"
  [ "$has_scope_full" -ge 1 ] && pass "S2. full scope SCOPE=full" || fail "S2. full scope SCOPE=full" "$out"
  [ "$has_review_alpha" -ge 1 ] && pass "S2. REVIEW has alpha.sh" || fail "S2. REVIEW has alpha.sh" "$out"
  [ "$has_source_code" -ge 1 ] && pass "S2. SOURCE has code.js" || fail "S2. SOURCE has code.js" "$out"
}

# ============================================================
# S3: REVIEW path not on disk → exit 4 with path on stderr
# ============================================================
T_S3() {
  if [ "$CLI_EXISTS" -eq 0 ]; then fail "S3.review-missing" "bin/select-review-scope.js not yet implemented"; return; fi
  local sid="s3-scope-$$"
  # Stage a test file then remove it from disk
  mkdir -p "$REPO/tests"
  echo "# test" > "$REPO/tests/ghost.sh"
  git -C "$REPO" add tests/ghost.sh
  rm -f "$REPO/tests/ghost.sh"
  # Build state with no manifest so scope=full, ghost.sh in REVIEW
  run_with_timeout 10 node - "$STATE_IO" "$sid" << 'JSEOF' 2>/dev/null
const [,, sp, sid] = process.argv;
const m = require(sp);
m.writeState(sid, m.createInitialState(sid, { cwd: "." }));
JSEOF
  local rc=0 err
  err=$(run_cli_err --session "$sid" --worktree "$REPO_NP") || rc=$?
  git -C "$REPO" rm -f --cached tests/ghost.sh 2>/dev/null || true
  if [ "$rc" -eq 4 ]; then
    pass "S3. REVIEW path missing → exit 4"
    printf '%s\n' "$err" | grep -q "ghost.sh" \
      && pass "S3. exit 4 stderr mentions ghost.sh" \
      || fail "S3. exit 4 stderr mentions ghost.sh" "$err"
  else
    fail "S3. REVIEW path missing → exit 4" "got exit $rc; $err"
  fi
}

# ============================================================
# S4: DELETED path missing on disk → still exit 0
# ============================================================
T_S4() {
  if [ "$CLI_EXISTS" -eq 0 ]; then fail "S4.deleted-missing" "bin/select-review-scope.js not yet implemented"; return; fi
  local sid="s4-scope-$$"
  # Manifest has tests/gone.sh, current has tests/here.sh (tests-only delta)
  # tests/gone.sh does not exist on disk (deleted = normal for DELETED)
  mkdir -p "$REPO/tests"
  echo "# here" > "$REPO/tests/here.sh"
  git -C "$REPO" add tests/here.sh
  setup_state_with_manifest "$sid" '{"tests/gone.sh":"old123","hooks/impl.js":"ii"}'
  # Also stage impl so SOURCE is non-empty
  mkdir -p "$REPO/hooks"
  echo "impl" > "$REPO/hooks/impl.js"
  git -C "$REPO" add hooks/impl.js
  local rc=0
  run_cli --session "$sid" --worktree "$REPO_NP" > /dev/null || rc=$?
  git -C "$REPO" rm -f --cached tests/here.sh hooks/impl.js 2>/dev/null || true
  rm -f "$REPO/tests/here.sh" "$REPO/hooks/impl.js"
  [ "$rc" -eq 0 ] && pass "S4. DELETED missing → exit 0" || fail "S4. DELETED missing → exit 0" "got exit $rc"
}

# ============================================================
# S9: delta scope — tests-only D (gone deleted, here added), keep unchanged, no impl
# ============================================================
T_S9() {
  if [ "$CLI_EXISTS" -eq 0 ]; then fail "S9.delta-scope" "bin/select-review-scope.js not yet implemented"; return; fi
  local sid="s9-scope-$$"
  mkdir -p "$REPO/tests"
  echo "# keep" > "$REPO/tests/keep.sh"
  git -C "$REPO" add tests/keep.sh
  local keep_oid
  keep_oid=$(git -C "$REPO" rev-parse :tests/keep.sh)
  setup_state_with_manifest "$sid" "{\"tests/gone.sh\":\"1111111111111111111111111111111111111111\",\"tests/keep.sh\":\"$keep_oid\"}"
  echo "# here" > "$REPO/tests/here.sh"
  git -C "$REPO" add tests/here.sh
  local out rc=0
  out=$(run_cli --session "$sid" --worktree "$REPO_NP") || rc=$?
  git -C "$REPO" rm -f --cached tests/keep.sh tests/here.sh 2>/dev/null || true
  rm -f "$REPO/tests/keep.sh" "$REPO/tests/here.sh"
  local tab=$'\t'
  [ "$rc" -eq 0 ] && pass "S9. delta → exit 0" || fail "S9. delta → exit 0" "got exit $rc; $out"
  printf '%s\n' "$out" | grep -qx "SCOPE=delta" && pass "S9. SCOPE=delta" || fail "S9. SCOPE=delta" "$out"
  printf '%s\n' "$out" | grep -qx "REASON=tests-only" && pass "S9. REASON=tests-only" || fail "S9. REASON=tests-only" "$out"
  printf '%s\n' "$out" | grep -qx "DELETED${tab}tests/gone.sh" && pass "S9. DELETED tests/gone.sh" || fail "S9. DELETED tests/gone.sh" "$out"
  printf '%s\n' "$out" | grep "^REVIEW${tab}" | grep -q "tests/here.sh$" && pass "S9. REVIEW has here.sh" || fail "S9. REVIEW has here.sh" "$out"
  printf '%s\n' "$out" | grep -qx "INVENTORY${tab}tests/keep.sh" && pass "S9. INVENTORY has keep.sh" || fail "S9. INVENTORY has keep.sh" "$out"
  if printf '%s\n' "$out" | grep "^REVIEW${tab}" | grep -q "keep.sh"; then
    fail "S9. unchanged keep.sh not on REVIEW" "$out"
  else
    pass "S9. unchanged keep.sh not on REVIEW"
  fi
  if printf '%s\n' "$out" | grep "^REVIEW${tab}" | grep -q "gone.sh"; then
    fail "S9. deleted gone.sh not on REVIEW" "$out"
  else
    pass "S9. deleted gone.sh not on REVIEW"
  fi
}

# ============================================================
# S10: delta — content-changed tests/ file (same path, new OID) and a new test/ fixture
# ============================================================
T_S10() {
  if [ "$CLI_EXISTS" -eq 0 ]; then fail "S10.delta-changed-and-test-dir" "bin/select-review-scope.js not yet implemented"; return; fi
  local sid="s10-scope-$$"
  mkdir -p "$REPO/tests" "$REPO/test"
  echo "# mod v1" > "$REPO/tests/mod.sh"
  git -C "$REPO" add tests/mod.sh
  local old_oid
  old_oid=$(git -C "$REPO" rev-parse :tests/mod.sh)
  setup_state_with_manifest "$sid" "{\"tests/mod.sh\":\"$old_oid\"}"
  echo "# mod v2 edited" > "$REPO/tests/mod.sh"
  echo "# fx" > "$REPO/test/fx.sh"
  git -C "$REPO" add tests/mod.sh test/fx.sh
  local out rc=0
  out=$(run_cli --session "$sid" --worktree "$REPO_NP") || rc=$?
  git -C "$REPO" rm -f --cached tests/mod.sh test/fx.sh 2>/dev/null || true
  rm -f "$REPO/tests/mod.sh" "$REPO/test/fx.sh"
  local tab=$'\t'
  [ "$rc" -eq 0 ] && pass "S10. delta → exit 0" || fail "S10. delta → exit 0" "got exit $rc; $out"
  printf '%s\n' "$out" | grep -qx "SCOPE=delta" && pass "S10. SCOPE=delta" || fail "S10. SCOPE=delta" "$out"
  printf '%s\n' "$out" | grep -qx "REASON=tests-only" && pass "S10. REASON=tests-only (test/ counts as tests)" || fail "S10. REASON=tests-only (test/ counts as tests)" "$out"
  printf '%s\n' "$out" | grep "^REVIEW${tab}" | grep -q "tests/mod.sh$" && pass "S10. REVIEW has content-changed mod.sh" || fail "S10. REVIEW has content-changed mod.sh" "$out"
  printf '%s\n' "$out" | grep "^REVIEW${tab}" | grep -q "test/fx.sh$" && pass "S10. REVIEW has test/fx.sh" || fail "S10. REVIEW has test/fx.sh" "$out"
  if printf '%s\n' "$out" | grep "^SOURCE" | grep -q "fx.sh"; then
    fail "S10. test/fx.sh not on SOURCE" "$out"
  else
    pass "S10. test/fx.sh not on SOURCE"
  fi
}

# ============================================================
# S11: manifest present — added + changed + deleted + unchanged tests across both test/
#      and tests/; the whole stdout is compared exactly (order-insensitive, line-exact).
# ============================================================
T_S11() {
  if [ "$CLI_EXISTS" -eq 0 ]; then fail "S11.delta-exact-output" "bin/select-review-scope.js not yet implemented"; return; fi
  local sid="s11-scope-$$" repo="$TMPDIR_BASE/repo-s11" tab=$'\t'
  harness_git_init "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
  git -C "$repo" config core.autocrlf false
  echo "init" > "$repo/.gitkeep"
  git -C "$repo" add .gitkeep
  git -C "$repo" commit -q -m "init"
  mkdir -p "$repo/tests/sub" "$repo/test"
  echo "# keep" > "$repo/tests/keep.sh"
  echo "# keep2" > "$repo/test/keep2.sh"
  echo "# mod v1" > "$repo/tests/sub/mod.sh"
  echo "# tmod v1" > "$repo/test/tmod.sh"
  git -C "$repo" add tests/keep.sh test/keep2.sh tests/sub/mod.sh test/tmod.sh
  local k1 k2 m1 m2
  k1=$(git -C "$repo" rev-parse :tests/keep.sh)
  k2=$(git -C "$repo" rev-parse :test/keep2.sh)
  m1=$(git -C "$repo" rev-parse :tests/sub/mod.sh)
  m2=$(git -C "$repo" rev-parse :test/tmod.sh)
  local gone="1111111111111111111111111111111111111111"
  setup_state_with_manifest "$sid" "{\"tests/keep.sh\":\"$k1\",\"test/keep2.sh\":\"$k2\",\"tests/sub/mod.sh\":\"$m1\",\"test/tmod.sh\":\"$m2\",\"tests/gone.sh\":\"$gone\",\"test/gone2.sh\":\"$gone\"}"
  echo "# mod v2" > "$repo/tests/sub/mod.sh"
  echo "# tmod v2" > "$repo/test/tmod.sh"
  echo "# add" > "$repo/tests/add.sh"
  echo "# tadd" > "$repo/test/tadd.sh"
  git -C "$repo" add tests/sub/mod.sh test/tmod.sh tests/add.sh test/tadd.sh
  local repo_np out rc=0 want got
  repo_np="$(np "$repo")"
  out=$(run_cli --session "$sid" --worktree "$repo_np") || rc=$?
  want="$(printf '%s\n' "SCOPE=delta" "REASON=tests-only" \
    "REVIEW${tab}$repo_np/tests/add.sh" "REVIEW${tab}$repo_np/test/tadd.sh" \
    "REVIEW${tab}$repo_np/tests/sub/mod.sh" "REVIEW${tab}$repo_np/test/tmod.sh" \
    "DELETED${tab}tests/gone.sh" "DELETED${tab}test/gone2.sh" \
    "INVENTORY${tab}tests/keep.sh" "INVENTORY${tab}test/keep2.sh" | LC_ALL=C sort)"
  got="$(printf '%s\n' "$out" | tr -d '\r' | grep -v '^$' | LC_ALL=C sort)"
  [ "$rc" -eq 0 ] && pass "S11. delta → exit 0" || fail "S11. delta → exit 0" "got exit $rc; $out"
  if [ "$got" = "$want" ]; then
    pass "S11. exact SCOPE/REASON/REVIEW/DELETED/INVENTORY output, no SOURCE"
  else
    fail "S11. exact output mismatch" "want=[$want] got=[$got]"
  fi
}

# ============================================================
# S5: output format — SCOPE, REASON, REVIEW/DELETED/INVENTORY/SOURCE lines
# ============================================================
T_S5() {
  if [ "$CLI_EXISTS" -eq 0 ]; then fail "S5.output-format" "bin/select-review-scope.js not yet implemented"; return; fi
  local sid="s5-scope-$$"
  run_with_timeout 10 node - "$STATE_IO" "$sid" << 'JSEOF' 2>/dev/null
const [,, sp, sid] = process.argv;
const m = require(sp);
m.writeState(sid, m.createInitialState(sid, { cwd: "." }));
JSEOF
  mkdir -p "$REPO/tests" "$REPO/hooks"
  echo "# t" > "$REPO/tests/fmt.sh"
  echo "impl" > "$REPO/hooks/fmt.js"
  git -C "$REPO" add tests/fmt.sh hooks/fmt.js
  local out
  out=$(run_cli --session "$sid" --worktree "$REPO_NP") || true
  git -C "$REPO" rm -f --cached tests/fmt.sh hooks/fmt.js 2>/dev/null || true
  rm -f "$REPO/tests/fmt.sh" "$REPO/hooks/fmt.js"
  printf '%s\n' "$out" | grep -q "^SCOPE=" && pass "S5. output has SCOPE= line" || fail "S5. output has SCOPE= line" "$out"
  printf '%s\n' "$out" | grep -q "^REASON=" && pass "S5. output has REASON= line" || fail "S5. output has REASON= line" "$out"
  printf '%s\n' "$out" | grep -qE "^(REVIEW|DELETED|INVENTORY)" && pass "S5. output has REVIEW/DELETED/INVENTORY" || fail "S5. output has review lines" "$out"
  printf '%s\n' "$out" | grep -q "^SOURCE" && pass "S5. output has SOURCE line" || fail "S5. output has SOURCE line" "$out"
}

# ============================================================
# S6: SOURCE excludes CHANGELOG.md and changelog/
# ============================================================
T_S6() {
  if [ "$CLI_EXISTS" -eq 0 ]; then fail "S6.source-excludes-changelog" "bin/select-review-scope.js not yet implemented"; return; fi
  local sid="s6-scope-$$"
  run_with_timeout 10 node - "$STATE_IO" "$sid" << 'JSEOF' 2>/dev/null
const [,, sp, sid] = process.argv;
const m = require(sp);
m.writeState(sid, m.createInitialState(sid, { cwd: "." }));
JSEOF
  mkdir -p "$REPO/changelog"
  echo "impl" > "$REPO/hooks-s6.js"
  echo "changes" > "$REPO/CHANGELOG.md"
  echo "2026" > "$REPO/changelog/2026.md"
  git -C "$REPO" add hooks-s6.js CHANGELOG.md "changelog/2026.md"
  local out
  out=$(run_cli --session "$sid" --worktree "$REPO_NP") || true
  git -C "$REPO" rm -f --cached hooks-s6.js CHANGELOG.md "changelog/2026.md" 2>/dev/null || true
  rm -f "$REPO/hooks-s6.js" "$REPO/CHANGELOG.md" "$REPO/changelog/2026.md"
  local no_changelog=1
  printf '%s\n' "$out" | grep "^SOURCE" | grep -q "CHANGELOG" && no_changelog=0 || true
  printf '%s\n' "$out" | grep "^SOURCE" | grep -q "changelog" && no_changelog=0 || true
  [ "$no_changelog" -eq 1 ] && pass "S6. SOURCE excludes CHANGELOG.md and changelog/" \
    || fail "S6. SOURCE excludes CHANGELOG.md and changelog/" "$out"
  printf '%s\n' "$out" | grep "^SOURCE" | grep -q "hooks-s6.js" \
    && pass "S6. SOURCE includes hooks-s6.js" \
    || fail "S6. SOURCE includes hooks-s6.js" "$out"
}

# ============================================================
# S7: invalid session id rejected
# ============================================================
T_S7() {
  if [ "$CLI_EXISTS" -eq 0 ]; then fail "S7.invalid-sid" "bin/select-review-scope.js not yet implemented"; return; fi
  local rc=0
  run_cli --session "../../etc/passwd" --worktree "$REPO_NP" > /dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] && pass "S7. invalid session id rejected (exit $rc)" \
    || fail "S7. invalid session id rejected" "unexpectedly exit 0"
}

# ============================================================
# S8: /c/... POSIX drive-letter worktree path accepted
# ============================================================
T_S8() {
  if [ "$CLI_EXISTS" -eq 0 ]; then fail "S8./c/-path" "bin/select-review-scope.js not yet implemented"; return; fi
  if ! command -v cygpath >/dev/null 2>&1; then skip "S8. /c/... path — cygpath not available (non-Windows)"; return; fi
  local sid="s8-scope-$$"
  run_with_timeout 10 node - "$STATE_IO" "$sid" << 'JSEOF' 2>/dev/null
const [,, sp, sid] = process.argv;
const m = require(sp);
m.writeState(sid, m.createInitialState(sid, { cwd: "." }));
JSEOF
  # Build the /<drive>/... spelling by hand: `cygpath -u` would pick the /tmp mount instead.
  local win posix_repo drive
  win="$(cygpath -m "$REPO")"
  drive="$(printf '%s' "${win:0:1}" | tr 'A-Z' 'a-z')"
  posix_repo="/${drive}${win:2}"
  case "$posix_repo" in
    /[a-z]/*) ;;
    *) fail "S8. fixture path is /<drive>/..." "got $posix_repo"; return ;;
  esac
  mkdir -p "$REPO/tests"
  echo "# s8" > "$REPO/tests/s8.sh"
  git -C "$REPO" add tests/s8.sh
  local out rc=0 tab=$'\t'
  out=$(run_cli --session "$sid" --worktree "$posix_repo") || rc=$?
  git -C "$REPO" rm -f --cached tests/s8.sh 2>/dev/null || true
  rm -f "$REPO/tests/s8.sh"
  [ "$rc" -eq 0 ] && pass "S8. /c/... worktree path → exit 0" \
    || fail "S8. /c/... worktree path → exit 0" "got exit $rc; $out"
  printf '%s\n' "$out" | tr -d '\r' | grep -qx "SCOPE=full" \
    && pass "S8. /c/... worktree → SCOPE=full" || fail "S8. /c/... worktree → SCOPE=full" "$out"
  printf '%s\n' "$out" | tr -d '\r' | grep -qxF "REVIEW${tab}${win}/tests/s8.sh" \
    && pass "S8. REVIEW path normalized to drive-letter form" \
    || fail "S8. REVIEW path normalized to drive-letter form" "want REVIEW${tab}${win}/tests/s8.sh; $out"
}

T_S1
T_S2
T_S3
T_S4
T_S5
T_S6
T_S7
T_S8
T_S9
T_S10
T_S11

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
