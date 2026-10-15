#!/usr/bin/env bash
# run-one.sh <test-rel> — EXPERIMENTAL (#2585). One test through run-jailed.sh: a log under
# $JAIL_RUN_DIR/logs and one "rc<TAB>secs<TAB>test<TAB>obtained" line in $JAIL_RUN_DIR/results.tsv
# (obtained = the pin the run really had, "unknown" when the log does not say).
# JAIL_TREE / JAIL_PIN / JAIL_SECS select the tree, pin mode and timeout, and
# JAIL_ALLOW_WEAKER_PIN=1 passes --allow-weaker-pin (run-list.sh sets them).
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

: "${JAIL_RUN_DIR:?JAIL_RUN_DIR is required}"
rel="${1:?test path required}"
name="${rel//\//__}"
flags=()
[[ "${JAIL_ALLOW_WEAKER_PIN:-}" == 1 ]] && flags+=(--allow-weaker-pin)
start=$SECONDS
bash "$SCRIPT_CHECKOUT_ROOT/experimental/test-jail/run-jailed.sh" \
    --tree "${JAIL_TREE:-$SCRIPT_CHECKOUT_ROOT}" --pin "${JAIL_PIN:-full}" --timeout "${JAIL_SECS:-300}" \
    ${flags[@]+"${flags[@]}"} "$rel" > "$JAIL_RUN_DIR/logs/$name.log" 2>&1
rc=$?
secs=$((SECONDS - start))
obtained="$(awk '/^PINNED: obtained=/{sub(/^PINNED: obtained=/, ""); sub(/ .*/, ""); print; exit}' "$JAIL_RUN_DIR/logs/$name.log")"
printf '%s\t%s\t%s\t%s\n' "$rc" "$secs" "$rel" "${obtained:-unknown}" >> "$JAIL_RUN_DIR/results.tsv"
