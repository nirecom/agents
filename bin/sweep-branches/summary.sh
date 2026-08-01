#!/bin/bash
#
# bin/sweep-branches/summary.sh
#
# Sourced by bin/sweep-branches.sh. Renders the end-of-run summary in whichever
# shape --ci-mode selected. The JSON key set here is the machine contract the
# /sweep hub and tests/feature-sweep-branches* read, so keys are only ever
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
    printf '{"scanned":%d,"candidates":%d,"local_deleted":%d,"remote_deleted":%d,"remote_delete_failed":%d,"skipped_unmerged":%d,"skipped_young":%d,"skipped_worktree_locked":%d,"no_pr_candidates":%d,"no_pr_deleted":%d,"no_pr_skipped_young":%d,"no_pr_skipped_unreachable":%d,"pr_state_unknown":%d,"unmerged_pr_skipped":%d,"errors":%s}\n' \
      "$scanned" "$candidates" "$local_deleted" "$remote_deleted" \
      "$remote_delete_failed" "$skipped_unmerged" "$skipped_young" \
      "$skipped_worktree_locked" \
      "$no_pr_candidates" "$no_pr_deleted" "$no_pr_skipped_young" \
      "$no_pr_skipped_unreachable" "$pr_state_unknown" \
      "$unmerged_pr_skipped" \
      "$errs_json"
  else
    printf 'sweep-branches summary:\n'
    printf '  scanned: %d\n' "$scanned"
    printf '  candidates: %d\n' "$candidates"
    printf '  local_deleted: %d\n' "$local_deleted"
    printf '  remote_deleted: %d\n' "$remote_deleted"
    printf '  remote_delete_failed: %d\n' "$remote_delete_failed"
    printf '  skipped_unmerged: %d\n' "$skipped_unmerged"
    printf '  skipped_young: %d\n' "$skipped_young"
    printf '  skipped_worktree_locked: %d\n' "$skipped_worktree_locked"
    printf '  no_pr_candidates: %d\n' "$no_pr_candidates"
    printf '  no_pr_deleted: %d\n' "$no_pr_deleted"
    printf '  no_pr_skipped_young: %d\n' "$no_pr_skipped_young"
    printf '  no_pr_skipped_unreachable: %d\n' "$no_pr_skipped_unreachable"
    printf '  pr_state_unknown: %d\n' "$pr_state_unknown"
    printf '  unmerged_pr_skipped: %d\n' "$unmerged_pr_skipped"
    sweep_write_mode_footer
  fi
}
