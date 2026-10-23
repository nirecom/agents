#!/usr/bin/env bash
# tests/hooks/feature-2631-precommit-size-gate/lane.sh — one parallel lane of
# tests/hooks/feature-2631-precommit-size-gate.sh. The whole file costs over 200 s serially on
# Windows, so the entry starts several lanes at once and replays their PASS / FAIL lines into its
# own case records.
# Usage: bash lane.sh <lane-tmp-dir> <case-name>=<function> ...
# Prints "@@CASE <case-name>" before each body and "@@DONE" after the last; a section with no
# closing @@ line tells the entry that the lane died inside that body.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$ROOT/tests/lib/harness.sh"

TMP_ROOT="$1"
readonly TMP_ROOT
shift
mkdir -p "$TMP_ROOT"
harness_isolate "$TMP_ROOT/iso"
harness_assert_isolated
unset CLAUDE_CODE_SESSION_ID CODE_FILE_EXTENSIONS 2>/dev/null || true
export CONFIRM_INTENT=on CONFIRM_OUTLINE=on CONFIRM_DETAIL=on COMMENT_BLOCK_ENFORCE=on

LANE_DIR="$ROOT/tests/hooks/feature-2631-precommit-size-gate"
# shellcheck source=fixture.sh
. "$LANE_DIR/fixture.sh"
# shellcheck source=cases-core.sh
. "$LANE_DIR/cases-core.sh"
# shellcheck source=cases-edges.sh
. "$LANE_DIR/cases-edges.sh"
# shellcheck source=git-commit-route.sh
. "$LANE_DIR/git-commit-route.sh"

for spec in "$@"; do
  printf '@@CASE %s\n' "${spec%%=*}"
  "${spec#*=}"
done
printf '@@DONE\n'
