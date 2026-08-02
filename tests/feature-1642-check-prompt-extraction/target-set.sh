#!/usr/bin/env bash
# tests/feature-1642-check-prompt-extraction/target-set.sh
# Tests: bin/check-prompt-extraction, bin/lib/prompt-extraction/targets.js
# Tags: prompt, bin, prompt-extraction, target-set, base-mode, scope:issue-specific, scope:feature-1642, layer:TL2
#
# Issue #1642 — target enumeration contract for the extraction gate.
#
# The target set is the SSOT-in-code (bin/lib/prompt-extraction/targets.js) and is a
# deliberate superset of the prose in rules/prompt.md:10 (detail plan, C6 決定):
#   rules/**/*.md, skills/*/SKILL.md, agents/**/*.md, skills/_shared/**/*.md,
#   skills/*/agents/**/*.md
# Excluded: _archived/, _archive/, node_modules/, .git/
#
# Split out of tests/feature-1642-check-prompt-extraction.sh per
# rules/coding/file-split.md Pattern A (500-line HARD limit). The sibling file owns
# detection semantics; this one owns "which files are looked at at all" plus the
# --base mode that selects them from a git ref. Setup boilerplate is duplicated
# deliberately: a shared helpers.sh would couple files that must stay independently
# runnable by the test runner.
#
# TL3 gap (what this test does NOT catch):
# - Glob behaviour against the real repository layout (117 tracked prompt files);
#   fixtures use a synthetic tree. Covered at audit time by --all against the checkout.
# Closest-to-action mitigation: bin/check-verification-gate.sh category: installer.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$AGENTS_DIR/bin/check-prompt-extraction"

if [ ! -f "$CLI" ]; then
    echo "SKIP: bin/check-prompt-extraction not found (issue #1642 not implemented yet)"
    exit 77
fi

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

EMPTY_HOOKS_DIR="$TMPDIR_BASE/no-hooks"
mkdir -p "$EMPTY_HOOKS_DIR"

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

make_repo() {
    local repo="$TMPDIR_BASE/$1"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config core.hooksPath "$EMPTY_HOOKS_DIR"
    git -C "$repo" config core.autocrlf false
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
    echo "$repo"
}

write_file() {
    local repo="$1" rel="$2"
    mkdir -p "$repo/$(dirname "$rel")"
    cat > "$repo/$rel"
}

OUT=""
RC=0
run_cli() {
    local repo="$1"; shift
    RC=0
    OUT="$(cd "$repo" && run_with_timeout 60 bash "$CLI" "$@" 2>&1)" || RC=$?
}

assert_rc() {
    local label="$1" want="$2"
    if [ "$RC" -eq "$want" ]; then
        pass "$label (exit $want)"
    else
        fail "$label: expected exit $want, got $RC" "$OUT"
    fi
}

assert_contains() {
    local label="$1" needle="$2"
    if printf '%s\n' "$OUT" | grep -q -- "$needle"; then
        pass "$label"
    else
        fail "$label: output missing '$needle'" "$OUT"
    fi
}

assert_not_contains() {
    local label="$1" needle="$2"
    if printf '%s\n' "$OUT" | grep -q -- "$needle"; then
        fail "$label: output unexpectedly contains '$needle'" "$OUT"
    else
        pass "$label"
    fi
}

emit_fence() {
    local n="$1" i
    echo '```bash'
    for ((i = 1; i <= n; i++)); do echo "echo line $i"; done
    echo '```'
}

# ============================================================================
# TS01 — target-set membership (table-driven)
#
# One repo holds a violating file at every candidate path. A single --all run
# then decides membership per path: an included path must appear in the report,
# an excluded path must never appear.
# ============================================================================

TS_TABLE='
rules-flat            | rules/flat.md                          | in
rules-nested          | rules/nested/deep/rule.md              | in
skill-md              | skills/demo/SKILL.md                   | in
agents-flat           | agents/flat.md                         | in
agents-nested         | agents/nested/deep/worker.md           | in
shared-flat           | skills/_shared/shared.md               | in
shared-nested         | skills/_shared/test-design/nested.md   | in
skill-agents-nested   | skills/demo/agents/nested/worker.md    | in
skill-scripts-md      | skills/demo/scripts/notes.md           | out
archived-dir          | skills/_archived/old/SKILL.md          | out
archive-dir           | skills/_archive/old/SKILL.md           | out
node-modules          | node_modules/pkg/rules/vendor.md       | out
docs-md               | docs/architecture/design.md            | out
readme-root           | README-extra.md                        | out
'

ts01_membership() {
    local repo; repo="$(make_repo ts01)"
    local name rel want
    # Populate every path with an unambiguous 8-line fence violation.
    while IFS='|' read -r name rel want; do
        [ -z "${name// /}" ] && continue
        case "${name## }" in \#*) continue ;; esac
        rel="${rel//[[:space:]]/}"
        { echo "# Doc"; echo ""; emit_fence 8; } | write_file "$repo" "$rel"
    done <<< "$TS_TABLE"

    git -C "$repo" add -A
    git -C "$repo" commit -q -m "populate candidate target paths"
    run_cli "$repo" --all --no-allowlist
    assert_rc "TS01: --all always exits 0" 0

    while IFS='|' read -r name rel want; do
        [ -z "${name// /}" ] && continue
        case "${name## }" in \#*) continue ;; esac
        name="${name//[[:space:]]/}"
        rel="${rel//[[:space:]]/}"
        want="${want//[[:space:]]/}"
        if [ "$want" = "in" ]; then
            assert_contains "TS01/$name: $rel is inside the target set" "$rel"
        else
            assert_not_contains "TS01/$name: $rel is outside the target set" "$rel"
        fi
    done <<< "$TS_TABLE"
}

# TS02: the two archive spellings are both excluded, checked by directory token
#       rather than by full path (guards a regex that matches only one spelling).
ts02_archive_spellings() {
    local repo; repo="$(make_repo ts02)"
    { echo "# Old"; echo ""; emit_fence 9; } | write_file "$repo" skills/_archived/a/SKILL.md
    { echo "# Old"; echo ""; emit_fence 9; } | write_file "$repo" skills/_archive/b/SKILL.md
    { echo "# Old"; echo ""; emit_fence 9; } | write_file "$repo" rules/_archive/c.md
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "add archived trees"
    run_cli "$repo" --all --no-allowlist
    assert_rc "TS02: --all always exits 0" 0
    assert_not_contains "TS02: '_archived' never enumerated" "_archived"
    assert_not_contains "TS02: '_archive' never enumerated" "_archive"
}

# ============================================================================
# TS03..TS06 — --base <ref> mode
#
# --base compares against a git ref and reads the WORKING TREE (unlike --staged,
# which reads the index). Only files that differ from the ref are inspected.
# ============================================================================

# TS03: a violation introduced after the base ref is reported and blocks.
ts03_base_reports_new_violation() {
    local repo; repo="$(make_repo ts03)"
    { echo "# Doc"; echo ""; echo "lean."; } | write_file "$repo" rules/a.md
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "clean base"
    local base; base="$(git -C "$repo" rev-parse HEAD)"

    git -C "$repo" checkout -q -b feature
    { echo "# Doc"; echo ""; emit_fence 7; } | write_file "$repo" rules/a.md
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "introduce a fence"

    run_cli "$repo" --base "$base" --no-allowlist
    assert_rc "TS03: --base blocks on a violation added after the ref" 1
    assert_contains "TS03: violation names rules/a.md" "rules/a.md"
}

# TS04: pre-existing violations that are unchanged since the base are not reported.
ts04_base_ignores_unchanged() {
    local repo; repo="$(make_repo ts04)"
    { echo "# Doc"; echo ""; emit_fence 7; } | write_file "$repo" rules/old.md
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "pre-existing debt"
    local base; base="$(git -C "$repo" rev-parse HEAD)"

    git -C "$repo" checkout -q -b feature
    { echo "# Doc"; echo ""; echo "lean."; } | write_file "$repo" rules/new.md
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "add an unrelated lean file"

    run_cli "$repo" --base "$base" --no-allowlist
    assert_rc "TS04: --base ignores debt that predates the ref" 0
    assert_not_contains "TS04: unchanged rules/old.md not reported" "rules/old.md"
}

# TS05: --base reads the WORKING TREE, not the index (the --staged counterpart).
ts05_base_reads_worktree() {
    local repo; repo="$(make_repo ts05)"
    { echo "# Doc"; echo ""; echo "lean."; } | write_file "$repo" rules/a.md
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "clean base"
    local base; base="$(git -C "$repo" rev-parse HEAD)"

    git -C "$repo" checkout -q -b feature
    # Uncommitted, unstaged working-tree edit.
    { echo "# Doc"; echo ""; emit_fence 7; } | write_file "$repo" rules/a.md

    run_cli "$repo" --base "$base" --no-allowlist
    assert_rc "TS05: --base sees the uncommitted working-tree edit" 1
    assert_contains "TS05: working-tree violation named" "rules/a.md"
}

# TS06: an unresolvable base ref is an infra error, exit 3.
ts06_base_bad_ref() {
    local repo; repo="$(make_repo ts06)"
    run_cli "$repo" --base refs/heads/does-not-exist --no-allowlist
    assert_rc "TS06: unresolvable --base ref" 3
}

run_all() {
    ts01_membership
    ts02_archive_spellings
    ts03_base_reports_new_violation
    ts04_base_ignores_unchanged
    ts05_base_reads_worktree
    ts06_base_bad_ref
}

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
