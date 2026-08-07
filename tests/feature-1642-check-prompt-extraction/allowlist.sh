#!/usr/bin/env bash
# tests/feature-1642-check-prompt-extraction/allowlist.sh
# Tests: bin/check-prompt-extraction, bin/lib/prompt-extraction/allowlist.js
# Tags: prompt, bin, prompt-extraction, allowlist, table-driven, write-allowlist, scope:issue-specific, scope:feature-1642, layer:TL2
#
# Issue #1642 — allowlist contract for the extraction gate.
#
# Owns: allowlist parsing, (kind, path, count) matching, wildcard exemption, STALE
# reporting, --advisory's no-allowlist implication (detail plan C4 決定),
# --allowlist-total's machine-readable line (C3 決定), --write-allowlist baseline
# generation (D2), and the --staged index-vs-working-tree precedence of the
# allowlist file itself.
#
# The allowlist is a parser/allowlist target, so the parse and match assertions are
# table-driven per skills/_shared/test-design/parser-regex-tests.md.
#
# --allowlist-total output contract (detail plan C3 決定) is exactly one line:
#     TOTAL <n> WILDCARD <m> ENTRIES <e>
#   TOTAL    = sum of the <count> field over NON-wildcard entries (not the row count)
#   WILDCARD = number of entries whose <count> is '*'
#   ENTRIES  = total entry rows (diagnostic only; the ratchet does not judge on it)
#
# Split out of tests/feature-1642-check-prompt-extraction.sh per
# rules/coding/file-split.md Pattern A (500-line HARD limit). Setup boilerplate is
# duplicated deliberately: a shared helpers.sh would couple files that must stay
# independently runnable by the test runner.
#
# TL3 gap (what this test does NOT catch):
# - The committed repo-root .prompt-extraction-allowlist actually shrinking over time;
#   that ratchet lives in tests/feature-1642-prompt-extraction-static-guards.sh.
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

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$name"
    else
        fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
    fi
}

# trim leading/trailing whitespace
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

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

stage() { git -C "$1" add -A -- "$2"; }

OUT=""
RC=0
run_cli() {
    local repo="$1"; shift
    RC=0
    OUT="$(cd "$repo" && run_with_timeout 60 bash "$CLI" "$@" 2>&1)" || RC=$?
}

run_cli_stdin() {
    local repo="$1" input="$2"; shift 2
    RC=0
    OUT="$(cd "$repo" && printf '%s' "$input" | run_with_timeout 60 bash "$CLI" "$@" 2>&1)" || RC=$?
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

# emit_fences <n> -> a document containing <n> separate 4-line fences
emit_doc_with_fences() {
    local n="$1" i
    echo "# Doc"
    for ((i = 1; i <= n; i++)); do
        echo ""
        echo "## Section $i"
        echo ""
        emit_fence 4
    done
}

# ============================================================================
# AL01 — allowlist parsing / --allowlist-total (table-driven)
#
# Each row feeds an allowlist blob on stdin and asserts the full contracted line.
# '\n' in the input column is expanded by printf %b.
# ============================================================================
al01_total_table() {
    local repo; repo="$(make_repo al01)"
    local name input want got
    while IFS='|' read -r name input want; do
        name="$(trim "$name")"
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        want="$(trim "$want")"
        input="$(printf '%b' "$(trim "$input")")"
        run_cli_stdin "$repo" "$input" --allowlist-total --allowlist-file -
        if [ "$RC" -ne 0 ]; then
            fail "AL01/$name: --allowlist-total exited $RC, expected 0" "$OUT"
            continue
        fi
        got="$(printf '%s\n' "$OUT" | grep -m1 '^TOTAL ' || true)"
        assert_eq "AL01/$name" "$want" "$got"
    done <<'TABLE'
sum-not-rowcount     | code-fence rules/a.md 3\ninline-procedure rules/b.md 5\n           | TOTAL 8 WILDCARD 0 ENTRIES 2
single-entry         | code-fence rules/a.md 4\n                                          | TOTAL 4 WILDCARD 0 ENTRIES 1
empty-allowlist      |                                                                    | TOTAL 0 WILDCARD 0 ENTRIES 0
comment-skipped      | # header comment\ncode-fence rules/a.md 3\n                        | TOTAL 3 WILDCARD 0 ENTRIES 1
indented-comment     |   # indented comment\ncode-fence rules/a.md 7\n                    | TOTAL 7 WILDCARD 0 ENTRIES 1
blank-lines-skipped  | \n\ncode-fence rules/a.md 2\n\n                                    | TOTAL 2 WILDCARD 0 ENTRIES 1
wildcard-excluded    | code-fence rules/a.md *\ncode-fence rules/b.md 2\n                 | TOTAL 2 WILDCARD 1 ENTRIES 2
wildcard-only        | code-fence rules/a.md *\ninline-procedure rules/b.md *\n           | TOTAL 0 WILDCARD 2 ENTRIES 2
zero-count-entry     | code-fence rules/a.md 0\ncode-fence rules/b.md 5\n                 | TOTAL 5 WILDCARD 0 ENTRIES 2
extra-column-spacing | code-fence    rules/a.md    6\n                                    | TOTAL 6 WILDCARD 0 ENTRIES 1
same-path-two-kinds  | code-fence rules/a.md 1\ninline-procedure rules/a.md 2\n           | TOTAL 3 WILDCARD 0 ENTRIES 2
no-trailing-newline  | code-fence rules/a.md 9                                            | TOTAL 9 WILDCARD 0 ENTRIES 1
TABLE
}

# AL02: --allowlist-total emits exactly one contracted line (machine-readable).
al02_total_single_line() {
    local repo; repo="$(make_repo al02)"
    run_cli_stdin "$repo" 'code-fence rules/a.md 3
' --allowlist-total --allowlist-file -
    assert_rc "AL02: --allowlist-total exits 0" 0
    local n
    n="$(printf '%s\n' "$OUT" | grep -c '^TOTAL ' || true)"
    assert_eq "AL02: exactly one TOTAL line" "1" "$n"
    assert_contains "AL02: line carries all three fields in order" \
        "^TOTAL [0-9][0-9]* WILDCARD [0-9][0-9]* ENTRIES [0-9][0-9]*$"
}

# AL03: --allowlist-file pointing at an unreadable path is a usage error, exit 2.
al03_missing_allowlist_file() {
    local repo; repo="$(make_repo al03)"
    run_cli "$repo" --allowlist-total --allowlist-file no-such-file.txt
    assert_rc "AL03: unreadable --allowlist-file" 2
}

# ============================================================================
# AL04 — (kind, path, count) matching (table-driven)
#
# Each row stages a file holding <violations> separate fences and applies the
# allowlist entry in <entry>, then asserts the exit code.
# ============================================================================
al04_match_table() {
    local name entry violations want repo i=0
    while IFS='|' read -r name entry violations want; do
        name="$(trim "$name")"
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        entry="$(trim "$entry")"
        violations="$(trim "$violations")"
        want="$(trim "$want")"
        i=$((i + 1))
        repo="$(make_repo "al04-$i")"
        emit_doc_with_fences "$violations" | write_file "$repo" rules/a.md
        stage "$repo" rules/a.md
        printf '%s\n' "$entry" > "$repo/al.txt"
        run_cli "$repo" --staged --kind code-fence --allowlist-file al.txt
        assert_rc "AL04/$name: '$entry' vs $violations actual" "$want"
    done <<'TABLE'
exact-cover        | code-fence rules/a.md 1        | 1 | 0
count-exceeded     | code-fence rules/a.md 1        | 2 | 1
count-well-over    | code-fence rules/a.md 1        | 5 | 1
generous-count     | code-fence rules/a.md 5        | 2 | 0
wildcard-unlimited | code-fence rules/a.md *        | 6 | 0
zero-count-blocks  | code-fence rules/a.md 0        | 1 | 1
wrong-kind         | inline-procedure rules/a.md 9  | 1 | 1
wrong-path         | code-fence rules/b.md 9        | 1 | 1
comment-only       | # code-fence rules/a.md 9      | 1 | 1
TABLE
}

# AL05: an over-counted entry surfaces as STALE: in --all (debt recovery prompt).
al05_stale_entry() {
    local repo; repo="$(make_repo al05)"
    emit_doc_with_fences 1 | write_file "$repo" rules/a.md
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "add rules/a.md"
    printf 'code-fence rules/a.md 5\n' > "$repo/al.txt"
    run_cli "$repo" --all --kind code-fence --allowlist-file al.txt
    assert_rc "AL05: --all exits 0" 0
    assert_contains "AL05: STALE: reported for an over-counted entry" "STALE:"
}

# AL06: --advisory never blocks AND implies --no-allowlist (detail plan C4 決定).
al06_advisory_ignores_allowlist() {
    local repo; repo="$(make_repo al06)"
    emit_doc_with_fences 2 | write_file "$repo" rules/a.md
    stage "$repo" rules/a.md
    printf 'code-fence rules/a.md *\n' > "$repo/al.txt"
    run_cli "$repo" --staged --advisory --kind code-fence --allowlist-file al.txt
    assert_rc "AL06: --advisory always exits 0" 0
    assert_contains "AL06: advisory output uses WARN:" "^WARN:"
    assert_not_contains "AL06: advisory output never emits HARD:" "^HARD:"
    assert_contains "AL06: advisory reports through a wildcard allowlist entry" "rules/a.md"
}

# ============================================================================
# AL07 — --staged reads the allowlist from the INDEX, not the working tree
#
# The allowlist file is itself a tracked file, so it is subject to the same
# index-vs-working-tree precedence as the prompt files being scanned (CPR-E2E:
# a commit must be judged against what is actually being committed).
# ============================================================================
al07_staged_uses_index_allowlist() {
    local repo; repo="$(make_repo al07)"
    emit_doc_with_fences 1 | write_file "$repo" rules/a.md
    printf 'code-fence rules/a.md 1\n' > "$repo/.prompt-extraction-allowlist"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "commit the covering allowlist"

    # Working tree now removes the exemption; the INDEX still carries it.
    printf '# emptied in the working tree only\n' > "$repo/.prompt-extraction-allowlist"
    stage "$repo" rules/a.md
    run_cli "$repo" --staged --kind code-fence
    assert_rc "AL07: --staged honours the indexed allowlist, not the dirty worktree" 0
    assert_not_contains "AL07: no HARD: from the working-tree-only allowlist edit" "^HARD:"

    # Symmetric direction: staging the narrowed allowlist must start blocking.
    git -C "$repo" add .prompt-extraction-allowlist
    run_cli "$repo" --staged --kind code-fence
    assert_rc "AL07: once the narrowed allowlist is staged, the violation blocks" 1
    assert_contains "AL07: blocked violation names rules/a.md" "rules/a.md"
}

# AL08: --no-allowlist ignores an otherwise-covering allowlist.
al08_no_allowlist_flag() {
    local repo; repo="$(make_repo al08)"
    emit_doc_with_fences 1 | write_file "$repo" rules/a.md
    printf 'code-fence rules/a.md *\n' > "$repo/.prompt-extraction-allowlist"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "wildcard allowlist"
    stage "$repo" rules/a.md
    run_cli "$repo" --staged --kind code-fence --no-allowlist
    assert_rc "AL08: --no-allowlist blocks despite a wildcard entry" 1
    assert_contains "AL08: raw detection result reported" "rules/a.md"
}

# ============================================================================
# AL09..AL11 — --write-allowlist (D2 baseline generation)
# ============================================================================

# AL09: --all --write-allowlist generates the repo-root allowlist and the
#       regenerated baseline is self-consistent (a re-run finds 0 violations).
al09_write_allowlist_roundtrip() {
    local repo; repo="$(make_repo al09)"
    emit_doc_with_fences 3 | write_file "$repo" rules/a.md
    { echo "# Doc"; echo ""; echo "## Procedure"; echo ""
      echo "1. one"; echo "2. two"; echo "3. three"; echo "4. four"; } \
        | write_file "$repo" rules/b.md
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "seed existing debt"

    run_cli "$repo" --all --write-allowlist
    assert_rc "AL09: --all --write-allowlist exits 0" 0
    if [ -f "$repo/.prompt-extraction-allowlist" ]; then
        pass "AL09: .prompt-extraction-allowlist generated at the repo root"
    else
        fail "AL09: .prompt-extraction-allowlist was not generated" "$OUT"
        return
    fi

    # The generated baseline must cover every pre-existing violation.
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "record the generated baseline"
    git -C "$repo" checkout -q -b al09-branch
    echo "" >> "$repo/rules/a.md"
    stage "$repo" rules/a.md
    run_cli "$repo" --staged
    assert_rc "AL09: re-run against the generated baseline is clean" 0
    assert_not_contains "AL09: no HARD: after baseline generation" "^HARD:"

    # And it must not be over-generous: --all reports no STALE entries either.
    run_cli "$repo" --all
    assert_rc "AL09: --all exits 0" 0
    assert_not_contains "AL09: generated baseline has no STALE entries" "STALE:"
}

# AL10: a violation added AFTER baseline generation still blocks (the baseline
#       freezes existing debt without disabling the gate).
al10_write_allowlist_then_new_debt() {
    local repo; repo="$(make_repo al10)"
    emit_doc_with_fences 1 | write_file "$repo" rules/a.md
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "seed debt"
    run_cli "$repo" --all --write-allowlist
    assert_rc "AL10: baseline generation exits 0" 0
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "record baseline"

    git -C "$repo" checkout -q -b al10-branch
    emit_doc_with_fences 2 | write_file "$repo" rules/c.md
    stage "$repo" rules/c.md
    run_cli "$repo" --staged --kind code-fence
    assert_rc "AL10: newly added debt blocks despite the frozen baseline" 1
    assert_contains "AL10: the new file is named" "rules/c.md"
}

# AL11: --write-allowlist is --all-only; every other mode is a usage error.
al11_write_allowlist_mode_guard() {
    local repo; repo="$(make_repo al11)"
    local name args
    while IFS='|' read -r name args; do
        name="$(trim "$name")"
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        args="$(trim "$args")"
        # shellcheck disable=SC2086
        run_cli "$repo" $args
        assert_rc "AL11/$name: '$args' rejected (--write-allowlist is --all-only)" 2
    done <<'TABLE'
with-staged | --staged --write-allowlist
with-base   | --base HEAD --write-allowlist
with-total  | --allowlist-total --write-allowlist
TABLE
    if [ -f "$repo/.prompt-extraction-allowlist" ]; then
        fail "AL11: a rejected --write-allowlist invocation still wrote the allowlist"
    else
        pass "AL11: rejected invocations leave no allowlist behind"
    fi
}

run_all() {
    al01_total_table
    al02_total_single_line
    al03_missing_allowlist_file
    al04_match_table
    al05_stale_entry
    al06_advisory_ignores_allowlist
    al07_staged_uses_index_allowlist
    al08_no_allowlist_flag
    al09_write_allowlist_roundtrip
    al10_write_allowlist_then_new_debt
    al11_write_allowlist_mode_guard
}

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
