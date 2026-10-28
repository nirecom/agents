#!/usr/bin/env bash
# tests/bin/feature-2502-bash-golden.sh
# Tests: bin/lib/case-record-reader.sh, bin/lib/test-language-parts/bash-case-embed.sh, bin/lib/test-retire-predicate/case-parser.sh, bin/lib/test-retire-predicate.sh, bin/check-case-markers.sh, bin/verify-case-embed.sh
# Tags: TL2, bin, case-markers, sweep-tests, golden, scope:issue-specific
# The bash results pinned before #2502 / #2712 change the shared case modules: crr_read,
# the bash caseEmbedRules ops, trp_enumerate_cases, trp_remove_orphan_cases,
# check-case-markers.sh and the static checks of verify-case-embed.sh, over the inputs of
# tests/bin/feature-2502-bash-golden/sample-list.txt. Each kind is compared byte for byte with
# expected/<kind>.tsv. regen.sh rewrites expected/ (never run here); a rewrite shows in the PR diff.
# TL3 gap: the bash corpus beyond the pinned samples is only seen when the sweep runs on it.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

TMPBASE="$(make_tmp)"
trap 'rm -rf "$TMPBASE"' EXIT
export HOME="$TMPBASE/home"
mkdir -p "$HOME"
export NO_LOG=true
# shellcheck source=../../bin/lib/run-all-launch.sh
. "$SCRIPT_CHECKOUT_ROOT/bin/lib/run-all-launch.sh"
harness_isolate "$TMPBASE/state"
export RUN_ALL_DURATIONS_LIB=/nonexistent RUN_ALL_PROGRESS=off

# fx_root_decoy / same_text: the registry suite's helpers (one owner).
# shellcheck source=test-language-registry/_lib.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/test-language-registry/_lib.sh"
# shellcheck source=feature-2502-bash-golden/record.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2502-bash-golden/record.sh"

GCO="$TMPBASE/co"
gb_build "$GCO"
GB_REC_RC=0
gb_record_all "$GCO" "$TMPBASE/rec" || GB_REC_RC=$?

# golden <label> <kind> — the recorded <kind> compared with expected/.
golden() {
  same_text "$1: $2 matches expected/$2.tsv" "$TMPBASE/rec/$2.tsv" "$GB_DIR/expected/$2.tsv"
}

case_begin "inputs-all-present" "bin/lib/case-record-reader.sh"
# Every sample-list row became an input; a missing fixture or blob would shrink the golden.
assert_eq "missing inputs: [$GB_BUILD_ERR]" "missing inputs: []"
want="$(grep -cE '^(crr|vce|ec|repo)\|' "$GB_DIR/sample-list.txt")"
assert_eq "inputs=${#GB_INPUTS[@]}" "inputs=$want"
roles="$(awk -F'|' '$1 == "repo" { print $5 }' "$GB_DIR/sample-list.txt" | sort | uniq -c | awk '{ print $2 "=" $1 }' | tr '\n' ' ')"
assert_eq "repo sample roles: $roles" "repo sample roles: markers=1 no-markers=1 table-driven=1 "
assert_eq "every kind recorded: rc=$GB_REC_RC" "every kind recorded: rc=0"
case_end

case_begin "crr-read-output" "bin/lib/case-record-reader.sh"
golden "crr_read" crr-read
case_end

case_begin "bash-embed-ops-output" "bin/lib/test-language-parts/bash-case-embed.sh"
golden "deps / leftover-defs / self-impl / skip-reason" embed-ops
case_end

case_begin "enumerate-cases-globals" "bin/lib/test-retire-predicate/case-parser.sh"
golden "trp_enumerate_cases" enumerate-cases
case_end

case_begin "remove-orphan-cases-rewrite" "bin/lib/test-retire-predicate.sh"
golden "trp_remove_orphan_cases" remove-orphan
case_end

case_begin "check-case-markers-stdout-and-rc" "bin/check-case-markers.sh"
golden "check-case-markers.sh" check-case-markers
case_end

case_begin "verify-case-embed-static-checks" "bin/verify-case-embed.sh"
golden "verify-case-embed.sh checks 1/3/4/5" verify-static
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
