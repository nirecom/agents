#!/usr/bin/env bash
# tests/prompt-bash-node-calling-convention.sh
# Tests: install/lib/settings-allow-rules.js, install/settings-allow-commands.txt, skills/review-tests/SKILL.md, hooks/bash-guard/judge.js
# Tags: prompt, permissions, calling-convention, ssot, scope:common, pwsh-not-required, TL2

set -uo pipefail

# THE SUBJECT. A permission allow rule matches the WHOLE command string, and every generated
# spelling puts a LITERAL interpreter token in execution position -- `bash "<path>"`, never
# `"<path>"` on its own. So a prompt asset that tells the model to run
# `"$AGENTS_CONFIG_DIR/bin/foo"` directly instructs a command line no rule can match, and the
# step falls back to `ask`. WHICH commands are in scope is owned by
# install/settings-allow-commands.txt (CPR-SSOT); the spellings by
# install/lib/settings-allow-rules.js; the calling convention the model is told to use, by the
# prompt assets themselves. This suite holds the three in agreement.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# WHY scope:common AND NOT feature-<N>: the invariant is class-level -- every entry in the
# SSOT, in every prompt asset, forever. Filed under an issue number it would be retired the
# day that issue closed, taking the only enforcement of the calling convention with it.

SSOT_REL="install/settings-allow-commands.txt"
SSOT="$AGENTS_DIR/$SSOT_REL"
LIB_REL_LIST="install/lib/settings-allow-rules.js"
LIB_DIR="$AGENTS_DIR/install/lib"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name -- want [$want] got [$got]"; FAIL=$((FAIL + 1)); fi
}

# SKIPPED: proving in a live session that the convention the prompt assets state is the one the
#          model then issues, and that the matching rule really suppresses the prompt.
# Because: an approved `ask` leaves no observable record, so nothing after the fact can tell
#          "matched an allow rule" from "the user pressed yes". Same reason as #2119's suite.

ROWS=0

# TL3 gap (what this test does NOT catch):
# - Whether the permission engine matches the spellings the assets now instruct -- rule matching
#   is the engine's behaviour and only a real session exercises it.
# - Whether the model, reading the hardened prose, actually issues the instructed spelling.
# - Prompt assets outside the four scanned classes (agents/*.md, rules/*.md,
#   skills/_shared/*.md, skills/**/SKILL.md) are out of the sweep's scope by construction.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.

# EXECUTED-ROW BUDGET. Every table-driven loop in the part files increments ROWS; the final
# assertion pins the exact total, so an empty table or an early return cannot report green.
ROWS_EXPECTED=132 # T26 27 + T48 37 + T50 4 + T51 6 + T52 7 + T53 3 + T54 5 + T55 6
                  # + T56 4 + T57 5 + T58 9 + T59 8 + T60 8 + T22 3

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/pbn-cc.XXXXXX")" || { echo "FAIL: harness -- mktemp -d failed"; exit 1; }
trap 'rm -rf "$TMPROOT"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md): the plans dir is pinned in the same
# breath as anything workflow-shaped, and inherited session ids are dropped so a hook reached
# through a child process can never resolve the developer's live session.
WORKFLOW_PLANS_DIR="$TMPROOT/plans"
CLAUDE_WORKFLOW_DIR="$TMPROOT/workflow"
mkdir -p "$WORKFLOW_PLANS_DIR" "$CLAUDE_WORKFLOW_DIR"
export WORKFLOW_PLANS_DIR CLAUDE_WORKFLOW_DIR
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# MISSING-ARTIFACT SENTINEL. A case whose implementation does not exist yet must fail with a
# message naming the artifact, never crash the run: the helper returns a sentinel string that
# flows into assert_eq's "got" side, so the table keeps executing and the budget stays meaningful.
missing_lib() { printf '<MISSING:%s>' "$LIB_REL_LIST"; }
have_lib() { [ -f "$LIB_DIR/settings-allow-rules.js" ]; }

PART_DIR="$AGENTS_DIR/tests/prompt-bash-node-calling-convention"

# home-canary.sh is sourced FIRST and only defines functions: canary_setup repoints HOME and
# every home-shaped variable at a seeded fixture BEFORE any other part spawns a subprocess.
# This suite's subject is a READ-ONLY scan, so T22 is the PROOF of that claim rather than a
# guard against a known writer: it compares the fixture after every other part has run.
. "$PART_DIR/home-canary.sh"
canary_setup

. "$PART_DIR/template-pairs.sh"
. "$PART_DIR/rt0-calling-convention.sh"
. "$PART_DIR/exec-position-fixtures.sh"
. "$PART_DIR/exec-position-sweep.sh"
. "$PART_DIR/legacy-p2p3-coverage.sh"

t22_home_canary

assert_eq "TOTAL: every table-driven loop executed its full row count (a short count means an empty or unreachable table reported green)" \
    "$ROWS_EXPECTED" "$ROWS"

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
