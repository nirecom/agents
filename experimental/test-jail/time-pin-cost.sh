#!/usr/bin/env bash
# time-pin-cost.sh <test-rel> <out-dir> [tree] — EXPERIMENTAL (#2585). One test, alone, under
# each pin mode of run-jailed.sh: none (HOME swap + forge closed only), state (+ state/plans
# dirs), full (+ root decoy). Prints rc, seconds and the pin really obtained per mode; logs land
# in <out-dir>. JAIL_ALLOW_WEAKER_PIN=1 passes --allow-weaker-pin to every mode.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

T="${1:?test path required}"
OUT="${2:?out dir required}"
TREE="${3:-$SCRIPT_CHECKOUT_ROOT}"
flags=()
[[ "${JAIL_ALLOW_WEAKER_PIN:-}" == 1 ]] && flags+=(--allow-weaker-pin)
mkdir -p "$OUT"
for mode in none state full; do
  s=$SECONDS
  bash "$SCRIPT_CHECKOUT_ROOT/experimental/test-jail/run-jailed.sh" --tree "$TREE" --pin "$mode" --timeout 900 ${flags[@]+"${flags[@]}"} "$T" > "$OUT/time-pin-cost-$mode.log" 2>&1
  rc=$?
  obtained="$(awk '/^PINNED: obtained=/{sub(/^PINNED: obtained=/, ""); sub(/ .*/, ""); print; exit}' "$OUT/time-pin-cost-$mode.log")"
  echo "$mode rc=$rc secs=$((SECONDS - s)) obtained=${obtained:-unknown}"
done
