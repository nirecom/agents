#!/bin/bash
# tests/feature-2215-codegraph-context-inject.sh
# Tests: hooks/codegraph-context-inject.js, hooks/lib/codegraph-boundary.js, hooks/lib/path-normalize.js, hooks/lib/settings-drift.js, settings.json
# Tags: hook-injection, codegraph, prompt-hook, scope-gate, hook-registration, TL2, scope:issue-specific
#
# Issue #2215 TL2 cases M16-M31 (+M19b/M22b/M25b/M27c); see the detail plan (S5-8) as
# SSOT for case specs. Dispatcher only: counters, the pass/fail vocabulary and the
# source order. Every fixture, stub and helper lives in harness.sh; the cases are
# grouped by the contract they pin (forwarding, payload, settings, scope gate).
# RED-PHASE: hooks/codegraph-context-inject.js and hooks/lib/codegraph-boundary.js do not exist
# yet, so every case here is expected to FAIL against current HEAD. Do not weaken assertions.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && (pwd -W 2>/dev/null || pwd))"
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-2215-codegraph-context-inject"

# TL3 gap (what this test does NOT catch): the real `codegraph prompt-hook`
# contract against an actually-installed CLI (this suite only stubs it); real
# hook registration end-to-end via Claude Code (settings.json is read
# statically here, and the hook script is invoked directly with `node`); and
# Windows shim resolution against a real `npm install -g` layout, beyond the
# synthetic shim trio built below.
# Closest-to-action mitigation: tests/TL3-codegraph-cli-contract.sh (M37-M40,
# RUN_TL3-gated) runs the real CLI's `prompt-hook` / `--version` against a
# fixture home/project, exercising the contract this file only stubs.

PASS=0
FAIL=0
SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

# shellcheck source=./feature-2215-codegraph-context-inject/harness.sh
. "$MODULE_DIR/harness.sh"

echo "=== feature-2215-codegraph-context-inject: M16-M31 ==="

# shellcheck source=./feature-2215-codegraph-context-inject/forwarding.sh
. "$MODULE_DIR/forwarding.sh"
# shellcheck source=./feature-2215-codegraph-context-inject/payload.sh
. "$MODULE_DIR/payload.sh"
# shellcheck source=./feature-2215-codegraph-context-inject/settings-static.sh
. "$MODULE_DIR/settings-static.sh"
# shellcheck source=./feature-2215-codegraph-context-inject/scope-gate.sh
. "$MODULE_DIR/scope-gate.sh"

echo ""
echo "=== feature-2215-codegraph-context-inject: $PASS passed, $FAIL failed, $SKIP skipped ==="
[ "$FAIL" -eq 0 ]
