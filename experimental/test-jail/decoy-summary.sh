#!/usr/bin/env bash
# decoy-summary.sh <run-dir> — EXPERIMENTAL (#2585). Root decoy hits of one run-list.sh run
# (pin mode full): per hit path, per test, and the tests that are green despite a hit.
set -u
RUN="${1:?run dir required}"
LOGS="$RUN/logs"
echo "--- tests with at least one hit ---"
grep -l 'root decoy hit: ' "$LOGS"/*.log | wc -l
echo "--- hit paths (count of tests / path) ---"
for f in "$LOGS"/*.log; do
  grep -o 'root decoy hit: [^	]*' "$f" | sort -u
done | sort | uniq -c | sort -rn
echo "--- per test: unique hit paths ---"
for f in "$LOGS"/*.log; do
  hits="$(grep -o 'root decoy hit: [^	]*' "$f" | sed 's/root decoy hit: //' | sort -u | tr '\n' ' ')"
  [[ -z "$hits" ]] && continue
  name="$(basename "$f" .log)"
  rc="$(awk -F'\t' -v t="${name//__//}" '$3==t{print $1}' "$RUN/results.tsv")"
  printf '%s\trc=%s\t%s\n' "${name//__//}" "$rc" "$hits"
done
echo "--- tests green but with a hit ---"
for f in "$LOGS"/*.log; do
  grep -q 'root decoy hit: ' "$f" || continue
  name="$(basename "$f" .log)"
  awk -F'\t' -v t="${name//__//}" '$3==t && $1==0{print $3}' "$RUN/results.tsv"
done
echo END
