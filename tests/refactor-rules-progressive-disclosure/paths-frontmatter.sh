#!/usr/bin/env bash
# Tests: hooks/lib/rules-injection-policy.js, rules/branch.md, rules/claude-config-source.md, rules/coding.md, rules/coding/file-split.md, rules/coding/nodejs.md, rules/coding/python.md, rules/core-principles.md, rules/docs-only-short-circuit.md, rules/docs.md, rules/docs/architecture.md, rules/docs/changelog.md, rules/docs/env-example.md, rules/docs/history.md, rules/docs/readme.md, rules/docs/todo.md, rules/git.md, rules/github-issues.md, rules/installer.md, rules/issue-close-verified.md, rules/mid-workflow-findings.md, rules/ops.md, rules/prompt.md, rules/shell-commands.md, rules/stop-guard-exemptions.md, rules/supervisor-reporting.md, rules/test.md, rules/test/claude-e2e.md, rules/test/fixture-isolation.md, rules/test/installer.md, rules/test/macos-timeout.md, rules/user-escalation.md, rules/workflow-off.md, rules/worktree.md
# Tags: frontmatter, rules, paths, on-demand-rules, rules-injection, scope:common
# Part of tests/refactor-rules-progressive-disclosure.sh — sourced, not run directly.
# Test 1: the three rules-injection classes, asserted separately: T1-A conditional rules (exact ordered pattern list + format validity); T1-B on-demand rules (paths: is EXACTLY [ON_DEMAND_TOKEN], length is load-bearing); T1-C set equality (enumerated paths:-carrying set == T1-A ∪ T1-B); T1-D unconditional set (every EXPECTED_UNCONDITIONAL entry carries no paths: key); T1-E token containment (reserved token appears in no other rules file). Test 2: no remaining globs: frontmatter under rules/.
# Why separate: a conditional rule and an on-demand rule carry opposite invariants — conditional must keep its exact globs; on-demand must carry the reserved never-match token and NOTHING else (`paths:` is OR-semantics, so a second element silently restores injection). A single count-or-membership assertion over the union would pass through both regressions.
# The policy SSOT (hooks/lib/rules-injection-policy.js) is read AS DATA by text-matching its literal declarations — never require()d or executed, since it's contributor-editable and evaluating it from the harness would run arbitrary code on every developer's machine (same contract as bin/check-on-demand-rules.sh's P11 case in tests/bin-check-on-demand-rules.sh).
# Fail-closed: this group never SKIPs. If the rules/ rename has not landed the contract FAILS naming the missing path — a checkout without the conversion must not pass CI with zero assertions run. Likewise an empty or unparseable SSOT array FAILS loudly instead of reducing T1-B/T1-D to zero assertions.

# ---------------------------------------------------------------------------
# Expected CONDITIONAL rules (T1-A):
#   <repo-relative path>|<pattern>|<pattern>|...
# Patterns are the verbatim, ordered values. This is the pinned contract — any
# addition, removal, reorder, or edit of a pattern fails.
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
rules/test/fixture-isolation.md|tests/**|**/*.sh|**/*.Tests.ps1|test_*.py|**/*.spec.*
rules/test/installer.md|install/**|**/*.Tests.ps1
rules/test/macos-timeout.md|tests/**|**/*.sh|**/*.Tests.ps1
SPEC
)"

POLICY_FILE="$REPO_ROOT/hooks/lib/rules-injection-policy.js"

# ---------------------------------------------------------------------------
# SSOT readers — text-matching only. Never require(), never node -e.
# ---------------------------------------------------------------------------
policy_string_const() {
    sed -n "s/^const $1 = \"\\(.*\\)\";[[:space:]]*\$/\\1/p" "$POLICY_FILE" 2>/dev/null | head -1
}

# Reads `const <NAME> = [ "a", "b" ];` — multi-line or single-line — and prints the
# string literals one per line. The closing `]` terminates the block on whatever line
# it appears, so an EMPTY array cannot silently absorb the NEXT declaration's items
# (that would turn a wiped-out allowlist into a plausible-looking one).
policy_string_array() {
    awk -v name="$1" '
        function emit(s,   done, p) {
            p = index(s, "]")
            if (p > 0) { s = substr(s, 1, p - 1); done = 1 }
            while (match(s, /"[^"]*"/)) {
                print substr(s, RSTART + 1, RLENGTH - 2)
                s = substr(s, RSTART + RLENGTH)
            }
            return done
        }
        !inarr && index($0, "const " name " = [") == 1 {
            inarr = 1
            if (emit(substr($0, index($0, "[") + 1))) exit
            next
        }
        inarr { if (emit($0)) exit }
    ' "$POLICY_FILE" 2>/dev/null
}

echo "=== Test 1: rules-injection scope contract ==="

# Fail-closed rename gate: report every expected path that is absent.
if [ "$RENAME_DONE" = "false" ]; then
    rename_missing=""
    [ -d "$REPO_ROOT/rules/docs" ]     || rename_missing="$rename_missing rules/docs/"
    [ -d "$REPO_ROOT/rules/test" ]     || rename_missing="$rename_missing rules/test/"
    [ -f "$REPO_ROOT/rules/prompt.md" ] || rename_missing="$rename_missing rules/prompt.md"
    fail "T1: rules/ rename incomplete" "missing expected path(s):${rename_missing} — paths: contract cannot hold"
fi

# ---------------------------------------------------------------------------
# T1-0 — SSOT parse guard.
# Every T1-B / T1-D assertion is derived from these arrays. An empty or
# unparseable array would silently run zero assertions and report green, so the
# parse result is asserted before anything consumes it.
# ---------------------------------------------------------------------------
if [ ! -f "$POLICY_FILE" ]; then
    fail "T1-0: rules-injection policy SSOT" "file not found: hooks/lib/rules-injection-policy.js"
    ON_DEMAND_TOKEN=""
    ON_DEMAND_FILES_LIST=""
    EXPECTED_UNCONDITIONAL_LIST=""
else
    ON_DEMAND_TOKEN="$(policy_string_const ON_DEMAND_TOKEN)"
    # #2037: the rule name is the KEY half of each ON_DEMAND_READERS row, so the
    # on-demand set is that column. There is no ON_DEMAND_FILES literal left to read.
    ON_DEMAND_FILES_LIST="$(policy_string_array ON_DEMAND_READERS | cut -d"|" -f1)"
    EXPECTED_UNCONDITIONAL_LIST="$(policy_string_array EXPECTED_UNCONDITIONAL)"

    if [ -n "$ON_DEMAND_TOKEN" ]; then
        pass "T1-0: ON_DEMAND_TOKEN parsed from the SSOT as data ($ON_DEMAND_TOKEN)"
    else
        fail "T1-0: ON_DEMAND_TOKEN" "not parseable as a one-line string literal — T1-B/T1-E would be vacuous"
    fi

    od_n="$(printf '%s\n' "$ON_DEMAND_FILES_LIST" | grep -c . || true)"
    if [ "$od_n" -gt 0 ]; then
        pass "T1-0: ON_DEMAND_READERS parsed non-empty ($od_n entries) so T1-B is live"
    else
        fail "T1-0: ON_DEMAND_READERS" "parsed as empty/unparseable — the T1-B assertions would be vacuous"
    fi

    eu_n="$(printf '%s\n' "$EXPECTED_UNCONDITIONAL_LIST" | grep -c . || true)"
    if [ "$eu_n" -gt 0 ]; then
        pass "T1-0: EXPECTED_UNCONDITIONAL parsed non-empty ($eu_n entries) so T1-D is live"
    else
        fail "T1-0: EXPECTED_UNCONDITIONAL" "parsed as empty/unparseable — the T1-D assertions would be vacuous"
    fi
fi

# ---------------------------------------------------------------------------
# T1-A — conditional rules: exact ordered pattern list + format validity
# ---------------------------------------------------------------------------
while IFS='|' read -r rel want_rest; do
    [ -z "$rel" ] && continue
    abs="$REPO_ROOT/$rel"
    if [ ! -f "$abs" ]; then
        fail "T1-A: $rel" "file not found"
        continue
    fi
    want_items="$(printf '%s' "$want_rest" | tr '|' '\n')"
    got_items="$(extract_paths_items "$abs")"
    if [ "$got_items" = "$want_items" ]; then
        pass "T1-A: $rel — paths: patterns match exactly ($(echo "$want_items" | grep -c .) items)"
    else
        fail "T1-A: $rel pattern list" \
            "expected [$(echo "$want_items" | tr '\n' ' ')] got [$(echo "$got_items" | tr '\n' ' ')]"
    fi
    if reason="$(check_paths_frontmatter "$abs")"; then
        pass "T1-A: $rel — valid paths: frontmatter"
    else
        fail "T1-A: $rel" "$reason"
    fi
done <<< "$EXPECTED_PATHS_SPEC"

# ---------------------------------------------------------------------------
# T1-B — on-demand rules: paths: is EXACTLY one element, the reserved token.
# The length assertion is the load-bearing half: paths: matching is OR-semantics,
# so token + any real glob re-enables injection while still looking de-injected.
# ---------------------------------------------------------------------------
while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    abs="$REPO_ROOT/$rel"
    if [ ! -f "$abs" ]; then
        fail "T1-B: $rel" "listed in ON_DEMAND_READERS but the file does not exist"
        continue
    fi
    if reason="$(check_paths_frontmatter "$abs")"; then
        pass "T1-B: $rel — valid paths: frontmatter"
    else
        fail "T1-B: $rel" "$reason"
    fi
    items="$(extract_paths_items "$abs")"
    n="$(printf '%s\n' "$items" | grep -c . || true)"
    if [ "$n" -eq 0 ]; then
        fail "T1-B: $rel exactly-one-token" \
            "no paths: list items — the rule lost its de-injection and is now injected into every session"
    elif [ "$n" -ne 1 ]; then
        fail "T1-B: $rel exactly-one-token" \
            "$n paths: items [$(printf '%s' "$items" | tr '\n' ' ')] — paths: is OR-semantics, so any second element re-enables injection"
    elif [ "$items" != "$ON_DEMAND_TOKEN" ]; then
        fail "T1-B: $rel exactly-one-token" \
            "sole paths: item is [$items], expected the reserved token [$ON_DEMAND_TOKEN]"
    else
        pass "T1-B: $rel — paths: is exactly the reserved never-match token"
    fi
done <<< "$ON_DEMAND_FILES_LIST"

# ---------------------------------------------------------------------------
# T1-C — set equality: enumerated paths:-carrying rules == T1-A ∪ T1-B
# ---------------------------------------------------------------------------
PATHS_FILES=()
while IFS= read -r rel; do
    [ -n "$rel" ] && PATHS_FILES+=("$rel")
done < <(cd "$REPO_ROOT" && git ls-files -- rules | grep '\.md$' | xargs grep -ln '^paths:' 2>/dev/null)

EXPECTED_LIST="$( { echo "$EXPECTED_PATHS_SPEC" | cut -d'|' -f1; printf '%s\n' "$ON_DEMAND_FILES_LIST"; } | grep -v '^$' | sort -u)"
ACTUAL_LIST="$(printf '%s\n' "${PATHS_FILES[@]}" | grep -v '^$' | sort -u)"

MISSING="$(comm -23 <(echo "$EXPECTED_LIST") <(echo "$ACTUAL_LIST") | tr '\n' ' ')"
UNEXPECTED="$(comm -13 <(echo "$EXPECTED_LIST") <(echo "$ACTUAL_LIST") | tr '\n' ' ')"

if [ -z "${MISSING// /}" ] && [ -z "${UNEXPECTED// /}" ]; then
    pass "T1-C: paths:-carrying rules == conditional ∪ on-demand exactly ($(echo "$EXPECTED_LIST" | grep -c .) files)"
else
    fail "T1-C: paths: file set" "missing: [${MISSING% }] unexpected: [${UNEXPECTED% }]"
fi

# ---------------------------------------------------------------------------
# T1-D — unconditional set: every EXPECTED_UNCONDITIONAL entry carries no
# paths: key at all. Derived from the SSOT so all entries are covered, not the
# hand-picked subset T9 used to check.
# ---------------------------------------------------------------------------
uncond_bad=""
uncond_missing=""
uncond_n=0
while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    abs="$REPO_ROOT/$rel"
    if [ ! -f "$abs" ]; then
        uncond_missing="$uncond_missing $rel"
        continue
    fi
    uncond_n=$((uncond_n + 1))
    if extract_frontmatter "$abs" | grep -q '^paths:'; then
        uncond_bad="$uncond_bad $rel"
    fi
done <<< "$EXPECTED_UNCONDITIONAL_LIST"

if [ -n "$uncond_missing" ]; then
    fail "T1-D: unconditional rules exist" "listed in EXPECTED_UNCONDITIONAL but not on disk:${uncond_missing}"
else
    pass "T1-D: every EXPECTED_UNCONDITIONAL entry exists on disk ($uncond_n files)"
fi

if [ -n "$uncond_bad" ]; then
    fail "T1-D: unconditional rules carry no paths:" \
        "gained a paths: key and is no longer injected unconditionally:${uncond_bad}"
elif [ "$uncond_n" -gt 0 ]; then
    pass "T1-D: all $uncond_n EXPECTED_UNCONDITIONAL rules carry no paths: key"
fi

# ---------------------------------------------------------------------------
# T1-E — token containment: the reserved never-match token may appear in no
# rules file other than the registered on-demand ones. Catches a conditional or
# unconditional rule quietly acquiring the de-injection token.
# ---------------------------------------------------------------------------
if [ -n "$ON_DEMAND_TOKEN" ]; then
    TOKEN_FILES="$(cd "$REPO_ROOT" && git ls-files -- rules | grep '\.md$' | xargs grep -lF -- "$ON_DEMAND_TOKEN" 2>/dev/null | sort -u)"
    OD_SORTED="$(printf '%s\n' "$ON_DEMAND_FILES_LIST" | grep -v '^$' | sort -u)"
    TOK_EXTRA="$(comm -13 <(echo "$OD_SORTED") <(echo "$TOKEN_FILES") | tr '\n' ' ')"
    TOK_LOST="$(comm -23 <(echo "$OD_SORTED") <(echo "$TOKEN_FILES") | tr '\n' ' ')"
    if [ -z "${TOK_EXTRA// /}" ] && [ -z "${TOK_LOST// /}" ]; then
        pass "T1-E: the reserved token appears in exactly the ON_DEMAND_READERS rules"
    else
        fail "T1-E: reserved-token containment" \
            "unregistered files carrying the token: [${TOK_EXTRA% }]; registered files without it: [${TOK_LOST% }]"
    fi
fi

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
