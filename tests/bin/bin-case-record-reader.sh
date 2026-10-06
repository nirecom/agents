#!/usr/bin/env bash
# tests/bin/bin-case-record-reader.sh
# Tests: bin/lib/case-record-reader.sh, bin/lib/test-language-parts/bash-case-embed.sh
# Tags: TL2, bin, case-markers, test-language-registry, sweep-tests, scope:common
# crr_read is the one window onto a test file's case records (FILE/CASE TSV); the bash
# caseEmbedRules part answers the per-language questions the embed verifier asks. Cases
# live in tests/bin/bin-case-record-reader/*.sh; fixture registries are installed as the
# default table of a fixture checkout (the loader has no env override).
# TL3 gap: real corpus files (mixed heredocs, eval, sourced helpers) are only seen when
# the first band is embedded in a later PR; here every input is a small fixture.
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$AGENTS_DIR/tests/lib/harness.sh"

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
. "$AGENTS_DIR/bin/lib/run-all-launch.sh"
run_all_pin_state_dirs "$TMPBASE/state" || { echo "FAIL: cannot pin state dirs"; exit 1; }
export RUN_ALL_DURATIONS_LIB=/nonexistent RUN_ALL_PROGRESS=off

# fx_checkout / fx_table_edit: the registry suite's fixture-checkout helpers (one owner).
# shellcheck source=test-language-registry/_lib.sh
. "$AGENTS_DIR/tests/bin/test-language-registry/_lib.sh"

CRR_CASES="$AGENTS_DIR/tests/bin/bin-case-record-reader"
FXD="$TMPBASE/fx"
mkdir -p "$FXD"
T=$'\t'

# crr <checkout> <file> — crr_read in a fresh bash that sourced only that checkout's
# case-record-reader.sh (the library must pull in what it needs). Sets CRR_RC / CRR_OUT.
crr() {
  CRR_RC=0
  CRR_OUT="$(run_with_timeout 120 bash -c '. "$1/bin/lib/case-record-reader.sh" || exit 97; crr_read "$2"' _ "$1" "$2" 2>"$TMPBASE/crr.err")" || CRR_RC=$?
}

# op <checkout> <file> <op> [args...] — crr_read <file>, then in the SAME shell the bash
# caseEmbedRules part through the registry (the same-shell contract). Sets OP_RC / OP_OUT.
op() {
  local co="$1"
  shift
  OP_RC=0
  OP_OUT="$(run_with_timeout 120 bash -c '. "$1/bin/lib/case-record-reader.sh" || exit 97
f="$2"; shift 2
crr_read "$f" >/dev/null
tlr_call_part bash caseEmbedRules "$@"' _ "$co" "$@" 2>"$TMPBASE/op.err")" || OP_RC=$?
}

# file_line <crr-output> — the FILE line's fields as "state|line|reason".
file_line() {
  printf '%s\n' "$1" | awk -F'\t' '$1 == "FILE" { print $2 "|" $3 "|" $4; exit }'
}

case_begin "reader-library-present" "bin/lib/case-record-reader.sh"
got="$(bash -c '. "$1" || exit 97; declare -F crr_read >/dev/null && echo defined' _ "$AGENTS_DIR/bin/lib/case-record-reader.sh" 2>/dev/null)"
assert_eq "crr_read: ${got:-missing}" "crr_read: defined"
case_end

case_begin "embed-part-registered-for-bash" "bin/lib/test-language-parts/bash-case-embed.sh"
got="$(bash -c '. "$1/bin/lib/test-language-registry.sh"; tlr_load || exit 96; tlr_field bash caseEmbedRules.file; tlr_field bash caseEmbedRules.function' _ "$AGENTS_DIR" 2>/dev/null | tr '\n' ' ')"
assert_eq "$got" "bin/lib/test-language-parts/bash-case-embed.sh bash_case_embed "
case_end

# shellcheck source=bin-case-record-reader/fixtures.sh
. "$CRR_CASES/fixtures.sh"
# shellcheck source=bin-case-record-reader/reader.sh
. "$CRR_CASES/reader.sh"
# shellcheck source=bin-case-record-reader/ops.sh
. "$CRR_CASES/ops.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
