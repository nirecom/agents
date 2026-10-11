#!/usr/bin/env bash
# Tests: bin/check-root-names.sh, bin/check-root-names/main.js, bin/check-root-names/line-scan.js, bin/check-root-names/env-name.js, bin/check-root-names/structural.js
# Tags: root-names, staged, index, linked-worktree, typechange, symlink, gitlink, python, gate, static-check, bin, scope:issue-specific, TL2
# #2589 (commit 9 of #2561): every path the gate is handed is judged — an empty blob, a
# type change, a symlink, a gitlink, a subdirectory root, a linked worktree's index —
# and an environment write is caught in Python and through any env-named object.
# TL3 gap (what this test does NOT catch):
# - a real `git commit` in a linked worktree going through the installed pre-commit hook.
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
T="$(np "$(make_tmp)")"
readonly T
harness_isolate "$T/iso"
trap 'rm -rf "$T"' EXIT
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE 2>/dev/null || true
REAL_GATE="$SCRIPT_CHECKOUT_ROOT/bin/check-root-names.sh"
RETIRED_LIST="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2561-root-names-residue.sh"
. "$(dirname "$0")/feature-2561-root-names/common.sh"

# A retired spelling and a retired path word, split so this file carries neither.
OLD_ENV="AGENTS_CON""FIG_D""IR"
OLD_LINE="echo \"\$$OLD_ENV\""
OLD_PATH="hooks/lib/agents-con""fig-d""ir.js"

# staged_kit <name> — the gate copy is itself the repository under test; sets KIT.
staged_kit() {
  make_kit "$1"
  write_table "$KIT"
  init_repo "$KIT"
  fx "$KIT/bin/base.sh" 'echo base'
  commit_all "$KIT"
}

staged() { run_gate_at "$KIT" "$KIT" --staged "$@"; }

# blob_of <repo> <text> — write <text> (no trailing newline) as a blob; prints its id.
blob_of() { printf '%s' "$2" | git -C "$1" hash-object -w --stdin; }

# msg_of <key> — the text that tells the messages of env-name and structural apart.
msg_of() {
  case "$1" in
    set) printf 'neither a test nor a named exception' ;;
    never) printf 'never becomes an environment variable' ;;
    put) printf 'but it is put into an environment' ;;
    *) printf 'unknown message key %s' "$1" ;;
  esac
}

# An empty blob is read as "" (not skipped), so its path is still judged.
c_empty_staged_file() {
  staged_kit empty
  mkdir -p "$KIT/zz" "$KIT/hooks/lib"
  touch "$KIT/zz/empty.sh" "$KIT/$OLD_PATH"
  git -C "$KIT" add zz/empty.sh "$OLD_PATH"
  expect "empty: the staged blob really is empty" test "$(git -C "$KIT" cat-file -s :zz/empty.sh)" = 0
  staged --only table-match
  expect "empty: a path without a rule is reported" reports "zz/empty.sh" table-match 0 'no classification rule'
  staged --only residue
  expect "empty: a path carrying a retired word is reported" reports "$OLD_PATH" residue 0 'the path carries'
}

# A type change (symlink -> regular file) is a staged change like any other (ACMRT).
c_typechange_is_judged() {
  local link file
  staged_kit typechange
  link="$(blob_of "$KIT" 'base.sh')"
  git -C "$KIT" update-index --add --cacheinfo "120000,$link,bin/t-link"
  git -C "$KIT" commit -qm symlink
  file="$(blob_of "$KIT" "$OLD_LINE")"
  git -C "$KIT" update-index --cacheinfo "100644,$file,bin/t-link"
  expect "typechange: git sees a T change" test "$(git -C "$KIT" diff --cached --name-status)" = "T	bin/t-link"
  staged --only residue
  expect "typechange: the new regular file's content is judged" reports "bin/t-link" residue 1
}

# A staged gitlink has no blob, but its path is still judged.
c_staged_gitlink_path() {
  local zero
  zero="$(printf '%040d' 1)"
  staged_kit gitlink-path
  git -C "$KIT" update-index --add --cacheinfo "160000,$zero,$OLD_PATH"
  staged --only residue
  expect "gitlink: a retired word in a staged gitlink path is reported" reports "$OLD_PATH" residue 0 'the path carries'
  staged_kit gitlink-rule
  git -C "$KIT" update-index --add --cacheinfo "160000,$zero,zz/sub"
  staged --only table-match
  expect "gitlink: a staged gitlink without a rule is reported" reports "zz/sub" table-match 0 'no classification rule'
}

# A tree run judges the path of every tracked entry, not only regular files.
c_tree_non_regular_paths() {
  make_kit tree
  write_table "$KIT"
  new_repo tree-gitlink
  fx "$REPO/bin/r.sh" 'echo clean'
  git -C "$REPO" add bin/r.sh
  git -C "$REPO" update-index --add --cacheinfo "160000,$(printf '%040d' 1),$OLD_PATH"
  git -C "$REPO" commit -qm fixture
  run_gate "$KIT" --root "$REPO" --only residue
  expect "tree gitlink: a tracked gitlink path with a retired word is reported" reports "$OLD_PATH" residue 0 'the path carries'
  new_repo tree-symlink
  fx "$REPO/bin/r.sh" 'echo clean'
  mkdir -p "$REPO/hooks/lib"
  MSYS=winsymlinks:nativestrict ln -s ../../bin/r.sh "$REPO/$OLD_PATH" 2>/dev/null || true
  if [[ ! -L "$REPO/$OLD_PATH" ]]; then
    skip "tree symlink: this host cannot create a symbolic link"
    return 0
  fi
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only residue
  expect "tree symlink: a tracked symlink path with a retired word is reported" reports "$OLD_PATH" residue 0 'the path carries'
}

# A subdirectory root reports repository-relative paths, so the table rules still match.
c_subdir_root() {
  make_kit subdir
  write_table "$KIT"
  new_repo subdir
  fx "$REPO/bin/r.sh" "echo \"$V_SCR\""
  fx "$REPO/plain/p.sh" "echo \"$V_SCR\""
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO/bin" --only table-match
  expect "subdir: a bin root matches the bin rule (exit 0)" rc_is 0
  expect "subdir: no file falls to 'no classification rule'" never_says 'no classification rule'
  run_gate "$KIT" --root "$REPO/plain" --only table-match
  expect "subdir: the path is reported from the repository root" reports "plain/p.sh" table-match 1 'is not allowed'
}

# A commit in a linked worktree: the index is that worktree's and the base is its HEAD.
c_linked_worktree_index() {
  local wt="$T/wt" idx
  staged_kit linked
  git -C "$KIT" worktree add -q -b wt-branch "$wt"
  fx "$wt/bin/wt-only.sh" "$OLD_LINE"
  git -C "$wt" add bin/wt-only.sh
  git -C "$wt" commit -qm wt-only
  fx "$wt/bin/wt-new.sh" "$OLD_LINE"
  git -C "$wt" add bin/wt-new.sh
  idx="$(git -C "$wt" rev-parse --path-format=absolute --git-path index)"
  GIT_INDEX_FILE="$idx" run_gate_at "$wt" "$KIT" --staged --only residue
  expect "worktree: the file staged in the worktree is reported" reports "bin/wt-new.sh" residue 1
  expect "worktree: a file already in the worktree's HEAD is not a staged change" clean_for "bin/wt-only.sh"
  run_gate_at "$wt" "$KIT" --staged --only residue
  expect "worktree: without GIT_INDEX_FILE the cwd repo's index is judged" reports "bin/wt-new.sh" residue 1
}

# Python writes and env-named object writes count as environment writes.
c_env_member_writes() {
  local rows
  make_kit envw
  write_table "$KIT"
  new_repo envw
  table rows <<TABLE
bin/p-scr.py|never@1|os.environ["$N_SCR"] = x
bin/p-tmr-default.py|never@1|os.environ.setdefault("$N_TMR", x)
bin/p-amr.py|set@1|os.environ["$N_AMR"] = x
bin/p-amr-default.py|set@1|os.environ.setdefault("$N_AMR", x)
bin/p-amr-shebang|set@2|#!/usr/bin/env python3<NL>os.environ['$N_AMR'] = x
tests/p-amr-test.py|accepted|os.environ["$N_AMR"] = x
bin/p-comment.py|accepted|x = 1  # os.environ["$N_SCR"] = x
hooks/j-env.js|never@1|env.$N_SCR = x;
hooks/j-child.js|never@1|childEnv.$N_TCR = x;
hooks/j-bracket.js|never@1|env["$N_SCR"] = x;
hooks/j-amr.js|set@1|env.$N_AMR = x;
tests/j-amr-test.js|accepted|env.$N_AMR = x;
hooks/j-roots.js|accepted|roots.$N_TMR = x;
TABLE
  seed "$REPO" rows 1
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only env-name
  expect_rows "env write" env-name <<<"$rows"
  new_repo envs
  fx "$REPO/hooks/s-env.js" "env.$N_SCR = x;"
  fx "$REPO/hooks/s-ok.js" "roots.$N_SCR = x;"
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only structural
  expect "structural: env.<checkout root> = x is reported" reports "hooks/s-env.js" structural 1 "$(msg_of put)"
  expect "structural: a non-env object is not" clean_for "hooks/s-ok.js" structural
}

case_begin "empty-staged-file-path-is-judged" "bin/check-root-names/main.js"
c_empty_staged_file
case_end

case_begin "staged-type-change-is-judged" "bin/check-root-names/main.js"
c_typechange_is_judged
case_end

case_begin "staged-gitlink-path-is-judged" "bin/check-root-names/main.js"
c_staged_gitlink_path
case_end

case_begin "tree-symlink-and-gitlink-paths-are-judged" "bin/check-root-names/main.js"
c_tree_non_regular_paths
case_end

case_begin "subdirectory-root-keeps-repository-relative-paths" "bin/check-root-names/main.js"
c_subdir_root
case_end

case_begin "linked-worktree-commit-judges-that-worktrees-index" "bin/check-root-names/main.js"
c_linked_worktree_index
case_end

case_begin "python-and-env-object-writes-are-environment-writes" "bin/check-root-names/env-name.js"
c_env_member_writes
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]]
