#!/usr/bin/env bash
# run-list.sh <list-file> <run-dir> [tree] [desired-jobs=15] [pin=full] [timeout-secs=300]
# EXPERIMENTAL (#2585). Runs every test named in <list-file> (one tree-relative path per
# line) through run-jailed.sh, leasing up to min(desired, H-1) host-wide test lanes
# (bin/lib/test-host-lanes.sh). Tests carrying a "# Serial:" header run one at a time after
# the parallel ones. A breach ("SAFE-RUN:" line) does not stop the run: the logs holding one
# are listed at the end.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

JAIL_DIR="$SCRIPT_CHECKOUT_ROOT/experimental/test-jail"
LIST="${1:?list file required}"
export JAIL_RUN_DIR="${2:?run dir required}"
export JAIL_TREE="${3:-$SCRIPT_CHECKOUT_ROOT}"
DESIRED="${4:-15}"
export JAIL_PIN="${5:-full}"
export JAIL_SECS="${6:-300}"

# Only an earlier run dir (or nothing) is replaced.
if [[ -e "$JAIL_RUN_DIR" && ! -f "$JAIL_RUN_DIR/results.tsv" ]]; then
    echo "ABORT: $JAIL_RUN_DIR exists and is not a run dir"; exit 2
fi

bash "$JAIL_DIR/run-jailed.sh" --probe || { echo "ABORT: isolation probe failed"; exit 96; }

. "$SCRIPT_CHECKOUT_ROOT/bin/lib/run-all-parallelism.sh"
. "$SCRIPT_CHECKOUT_ROOT/bin/lib/test-host-lanes.sh"
trap thl_release_all EXIT
thl_run_all_lease "$DESIRED" 0 || { echo "ABORT: no test lane freed (rc=$?)"; exit 4; }
JOBS="$THL_GRANTED"
echo "lanes: $THL_NOTE"

rm -rf "$JAIL_RUN_DIR"
mkdir -p "$JAIL_RUN_DIR/logs"
: > "$JAIL_RUN_DIR/results.tsv"
: > "$JAIL_RUN_DIR/par.txt"
: > "$JAIL_RUN_DIR/ser.txt"
: > "$JAIL_RUN_DIR/absent.txt"
while IFS= read -r rel; do
  [[ -z "$rel" ]] && continue
  if [[ ! -f "$JAIL_TREE/$rel" ]]; then echo "$rel" >> "$JAIL_RUN_DIR/absent.txt"; continue; fi
  if head -15 "$JAIL_TREE/$rel" | grep -Eq '^# Serial:[[:space:]]*[^[:space:]]'; then
    echo "$rel" >> "$JAIL_RUN_DIR/ser.txt"
  else
    echo "$rel" >> "$JAIL_RUN_DIR/par.txt"
  fi
done < "$LIST"
echo "parallel=$(grep -c . "$JAIL_RUN_DIR/par.txt") serial=$(grep -c . "$JAIL_RUN_DIR/ser.txt") absent=$(grep -c . "$JAIL_RUN_DIR/absent.txt") jobs=$JOBS"

# The tests see no lane marker: their own run-all calls resolve lanes under the jailed home.
START=$SECONDS
xargs -P "$JOBS" -n 1 env -u TEST_LANES_HELD bash "$JAIL_DIR/run-one.sh" < "$JAIL_RUN_DIR/par.txt"
echo "parallel lane done after $((SECONDS - START))s"
while IFS= read -r rel; do
  [[ -z "$rel" ]] && continue
  env -u TEST_LANES_HELD bash "$JAIL_DIR/run-one.sh" "$rel"
done < "$JAIL_RUN_DIR/ser.txt"
echo "all done after $((SECONDS - START))s"

echo "results=$(grep -c . "$JAIL_RUN_DIR/results.tsv")"
echo "pass=$(grep -c '^0	' "$JAIL_RUN_DIR/results.tsv")"
echo "skip77=$(grep -c '^77	' "$JAIL_RUN_DIR/results.tsv")"
echo "--- not 0 / 77 ---"
grep -v -e '^0	' -e '^77	' "$JAIL_RUN_DIR/results.tsv" | sort -k3
echo "--- logs holding a SAFE-RUN line ---"
grep -l '^SAFE-RUN:' "$JAIL_RUN_DIR"/logs/*.log
echo "END"
