#!/usr/bin/env bash
# tests/feat-1763-provenance-removal-grep-guard.sh
# Tests: hooks/lib/issue-provenance-keys.js, bin/github-issues/issue-provenance, skills/issue-create/SKILL.md, settings.json, .env.example
# Tags: issue-create, provenance-removal, dead-code-guard, repo-wide-scan, scope:issue-specific, pwsh-not-required, TL1
# TL3 gap (what this test does NOT catch):
# - A residue that is spelled differently from the three tokens scanned here (e.g. a
#   renamed marker file). Only the documented spellings are greppable offline.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.
#
# The provenance token mechanism is deleted wholesale in this PR: the mint hook, its
# libraries, the CLI, the confirm-gate input, the settings.json registration and the
# .env.example switch all go at once. Partial removal is the dangerous outcome — a
# surviving registration in settings.json would keep firing a deleted hook on every
# UserPromptSubmit, and a surviving `ISSUE_PROVENANCE` read would branch on a value
# nothing writes. Neither shows up in a behavioural test of the code that REMAINS, so
# the only way to observe the residue is to scan for it.
#
# docs/ and tests/ are deliberately out of scope: history.md, CHANGELOG.md and this
# file itself must be able to name the thing that was removed.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }
fatal() { echo "FATAL: $1"; echo "Results: $PASS passed, $((FAIL + 1)) failed"; exit 1; }

# The three spellings the mechanism used, across code, config and prompts.
PATTERN='issue-provenance|ISSUE_PROVENANCE|session-transcript'

# Behaviour code, config and prompts — everything that can still EXECUTE a reference.
ROOTS="hooks bin skills rules settings.json .env.example agents"

# scan <dir> → prints "<path>:<line>:<text>" for every hit under $1
scan() {
    local base="$1" r
    for r in $ROOTS; do
        [ -e "$base/$r" ] || continue
        grep -rnE "$PATTERN" "$base/$r" 2>/dev/null
    done
}

echo "=== G0: the scanner is wired up and can both find and not-find ==="
# A grep guard that silently matches nothing (wrong root, wrong pattern, missing -r)
# is green forever. Prove both directions on fixtures before trusting the real scan.
PROBE="$(mktemp -d)"
trap 'rm -rf "$PROBE"' EXIT
mkdir -p "$PROBE/hooks"
printf 'const KEY = ".issue-provenance";\n' > "$PROBE/hooks/residue.js"
if [ "$(scan "$PROBE" | wc -l | tr -d ' ')" -ge 1 ]; then
    pass "G0-scanner-finds-a-planted-reference"
else
    fatal "the scanner found nothing in a fixture that plainly contains '.issue-provenance' — every assertion below would be vacuous"
fi
rm -f "$PROBE/hooks/residue.js"
printf 'const KEY = ".off-clearance";\n' > "$PROBE/hooks/clean.js"
if [ -z "$(scan "$PROBE")" ]; then
    pass "G0-scanner-clears-an-unrelated-file"
else
    fatal "the scanner matched a file with no provenance reference — the pattern is too broad to prove anything"
fi

# The real tree must actually contain the roots, or the scan below is scanning nothing.
FOUND_ROOTS=0
for r in $ROOTS; do [ -e "$AGENTS_DIR/$r" ] && FOUND_ROOTS=$((FOUND_ROOTS + 1)); done
if [ "$FOUND_ROOTS" -ge 5 ]; then
    pass "G0-roots-present ($FOUND_ROOTS roots)"
else
    fatal "only $FOUND_ROOTS of the scanned roots exist under $AGENTS_DIR — the scan would be degenerate"
fi

echo ""
echo "=== G1: no executable reference to the provenance mechanism survives ==="
HITS="$(scan "$AGENTS_DIR")"
if [ -z "$HITS" ]; then
    pass "G1-no-provenance-references"
else
    fail "G1-no-provenance-references" "$(printf '%s' "$HITS" | wc -l | tr -d ' ') surviving reference(s):
$(printf '%s' "$HITS" | head -n 20)"
fi

echo ""
echo "=== G2: the deleted files are actually gone ==="
# Named individually so a partially-completed deletion reports WHICH file remains,
# rather than one undifferentiated grep dump.
for f in \
    hooks/issue-provenance-mint.js \
    hooks/lib/issue-provenance-keys.js \
    hooks/lib/issue-provenance-consumed.js \
    hooks/lib/issue-request-patterns.js \
    bin/github-issues/issue-provenance
do
    if [ -e "$AGENTS_DIR/$f" ]; then
        fail "G2-deleted:$f" "still present"
    else
        pass "G2-deleted:$f"
    fi
done

echo ""
echo "=== G3: settings.json no longer registers the mint hook ==="
if [ ! -f "$AGENTS_DIR/settings.json" ]; then
    fail "G3-settings-registration-removed" "settings.json is missing — cannot verify the registration was removed"
elif grep -qF 'issue-provenance-mint' "$AGENTS_DIR/settings.json"; then
    fail "G3-settings-registration-removed" "settings.json still registers issue-provenance-mint.js, which would fire a deleted hook on every UserPromptSubmit"
else
    pass "G3-settings-registration-removed"
fi

echo ""
echo "=== G4: .env.example no longer advertises the removed switches ==="
if [ ! -f "$AGENTS_DIR/.env.example" ]; then
    fail "G4-env-example-switches-removed" ".env.example is missing — cannot verify the switches were removed"
elif grep -qE 'ISSUE_PROVENANCE|ISSUE_VERDICT_REVIEW' "$AGENTS_DIR/.env.example"; then
    fail "G4-env-example-switches-removed" ".env.example still documents a switch that nothing reads: $(grep -nE 'ISSUE_PROVENANCE|ISSUE_VERDICT_REVIEW' "$AGENTS_DIR/.env.example" | head -n 3 | tr '\n' ' ')"
else
    pass "G4-env-example-switches-removed"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
