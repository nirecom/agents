#!/bin/bash
#
# bin/sweep-issues/summary.sh — sourced by bin/sweep-issues.sh (reads the caller's
# counters; never executed directly). Renders the pass-1 summary in the shape
# --ci-mode selected, adds the all-bands aggregate fields when ALL_BANDS=1, and
# owns the run's exit status. `errors` is a REAL count of every failed sub-step
# and incomplete close row; errors > 0 exits 1 so a cron job sees the failure.

# emit_scan_summary — prints the summary and exits with the run's status.
emit_scan_summary() {
  if [[ "$CI_MODE" -eq 1 ]]; then
    if [[ "${ALL_BANDS:-0}" -eq 1 ]]; then
      printf '{"mode":"scan","band_index":"all","band_size":%s,"scanned":%s,"tier2_candidates":%s,"tier1_candidates":%s,"tier1_closed":%s,"tier2_closed":0,"partial":%s,"errors":%s,"bands_swept":%s,"total_bands":%s}\n' \
        "$BAND_SIZE" "${scanned:-0}" "${tier2_count:-0}" \
        "${tier1_count:-0}" "${tier1_closed:-0}" "${partial_count:-0}" \
        "${errors:-0}" "${bands_swept:-0}" "${total_bands:-0}"
    else
      printf '{"mode":"scan","band_index":%s,"band_size":%s,"scanned":%s,"tier2_candidates":%s,"tier1_candidates":%s,"tier1_closed":%s,"tier2_closed":0,"partial":%s,"errors":%s}\n' \
        "$BAND_INDEX" "$BAND_SIZE" "${scanned:-0}" "${tier2_count:-0}" \
        "${tier1_count:-0}" "${tier1_closed:-0}" "${partial_count:-0}" \
        "${errors:-0}"
    fi
  else
    if [[ "${ALL_BANDS:-0}" -eq 1 ]]; then
      printf 'SUMMARY: scanned=%s tier2_candidates=%s tier1_candidates=%s tier1_closed=%s partial=%s errors=%s band_index=all bands_swept=%s total_bands=%s\n' \
        "${scanned:-0}" "${tier2_count:-0}" "${tier1_count:-0}" \
        "${tier1_closed:-0}" "${partial_count:-0}" "${errors:-0}" \
        "${bands_swept:-0}" "${total_bands:-0}"
    else
      printf 'SUMMARY: scanned=%s tier2_candidates=%s tier1_candidates=%s tier1_closed=%s partial=%s errors=%s\n' \
        "${scanned:-0}" "${tier2_count:-0}" "${tier1_count:-0}" \
        "${tier1_closed:-0}" "${partial_count:-0}" "${errors:-0}"
    fi
    if [[ "${errors:-0}" -gt 0 ]]; then
      printf 'WARNING: %s sub-step(s) failed — this run is NOT a clean sweep; see the ERROR/PARTIAL/SKIP lines above\n' \
        "${errors:-0}" >&2
    fi
    sweep_write_mode_footer
  fi

  [[ "${errors:-0}" -gt 0 ]] && exit 1
  exit 0
}
