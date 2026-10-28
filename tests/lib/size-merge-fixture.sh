#!/usr/bin/env bash
# tests/lib/size-merge-fixture.sh — sourced. An uncommitted merge (MERGE_HEAD present) for the
# #2631 stage-9 merge-exclusion tests; HARD values come from bin/print-size-limits --get.
# Functions set globals (SMF_MERGE_HEAD) instead of printing, so callers never wrap them in $(...).

_SMF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SMF_MERGE_HEAD=""
SMF_SEQ=0

# smf_hard <kind> — the HARD of <kind>.
smf_hard() {
  local w h
  read -r w h < <(node "$_SMF_ROOT/bin/print-size-limits" --get "$1" | tr -d '\r')
  printf '%s' "$h"
}

# smf_lines <n> [tag] — exactly n newline-terminated lines.
smf_lines() { local i; for ((i = 1; i <= $1; i++)); do printf '%s line %d\n' "${2:-incoming}" "$i"; done; }

smf_git() { git -C "$1" -c user.email=test@example.com -c user.name=Test "${@:2}"; }

# smf_start_merge <repo> <rel>=<n>... — in a repo whose HEAD is on a branch: a side branch adds each
# <rel> with <n> lines, HEAD gets a commit of its own, and `git merge --no-commit --no-ff` leaves
# MERGE_HEAD behind. Sets SMF_MERGE_HEAD to the incoming commit.
smf_start_merge() {
  local repo="$1" spec rel n base branch
  shift
  SMF_SEQ=$((SMF_SEQ + 1))
  base="$(git -C "$repo" rev-parse --abbrev-ref HEAD)" || return 1
  branch="smf-incoming-$$-$SMF_SEQ"
  git -C "$repo" checkout -q -b "$branch" || return 1
  for spec in "$@"; do
    rel="${spec%=*}"
    n="${spec##*=}"
    mkdir -p "$(dirname "$repo/$rel")"
    smf_lines "$n" "incoming-$SMF_SEQ" > "$repo/$rel"
    git -C "$repo" add -- "$rel" || return 1
  done
  smf_git "$repo" commit -q -m "fixture: incoming side" || return 1
  git -C "$repo" checkout -q "$base" || return 1
  printf 'head side %s\n' "$SMF_SEQ" > "$repo/smf-head-side-$SMF_SEQ.txt"
  git -C "$repo" add -- "smf-head-side-$SMF_SEQ.txt" || return 1
  smf_git "$repo" commit -q -m "fixture: head side" || return 1
  smf_git "$repo" merge -q --no-commit --no-ff "$branch" > /dev/null 2>&1
  [ -f "$(smf_merge_head_path "$repo")" ] || return 1
  SMF_MERGE_HEAD="$(git -C "$repo" rev-parse "$branch")"
}

# make_merge_repo <dir> <rel>=<n>... — a fresh repo (hooks off, HEAD main, base commit) + smf_start_merge.
make_merge_repo() {
  local dir="$1"
  shift
  mkdir -p "$dir"
  git init -q "$dir" || return 1
  git -C "$dir" config core.hooksPath /dev/null
  git -C "$dir" config core.autocrlf false
  git -C "$dir" symbolic-ref HEAD refs/heads/main
  printf 'seed\n' > "$dir/seed.txt"
  git -C "$dir" add seed.txt
  smf_git "$dir" commit -q -m "fixture: base" || return 1
  smf_start_merge "$dir" "$@"
}

# smf_grow <repo> <rel> — append one line to <rel> and stage it: the staged blob now differs from MERGE_HEAD.
smf_grow() {
  printf 'one more line\n' >> "$1/$2"
  git -C "$1" add -- "$2"
}

# smf_merge_head_path <repo> — the MERGE_HEAD file (per-worktree in a linked worktree).
smf_merge_head_path() {
  local rel
  rel="$(git -C "$1" rev-parse --git-path MERGE_HEAD | tr -d '\r')"
  case "$rel" in
    /* | [A-Za-z]:*) printf '%s' "$rel" ;;
    *) printf '%s/%s' "$1" "$rel" ;;
  esac
}
