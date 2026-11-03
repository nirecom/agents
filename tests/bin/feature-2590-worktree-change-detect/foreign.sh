#!/usr/bin/env bash
# tests/bin/feature-2590-worktree-change-detect/foreign.sh — sourced after setup.sh: the #2803 cases.
# Foreign (never a hit): $common/config (kind=config) and the head of a tree other than this
# checkout. $gitdir/config.worktree (kind=config-worktree) stays a hit. rtb_exec_one judges the same.
# Design: the "#2803 design" section of the #2688 detail plan, docs/architecture/claude-code/test-command-guard.md

# Fixture tests are pure bash with baked paths: under rtb_exec_one the command guard refuses git writes.
# fg_flip_ref <name> <ref file> <oid a> <oid b> — toggles the ref between two commits of one tree.
fg_flip_ref() {
  printf '%s\n' "ref='$2'" 'read -r cur <"$ref"' \
    "if [ \"\$cur\" = '$3' ]; then printf '%s\n' '$4' >\"\$ref\"; else printf '%s\n' '$3' >\"\$ref\"; fi" \
    'exit 0' >"$FG_TESTS/$1"
}

# fg_setup — "fg main" and its linked worktree "fg linked" (the checkout the launcher is loaded
# from), plus one fixture test per kind under fg linked/tests/bin.
fg_setup() {
  local main_head linked_head main_ref linked_ref c1 c2 linked_gitdir
  FG_MAIN="$TMP_ROOT/fg main"
  FG_LINKED="$TMP_ROOT/fg linked"
  wcd_checkout "$FG_MAIN" || return 1
  git -C "$FG_MAIN" worktree add -q -b fg-linked "$FG_LINKED" || return 1
  FG_TESTS="$FG_LINKED/tests/bin"
  mkdir -p "$FG_TESTS" || return 1
  main_ref="$FG_MAIN/.git/$(git -C "$FG_MAIN" symbolic-ref HEAD)" || return 1
  linked_ref="$FG_MAIN/.git/refs/heads/fg-linked"
  [ -f "$main_ref" ] && [ -f "$linked_ref" ] || return 1
  main_head="$(git -C "$FG_MAIN" rev-parse HEAD)" || return 1
  linked_head="$(git -C "$FG_LINKED" rev-parse HEAD)" || return 1
  c1="$(git -C "$FG_MAIN" -c user.name=t -c user.email=t@example.invalid commit-tree "HEAD^{tree}" -p HEAD -m fg-main)" || return 1
  c2="$(git -C "$FG_LINKED" -c user.name=t -c user.email=t@example.invalid commit-tree "HEAD^{tree}" -p HEAD -m fg-linked)" || return 1
  linked_gitdir="$(git -C "$FG_LINKED" rev-parse --path-format=absolute --git-dir)" || return 1
  linked_gitdir="${linked_gitdir%$'\r'}"
  # kind=config: the common config every checkout shares.
  printf '%s\n' "printf '[fg]\\n\\tn = %s\\n' \"\$RANDOM\" >>'$FG_MAIN/.git/config'" 'exit 0' >"$FG_TESTS/fg-config.sh"
  # kind=config-worktree: this checkout's own config.worktree.
  printf '%s\n' "printf '[fg]\\n\\tn = %s\\n' \"\$RANDOM\" >>'$linked_gitdir/config.worktree'" 'exit 0' >"$FG_TESTS/fg-config-worktree.sh"
  fg_flip_ref fg-head-main.sh "$main_ref" "$main_head" "$c1"
  fg_flip_ref fg-head-self.sh "$linked_ref" "$linked_head" "$c2"
  # Toggles clean.txt between the committed text and a modified one (CRLF checkouts included).
  printf '%s\n' "f='$FG_LINKED/clean.txt'" 'c="$(<"$f")"' \
    "case \"\$c\" in *more*) printf 'clean\\n' >\"\$f\" ;; *) printf 'clean\\nmore\\n' >\"\$f\" ;; esac" \
    'exit 0' >"$FG_TESTS/fg-tracked.sh"
  wcd_exec_driver
}

wcd_exec_driver() {
  cat >"$TMP_ROOT/exec-driver.sh" <<'DRIVER'
# exec-driver.sh <wt> <rel> <logdir> — one base-side run through rtb_exec_one, then its stderr log.
wt="$1"; rel="$2"; logdir="$3"
cd "$wt" || exit 89
. "$wt/bin/lib/run-tests-baseline-exec.sh" || exit 90
rtb_exec_one "$wt" "$rel" 60 "$logdir"
echo "RET=$?"
echo "RC=${RTB_EXEC_RC:-unset}"
echo "DECOY=${RTB_EXEC_DECOY:-unset}"
cat "$logdir/1.err" 2>/dev/null
exit 0
DRIVER
}

# drive_exec <logdir> <fixture test name> — the exec driver in the same clean child as drive.
drive_exec() {
  (env -u TEST_RUN_ROOT -u COMMAND_GUARD_DIR -u ROOT_DECOY_DIR -u ROOT_DECOY_TEST_ID -u RUN_ALL_CACHE_DIR \
    HOME="$FHOME" USERPROFILE="$FHOME" TEST_HOST_TMPDIR="$TMP_ROOT/host tmp" RUN_TL3=off RUN_TL4=off RUN_ALL_PROGRESS=off \
    AGENTS_MAIN_ROOT="$TMP_ROOT/pretend real" bash "$RWT" 120 bash "$TMP_ROOT/exec-driver.sh" "$FG_LINKED" "tests/bin/$2" "$1" 2>&1)
}

# fg_detect_case — the detect-mode run from the linked checkout, one fixture per kind.
fg_detect_case() {
  local log="$TMP_ROOT/fg-detect.log" out
  out="$(drive "$FG_LINKED" detect "$log" "$FG_TESTS/fg-config.sh" "$FG_TESTS/fg-head-main.sh" \
    "$FG_TESTS/fg-config-worktree.sh" "$FG_TESTS/fg-head-self.sh" "$FG_TESTS/fg-tracked.sh")"
  expect_eq "foreign: every fixture test ran" "$(printf '%s\n' "$out" | grep -c '^EXEC:fg-.*=0$' || true)" "5"
  expect_eq "foreign: the common config change is no hit on the linked checkout" "$(changes "$out" "fg linked" fg-config.sh config)" "0"
  expect_eq "foreign: the common config change is no hit on the main worktree" "$(changes "$out" "fg main" fg-config.sh config)" "0"
  expect_ne "foreign: the common config change is a foreign line" "$(foreign_lines "$out" "fg linked" config)$(foreign_lines "$out" "fg main" config)" "00"
  expect_eq "foreign: the main worktree's moved head is no hit" "$(changes "$out" "fg main" fg-head-main.sh head)" "0"
  expect_eq "foreign: the main worktree's moved head is a foreign line" "$(foreign_lines "$out" "fg main" head)" "1"
  expect_eq "hit: this checkout's config.worktree change is a hit" "$(changes "$out" "fg linked" fg-config-worktree.sh config-worktree)" "1"
  expect_eq "hit: the config.worktree change is not reported as kind=config" "$(changes "$out" "fg linked" fg-config-worktree.sh config)" "0"
  expect_eq "hit: this checkout's moved head is a hit" "$(changes "$out" "fg linked" fg-head-self.sh head)" "1"
  expect_eq "hit: this checkout's tracked change is a hit" "$(changes "$out" "fg linked" fg-tracked.sh tracked)" "1"
  expect_eq "hit: no own change is called foreign" "$(foreign_lines "$out" "fg linked" config-worktree)$(foreign_lines "$out" "fg linked" head)" "00"
  expect_eq "log: the hit log holds no config line" "$(log_kinds "$log" | grep -cx 'config' || true)" "0"
  expect_eq "log: the hit log holds exactly the three own changes" "$(log_kinds "$log" | sort | tr '\n' ' ')" "config-worktree head tracked "
  expect_eq "log: the foreign changes go to <log>.foreign" "$([ -s "$log.foreign" ] && echo written)" "written"
  expect_has "log: <log>.foreign names the common config change" "$(cat "$log.foreign" 2>/dev/null)" "fg-config.sh"
  expect_has "log: <log>.foreign names the main worktree's head" "$(cat "$log.foreign" 2>/dev/null)" "fg-head-main.sh"
  expect_eq "log: <log>.foreign holds no own change" "$(grep -c -e 'fg-config-worktree.sh' -e 'fg-head-self.sh' -e 'fg-tracked.sh' "$log.foreign" 2>/dev/null || true)" "0"
}

# fg_only_foreign_case — a run whose only changes are foreign reports nothing and returns 0.
fg_only_foreign_case() {
  local log="$TMP_ROOT/fg-only.log" out
  out="$(drive "$FG_LINKED" detect "$log" "$FG_TESTS/fg-config.sh" "$FG_TESTS/fg-head-main.sh")"
  expect_eq "only foreign: no worktree change line" "$(change_lines "$out")" "0"
  expect_eq "only foreign: the report returns 0" "$(field "$out" REPORT_RC)" "0"
  expect_eq "only foreign: the hit log is empty" "$([ -s "$log" ] && echo nonempty || echo empty)" "empty"
  expect_has "only foreign: the change is still shown on stderr" "$out" "(foreign, not a hit)"
}

# fg_exec <label> <fixture> — sets FGX_OUT and FGX_LOG (the logdir) for one base-side run.
FG_EXEC_N=0
fg_exec() {
  FG_EXEC_N=$((FG_EXEC_N + 1))
  FGX_LOG="$TMP_ROOT/fg exec $FG_EXEC_N $1"
  mkdir -p "$FGX_LOG"
  FGX_OUT="$(drive_exec "$FGX_LOG" "$2")"
}

# fg_base_case — the same judgement on the base side (rtb_exec_one), CPR-ORTH.
fg_base_case() {
  fg_exec config fg-config.sh
  expect_eq "base: the common config run launched" "$(field "$FGX_OUT" RET)" "0"
  expect_eq "base: the common config change is no hit (DECOY=0)" "$(field "$FGX_OUT" DECOY)" "0"
  expect_eq "base: the passing test keeps rc 0" "$(field "$FGX_OUT" RC)" "0"
  expect_ne "base: the common config change is a foreign line" "$(foreign_lines "$FGX_OUT" "fg linked" config)$(foreign_lines "$FGX_OUT" "fg main" config)" "00"
  expect_eq "base: the hit log holds no config line" "$(log_kinds "$FGX_LOG/1.worktree-change" | grep -cx config || true)" "0"
  expect_eq "base: the change goes to the .foreign log" "$([ -s "$FGX_LOG/1.worktree-change.foreign" ] && echo written)" "written"

  fg_exec head-main fg-head-main.sh
  expect_eq "base: the main worktree's moved head is no hit (DECOY=0)" "$(field "$FGX_OUT" DECOY)" "0"
  expect_eq "base: the main worktree's moved head is a foreign line" "$(foreign_lines "$FGX_OUT" "fg main" head)" "1"

  fg_exec config-worktree fg-config-worktree.sh
  expect_eq "base: this checkout's config.worktree change is a hit (DECOY=1)" "$(field "$FGX_OUT" DECOY)" "1"
  expect_eq "base: the hit makes the passing test rc 1" "$(field "$FGX_OUT" RC)" "1"
  expect_eq "base: it is logged as kind=config-worktree" "$(log_kinds "$FGX_LOG/1.worktree-change" | tr '\n' ' ')" "config-worktree "

  fg_exec head-self fg-head-self.sh
  expect_eq "base: this checkout's moved head is a hit (DECOY=1)" "$(field "$FGX_OUT" DECOY)" "1"

  fg_exec tracked fg-tracked.sh
  expect_eq "base: this checkout's tracked change is a hit (DECOY=1)" "$(field "$FGX_OUT" DECOY)" "1"
  # If clean.txt was already dirty from a previous run, it becomes kind=content. Either way it is a HIT on the own checkout.
  expect_eq "base: it is logged as an own kind (tracked or content)" \
    "$(log_kinds "$FGX_LOG/1.worktree-change" | tr '\n' ' ' | sed -E 's/^(tracked|content) $/own/')" "own"
}
