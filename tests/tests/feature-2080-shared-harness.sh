#!/usr/bin/env bash
# tests/feature-2080-shared-harness.sh
# Tests: tests/lib/harness.sh, bin/check-test-frontmatter.sh
# Tags: TL2, scope:issue-specific, feature-2080-harness

# TL3 gap (what this test does NOT catch):
# - Real pre-commit hook firing via actual git commit on NTFS with case-folding
# - cygpath normalization differences between Windows and POSIX CI hosts
# Closest-to-action mitigation: gap checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS="$AGENTS_DIR/tests/lib/harness.sh"
CHECKER="$AGENTS_DIR/bin/check-test-frontmatter.sh"

# Fail-before-fix: harness.sh is created by write-code; fail explicitly until then.
if [ ! -f "$HARNESS" ]; then
  echo "BLOCKED: tests/lib/harness.sh not yet created — run /write-code first" >&2
  exit 1
fi

# Meta-verdict counters — this file's OWN pass/fail, kept separate from the
# harness PASS/FAIL globals which are themselves the object under test.
T_PASS=0
T_FAIL=0
T_SKIP=0
t_ok()   { T_PASS=$((T_PASS + 1)); echo "ok: $1"; }
t_bad()  { T_FAIL=$((T_FAIL + 1)); echo "NOT OK: $1"; }
t_skip() { T_SKIP=$((T_SKIP + 1)); echo "skip: $1"; }
t_eq()   { # $1=label $2=actual $3=expected
  if [ "$2" = "$3" ]; then t_ok "$1"; else t_bad "$1 (got='$2' want='$3')"; fi
}

# Source the harness (object under test for Group A, utility for Group B).
# Path-suffix form (…/tests/lib/harness.sh) so this file satisfies the checker's
# own MISSING_HARNESS_SOURCE pattern; $HARNESS (variable form) is reserved for the
# A2 re-source case, which the checker never inspects.
# shellcheck source=/dev/null
source "$AGENTS_DIR/tests/lib/harness.sh"

# ===========================================================================
# Group A — tests/lib/harness.sh function coverage
# ===========================================================================

# A1: required functions are all defined after sourcing.
group_a1_definitions() {
  local fn missing=""
  for fn in pass fail skip assert_eq case_begin case_end np make_tmp \
            run_with_timeout harness_isolate; do
    declare -F "$fn" >/dev/null 2>&1 || missing="$missing $fn"
  done
  if [ -z "$missing" ]; then
    t_ok "A1 all harness functions defined"
  else
    t_bad "A1 missing functions:$missing"
  fi
}

# A1b: np() — cygpath wrapper. Both branches are tested deterministically via
# PATH shims: empty PATH forces passthrough; a stub binary forces the cygpath
# branch regardless of whether real cygpath is installed on this host.
group_a_np_function() {
  local out tmpdir stub bash_bin

  # Capture bash absolute path BEFORE PATH manipulation: cygpath and bash may
  # share the same directory (e.g. /usr/bin), so derive bash_bin first to avoid
  # accidentally stripping it from PATH along with cygpath.
  bash_bin="$(command -v bash)"

  # Passthrough branch: filter cygpath dirs from PATH so np() falls through, but
  # keep enough of PATH that harness.sh sources cleanly. Invoke bash by its
  # absolute path so the filter cannot accidentally remove the shell itself.
  local filtered_path="" np_dir
  while IFS= read -r np_dir; do
    [ -x "$np_dir/cygpath" ] && continue
    [ -n "$np_dir" ] || continue
    filtered_path="${filtered_path:+$filtered_path:}$np_dir"
  done <<< "$(printf '%s\n' "$PATH" | tr ':' '\n')"
  [ -z "$filtered_path" ] && filtered_path="/usr/bin:/bin"
  out="$(PATH="$filtered_path" "$bash_bin" -euo pipefail -c "source '$HARNESS'; np '/a/b/c'" 2>/dev/null || true)"
  if [ -n "$out" ]; then
    t_eq "A1b np() passthrough (no cygpath) returns input unchanged" "$out" "/a/b/c"
  else
    t_bad "A1b np() passthrough: empty output — harness may have failed under filtered PATH"
  fi

  # cygpath branch: inject a stub that echoes "WIN:<path>" for `cygpath -m <path>`.
  # np() calls `cygpath -m "$1"`, so stub receives args: -m  <path>.
  tmpdir="$(make_tmp)"
  stub="$tmpdir/cygpath"
  printf '#!/usr/bin/env bash\nprintf "WIN:%%s\\n" "$2"\n' >"$stub"
  chmod +x "$stub"
  out="$(PATH="$tmpdir:$PATH" bash -euo pipefail -c "source '$HARNESS'; np '/a/b/c'" 2>/dev/null || true)"
  t_eq "A1b np() cygpath branch uses cygpath -m (stub echo)" "$out" "WIN:/a/b/c"
}

# A2: re-entry guard — re-sourcing does not reset pre-set PASS/FAIL/SKIP.
group_a2_reentry_guard() {
  PASS=5; FAIL=7; SKIP=3
  # shellcheck source=/dev/null
  source "$HARNESS"
  t_eq "A2 re-entry guard preserves PASS" "$PASS" "5"
  t_eq "A2 re-entry guard preserves FAIL" "$FAIL" "7"
  t_eq "A2 re-entry guard preserves SKIP" "$SKIP" "3"
}

# A3: pass()/fail()/skip() each increment their own counter by exactly 1.
group_a3_pass_direct() {
  local before="$PASS"
  pass "p" >/dev/null 2>&1 || true
  t_eq "A3 pass() increments PASS by 1" "$PASS" "$((before + 1))"
}
group_a3_fail_direct() {
  local before="$FAIL"
  fail "f" >/dev/null 2>&1 || true
  t_eq "A3 fail() increments FAIL by 1" "$FAIL" "$((before + 1))"
}
group_a3_skip_direct() {
  local before="$SKIP"
  skip "s" >/dev/null 2>&1 || true
  t_eq "A3 skip() increments SKIP by 1" "$SKIP" "$((before + 1))"
}

# C3: fresh-shell independence — a brand-new bash process sourcing the harness
# must start at PASS=0 and increment correctly, independent of this file's own
# already-mutated counters. Each subshell is `bash -euo pipefail -c` so the
# init contract is verified in isolation and the strict mode matches this file.
group_a3_fresh_shell() {
  local out
  # (1) fresh source initializes PASS to 0.
  out="$(bash -euo pipefail -c "source '$HARNESS'; echo \$PASS" 2>/dev/null || true)"
  t_eq "A3 fresh shell source initializes PASS=0" "$out" "0"
  # (2) one pass/fail/skip each → counters land at 1/1/1 from the zero baseline.
  out="$(bash -euo pipefail -c "source '$HARNESS'; pass p >/dev/null 2>&1; fail f >/dev/null 2>&1; skip s >/dev/null 2>&1; echo \$PASS \$FAIL \$SKIP" 2>/dev/null || true)"
  t_eq "A3 fresh shell one each → PASS/FAIL/SKIP = 1/1/1" "$out" "1 1 1"
  # (3) re-sourcing inside the same fresh shell preserves counts (re-entry guard).
  out="$(bash -euo pipefail -c "source '$HARNESS'; pass p >/dev/null 2>&1; source '$HARNESS'; echo \$PASS" 2>/dev/null || true)"
  t_eq "A3 fresh shell re-source preserves PASS" "$out" "1"
}

# A3: assert_eq success increments PASS by exactly 1.
group_a3_assert_eq_success() {
  local a="foo"
  local before="$PASS"
  assert_eq "$a" "$a" >/dev/null 2>&1 || true
  t_eq "A3 assert_eq success increments PASS" "$((PASS - before))" "1"
}

# A4: assert_eq failure increments FAIL and prints a want=/got= diagnostic.
group_a4_assert_eq_failure() {
  local td msg a b before after
  td="$(make_tmp)"
  msg="$td/assert_msg"
  a="foo"; b="bar"
  before="$FAIL"
  assert_eq "$a" "$b" >"$msg" 2>&1 || true
  after="$FAIL"
  if [ "$((after - before))" -ge 1 ]; then
    t_ok "A4 assert_eq failure increments FAIL"
  else
    t_bad "A4 assert_eq failure did not increment FAIL (delta=$((after - before)))"
  fi
  if grep -q 'want=' "$msg" && grep -q 'got=' "$msg"; then
    t_ok "A4 assert_eq failure message contains want= and got="
  else
    t_bad "A4 assert_eq failure message missing want=/got= ($(cat "$msg"))"
  fi
}

# A5: case_begin sets CURRENT_CASE/CURRENT_CASE_TARGET; case_end clears both.
group_a5_case_begin_end() {
  CURRENT_CASE=""; CURRENT_CASE_TARGET=""
  case_begin "mycase" "hooks/enforce-worktree.js" || true
  t_eq "A5 case_begin sets CURRENT_CASE" "$CURRENT_CASE" "mycase"
  t_eq "A5 case_begin sets CURRENT_CASE_TARGET" "$CURRENT_CASE_TARGET" "hooks/enforce-worktree.js"
  case_end || true
  t_eq "A5 case_end clears CURRENT_CASE" "$CURRENT_CASE" ""
  t_eq "A5 case_end clears CURRENT_CASE_TARGET" "$CURRENT_CASE_TARGET" ""
  # C6: a second case_end with no active case must not error (idempotent).
  local rc2
  rc2=0
  case_end >/dev/null 2>&1 || rc2=$?
  if [ "$rc2" -eq 0 ]; then
    t_ok "A5 case_end idempotent (second call exit 0)"
  else
    t_bad "A5 case_end second call errored (rc=$rc2)"
  fi
}

# A-isolate: harness_isolate <tmpdir> creates and exports the workflow dirs.
group_a_harness_isolate() {
  local tmpdir
  tmpdir="$(make_tmp)"
  harness_isolate "$tmpdir" >/dev/null 2>&1 || true
  t_eq "A4 harness_isolate CLAUDE_WORKFLOW_DIR" "$CLAUDE_WORKFLOW_DIR" "$tmpdir/workflow-state"
  t_eq "A4 harness_isolate WORKFLOW_PLANS_DIR" "$WORKFLOW_PLANS_DIR" "$tmpdir/plans"
  if [ -d "$tmpdir/workflow-state" ]; then
    t_ok "A4 harness_isolate creates workflow-state dir"
  else
    t_bad "A4 harness_isolate did not create $tmpdir/workflow-state"
  fi
  # C4: session-var cleanup — sourcing the harness must truly unset inherited
  # session ids (not merely empty them) so a fixture never mutates the developer's
  # live session state. ${VAR+set} returns "set" if VAR is set (even empty),
  # "" if VAR is truly unset — so the expected output is three empty tokens.
  local sv
  sv="$(bash -euo pipefail -c "
    export CLAUDE_SESSION_ID=test123
    export CLAUDE_CODE_SESSION_ID=test456
    export CLAUDE_ENV_FILE=/tmp/envfile
    source '$HARNESS'
    echo \"\${CLAUDE_SESSION_ID+set}|\${CLAUDE_CODE_SESSION_ID+set}|\${CLAUDE_ENV_FILE+set}\"
  " 2>/dev/null || true)"
  # All three must be truly unset → each token is empty → output is "||"
  if [ "$sv" = "||" ]; then
    t_ok "A4 harness source truly unsets CLAUDE_SESSION_ID/CODE_SESSION_ID/ENV_FILE"
  else
    t_bad "A4 harness source did not truly unset session vars (got='$sv' want='||')"
  fi
  # C4: child-process export — harness_isolate must export CLAUDE_WORKFLOW_DIR
  # and WORKFLOW_PLANS_DIR so child node processes inherit them.
  local export_check
  export_check="$(bash -euo pipefail -c "
    source '$HARNESS'
    d=\"\$(make_tmp)\"
    harness_isolate \"\$d\" >/dev/null 2>&1
    bash -c 'echo \"\${CLAUDE_WORKFLOW_DIR:-MISSING}|\${WORKFLOW_PLANS_DIR:-MISSING}\"'
  " 2>/dev/null || true)"
  if [ -n "$export_check" ] && ! printf '%s' "$export_check" | grep -q 'MISSING'; then
    t_ok "A4 harness_isolate exports CLAUDE_WORKFLOW_DIR and WORKFLOW_PLANS_DIR to child processes"
  else
    t_bad "A4 harness_isolate did not export dirs to child processes (got='$export_check')"
  fi
  # C4: repeat safety — a second harness_isolate on the same dir must not error
  # and must yield the same exported values.
  harness_isolate "$tmpdir" >/dev/null 2>&1 || true
  t_eq "A4 harness_isolate idempotent CLAUDE_WORKFLOW_DIR" "$CLAUDE_WORKFLOW_DIR" "$tmpdir/workflow-state"
  t_eq "A4 harness_isolate idempotent WORKFLOW_PLANS_DIR" "$WORKFLOW_PLANS_DIR" "$tmpdir/plans"
  # C4: make_tmp returns a distinct directory on each call.
  local d1 d2
  d1="$(make_tmp)"
  d2="$(make_tmp)"
  if [ -n "$d1" ] && [ -n "$d2" ] && [ "$d1" != "$d2" ]; then
    t_ok "A4 make_tmp returns distinct dirs on repeat calls"
  else
    t_bad "A4 make_tmp not distinct (d1='$d1' d2='$d2')"
  fi
  # C4: harness_git_init disables git hooks in the fixture repo by pinning
  # core.hooksPath=/dev/null (per rules/test/fixture-isolation.md), so an
  # installed pre-commit hook never fires inside the fixture.
  local gitdir hooks_path
  gitdir="$(make_tmp)"
  harness_git_init "$gitdir/repo" >/dev/null 2>&1 || true
  hooks_path="$(git -C "$gitdir/repo" config core.hooksPath 2>/dev/null || echo UNSET)"
  case "$hooks_path" in
    /dev/null|nul)
      t_ok "A4 harness_git_init sets core.hooksPath=/dev/null" ;;
    *)
      t_bad "A4 harness_git_init sets core.hooksPath=/dev/null (got='$hooks_path')" ;;
  esac
  # C4: AGENTS_DIR resolves to the parent of tests/ (the repo root the harness
  # is sourced from), so fixtures and helpers resolve repo-relative paths.
  local expected_agents_dir
  expected_agents_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  t_eq "A4 AGENTS_DIR resolves to parent of tests/" "$AGENTS_DIR" "$expected_agents_dir"
  # C2: AGENTS_DIR auto-resolves in a fresh shell where it was not pre-set.
  # harness.sh must derive it from BASH_SOURCE relative to tests/lib/harness.sh.
  local resolved
  resolved="$(bash -euo pipefail -c "
    unset AGENTS_DIR
    source '$HARNESS'
    echo \"\$AGENTS_DIR\"
  " 2>/dev/null || true)"
  t_eq "A4 AGENTS_DIR auto-resolves when not pre-set" "$resolved" "$expected_agents_dir"
}

# A-rwt: run_with_timeout wrapper forwards exit status of the wrapped command.
group_a_run_with_timeout() {
  local rc
  rc=0
  run_with_timeout 10 bash -c 'exit 0' >/dev/null 2>&1 || rc=$?
  t_eq "A5 run_with_timeout success exit 0" "$rc" "0"
  rc=0
  run_with_timeout 10 bash -c 'exit 3' >/dev/null 2>&1 || rc=$?
  t_eq "A5 run_with_timeout forwards non-0 exit 3" "$rc" "3"
  # C5: stdout of the wrapped command survives the wrapper.
  local td out
  td="$(make_tmp)"
  out="$td/rwt_out"
  run_with_timeout 10 bash -c 'echo hello' >"$out" 2>&1 || true
  if grep -q 'hello' "$out"; then
    t_ok "A5 run_with_timeout preserves wrapped stdout"
  else
    t_bad "A5 run_with_timeout lost wrapped stdout (got='$(cat "$out")')"
  fi
  # C5: a command exceeding the timeout is killed and returns non-0. This case
  # deliberately spends ~1-3s waiting for the timeout to fire.
  rc=0
  run_with_timeout 1 bash -c 'sleep 10' >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    t_ok "A5 run_with_timeout kills command exceeding timeout (rc=$rc)"
  else
    t_bad "A5 run_with_timeout did not fail on timeout (rc=$rc)"
  fi
  # C5: prove the child is actually killed, not merely reported failed — the
  # wrapper must return well before the wrapped `sleep 10` would finish. A short
  # elapsed time is the evidence the child process was terminated at the timeout.
  local start elapsed
  start=$SECONDS
  rc=0
  run_with_timeout 1 bash -c 'sleep 10' >/dev/null 2>&1 || rc=$?
  elapsed=$((SECONDS - start))
  if [ "$rc" -ne 0 ] && [ "$elapsed" -le 4 ]; then
    t_ok "A5 run_with_timeout kills child within timeout (${elapsed}s elapsed, rc=$rc)"
  else
    t_bad "A5 run_with_timeout did not kill promptly (elapsed=${elapsed}s rc=$rc)"
  fi
}

# Shared reject helper for A6-A10: a rejection increments FAIL and never
# accepts the attempted (non-empty) target.
expect_reject() { # $1=label $2=name $3=target
  CURRENT_CASE=""; CURRENT_CASE_TARGET=""
  local before after rc=0 ok=1
  before="$FAIL"
  # `|| rc=$?` captures the non-0 status while surviving `set -e` (a bare call
  # would abort the script before `rc=$?` under this file's `set -euo pipefail`).
  case_begin "$2" "$3" || rc=$?
  after="$FAIL"
  [ "$rc" -ne 0 ] || ok=0                                              # must return non-0
  [ "$((after - before))" -ge 1 ] || ok=0                             # must increment FAIL
  if [ -n "$3" ] && [ "$CURRENT_CASE_TARGET" = "$3" ]; then ok=0; fi  # must not set target
  [ -z "$CURRENT_CASE" ] || ok=0                                      # C6: must not set CURRENT_CASE either
  if [ "$ok" -eq 1 ]; then
    t_ok "$1"
  else
    t_bad "$1 (rc=$rc FAILdelta=$((after - before)) target='$CURRENT_CASE_TARGET' case='$CURRENT_CASE')"
  fi
}

group_a_rejections() {
  expect_reject "A6 empty name rejected"            ""         "hooks/enforce-worktree.js"
  expect_reject "A7 empty target rejected"          "c"        ""
  expect_reject "A8 absolute path rejected"         "c"        "/etc/passwd"
  expect_reject "A9 traversal ../secret rejected"   "c"        "../secret"
  expect_reject "A10 traversal a/../../b rejected"  "c"        "a/../../b"
  # C8 (security: input injection). A UNC path is absolute-prefixed (//…) so the
  # existing /*-absolute guard rejects it. Windows drive letters (C:\…) and shell
  # metacharacters are NOT caught by a /*-only guard — if these assertions fail,
  # write-code must extend case_begin with drive-letter and metachar validation.
  # These are TL2 input-injection cases per security test-design "Input injection".
  expect_reject "A8b UNC path //server/share rejected"      "c"  "//server/share"
  expect_reject "A8c Windows drive C:\\foo rejected"        "c"  'C:\foo'
  expect_reject "A8d metachar semicolon in path rejected"   "c"  "foo;rm -rf /"
}

# A11: a valid in-repo relative path is accepted (target set).
group_a11_valid_accept() {
  CURRENT_CASE=""; CURRENT_CASE_TARGET=""
  # C6: capture the accept return code instead of masking it with `|| true`.
  local rc
  rc=99
  { case_begin "goodcase" "hooks/enforce-worktree.js"; rc=$?; } 2>/dev/null || true
  t_eq "A11 case_begin valid returns 0" "$rc" "0"
  t_eq "A11 valid path accepted (target set)" "$CURRENT_CASE_TARGET" "hooks/enforce-worktree.js"
  case_end || true
}

# ===========================================================================
# Group B — bin/check-test-frontmatter.sh harness-source check extension
# ===========================================================================

# Writes a fixture test file with valid frontmatter so only the harness-source
# check is the variable under test. $1=absolute path, $2=harness ref line (may
# be empty).
make_fixture() { # $1=path $2=ref-line
  local path="$1" ref="$2" dir
  dir="$(dirname "$path")"
  mkdir -p "$dir"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# %s\n' "tests/$(basename "$path")"
    printf '# Tests: bin/example.sh\n'
    printf '# Tags: scope:issue-specific\n'
    [ -n "$ref" ] && printf '%s\n' "$ref"
    printf 'echo fixture\n'
  } >"$path"
}

# Fresh isolated fixture repo with tests/lib/harness.sh present (triggers the
# harness-source guard in check_harness_source). Prints path.
setup_repo() {
  local d
  d="$(make_tmp)"
  harness_git_init "$d/repo" >/dev/null 2>&1
  mkdir -p "$d/repo/tests/lib"
  touch "$d/repo/tests/lib/harness.sh"
  printf '%s' "$d/repo"
}

# Runs the checker in --staged mode inside $1, under a real timeout and isolated
# env. Sets CK_OUT and CK_RC. Uses bin/run-with-timeout.sh directly (known
# interface) to avoid depending on harness run_with_timeout semantics here.
# --staged requires explicit file path args (iterates "$@"); gather them from
# git's cache so callers need not duplicate the git query.
run_checker() { # $1=repo dir
  CK_RC=0
  local staged_args=()
  while IFS= read -r f; do
    [ -n "$f" ] && staged_args+=("$f")
  done < <(git -C "$1" diff --cached --name-only 2>/dev/null)
  CK_OUT="$(
    cd "$1" || exit 99
    harness_isolate >/dev/null 2>&1 || true
    bash "$AGENTS_DIR/bin/run-with-timeout.sh" 30 bash "$CHECKER" --staged "${staged_args[@]}" 2>&1
  )" || CK_RC=$?
}

# Probe: is the harness-source check extension installed? Stage one new
# categorized test file (tests/<category>/*.sh — flat tests/*.sh is rejected by
# the #1834 gate before the harness check runs) without a harness source line;
# the extension must emit MISSING_HARNESS_SOURCE. If it does not, the extension
# is absent → skip Group B.
extension_present() {
  local repo
  repo="$(setup_repo)"
  make_fixture "$repo/tests/bin/probe.sh" ""
  git -C "$repo" add tests/bin/probe.sh >/dev/null 2>&1 || true
  run_checker "$repo"
  case "$CK_OUT" in
    *MISSING_HARNESS_SOURCE*) return 0 ;;
    *) return 1 ;;
  esac
}

# B1: new categorized file without harness source → MISSING_HARNESS_SOURCE, exit 1.
group_b1_missing() {
  local repo
  repo="$(setup_repo)"
  make_fixture "$repo/tests/bin/foo.sh" ""
  git -C "$repo" add tests/bin/foo.sh >/dev/null 2>&1 || true
  run_checker "$repo"
  if [ "$CK_RC" -eq 1 ] && printf '%s' "$CK_OUT" | grep -q 'MISSING_HARNESS_SOURCE'; then
    t_ok "B1 missing harness → MISSING_HARNESS_SOURCE, exit 1"
  else
    t_bad "B1 expected MISSING_HARNESS_SOURCE exit 1 (rc=$CK_RC out='$CK_OUT')"
  fi
}

# Shared pass helper for the accept cases (B2, B3, B7, B8, B9).
expect_pass() { # $1=label $2=repo
  run_checker "$2"
  if [ "$CK_RC" -eq 0 ]; then
    t_ok "$1"
  else
    t_bad "$1 (rc=$CK_RC out='$CK_OUT')"
  fi
}

# B2: `source tests/lib/harness.sh` present → passes.
group_b2_source_keyword() {
  local repo
  repo="$(setup_repo)"
  make_fixture "$repo/tests/bin/foo.sh" "source tests/lib/harness.sh"
  git -C "$repo" add tests/bin/foo.sh >/dev/null 2>&1 || true
  expect_pass "B2 source keyword present → passes" "$repo"
}

# B3: `. tests/lib/harness.sh` (dot) present → passes.
group_b3_dot_keyword() {
  local repo
  repo="$(setup_repo)"
  make_fixture "$repo/tests/bin/foo.sh" ". tests/lib/harness.sh"
  git -C "$repo" add tests/bin/foo.sh >/dev/null 2>&1 || true
  expect_pass "B3 dot keyword present → passes" "$repo"
}

# B4: comment-only reference (no real source) → MISSING_HARNESS_SOURCE, exit 1.
group_b4_comment_only() {
  local repo
  repo="$(setup_repo)"
  make_fixture "$repo/tests/bin/foo.sh" "# source tests/lib/harness.sh"
  git -C "$repo" add tests/bin/foo.sh >/dev/null 2>&1 || true
  run_checker "$repo"
  if [ "$CK_RC" -eq 1 ] && printf '%s' "$CK_OUT" | grep -q 'MISSING_HARNESS_SOURCE'; then
    t_ok "B4 comment-only reference → MISSING_HARNESS_SOURCE, exit 1"
  else
    t_bad "B4 expected MISSING_HARNESS_SOURCE exit 1 (rc=$CK_RC out='$CK_OUT')"
  fi
}

# B5: echo reference only → MISSING_HARNESS_SOURCE, exit 1.
group_b5_echo_reference() {
  local repo
  repo="$(setup_repo)"
  make_fixture "$repo/tests/bin/foo.sh" "echo tests/lib/harness.sh"
  git -C "$repo" add tests/bin/foo.sh >/dev/null 2>&1 || true
  run_checker "$repo"
  if [ "$CK_RC" -eq 1 ] && printf '%s' "$CK_OUT" | grep -q 'MISSING_HARNESS_SOURCE'; then
    t_ok "B5 echo reference only → MISSING_HARNESS_SOURCE, exit 1"
  else
    t_bad "B5 expected MISSING_HARNESS_SOURCE exit 1 (rc=$CK_RC out='$CK_OUT')"
  fi
}

# B6: reference lives only in the `# Tests:` header → MISSING_HARNESS_SOURCE.
group_b6_header_only() {
  local repo path
  repo="$(setup_repo)"
  path="$repo/tests/bin/foo.sh"
  mkdir -p "$repo/tests/bin"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# tests/bin/foo.sh\n'
    printf '# Tests: tests/lib/harness.sh\n'
    printf '# Tags: scope:issue-specific\n'
    printf 'echo fixture\n'
  } >"$path"
  git -C "$repo" add tests/bin/foo.sh >/dev/null 2>&1 || true
  run_checker "$repo"
  if [ "$CK_RC" -eq 1 ] && printf '%s' "$CK_OUT" | grep -q 'MISSING_HARNESS_SOURCE'; then
    t_ok "B6 # Tests: header reference only → MISSING_HARNESS_SOURCE, exit 1"
  else
    t_bad "B6 expected MISSING_HARNESS_SOURCE exit 1 (rc=$CK_RC out='$CK_OUT')"
  fi
}

# B7: a modified (not new) existing file without harness → passes.
group_b7_modified_existing() {
  local repo
  repo="$(setup_repo)"
  make_fixture "$repo/tests/bin/existing.sh" ""
  git -C "$repo" add tests/bin/existing.sh >/dev/null 2>&1 || true
  git -C "$repo" -c user.email=harness@example.com -c user.name=Harness \
      commit -q -m "seed existing" >/dev/null 2>&1 || true
  printf 'echo modified\n' >>"$repo/tests/bin/existing.sh"
  git -C "$repo" add tests/bin/existing.sh >/dev/null 2>&1 || true
  expect_pass "B7 modified existing file (no harness) → passes" "$repo"
}

# B8: new file under tests/lib/ → excluded from the harness check → passes.
group_b8_subdir_lib() {
  local repo
  repo="$(setup_repo)"
  make_fixture "$repo/tests/lib/foo.sh" ""
  git -C "$repo" add tests/lib/foo.sh >/dev/null 2>&1 || true
  expect_pass "B8 new tests/lib/foo.sh → harness check excluded → passes" "$repo"
}

# B9: new file under tests/bin-x/ → excluded from the harness check → passes.
group_b9_subdir_binx() {
  local repo
  repo="$(setup_repo)"
  make_fixture "$repo/tests/bin-x/bar.sh" ""
  git -C "$repo" add tests/bin-x/bar.sh >/dev/null 2>&1 || true
  expect_pass "B9 new tests/bin-x/bar.sh → harness check excluded → passes" "$repo"
}

# B-var: variable-form `source "$HARNESS"` does NOT match the checker's literal
# path pattern → MISSING_HARNESS_SOURCE, exit 1.
group_b_variable_source() {
  local repo
  repo="$(setup_repo)"
  make_fixture "$repo/tests/bin/foo.sh" 'source "$HARNESS"'
  git -C "$repo" add tests/bin/foo.sh >/dev/null 2>&1 || true
  run_checker "$repo"
  if [ "$CK_RC" -eq 1 ] && printf '%s' "$CK_OUT" | grep -q 'MISSING_HARNESS_SOURCE'; then
    t_ok "B variable-form source \"\$HARNESS\" → MISSING_HARNESS_SOURCE, exit 1"
  else
    t_bad "B variable source expected MISSING_HARNESS_SOURCE exit 1 (rc=$CK_RC out='$CK_OUT')"
  fi
}

# B-prefix: a path-suffix form (…/tests/lib/harness.sh) matches the checker
# pattern via its optional leading segment → passes. The ref line carries the
# real expanded AGENTS_DIR path, double-quoted, so the suffix is literal.
group_b_path_prefix_source() {
  local repo
  repo="$(setup_repo)"
  make_fixture "$repo/tests/bin/foo.sh" "source \"$AGENTS_DIR/tests/lib/harness.sh\""
  git -C "$repo" add tests/bin/foo.sh >/dev/null 2>&1 || true
  expect_pass "B path-prefix source (…/tests/lib/harness.sh) → passes" "$repo"
}

# C7 B-dead: a `source tests/lib/harness.sh` inside a never-called function body
# still satisfies the checker. The check is a regex scan of the whole file, so it
# matches dead code intentionally — the author declared the source relationship.
group_b_dead_function_body() {
  local repo
  repo="$(setup_repo)"
  make_fixture "$repo/tests/bin/foo.sh" "$(printf 'unused_fn() {\n  source tests/lib/harness.sh\n}')"
  git -C "$repo" add tests/bin/foo.sh >/dev/null 2>&1 || true
  expect_pass "B dead function body source → checker accepts (regex scan)" "$repo"
}

# B-all-legacy: --all mode must NOT fail existing files that lack a harness
# source line. Protects the gradual-migration accepted tradeoff: the extension
# only applies to newly added top-level test files (--staged, new-only); legacy
# files must continue to pass --all without any source line added.
group_b_all_mode_legacy() {
  local repo rc=0 ck_out
  repo="$(setup_repo)"
  # Commit a legacy test file without harness source (simulates a pre-#2080 file).
  # Categorized path so the #1834 --all scan (tests/<category>/*.sh only) reaches it.
  make_fixture "$repo/tests/bin/legacy.sh" ""
  git -C "$repo" add tests/bin/legacy.sh >/dev/null 2>&1 || true
  git -C "$repo" -c user.email=harness@example.com -c user.name=Harness \
      commit -q -m "seed legacy" >/dev/null 2>&1 || true
  # --all mode must exit 0; the extension must not reject committed legacy files.
  ck_out="$(
    cd "$repo" || exit 99
    harness_isolate >/dev/null 2>&1 || true
    bash "$AGENTS_DIR/bin/run-with-timeout.sh" 30 bash "$CHECKER" --all 2>&1
  )" || rc=$?
  if [ "$rc" -eq 0 ]; then
    t_ok "B-all-legacy --all passes existing file lacking harness source (gradual-migration tradeoff)"
  else
    t_bad "B-all-legacy --all rejected legacy file (rc=$rc out='$ck_out')"
  fi
}

# ===========================================================================
# Runner
# ===========================================================================

# Group A — harness function coverage.
group_a1_definitions
group_a_np_function
group_a2_reentry_guard
group_a3_assert_eq_success
group_a3_pass_direct
group_a3_fail_direct
group_a3_skip_direct
group_a3_fresh_shell
group_a4_assert_eq_failure
group_a_harness_isolate
group_a5_case_begin_end
group_a_run_with_timeout
group_a_rejections
group_a11_valid_accept

# Group B — the checker extension. Past the exit-77 guard the harness.sh file
# exists, so the extension MUST exist too: write-code implements both together.
if extension_present; then
  group_b1_missing
  group_b2_source_keyword
  group_b3_dot_keyword
  group_b4_comment_only
  group_b5_echo_reference
  group_b6_header_only
  group_b7_modified_existing
  group_b8_subdir_lib
  group_b9_subdir_binx
  group_b_variable_source
  group_b_path_prefix_source
  group_b_dead_function_body
  group_b_all_mode_legacy
else
  t_bad "harness.sh present but checker extension absent — write-code must implement both together"
fi

echo ""
echo "Results: T_PASS=$T_PASS T_FAIL=$T_FAIL T_SKIP=$T_SKIP"
[ "$T_FAIL" -eq 0 ] && exit 0 || exit 1
