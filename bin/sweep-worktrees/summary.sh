#!/bin/bash
#
# bin/sweep-worktrees/summary.sh
#
# Sourced by bin/sweep-worktrees.sh. Renders the end-of-run summary in whichever
# shape --ci-mode selected. The JSON key set here is the machine contract the
# /sweep hub and tests/feature-sweep-worktrees* read, so keys are only ever
# added, never renamed.
#
# Must be `source`d, not executed directly — it reads the caller's counters.

emit_summary() {
  if [[ "$CI_MODE" == "1" ]]; then
    local errs_json="[]"
    if [[ ${#errors[@]} -gt 0 ]]; then
      errs_json="$(printf '%s\n' "${errors[@]}" | node -e \
        'const xs=require("fs").readFileSync(0,"utf8").split(/\r?\n/).filter(Boolean);process.stdout.write(JSON.stringify(xs))')"
    fi
    printf '{"scanned":%d,"candidates":%d,"worktree_removed":%d,"branch_deleted":%d,"skipped_eperm":%d,"skipped_unmerged":%d,"skipped_dirty":%d,"orphan_dirs_removed":%d,"orphan_dirs_skipped_has_git":%d,"orphan_dirs_skipped_young":%d,"orphan_dirs_skipped_registered":%d,"orphan_dirs_skipped_failed":%d,"orphan_dirs_skipped_has_files":%d,"orphan_dirs_skipped_repo_mismatch":%d,"empty_parents_candidates":%d,"empty_parents_removed":%d,"empty_parents_skipped_young":%d,"empty_parents_skipped_nonempty":%d,"empty_parents_skipped_registered":%d,"errors":%s}\n' \
      "$scanned" "$candidates" "$worktree_removed" "$branch_deleted" \
      "$skipped_eperm" "$skipped_unmerged" "$skipped_dirty" "$orphan_dirs_removed" \
      "$orphan_dirs_skipped_has_git" "$orphan_dirs_skipped_young" \
      "$orphan_dirs_skipped_registered" "$orphan_dirs_skipped_failed" \
      "$orphan_dirs_skipped_has_files" "$orphan_dirs_skipped_repo_mismatch" \
      "$empty_parents_candidates" "$empty_parents_removed" \
      "$empty_parents_skipped_young" "$empty_parents_skipped_nonempty" \
      "$empty_parents_skipped_registered" \
      "$errs_json"
  else
    printf 'sweep-worktrees summary:\n'
    printf '  scanned: %d\n' "$scanned"
    printf '  candidates: %d\n' "$candidates"
    printf '  worktree_removed: %d\n' "$worktree_removed"
    printf '  branch_deleted: %d\n' "$branch_deleted"
    printf '  skipped_eperm: %d\n' "$skipped_eperm"
    printf '  skipped_unmerged: %d\n' "$skipped_unmerged"
    printf '  skipped_dirty: %d\n' "$skipped_dirty"
    if [[ "$orphan_dirs_removed" -gt 0 ]]; then
      printf '  orphan_dirs_removed: %d\n' "$orphan_dirs_removed"
    fi
    local skip_summary=""
    [[ "$orphan_dirs_skipped_has_git" -gt 0 ]] && skip_summary+=" has_git=$orphan_dirs_skipped_has_git"
    [[ "$orphan_dirs_skipped_young" -gt 0 ]] && skip_summary+=" young=$orphan_dirs_skipped_young"
    [[ "$orphan_dirs_skipped_registered" -gt 0 ]] && skip_summary+=" registered=$orphan_dirs_skipped_registered"
    [[ "$orphan_dirs_skipped_failed" -gt 0 ]] && skip_summary+=" failed=$orphan_dirs_skipped_failed"
    [[ "$orphan_dirs_skipped_has_files" -gt 0 ]] && skip_summary+=" has_files=$orphan_dirs_skipped_has_files"
    [[ "$orphan_dirs_skipped_repo_mismatch" -gt 0 ]] && skip_summary+=" repo_mismatch=$orphan_dirs_skipped_repo_mismatch"
    if [[ -n "$skip_summary" ]]; then
      printf '  orphan_dirs_skipped:%s\n' "$skip_summary"
    fi
    sweep_write_mode_footer
  fi
}
