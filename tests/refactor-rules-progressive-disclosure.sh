#!/usr/bin/env bash
# tests/refactor-rules-progressive-disclosure.sh
# Tests: rules/claude-config-source.md, rules/coding.md, rules/coding/file-split.md, rules/coding/nodejs.md, rules/coding/python.md, rules/docs.md, rules/docs/architecture.md, rules/docs/changelog.md, rules/docs/env-example.md, rules/docs/history.md, rules/docs/readme.md, rules/docs/todo.md, rules/installer.md, rules/prompt.md, rules/test.md, rules/test/claude-e2e.md, rules/test/installer.md, rules/test/macos-timeout.md, skills/_shared/test-design.md
# Tags: frontmatter, rules, paths, progressive-disclosure, tests, scope:common
#
# Dispatcher for the refactor/rules-progressive-disclosure test group.
# Test groups live in tests/refactor-rules-progressive-disclosure/ and are
# sourced below; this file owns the shared helpers and PASS/FAIL/SKIP totals.
#
# Groups:
#   paths-frontmatter.sh — exact paths: file set, per-file item counts, no globs:
#   helper-fixtures.sh   — table-driven fixtures for check_paths_frontmatter
#   cleanup.sh           — stub deletion + hub files stay unconditional
#   content-parity.sh    — headings, verbatim sentences, links, char-count
#   memory.sh            — memory index consistency and merge check
#
# These tests validate POST-IMPLEMENTATION state.
# Tests that reference .bak files or sub-files not yet created will SKIP or FAIL
# appropriately — that is expected behavior before implementation is complete.
#
# TL3 gap (what this test does NOT catch):
# - Whether Claude Code actually injects a rule file with valid `paths:` frontmatter
#   into the session context when a matching file is read or edited.
# - Whether a conditional rule is correctly withheld when no matching path is touched
#   in the session (over-injection / always-on regression).
# - Whether user-scope conditional matching fires at all through the
#   ~/.claude/rules symlink into this repo (host-specific symlink resolution).
# This test only validates frontmatter FORMAT statically. The runtime injection
# proof is obtained once, pre-merge, via a one-shot manual `claude -p` probe
# (session verification step V1) and is deliberately not committed as a test.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

if [ -z "$_TIMEOUT_WRAPPED" ]; then
    export _TIMEOUT_WRAPPED=1
    if command -v timeout >/dev/null 2>&1; then
        exec timeout 120 bash "$0" "$@"
    else
        exec perl -e 'alarm 120; exec @ARGV' -- bash "$0" "$@"
    fi
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MEMORY_DIR="$HOME/.claude/projects/c--git-agents/memory"
PARTS_DIR="$(dirname "${BASH_SOURCE[0]}")/refactor-rules-progressive-disclosure"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1: ${2:-}"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1: ${2:-}"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm '"$secs"'; exec @ARGV' -- "$@"
    fi
}

# ---------------------------------------------------------------------------
# Rename-done gate: skip rename-sensitive tests until rules/ rename is applied
# ---------------------------------------------------------------------------
RENAME_DONE=false
if [ -d "$REPO_ROOT/rules/docs" ] && [ -d "$REPO_ROOT/rules/test" ] && [ -f "$REPO_ROOT/rules/prompt.md" ]; then
    RENAME_DONE=true
fi

# ---------------------------------------------------------------------------
# Helper: extract YAML frontmatter block (between first --- and second ---)
# Prints lines between the delimiters (exclusive)
# ---------------------------------------------------------------------------
extract_frontmatter() {
    local file="$1"
    awk 'NR==1 && /^---/{in_fm=1; next} in_fm && /^---/{exit} in_fm{print}' "$file"
}

# ---------------------------------------------------------------------------
# Helper: check a file has valid paths: frontmatter (YAML list form)
# Returns 0 (success) and prints nothing if valid.
# Returns 1 and prints reason if invalid.
# ---------------------------------------------------------------------------
check_paths_frontmatter() {
    local file="$1"

    # (a) line 1 is --- and a terminating --- exists
    local first_line
    first_line="$(head -1 "$file" 2>/dev/null)"
    if [[ "$first_line" != "---" ]]; then
        echo "line 1 is not ---"
        return 1
    fi
    if ! awk 'NR==1 && /^---/{next} /^---/{found=1; exit} END{exit !found}' "$file"; then
        echo "no terminating --- for frontmatter block"
        return 1
    fi

    local fm
    fm="$(extract_frontmatter "$file")"

    # (b) exactly one ^paths: line, with no trailing value after the colon
    local paths_count
    paths_count="$(echo "$fm" | grep -c '^paths:' || true)"
    if [ "$paths_count" -ne 1 ]; then
        echo "expected exactly 1 'paths:' line in frontmatter, found $paths_count"
        return 1
    fi
    local paths_line
    paths_line="$(echo "$fm" | grep '^paths:')"
    if [ "$paths_line" != "paths:" ]; then
        echo "paths: must have no inline value (got: $paths_line)"
        return 1
    fi

    # (c) collect list items following paths: until a non-list line; empty set = FAIL
    local items
    items="$(echo "$fm" | awk '/^paths:$/{found=1; next} found{ if ($0 ~ /^[[:space:]]*-/) print; else exit }')"
    if [ -z "$items" ]; then
        echo "paths: has no list items"
        return 1
    fi

    local item_count=0
    while IFS= read -r item; do
        [ -z "$item" ] && continue
        item_count=$((item_count + 1))
        # (d) full-line shape: 2-space indent, '- ', double-quoted, no quote/backslash inside
        if ! echo "$item" | grep -qE '^  - "[^"\\]+"$'; then
            echo "malformed list item (expected '  - \"pattern\"'): $item"
            return 1
        fi
        # (e) reject .. and backslashes in every item
        if echo "$item" | grep -qE '\.\.|\\'; then
            echo "list item contains .. or backslash: $item"
            return 1
        fi
    done <<< "$items"

    # (f) no unexpected frontmatter keys
    local extra
    extra="$(echo "$fm" | grep -vE '^paths:$' | grep -vE '^[[:space:]]*-' | grep -vE '^[[:space:]]*$' || true)"
    if [ -n "$extra" ]; then
        echo "unexpected frontmatter key(s): $(echo "$extra" | tr '\n' ' ')"
        return 1
    fi

    # (g) OPTIONAL non-gating full-YAML sanity parse (skipped silently if unavailable)
    if command -v uv >/dev/null 2>&1; then
        local yaml_out
        yaml_out="$(printf '%s\n' "$fm" | run_with_timeout 60 uv run --with pyyaml python -c 'import sys,yaml; d=yaml.safe_load(sys.stdin.read()); sys.exit(0 if isinstance(d, dict) and isinstance(d.get("paths"), list) and d["paths"] else 3)' 2>&1)"
        local yaml_rc=$?
        if [ "$yaml_rc" -eq 3 ]; then
            echo "YAML parse: 'paths' is not a non-empty list"
            return 1
        fi
        # any other non-zero rc (uv/network/tooling failure) is ignored: non-gating
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Helper: count list items under paths: in a file's frontmatter
# ---------------------------------------------------------------------------
count_paths_items() {
    extract_paths_items "$1" | grep -c . || true
}

# ---------------------------------------------------------------------------
# Helper: print the paths: list item VALUES (unquoted patterns), one per line,
# in file order. Non-list lines terminate the block.
# ---------------------------------------------------------------------------
extract_paths_items() {
    local file="$1"
    extract_frontmatter "$file" \
        | awk '/^paths:$/{found=1; next} found{ if ($0 ~ /^[[:space:]]*-/) print; else exit }' \
        | sed -e 's/^[[:space:]]*-[[:space:]]*//' -e 's/^"//' -e 's/"$//'
}

# ---------------------------------------------------------------------------
# Helper: count chars in a file
# ---------------------------------------------------------------------------
file_charcount() {
    wc -c < "$1" | tr -d ' '
}

# ---------------------------------------------------------------------------
# Helper: extract ## and ### headings from a markdown file (heading text only)
# ---------------------------------------------------------------------------
extract_headings() {
    local file="$1"
    grep -E '^#{2,3} ' "$file" | sed 's/^#\+[[:space:]]*//'
}

# ---------------------------------------------------------------------------
# Test groups
# ---------------------------------------------------------------------------
# Fail-closed: a missing or unsourceable group file must FAIL, never silently
# reduce the run to zero assertions and exit 0.
for part in helper-fixtures paths-frontmatter cleanup content-parity memory; do
    part_file="$PARTS_DIR/$part.sh"
    if [ ! -f "$part_file" ]; then
        echo "FAIL: test group file missing: $part_file"
        FAIL=$((FAIL + 1))
        continue
    fi
    # shellcheck source=/dev/null
    if ! . "$part_file"; then
        echo "FAIL: test group failed to source: $part_file"
        FAIL=$((FAIL + 1))
    fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "============================================"
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "============================================"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
