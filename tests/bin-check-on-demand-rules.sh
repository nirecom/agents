#!/usr/bin/env bash
# tests/bin-check-on-demand-rules.sh
# Tests: bin/check-on-demand-rules.sh, hooks/lib/rules-injection-policy.js, hooks/lib/rules-policy-reader.js
# Tags: rules-injection, on-demand-rules, static-check, frontmatter, table-driven, parse-dont-evaluate, TL2, scope:common

# TL2 table-driven coverage of the C1-C5 checks in bin/check-on-demand-rules.sh (detail plan "1-3")
# plus the SSOT constants in hooks/lib/rules-injection-policy.js. Dispatcher only — cases live in
# tests/bin-check-on-demand-rules/.
# TL3 gap (not caught here): whether hooks/pre-commit actually wires this checker in for staged
# rules/**/*.md (checker can be perfect, still never run on a real commit); whether the host loader
# really refuses ON_DEMAND_TOKEN — this file only proves the notation is internally consistent,
# never that injection stops. Mitigated at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh, category hook-registration.

# CONTRACT NOTE (read before implementing bin/check-on-demand-rules.sh): the fixtures ship their own
# hooks/lib/rules-injection-policy.js inside the tree under check and also export
# RULES_INJECTION_POLICY. The checker must resolve policy from one of those two
# (policy-of-the-tree-under-check), else --all <root> grades a foreign tree against the agents repo's
# own constants.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$AGENTS_DIR/bin/check-on-demand-rules.sh"
POLICY="$AGENTS_DIR/hooks/lib/rules-injection-policy.js"
# The policy is contributor-editable declaration DATA; this suite's own harnesses read it
# through the agents-owned reader (loadPolicyAsData) instead of require()-ing it, for the
# same reason the checker does — running this suite on a checked-out branch must not run
# that branch's code. CPR-ORTH sibling of tests/cc-on-demand-skill-ownership/cases-require-safety.sh.
READER="$AGENTS_DIR/hooks/lib/rules-policy-reader.js"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

# --- implementation guard (tier 1): fail loudly and specifically when a target is
# absent, BEFORE any assertion runs, so a real defect can never look like a skip. ---
MISSING=0
for f in "$CHECKER" "$POLICY" "$READER"; do
    [ -f "$f" ] || { echo "FAIL: IMPLEMENTATION MISSING: $f"; MISSING=1; }
done
if [ "$MISSING" -eq 1 ]; then
    echo ""
    echo "Results: 0 passed, 1 failed (targets not yet implemented — detail plan S2-1 / S2-6)"
    exit 1
fi

TOKEN='.on-demand-only/never-match'
MARKER='<!-- injection: on-demand-only - auto-injection disabled; the owning skill Reads it explicitly. -->'

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT
CASE_N=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin-check-on-demand-rules"
# shellcheck source=./bin-check-on-demand-rules/fixtures.sh
. "$SCRIPT_DIR/fixtures.sh"
# shellcheck source=./bin-check-on-demand-rules/cases-notation.sh
. "$SCRIPT_DIR/cases-notation.sh"
# shellcheck source=./bin-check-on-demand-rules/cases-staged.sh
. "$SCRIPT_DIR/cases-staged.sh"
# shellcheck source=./bin-check-on-demand-rules/cases-policy.sh
. "$SCRIPT_DIR/cases-policy.sh"
# shellcheck source=./bin-check-on-demand-rules/cases-marker.sh
. "$SCRIPT_DIR/cases-marker.sh"
# Injection cases run LAST: they deliberately hand the checker hostile paths and an
# out-of-root file, and they create a canary directory whose emptiness is the assertion.
# shellcheck source=./bin-check-on-demand-rules/cases-injection.sh
. "$SCRIPT_DIR/cases-injection.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
