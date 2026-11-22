#!/usr/bin/env bash
# bin/lib/worktree-base-prune.sh — sourced by the review-* --all scans (#1610).
# worktree_base_prune_args fills WT_BASE_PRUNE_ARGS with `find .` prune clauses for the
# in-repo worktree bases under the CWD: always ./.claude/worktrees, plus the resolver base
# (bin/worktree-base) when it lies strictly inside the CWD. Use as: find . "${WT_BASE_PRUNE_ARGS[@]}" <tests> -print.

_WT_BASE_PRUNE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

worktree_base_prune_args() {
  local out base here rel
  WT_BASE_PRUNE_ARGS=(-path './.claude/worktrees' -prune -o)
  out="$(bash "$_WT_BASE_PRUNE_ROOT/bin/worktree-base" --repo "$PWD" 2>/dev/null)" || return 0
  base="$(printf '%s\n' "$out" | sed -n 's/^WORKTREE_BASE=//p' | tr -d '\r')"
  here="$(pwd -W 2>/dev/null || pwd)"
  base="${base%/}"
  here="${here%/}"
  # Case-folded prefix test: Windows paths differ only in drive-letter case between tools.
  if [[ -n "$base" && "${base,,}" == "${here,,}"/* ]]; then
    rel="${base:${#here}+1}"
    if [[ "$rel" != ".claude/worktrees" ]]; then
      WT_BASE_PRUNE_ARGS+=(-path "./$rel" -prune -o)
    fi
  fi
  return 0
}
