#!/usr/bin/env bash
# Tests: tests/lib/command-guard/classify.js, tests/lib/command-guard/main.js
# Tags: scope:issue-specific, tl2, command-guard, fixture-isolation
#
# The command guard's verb table (#2590): each sub-command form isRead() calls a write is refused
# against a repo outside the run root and leaves it unchanged; each form it calls a read passes.
# The fast write path's deny list (--file / -f / --output, GIT_INDEX_FILE and friends) sends an
# inside-the-run-root command to main.js, which refuses its outside target.
# Fixtures and helpers: feature-2590-command-guard/setup.sh.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/state"
unset CLAUDE_CODE_SESSION_ID

. "$SCRIPT_CHECKOUT_ROOT/tests/tests/feature-2590-command-guard/setup.sh"

cg_setup || { echo "FAIL: fixture setup"; exit 1; }

ID=(-c user.name=t -c user.email=t@example.invalid)

# Refs, objects, config, index, reflog, worktrees and files of the outside repo, as one text.
cv_out_state() {
  rgit -C "$OUT_REPO" for-each-ref --format='%(refname) %(objectname)'
  rgit -C "$OUT_REPO" symbolic-ref -q HEAD
  rgit -C "$OUT_REPO" config --local --list
  rgit -C "$OUT_REPO" ls-files -s
  rgit -C "$OUT_REPO" count-objects -v
  rgit -C "$OUT_REPO" worktree list --porcelain
  cat "$OUT_REPO/.git/logs/HEAD"
  ls -a "$OUT_REPO"
}

# cv_deny <label> <git args...> — refused from inside the outside repo, which stays unchanged.
cv_deny() {
  local label="$1" before
  shift
  before="$(cv_out_state)"
  expect_reject "$label" "$OUT_REPO" git "$@"
  expect_has "$label: refused as an outside write" "$ERR_TEXT" "(write outside the run root)"
  expect_eq "$label: outside repo unchanged" "$(cv_out_state)" "$before"
}

# cv_allow <label> <git args...> — a read in the outside repo runs: exit 0, no hit.
cv_allow() {
  local label="$1"
  shift
  expect_allow "$label" "$OUT_REPO" git "$@"
}

# The outside repo gets what the read forms query and the write forms would change.
cv_fixture() {
  printf 'tracked\n' >"$OUT_REPO/t.txt"
  rgit -C "$OUT_REPO" add t.txt || return 1
  rcommit "$OUT_REPO" tracked || return 1
  rgit -C "$OUT_REPO" branch x || return 1
  rgit -C "$OUT_REPO" branch a || return 1
  rgit -C "$OUT_REPO" tag x || return 1
  printf 'changed\n' >"$OUT_REPO/t.txt"
  rgit -C "$OUT_REPO" "${ID[@]}" stash -q || return 1
  rgit -C "$OUT_REPO" remote add origin https://example.invalid/o/r.git || return 1
  rgit -C "$OUT_REPO" config cg.k v1 || return 1
  printf 'hash me %s\n' "$$" >"$OUTSIDE/hash-me.txt"
}

cv_fixture || { echo "FAIL: verb fixture setup"; exit 1; }
HASH_ME="$(np "$OUTSIDE/hash-me.txt")"

case_begin "write-forms-of-read-capable-verbs-are-refused" "tests/lib/command-guard/classify.js"
if cg_require "write forms of branch / tag / stash / remote are refused"; then
  cv_deny "branch new-branch" branch new-branch
  cv_deny "branch -D x" branch -D x
  cv_deny "branch -m a b" branch -m a b
  cv_deny "tag x2" tag x2
  cv_deny "tag -d x" tag -d x
  cv_deny "tag -a -m msg x3" "${ID[@]}" tag -a -m msg x3
  cv_deny "stash (bare)" "${ID[@]}" stash
  cv_deny "stash drop" stash drop
  cv_deny "remote add" remote add up https://example.invalid/o/up.git
  cv_deny "remote set-url" remote set-url origin https://example.invalid/o/other.git
fi
case_end

case_begin "write-forms-of-ref-and-object-verbs-are-refused" "tests/lib/command-guard/classify.js"
if cg_require "write forms of reflog / symbolic-ref / hash-object / notes are refused"; then
  cv_deny "reflog expire --all" reflog expire --expire=now --all
  cv_deny "reflog delete" reflog delete "HEAD@{0}"
  cv_deny "symbolic-ref HEAD refs/heads/x" symbolic-ref HEAD refs/heads/x
  cv_deny "symbolic-ref -d HEAD" symbolic-ref -d HEAD
  cv_deny "hash-object -w" hash-object -w "$HASH_ME"
  expect_ne "hash-object -w: object not written" "$(rc_of rgit -C "$OUT_REPO" cat-file -e "$(rgit -C "$OUT_REPO" hash-object "$HASH_ME")")" "0"
  cv_deny "notes add" "${ID[@]}" notes add -m msg HEAD
fi
case_end

case_begin "write-forms-of-submodule-worktree-config-are-refused" "tests/lib/command-guard/classify.js"
if cg_require "write forms of submodule / worktree / config are refused"; then
  cv_deny "submodule add (local url)" submodule add "$(np "$IN_REPO")" sub
  cv_deny "submodule update --init" submodule update --init
  cv_deny "worktree prune" worktree prune
  cv_deny "config --unset" config --unset cg.k
  cv_deny "config set" config set cg.k v2
  cv_deny "config k v" config cg.k v3
fi
case_end

case_begin "output-redirects-of-read-verbs-are-refused" "tests/lib/command-guard/classify.js"
if cg_require "--output / --output-directory outside the run root are refused"; then
  expect_reject "diff --output outside" "$IN_REPO" git diff "--output=$(np "$OUTSIDE/diff.out")"
  expect_eq "diff --output outside: no file" "$([[ -e "$OUTSIDE/diff.out" ]] && echo made)" ""
  expect_reject "format-patch --output-directory outside" "$IN_REPO" git format-patch -1 --output-directory "$(np "$OUTSIDE/patches")"
  expect_eq "format-patch outside: no directory" "$([[ -e "$OUTSIDE/patches" ]] && echo made)" ""
  expect_allow "diff --output inside" "$IN_REPO" git diff "--output=$(np "$RR/diff.out")"
  expect_eq "diff --output inside: file written" "$([[ -e "$RR/diff.out" ]] && echo made)" "made"
fi
case_end

case_begin "read-forms-pass-through" "tests/lib/command-guard/classify.js"
if cg_require "read forms of the read-capable verbs pass"; then
  cv_allow "branch (bare)" branch
  cv_allow "branch --list" branch --list
  cv_allow "branch --contains HEAD" branch --contains HEAD
  cv_allow "tag -l" tag -l
  cv_allow "stash list" stash list
  cv_allow "stash show" stash show
  cv_allow "remote (bare)" remote
  cv_allow "remote get-url origin" remote get-url origin
  expect_eq "remote get-url: real git output" "$OUT_TEXT" "https://example.invalid/o/r.git"
  cv_allow "reflog (bare)" reflog
  cv_allow "reflog show" reflog show
  cv_allow "notes list" notes list
  cv_allow "symbolic-ref HEAD" symbolic-ref HEAD
  cv_allow "hash-object without -w" hash-object "$HASH_ME"
  cv_allow "submodule status" submodule status
  cv_allow "worktree list" worktree list
  cv_allow "config --list" config --list
  cv_allow "config get" config get cg.k
  expect_eq "config get: real git output" "$OUT_TEXT" "v1"
  # A lightweight tag has nothing to verify, so real git fails; the guard must still let it run.
  before="$(hits_now)"
  gx "$OUT_REPO" git tag -v x
  expect_ne "tag -v x: not refused" "$RC" "97"
  expect_eq "tag -v x: records no hit" "$(hits_now)" "$before"
  expect_lacks "tag -v x: no guard message" "$ERR_TEXT" "command guard: refused"
fi
case_end

case_begin "fast-path-deny-list-reaches-main" "tests/lib/command-guard/main.js"
if cg_require "fast write path deny list sends outside targets to main.js"; then
  in_head="$(rgit -C "$IN_REPO" rev-parse HEAD)"
  expect_reject "config --file outside" "$IN_REPO" git config --file "$(np "$OUTSIDE/x.cfg")" cg.k v
  expect_reject "config -f outside" "$IN_REPO" git config -f "$(np "$OUTSIDE/x.cfg")" cg.k v
  expect_eq "config --file / -f outside: no file" "$([[ -e "$OUTSIDE/x.cfg" ]] && echo made)" ""
  expect_reject "GIT_INDEX_FILE outside" "$IN_REPO" env "GIT_INDEX_FILE=$(np "$OUTSIDE/idx")" git "${ID[@]}" commit -q --allow-empty -m x
  expect_eq "GIT_INDEX_FILE outside: no index" "$([[ -e "$OUTSIDE/idx" ]] && echo made)" ""
  expect_reject "GIT_OBJECT_DIRECTORY outside" "$IN_REPO" env "GIT_OBJECT_DIRECTORY=$(np "$OUTSIDE/obj")" git "${ID[@]}" commit -q --allow-empty -m x
  expect_eq "GIT_OBJECT_DIRECTORY outside: no object dir" "$([[ -e "$OUTSIDE/obj" ]] && echo made)" ""
  expect_reject "GIT_COMMON_DIR outside" "$IN_REPO" env "GIT_COMMON_DIR=$(np "$OUTSIDE/common.git")" git "${ID[@]}" commit -q --allow-empty -m x
  expect_eq "GIT_COMMON_DIR outside: nothing created" "$([[ -e "$OUTSIDE/common.git" ]] && echo made)" ""
  expect_reject "GIT_CONFIG outside" "$IN_REPO" env "GIT_CONFIG=$(np "$OUTSIDE/c")" git config cg.k v
  expect_eq "GIT_CONFIG outside: no file" "$([[ -e "$OUTSIDE/c" ]] && echo made)" ""
  expect_reject "commit --output outside" "$IN_REPO" git "${ID[@]}" commit -q --allow-empty -m x --output "$(np "$OUTSIDE/out")"
  expect_eq "commit --output outside: no file" "$([[ -e "$OUTSIDE/out" ]] && echo made)" ""
  expect_eq "fast path denies: inside HEAD unchanged" "$(rgit -C "$IN_REPO" rev-parse HEAD)" "$in_head"
  expect_allow "config --file inside" "$IN_REPO" git config --file "$(np "$RR/x.cfg")" cg.k v
  expect_eq "config --file inside: value written" "$(rgit config --file "$RR/x.cfg" --get cg.k)" "v"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
