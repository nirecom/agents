#!/usr/bin/env bash
# time-pin-cost.sh <test-rel> <out-dir> [tree] — EXPERIMENTAL (#2585). One test, alone, under
# each pin mode of run-jailed.sh: none (HOME swap + forge closed only), state (+ state/plans
# dirs), full (+ root decoy). Prints rc and seconds per mode; logs land in <out-dir>.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

T="${1:?test path required}"
OUT="${2:?out dir required}"
TREE="${3:-$SCRIPT_CHECKOUT_ROOT}"
mkdir -p "$OUT"
for mode in none state full; do
  s=$SECONDS
  bash "$SCRIPT_CHECKOUT_ROOT/experimental/test-jail/run-jailed.sh" --tree "$TREE" --pin "$mode" --timeout 900 "$T" > "$OUT/time-pin-cost-$mode.log" 2>&1
  echo "$mode rc=$? secs=$((SECONDS - s))"
done
