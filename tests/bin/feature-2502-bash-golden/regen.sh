#!/usr/bin/env bash
# tests/bin/feature-2502-bash-golden/regen.sh
# Tests: bin/lib/case-record-reader.sh
# Tags: TL2, case-markers, golden, scope:issue-specific
# Rewrites expected/<kind>.tsv from the current code: `bash tests/bin/feature-2502-bash-golden/regen.sh`.
# Run it by hand only when a bash result is meant to change, and show the rewrite in the PR
# diff. The golden test never calls it.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=../../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMPBASE="$(make_tmp)"
trap 'rm -rf "$TMPBASE"' EXIT
export HOME="$TMPBASE/home"
mkdir -p "$HOME"
export NO_LOG=true
# shellcheck source=../../../bin/lib/run-all-launch.sh
. "$SCRIPT_CHECKOUT_ROOT/bin/lib/run-all-launch.sh"
harness_isolate "$TMPBASE/state"
export RUN_ALL_DURATIONS_LIB=/nonexistent RUN_ALL_PROGRESS=off

# shellcheck source=../test-language-registry/_lib.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/test-language-registry/_lib.sh"
# shellcheck source=record.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2502-bash-golden/record.sh"

gb_build "$TMPBASE/co"
if [ -n "$GB_BUILD_ERR" ]; then
  echo "regen.sh: missing inputs: $GB_BUILD_ERR" >&2
  exit 1
fi
gb_record_all "$TMPBASE/co" "$TMPBASE/rec" || { echo "regen.sh: a kind was not recorded" >&2; exit 1; }
mkdir -p "$GB_DIR/expected"
for kind in $GB_KINDS; do
  cp "$TMPBASE/rec/$kind.tsv" "$GB_DIR/expected/$kind.tsv"
  echo "regen.sh: expected/$kind.tsv ($(grep -c . "$GB_DIR/expected/$kind.tsv") rows)"
done
