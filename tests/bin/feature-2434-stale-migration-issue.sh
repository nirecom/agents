#!/usr/bin/env bash
# tests/bin/feature-2434-stale-migration-issue.sh
# Tests: bin/open-stale-migration-issue.sh, bin/lib/check-migration-blocks.js, .github/workflows/sweep.yml
# Tags: scope:issue-specific, TL2, stale-migration-issue
# TL3 gap (what this test does NOT catch):
# - Real GitHub API: gh stub replaces live issue list/create calls
# - Real cron scheduling of the stale-migration-issue job
# - The deployed script scanning its own checkout: the cases launch a copy placed in a fixture
# Closest-to-action mitigation: hook-registration category in bin/check-verification-gate.sh

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

T="$(make_tmp)"
trap 'rm -rf "$T"' EXIT
harness_isolate "$T/wf"
export CLAUDE_TRANSCRIPT_BASE_DIR="$T/transcripts"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR"

OPEN_SCRIPT="$SCRIPT_CHECKOUT_ROOT/bin/open-stale-migration-issue.sh"
CMB="$SCRIPT_CHECKOUT_ROOT/bin/lib/check-migration-blocks.js"

# gh stub: logs "$@" to GH_LOG; answers issue list from GH_ISSUE_LIST env
mkdir -p "$T/bin"
cat > "$T/bin/gh" << 'GHSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  printf '%s\n' "${GH_ISSUE_LIST:-}"
  exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  if [ "${GH_CREATE_FAIL:-0}" = "1" ]; then
    printf 'error: gh issue create failed\n' >&2
    exit 1
  fi
  printf 'https://github.com/test/repo/issues/42\n'
  exit 0
fi
exit 0
GHSTUB
chmod +x "$T/bin/gh"

# PATH entries must be msys-form: a C:/ TMPDIR splits at ':' and silently drops the stub,
# letting the real gh reach GitHub (incident: real issue #2465).
GH_BIN_DIR="$T/bin"
command -v cygpath >/dev/null 2>&1 && GH_BIN_DIR="$(cygpath -u "$GH_BIN_DIR")"
STUB_PATH="$GH_BIN_DIR:$PATH"

# gh_resolves_to_stub: true only when `gh` under STUB_PATH is the stub itself.
gh_resolves_to_stub() {
  local got
  got="$(PATH="$STUB_PATH" command -v gh 2>/dev/null || true)"
  [ -n "$got" ] && [ "$got" -ef "$GH_BIN_DIR/gh" ]
}

if ! gh_resolves_to_stub; then
  fail "gh-stub-guard" "gh does not resolve to the stub under STUB_PATH (got '$(PATH="$STUB_PATH" command -v gh 2>/dev/null || true)'); aborting before any case can reach real GitHub"
  echo ""
  echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
  exit 1
fi

# A fixture source file with a stale BEGIN block (added 2026-06-29 = 91 days before
# 2026-09-28, which exceeds the >90-day threshold in checkAxis4)
STALE_DATE="2026-06-29"
FIXTURE_REPO="$T/repo"
mkdir -p "$FIXTURE_REPO/bin"
cat > "$FIXTURE_REPO/bin/example-migration.sh" << STALE_FIXTURE
#!/usr/bin/env bash
# --- BEGIN temporary: something -> migration added $STALE_DATE ---
# deletion-condition: remove after 2026-12-29
echo "temporary code"
# --- END temporary: something ---
STALE_FIXTURE

# A fixture file WITHOUT stale blocks (no BEGIN temporary at all)
mkdir -p "$T/clean-repo/bin"
printf '#!/usr/bin/env bash\necho clean\n' > "$T/clean-repo/bin/clean.sh"

# Expected issue title (must match exactly for dedup)
ISSUE_TITLE="Stale temporary migration blocks (>90 days)"

# run_open_script <fixture-root> <GH_ISSUE_LIST-value> <GH_CREATE_FAIL>: sets RUN_RC/RUN_OUT
run_open_script() {
  local root="$1" issues_list="$2" create_fail="$3"
  local log_file="$T/gh-log-$RANDOM.txt"
  printf '' > "$log_file"
  RUN_RC=0
  if ! gh_resolves_to_stub; then
    RUN_RC=99; RUN_OUT="gh stub guard tripped"; GH_LOG_CONTENTS=""; GH_CREATE_CALLS="guard"
    return 0
  fi
  # The script scans the checkout it lives in, so a copy is launched from inside the fixture.
  mkdir -p "$root/bin/lib"
  cp "$OPEN_SCRIPT" "$root/bin/open-stale-migration-issue.sh"
  cp "$CMB" "$root/bin/lib/check-migration-blocks.js"
  RUN_OUT="$(
    PATH="$STUB_PATH" \
    GH_REPO="gh-stub.invalid/none/none" \
    GH_LOG="$log_file" \
    GH_ISSUE_LIST="$issues_list" \
    GH_CREATE_FAIL="$create_fail" \
    run_with_timeout 30 bash "$root/bin/open-stale-migration-issue.sh" 2>&1
  )" || RUN_RC=$?
  GH_LOG_CONTENTS=""
  GH_LOG_CONTENTS="$(cat "$log_file" 2>/dev/null || true)"
  GH_CREATE_CALLS="$(grep -c "^issue create" "$log_file" 2>/dev/null || true)"
  GH_CREATE_CALLS="${GH_CREATE_CALLS:-0}"
}

# ── cases ────────────────────────────────────────────────────────────────────

case_begin "stale-91d-no-open-issue" "bin/open-stale-migration-issue.sh"
if [ ! -f "$OPEN_SCRIPT" ]; then
  fail "stale-91d-no-open-issue" "implementation absent"
else
  run_open_script "$FIXTURE_REPO" "" "0"
  if [ "$GH_CREATE_CALLS" = "1" ] && printf '%s' "$GH_LOG_CONTENTS" | grep -qF -- "--label type:task"; then
    pass "stale-91d-no-open-issue"
  else
    fail "stale-91d-no-open-issue" "want 1 create call with --label type:task; calls=$GH_CREATE_CALLS log='$GH_LOG_CONTENTS' out='$RUN_OUT'"
  fi
fi
case_end

case_begin "stale-partial-title-issue" "bin/open-stale-migration-issue.sh"
if [ ! -f "$OPEN_SCRIPT" ]; then
  fail "stale-partial-title-issue" "implementation absent"
else
  run_open_script "$FIXTURE_REPO" "Stale migration blocks" "0"
  if [ "$GH_CREATE_CALLS" = "1" ]; then
    pass "stale-partial-title-issue"
  else
    fail "stale-partial-title-issue" "partial title match should not suppress create; calls=$GH_CREATE_CALLS"
  fi
fi
case_end

case_begin "stale-exact-title-exists" "bin/open-stale-migration-issue.sh"
if [ ! -f "$OPEN_SCRIPT" ]; then
  fail "stale-exact-title-exists" "implementation absent"
else
  run_open_script "$FIXTURE_REPO" "$ISSUE_TITLE" "0"
  if [ "$GH_CREATE_CALLS" = "0" ]; then
    pass "stale-exact-title-exists"
  else
    fail "stale-exact-title-exists" "exact title open; create must not be called; calls=$GH_CREATE_CALLS"
  fi
fi
case_end

case_begin "nothing-stale" "bin/open-stale-migration-issue.sh"
if [ ! -f "$OPEN_SCRIPT" ]; then
  fail "nothing-stale" "implementation absent"
else
  run_open_script "$T/clean-repo" "" "0"
  if [ "$GH_CREATE_CALLS" = "0" ] && printf '%s' "$GH_LOG_CONTENTS" | grep -qv "issue"; then
    pass "nothing-stale"
  elif [ "$GH_CREATE_CALLS" = "0" ] && [ -z "$GH_LOG_CONTENTS" ]; then
    pass "nothing-stale"
  else
    fail "nothing-stale" "no stale blocks; gh must not be called; calls=$GH_CREATE_CALLS log='$GH_LOG_CONTENTS'"
  fi
fi
case_end

case_begin "create-fails-nonzero" "bin/open-stale-migration-issue.sh"
if [ ! -f "$OPEN_SCRIPT" ]; then
  fail "create-fails-nonzero" "implementation absent"
else
  run_open_script "$FIXTURE_REPO" "" "1"
  if [ "$RUN_RC" != "0" ]; then
    pass "create-fails-nonzero"
  else
    fail "create-fails-nonzero" "gh create failed; script should exit nonzero; got 0"
  fi
fi
case_end

case_begin "stale-report-cli-exit0" "bin/lib/check-migration-blocks.js"
# --stale-report mode: prints path:line:added lines, exits 0
# Before implementation this mode does not exist → exits 2 (unknown mode)
CMB_RC=0
CMB_OUT="$(run_with_timeout 15 node "$(np "$CMB")" --stale-report "$(np "$FIXTURE_REPO")" 2>&1)" || CMB_RC=$?
if [ "$CMB_RC" = "0" ]; then
  if printf '%s' "$CMB_OUT" | grep -qF "$STALE_DATE"; then
    pass "stale-report-cli-exit0"
  else
    fail "stale-report-cli-exit0" "exit 0 but output lacks stale date '$STALE_DATE': $CMB_OUT"
  fi
else
  fail "stale-report-cli-exit0" "want exit 0; got $CMB_RC (--stale-report not implemented yet): $CMB_OUT"
fi
case_end

case_begin "static-sweep-yml-new-job" ".github/workflows/sweep.yml"
SWEEP_YML="$SCRIPT_CHECKOUT_ROOT/.github/workflows/sweep.yml"
JOB_FOUND=0
grep -qF "stale-migration-issue" "$SWEEP_YML" 2>/dev/null && JOB_FOUND=1
ISSUES_WRITE=0
grep -qF "issues: write" "$SWEEP_YML" 2>/dev/null && ISSUES_WRITE=1
OR_TRUE_IN_JOB=0
if [ "$JOB_FOUND" = "1" ]; then
  awk '/stale-migration-issue/,0' "$SWEEP_YML" 2>/dev/null | grep -qF "|| true" && OR_TRUE_IN_JOB=1
fi
if [ "$JOB_FOUND" = "1" ] && [ "$ISSUES_WRITE" = "1" ] && [ "$OR_TRUE_IN_JOB" = "0" ]; then
  pass "static-sweep-yml-new-job"
else
  fail "static-sweep-yml-new-job" "job_found=$JOB_FOUND issues_write=$ISSUES_WRITE or_true_in_job=$OR_TRUE_IN_JOB"
fi
case_end

case_begin "static-issues-write-one-job" ".github/workflows/sweep.yml"
SWEEP_YML="$SCRIPT_CHECKOUT_ROOT/.github/workflows/sweep.yml"
WRITE_COUNT=0
WRITE_COUNT="$(grep -c "issues: write" "$SWEEP_YML" 2>/dev/null || true)"
IN_NEW_JOB=0
awk '/stale-migration-issue/,0' "$SWEEP_YML" 2>/dev/null | grep -qF "issues: write" && IN_NEW_JOB=1
if [ "$WRITE_COUNT" = "1" ] && [ "$IN_NEW_JOB" = "1" ]; then
  pass "static-issues-write-one-job"
else
  fail "static-issues-write-one-job" "write_count=$WRITE_COUNT in_new_job=$IN_NEW_JOB; issues:write must appear exactly once in stale-migration-issue job"
fi
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
