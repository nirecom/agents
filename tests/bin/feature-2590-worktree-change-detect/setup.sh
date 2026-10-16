#!/usr/bin/env bash
# tests/bin/feature-2590-worktree-change-detect/setup.sh — sourced by
# tests/bin/feature-2590-worktree-change-detect.sh: the fixture checkout, the fixture tests and
# the driver. Functions only.
#
# The launcher protects the checkout it is loaded from, so it is loaded from a copy of the
# launcher libraries committed into a fixture repo ("main checkout") and from a linked worktree
# of it ("linked checkout"). The real checkout is never a protected tree here.

expect_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=$3 got=$2"; fi; }
expect_ne() { if [[ "$2" != "$3" ]]; then pass "$1"; else fail "$1" "both sides are $2"; fi; }
expect_has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing: $3 in: $2" ;; esac; }
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }
nlow() { [[ -n "$1" ]] || return 0; np "$1" | tr 'A-Z\\' 'a-z/'; }

# changes <report> <tree basename> <fixture test> <kind> — how many report lines name that
# tree, that test and that kind ("[run-all] worktree change: <tree>\t<test id>\t<kind>", with or
# without a trailing "\t<paths>" field, #2669).
changes() {
  local line n=0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "$line" in
      "[run-all] worktree change: "*"/$2$TAB"*"$3"*"$TAB$4"|"[run-all] worktree change: "*"/$2$TAB"*"$3"*"$TAB$4$TAB"*) n=$((n + 1)) ;;
    esac
  done <<<"$1"
  printf '%s' "$n"
}
change_lines() { printf '%s\n' "$1" | grep -c '^\[run-all\] worktree change: ' || true; }

# wcd_checkout <dir> — a committed copy of what the launcher needs, plus three data files.
wcd_checkout() {
  local d="$1"
  mkdir -p "$d/bin" "$d/hooks/lib" "$d/tests/bin" || return 1
  cp -R "$ROOT_N/bin/lib" "$d/bin/" || return 1
  cp "$ROOT_N/bin/run-with-timeout.sh" "$ROOT_N/bin/test-language-registry" "$ROOT_N/bin/get-config-var" "$d/bin/" || return 1
  cp "$ROOT_N"/hooks/lib/test-language-registry.* "$ROOT_N/hooks/lib/load-env.js" "$d/hooks/lib/" || return 1
  cp -R "$ROOT_N/hooks/lib/test-language-registry" "$d/hooks/lib/" || return 1
  cp -R "$ROOT_N/tests/lib" "$d/tests/" || return 1
  cp "$ROOT_N/tests/bin/feature-2561-root-names-residue.sh" "$d/tests/bin/" || return 1
  printf 'clean\n' >"$d/clean.txt"
  printf 'dirty 0\n' >"$d/dirty.txt"
  printf 'staged 0\n' >"$d/staged.txt"
  harness_git_init "$d" || return 1
  git -C "$d" -c core.autocrlf=false add -A || return 1
  git -C "$d" -c user.name=t -c user.email=t@example.invalid commit -q -m base || return 1
}

# wcd_predirty <dir> — uncommitted changes that exist before any test runs: a modified file and
# a file whose index and worktree both differ from HEAD.
wcd_predirty() {
  printf 'dirty 1\n' >"$1/dirty.txt"
  printf 'staged A\n' >"$1/staged.txt"
  git -C "$1" -c core.autocrlf=false add staged.txt
  printf 'staged W\n' >"$1/staged.txt"
}

# One fixture test per change kind; FX_TREE names the tree it changes. "tracked" flips clean.txt
# between clean and modified, so every run changes the set of changed tracked files. "head"
# moves HEAD to a new commit of the same tree, leaving the index and the status lines alone.
wcd_fixtures() {
  local flip='if git -C "$FX_TREE" diff --quiet -- clean.txt; then printf "more\n" >>"$FX_TREE/clean.txt"; else git -C "$FX_TREE" checkout -q -- clean.txt; fi'
  local move='c=$(git -C "$FX_TREE" -c user.name=t -c user.email=t@example.invalid commit-tree "HEAD^{tree}" -p HEAD -m moved) && git -C "$FX_TREE" update-ref HEAD "$c"'
  mkdir -p "$FX"
  printf '%s\n' 'exit 0' >"$FX/noop.sh"
  printf '%s\n' "$flip" >"$FX/tracked.sh"
  printf '%s\n' 'printf "dirty 2\n" >"$FX_TREE/dirty.txt"' >"$FX/content.sh"
  printf '%s\n' "$move" >"$FX/head.sh"
  # Same status letters before and after: only the staged object changes.
  printf '%s\n' 'printf "staged B\n" >"$FX_TREE/staged.txt"' 'git -C "$FX_TREE" add staged.txt' \
    'printf "staged W\n" >"$FX_TREE/staged.txt"' >"$FX/index.sh"
  printf '%s\n' 'git -C "$FX_TREE" config core.hooksPath "$FX_TREE/.git/hooks-elsewhere"' >"$FX/config.sh"
  printf '%s\n' 'sleep 5' >"$FX/slow.sh"
  printf '%s\n' 'sleep 2' "$move" >"$FX/mutator.sh"
  # The combined report: a git write outside the run root (the guard refuses it), plus a
  # tracked change made without git.
  printf '%s\n' 'git -C "$FX_TREE" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m guarded' \
    'if [ -n "$(cat "$FX_TREE/clean.txt" | sed -n 2p)" ]; then printf "clean\n" >"$FX_TREE/clean.txt"; else printf "late\n" >>"$FX_TREE/clean.txt"; fi' \
    'exit 0' >"$FX/reporter.sh"
}

wcd_driver() {
  cat >"$TMP_ROOT/driver.sh" <<'DRIVER'
# driver.sh <checkout> <mode> <log> [fixture tests...]
co="$1"; mode="$2"; log="$3"; shift 3
cd "$co" || exit 89
source "$co/bin/lib/run-all-launch.sh" || exit 90
for fn in run_all_pin_worktree_change_detect run_all_worktree_fingerprint run_all_worktree_change_check run_all_worktree_change_report run_all_hit_report run_all_pin_command_guard; do
  declare -F "$fn" >/dev/null 2>&1 || echo "MISSING:$fn"
done
if [[ "$mode" == full ]]; then
  run_all_pin_test_env "$log" || { echo "PIN_RC=$?"; exit 92; }
  printf 'RUN_ROOT=%s\nGUARD=%s\nTMPDIR=%s\nPATH1=%s\n' "${TEST_RUN_ROOT:-}" "${COMMAND_GUARD_DIR:-}" "${TMPDIR:-}" "${PATH%%:*}"
  mkdir -p "$ROOT_DECOY_DIR/main/hits" && printf 'stub=decoy/own.js\ntest_id=%s:tests/x.sh\n' "$_RUN_ALL_DECOY_RUN" >"$ROOT_DECOY_DIR/main/hits/wcd.hit"
else
  declare -F run_all_pin_worktree_change_detect >/dev/null 2>&1 || exit 91
  run_all_pin_worktree_change_detect "$log" || { echo "PIN_RC=$?"; exit 92; }
fi
if [[ "$mode" == overlap ]]; then
  run_all_exec "$1" "$1.out" "$1.err" & first=$!
  run_all_exec "$2" "$2.out" "$2.err" & second=$!
  wait "$first"; wait "$second"
else
  # full mode replays each test's stderr: a hit the launcher claimed for the test is named there (#2669).
  for t in "$@"; do run_all_exec "$t" "$t.out" "$t.err"; echo "EXEC:${t##*/}=$?"; [[ "$mode" == full ]] && cat "$t.err" >&2; done
fi
if [[ "$mode" == full ]]; then run_all_hit_report; else run_all_worktree_change_report; fi
echo "REPORT_RC=$?"
DRIVER
}

# drive <checkout> <mode> <log> <fixture tests...> — a clean child with the fixture home, no
# inherited run root, guard or decoy; FX_TREE is the tree the fixture tests change.
drive() {
  (env -u TEST_RUN_ROOT -u COMMAND_GUARD_DIR -u ROOT_DECOY_DIR -u ROOT_DECOY_TEST_ID -u RUN_ALL_CACHE_DIR \
    HOME="$FHOME" USERPROFILE="$FHOME" TEST_HOST_TMPDIR="$TMP_ROOT/host tmp" RUN_TL3=off RUN_TL4=off RUN_ALL_PROGRESS=off \
    AGENTS_MAIN_ROOT="$TMP_ROOT/pretend real" FX_TREE="$FX_TREE" bash "$RWT" 120 bash "$TMP_ROOT/driver.sh" "$@" 2>&1)
}

wcd_setup() {
  FX="$TMP_ROOT/fixture tests"
  FHOME="$TMP_ROOT/home"
  MAIN_CO="$TMP_ROOT/main checkout"
  LINKED_CO="$TMP_ROOT/linked checkout"
  mkdir -p "$FHOME" "$TMP_ROOT/host tmp" "$TMP_ROOT/pretend real" || return 1
  wcd_checkout "$MAIN_CO" || return 1
  git -C "$MAIN_CO" worktree add -q -b linked "$LINKED_CO" || return 1
  wcd_predirty "$MAIN_CO"
  wcd_fixtures
  wcd_driver
}
