#!/usr/bin/env bash
# tests/cc-rules-injection-scope-conventions.sh
# Tests: rules/test/fixture-isolation.md, rules/test.md, rules/test/claude-e2e.md
# Tags: rules-injection, rules-scope, frontmatter, conventions, ssot, TL2, scope:common
#
# Detail plan S1 narrows rules/test/fixture-isolation.md from unconditional injection
# to the same test-file trigger set its sibling rules/test/claude-e2e.md already uses,
# and adds a pointer to it from rules/test.md so the content stays discoverable once
# it no longer loads on every turn. Narrowing the scope WITHOUT the pointer silently
# removes the rule from the agent's reach — the two halves must be asserted together.
# Layer: TL2 (reads the real rule files in this worktree; no fixtures, no subprocess).
#
# TL3 gap (what this test does NOT catch):
# - Whether Claude Code's own path matcher actually resolves these globs against the
#   files a session touches; only a live session's injection receipt shows that.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_RULE="$AGENTS_DIR/rules/test/fixture-isolation.md"
E2E_RULE="$AGENTS_DIR/rules/test/claude-e2e.md"
TEST_RULE="$AGENTS_DIR/rules/test.md"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

MISSING=0
for f in "$FIXTURE_RULE" "$E2E_RULE" "$TEST_RULE"; do
    [ -f "$f" ] || { echo "FAIL: IMPLEMENTATION MISSING: $f"; MISSING=1; }
done
# Tier 1 also covers the not-yet-applied state: before /write-code lands S1 the file
# still has no frontmatter at all, and every assertion below would be noise.
if [ "$MISSING" -eq 0 ] && ! head -1 "$FIXTURE_RULE" | grep -q '^---$'; then
    echo "FAIL: IMPLEMENTATION MISSING: rules/test/fixture-isolation.md has no frontmatter block (detail plan S1 not applied)"
    MISSING=1
fi
if [ "$MISSING" -eq 1 ]; then
    echo ""
    echo "Results: 0 passed, 1 failed (target not yet implemented — detail plan S1)"
    exit 1
fi

# paths_of <file> -> one glob per line, in file order
paths_of() {
    node -e "
const fs = require('fs');
const t = fs.readFileSync(process.argv[1], 'utf8');
const m = /^---\r?\n([\s\S]*?)\r?\n---/.exec(t);
if (!m) { console.log('NO_FRONTMATTER'); process.exit(0); }
const lines = m[1].split(/\r?\n/);
const i = lines.findIndex((l) => /^paths:/.test(l));
if (i < 0) { console.log('NO_PATHS_KEY'); process.exit(0); }
const out = [];
for (let j = i + 1; j < lines.length; j++) {
  const mm = /^\s+-\s+\"?([^\"]*)\"?\s*\$/.exec(lines[j]);
  if (!mm) break;
  out.push(mm[1]);
}
console.log(out.join('\n'));
" "$(node_path "$1")" 2>&1
}

WANT_GLOBS='tests/**
**/*.sh
**/*.Tests.ps1
test_*.py
**/*.spec.*'

GOT_GLOBS="$(paths_of "$FIXTURE_RULE")"

# --- C1: the glob set is EXACTLY the five entries, in the sibling's order.
# An exact comparison, not a containment check: an extra glob widens the trigger
# surface back out and a missing one drops a file type from coverage. ---
if [ "$GOT_GLOBS" = "$WANT_GLOBS" ]; then
    pass "C1: fixture-isolation.md paths: is exactly the five test-file globs"
else
    fail "C1: paths: mismatch — want [$(printf '%s' "$WANT_GLOBS" | tr '\n' ' ')] got [$(printf '%s' "$GOT_GLOBS" | tr '\n' ' ')]"
fi

# --- C2: the two sibling test rules share one trigger set (CPR-ORTH). If a later
# change extends claude-e2e.md's globs, this fails until fixture-isolation.md follows. ---
E2E_GLOBS="$(paths_of "$E2E_RULE")"
if [ "$GOT_GLOBS" = "$E2E_GLOBS" ]; then
    pass "C2: fixture-isolation.md and claude-e2e.md declare an identical trigger set"
else
    fail "C2: sibling trigger sets diverged — claude-e2e.md=[$(printf '%s' "$E2E_GLOBS" | tr '\n' ' ')] fixture-isolation.md=[$(printf '%s' "$GOT_GLOBS" | tr '\n' ' ')]"
fi

# --- C3: the reserved on-demand token must NOT appear here. This rule is
# conditionally injected, not on-demand-only; the two mechanisms are distinct. ---
if grep -q '\.on-demand-only/never-match' "$FIXTURE_RULE"; then
    fail "C3: fixture-isolation.md carries the reserved on-demand token — it is a conditional rule, not an on-demand one"
else
    pass "C3: fixture-isolation.md does not claim the reserved on-demand token"
fi

# --- C4: rules/test.md carries the pointer section EXACTLY ONCE. `grep -q` was the
# original assertion and it is satisfied by two, three or ten copies of the heading —
# and a duplicated heading is not a cosmetic defect here: the awk extraction in C5
# reads from the FIRST match to the next `## `, so a second section can hold an
# unreviewed second pointer (or a copy of the rule's substance) that C5/C6 never see.
# Duplicate headings also defeat anchor links. Require one, not at-least-one. ---
HEAD_N="$(grep -c '^## Test Fixture Isolation$' "$TEST_RULE" || true)"
if [ "${HEAD_N:-0}" -eq 1 ]; then
    pass "C4: rules/test.md has exactly one '## Test Fixture Isolation' section"
elif [ "${HEAD_N:-0}" -eq 0 ]; then
    fail "C4: rules/test.md is missing the '## Test Fixture Isolation' section"
else
    fail "C4: rules/test.md has $HEAD_N '## Test Fixture Isolation' headings — C5/C6 only inspect the first, so the rest are unreviewed"
fi

# --- C5: that section must actually link the file, and stay a POINTER (the content
# lives in one place — CPR-SSOT), so a body that grows past a couple of lines fails. ---
SECTION="$(awk '/^## Test Fixture Isolation$/{f=1;next} /^## /{f=0} f' "$TEST_RULE")"
SECTION_BODY="$(printf '%s\n' "$SECTION" | grep -v '^[[:space:]]*$' || true)"
SECTION_LINES="$(printf '%s\n' "$SECTION_BODY" | grep -c . || true)"
# Occurrences of the LINK, not lines containing it: two references on one line is the
# shape a `<=2 lines` check waved through, and a second reference is either a second
# (divergent) path or a restatement — both are the CPR-SSOT drift this asserts against.
#
# Counting the raw path string would be wrong: `[test/fixture-isolation.md](test/...)`
# is the ordinary markdown form and contains the path twice by construction, so a
# by-string count fails the correct pointer. Count link TARGETS, then remove whole link
# constructs and require that no bare mention of the path survives — that catches the
# second pointer regardless of which label style the first one used.
LINK_N="$(printf '%s\n' "$SECTION_BODY" | grep -o '](test/fixture-isolation\.md)' | grep -c . || true)"
BARE_REST="$(printf '%s\n' "$SECTION_BODY" | sed 's/\[[^]]*\](test\/fixture-isolation\.md)//g')"
BARE_N="$(printf '%s\n' "$BARE_REST" | grep -o 'test/fixture-isolation\.md' | grep -c . || true)"
if [ "${LINK_N:-0}" -eq 0 ] && [ "${BARE_N:-0}" -eq 0 ]; then
    fail "C5: the section does not reference test/fixture-isolation.md — body: [$(printf '%s' "$SECTION_BODY" | tr '\n' ' ')]"
elif [ "${LINK_N:-0}" -ne 1 ]; then
    fail "C5: the section contains $LINK_N markdown links to test/fixture-isolation.md — a pointer links its target exactly once"
elif [ "${BARE_N:-0}" -ne 0 ]; then
    fail "C5: the section mentions test/fixture-isolation.md $BARE_N more time(s) outside its link — a second reference is either a divergent path or a restatement"
elif [ "$SECTION_LINES" -ne 1 ]; then
    fail "C5: the section must stay a one-line pointer, got $SECTION_LINES non-blank lines — anything more is content that belongs in the rule file"
else
    pass "C5: rules/test.md points at test/fixture-isolation.md exactly once, in a single line"
fi

# --- C6: the pointer must not duplicate the rule's substance. The dual-pin contract
# is the one sentence most likely to be copied; asserting its absence keeps the SSOT. ---
if printf '%s' "$SECTION_BODY" | grep -q 'WORKFLOW_PLANS_DIR'; then
    fail "C6: the pointer section duplicates the dual-pin contract instead of linking to it"
else
    pass "C6: the pointer section does not copy the rule's substance"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
