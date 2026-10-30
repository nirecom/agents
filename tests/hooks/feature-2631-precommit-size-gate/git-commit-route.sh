#!/usr/bin/env bash
# tests/hooks/feature-2631-precommit-size-gate/git-commit-route.sh — the real `git commit` and the
# shell-metacharacter path bodies of tests/hooks/feature-2631-precommit-size-gate.sh (the case markers
# stay in the entry file). Sourced by lane.sh after fixture.sh (new_cfg, stage, run_pc, expect_*).

# gc_commit <cfg> <msg> — a real `git commit` in <cfg> whose core.hooksPath is the install's hooks/
# (what the installer sets); git, not the test, runs hooks/pre-commit. Sets RC / OUT / ERR.
gc_commit() {
  local hp="$1/hooks"
  if command -v cygpath >/dev/null 2>&1; then hp="$(cygpath -m "$hp")"; fi
  RC=0
  OUT="$(cd "$1" && run_with_timeout 60 env -u CLAUDE_CODE_SESSION_ID AGENTS_MAIN_ROOT="$1" ENFORCE_WORKTREE=off git -c core.hooksPath="$hp" commit -q -m "$2" 2>"$TMP_ROOT/gc.err")" || RC=$?
  ERR="$(cat "$TMP_ROOT/gc.err" 2>/dev/null || true)"
}

gc_case_git_commit_invokes_the_gate() {
  local cfg base
  cfg="$(new_cfg)"
  base="$(git -C "$cfg" rev-parse HEAD)"
  stage "$cfg" src/new.js 501
  gc_commit "$cfg" "over hard"
  expect_block "git commit of a new 501-line src/new.js is rejected with the size verdict" src/new.js
  if [ "$(git -C "$cfg" rev-parse HEAD)" = "$base" ]; then pass "the rejected git commit leaves HEAD unmoved"
  else fail "the rejected git commit leaves HEAD unmoved" "HEAD moved past $base"; fi
  git -C "$cfg" reset -q --hard "$base"
  cfg="$(new_cfg)"
  stage "$cfg" src/small.js 10
  gc_commit "$cfg" "under limit"
  expect_pass "git commit of a 10-line src/small.js goes through the same hooks"
  # The fixture .env makes hooks/pre-commit print this notice; seeing it proves git ran the hook.
  if printf '%s\n' "$ERR" | grep -q 'COMMENT_BLOCK_ENFORCE=off'; then pass "premise: git itself ran the install's hooks/pre-commit"
  else fail "premise: git itself ran the install's hooks/pre-commit" "err=$ERR"; fi
  if [ "$(git -C "$cfg" rev-parse HEAD)" != "$base" ]; then pass "the under-limit git commit moves HEAD"
  else fail "the under-limit git commit moves HEAD" "rc=$RC out=$OUT err=$ERR"; fi
  # The later cases rely on HEAD being the fixture's init commit.
  git -C "$cfg" reset -q --hard "$base"
}

# gc_stage_then_put <cfg> <path> <staged-n> <worktree-n> — stage one size, leave another in the worktree.
gc_stage_then_put() {
  stage "$1" "$2" "$3" idx
  make_lines "$4" wt > "$1/$2"
}

# The gate judges the staged blob: the index and the worktree disagree on the verdict.
gc_case_staged_size_beats_worktree_size() {
  local cfg base
  cfg="$(new_cfg)"
  base="$(git -C "$cfg" rev-parse HEAD)"
  gc_stage_then_put "$cfg" src/new.js 10 501
  gc_commit "$cfg" "staged under, worktree over"
  if [ "$RC" = 0 ]; then pass "staged 10 lines, worktree 501: the git commit is allowed (rc 0)"
  else fail "staged 10 lines, worktree 501: the git commit is allowed (rc 0)" "rc=$RC out=$OUT err=$ERR"; fi
  if printf '%s\n%s\n' "$OUT" "$ERR" | grep -F src/new.js | grep -q HARD; then fail "staged 10 lines, worktree 501: no HARD diagnostic for src/new.js" "out=$OUT err=$ERR"
  else pass "staged 10 lines, worktree 501: no HARD diagnostic for src/new.js"; fi
  if [ "$(git -C "$cfg" rev-parse HEAD)" != "$base" ]; then pass "staged 10 lines, worktree 501: HEAD moves"
  else fail "staged 10 lines, worktree 501: HEAD moves" "rc=$RC err=$ERR"; fi
  git -C "$cfg" reset -q --hard "$base"
  cfg="$(new_cfg)"
  gc_stage_then_put "$cfg" src/new.js 501 10
  gc_commit "$cfg" "staged over, worktree under"
  expect_block "staged 501 lines, worktree 10: the git commit is denied (rc 1) with the HARD diagnostic naming src/new.js" src/new.js
  if [ "$(git -C "$cfg" rev-parse HEAD)" = "$base" ]; then pass "staged 501 lines, worktree 10: HEAD stays put"
  else fail "staged 501 lines, worktree 10: HEAD stays put" "HEAD moved past $base"; fi
  git -C "$cfg" reset -q --hard "$base"
}

# src/old.js is 600 lines (over HARD) at HEAD; the index shrinks it while the worktree grows it back.
gc_case_shrink_of_over_hard_file_judged_by_index() {
  local cfg base
  cfg="$(new_cfg)"
  base="$(git -C "$cfg" rev-parse HEAD)"
  gc_stage_then_put "$cfg" src/old.js 505 620
  gc_commit "$cfg" "shrink over-hard, worktree grown"
  if [ "$RC" = 0 ]; then pass "over-HARD at HEAD, index shrunk to 505, worktree 620: the git commit is allowed (rc 0)"
  else fail "over-HARD at HEAD, index shrunk to 505, worktree 620: the git commit is allowed (rc 0)" "rc=$RC out=$OUT err=$ERR"; fi
  if printf '%s\n%s\n' "$OUT" "$ERR" | grep -F src/old.js | grep -q HARD; then fail "shrink with grown worktree: no HARD diagnostic for src/old.js" "out=$OUT err=$ERR"
  else pass "shrink with grown worktree: no HARD diagnostic for src/old.js"; fi
  if [ "$(git -C "$cfg" rev-parse HEAD)" != "$base" ]; then pass "shrink with grown worktree: HEAD moves"
  else fail "shrink with grown worktree: HEAD moves" "rc=$RC err=$ERR"; fi
  git -C "$cfg" reset -q --hard "$base"
  # Control: the gate is live — the index growing the same file blocks even with a shrunk worktree.
  cfg="$(new_cfg)"
  gc_stage_then_put "$cfg" src/old.js 620 505
  gc_commit "$cfg" "grow over-hard, worktree shrunk"
  expect_block "over-HARD at HEAD, index grown to 620, worktree 505: the git commit is denied with the HARD diagnostic naming src/old.js" src/old.js
  git -C "$cfg" reset -q --hard "$base"
}

# gc_mixed <name> <expect: block|pass> <offender|-> <path:n>... — one git commit staging every
# <path:n>; git lists them docs/ < rules/ < src/, so a small file is judged before the offender.
gc_mixed() {
  local name="$1" want="$2" offender="$3" cfg base spec p
  shift 3
  cfg="$(new_cfg)"
  base="$(git -C "$cfg" rev-parse HEAD)"
  for spec in "$@"; do stage "$cfg" "${spec%:*}" "${spec##*:}"; done
  gc_commit "$cfg" "mixed kinds"
  if [ "$want" = block ]; then
    expect_block "$name: the commit is rejected, naming $offender" "$offender"
    if [ "$(git -C "$cfg" rev-parse HEAD)" = "$base" ]; then pass "$name: HEAD stays put"
    else fail "$name: HEAD stays put" "HEAD moved past $base"; fi
  else
    expect_pass "$name: the commit is allowed"
    if [ "$(git -C "$cfg" rev-parse HEAD)" != "$base" ]; then pass "$name: HEAD moves"
    else fail "$name: HEAD moves" "rc=$RC err=$ERR"; fi
  fi
  for spec in "$@"; do
    p="${spec%:*}"
    [ "$p" = "$offender" ] && continue
    if printf '%s\n%s\n' "$OUT" "$ERR" | grep -F "$p" | grep -q HARD; then fail "$name: no HARD verdict names $p" "out=$OUT err=$ERR"
    else pass "$name: no HARD verdict names $p"; fi
  done
  git -C "$cfg" reset -q --hard "$base"
}

# HARD: docs 500, prompt 200, code 500; WARN: docs 300, prompt 100, code 300.
gc_case_mixed_kinds_small_then_over_hard() {
  gc_mixed "small docs + small prompt, then code at HARD+1" block src/zz.js docs/guide.md:10 rules/a.md:10 src/zz.js:501
  gc_mixed "small docs, then prompt at HARD+1, then small code" block rules/zz.md docs/guide.md:10 rules/zz.md:201 src/a.js:10
  gc_mixed "every kind at exactly HARD" pass - docs/guide.md:500 rules/a.md:200 src/a.js:500
  gc_mixed "every kind over WARN, under HARD" pass - docs/guide.md:301 rules/a.md:101 src/a.js:301
}

# Each metacharacter would run a command if the path ever reached a shell unquoted.
GC_META_PATH="src/a;b \$(touch pwned) 'q'.js"

# gc_no_pwned <name> — no file named pwned appeared anywhere under the test's temp root.
gc_no_pwned() {
  local hit
  hit="$(find "$TMP_ROOT" -name pwned -print 2>/dev/null | head -n 1)"
  if [ -z "$hit" ]; then pass "$1"; else fail "$1" "found $hit"; fi
}

gc_case_shell_metachar_path() {
  local cfg
  cfg="$(new_cfg)"
  stage "$cfg" "$GC_META_PATH" 501
  if [ -f "$cfg/$GC_META_PATH" ]; then pass "premise: the metacharacter file exists on disk"
  else fail "premise: the metacharacter file exists on disk" "$cfg/$GC_META_PATH"; fi
  run_pc "$cfg" "$cfg"
  expect_block "'$GC_META_PATH' at HARD+1 blocks, named verbatim" "$GC_META_PATH"
  gc_no_pwned "no command embedded in the path ran (HARD+1 run)"
  cfg="$(new_cfg)"
  stage "$cfg" "$GC_META_PATH" 10
  run_pc "$cfg" "$cfg"
  expect_pass "'$GC_META_PATH' at 10 lines passes"
  gc_no_pwned "no command embedded in the path ran (10-line run)"
}
