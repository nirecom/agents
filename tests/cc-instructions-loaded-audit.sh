#!/usr/bin/env bash
# tests/cc-instructions-loaded-audit.sh
# Tests: hooks/instructions-loaded-audit.js, hooks/lib/instructions-loaded-receipt.js, hooks/lib/rules-injection-policy.js
# Tags: rules-injection, instructions-loaded, hook, classifier, table-driven, fail-open, security, TL2, scope:common
#
# TL2 coverage of the InstructionsLoaded audit hook (detail plan section 3-2..3-6):
# single-file payload on stdin -> verdict classification -> atomic per-entry receipt.
# Layer: TL2 (real node subprocess, real stdin payload, real receipt files).
# Dispatcher only: fixtures live in cc-instructions-loaded-audit/helpers.sh and the
# case groups in the sibling cases-*.sh files (rules/coding/file-split.md Pattern A).
#
# TL3 gap (what this test does NOT catch):
# - Whether the host actually dispatches an "InstructionsLoaded" event under that
#   exact spelling, and what payload shape it really passes (file_path/load_reason).
# - Whether settings.json registration makes the hook fire at all in a live session.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.
#
# Skipped-Because: EACCES / read-only coverage (chmod 0000 on a rule file, or a
# read-only receipt directory) is NOT tested here. POSIX permission bits are not
# reliably enforced on this Windows host — the developer account routinely bypasses
# them — so a chmod-based case would assert nothing on the machine that runs it and
# would flake on machines that do enforce them. Instead the SAME fail-open branch is
# provoked deterministically and platform-independently by E8c in
# cc-instructions-loaded-audit/cases-receipt.sh, which points the receipt directory at
# a path whose parent is a regular file, so mkdir fails with ENOTDIR on every platform.
# What remains genuinely uncovered is the EACCES errno specifically, not the branch.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")/cc-instructions-loaded-audit"
HOOK="$AGENTS_DIR/hooks/instructions-loaded-audit.js"
RECEIPT_LIB="$AGENTS_DIR/hooks/lib/instructions-loaded-receipt.js"
POLICY="$AGENTS_DIR/hooks/lib/rules-injection-policy.js"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

MISSING=0
for f in "$HOOK" "$RECEIPT_LIB" "$POLICY"; do
    [ -f "$f" ] || { echo "FAIL: IMPLEMENTATION MISSING: $f"; MISSING=1; }
done
if [ "$MISSING" -eq 1 ]; then
    echo ""
    echo "Results: 0 passed, 1 failed (targets not yet implemented — detail plan S2-2 / S2-4)"
    exit 1
fi

# shellcheck source=./cc-instructions-loaded-audit/helpers.sh
. "$SCRIPT_DIR/helpers.sh"
# shellcheck source=./cc-instructions-loaded-audit/cases-verdicts.sh
. "$SCRIPT_DIR/cases-verdicts.sh"
# shellcheck source=./cc-instructions-loaded-audit/cases-frontmatter.sh
. "$SCRIPT_DIR/cases-frontmatter.sh"
# cases-pathid.sh must run BEFORE cases-security.sh: its N4 sweep asserts that no
# receipt written so far carries a root-dependent path, and the security group
# deliberately feeds absolute and traversal paths that have no repo-relative form.
# shellcheck source=./cc-instructions-loaded-audit/cases-pathid.sh
. "$SCRIPT_DIR/cases-pathid.sh"
# shellcheck source=./cc-instructions-loaded-audit/cases-security.sh
. "$SCRIPT_DIR/cases-security.sh"
# cases-rulesroot.sh runs after cases-security.sh for the same reason cases-pathid.sh
# runs before it: it deliberately fires out-of-root paths, which cases-pathid's N4 sweep
# would otherwise see.
RRCASES="$SCRIPT_DIR/cases-rulesroot.sh"
if [ -f "$RRCASES" ]; then
    # shellcheck source=./cc-instructions-loaded-audit/cases-rulesroot.sh
    . "$RRCASES"
else
    fail "IMPLEMENTATION MISSING: $RRCASES (rules-key root anchoring cases)"
fi
# shellcheck source=./cc-instructions-loaded-audit/cases-receipt.sh
. "$SCRIPT_DIR/cases-receipt.sh"
# cases-supervisor.sh runs LAST: it is the only group that pins its own
# WORKFLOW_PLANS_DIR and fires from a CWD carrying a resolvable Session-ID, so the
# supervisor emission path actually executes. Running it earlier would leave its
# supervisor-state artifacts inside the shared plans dir for later groups to trip over.
SUPCASES="$SCRIPT_DIR/cases-supervisor.sh"
if [ -f "$SUPCASES" ]; then
    # shellcheck source=./cc-instructions-loaded-audit/cases-supervisor.sh
    . "$SUPCASES"
else
    fail "IMPLEMENTATION MISSING: $SUPCASES (supervisor containment cases)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
