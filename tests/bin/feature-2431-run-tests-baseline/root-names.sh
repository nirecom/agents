# shellcheck shell=bash
# tests/bin/feature-2431-run-tests-baseline/root-names.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, cli, exec, root-names, security, scope:issue-specific, pwsh-not-required, TL2
# Sourced by the dispatcher; never run standalone.
# #2561: a merge-base older than the root rename gives no baseline (exit 5, nothing launched);
# rtb_exec_one runs the base test under the launcher's decoy pin and adds no root name itself.

_ROOT_NAMES_SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$_ROOT_NAMES_SCRIPT_CHECKOUT_ROOT/tests/lib/root-decoy.sh"
_RN_BUILDER="$(np "$_ROOT_NAMES_SCRIPT_CHECKOUT_ROOT/tests/lib/root-decoy-build.js")"
_RN_NEW_NAME="AGENTS_MAIN""_ROOT"

# isolation (#2512): re-pin to helpers.sh's private dirs (a sibling's pin is invisible to the scanner).
: "${WF_DIR:?helpers.sh must be sourced first}" "${PLANS_DIR:?helpers.sh must be sourced first}"
export WORKFLOW_STATE_DIR="$(np "$WF_DIR")" WORKFLOW_PLANS_DIR="$(np "$PLANS_DIR")"
harness_assert_isolated

_rn_canon() { local p; p="$(np "$1")"; printf '%s' "${p%/}" | tr 'A-Z' 'a-z'; }

# _rn_load_retired — the retired environment names into _RN_RETIRED (never spelled here).
_rn_load_retired() {
  local n
  _RN_RETIRED=()
  while IFS= read -r n; do
    n="${n%$'\r'}"
    if [ -n "$n" ]; then _RN_RETIRED+=("$n"); fi
  done < <(run_with_timeout 30 node "$_RN_BUILDER" --print-retired-env-names 2>/dev/null)
  [ "${#_RN_RETIRED[@]}" -gt 0 ]
}

# _rn_snippet <repo> <old|new|none> — the profile snippet in its pre-rename / post-rename shape.
_rn_snippet() {
  case "$2" in
    old) printf '# profile snippet\nexport %s="$HOME/somewhere"\n' "${_RN_RETIRED[0]}" > "$1/profile-snippet.sh" ;;
    new) printf '# profile snippet\nexport %s="$HOME/somewhere"\n' "$_RN_NEW_NAME" > "$1/profile-snippet.sh" ;;
    none) rm -f "$1/profile-snippet.sh" ;;
  esac
}

# _rn_cli_repo <repo> <shape at merge-base> <shape at HEAD> <sentinel> — the one failing test
# leaves <sentinel> behind whenever it is launched.
_rn_cli_repo() {
  mk_fixture_repo "$1" >/dev/null
  git -C "$1" checkout -q main
  printf '#!/usr/bin/env bash\ntouch "%s"\nexit 1\n' "$(np "$4")" > "$1/tests/bin/test-preexisting.sh"
  _rn_snippet "$1" "$2"
  git -C "$1" add -A
  git -C "$1" commit -q -m "base shape $2"
  git -C "$1" checkout -q feature
  git -C "$1" merge -q --no-edit main
  if [ "$3" != "$2" ]; then
    _rn_snippet "$1" "$3"
    git -C "$1" add -A
    git -C "$1" commit -q -m "head shape $3"
  fi
}

# _rn_cli <cache> <repo> <sid> — sets _RN_RC; stdout / stderr land in $TMPROOT/rn-out|err.txt.
_rn_cli() {
  _RN_RC=0
  (cd "$TMPROOT" && export RUN_ALL_CACHE_DIR="$1" && run_with_timeout 120 bash "$BASELINE_CLI" \
    --session "$3" --worktree "$2" --per-test-timeout 10 >"$TMPROOT/rn-out.txt" 2>"$TMPROOT/rn-err.txt") || _RN_RC=$?
}

_rn_worktree_count() { git -C "$1" worktree list --porcelain 2>/dev/null | grep -c '^worktree '; }

run_root_names_cli_cases() {
  local t="tests/bin/test-preexisting.sh" repo ran cache base
  if ! _rn_load_retired; then fail "RN-cli: setup — the retired environment names are unavailable"; return; fi

  # ---- base predates the rename, HEAD carries the new name (this branch's own shape) ----
  repo="$TMPROOT/rn-cli-old"; ran="$TMPROOT/rn-cli-old.ran"; cache="$(cli_case_cache rn-old)"
  _rn_cli_repo "$repo" old new "$ran"
  base="$(git -C "$repo" rev-parse main)"
  if git -C "$repo" show "main:profile-snippet.sh" 2>/dev/null | grep -qF "$_RN_NEW_NAME" \
    || ! git -C "$repo" show "HEAD:profile-snippet.sh" 2>/dev/null | grep -qF "$_RN_NEW_NAME"; then
    fail "RN-cli: setup — fixture shapes are wrong (base must lack the new name, HEAD must carry it)"
    return
  fi
  seed_failing "rn-old-$$" "$t"
  _rn_cli "$cache" "$repo" "rn-old-$$"
  [ "$_RN_RC" -eq 5 ] && pass "RN-cli-old: exit 5 when the merge-base predates the root rename" \
    || fail "RN-cli-old: expected exit 5, got $_RN_RC (stderr: $(tr '\n' '|' < "$TMPROOT/rn-err.txt"))"
  if grep -E '^run-tests-baseline: ' "$TMPROOT/rn-err.txt" | grep -i 'baseline' | grep -qi 'rebase'; then
    pass "RN-cli-old: stderr says there is no baseline and a rebase is needed"
  else
    fail "RN-cli-old: no 'run-tests-baseline: ... baseline ... rebase' line on stderr ($(tr '\n' '|' < "$TMPROOT/rn-err.txt"))"
  fi
  if [ "$_RN_RC" -eq 5 ] && ! grep -q '^BASELINE' "$TMPROOT/rn-out.txt" \
    && ! grep -q 'base-run logs:' "$TMPROOT/rn-out.txt" "$TMPROOT/rn-err.txt"; then
    pass "RN-cli-old: no classification line and no base-run log directory"
  else
    fail "RN-cli-old: expected exit 5 with no BASELINE lines; rc=$_RN_RC out=$(tr '\n' '|' < "$TMPROOT/rn-out.txt")"
  fi
  [ "$_RN_RC" -eq 5 ] && [ ! -e "$ran" ] && pass "RN-cli-old: no fixture test was launched" \
    || fail "RN-cli-old: rc=$_RN_RC, the failing test ran at base=$([ -e "$ran" ] && echo yes || echo no)"
  [ "$_RN_RC" -eq 5 ] && [ "$(_rn_worktree_count "$repo")" = "1" ] \
    && pass "RN-cli-old: no merge-base worktree was created" \
    || fail "RN-cli-old: rc=$_RN_RC, worktrees=$(_rn_worktree_count "$repo") (expected exit 5 and 1)"
  if [ "$_RN_RC" -eq 5 ] && [ "$(read_step_field "rn-old-$$" run_tests status)" = '"pending"' ] \
    && [ "$(read_step_field "rn-old-$$" run_tests completion_basis)" = "(absent)" ] \
    && [ "$(read_step_field "rn-old-$$" run_tests baseline_classification)" = "(absent)" ]; then
    pass "RN-cli-old: run_tests stays pending with nothing recorded"
  else
    fail "RN-cli-old: rc=$_RN_RC status=$(read_step_field "rn-old-$$" run_tests status) classification=$(read_step_field "rn-old-$$" run_tests baseline_classification)"
  fi

  # ---- idempotent, and decided before the ledger: a cached same-base verdict changes nothing ----
  ledger_call "$cache" "$repo" rtb_ledger_append "$base" "$t" pass >/dev/null 2>&1
  _rn_cli "$cache" "$repo" "rn-old-$$"
  if [ "$_RN_RC" -eq 5 ] && ! grep -q '^BASELINE' "$TMPROOT/rn-out.txt" && [ ! -e "$ran" ] \
    && [ "$(_rn_worktree_count "$repo")" = "1" ]; then
    pass "RN-cli-old: second run with a cached same-base record still exits 5 and launches nothing"
  else
    fail "RN-cli-old: second run rc=$_RN_RC out=$(tr '\n' '|' < "$TMPROOT/rn-out.txt")"
  fi

  # ---- other verdict: a base that already carries the new name is compared as before ----
  repo="$TMPROOT/rn-cli-new"; ran="$TMPROOT/rn-cli-new.ran"
  _rn_cli_repo "$repo" new new "$ran"
  seed_failing "rn-new-$$" "$t"
  _rn_cli "$(cli_case_cache rn-new)" "$repo" "rn-new-$$"
  if [ "$_RN_RC" -eq 0 ] && grep -qE "^BASELINE: preexisting[[:space:]]+$t" "$TMPROOT/rn-out.txt" && [ -e "$ran" ]; then
    pass "RN-cli-new: a post-rename base is run and classified (exit 0, preexisting)"
  else
    fail "RN-cli-new: expected exit 0 + preexisting + a launched test; rc=$_RN_RC out=$(tr '\n' '|' < "$TMPROOT/rn-out.txt")"
  fi

  # ---- other verdict: the snippet is absent at the base; only HEAD has a pre-rename one ----
  repo="$TMPROOT/rn-cli-none"; ran="$TMPROOT/rn-cli-none.ran"
  _rn_cli_repo "$repo" none old "$ran"
  seed_failing "rn-none-$$" "$t"
  _rn_cli "$(cli_case_cache rn-none)" "$repo" "rn-none-$$"
  if [ "$_RN_RC" -eq 0 ] && grep -qE "^BASELINE: preexisting[[:space:]]+$t" "$TMPROOT/rn-out.txt" && [ -e "$ran" ]; then
    pass "RN-cli-none: a base without the snippet is run; the HEAD content does not decide"
  else
    fail "RN-cli-none: expected exit 0 + preexisting; rc=$_RN_RC out=$(tr '\n' '|' < "$TMPROOT/rn-out.txt")"
  fi
}

# _rn_predicate <label> <want rc> <root> <commit> — 0 means "predates the rename", 1 means not.
_rn_predicate() {
  local rc=0
  (cd "$TMPROOT" && rtb_call 30 "$EXEC_LIB" rtb_base_predates_root_names "$3" "$4" >/dev/null 2>&1) || rc=$?
  [ "$rc" -eq "$2" ] && pass "RN-predicate: $1 → $2" || fail "RN-predicate: $1 — expected status $2, got $rc"
}

run_root_names_predicate_cases() {
  local d="$TMPROOT/rn pred & \$x" old new none nested c_old c_new r
  if ! _rn_load_retired; then fail "RN-predicate: setup — the retired environment names are unavailable"; return; fi
  old="$d/old"; new="$d/new"; none="$d/none"; nested="$d/nested"
  mkdir -p "$d"
  for r in "$old" "$new" "$none" "$nested"; do
    harness_git_init "$r" >/dev/null 2>&1
    git -C "$r" config core.autocrlf false
    git -C "$r" config user.email test@example.com
    git -C "$r" config user.name Test
    git -C "$r" config commit.gpgsign false
    printf 'x\n' > "$r/readme.txt"
  done
  _rn_snippet "$old" old
  _rn_snippet "$new" new
  mkdir -p "$nested/sub"
  _rn_snippet "$nested/sub" old
  for r in "$old" "$new" "$none" "$nested"; do
    git -C "$r" add -A
    git -C "$r" commit -q -m "first"
  done
  c_old="$(git -C "$old" rev-parse HEAD)"
  _rn_snippet "$old" new
  git -C "$old" add -A
  git -C "$old" commit -q -m "renamed"
  c_new="$(git -C "$old" rev-parse HEAD)"
  if [ -z "$c_old" ] || [ -z "$c_new" ] || [ "$c_old" = "$c_new" ]; then
    fail "RN-predicate: setup — fixture commits were not created"
    return
  fi

  _rn_predicate "snippet present without the new name" 0 "$old" "$c_old"
  _rn_predicate "later commit of the same repository carries the new name" 1 "$old" "$c_new"
  _rn_predicate "snippet present with the new name" 1 "$new" HEAD
  _rn_predicate "repository without the snippet" 1 "$none" HEAD
  _rn_predicate "snippet only in a subdirectory" 1 "$nested" HEAD
  # The commit decides, never the working tree.
  _rn_snippet "$new" old
  _rn_predicate "working tree edited back to the old shape, commit unchanged" 1 "$new" HEAD
  _rn_predicate "old commit asked again (same answer)" 0 "$old" "$c_old"
  if [ "$(_rn_worktree_count "$old")" = "1" ] && [ -z "$(git -C "$old" status --porcelain 2>/dev/null)" ]; then
    pass "RN-predicate: the check leaves the repository untouched"
  else
    fail "RN-predicate: the check changed the repository ($(git -C "$old" status --porcelain 2>/dev/null | tr '\n' '|'))"
  fi
}

# _rn_exec_probe <wt> <rel> <logdir> [NAME=value...] — rtb_exec_one with AGENTS_MAIN_ROOT set to
# $_RN_CALLER_MAIN and every retired name pointing at the old-name decoy; prints
# "RC=<n> DECOY=<0|1>".
_rn_exec_probe() {
  local wt="$1" rel="$2" logs="$3"; shift 3
  mkdir -p "$logs"
  (cd "$wt" && AGENTS_MAIN_ROOT="$_RN_CALLER_MAIN" run_with_timeout 90 env "${_RN_ENV[@]}" "$@" bash -c \
    '. "$1" || exit 98; shift; rtb_exec_one "$@"; printf "RC=%s DECOY=%s\n" "${RTB_EXEC_RC:-unset}" "${RTB_EXEC_DECOY:-unset}"' \
    rn_probe "$EXEC_LIB" "$wt" "$rel" 10 "$logs" 2>/dev/null | grep '^RC=' | tail -1)
}

# _rn_exec_probe_ret <wt> <rel> <logdir> — the same call; prints "RET=<status> RC=<n|unset>".
_rn_exec_probe_ret() {
  local wt="$1" rel="$2" logs="$3"
  mkdir -p "$logs"
  (cd "$wt" && AGENTS_MAIN_ROOT="$_RN_CALLER_MAIN" run_with_timeout 90 env "${_RN_ENV[@]}" bash -c \
    '. "$1" || exit 98; shift; rtb_exec_one "$@"; printf "RET=%s RC=%s\n" "$?" "${RTB_EXEC_RC:-unset}"' \
    rn_probe "$EXEC_LIB" "$wt" "$rel" 10 "$logs" 2>/dev/null | grep '^RET=' | tail -1)
}

# _rn_seen <dump> <name> — the value the base test saw for <name>, canonical form.
_rn_seen() { _rn_canon "$(sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1)"; }

run_root_names_exec_cases() {
  local d="$TMPROOT/rn exec" wt wt2 wt3 decoy rec rec3 ran3 dump tool r name stale
  if ! _rn_load_retired; then fail "RN-exec: setup — the retired environment names are unavailable"; return; fi
  mkdir -p "$d"
  decoy="$(np "$d/decoy")"
  if ! run_with_timeout 120 node "$_RN_BUILDER" --out "$decoy" >/dev/null 2>&1 || [ ! -d "$decoy/main/bin" ]; then
    fail "RN-exec: setup — the decoy tree could not be built"
    return
  fi
  _RN_ENV=("RN_PROBE=1")
  for name in "${_RN_RETIRED[@]}"; do _RN_ENV+=("$name=$decoy/old"); done

  # ---- the base checkout brings its own launcher: its decoy pin is called, then the test ----
  wt="$d/repo"; rec="$(np "$d/calls.txt")"; dump="$(np "$d/env.txt")"; tool="$(np "$d/tool.txt")"
  mk_fixture_repo "$wt" >/dev/null
  mkdir -p "$wt/bin/lib"
  cat > "$wt/bin/lib/run-all-launch.sh" << EOF
run_all_pin_root_decoy() { printf 'pin\n' >> "$rec"; }
run_all_exec() {
  printf 'exec\n' >> "$rec"
  env > "$dump"
  bash "\$1" > "\$2" 2> "\$3"
}
EOF
  printf '#!/usr/bin/env bash\nprintf "tool\\n" >> "%s"\n' "$tool" > "$wt/bin/fixture-tool.sh"
  cat > "$wt/tests/bin/test-uses-bin.sh" << 'EOF'
#!/usr/bin/env bash
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bash "$here/bin/fixture-tool.sh"
EOF
  _RN_CALLER_MAIN="$decoy/main"
  r="$(_rn_exec_probe "$wt" tests/bin/test-uses-bin.sh "$d/logs1")"
  [ "$r" = "RC=0 DECOY=0" ] && pass "RN-exec: the base test ran under the fixture launcher (RC=0, no decoy hit)" \
    || fail "RN-exec: expected 'RC=0 DECOY=0', got: ${r:-none}"
  [ "$(tr '\n' '|' < "$rec" 2>/dev/null)" = "pin|exec|" ] \
    && pass "RN-exec: the selected launcher's decoy pin is called once, before the test" \
    || fail "RN-exec: launcher call order was [$(tr '\n' '|' < "$rec" 2>/dev/null)], expected [pin|exec|]"
  [ "$(tr '\n' '|' < "$tool" 2>/dev/null)" = "tool|" ] \
    && pass "RN-exec: the base checkout's own bin/ script was the one called" \
    || fail "RN-exec: fixture bin/ call record is [$(tr '\n' '|' < "$tool" 2>/dev/null)]"
  stale=""
  for name in "${_RN_RETIRED[@]}"; do
    if [ "$(_rn_seen "$dump" "$name")" != "$(_rn_canon "$decoy/old")" ]; then stale="$stale #${name%%_*}=$(_rn_seen "$dump" "$name")"; fi
  done
  [ -f "$dump" ] && [ -z "$stale" ] && pass "RN-exec: no retired name is re-pointed at the base checkout" \
    || fail "RN-exec: a retired name was changed on the way to the base test:${stale:- no env dump}"
  [ "$(_rn_seen "$dump" "$_RN_NEW_NAME")" = "$(_rn_canon "$decoy/main")" ] \
    && pass "RN-exec: rtb_exec_one itself leaves AGENTS_MAIN_ROOT alone" \
    || fail "RN-exec: the base test saw AGENTS_MAIN_ROOT=$(_rn_seen "$dump" "$_RN_NEW_NAME")"

  # ---- the launcher's decoy pin fails: a setup failure, and the base test is never started ----
  wt3="$d/repo3"; rec3="$(np "$d/calls3.txt")"; ran3="$(np "$d/ran3.txt")"
  mk_fixture_repo "$wt3" >/dev/null
  mkdir -p "$wt3/bin/lib"
  cat > "$wt3/bin/lib/run-all-launch.sh" << EOF
run_all_pin_root_decoy() { printf 'pin\n' >> "$rec3"; return 1; }
run_all_exec() { printf 'exec\n' >> "$rec3"; bash "\$1" > "\$2" 2> "\$3"; }
EOF
  printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$ran3" > "$wt3/tests/bin/test-must-not-run.sh"
  _RN_CALLER_MAIN="$decoy/main"
  r="$(_rn_exec_probe_ret "$wt3" tests/bin/test-must-not-run.sh "$d/logs3")"
  [ "$r" = "RET=2 RC=unset" ] && pass "RN-exec-pin-fails: rtb_exec_one returns 2 and reports no test exit code" \
    || fail "RN-exec-pin-fails: expected 'RET=2 RC=unset', got: ${r:-none}"
  [ "$(tr '\n' '|' < "$rec3" 2>/dev/null)" = "pin|" ] \
    && pass "RN-exec-pin-fails: the pin was tried once and the launch function was never called" \
    || fail "RN-exec-pin-fails: launcher call order was [$(tr '\n' '|' < "$rec3" 2>/dev/null)], expected [pin|]"
  [ ! -e "$ran3" ] && pass "RN-exec-pin-fails: the base test did not run" \
    || fail "RN-exec-pin-fails: the base test ran without the decoy pin"
  [ "$(find "$d/logs3" -name '*.nolaunch' 2>/dev/null | wc -l | tr -d ' ')" = "1" ] \
    && pass "RN-exec-pin-fails: the failure is flagged as not launched in the log directory" \
    || fail "RN-exec-pin-fails: log directory holds [$(ls "$d/logs3" 2>/dev/null | tr '\n' '|')], expected one .nolaunch flag"

  # ---- no launcher in the base checkout: this checkout's launcher pins the decoy even when ----
  # ---- the caller's AGENTS_MAIN_ROOT names a real directory                                ----
  wt2="$d/repo2"; dump="$(np "$d/env2.txt")"
  mk_fixture_repo "$wt2" >/dev/null
  printf '#!/usr/bin/env bash\nenv > "%s"\n' "$dump" > "$wt2/tests/bin/test-dump-env.sh"
  _RN_CALLER_MAIN="$(np "$wt2")"
  r="$(_rn_exec_probe "$wt2" tests/bin/test-dump-env.sh "$d/logs2" "ROOT_DECOY_DIR=$decoy")"
  [ "$r" = "RC=0 DECOY=0" ] && [ -f "$dump" ] && pass "RN-exec-own-launcher: the base test ran (RC=0, no decoy hit)" \
    || fail "RN-exec-own-launcher: expected 'RC=0 DECOY=0' and an env dump, got: ${r:-none}"
  [ "$(_rn_seen "$dump" "$_RN_NEW_NAME")" = "$(_rn_canon "$decoy/main")" ] \
    && pass "RN-exec-own-launcher: the base test sees the decoy as AGENTS_MAIN_ROOT, not the caller's value" \
    || fail "RN-exec-own-launcher: the base test saw AGENTS_MAIN_ROOT=$(_rn_seen "$dump" "$_RN_NEW_NAME"), expected $decoy/main"
  stale=""
  for name in "${_RN_RETIRED[@]}"; do
    if [ "$(_rn_seen "$dump" "$name")" != "$(_rn_canon "$decoy/old")" ]; then stale="$stale #${name%%_*}=$(_rn_seen "$dump" "$name")"; fi
  done
  [ -f "$dump" ] && [ -z "$stale" ] && pass "RN-exec-own-launcher: every retired name points at the old-name decoy" \
    || fail "RN-exec-own-launcher: retired names seen by the base test:${stale:- no env dump}"

  r="$(root_decoy_hit_count "$decoy/main")/$(root_decoy_hit_count "$decoy/old")"
  [ "$r" = "0/0" ] && pass "RN-exec: no decoy stub was executed (main/old hits 0/0)" \
    || fail "RN-exec: decoy hits main/old = $r: $(root_decoy_hits "$decoy/main" | tr '\n' '|')$(root_decoy_hits "$decoy/old" | tr '\n' '|')"
}

run_root_names_exec_hit_cases() {
  local d="$TMPROOT/rn exec hit" wt decoy r name
  if ! _rn_load_retired; then fail "RN-exec-hit: setup — the retired environment names are unavailable"; return; fi
  mkdir -p "$d"
  decoy="$(np "$d/decoy")"
  if ! run_with_timeout 120 node "$_RN_BUILDER" --out "$decoy" >/dev/null 2>&1 || [ ! -f "$decoy/main/hooks/lib/load-env.js" ]; then
    fail "RN-exec-hit: setup — the decoy tree could not be built"
    return
  fi
  _RN_ENV=("RN_PROBE=1" "ROOT_DECOY_DIR=$decoy")
  for name in "${_RN_RETIRED[@]}"; do _RN_ENV+=("$name=$decoy/old"); done
  _RN_CALLER_MAIN="$decoy/main"
  wt="$d/repo"
  mk_fixture_repo "$wt" >/dev/null
  printf '#!/usr/bin/env bash\nnode "$%s/hooks/lib/load-env.js" >/dev/null 2>&1 || true\necho reached-the-end\nexit 0\n' \
    "$_RN_NEW_NAME" > "$wt/tests/bin/test-reaches-decoy.sh"
  printf '#!/usr/bin/env bash\nnode "$%s/hooks/lib/load-env.js" >/dev/null 2>&1 || true\nexit 3\n' \
    "$_RN_NEW_NAME" > "$wt/tests/bin/test-reaches-decoy-exit3.sh"

  r="$(_rn_exec_probe "$wt" tests/bin/test-reaches-decoy.sh "$d/logs-hit")"
  grep -q '^reached-the-end$' "$d/logs-hit/1.out" 2>/dev/null \
    && pass "RN-exec-hit: the base test itself ran to its exit 0" \
    || fail "RN-exec-hit: the base test did not run to its end (out: $(tr '\n' '|' < "$d/logs-hit/1.out" 2>/dev/null))"
  case "$r" in
    "RC=0 "*|RC=unset*|"") fail "RN-exec-hit: a base test that reached the decoy must not be green, got: ${r:-none}" ;;
    *) pass "RN-exec-hit: a base test that exits 0 but reached the decoy is not green ($r)" ;;
  esac
  [ "$r" = "RC=1 DECOY=1" ] && [ -e "$d/logs-hit/1.decoyhit" ] \
    && pass "RN-exec-hit-flag: the hit is reported as RTB_EXEC_DECOY=1 with a .decoyhit marker" \
    || fail "RN-exec-hit-flag: expected 'RC=1 DECOY=1' and 1.decoyhit, got: ${r:-none} (logs: $(ls "$d/logs-hit" 2>/dev/null | tr '\n' '|'))"
  grep -q 'root decoy hit: .*hooks/lib/load-env\.js' "$d/logs-hit/1.err" 2>/dev/null \
    && pass "RN-exec-hit: the hit is named in the test's stderr log" \
    || fail "RN-exec-hit: no 'root decoy hit' line in 1.err ($(tr '\n' '|' < "$d/logs-hit/1.err" 2>/dev/null))"

  r="$(_rn_exec_probe "$wt" tests/bin/test-reaches-decoy-exit3.sh "$d/logs-hit3")"
  [ "$r" = "RC=3 DECOY=1" ] && [ -e "$d/logs-hit3/1.decoyhit" ] \
    && pass "RN-exec-hit-nonzero: a failing base test that reached the decoy keeps its exit code and is flagged" \
    || fail "RN-exec-hit-nonzero: expected 'RC=3 DECOY=1' and 1.decoyhit, got: ${r:-none} (logs: $(ls "$d/logs-hit3" 2>/dev/null | tr '\n' '|'))"

  r="$(_rn_exec_probe "$wt" tests/bin/test-broken.sh "$d/logs-clean")"
  [ "$r" = "RC=0 DECOY=0" ] && pass "RN-exec-hit: a base test that exits 0 without a hit stays green (RTB_EXEC_DECOY=0)" \
    || fail "RN-exec-hit: expected 'RC=0 DECOY=0' for the clean base test, got: ${r:-none}"
  ! grep -q 'root decoy hit' "$d/logs-clean/1.err" 2>/dev/null && [ ! -e "$d/logs-clean/1.decoyhit" ] \
    && pass "RN-exec-hit: the clean base test's stderr log names no hit and no marker is left" \
    || fail "RN-exec-hit: the clean base test was charged a hit ($(tr '\n' '|' < "$d/logs-clean/1.err" 2>/dev/null))"

  r="$(_rn_exec_probe "$wt" tests/bin/test-preexisting.sh "$d/logs-fail")"
  [ "$r" = "RC=1 DECOY=0" ] && pass "RN-exec-hit: a base test that fails without a hit is RC=1 with RTB_EXEC_DECOY=0" \
    || fail "RN-exec-hit: expected 'RC=1 DECOY=0' for the plain failing base test, got: ${r:-none}"
}
