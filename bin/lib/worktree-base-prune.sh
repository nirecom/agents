#!/usr/bin/env bash
# bin/lib/worktree-base-prune.sh — sourced by the review-* --all scans (#1610).
# worktree_base_prune_args fills WT_BASE_PRUNE_ARGS with `find .` prune clauses for the
# in-repo worktree bases under the CWD: always ./.claude/worktrees, plus the resolver base
# (bin/worktree-base) when it lies strictly inside the CWD. Use as: find . "${WT_BASE_PRUNE_ARGS[@]}" <tests> -print.
# Letter case folds (-ipath) per WORKTREE_BASE_FOLD_CASE from the CLI (#3138); when the CLI
# fails, only the fixed clause is added, always as -ipath, with one warning on stderr.

_WT_BASE_PRUNE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

worktree_base_prune_args() {
  local out base here rel fold match
  if ! out="$(bash "$_WT_BASE_PRUNE_ROOT/bin/worktree-base" --repo "$PWD" 2>/dev/null)"; then
    WT_BASE_PRUNE_ARGS=(-ipath './.claude/worktrees' -prune -o)
    printf '%s\n' "worktree_base_prune_args: bin/worktree-base failed; pruning only ./.claude/worktrees (case-insensitive), not the configured base" >&2
    return 0
  fi
  fold="$(printf '%s\n' "$out" | sed -n 's/^WORKTREE_BASE_FOLD_CASE=//p' | tr -d '\r')"
  match="-path"
  if [[ "$fold" == "on" ]]; then match="-ipath"; fi
  WT_BASE_PRUNE_ARGS=("$match" './.claude/worktrees' -prune -o)
  base="$(printf '%s\n' "$out" | sed -n 's/^WORKTREE_BASE=//p' | tr -d '\r')"
  here="$(pwd -W 2>/dev/null || pwd)"
  base="${base%/}"
  here="${here%/}"
  if [[ -z "$base" ]]; then return 0; fi
  if [[ "$fold" == "on" && "${base,,}" == "${here,,}"/* ]] || [[ "$fold" != "on" && "$base" == "$here"/* ]]; then
    rel="${base:${#here}+1}"
    if [[ "$rel" != ".claude/worktrees" ]]; then
      WT_BASE_PRUNE_ARGS+=("$match" "./$rel" -prune -o)
    fi
  fi
  return 0
}
