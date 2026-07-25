#!/usr/bin/env bash
# Tests: rules/claude-config-source.md, rules/coding/file-split.md, rules/coding/nodejs.md, rules/coding/python.md, rules/docs/architecture.md, rules/docs/changelog.md, rules/docs/env-example.md, rules/docs/history.md, rules/docs/readme.md, rules/docs/todo.md, rules/installer.md, rules/prompt.md, rules/test/claude-e2e.md, rules/test/installer.md, rules/test/macos-timeout.md
# Tags: frontmatter, rules, paths, scope:common
# Part of tests/refactor-rules-progressive-disclosure.sh — sourced, not run directly.
# Test 1: exact paths: file set + per-file exact pattern list + format validity
# Test 2: no remaining globs: frontmatter under rules/
#
# Fail-closed: this group never SKIPs. If the rules/ rename has not landed the
# contract FAILS naming the missing path — a checkout without the conversion
# must not pass CI with zero assertions run.

# ---------------------------------------------------------------------------
# Expected post-conversion state:
#   <repo-relative path>|<pattern>|<pattern>|...
# Patterns are the verbatim, ordered values carried over from the pre-conversion
# globs: comma-separated string. This is the pinned contract — any addition,
# removal, reorder, or edit of a pattern fails.
# ---------------------------------------------------------------------------
EXPECTED_PATHS_SPEC="$(cat <<'SPEC'
rules/claude-config-source.md|**/docker-compose.yml|**/docker-compose.yaml|**/docker-compose.*.yml|**/docker-compose.*.yaml|**/compose.yml|**/compose.yaml|**/Dockerfile|**/Dockerfile.*|**/.env|**/.env.*
rules/coding/file-split.md|**/*.js|**/*.ts|**/*.py|**/*.sh|rules/**/*.md|skills/**/SKILL.md|agents/**/*.md
rules/coding/nodejs.md|**/*.js|**/*.ts|**/*.mjs|**/*.cjs|**/package.json|**/.nvmrc|**/.node-version
rules/coding/python.md|**/*.py|**/pyproject.toml|**/uv.lock|**/requirements.txt|**/setup.py|**/setup.cfg
rules/docs/architecture.md|docs/architecture.md|docs/architecture/**/*.md
rules/docs/changelog.md|CHANGELOG.md|docs/CHANGELOG.md
rules/docs/env-example.md|**/.env.example|**/.env.sample|**/.env.template|**/.env.dist
rules/docs/history.md|docs/history.md|docs/history/**/*.md
rules/docs/readme.md|README.md
rules/docs/todo.md|docs/todo.md
rules/installer.md|install/**|**/*.ps1|**/*.nsi|**/*.iss
rules/prompt.md|rules/**/*.md|skills/**/SKILL.md|agents/**/*.md
rules/test/claude-e2e.md|tests/**|**/*.sh|**/*.Tests.ps1|test_*.py|**/*.spec.*
rules/test/installer.md|install/**|**/*.Tests.ps1
rules/test/macos-timeout.md|tests/**|**/*.sh|**/*.Tests.ps1
SPEC
)"

echo "=== Test 1: paths: frontmatter validity ==="

# Fail-closed rename gate: report every expected path that is absent.
if [ "$RENAME_DONE" = "false" ]; then
    rename_missing=""
    [ -d "$REPO_ROOT/rules/docs" ]     || rename_missing="$rename_missing rules/docs/"
    [ -d "$REPO_ROOT/rules/test" ]     || rename_missing="$rename_missing rules/test/"
    [ -f "$REPO_ROOT/rules/prompt.md" ] || rename_missing="$rename_missing rules/prompt.md"
    fail "T1: rules/ rename incomplete" "missing expected path(s):${rename_missing} — paths: contract cannot hold"
fi

# Dynamic enumeration: all tracked rules/*.md (root-level included), then select
# the ones carrying a paths: frontmatter key.
PATHS_FILES=()
while IFS= read -r rel; do
    [ -n "$rel" ] && PATHS_FILES+=("$rel")
done < <(cd "$REPO_ROOT" && git ls-files -- rules | grep '\.md$' | xargs grep -ln '^paths:' 2>/dev/null)

EXPECTED_LIST="$(echo "$EXPECTED_PATHS_SPEC" | cut -d'|' -f1 | sort)"
ACTUAL_LIST="$(printf '%s\n' "${PATHS_FILES[@]}" | grep -v '^$' | sort)"

MISSING="$(comm -23 <(echo "$EXPECTED_LIST") <(echo "$ACTUAL_LIST") | tr '\n' ' ')"
UNEXPECTED="$(comm -13 <(echo "$EXPECTED_LIST") <(echo "$ACTUAL_LIST") | tr '\n' ' ')"

if [ -z "${MISSING// /}" ] && [ -z "${UNEXPECTED// /}" ]; then
    pass "T1: paths: file set matches the expected 15-file contract exactly"
else
    fail "T1: paths: file set" "missing: [${MISSING% }] unexpected: [${UNEXPECTED% }]"
fi

# Per-file exact pattern list (ordered) + format validation
while IFS='|' read -r rel want_rest; do
    [ -z "$rel" ] && continue
    abs="$REPO_ROOT/$rel"
    if [ ! -f "$abs" ]; then
        fail "T1: $rel" "file not found"
        continue
    fi
    want_items="$(printf '%s' "$want_rest" | tr '|' '\n')"
    got_items="$(extract_paths_items "$abs")"
    if [ "$got_items" = "$want_items" ]; then
        pass "T1: $rel — paths: patterns match exactly ($(echo "$want_items" | grep -c .) items)"
    else
        fail "T1: $rel pattern list" \
            "expected [$(echo "$want_items" | tr '\n' ' ')] got [$(echo "$got_items" | tr '\n' ' ')]"
    fi
    if reason="$(check_paths_frontmatter "$abs")"; then
        pass "T1: $rel — valid paths: frontmatter"
    else
        fail "T1: $rel" "$reason"
    fi
done <<< "$EXPECTED_PATHS_SPEC"

echo ""

# ---------------------------------------------------------------------------
# Test 2 — No remaining globs: frontmatter under rules/
# ---------------------------------------------------------------------------
echo "=== Test 2: No globs: frontmatter under rules/ ==="

found_globs_fm=0
while IFS= read -r -d '' f; do
    fm="$(extract_frontmatter "$f")"
    if echo "$fm" | grep -qE '^globs:'; then
        fail "T2: obsolete globs: frontmatter found in $f"
        found_globs_fm=1
    fi
done < <(find "$REPO_ROOT/rules" -name "*.md" -print0 2>/dev/null)

if [ "$found_globs_fm" -eq 0 ]; then
    pass "T2: No globs: frontmatter found in any rules/ file"
fi

echo ""
