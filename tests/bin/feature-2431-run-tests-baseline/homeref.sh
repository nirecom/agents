# shellcheck shell=bash
# shellcheck disable=SC2016,SC2088  # fixture text holds literal $HOME / ~ reference strings
# tests/bin/feature-2431-run-tests-baseline/homeref.sh
# Tests: bin/lib/run-tests-baseline-homeref.sh
# Tags: run-tests, baseline, homeref, scope:issue-specific, pwsh-not-required, TL2
# Sourced by the dispatcher; never run standalone.
# Contract: rtb_has_home_ref <path...> returns 0 (reference, or undeterminable: fail-closed) or 1
# (no RTB_HOME_REFS pattern outside whole-line comments of the file's own language).

# isolation (#2512): re-pin to helpers.sh's private dirs (a sibling's pin is invisible to the scanner).
: "${WF_DIR:?helpers.sh must be sourced first}" "${PLANS_DIR:?helpers.sh must be sourced first}"
export WORKFLOW_STATE_DIR="$(np "$WF_DIR")" WORKFLOW_PLANS_DIR="$(np "$PLANS_DIR")"
declare -F harness_assert_isolated >/dev/null || . "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
harness_assert_isolated

# hr_mk <file> <line...> — a fixture file, one argument per line (parents created).
hr_mk() {
  local f="$1"; shift
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$@" > "$f"
}

# hr_expect <label> <want-rc> <path...> — homeref_call's rc must equal want.
hr_expect() {
  local label="$1" want="$2" got=0
  shift 2
  homeref_call "$@" >/dev/null 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then
    pass "$label"
  else
    fail "$label: expected rc=$want, got rc=$got"
  fi
}

run_homeref_unit_cases() {
  if [ ! -f "$HOMEREF_LIB" ]; then
    local id
    for id in U1 U2 U3 U4 U5 U6 U7 U8 U9 U10 U11 U12; do
      fail "$id: bin/lib/run-tests-baseline-homeref.sh not found (impl pending)"
    done
    return
  fi
  local R="$TMPROOT/homeref-unit" refs=() r n=0 d i
  # The expected pattern set, independent of the implementation (the contract's 7 literals).
  local exp=('$HOME/.claude' '${HOME}/.claude' '~/.claude' '$env:USERPROFILE' '$env:HOME' 'Path.home()' 'expanduser("~')

  # ---- U1: RTB_HOME_REFS is exactly the 7 contract literals; each behaves alike (exec line -> 0, comment-only -> 1) ----
  while IFS= read -r r; do
    [ -n "$r" ] && refs+=("$r")
  done < <(run_with_timeout 30 bash -c '. "$1" || exit 98; printf "%s\n" "${RTB_HOME_REFS[@]}"' x "$HOMEREF_LIB" 2>/dev/null)
  if [ "${#refs[@]}" -eq "${#exp[@]}" ]; then
    pass "U1: RTB_HOME_REFS has the ${#exp[@]} expected patterns"
  else
    fail "U1: expected ${#exp[@]} RTB_HOME_REFS patterns, got ${#refs[@]}"
  fi
  for i in "${!exp[@]}"; do
    if [ "${refs[$i]-}" = "${exp[$i]}" ]; then
      pass "U1: RTB_HOME_REFS[$i] is '${exp[$i]}'"
    else
      fail "U1: RTB_HOME_REFS[$i] expected '${exp[$i]}', got '${refs[$i]-}'"
    fi
  done
  for r in "${exp[@]}"; do
    n=$((n + 1))
    hr_mk "$R/u1/x$n.sh" '#!/usr/bin/env bash' "ls $r"
    hr_mk "$R/u1/y$n.sh" '#!/usr/bin/env bash' "# $r" 'exit 1'
    hr_expect "U1[$n]: exec line with '$r' -> 0" 0 "$R/u1/x$n.sh"
    hr_expect "U1[$n]: comment-only '$r' -> 1" 1 "$R/u1/y$n.sh"
  done

  # ---- U2: comment prefix comes from the file's own language (registry header.commentPrefix) ----
  hr_mk "$R/u2/a.sh" '# ~/.claude'
  hr_mk "$R/u2/t.Tests.ps1" '# $env:USERPROFILE'
  hr_mk "$R/u2/test_a.py" '# Path.home()'
  hr_mk "$R/u2/b.js" '// ~/.claude'
  hr_expect "U2: .sh '#' comment -> 1" 1 "$R/u2/a.sh"
  hr_expect "U2: .Tests.ps1 '#' comment -> 1" 1 "$R/u2/t.Tests.ps1"
  hr_expect "U2: test_*.py '#' comment -> 1" 1 "$R/u2/test_a.py"
  hr_expect "U2: .js '//' comment -> 1" 1 "$R/u2/b.js"

  # ---- U3: another language's prefix is not a comment ----
  hr_mk "$R/u3/b.js" '# ~/.claude'
  hr_mk "$R/u3/a.sh" '// ~/.claude'
  hr_mk "$R/u3/test_a.py" '// ~/.claude'
  hr_expect "U3: '#' line in .js is not a comment -> 0" 0 "$R/u3/b.js"
  hr_expect "U3: '//' line in .sh is not a comment -> 0" 0 "$R/u3/a.sh"
  hr_expect "U3: '//' line in test_*.py is not a comment -> 0" 0 "$R/u3/test_a.py"

  # ---- U4: leading spaces and tabs before the prefix are allowed ----
  hr_mk "$R/u4/sp.sh" '    # ~/.claude'
  hr_mk "$R/u4/tab.sh" "$(printf '\t# $HOME/.claude')"
  hr_mk "$R/u4/js.js" "$(printf ' \t // ~/.claude')"
  hr_expect "U4: spaces before '#' -> 1" 1 "$R/u4/sp.sh"
  hr_expect "U4: tab before '#' -> 1" 1 "$R/u4/tab.sh"
  hr_expect "U4: spaces+tab before '//' -> 1" 1 "$R/u4/js.js"

  # ---- U5: conservative: only whole-line comments are excluded ----
  hr_mk "$R/u5/eol.sh" 'ls x # ~/.claude'
  hr_mk "$R/u5/str.sh" 'echo "~/.claude"'
  hr_mk "$R/u5/heredoc.sh" "cat <<'EOF'" '~/.claude/settings' 'EOF'
  hr_mk "$R/u5/block.Tests.ps1" '<#' '  ~/.claude' '#>'
  hr_mk "$R/u5/test_doc.py" '"""' '~/.claude' '"""'
  hr_expect "U5: end-of-line comment is not excluded -> 0" 0 "$R/u5/eol.sh"
  hr_expect "U5: reference inside a string is not excluded -> 0" 0 "$R/u5/str.sh"
  hr_expect "U5: heredoc body line is not excluded -> 0" 0 "$R/u5/heredoc.sh"
  hr_expect "U5: block-comment body is not excluded -> 0" 0 "$R/u5/block.Tests.ps1"
  hr_expect "U5: docstring body is not excluded -> 0" 0 "$R/u5/test_doc.py"

  # ---- U6: comment reference plus an executable reference in one file -> 0 ----
  hr_mk "$R/u6/mixed.sh" '# ~/.claude is documented here' 'ls "$HOME/.claude"'
  hr_expect "U6: mixed comment + exec reference -> 0" 0 "$R/u6/mixed.sh"

  # ---- U7: data directory, recursion ----
  hr_mk "$R/u7/clean/a.sh" '# ~/.claude'
  hr_mk "$R/u7/clean/sub/b.sh" '  # $HOME/.claude'
  hr_mk "$R/u7/dirty/a.sh" '# ~/.claude'
  hr_mk "$R/u7/dirty/sub/deep/c.sh" 'ls ~/.claude'
  hr_mk "$R/u7/body.sh" '# ~/.claude'
  hr_expect "U7: dir with comment-only files (nested) -> 1" 1 "$R/u7/clean"
  hr_expect "U7: dir with one nested exec reference -> 0" 0 "$R/u7/dirty"
  hr_expect "U7: comment-only body file + clean dir -> 1" 1 "$R/u7/body.sh" "$R/u7/clean"
  hr_expect "U7: comment-only body file + dirty dir -> 0" 0 "$R/u7/body.sh" "$R/u7/dirty"
  # a file name with a space and shell metacharacters must be handled exactly, not word-split
  hr_mk "$R/u7/odd-exec/a b\$c;d.sh" 'ls ~/.claude'
  hr_mk "$R/u7/odd-comment/a b\$c;d.sh" '# ~/.claude'
  hr_expect "U7: odd-named file with an exec reference (dir) -> 0" 0 "$R/u7/odd-exec"
  hr_expect "U7: odd-named file with a comment-only reference (dir) -> 1" 1 "$R/u7/odd-comment"
  hr_expect "U7: odd-named file with an exec reference (direct) -> 0" 0 "$R/u7/odd-exec/a b\$c;d.sh"
  hr_expect "U7: odd-named file with a comment-only reference (direct) -> 1" 1 "$R/u7/odd-comment/a b\$c;d.sh"

  # ---- U8: unregistered extension / null-header entry gets no comment exclusion (D1) ----
  hr_mk "$R/u8/n.txt" '# ~/.claude'
  hr_mk "$R/u8/n.json" '# ~/.claude'
  hr_mk "$R/u8/test_data.txt" '# ~/.claude'
  hr_mk "$R/u8/ok.txt" 'nothing to see'
  hr_expect "U8: .txt '#' line is not excluded -> 0" 0 "$R/u8/n.txt"
  hr_expect "U8: .json '#' line is not excluded -> 0" 0 "$R/u8/n.json"
  hr_expect "U8: null-header entry (test_*) '#' line is not excluded -> 0" 0 "$R/u8/test_data.txt"
  hr_expect "U8 control: unregistered file without references -> 1" 1 "$R/u8/ok.txt"

  # ---- U9: failures are fail-closed (rc 0) ----
  hr_expect "U9a: nonexistent path -> 0" 0 "$R/u9/does-not-exist"
  mkdir -p "$R/u9/empty"
  hr_expect "U9b: only an empty directory (zero targets) -> 0" 0 "$R/u9/empty"
  hr_mk "$R/u9/c.sh" '# ~/.claude'
  d="$R/u9-stub-awk"
  mkdir -p "$d"
  # shellcheck disable=SC2016  # the stub's own text
  printf '%s\n' '#!/usr/bin/env bash' "echo called >> \"$d/awk.log\"" 'exit 3' > "$d/awk"
  chmod +x "$d/awk"
  hr_expect "U9c control: comment-only file without the stub -> 1" 1 "$R/u9/c.sh"
  HOMEREF_PATH_PREFIX="$d" hr_expect "U9c: awk exits 3 on a comment-only file -> 0" 0 "$R/u9/c.sh"
  if [ -s "$d/awk.log" ]; then
    pass "U9c: the awk stub was actually reached"
  else
    fail "U9c: the awk stub was never invoked (the 0 above proves nothing)"
  fi
  local rc_d=0
  run_with_timeout 30 bash -c '. "$1" || exit 98; shift; rtb_has_home_ref "$@"' x "$HOMEREF_LIB" "$R/u9/c.sh" >/dev/null 2>&1 || rc_d=$?
  if [ "$rc_d" -eq 0 ]; then
    pass "U9d: registry not loaded (tlr_match undefined) -> 0"
  else
    fail "U9d: expected rc=0 without the registry, got $rc_d"
  fi

  # ---- U10: negative control: no reference at all -> 1 ----
  hr_mk "$R/u10/none.sh" '#!/usr/bin/env bash' 'echo hello' 'exit 1'
  hr_mk "$R/u10/dir/x.sh" 'echo hello'
  hr_expect "U10: file without references -> 1" 1 "$R/u10/none.sh"
  hr_expect "U10: directory without references -> 1" 1 "$R/u10/dir"

  # ---- U11: find fails after listing only part of the tree -> fail-closed ----
  hr_mk "$R/u11/d/ok.sh" '# ~/.claude'
  hr_mk "$R/u11/d/bad.sh" 'ls "$HOME/.claude"'
  local fa="$R/u11-stub-fail" fo="$R/u11-stub-ok"
  mkdir -p "$fa" "$fo"
  # shellcheck disable=SC2016  # the stub's own text
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$1/ok.sh"' 'exit 1' > "$fa/find"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$1/ok.sh"' 'exit 0' > "$fo/find"
  chmod +x "$fa/find" "$fo/find"
  HOMEREF_PATH_PREFIX="$fa" hr_expect "U11a: find lists ok.sh then exits 1 -> 0 (partial listing discarded)" 0 "$R/u11/d"
  HOMEREF_PATH_PREFIX="$fo" hr_expect "U11b control: same listing with find exit 0 -> 1 (stub is in effect)" 1 "$R/u11/d"

  # ---- U12: a listed but unreadable file cannot be decided -> fail-closed (rc 0) ----
  hr_mk "$R/u12/f.sh" '# ~/.claude'
  hr_mk "$R/u12/d/f.sh" '# ~/.claude'
  hr_expect "U12 control: readable comment-only file -> 1" 1 "$R/u12/f.sh"
  chmod 000 "$R/u12/f.sh" "$R/u12/d/f.sh" 2>/dev/null
  if cat "$R/u12/f.sh" >/dev/null 2>&1; then
    pass "U12: SKIP - chmod 000 does not block reads here (root or no POSIX permissions)"
  else
    hr_expect "U12a: unreadable comment-only file -> 0" 0 "$R/u12/f.sh"
    hr_expect "U12b: unreadable comment-only file inside a directory -> 0" 0 "$R/u12/d"
  fi
  chmod 644 "$R/u12/f.sh" "$R/u12/d/f.sh" 2>/dev/null
}
