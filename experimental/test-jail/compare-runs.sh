#!/usr/bin/env bash
# compare-runs.sh <changed-run-dir> <baseline-run-dir> <out-dir> — EXPERIMENTAL (#2585).
# For each red test of the changed run (run-list.sh output), classifies it against the
# baseline run by exit code and by the set of FAIL lines. Writes <out-dir>/summary.tsv and,
# per test, the normalized FAIL lines (.w / .b) and the ones only the changed run has (.new).
# A comparison that cannot be trusted goes to not-compared.tsv with its reason and nowhere
# else: it has no summary.tsv row (a red REFUSED test keeps one, outside the red classes), so
# it is counted neither red nor green. A red among the
# trusted comparisons is NEW-RED (exit 1); otherwise any not-compared line is INCOMPLETE (exit 3).
set -u
W="${1:?changed run dir required}"
B="${2:?baseline run dir required}"
CMP="${3:?out dir required}"
. "$(dirname "${BASH_SOURCE[0]}")/jail-marker.sh"
jail_marker_prepare "$CMP" compare compare-runs.sh || exit 2
: > "$CMP/summary.tsv"
TAB=$'\t'

fails() {  # normalized FAIL lines of one log (summary counters and temp names dropped)
  grep -aE 'FAIL|not ok|✗' "$1" 2>/dev/null \
    | grep -avE 'PASS[=: ]*[0-9]+.*FAIL[=: ]*[0-9]+|FAIL[=: ]+[0-9]+ *$|[0-9]+ (passed|failed)' \
    | sed -E 's/tmp\.[A-Za-z0-9]{6,}/tmp.X/g; s/[0-9]+ms//g; s/\x1b\[[0-9;]*m//g; s/[[:space:]]+$//' \
    | sort -u
}

# log_flags <log>... — "safe" first when a log holds a SAFE-RUN: line, "weak" last when the
# first "PINNED: obtained=" line of a log shows another pin than the one asked for.
log_flags() {
  LC_ALL=C awk '
    FNR == 1 { pinned = 0 }
    /^SAFE-RUN:/ { safe = 1 }
    !pinned && /^PINNED: obtained=/ { pinned = 1; if (substr($2, 10) != substr($3, 11)) weak = 1 }
    END { print (safe ? "safe" : "") " " (weak ? "weak" : "") }' "$@"
}

# Pre-pass over every changed row, green ones included: the comparisons that cannot be trusted,
# each with the first reason that applies. The loop below then leaves those tests alone.
declare -A INVALID=() BRC=()
INVALID_ORDER=()
while IFS=$'\t' read -r rc secs rel pin; do
  [[ -z "$rel" ]] && continue
  name="${rel//\//__}"
  brow="$(awk -F'\t' -v t="$rel" '$3==t{print $1 "\t" $4; exit}' "$B/results.tsv")"
  brc="${brow%%"$TAB"*}"
  bpin="${brow#*"$TAB"}"
  BRC[$rel]="${brc:-absent}"
  # The loop files this one as REFUSED.
  if [[ "$rc" != 0 && "$rc" != 77 ]] && [[ "$rc" == 95 || "$rc" == 96 || "$brc" == 95 || "$brc" == 96 ]]; then continue; fi
  # A result row without its log cannot be shown free of a SAFE-RUN: line.
  logs=(); nolog=""
  if [[ -f "$W/logs/$name.log" ]]; then logs+=("$W/logs/$name.log"); else nolog=1; fi
  if [[ -f "$B/logs/$name.log" ]]; then logs+=("$B/logs/$name.log"); elif [[ -n "$brc" ]]; then nolog=1; fi
  flags=" "
  [[ "${#logs[@]}" -gt 0 ]] && flags="$(log_flags "${logs[@]}")"
  # A green changed row never reaches the loop, so a refused baseline is filed here.
  if [[ "$brc" == 95 || "$brc" == 96 ]]; then reason="REFUSED"
  elif [[ "$flags" == safe* ]]; then reason="SAFE-RUN-LINE"
  elif [[ -n "$nolog" ]]; then reason="NO-LOG"
  elif [[ "$rc" == 77 ]]; then reason="SKIPPED-IN-CHANGED"
  elif [[ -z "$pin" || "$pin" == unknown ]]; then reason="UNVERIFIED-PIN"
  elif [[ -n "$brc" ]] && [[ -z "$bpin" || "$bpin" == unknown ]]; then reason="UNVERIFIED-PIN"
  elif [[ "$flags" == *weak ]]; then reason="WEAK-PIN"
  elif [[ -n "$brc" && "$pin" != "$bpin" ]]; then reason="WEAK-PIN"
  # A test the baseline tree does not have is new; one it has but did not report is a lost row.
  elif [[ -z "$brc" ]] && ! grep -qxF -- "$rel" "$B/absent.txt" 2>/dev/null; then reason="NO-RESULT-ROW"
  else continue
  fi
  INVALID[$rel]="$reason"
  INVALID_ORDER+=("$rel")
done < "$W/results.tsv"

while IFS=$'\t' read -r rc secs rel pin; do
  case "$rc" in 0|77) continue ;; esac
  [[ -n "$rel" && -z "${INVALID[$rel]:-}" ]] || continue
  name="${rel//\//__}"
  brc="${BRC[$rel]}"
  fails "$W/logs/$name.log" > "$CMP/$name.w"
  if [[ -f "$B/logs/$name.log" ]]; then fails "$B/logs/$name.log" > "$CMP/$name.b"; else : > "$CMP/$name.b"; fi
  comm -23 "$CMP/$name.w" "$CMP/$name.b" > "$CMP/$name.new"
  nw="$(grep -c . "$CMP/$name.w")"; nb="$(grep -c . "$CMP/$name.b")"; nn="$(grep -c . "$CMP/$name.new")"
  if [[ "$rc" == 95 || "$rc" == 96 || "$brc" == 95 || "$brc" == 96 ]]; then class="REFUSED"
  elif [[ "$brc" == absent ]]; then class="NEW-TEST"
  elif [[ "$brc" == 0 || "$brc" == 77 ]]; then class="BASE-GREEN"
  elif [[ "$nn" -eq 0 && "$nw" -gt 0 ]]; then class="SAME-OR-FEWER"
  elif [[ "$nn" -eq 0 ]]; then class="BOTH-RED-NO-FAIL-LINES"
  else class="EXTRA-FAILS"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$class" "$rc" "$brc" "$nw" "$nb" "$nn" "$rel" >> "$CMP/summary.tsv"
done < "$W/results.tsv"

echo "--- classes (class / changed rc / baseline rc / fail lines w / b / new / test) ---"
cut -f1 "$CMP/summary.tsv" | sort | uniq -c
for c in NEW-TEST BASE-GREEN EXTRA-FAILS BOTH-RED-NO-FAIL-LINES REFUSED; do
  echo "--- $c ---"
  grep -a "^$c$TAB" "$CMP/summary.tsv" | sort -t"$TAB" -k7
done

# no_result_row <run-dir> — tests asked for and present in the changed tree and in that run's
# tree, without a result row in that run.
no_result_row() {
  grep . "$W/requested.txt" | grep -vxFf <(cat "$W/absent.txt" "$1/absent.txt" 2>/dev/null) \
    | grep -vxFf <(cut -f3 "$1/results.tsv") | awk '{print "NO-RESULT-ROW\t" $0}'
}
# Nothing listed here was compared: it is not a pass, and the run cannot be called free of new
# reds while any is left. One line per test, the first reason that applies.
{
  grep -a "^REFUSED$TAB" "$CMP/summary.tsv" | cut -f1,7
  for rel in ${INVALID_ORDER[@]+"${INVALID_ORDER[@]}"}; do printf '%s\t%s\n' "${INVALID[$rel]}" "$rel"; done
  if [[ -f "$W/requested.txt" ]]; then
    no_result_row "$W"
    no_result_row "$B"
  else
    # An old run dir: what was asked for is unknown, so a missing row cannot be told.
    printf 'NO-REQUESTED-LIST\t(whole run)\n'
  fi
  [[ -f "$W/absent.txt" ]] && awk 'NF{print "ABSENT-IN-CHANGED-TREE\t" $0}' "$W/absent.txt"
  cut -f3 "$B/results.tsv" | grep -vxFf <(cut -f3 "$W/results.tsv") | awk '{print "BASELINE-ONLY\t" $0}'
} | awk -F'\t' '$1 == "NO-REQUESTED-LIST" || !seen[$2]++' > "$CMP/not-compared.tsv"
echo "--- not compared ---"
cat "$CMP/not-compared.tsv"
red="$(grep -acE "^(NEW-TEST|BASE-GREEN|EXTRA-FAILS|BOTH-RED-NO-FAIL-LINES)$TAB" "$CMP/summary.tsv")"
skipped="$(grep -c . "$CMP/not-compared.tsv")"
if [[ "$red" -gt 0 ]]; then echo "VERDICT: NEW-RED ($red to read, $skipped not compared)"; exit 1; fi
if [[ "$skipped" -gt 0 ]]; then echo "VERDICT: INCOMPLETE ($skipped not compared)"; exit 3; fi
echo "VERDICT: NO-NEW-RED"
