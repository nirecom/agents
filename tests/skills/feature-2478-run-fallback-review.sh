#!/usr/bin/env bash
# Tests: skills/review-tests/scripts/run-fallback-review.sh
# Tags: feature-2478, review-tests, codex-review-loop, cc-fallback, prestaged, scope:issue-specific, TL2
#
# #2478 S3-3: after the review-tests wrapper ends exit 3 (codex unusable), run-fallback-review.sh
# drives the CC-fallback round through the same wrapper: --brief prints FALLBACK_ROUND=<n> without
# counting a round, and <report> forwards the test-reviewer report as a prestaged ADVANCE, which
# records one cc-fallback row and replaces the rc 3 marker. The real wrapper and loop run here.
# TL3 gap: the real test-reviewer agent writing the report in a live session (the report is stubbed).

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2937-review-loop/fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2937-review-loop/fixture.sh"
# shellcheck source=tests/bin/feature-2478-fallback/helpers.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2478-fallback/helpers.sh"

# The review-scope fingerprint is taken from the staged diff: stage a test and its target.
mkdir -p "$REPO/hooks"
printf '#!/usr/bin/env bash\n# Tests: hooks/impl.js\n' > "$REPO/tests/fb.sh"
printf 'impl\n' > "$REPO/hooks/impl.js"
git -C "$REPO" add tests/fb.sh hooks/impl.js

F=test-review
FRS="$ROOT/skills/review-tests/scripts/run-fallback-review.sh"
term() { printf '%s/test-review-terminal.txt' "$(ctl "$1")"; }
line1() { if [ -f "$1" ]; then sed -n '1p' "$1" | tr -d '\r'; else printf 'absent'; fi; }

# frs <sid> [args...] — the real run-fallback-review.sh, as the skill runs it (sets S_RC / S_OUT / S_ERR).
frs() {
    local sid="$1" errf="$FX_TMP/frs.err"
    shift
    S_RC=0
    S_OUT="$( cd "$REPO" || exit 1
        export AGENTS_MAIN_ROOT="$ROOT"
        SESSION_ID="$sid" PLANS_DIR="$P" EXTENSIONS_USED=0 bash "$FRS" "$@" 2>"$errf"
    )" || S_RC=$?
    S_ERR="$(cat "$errf" 2>/dev/null)"
}

# exit3 <sid> — codex unusable: the wrapper ends exit 3 and leaves the rc 3 marker.
exit3() {
    seed_sid "$1"
    st seed "$1"
    FX_RV=1 wrap review-tests "$1"
    assert_eq "$1 setup: the wrapper exits 3" "3" "$W_RC"
    assert_eq "$1 setup: the rc 3 marker is armed" "3" "$(line1 "$(term "$1")")"
}

echo "=== S3-3: run-fallback-review.sh exists in the skill ==="
case_begin "run-fallback-review-script-is-shipped" "skills/review-tests/scripts/run-fallback-review.sh"
assert_eq "run-fallback-review.sh is present beside the wrapper" "present" "$(clf_file_state "$SCRIPT_CHECKOUT_ROOT/skills/review-tests/scripts/run-fallback-review.sh")"
case_end

echo "=== S3-3 --brief: the fallback round is named, nothing is counted ==="
case_begin "brief-after-exit3-names-round-1" "skills/review-tests/scripts/run-fallback-review.sh"
exit3 brf
frs brf --brief
assert_eq "--brief: exit 0" "0" "$S_RC"
assert_eq "--brief: the first line is FALLBACK_ROUND=1" "FALLBACK_ROUND=1" "$(printf '%s\n' "$S_OUT" | tr -d '\r' | sed -n '1p')"
assert_eq "--brief counts no round" "absent" "$(clf_read "$(round_file brf "$F")")"
assert_eq "--brief adds no row" "0" "$(rows brf "$F")"
assert_eq "--brief keeps the rc 3 marker" "3" "$(line1 "$(term brf)")"
case_end

echo "=== S3-3 <report>: the fallback report becomes one counted round ==="
case_begin "report-after-exit3-records-one-fallback-round" "skills/review-tests/scripts/run-fallback-review.sh"
exit3 rep
RAW="$(raw_of rep "$F")"
report "$RAW" NEEDS_REVISION "C1. [HIGH] the fallback round is not counted"
FX_RV=1 frs rep "$RAW"
assert_eq "<report> NEEDS_REVISION: exit 1 (continue)" "1" "$S_RC"
assert_not_contains "<report> is not refused by the terminal guard" "terminal exit" "$S_ERR"
assert_not_contains "<report> is accepted as a prestaged producer" "not permitted" "$S_ERR"
assert_eq "<report>: exactly one row" "1" "$(rows rep "$F")"
assert_eq "<report>: the row is the fallback's" "cc-fallback" "$(row rep "$F" 1 source)"
assert_eq "<report>: ROUND_FILE is 1" "1" "$(clf_read "$(round_file rep "$F")")"
assert_eq "<report>: the rc 3 marker is removed" "absent" "$(line1 "$(term rep)")"
case_end

finish
