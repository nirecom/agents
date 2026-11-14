#!/usr/bin/env bash
# Tests: skills/make-outline-plan/scripts/run-codex-review-loop.sh, skills/make-detail-plan/scripts/run-codex-review-loop.sh, skills/review-plan-security/scripts/run-codex-review-loop.sh, skills/review-code-security/scripts/run-codex-review-loop.sh, skills/review-tests/scripts/run-codex-review-loop.sh
# Tags: feature-2938, review-record, codex-review-loop, fingerprint, scope:issue-specific, TL2, dup-group-keep:time-hard-limit
#
# #2938 T5-12: every stage wrapper hands the loop the reviewed-input fingerprint, so the
# first row of a fresh session (no terminal file yet) carries one in all five formats,
# security-code's prestaged ADVANCE row too; when git cannot hash the input the row
# carries fingerprint=null and the wrapper says so on stderr.
# TL3 gap: a real codex CLI round is not run; the reviewer is the stub of tests/bin/feature-2937-review-loop/fixture.sh.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2937-review-loop/fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2937-review-loop/fixture.sh"

NULL_WARN="warning: reviewed-input fingerprint unavailable; the review record row will carry fingerprint=null"
# A git whose hash-object always fails; every other subcommand is the real git.
REAL_GIT="$(command -v git)"
SHIM="$FX_TMP/git-shim"
mkdir -p "$SHIM"
printf '#!/usr/bin/env bash\n[ "${1:-}" = hash-object ] && exit 1\nexec %q "$@"\n' "$REAL_GIT" > "$SHIM/git"
chmod +x "$SHIM/git"

# has_fp <label> <sid> <fmt> — the last row of the record has a non-null fingerprint.
has_fp() {
    local fp
    fp="$(row "$2" "$3" -1 fingerprint)"
    if [ -n "$fp" ] && [ "$fp" != null ]; then pass "$1"; else fail "$1" "fingerprint=${fp:-<no row>}"; fi
}

case_begin "t5-12-plan-wrappers-record-a-fingerprint" "skills/make-detail-plan/scripts/run-codex-review-loop.sh"
for pair in make-outline-plan:outline-plan make-detail-plan:detail-plan review-plan-security:security-plan; do
    skill="${pair%%:*}"; fmt="${pair#*:}"; sid="fp-$skill"
    seed_sid "$sid"
    st seed "$sid"
    wrap "$skill" "$sid"
    assert_ne "$skill runs (precondition, not HALT)" "4" "$W_RC"
    has_fp "$skill: the first row carries a fingerprint" "$sid" "$fmt"
done
case_end

case_begin "t5-12-review-tests-records-a-fingerprint" "skills/review-tests/scripts/run-codex-review-loop.sh"
seed_sid fp-rt
st seed fp-rt
# review-tests fingerprints the staged diff only; the fixture's change is committed, so stage one.
printf '#!/usr/bin/env bash\necho staged\n' > "$REPO/tests/t-staged.sh"
git -C "$REPO" add tests/t-staged.sh
wrap review-tests fp-rt
git -C "$REPO" rm -q --cached tests/t-staged.sh
rm -f "$REPO/tests/t-staged.sh"
assert_ne "review-tests runs (precondition, not HALT)" "4" "$W_RC"
has_fp "review-tests: the first row carries a fingerprint" fp-rt test-review
case_end

case_begin "t5-12-security-code-codex-and-prestaged-rows-record-a-fingerprint" "skills/review-code-security/scripts/run-codex-review-loop.sh"
seed_sid fp-sc
st seed fp-sc
wrap review-code-security fp-sc
assert_ne "review-code-security runs (precondition, not HALT)" "4" "$W_RC"
has_fp "security-code: the codex row carries a fingerprint" fp-sc security-code
seed_sid fp-scp
st seed fp-scp
export FX_RV=1
wrap review-code-security fp-scp
unset FX_RV
assert_eq "codex failure is exit 3 (precondition)" "3" "$W_RC"
REP="$FX_TMP/fp-scanner.txt"
delta "$REP" HIGH "[HIGH] C1 | reviewed.txt#5 | correctness | unchecked input reaches the shell"
W_RC=0
W_OUT="$( cd "$REPO" || exit 1
    export AGENTS_MAIN_ROOT="$ROOT"
    SESSION_ID=fp-scp PLANS_DIR="$P" EXTENSIONS_USED=0 bash "$ROOT/skills/review-code-security/scripts/run-codex-review-loop.sh" \
        --prestaged-report "$REP" --prestaged-producer security-scanner --prestaged-exec PERFORMED 2>"$FX_TMP/wrap.err"
)" || W_RC=$?
assert_ne "the prestaged ADVANCE runs (precondition, not HALT)" "4" "$W_RC"
has_fp "security-code: the prestaged ADVANCE row carries a fingerprint" fp-scp security-code
case_end

case_begin "t5-12-unhashable-input-records-null-and-warns" "skills/review-plan-security/scripts/run-codex-review-loop.sh"
seed_sid fp-null
st seed fp-null
PATH="$SHIM:$PATH" wrap review-plan-security fp-null
assert_ne "review-plan-security runs without a hash (precondition, not HALT)" "4" "$W_RC"
assert_eq "the row carries fingerprint=null" "null" "$(row fp-null security-plan -1 fingerprint)"
assert_contains "and the wrapper warns" "$NULL_WARN" "$W_ERR"
case_end

finish
