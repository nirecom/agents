#!/usr/bin/env bash
# tests/feature-1894-comment-block-size/output-contract.sh
# Tests: bin/review-comment-block-size
# Tags: comment-block-size, cli, exit-code, guards, idempotency, table-driven, scope:issue-specific, scope:feature-1894, layer:TL2
#
# Part 4 — the output/exit-code contract the pre-commit hook depends on.
#
# rc 0 = performed or skipped (findings never change it), rc 3 = internal error.
# rc 1 and rc 2 are RESERVED and must never be returned: hooks/pre-commit treats
# any non-zero rc as "advisory check incomplete", and a findings-driven rc 1
# would turn an advisory notice into a permanent false alarm.

opad() { local n="$1" i; for ((i = 1; i <= n; i++)); do echo "code_$i=$i"; done; }
ocm() { local n="$1" tag="$2" i; for ((i = 1; i <= n; i++)); do echo "# $tag $i"; done; }

# raw_cb <repo> [VAR=VAL ...] -- [cli args ...]
# Same as run_cb but WITHOUT the BASE_ENV pins. It still starts from
# CB_ENV_RESET, so every config variable the caller does not name is genuinely
# unset in the child — that is what makes the "variable absent" branches real
# instead of "whatever the developer's .env holds".
raw_cb() {
    local repo="$1"; shift
    local -a pre=("${CB_ENV_RESET[@]}")
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do pre+=("$1"); shift; done
    [ "${1:-}" = "--" ] && shift
    local errfile="$TMPDIR_BASE/cb.err"
    CB_RC=0
    CB_OUT="$( (cd "$repo" && run_with_timeout 60 env "${pre[@]}" bash "$SCRIPT" "$@") 2>"$errfile" )" || CB_RC=$?
    CB_ERR="$(cat "$errfile" 2>/dev/null || true)"
}

OREPO="$(new_repo outc)"
{ opad 5; ocm 12 note; } > "$OREPO/one.sh"
git -C "$OREPO" add -A >/dev/null 2>&1

# ---------------------------------------------------------------------------
# O1 — argument handling: every rejected invocation SKIPS and returns 0
# ---------------------------------------------------------------------------
echo ""
echo "=== O1: argument handling ==="
while IFS='|' read -r name args; do
    [ -z "${name//[[:space:]]/}" ] && continue
    [[ "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    # shellcheck disable=SC2086
    run_cb "$OREPO" -- $args
    got_head="$(cb_header)"
    case "$got_head" in
        "## Comment-block Size Review: SKIPPED"*) got="skipped" ;;
        *) got="$got_head" ;;
    esac
    assert_eq "O1/$name-header" "skipped" "$got"
    assert_eq "O1/$name-rc" "0" "$CB_RC"
done <<'TABLE'
no-args           |
staged-and-all    | --staged --all
all-and-staged    | --all --staged
unknown-flag      | --bogus
unknown-positional| whatever
TABLE

# ---------------------------------------------------------------------------
# O2 — --all mode
# ---------------------------------------------------------------------------
echo ""
echo "=== O2: --all mode ==="
{ opad 3; ocm 12 a; opad 3; ocm 15 b; opad 3; } > "$OREPO/allscan.sh"
run_cb "$OREPO" -- --all
assert_eq "O2/header" "## Comment-block Size Review: PERFORMED (all-scan mode)" "$(cb_header)"
assert_contains "O2/finding-shape" \
    "longest comment run 15 lines (2 runs over threshold)" "$CB_OUT"
assert_eq "O2/rc" "0" "$CB_RC"
rm -f "$OREPO/allscan.sh"

# ---------------------------------------------------------------------------
# O3 — detail lines are capped at 5 with an "... and N more" tail
# ---------------------------------------------------------------------------
echo ""
echo "=== O3: detail-line cap ==="
MANY="$(new_repo manyruns)"
{ for i in $(seq 1 7); do opad 2; ocm 12 "run$i"; done; } > "$MANY/many.sh"
git -C "$MANY" add -A >/dev/null 2>&1
run_cb "$MANY" -- --staged
assert_eq "O3/five-detail-lines" "5" "$(printf '%s\n' "$CB_OUT" | grep -c '^  L' || true)"
assert_contains "O3/and-n-more" "  ... and 2 more" "$CB_OUT"

# ---------------------------------------------------------------------------
# O4 / O5 — size and count guards
# ---------------------------------------------------------------------------
echo ""
echo "=== O4: COMMENT_BLOCK_MAX_FILES guard ==="
GUARD="$(new_repo guards)"
for f in g1 g2 g3; do { opad 2; ocm 12 note; } > "$GUARD/$f.sh"; done
git -C "$GUARD" add -A >/dev/null 2>&1
run_cb "$GUARD" "COMMENT_BLOCK_MAX_FILES=2" -- --staged
case "$(cb_header)" in
    "## Comment-block Size Review: SKIPPED"*) pass "O4/skipped-header" ;;
    *) fail "O4/skipped-header" "got: $(cb_header)" ;;
esac
assert_contains "O4/reason-names-the-count" "too many staged files (3)" "$CB_OUT"
assert_eq "O4/rc" "0" "$CB_RC"
# Symmetric counterpart: below the cap the same index is scanned normally.
run_cb "$GUARD" "COMMENT_BLOCK_MAX_FILES=200" -- --staged
assert_eq "O4/under-cap-header" \
    "## Comment-block Size Review: PERFORMED (staged mode)" "$(cb_header)"
assert_eq "O4/under-cap-warns" "3" "$(cb_warn_count)"
# Boundary: the guard is "too many", so cap == count is still inside the budget.
run_cb "$GUARD" "COMMENT_BLOCK_MAX_FILES=3" -- --staged
assert_eq "O4/at-cap-header" \
    "## Comment-block Size Review: PERFORMED (staged mode)" "$(cb_header)"
assert_eq "O4/at-cap-warns" "3" "$(cb_warn_count)"

echo ""
echo "=== O5: COMMENT_BLOCK_MAX_BYTES per-file guard ==="
BIG="$(new_repo bigfile)"
{ opad 2; ocm 20 "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; } > "$BIG/big.sh"
{ ocm 12 s; } > "$BIG/small.sh"
git -C "$BIG" add -A >/dev/null 2>&1
run_cb "$BIG" "COMMENT_BLOCK_MAX_BYTES=200" -- --staged
assert_contains "O5/summary-counts-skipped" "skipped (too large): 1" "$CB_OUT"
assert_absent "O5/oversized-file-not-reported" "WARN: big.sh" "$CB_OUT"
assert_contains "O5/small-file-still-reported" "WARN: small.sh" "$CB_OUT"
assert_eq "O5/rc" "0" "$CB_RC"
# Boundary: "too large" means strictly greater, so size == cap is still scanned
# and size == cap-1 keeps the file in range on the other side of the equality.
SMALL_BYTES="$(wc -c < "$BIG/small.sh" | tr -d '[:space:]')"
run_cb "$BIG" "COMMENT_BLOCK_MAX_BYTES=$SMALL_BYTES" -- --staged
assert_contains "O5/at-cap-file-still-scanned" "WARN: small.sh" "$CB_OUT"
run_cb "$BIG" "COMMENT_BLOCK_MAX_BYTES=$((SMALL_BYTES - 1))" -- --staged
assert_absent "O5/one-byte-over-cap-skipped" "WARN: small.sh" "$CB_OUT"
assert_contains "O5/one-byte-over-cap-counted" "skipped (too large): 2" "$CB_OUT"

# ---------------------------------------------------------------------------
# O6 — extension resolution: COMMENT_BLOCK_FILE_EXTENSIONS -> CODE_FILE_EXTENSIONS
#      -> built-in js;sh;py
# ---------------------------------------------------------------------------
echo ""
echo "=== O6: extension resolution chain ==="
EXTR="$(new_repo extres)"
{ opad 2; ocm 12 note; } > "$EXTR/target.sh"
git -C "$EXTR" add -A >/dev/null 2>&1

run_cb "$EXTR" "COMMENT_BLOCK_FILE_EXTENSIONS=js" -- --staged
assert_eq "O6/explicit-list-excludes-sh" "0" "$(cb_warn_count)"

raw_cb "$EXTR" "CODE_FILE_EXTENSIONS=sh" "COMMENT_BLOCK_WARN_LINES=10" -- --staged
assert_eq "O6/falls-back-to-CODE_FILE_EXTENSIONS" "1" "$(cb_warn_count)"

raw_cb "$EXTR" "COMMENT_BLOCK_WARN_LINES=10" -- --staged
assert_eq "O6/built-in-default-includes-sh" "1" "$(cb_warn_count)"
assert_contains "O6/built-in-default-listed-in-summary" "(extensions: js;sh;py;" "$CB_OUT"

# CODE_FILE_EXTENSIONS must NOT win when the specific variable is present.
raw_cb "$EXTR" "COMMENT_BLOCK_FILE_EXTENSIONS=js" "CODE_FILE_EXTENSIONS=sh" \
    "COMMENT_BLOCK_WARN_LINES=10" -- --staged
assert_eq "O6/specific-var-wins" "0" "$(cb_warn_count)"

# ---------------------------------------------------------------------------
# O7 — idempotency: the CLI is a pure inspection, so a second run must be
#      byte-identical and must not mutate the index.
# ---------------------------------------------------------------------------
echo ""
echo "=== O7: idempotency ==="
run_cb "$MANY" -- --staged
FIRST_OUT="$CB_OUT"; FIRST_RC="$CB_RC"
IDX_BEFORE="$(git -C "$MANY" diff --cached --name-status | sort)"
run_cb "$MANY" -- --staged
IDX_AFTER="$(git -C "$MANY" diff --cached --name-status | sort)"
assert_eq "O7/output-identical" "$FIRST_OUT" "$CB_OUT"
assert_eq "O7/rc-identical" "$FIRST_RC" "$CB_RC"
assert_eq "O7/index-untouched" "$IDX_BEFORE" "$IDX_AFTER"

# ---------------------------------------------------------------------------
# O8 — reserved exit codes are never used
# ---------------------------------------------------------------------------
echo ""
echo "=== O8: rc 1 / rc 2 are reserved ==="
run_cb "$MANY" -- --staged
case "$CB_RC" in
    1|2) fail "O8/findings-run-rc-not-reserved" "rc=$CB_RC (findings must not change rc)" ;;
    *) assert_eq "O8/findings-run-rc" "0" "$CB_RC" ;;
esac
run_cb "$OREPO" -- --bogus
case "$CB_RC" in
    1|2) fail "O8/bad-args-rc-not-reserved" "rc=$CB_RC" ;;
    *) assert_eq "O8/bad-args-rc" "0" "$CB_RC" ;;
esac

# ---------------------------------------------------------------------------
# O12 — invoked outside any git repository
# ---------------------------------------------------------------------------
# The script opens with `cd "$(git rev-parse --show-toplevel)"`. Outside a repo
# that command fails, and the contract is an explicit SKIPPED header at rc 0 —
# not an rc-3 internal error and not a bare shell diagnostic. This is the one
# entry condition a user can hit by accident (running the CLI from ~), and the
# hook's fail-open path would report rc 3 as "check incomplete" on every commit.
echo ""
echo "=== O12: not a git repository ==="
NOGIT="$TMPDIR_BASE/nogit-dir"
mkdir -p "$NOGIT"
if (cd "$NOGIT" && git rev-parse --show-toplevel >/dev/null 2>&1); then
    skip "O12: \$TMPDIR itself lives inside a git repository — no non-repo CWD available"
else
    run_cb "$NOGIT" -- --staged
    assert_eq "O12/rc-is-0" "0" "$CB_RC"
    assert_eq "O12/header" \
        "## Comment-block Size Review: SKIPPED — not a git repository" "$(cb_header)"
    assert_eq "O12/no-warn-line" "0" "$(cb_warn_count)"
    # Symmetric counterpart for --all: the guard is about the CWD, not the mode.
    run_cb "$NOGIT" -- --all
    assert_eq "O12/all-mode-rc-is-0" "0" "$CB_RC"
    assert_eq "O12/all-mode-header" \
        "## Comment-block Size Review: SKIPPED — not a git repository" "$(cb_header)"
fi
