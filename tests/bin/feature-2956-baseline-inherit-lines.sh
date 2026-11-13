#!/usr/bin/env bash
# tests/bin/feature-2956-baseline-inherit-lines.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, inherit, ledger, scope:issue-specific, pwsh-not-required, TL2
# #2956 S6 - inheritance compares too: b1 has fail rows, then main changes only src/v.txt, so
# `git diff b1 B2 -- t d/` is empty. t.sh puts v.txt into its detail, so the branch has a line b1
# lacks (R) and the base runs at B2 instead of inheriting; x.sh has no such line and is inherited.
# TL3 gap: inheritance across a real multi-week main history is out of scope.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2688-branch-rerun/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-2688-branch-rerun/_lib.sh"
# shellcheck source=tests/bin/feature-2956-baseline-ledger-paths/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-2956-baseline-ledger-paths/_lib.sh"

I="$TMPROOT/inh"; IM="$I.marks"; lp_repo "$I"; mkdir -p "$I.cache" "$I/src"
printf 'one\n' > "$I/src/v.txt"
lp_body "$(np "$IM")" t "a" 1 "a" 1 '$(cat "$r/src/v.txt")' > "$I/tests/bin/t.sh"
lp_body "$(np "$IM")" x "a" 1 "a" 1 > "$I/tests/bin/x.sh"
lp_publish "$I" "add t x"
seed "inh1-$$" '{"tests/bin/t.sh":1,"tests/bin/x.sh":1}' tests/bin/t.sh tests/bin/x.sh
rtb "$I.cache" "$I" "inh1-$$"

case_begin "b1-records-fail-rows" "bin/run-tests-baseline"
ck "b1: exit 0" 0 "$RTB_RC"
present "b1: the base ran for t" "$IM/base-t"
present "b1: the base ran for x" "$IM/base-x"
case_end

rm -f "$IM"/*
git -C "$I" checkout -q main
printf 'two\n' > "$I/src/v.txt"
lp_publish "$I" "B2 changes v.txt"
seed "inh2-$$" '{"tests/bin/t.sh":1,"tests/bin/x.sh":1}' tests/bin/t.sh tests/bin/x.sh
rtb "$I.cache" "$I" "inh2-$$"

case_begin "inherit-without-new-lines-is-inherited" "bin/run-tests-baseline"
ck "B2: exit 0" 0 "$RTB_RC"
has_line "x: no new lines - inherited" "BASELINE: preexisting-inherited tests/bin/x.sh"
absent "x: inherited without a base run" "$IM/base-x"
case_end

case_begin "inherit-with-new-lines-goes-to-the-base-run" "bin/run-tests-baseline"
present "t: new lines against b1 - the base ran at B2" "$IM/base-t"
has_line "t: preexisting at B2" "BASELINE: preexisting tests/bin/t.sh"
lacks_line "t: not inherited" "BASELINE: preexisting-inherited tests/bin/t.sh"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
