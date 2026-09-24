#!/usr/bin/env bash
# Tests: skills/_shared/test-design/parser-regex-tests.md
# Tags: frontmatter, table-driven, fixtures, scope:common
# Part of tests/refactor-rules-progressive-disclosure.sh — sourced, not run directly.
# Test 0: table-driven fixtures for the check_paths_frontmatter helper itself.
# These assertions must PASS regardless of the rules/ conversion state — they
# exercise the validator, not the repository content.

echo "=== Test 0: check_paths_frontmatter fixture table ==="

FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

# Write fixture $1 into "$FIXTURE_DIR/$1.md".
make_fixture() {
    local id="$1"
    local out="$FIXTURE_DIR/$id.md"
    case "$id" in
        valid-multi)
            printf '%s\n' '---' 'paths:' '  - "rules/**/*.md"' '  - "docs/*.md"' '---' '' '# Body' > "$out" ;;
        valid-single)
            printf '%s\n' '---' 'paths:' '  - "rules/docs/todo.md"' '---' '' '# Body' > "$out" ;;
        missing-open)
            printf '%s\n' 'paths:' '  - "rules/*.md"' '---' '' '# Body' > "$out" ;;
        missing-close)
            printf '%s\n' '---' 'paths:' '  - "rules/*.md"' '' '# Body' > "$out" ;;
        inline-scalar)
            printf '%s\n' '---' 'paths: "rules/*.md"' '---' '' '# Body' > "$out" ;;
        empty-list)
            printf '%s\n' '---' 'paths:' '---' '' '# Body' > "$out" ;;
        unquoted-item)
            printf '%s\n' '---' 'paths:' '  - rules/*.md' '---' '' '# Body' > "$out" ;;
        wrong-indent)
            printf '%s\n' '---' 'paths:' '    - "rules/*.md"' '---' '' '# Body' > "$out" ;;
        dotdot-item)
            printf '%s\n' '---' 'paths:' '  - "../secrets/*.md"' '---' '' '# Body' > "$out" ;;
        backslash-item)
            printf '%s\n' '---' 'paths:' '  - "rules\\docs\\todo.md"' '---' '' '# Body' > "$out" ;;
        duplicate-paths)
            printf '%s\n' '---' 'paths:' '  - "rules/*.md"' 'paths:' '  - "docs/*.md"' '---' '' '# Body' > "$out" ;;
        extra-key)
            printf '%s\n' '---' 'description: extra key not allowed' 'paths:' '  - "rules/*.md"' '---' '' '# Body' > "$out" ;;
        *)
            echo "unknown fixture id: $id" >&2; return 1 ;;
    esac
    echo "$out"
}

while IFS='|' read -r name id want_rc; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    id="${id//[[:space:]]/}"
    want_rc="${want_rc//[[:space:]]/}"

    fixture_path="$(make_fixture "$id")" || { fail "T0: $name" "fixture generation failed"; continue; }

    reason="$(check_paths_frontmatter "$fixture_path")"
    got_rc=$?

    if [ "$got_rc" != "$want_rc" ]; then
        fail "T0: $name" "expected rc=$want_rc, got rc=$got_rc (reason: ${reason:-<empty>})"
        continue
    fi

    if [ "$want_rc" = "1" ] && [ -z "$reason" ]; then
        fail "T0: $name" "rejected with rc=1 but printed no reason text"
        continue
    fi
    if [ "$want_rc" = "0" ] && [ -n "$reason" ]; then
        fail "T0: $name" "accepted with rc=0 but printed unexpected output: $reason"
        continue
    fi

    pass "T0: $name — rc=$got_rc as expected"
done <<'TABLE'
valid-multi       | valid-multi      | 0
valid-single      | valid-single     | 0
missing-open      | missing-open     | 1
missing-close     | missing-close    | 1
inline-scalar     | inline-scalar    | 1
empty-list        | empty-list       | 1
unquoted-item     | unquoted-item    | 1
wrong-indent      | wrong-indent     | 1
dotdot-item       | dotdot-item      | 1
backslash-item    | backslash-item   | 1
duplicate-paths   | duplicate-paths  | 1
extra-key         | extra-key        | 1
TABLE

echo ""
