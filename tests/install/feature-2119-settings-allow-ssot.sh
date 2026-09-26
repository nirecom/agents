#!/usr/bin/env bash
# tests/feature-2119-settings-allow-ssot.sh
# Tests: install/settings-allow-commands.txt, hooks/lib/allow-command-list.js, install/lib/settings-assembly.js, install/lib/settings-deploy.js, install/assemble-settings.js, hooks/lib/settings-drift.js, hooks/post-merge, hooks/post-checkout, settings.json, docs/architecture/claude-code/settings.md
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2

set -uo pipefail

# THE INCIDENT. The permission engine matches an allow rule against the WHOLE command string,
# so one internal tool spelled two ways is two patterns and the second one falls back to
# `ask`. Every generated spelling ended in ` *`, and a trailing ` *` demands the space in
# front of it -- so `Bash(node bin/workflow/next-step *)` never matched the argument-less
# `node bin/workflow/next-step` the model actually issues. Measured denials confirmed it.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# THE ROOT CAUSE has two halves. (1) Each spelling family had only its argument-bearing form,
# so the argument-less invocation had no rule at all. (2) The rules lived in the repository's
# own settings.json, where "which internal command is allow-listed" was ~150 hand-typed
# strings a human had to keep in step with the SSOT (CPR-SSOT: one canonical location owns
# the fact; CPR-ORTH: a treatment one family needs, every sibling family needs).

SSOT_REL="install/settings-allow-commands.txt"
SSOT="$AGENTS_DIR/$SSOT_REL"
PATH_SSOT_REL="install/path-exposed-commands.txt"
PATH_SSOT="$AGENTS_DIR/$PATH_SSOT_REL"

# THE CONTRACT UNDER TEST. One declarative file names the commands and nothing else -- no
# interpreter (read from the shebang), no rule strings, no bare-form flag (decided by
# install/path-exposed-commands.txt). Since #2264 hooks/lib/allow-command-list.js reads both
# lists and bash-guard answers those commands with permissionDecision "allow"; the generator
# and its settings.json spellings are gone. install/lib/settings-assembly.js merges base +
# extension ONLY; install/lib/settings-deploy.js is the single writer of ~/.claude/settings.json.

ASSEMBLE_REL="install/assemble-settings.js"
ASSEMBLE="$AGENTS_DIR/$ASSEMBLE_REL"
SETTINGS_REL="settings.json"
SETTINGS="$AGENTS_DIR/$SETTINGS_REL"
LIB_DIR="$AGENTS_DIR/install/lib"
LIB_REL_LIST="install/lib/settings-assembly.js, settings-deploy.js"

# OUT OF SCOPE: install/path-exposed-commands.txt itself (read to decide bare forms, never
# modified); wrapper launchers such as bin/run-with-timeout.sh, whose trailing ` *` template
# would allow-list every command reachable through them; gh-write and git-state-changing
# commands; and WRITING the developer's OWN ~/.claude/settings.json, which home-canary.sh pins
# as untouched even though these cases now really do deploy (into fixture-private homes).
# T53 only READS that file.

PASS=0
FAIL=0
SKIP=0

# LAYER. Static/structural, plus fixture-driven integration that never touches the real tree
# or the real home: the install layer is COPIED into a temp fixture, run with cwd set there,
# and pointed at a fixture-private HOME per subprocess.

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
# Label-only markers (tests/lib/harness.sh is not sourced): targets are for static grep.
case_begin() { :; }
case_end() { :; }

# SKIPPED: asserting that bash-guard's allow actually stops the permission prompt in a live
#          Claude Code session.
# Because: an approved `ask` leaves no observable record; tests/hooks/TL3-hook-bash-guard-envelope.sh
#          owns that live measurement.

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name -- want [$want] got [$got]"; FAIL=$((FAIL + 1)); fi
}

# TL3 gap (what this test does NOT catch):
# - Whether the platform honours a PreToolUse permissionDecision "allow" without prompting --
#   the engine's behaviour, exercised only by a real session.
# - Whether the spelling the model actually issues is the one bash-guard recognises.
# - Whether the installer entry points and a genuine git event reach the assembler as the
#   fixture callers in hook-callers.sh do.

ROWS=0

# Closest-to-action mitigation for the gap above: a live spot-check of one command per spelling
# family, in BOTH the argument-bearing and the argument-less form, at the WORKFLOW_USER_VERIFIED
# preflight. The staged claude-global/settings.json makes bin/check-verification-gate.sh fire
# category `hook-registration`, which is the prompt forcing that spot-check.
# The two git-hook CALLERS are covered at TL2 by hook-callers.sh (real assembler, fixture HOME);
# only what needs a real machine is deferred -- reason in tests/fix-846-settings-drift-hooks.sh.
#
# EXECUTED-ROW BUDGET. Every table-driven loop in the part files increments ROWS; T10 asserts
# the exact total. An empty table, a drifted heredoc delimiter or an early return in front of
# a loop otherwise leaves a file that counts only its failures reporting green.
ROWS_EXPECTED=229 # ssot-structure 39 (T3a 4 + T3b 25 + T46 10) + write-and-drift 4 (T6 3 + T7 1)
                   # + settings-preservation 7 + merger-contract 14 + input-validation 15
                   # + provider-purity 14 + assembler-failclosed 18 (T29 12 + T36 6)
                   # + deploy-preconditions 17 (T40 8 + T41 9) + deploy-symlink-policy 29
                   # + drift-detection 13 + docs-contract 27 (T23 16 + stale 11) + retirement 7
                   # + hook-callers 15 (T37 10 + T38 5) + assembly-ownership 7 + T22 3
                   # T51/T52 (migration pins) are plain assert rows, outside this budget.
                   # #2264 retired the generator parts (T4/T5/T7b/T7c/T14-T17/T25/T31/T42/T44/T49).

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
# the T10 budget stays meaningful. The lib sentinel is separate from the CLI one on purpose:
# a CLI present without its modules fails as MODULE_NOT_FOUND, and every rc=2 row in the
# suite would otherwise read that crash as successful input validation.
missing_lib()      { printf '<MISSING:%s>' "$LIB_REL_LIST"; }
missing_assemble() { printf '<MISSING:%s>' "$ASSEMBLE_REL"; }

have_lib() {
    [ -f "$LIB_DIR/settings-assembly.js" ] &&
    [ -f "$LIB_DIR/settings-deploy.js" ]
}

PART_DIR="$AGENTS_DIR/tests/install/feature-2119-settings-allow-ssot"

# home-canary.sh is sourced FIRST and only defines functions: canary_setup repoints HOME and
# every home-shaped variable at a seeded fixture BEFORE any other part spawns a subprocess, so
# no node/bash/git child in this suite can reach the developer's deployed ~/.claude/settings.json.
# T22 then compares that fixture after every other part has run.
. "$PART_DIR/home-canary.sh"
canary_setup

. "$PART_DIR/ssot-structure.sh"
. "$PART_DIR/fixture.sh"
. "$PART_DIR/write-and-drift.sh"
. "$PART_DIR/settings-preservation.sh"
. "$PART_DIR/merger-contract.sh"
. "$PART_DIR/input-validation.sh"
. "$PART_DIR/provider-purity.sh"
. "$PART_DIR/assembler-failclosed.sh"
. "$PART_DIR/deploy-preconditions.sh"
. "$PART_DIR/deploy-symlink-policy.sh"
. "$PART_DIR/drift-detection.sh"
. "$PART_DIR/docs-contract.sh"
. "$PART_DIR/retirement.sh"
. "$PART_DIR/hook-callers.sh"
. "$PART_DIR/assembly-ownership.sh"
. "$PART_DIR/no-generated-spellings.sh"  # T51 (one synthetic entry)
. "$PART_DIR/real-spellings-gone.sh"     # T52 (every real SSOT entry) + T53 (real deployment); not ROWS-counted

t22_home_canary

assert_eq "T10: every table-driven loop executed its full row count (a short count means an empty or unreachable table reported green)" \
    "$ROWS_EXPECTED" "$ROWS"

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
