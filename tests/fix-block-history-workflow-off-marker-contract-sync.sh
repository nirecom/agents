#!/usr/bin/env bash
# tests/fix-block-history-workflow-off-marker-contract-sync.sh
# Tests: docs/architecture/claude-code/marker-bypass-contract.md, hooks/, settings.json
# Tags: docs-sync, marker-bypass, static-check, scope:common, pwsh-not-required, TL1, TL2
# TL3 gap (what this test does NOT catch):
# - Whether each row's Yes/No values are behaviorally correct: this test asserts row
#   PRESENCE only, never the truth of the "Honors .workflow-off" / "Honors .worktree-off"
#   cells. A hook could honor a marker while the table says "No" and this test stays green.
# - A real hook-execution TL3 test would run each hook via real `claude -p` with a
#   `.workflow-off` / `.worktree-off` marker on disk and assert the observed
#   allow/block verdict matches the cell value in the table.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$AGENTS_DIR"

DOC="docs/architecture/claude-code/marker-bypass-contract.md"
SETTINGS="settings.json"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

[[ -f "$DOC" ]] || { echo "FATAL: missing $DOC"; exit 1; }
[[ -f "$SETTINGS" ]] || { echo "FATAL: missing $SETTINGS"; exit 1; }
[[ -d hooks ]] || { echo "FATAL: missing hooks/ directory"; exit 1; }

# --- Step 3: extract table rows from the "## Honoring hooks" section -----------
# Rows look like: | `hooks/foo.js` | PreToolUse | Yes | No |
# or:             | `hooks/pre-commit` (worktree-isolation gate only) | git pre-commit | ...
extract_table_rows() {
    sed -n '/^## Honoring hooks/,/^## [^H]/p' "$DOC" \
        | grep -E '^\| *`hooks/' \
        | sed -e 's/^| *//' -e 's/ *|.*$//' \
              -e 's/`//g' \
              -e 's/ *([^)]*)//g' \
              -e 's/[[:space:]]*$//'
}

TABLE_ROWS="$(extract_table_rows || true)"

if [[ -z "$TABLE_ROWS" ]]; then
    echo "FATAL: extracted zero rows from the '## Honoring hooks' table in $DOC"
    echo "       (extraction logic is broken, or the section was renamed)"
    exit 1
fi

row_count="$(printf '%s\n' "$TABLE_ROWS" | grep -c . || true)"
if [[ "$row_count" -lt 10 ]]; then
    echo "FATAL: only $row_count table rows extracted — implausibly few; extraction is broken"
    exit 1
fi
pass "extracted $row_count rows from the Honoring-hooks table"

has_row() {  # <hook-path>
    printf '%s\n' "$TABLE_ROWS" | grep -qxF "$1"
}

# Self-check on the extraction logic: a hook path that cannot exist must NOT match.
# This proves has_row() is capable of returning false (guards against a false green
# where a broken matcher answers "yes" for everything).
if has_row "hooks/definitely-not-a-real-hook.js"; then
    echo "FATAL: has_row() matched a nonexistent hook — matcher is degenerate"
    exit 1
fi
pass "has_row() rejects a nonexistent hook path (matcher is not degenerate)"

# --- Step 1: enumerate marker-callers under hooks/ -----------------------------
# hooks/lib/session-markers.js is excluded: it DEFINES isWorkflowOff/isWorktreeOff.
# hooks/workflow-gate/worktree-entry-gate.js folds into hooks/workflow-gate.js.
CALLERS="$(grep -rl 'isWorkflowOff\|isWorktreeOff' hooks/ \
    | tr '\\' '/' \
    | grep -v '^hooks/lib/session-markers\.js$' \
    | sed -e 's|^hooks/workflow-gate/.*$|hooks/workflow-gate.js|' \
    | sort -u)"

if [[ -z "$CALLERS" ]]; then
    echo "FATAL: grep found zero marker-callers under hooks/ — enumeration is broken"
    exit 1
fi
caller_count="$(printf '%s\n' "$CALLERS" | grep -c . || true)"
pass "enumerated $caller_count marker-caller hook(s) via grep"

# --- Step 2: enumerate settings.json PreToolUse hook scripts ------------------
PRETOOLUSE="$(node -e '
const s = require("./settings.json");
const out = new Set();
for (const entry of (s.hooks && s.hooks.PreToolUse) || []) {
  for (const h of entry.hooks || []) {
    const m = String(h.command || "").match(/hooks\/[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*/g);
    if (m) m.forEach((p) => out.add(p));
  }
}
console.log([...out].sort().join("\n"));
')"

if [[ -z "$PRETOOLUSE" ]]; then
    echo "FATAL: parsed zero PreToolUse hook scripts from $SETTINGS — parser is broken"
    exit 1
fi
pre_count="$(printf '%s\n' "$PRETOOLUSE" | grep -c . || true)"
pass "parsed $pre_count PreToolUse hook script(s) from $SETTINGS"

# --- Step 4a: every marker-caller must have a table row -----------------------
missing_callers=0
while IFS= read -r hook; do
    [[ -n "$hook" ]] || continue
    if ! has_row "$hook"; then
        echo "MISSING TABLE ROW: $hook is a marker-caller (grep-detected) but has no row in the Honoring-hooks table"
        missing_callers=$((missing_callers + 1))
    fi
done <<< "$CALLERS"

if [[ "$missing_callers" -eq 0 ]]; then
    pass "all $caller_count marker-caller hook(s) appear in the Honoring-hooks table"
else
    fail "$missing_callers marker-caller hook(s) missing from the Honoring-hooks table"
fi

# --- Step 4b: every settings.json PreToolUse hook must have a table row -------
# hooks/pre-commit is a git hook, not a PreToolUse entry — it is intentionally not
# expected from this enumeration (the doc lists it as a git pre-commit hook).
missing_registered=0
while IFS= read -r hook; do
    [[ -n "$hook" ]] || continue
    [[ "$hook" == "hooks/pre-commit" ]] && continue
    if ! has_row "$hook"; then
        echo "MISSING TABLE ROW: $hook is registered as a PreToolUse hook in settings.json but has no row in the Honoring-hooks table"
        missing_registered=$((missing_registered + 1))
    fi
done <<< "$PRETOOLUSE"

if [[ "$missing_registered" -eq 0 ]]; then
    pass "all $pre_count PreToolUse hook(s) from $SETTINGS appear in the Honoring-hooks table"
else
    fail "$missing_registered registered PreToolUse hook(s) missing from the Honoring-hooks table"
fi

# --- Summary ------------------------------------------------------------------
echo "----"
echo "PASS=$PASS FAIL=$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
    echo "RESULT: marker-bypass contract table is out of sync with hooks/ + $SETTINGS"
    exit 1
fi
echo "RESULT: marker-bypass contract table is in sync with hooks/ + $SETTINGS"
exit 0
