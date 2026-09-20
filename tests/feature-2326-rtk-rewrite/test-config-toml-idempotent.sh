#!/bin/bash
# tests/feature-2326-rtk-rewrite/test-config-toml-idempotent.sh
# Tests: install/lib/rtk-config-deploy.js
# Tags: rtk, installer, idempotent, scope:issue-specific
#
# rtk-config-deploy.js must be non-destructive: when config.toml already exists
# it is left byte-for-byte unchanged across repeated runs, and every run exits 0.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOY="$AGENTS_DIR/install/lib/rtk-config-deploy.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

# Case 1: pre-existing config is preserved across two runs.
TARGET="$TMPDIR_T/rtk/config.toml"
mkdir -p "$TMPDIR_T/rtk"
KNOWN='[retriever]
enabled = false
# user-customized'
printf '%s' "$KNOWN" > "$TARGET"
BEFORE="$(cat "$TARGET")"

RTK_CONFIG_TOML="$TARGET" node "$DEPLOY" >/dev/null 2>&1
RC1=$?
RTK_CONFIG_TOML="$TARGET" node "$DEPLOY" >/dev/null 2>&1
RC2=$?
AFTER="$(cat "$TARGET")"

[ "$RC1" -eq 0 ] && pass "first run exits 0" || fail "first run exit $RC1"
[ "$RC2" -eq 0 ] && pass "second run exits 0" || fail "second run exit $RC2"
[ "$BEFORE" = "$AFTER" ] && pass "existing config unchanged" || fail "existing config was modified"

# Case 2: absent config is created, then preserved on the second run.
TARGET2="$TMPDIR_T/fresh/config.toml"
RTK_CONFIG_TOML="$TARGET2" node "$DEPLOY" >/dev/null 2>&1
RC3=$?
[ -f "$TARGET2" ] && pass "config created when absent" || fail "config not created"
CREATED="$(cat "$TARGET2" 2>/dev/null)"
RTK_CONFIG_TOML="$TARGET2" node "$DEPLOY" >/dev/null 2>&1
RECHECK="$(cat "$TARGET2" 2>/dev/null)"
[ "$RC3" -eq 0 ] && pass "create run exits 0" || fail "create run exit $RC3"
[ "$CREATED" = "$RECHECK" ] && pass "created config unchanged on rerun" || fail "created config changed on rerun"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
