#!/usr/bin/env bash
# tests/feature-2119-settings-allow-ssot.sh
# Tests: install/settings-allow-commands.txt, install/gen-settings-allow.js, bin/review-settings-allow, hooks/pre-commit, settings.json, docs/architecture/claude-code/settings.md
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2

set -uo pipefail

# THE INCIDENT. The permission engine matches allow rules against the WHOLE command string,
# so one internal tool spelled two ways is two patterns and the second one falls back to
# `ask`. settings.json carries seven hand-written rules for agents' own tools, and not one of
# the ten most-denied commands has a rule at all. What is missing is not "a rule" but "every
# spelling variant of each command" — the `$AGENTS_CONFIG_DIR` form, the two path forms, the
# bare form, the `bash -c` form, the `cd && ` form. Hand maintenance cannot track that.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# THE ROOT CAUSE is that "which internal command is allow-listed" exists only as ~150
# hand-typed strings inside settings.json, with the command, the interpreter and the spelling
# template smeared together in each one. Adding a command means remembering eight spellings;
# forgetting is silent, because the failure mode is a prompt in someone's future session
# rather than a red test today (CPR-SSOT: one canonical location owns the fact; CPR-E2C: the
# class is "agents-internal auto-issued command", not the ten sampled members).

SSOT_REL="install/settings-allow-commands.txt"
SSOT="$AGENTS_DIR/$SSOT_REL"
PATH_SSOT_REL="install/path-exposed-commands.txt"
PATH_SSOT="$AGENTS_DIR/$PATH_SSOT_REL"

# THE CONTRACT UNDER TEST. One declarative file, install/settings-allow-commands.txt, names
# the commands and nothing else — no interpreter (read from the shebang), no rule strings, no
# bare-form flag (decided by install/path-exposed-commands.txt). install/gen-settings-allow.js
# owns the template table in ONE place and expands each entry into 10 path spellings plus 3
# bare spellings for PATH-exposed commands; `--check` reports both missing AND orphaned
# entries, `--write` appends only. bin/review-settings-allow turns `--check` into a
# PERFORMED/FAIL binary and hooks/pre-commit blocks the commit on any non-zero — fail-closed,
# so deleting the gate cannot disable the gate.

GEN_REL="install/gen-settings-allow.js"
GEN="$AGENTS_DIR/$GEN_REL"
REVIEW_REL="bin/review-settings-allow"
REVIEW="$AGENTS_DIR/$REVIEW_REL"
SETTINGS_REL="settings.json"
SETTINGS="$AGENTS_DIR/$SETTINGS_REL"

# OUT OF SCOPE: install/path-exposed-commands.txt itself (read to decide bare forms, never
# copied and never modified); wrapper launchers such as bin/run-with-timeout.sh, whose
# trailing ` *` template would allow-list every command reachable through them; gh-write and
# git-state-changing commands; and the deployed ~/.claude/settings.json, which nothing here
# reads or writes.

PRECOMMIT="$AGENTS_DIR/hooks/pre-commit"

# LAYER. Static/structural, plus two fixture-driven integration families that never touch the
# real tree: the generator and the review script are COPIED into a temp fixture and run with
# cwd set there, and the pre-commit family runs the real hooks/pre-commit inside a throwaway
# repo that doubles as its own AGENTS_CONFIG_DIR. The only thing read from the real repo is
# text; the only real-repo execution is `--check`, which writes nothing.

PASS=0
FAIL=0
SKIP=0

# SKIPPED: asserting that the generated spellings actually stop the permission engine from
#          prompting — i.e. running each of the eight forms in a live Claude Code session.
# Because: an approved `ask` leaves no observable record, so a passive after-the-fact check
#          cannot distinguish "matched an allow rule" from "the user pressed yes".

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

# TL3 gap (what this test does NOT catch):
# - Whether the permission engine matches the generated spellings at all: rule matching is
#   the engine's behaviour, and it is exercised only by a real session.
# - Whether a spelling that matches here is the spelling the model actually issues.
# - Whether the `cd "$AGENTS_CONFIG_DIR" && ...` forms are needed — the non-splitting of `&&`
#   is taken from docs/architecture/claude-code/settings.md, not measured here.
# - Whether git really invokes hooks/pre-commit through core.hooksPath on the developer's box.
# Closest-to-action mitigation: live spot-check of one command per spelling family at the
# WORKFLOW_USER_VERIFIED preflight, before the PR is marked verified.

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name -- want [$want] got [$got]"; FAIL=$((FAIL + 1)); fi
}

# EXECUTED-ROW BUDGET. Every table-driven loop in the part files increments ROWS; T10 asserts
# the exact total. An empty table, a drifted heredoc delimiter or an early return in front of
# a loop otherwise leaves a file that counts only its failures reporting green.
ROWS=0
ROWS_EXPECTED=158  # T3a 3 + T3b 18 + T4 16 + T4-empty 2 + T4-dup 2 + T5 4 + T6 3 + T7b 2 + T7c 2
                   # + T11 4 + T12 3 + T25 6 + T13 15 + T14 10 + T15 3 + T16 5 + T17 12
                   # + T8 6 + T9 6 + T18 10 + T20 5 + T21 3 + T24 5 + T22 3 + T23 10

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/sa-2119.XXXXXX")" || { echo "FAIL: harness -- mktemp -d failed"; exit 1; }
trap 'rm -rf "$TMPROOT"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md): the plans dir is pinned in the same
# breath as anything workflow-shaped, and inherited session ids are dropped at each spawn
# site so a hook can never resolve the developer's live session.
WORKFLOW_PLANS_DIR="$TMPROOT/plans"
CLAUDE_WORKFLOW_DIR="$TMPROOT/workflow"
mkdir -p "$WORKFLOW_PLANS_DIR" "$CLAUDE_WORKFLOW_DIR"
export WORKFLOW_PLANS_DIR CLAUDE_WORKFLOW_DIR

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# The SSOT reader, shared by every structural case: one entry per line, `#` comments and
# blank lines dropped, trailing whitespace stripped -- the same shape the sibling
# install/path-exposed-commands.txt consumer reads.
ssot_entries() { # <file>
    [ -f "$1" ] || return 0
    sed -e 's/[[:space:]]*$//' "$1" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$'
}

# MISSING-ARTIFACT SENTINELS. A case whose implementation does not exist yet must fail with a
# message naming the artifact, never crash the run: the helpers below return a sentinel
# string that flows into assert_eq's "got" side, so the table keeps executing its rows and
# the T10 budget stays meaningful.
missing_gen()    { printf '<MISSING:%s>' "$GEN_REL"; }
missing_review() { printf '<MISSING:%s>' "$REVIEW_REL"; }

have_gen()    { [ -f "$GEN" ]; }
have_review() { [ -f "$REVIEW" ]; }

PART_DIR="$AGENTS_DIR/tests/feature-2119-settings-allow-ssot"

# home-canary.sh is sourced FIRST and only defines functions: canary_setup repoints HOME and
# every home-shaped variable at a seeded fixture BEFORE any other part spawns a subprocess, so
# no node/bash/git child in this suite can reach the developer's deployed ~/.claude/settings.json.
# T22 then compares that fixture after every other part has run.
. "$PART_DIR/home-canary.sh"
canary_setup

. "$PART_DIR/ssot-structure.sh"
. "$PART_DIR/generator.sh"
. "$PART_DIR/write-and-drift.sh"
. "$PART_DIR/settings-preservation.sh"
. "$PART_DIR/orphan-preservation.sh"
. "$PART_DIR/input-validation.sh"
. "$PART_DIR/orphan-classifier.sh"
. "$PART_DIR/cli-contract.sh"
. "$PART_DIR/review-script.sh"
. "$PART_DIR/review-diagnostics.sh"
. "$PART_DIR/precommit.sh"
. "$PART_DIR/precommit-real-commit.sh"
. "$PART_DIR/precommit-synchronized.sh"
. "$PART_DIR/docs-contract.sh"

t22_home_canary

assert_eq "T10: every table-driven loop executed its full row count (a short count means an empty or unreachable table reported green)" \
    "$ROWS_EXPECTED" "$ROWS"

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
