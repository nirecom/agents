#!/usr/bin/env bash
# Tests: tests/lib/command-guard.sh, tests/lib/command-guard-build.js, tests/lib/command-guard/main.js
# Tags: scope:issue-specific, tl2, command-guard, fixture-isolation
#
# The command guard (#2590) fails closed: a guard whose settings are gone, half-written or point at
# a missing node still refuses a git write (exit 97 + one hit) and never lets it through. Each case
# runs on a private copy of the fixture guard, so breaking guard.conf never touches the shared one.
# Fixtures and setup: feature-2590-command-guard/setup.sh (cg_setup).

# TL3 gap: the Windows launcher and the POSIX bash stub fail closed through different code
# (launcher.cs Hit vs the bin script); only the one native to this host runs here.
# TL3 gap: a guard whose own bin is read-only (hit file cannot be written) is not simulated.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/state"
unset CLAUDE_CODE_SESSION_ID

. "$SCRIPT_CHECKOUT_ROOT/tests/tests/feature-2590-command-guard/setup.sh"

MAIN_JS="$(np "$SCRIPT_CHECKOUT_ROOT/tests/lib/command-guard/main.js")"
readonly MAIN_JS

# cgf_clone <name> — a private copy of the fixture guard with no hits; sets CGI.
cgf_clone() {
  CGI="$TMP_ROOT/inst-$1"
  rm -rf "$CGI"
  cp -R "$GDIR" "$CGI" || return 1
  rm -rf "$CGI/hits"
  mkdir -p "$CGI/hits"
}

cgf_hits() { find "$CGI/hits" -type f -name '*.hit' 2>/dev/null | wc -l | tr -d ' '; }

# cgf_conf_without <key> — guard.conf of CGI minus every <key>= line.
cgf_conf_without() {
  grep -v "^$1=" "$CGI/guard.conf" >"$CGI/guard.conf.new"
  mv "$CGI/guard.conf.new" "$CGI/guard.conf"
}

# cgf_run <tool> <args...> — the CGI stub run from the fixture run root; sets RC and ERR_TEXT.
cgf_run() {
  local tool="$1"
  shift
  RC=0
  (cd "$RR" && PATH="$SAFE_PATH" ROOT_DECOY_TEST_ID="$CG_TID" HOME="$FHOME" USERPROFILE="$FHOME" \
    bash "$RWT" 60 "$CGI/bin/$tool$CG_EXE" "$@") >"$TMP_ROOT/cgf.out" 2>"$TMP_ROOT/cgf.err" || RC=$?
  ERR_TEXT="$(cat "$TMP_ROOT/cgf.err")"
}

# cgf_main <tool> <args...> — main.js called directly on CGI; sets RC and ERR_TEXT.
cgf_main() {
  RC=0
  (cd "$RR" && PATH="$SAFE_PATH" ROOT_DECOY_TEST_ID="$CG_TID" HOME="$FHOME" USERPROFILE="$FHOME" \
    bash "$RWT" 60 node "$MAIN_JS" "$(np "$CGI")" "$@") >"$TMP_ROOT/cgf.out" 2>"$TMP_ROOT/cgf.err" || RC=$?
  ERR_TEXT="$(cat "$TMP_ROOT/cgf.err")"
}

cg_setup || { echo "FAIL: fixture setup"; exit 1; }

case_begin "guard-conf-deleted-fails-closed" "tests/lib/command-guard.sh"
if cg_require "guard conf deleted" && cgf_clone a1; then
  rm -f "$CGI/guard.conf"
  cgf_run git push origin main
  expect_eq "A1 stub: exits 97" "$RC" "97"
  expect_eq "A1 stub: one hit" "$(cgf_hits)" "1"
  expect_has "A1 stub: says it refused" "$ERR_TEXT" "command guard"
  expect_eq "A1 stub: the git write did not run" "$([[ -e "$RR/origin" ]] && echo ran)" ""
  cgf_clone a1m
  rm -f "$CGI/guard.conf"
  cgf_main git push origin main
  expect_eq "A1 main.js: exits 97" "$RC" "97"
  expect_eq "A1 main.js: one hit" "$(cgf_hits)" "1"
  expect_has "A1 main.js: names guard.conf unreadable" "$ERR_TEXT" "guard.conf unreadable"
fi
case_end

case_begin "guard-conf-without-realgit-fails-closed" "tests/lib/command-guard/main.js"
if cg_require "guard conf without realgit" && cgf_clone a2; then
  cgf_conf_without realgit
  cgf_run git push origin main
  expect_eq "A2 stub: exits 97" "$RC" "97"
  expect_eq "A2 stub: one hit" "$(cgf_hits)" "1"
  expect_has "A2 stub: names guard.conf" "$ERR_TEXT" "guard.conf"
  cgf_clone a2m
  cgf_conf_without realgit
  cgf_main git status
  expect_eq "A2 main.js: exits 97 even for a read" "$RC" "97"
  expect_eq "A2 main.js: one hit" "$(cgf_hits)" "1"
  expect_has "A2 main.js: says no realgit" "$ERR_TEXT" "guard.conf has no realgit"
fi
case_end

case_begin "node-unavailable-fails-closed" "tests/lib/command-guard-build.js"
if cg_require "node unavailable" && cgf_clone a3; then
  # guard.conf names a node that does not exist: the bash stub's [[ ! -x node ]] branch, or on
  # Windows the launcher's cannot-start branch. Either way a hit and exit 97.
  sed "s|^node=.*|node=$TMP_ROOT/no-such-dir/node|" "$CGI/guard.conf" >"$CGI/guard.conf.new"
  mv "$CGI/guard.conf.new" "$CGI/guard.conf"
  cgf_run git push origin main
  expect_eq "A3: exits 97" "$RC" "97"
  expect_eq "A3: one hit" "$(cgf_hits)" "1"
  expect_has "A3: says it refused" "$ERR_TEXT" "command guard: refused git"
  hit="$(cat "$(ls "$CGI/hits"/*.hit | head -n 1)" 2>/dev/null)"
  expect_eq "A3: hit names git" "$(field "$hit" stub)" "git"
  expect_eq "A3: hit carries the test id" "$(field "$hit" test_id)" "$CG_TID"
  cgf_clone a3b
  cgf_conf_without node
  cgf_run gh api repos/x/y
  expect_eq "A3 no node= line, gh: exits 97" "$RC" "97"
  expect_eq "A3 no node= line, gh: one hit" "$(cgf_hits)" "1"
fi
case_end

case_begin "unknown-tool-fails-closed" "tests/lib/command-guard/main.js"
if cg_require "unknown tool" && cgf_clone a4; then
  cgf_main docker status
  expect_eq "A4: exits 97" "$RC" "97"
  expect_eq "A4: one hit" "$(cgf_hits)" "1"
  expect_has "A4: says unknown tool" "$ERR_TEXT" "unknown tool"
  hit="$(cat "$(ls "$CGI/hits"/*.hit | head -n 1)" 2>/dev/null)"
  expect_eq "A4: hit names the tool" "$(field "$hit" stub)" "docker"
  cgf_clone a4e
  cgf_main ""
  expect_eq "A4 empty tool: exits 97" "$RC" "97"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
