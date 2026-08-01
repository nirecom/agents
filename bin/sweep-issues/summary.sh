#!/bin/bash
#
# bin/sweep-issues/summary.sh
#
# Sourced by bin/sweep-issues.sh. Renders the pass-1 summary in whichever shape
# --ci-mode selected, and owns the run's exit status.
#
# `errors` is a REAL count, not a placeholder: every sub-step that failed (band
# fetch, stale scan, meta-parent listing) and every row the close batch could not
# complete (PARTIAL: / SKIP:) increments it. A run with errors > 0 exits 1, so a
# cron schedule that only looks at the exit status still sees the failure.
#
# Must be `source`d, not executed directly — it reads the caller's counters.

# emit_scan_summary — prints the summary and exits with the run's status.
emit_scan_summary() {
  if [[ "$CI_MODE" -eq 1 ]]; then
    printf '{"mode":"scan","band_index":%s,"band_size":%s,"scanned":%s,"tier2_candidates":%s,"tier1_candidates":%s,"tier1_closed":%s,"tier2_closed":0,"partial":%s,"errors":%s}\n' \
      "$BAND_INDEX" "$BAND_SIZE" "${scanned:-0}" "${tier2_count:-0}" \
      "${tier1_count:-0}" "${tier1_closed:-0}" "${partial_count:-0}" \
      "${errors:-0}"
  else
    printf 'SUMMARY: scanned=%s tier2_candidates=%s tier1_candidates=%s tier1_closed=%s partial=%s errors=%s\n' \
      "${scanned:-0}" "${tier2_count:-0}" "${tier1_count:-0}" \
      "${tier1_closed:-0}" "${partial_count:-0}" "${errors:-0}"
    if [[ "${errors:-0}" -gt 0 ]]; then
      printf 'WARNING: %s sub-step(s) failed — this run is NOT a clean sweep; see the ERROR/PARTIAL/SKIP lines above\n' \
        "${errors:-0}" >&2
    fi
    sweep_write_mode_footer
  fi

  [[ "${errors:-0}" -gt 0 ]] && exit 1
  exit 0
}
