#!/usr/bin/env bash
# tests/tests/feature-2590-command-guard/git-cases.sh — sourced by
# tests/tests/feature-2590-command-guard.sh: the guard's git judgement. Functions only.
#
# Every "outside" target is a fixture repo under $TMP_ROOT/outside, and every reject also checks
# that target is unchanged afterwards. GIT_CONFIG_SYSTEM points at a fixture file and ssh is
# disabled, so even a guard that wrongly passes a command through cannot leave the fixture tree.

CG_GIT_ENV=(env "GIT_CONFIG_SYSTEM=$TMP_ROOT/system.gitconfig" "GIT_SSH_COMMAND=false" "GIT_TERMINAL_PROMPT=0")

# Reads pass from bash and from a shell-less spawn, and print what real git prints.
cg_case_reads_pass() {
  cg_require "git reads pass through" || return 0
  local want
  want="$(rgit -C "$OUT_REPO" log --format=%H -1)"
  expect_allow "log outside (bash)" "$RR" git -C "$OUT_REPO" log --format=%H -1
  expect_eq "log outside (bash): same output as real git" "$OUT_TEXT" "$want"
  expect_allow "log outside (node)" "$RR" node "$SPAWN_JS" git -C "$OUT_REPO" log --format=%H -1
  expect_eq "log outside (node): same output as real git" "$OUT_TEXT" "$want"
  expect_allow "status outside" "$OUT_REPO" git status --porcelain
  expect_allow "rev-parse outside" "$OUT_REPO" git rev-parse --git-common-dir
  expect_allow "config read outside" "$OUT_REPO" git config --get core.hooksPath
  expect_eq "config read outside: same output as real git" "$OUT_TEXT" "$(rgit -C "$OUT_REPO" config --get core.hooksPath)"
}

# Writes whose git-dir, common dir and toplevel all sit inside the run root pass.
cg_case_inside_writes_pass() {
  cg_require "git writes inside the run root pass" || return 0
  expect_allow "init inside" "$RR" git init -q "$RR/fresh"
  expect_allow "config inside" "$RR/fresh" git config core.hooksPath /dev/null
  expect_allow "commit inside" "$IN_REPO" git -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m inside
  expect_allow "worktree add inside" "$IN_REPO" git worktree add -q -b wt-in "$RR/wt in"
  expect_allow "worktree move inside" "$IN_REPO" git worktree move "$RR/wt in" "$RR/wt moved"
  expect_allow "worktree remove inside" "$IN_REPO" git worktree remove "$RR/wt moved"
}

cg_out_unchanged() {
  expect_eq "$1: outside HEAD unchanged" "$(rgit -C "$OUT_REPO" rev-parse HEAD)" "$OUT_HEAD"
  expect_eq "$1: outside hooksPath unchanged" "$(rgit -C "$OUT_REPO" config --get core.hooksPath)" "$OUT_HOOKS"
}

# Each way of pointing a write at a repo outside the run root.
cg_case_redirected_writes_rejected() {
  cg_require "writes redirected outside the run root are rejected" || return 0
  local c=(-c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m leak)
  expect_reject "-C outside" "$RR" git -C "$OUT_REPO" "${c[@]}"
  cg_out_unchanged "-C outside"
  expect_reject "-C empty from an outside cwd" "$OUT_REPO" git -C "" "${c[@]}"
  cg_out_unchanged "-C empty"
  expect_reject "--git-dir outside" "$RR" git --git-dir="$(np "$OUT_REPO/.git")" --work-tree="$(np "$OUT_REPO")" "${c[@]}"
  cg_out_unchanged "--git-dir outside"
  expect_reject "GIT_DIR outside" "$RR" env "GIT_DIR=$(np "$OUT_REPO/.git")" git "${c[@]}"
  cg_out_unchanged "GIT_DIR outside"
  expect_reject "GIT_WORK_TREE outside" "$IN_REPO" env "GIT_WORK_TREE=$(np "$OUTSIDE/plain")" git add file.txt
  expect_eq "GIT_WORK_TREE outside: index unchanged" "$(rgit -C "$IN_REPO" ls-files)" ""
  expect_reject "core.worktree outside" "$RR/split" git add file.txt
  expect_eq "core.worktree outside: index unchanged" "$(rgit -C "$RR/split" ls-files)" ""
  expect_reject "linked worktree with an outside common dir" "$RR/linked" git "${c[@]}"
  expect_eq "linked worktree: branch unchanged" "$(rgit -C "$OUT_REPO" rev-parse linked)" "$OUT_HEAD"
}

cg_case_repo_creation_and_config_rejected() {
  cg_require "repo creation and config outside the run root are rejected" || return 0
  local before
  expect_reject "init in the OS temp area" "$RR" git init -q "$OUTSIDE/new repo"
  expect_eq "init outside: nothing created" "$([[ -e "$OUTSIDE/new repo" ]] && echo made)" ""
  expect_reject "core.hooksPath outside" "$OUT_REPO" git config core.hooksPath "$OUTSIDE/hooks"
  cg_out_unchanged "core.hooksPath outside"
  expect_reject "--global with HOME outside" "$RR" env -u GIT_CONFIG_GLOBAL "HOME=$OUTSIDE" "USERPROFILE=$OUTSIDE" git config --global user.name leak
  expect_eq "--global: no config written" "$([[ -e "$OUTSIDE/.gitconfig" ]] && echo made)" ""
  expect_reject "--system" "$IN_REPO" "${CG_GIT_ENV[@]}" git config --system user.name leak
  expect_eq "--system: no config written" "$([[ -e "$TMP_ROOT/system.gitconfig" ]] && echo made)" ""
  before="$(rgit -C "$OUT_REPO" worktree list --porcelain)"
  expect_reject "worktree add outside" "$OUT_REPO" git worktree add -q -b leak "$OUTSIDE/wt leak"
  expect_reject "worktree move outside" "$OUT_REPO" git worktree move "$RR/linked" "$OUTSIDE/wt moved"
  expect_reject "worktree remove outside" "$IN_REPO" git worktree remove --force "$OUTSIDE/wt of inner"
  expect_eq "worktree outside: list unchanged" "$(rgit -C "$OUT_REPO" worktree list --porcelain)" "$before"
  expect_eq "worktree remove outside: tree kept" "$([[ -d "$OUTSIDE/wt of inner" ]] && echo kept)" "kept"
}

# Pushing anywhere, and any network URL even from inside the run root, is rejected.
cg_case_push_and_network_rejected() {
  cg_require "push and network URLs are rejected" || return 0
  expect_reject "push to an outside bare repo" "$IN_REPO" git push -q "$(np "$BARE")" HEAD:refs/heads/leak
  expect_eq "push: bare repo has no ref" "$(rgit --git-dir="$BARE" for-each-ref)" ""
  expect_reject "https URL" "$IN_REPO" "${CG_GIT_ENV[@]}" git ls-remote https://example.invalid/o/r.git
  expect_reject "scp-style URL" "$IN_REPO" "${CG_GIT_ENV[@]}" git fetch git@example.invalid:o/r.git
}

# The representative rejects again, from a shell-less spawn and from a stripped environment.
cg_case_rejects_hold_on_every_route() {
  cg_require "rejects hold from node and env -i" || return 0
  local c=(-c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m leak)
  expect_reject "-C outside (node)" "$RR" node "$SPAWN_JS" git -C "$(np "$OUT_REPO")" "${c[@]}"
  expect_reject "hooksPath outside (node)" "$OUT_REPO" node "$SPAWN_JS" git config core.hooksPath x
  expect_reject "push (node)" "$IN_REPO" node "$SPAWN_JS" git push -q "$(np "$BARE")" HEAD:refs/heads/leak
  expect_reject "-C outside (env -i)" "$RR" env -i "PATH=$GBIN_U:$SAFE_PATH" "ROOT_DECOY_TEST_ID=$CG_TID" git -C "$OUT_REPO" "${c[@]}"
  expect_reject "hooksPath outside (env -i)" "$OUT_REPO" env -i "PATH=$GBIN_U:$SAFE_PATH" git config core.hooksPath x
  expect_reject "push (env -i)" "$IN_REPO" env -i "PATH=$GBIN_U:$SAFE_PATH" git push -q "$(np "$BARE")" HEAD:refs/heads/leak
  cg_out_unchanged "every route"
}

# HEAD, index and local config of the outside repo, as one comparable text.
cg_out_state() { rgit -C "$OUT_REPO" rev-parse HEAD; rgit -C "$OUT_REPO" ls-files -s; rgit -C "$OUT_REPO" config --local --list; }

# cg_reject_writes_via <label> <cwd> <git prefix...> — commit, add and config through one route.
cg_reject_writes_via() {
  local label="$1" cwd="$2" before
  shift 2
  printf 'n\n' >"$OUT_REPO/untracked.txt"
  before="$(cg_out_state)"
  expect_reject "$label commit" "$cwd" "$@" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m leak
  expect_reject "$label add" "$cwd" "$@" add untracked.txt
  expect_reject "$label config" "$cwd" "$@" config leak.key value
  expect_eq "$label: outside HEAD, index and config unchanged" "$(cg_out_state)" "$before"
}

# Chained -C: each -C resolves against the previous one, so the last hop leaves the run root.
cg_case_chained_dash_c_rejected() {
  cg_require "chained -C leaving the run root is rejected" || return 0
  cg_reject_writes_via "-C chain" "$RR" git -C "$RR" -C "../outside/real repo"
  cg_reject_writes_via "-C chain from a subdir" "$IN_REPO" git -C .. -C ../outside -C "real repo"
}

# A link inside the run root naming an outside repo: the guard must judge the resolved target.
# Windows without symlink rights falls back to a junction; no link at all is a FAIL, never a skip.
cg_case_symlink_out_rejected() {
  cg_require "a link inside the run root to an outside repo is rejected" || return 0
  local link="$RR/link to outside"
  MSYS=winsymlinks:nativestrict ln -s "$OUT_REPO" "$link" 2>/dev/null \
    || { [[ -n "$CG_EXE" ]] && cmd //c mklink //J "$(np "$link" | tr / '\\')" "$(np "$OUT_REPO" | tr / '\\')" >/dev/null 2>&1; }
  if [[ ! -d "$link/.git" ]]; then fail "link to outside repo" "could not create a symlink or junction at $link"; return 0; fi
  cg_reject_writes_via "via link (-C)" "$RR" git -C "$link"
  cg_reject_writes_via "via link (cwd)" "$link" git
}

# An alias the guard cannot see through counts as a write.
cg_case_alias_counts_as_write() {
  cg_require "unknown verbs are writes" || return 0
  expect_reject "alias outside" "$OUT_REPO" git zz
  rgit -C "$IN_REPO" config alias.zz status
  expect_allow "alias inside" "$IN_REPO" git zz
}
