#!/usr/bin/env bash
# run-one.sh <test-rel> — EXPERIMENTAL (#2585). One test through run-jailed.sh: a log under
# $JAIL_RUN_DIR/logs and one "rc<TAB>secs<TAB>test" line in $JAIL_RUN_DIR/results.tsv.
# JAIL_TREE / JAIL_PIN / JAIL_SECS select the tree, pin mode and timeout (run-list.sh sets them).
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

: "${JAIL_RUN_DIR:?JAIL_RUN_DIR is required}"
rel="${1:?test path required}"
name="${rel//\//__}"
start=$SECONDS
bash "$SCRIPT_CHECKOUT_ROOT/experimental/test-jail/run-jailed.sh" \
    --tree "${JAIL_TREE:-$SCRIPT_CHECKOUT_ROOT}" --pin "${JAIL_PIN:-full}" --timeout "${JAIL_SECS:-300}" \
    "$rel" > "$JAIL_RUN_DIR/logs/$name.log" 2>&1
rc=$?
printf '%s\t%s\t%s\n' "$rc" "$((SECONDS - start))" "$rel" >> "$JAIL_RUN_DIR/results.tsv"
