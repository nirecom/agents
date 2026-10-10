#!/usr/bin/env bash
# new-fail-digest.sh <compare-dir> <changed-run-dir> [lines-per-test=5] — EXPERIMENTAL (#2585).
# For the BASE-GREEN and EXTRA-FAILS tests of a compare-runs.sh result: the first new FAIL
# lines (cut to 230 chars) plus error-shaped lines of the changed run's log, written to
# <compare-dir>/digest.txt.
set -u
CMP="${1:?compare dir required}"
WRUN="${2:?changed run dir required}"
N="${3:-5}"
DIG="$CMP/digest.txt"
: > "$DIG"
grep -aE '^(BASE-GREEN|EXTRA-FAILS)	' "$CMP/summary.tsv" | sort -t$'\t' -k7 | while IFS=$'\t' read -r class rc brc nw nb nn rel; do
  name="${rel//\//__}"
  {
    echo "### $rel [$class w=$rc b=$brc new=$nn]"
    head -n "$N" "$CMP/$name.new" | cut -c1-230
    grep -aE 'unbound variable|root-decoy|root decoy hit|No such file|command not found|Cannot find module|not set|is required' "$WRUN/logs/$name.log" \
      | sed -E 's/tmp\.[A-Za-z0-9]{6,}/tmp.X/g' | sort -u | head -n 3 | cut -c1-230 | sed 's/^/  ERR: /'
  } >> "$DIG"
done
grep -c '^###' "$DIG"
echo END
