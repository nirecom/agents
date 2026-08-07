#!/usr/bin/env bash
# tests/feature-530-notes-promotion-triage-flow.sh
# Tests: bin/worktree-notes-triage.js, bin/worktree-notes-triage/resolve.js, hooks/lib/worktree-notes-sections.js
# Tags: notes-promotion, worktree-notes, triage, cli, subprocess, TL2, scope:common
#
# Issue #530 — the promotion protocol asks one CLI two questions before it does
# anything: "is this run mine?" (ownership) and "where is WORKTREE_NOTES.md?"
# (a five-step resolution chain). Both answers are invisible in prompt text; this
# suite spawns the real CLI against real fixtures and asserts the JSON contract.
#
# Pinned invocation contract (the shape the callsites in worktree-end SC/WE and
# issue-close-finalize are written against):
#
#   node bin/worktree-notes-triage.js resolve \
#        --caller <worktree-end|session-close|issue-close-finalize> \
#        [--from-session] [--worktree <dir>] [--session-id <sid>] \
#        [--issue <N>] [--pr-branch <branch>] [--main-root <dir>]
#
#   stdout: exactly one line of JSON — { action, skipReason?, resolvedVia?, notesPath? }
#   exit 0 for both "promote" and "skip"; exit 1 only for an unusable invocation.
#
# Resolution chain, highest priority first:
#   worktree → env-json → notes-backup-dir → backup-branch-dir → intent-scan
#   → (nothing found) skip/notes-path-unresolved
#
# This file is a dispatcher only. The cases live in the sibling directory
# (the single-file form crossed the 500-line HARD limit):
#
#   feature-530-notes-promotion-triage-flow/helpers.sh         shared fixtures
#   feature-530-notes-promotion-triage-flow/resolve-branches.sh G1-G5, G8
#   feature-530-notes-promotion-triage-flow/security.sh         S1-S6 (path/anchor escape)
#   feature-530-notes-promotion-triage-flow/injection.sh        P1-P3 (entries as
#                                                               untrusted, inert data)
#   feature-530-notes-promotion-triage-flow/security-anchors.sh A1-A4 (--worktree /
#                                                               --main-root absolute
#                                                               paths and shell metachars)
#   feature-530-notes-promotion-triage-flow/promotion-loop.sh   L1-L3, I1, E1-E6, G7
#   feature-530-notes-promotion-triage-flow/protocol-order.sh   O1-O2, N1-N2 (traced
#                                                               NP-4..NP-8 call order)
#
# NOT covered here (prompt-layer behavior; see the static suites
# tests/feature-530-notes-promotion-protocol.sh and
# tests/feature-530-promotion-callsite-conditions.sh, plus operational
# observation):
#   - the real /issue-create skill (promotion-loop.sh drives the documented loop
#     against a stub on PATH; the skill itself is model-driven)
#   - the NP-4 Read-based prefilter as performed by the model (protocol-order.sh
#     drives a reference implementation of it and asserts the CLI is never spawned)
#   - NP-9 skip conditions 1-3 (non-interactive / non-GitHub remote / user defer)
#   - defer-language suppression in the notice text
#
# TL3 gap (what this test does NOT catch):
# - Whether the three SKILL.md callsites actually issue this command in a live
#   session, in the right order, and with the right caller value.
# - Whether the Bash-tool hooks (enforce-worktree) permit the command as written
#   from the main worktree during session-close.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.
#
# RED before write-code: `resolve` does not exist yet, so every G1-G5/G8 and most
# S case fails on a named assertion (unknown subcommand → exit 1, empty stdout).
# The list/annotate cases (L, I, E, G7, P) use shipped subcommands and pass
# today, except three that pin behavior the current annotate lacks:
#   I1  markEntryPromoted appends unconditionally, so a retry stacks a second
#       identical marker on the line.
#   E2  annotate on a zero-byte notes file reports success and writes.
#   E3a annotate on a line past EOF reports success while doing nothing, so the
#       caller believes an entry was marked that was not.

set -u

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-530-notes-promotion-triage-flow"

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0

run_sub() {
    local sub="$1" out
    echo ""
    echo "=== $sub ==="
    out="$(bash "$SUITE_DIR/$sub" 2>&1)"
    echo "$out"
    TOTAL_PASS=$((TOTAL_PASS + $(printf '%s\n' "$out" | grep -c '^PASS:')))
    TOTAL_FAIL=$((TOTAL_FAIL + $(printf '%s\n' "$out" | grep -c '^FAIL:')))
    TOTAL_SKIP=$((TOTAL_SKIP + $(printf '%s\n' "$out" | grep -c '^SKIP:')))
}

run_sub resolve-branches.sh
run_sub security.sh
run_sub injection.sh
run_sub security-anchors.sh
run_sub promotion-loop.sh
run_sub protocol-order.sh

echo ""
echo "Results: $TOTAL_PASS passed, $TOTAL_FAIL failed, $TOTAL_SKIP skipped"
echo "Total: PASS=$TOTAL_PASS FAIL=$TOTAL_FAIL SKIP=$TOTAL_SKIP"
exit $((TOTAL_FAIL > 0 ? 1 : 0))
