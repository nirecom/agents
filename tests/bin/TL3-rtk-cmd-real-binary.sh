#!/bin/bash
# tests/bin/TL3-rtk-cmd-real-binary.sh
# Tests: bin/rtk-cmd
# Tags: rtk, wrapper, bin, tl3, scope:common, dup-group-keep:distinct-layer

# Skip gates — evaluated before set -euo pipefail
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v rtk >/dev/null 2>&1 || exit 77
"$AGENTS_DIR/bin/get-config-var" --is-off RUN_TL3 off && exit 77
[ -x "$AGENTS_DIR/bin/rtk-cmd" ] || exit 77

# TL3 gap (future extension):
# - Verify rtk's actual output compression quality and audit-log evidence
#   (e.g., hooks/lib/rtk-guard-audit.js log entry parsing).
# - Verify native rtk binary behavior beyond the minimal contract below.
# Current minimal contract: exit 0 + non-empty output.

set -euo pipefail

# Shared harness: pass/fail reporters + PASS/FAIL counters + session-ID unset.
. "$AGENTS_DIR/tests/lib/harness.sh"

TMPDIR_T="$(make_tmp)"
trap 'rm -rf "$TMPDIR_T"' EXIT

# (j) RTK=on, real rtk from PATH, run bin/rtk-cmd git log --oneline -1
ec_j=0
out_j=$(env RTK=on AGENTS_CONFIG_DIR="$AGENTS_DIR" \
  "$AGENTS_DIR/bin/rtk-cmd" git log --oneline -1 2>&1) || ec_j=$?

if [[ "$ec_j" -eq 0 ]]; then
  pass "(j) real rtk: exit 0"
else
  fail "(j) real rtk: expected exit 0, got ec=$ec_j"
fi

if [[ -n "$out_j" ]]; then
  pass "(j) real rtk: output non-empty"
else
  fail "(j) real rtk: expected non-empty output, got empty"
fi

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
