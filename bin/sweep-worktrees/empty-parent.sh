#!/bin/bash
#
# bin/sweep-worktrees/empty-parent.sh
#
# Sourced by bin/sweep-worktrees.sh. Provides two functions:
#
#   discover_registered_wt_parents
#     Populates the REGISTERED_WT_PARENTS associative array with
#     WORKTREE_BASE_DIR/<task-name> parent directories referenced by any
#     discovered main repo's `git worktree list`. Inputs: $WORKTREE_BASE_DIR,
#     $MAIN_ROOT. Mutates: REGISTERED_WT_PARENTS, DISCOVERED_MAIN_ROOTS.
#
#   sweep_empty_parents
#     Reclaims depth-1 task-name parent directories under WORKTREE_BASE_DIR
#     that are empty (no subdirectories), not registered with any discovered
#     repo's worktree, and older than SWEEP_AGE_DAYS. Inputs: $WORKTREE_BASE_DIR,
#     $SWEEP_AGE_DAYS, $DRY_RUN, REGISTERED_WT_PARENTS. Mutates:
#     $empty_parents_candidates, $empty_parents_removed,
#     $empty_parents_skipped_young, $empty_parents_skipped_nonempty,
#     $empty_parents_skipped_registered.
#
# Must be `source`d, not executed directly — it mutates caller-scope variables.

discover_registered_wt_parents() {
  if [[ -z "${WORKTREE_BASE_DIR:-}" ]] || [[ ! -d "$WORKTREE_BASE_DIR" ]]; then
    return 0
  fi
  DISCOVERED_MAIN_ROOTS["$MAIN_ROOT"]=1
  local wt_leaf common_dir main_root_cand
  while IFS= read -r -d '' wt_leaf; do
    common_dir="$(git -C "$wt_leaf" rev-parse --git-common-dir 2>/dev/null || true)"
    if [[ -n "$common_dir" ]]; then
      main_root_cand="$(cd "$common_dir/.." 2>/dev/null && pwd || true)"
      if [[ -n "$main_root_cand" ]]; then
        DISCOVERED_MAIN_ROOTS["$main_root_cand"]=1
      fi
    fi
  done < <(find "$WORKTREE_BASE_DIR" -mindepth 2 -maxdepth 2 -type d -print0 2>/dev/null)
  # Normalize the base for cross-platform prefix matching: git worktree list
  # may return canonical paths in a different surface form than the literal
  # $WORKTREE_BASE_DIR (e.g. Windows drive-letter form vs MSYS /tmp form).
  local wt_base_norm
  wt_base_norm="$(norm_path "$WORKTREE_BASE_DIR")"
  local repo_root line wt_path wt_path_norm rel task_seg
  for repo_root in "${!DISCOVERED_MAIN_ROOTS[@]}"; do
    while IFS= read -r line; do
      case "$line" in
        worktree\ *)
          wt_path="${line#worktree }"
          wt_path_norm="$(norm_path "$wt_path")"
          case "$wt_path_norm" in
            "$wt_base_norm"/*) ;;
            *) continue ;;
          esac
          rel="${wt_path_norm#"$wt_base_norm"/}"
          task_seg="${rel%%/*}"
          REGISTERED_WT_PARENTS["$wt_base_norm/$task_seg"]=1
          ;;
      esac
    done < <(git -C "$repo_root" worktree list --porcelain 2>/dev/null || true)
  done
}

sweep_empty_parents() {
  if [[ ! -d "${WORKTREE_BASE_DIR:-}" ]]; then
    return 0
  fi
  local empty_parent_age_mins
  empty_parent_age_mins=$(( SWEEP_AGE_DAYS * 24 * 60 ))
  local parent parent_norm
  while IFS= read -r -d '' parent; do
    parent_norm="$(norm_path "$parent")"
    # Gate 0: registered in any discovered repo's worktree registry.
    if [[ -n "${REGISTERED_WT_PARENTS[$parent_norm]+x}" ]]; then
      empty_parents_skipped_registered=$(( empty_parents_skipped_registered + 1 ))
      continue
    fi
    # Gate 0b: safety net — any depth-2 child contains a .git pointer.
    if find "$parent" -mindepth 2 -maxdepth 2 -name '.git' -print -quit 2>/dev/null | grep -q .; then
      empty_parents_skipped_registered=$(( empty_parents_skipped_registered + 1 ))
      continue
    fi
    # Gate 1: must be truly empty (no children of ANY type — subdirs OR files).
    # A files-only parent is still data that we must not silently drop;
    # rmdir would fail anyway, so we'd inflate `candidates` for nothing.
    if [[ -n "$(find "$parent" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
      empty_parents_skipped_nonempty=$(( empty_parents_skipped_nonempty + 1 ))
      continue
    fi
    # Gate 2: age gate — must be older than SWEEP_AGE_DAYS.
    if find "$parent" -maxdepth 0 -mmin "-${empty_parent_age_mins}" 2>/dev/null | grep -q .; then
      empty_parents_skipped_young=$(( empty_parents_skipped_young + 1 ))
      continue
    fi
    empty_parents_candidates=$(( empty_parents_candidates + 1 ))
    if [[ "$DRY_RUN" == "1" ]]; then
      # Route to stderr under CI_MODE so the trailing JSON on stdout parses cleanly.
      if [[ "${CI_MODE:-0}" == "1" ]]; then
        printf 'DRY-RUN: empty-parent %s\n' "$parent" >&2
      else
        printf 'DRY-RUN: empty-parent %s\n' "$parent"
      fi
    else
      if rmdir "$parent" 2>/dev/null; then
        empty_parents_removed=$(( empty_parents_removed + 1 ))
      else
        printf 'WARN: rmdir failed for %s\n' "$parent" >&2
      fi
    fi
  done < <(find "$WORKTREE_BASE_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
}
