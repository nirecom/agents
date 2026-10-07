#!/usr/bin/env bash
# tests/skills/feature-2079-run-tests-calibration-offer.sh
# Tests: skills/run-tests/scripts/probe-calibration.sh, skills/run-tests/scripts/mark-calibration-asked.sh, skills/run-tests/scripts/answer-calibration.sh, skills/run-tests/scripts/lib/calibration-offer.sh, skills/run-tests/SKILL.md, install/settings-allow-commands.txt, bin/lib/run-all-parallelism.sh
# Tags: run-tests, calibration, never-ask, session-marker, allowlist, security, TL2, scope:issue-specific
# Dispatcher for #2079 R1-R3: /run-tests offers calibration once per session (probe / mark /
# answer), the never-ask record silences it per host, and the printed hint opens the gate.
# TL3 gap (what this test does NOT catch):
# - the live AskUserQuestion dialog and the Bash run_in_background completion notice in RNT-6a
# - a real 90-minute calibration on a multi-core host (P9 replaces the measurement by the seam)
# Mitigation: WORKFLOW_USER_VERIFIED preflight runs /run-tests once on an uncalibrated host.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"
GROUP_DIR="$AGENTS_DIR/tests/skills/feature-2079-run-tests-calibration-offer"
SCRIPTS_DIR="$AGENTS_DIR/skills/run-tests/scripts"
PROBE="$SCRIPTS_DIR/probe-calibration.sh"
MARK="$SCRIPTS_DIR/mark-calibration-asked.sh"
ANSWER="$SCRIPTS_DIR/answer-calibration.sh"
CO_LIB="$SCRIPTS_DIR/lib/calibration-offer.sh"
SKILL_MD="$AGENTS_DIR/skills/run-tests/SKILL.md"
ALLOW_TXT="$AGENTS_DIR/install/settings-allow-commands.txt"
PAR_LIB="$AGENTS_DIR/bin/lib/run-all-parallelism.sh"

TMPROOT="$(make_tmp)"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
trap 'chmod -R u+rwX "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT"' EXIT

# ── Fixture isolation (rules/test/fixture-isolation.md) ─────────────────────
harness_isolate "$TMPROOT/iso"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPROOT/transcripts"
export HOME="$TMPROOT/home"
export TMPDIR="$TMPROOT/tmp"
export RUN_ALL_CACHE_DIR="$TMPROOT/cache-default"
# A nonexistent resolver skips the .env layer, so the developer's .env never decides a value.
export RUN_ALL_CONFIG_VAR_CMD="$TMPROOT/no-such-config-var-cmd"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR" "$HOME" "$TMPDIR" "$RUN_ALL_CACHE_DIR"
unset RUN_CALIBRATION RUN_ALL_CALIBRATION_MEASURE_CMD TEST_MAX_JOBS_PER_HOST TEST_MAX_JOBS_PER_RUN \
    TEST_LANES TEST_LANES_HELD TESTS_DIR CONFIRM_INTENT CONFIRM_OUTLINE CONFIRM_DETAIL \
    RUN_TL3 GIT_DIR GIT_WORK_TREE 2>/dev/null || true
CACHE="$RUN_ALL_CACHE_DIR"
NEUTRAL_DIR="$TMPROOT/neutral"
mkdir -p "$NEUTRAL_DIR"

GRP_DONE=""
grp_done() { GRP_DONE="${GRP_DONE}$1"$'\n'; }
CASE_RAN=""
case_ran() { CASE_RAN="${CASE_RAN} $1"; }
# ck <name> <want> <got>
ck() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$(printf '%q' "$2") got=$(printf '%q' "$3")"; fi; }
p0_exists() { if [ -f "$2" ]; then pass "P0 $1 exists"; else fail "P0 $1 missing (not implemented yet)"; fi; }

# ── Preconditions: one existence case per Tests-header path ─────────────────
case_begin "probe-script-exists" "skills/run-tests/scripts/probe-calibration.sh"
p0_exists "probe-calibration.sh" "$PROBE"
case_end

case_begin "mark-script-exists" "skills/run-tests/scripts/mark-calibration-asked.sh"
p0_exists "mark-calibration-asked.sh" "$MARK"
case_end

case_begin "answer-script-exists" "skills/run-tests/scripts/answer-calibration.sh"
p0_exists "answer-calibration.sh" "$ANSWER"
case_end

case_begin "offer-lib-exists" "skills/run-tests/scripts/lib/calibration-offer.sh"
p0_exists "lib/calibration-offer.sh" "$CO_LIB"
case_end

# ── Case files ──────────────────────────────────────────────────────────────
# shellcheck source=feature-2079-run-tests-calibration-offer/_fixture.sh
. "$GROUP_DIR/_fixture.sh"
# shellcheck source=feature-2079-run-tests-calibration-offer/probe-cases.sh
. "$GROUP_DIR/probe-cases.sh"
# shellcheck source=feature-2079-run-tests-calibration-offer/answer-cases.sh
. "$GROUP_DIR/answer-cases.sh"
# shellcheck source=feature-2079-run-tests-calibration-offer/security-cases.sh
. "$GROUP_DIR/security-cases.sh"
# shellcheck source=feature-2079-run-tests-calibration-offer/static-cases.sh
. "$GROUP_DIR/static-cases.sh"
# shellcheck source=feature-2079-run-tests-calibration-offer/hint-gate-cases.sh
. "$GROUP_DIR/hint-gate-cases.sh"

case_begin "suite-integrity" "skills/run-tests/scripts/probe-calibration.sh"
GRP_PRESENT="$(ls -1 "$GROUP_DIR" 2>/dev/null | grep '\.sh$' | LC_ALL=C sort | tr '\n' ' ')"
GRP_SOURCED="$(sed -n 's|^\. "\$GROUP_DIR/\(.*\.sh\)"$|\1|p' "${BASH_SOURCE[0]}" | LC_ALL=C sort | tr '\n' ' ')"
GRP_FINISHED="$(printf '%s' "$GRP_DONE" | grep -v '^$' | LC_ALL=C sort | tr '\n' ' ')"
ck "GRP1 every case file is sourced and every sourced case file exists" "$GRP_PRESENT" "$GRP_SOURCED"
ck "GRP2 every sourced case file ran to its completion marker" "$GRP_SOURCED" "$GRP_FINISHED"
CASE_MISSING=""
for _c in P1 P2 P3 P4 P5 P6 P7 P8 P9 P10 P11 P12 P13 P14 S1 S2 S3 S4 S5 A1 I1; do
    case " $CASE_RAN " in *" $_c "*) ;; *) CASE_MISSING="${CASE_MISSING:+$CASE_MISSING }$_c" ;; esac
done
ck "CASE1 every planned case id ran" "" "$CASE_MISSING"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
