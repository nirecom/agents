#!/usr/bin/env bash
# compare-runs.sh <changed-run-dir> <baseline-run-dir> <out-dir> — EXPERIMENTAL (#2585).
# For each red test of the changed run (run-list.sh output), classifies it against the
# baseline run by exit code and by the set of FAIL lines. Writes <out-dir>/summary.tsv and,
# per test, the normalized FAIL lines (.w / .b) and the ones only the changed run has (.new).
set -u
W="${1:?changed run dir required}"
B="${2:?baseline run dir required}"
CMP="${3:?out dir required}"
if [[ -e "$CMP" && ! -f "$CMP/summary.tsv" ]]; then
  echo "ABORT: $CMP exists and is not a compare dir"; exit 2
fi
rm -rf "$CMP"; mkdir -p "$CMP"
: > "$CMP/summary.tsv"

fails() {  # normalized FAIL lines of one log (summary counters and temp names dropped)
  grep -aE 'FAIL|not ok|✗' "$1" 2>/dev/null \
    | grep -avE 'PASS[=: ]*[0-9]+.*FAIL[=: ]*[0-9]+|FAIL[=: ]+[0-9]+ *$|[0-9]+ (passed|failed)' \
    | sed -E 's/tmp\.[A-Za-z0-9]{6,}/tmp.X/g; s/[0-9]+ms//g; s/\x1b\[[0-9;]*m//g; s/[[:space:]]+$//' \
    | sort -u
}

while IFS=$'\t' read -r rc secs rel; do
  case "$rc" in 0|77) continue ;; esac
  name="${rel//\//__}"
  brc="$(grep -aF "	$rel" "$B/results.tsv" | head -1 | cut -f1)"
  [[ -z "$brc" ]] && brc="absent"
  fails "$W/logs/$name.log" > "$CMP/$name.w"
  if [[ -f "$B/logs/$name.log" ]]; then fails "$B/logs/$name.log" > "$CMP/$name.b"; else : > "$CMP/$name.b"; fi
  comm -23 "$CMP/$name.w" "$CMP/$name.b" > "$CMP/$name.new"
  nw="$(grep -c . "$CMP/$name.w")"; nb="$(grep -c . "$CMP/$name.b")"; nn="$(grep -c . "$CMP/$name.new")"
  if [[ "$brc" == absent ]]; then class="NEW-TEST"
  elif [[ "$brc" == 0 || "$brc" == 77 ]]; then class="BASE-GREEN"
  elif [[ "$nn" -eq 0 && "$nw" -gt 0 ]]; then class="SAME-OR-FEWER"
  elif [[ "$nn" -eq 0 ]]; then class="BOTH-RED-NO-FAIL-LINES"
  else class="EXTRA-FAILS"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$class" "$rc" "$brc" "$nw" "$nb" "$nn" "$rel" >> "$CMP/summary.tsv"
done < "$W/results.tsv"

echo "--- classes (class / changed rc / baseline rc / fail lines w / b / new / test) ---"
cut -f1 "$CMP/summary.tsv" | sort | uniq -c
for c in NEW-TEST BASE-GREEN EXTRA-FAILS BOTH-RED-NO-FAIL-LINES; do
  echo "--- $c ---"
  grep -a "^$c	" "$CMP/summary.tsv" | sort -t$'\t' -k7
done
# A test with no result row in the changed run was never compared: it is not a pass.
echo "--- not compared (no result row in the changed run) ---"
[[ -f "$W/absent.txt" ]] && sed 's/^/ABSENT-IN-CHANGED-TREE	/' "$W/absent.txt"
cut -f3 "$B/results.tsv" | grep -vxFf <(cut -f3 "$W/results.tsv") | sed 's/^/BASELINE-ONLY	/'
