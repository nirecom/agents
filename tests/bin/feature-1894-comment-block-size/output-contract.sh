#!/usr/bin/env bash
# tests/feature-1894-comment-block-size/output-contract.sh
# Tests: bin/review-comment-block-size
# Tags: comment-block-size, cli, exit-code, guards, idempotency, table-driven, scope:issue-specific, scope:feature-1894, layer:TL2

# Part 4 — output/exit-code contract the pre-commit hook depends on. rc: 0 =
# nothing to block or skipped; 1 = --staged found a BLOCK finding (NEW —
# commit-blocking verdict hooks/pre-commit propagates); 2 = reserved, never
# returned; 3 = internal error. rc 1 is load-bearing: hooks/pre-commit used
# to treat any non-zero rc as "advisory incomplete, continue", so 1 must be
# distinguishable from 3, or a broken scanner and a real violation look
# identical to the committer. --all stays rc 0 with findings (inventory, not
# a gate). raw_cb (no BASE_ENV seed) exercises the built-in default branches
# through the same .env routing as every other invocation.

opad() { local n="$1" i; for ((i = 1; i <= n; i++)); do echo "code_$i=$i"; done; }
ocm() { local n="$1" tag="$2" i; for ((i = 1; i <= n; i++)); do echo "# $tag $i"; done; }

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
    cb_expect_rc "O1/$name-rc"
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
cb_expect_rc "O2/rc"
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

# O4 / O5 — the file-count and byte-size guards. Both caps are compiled-in
# constants rather than configuration, so their output contract (the SKIPPED
# reason naming the count; the "skipped (too large): N" summary line) is pinned
# together with their boundaries in config-numeric-caps.sh (N1/N3) rather than
# split across two files.

# ---------------------------------------------------------------------------
# O6 — CODE_FILE_EXTENSIONS is the single source for the extension list
# ---------------------------------------------------------------------------
# There is no resolution chain left to order: the scanner reads
# CODE_FILE_EXTENSIONS and falls back to the built-in js;sh;py. The removed
# COMMENT_BLOCK_FILE_EXTENSIONS must therefore be unable to change the scan set
# from either side — neither narrowing what CODE_FILE_EXTENSIONS admits nor
# widening what it excludes.
echo ""
echo "=== O6: CODE_FILE_EXTENSIONS is the single source ==="
EXTR="$(new_repo extres)"
{ opad 2; ocm 12 note; } > "$EXTR/target.sh"
git -C "$EXTR" add -A >/dev/null 2>&1

# Both directions of the pin, so neither can pass vacuously.
run_cb "$EXTR" "CODE_FILE_EXTENSIONS=js" -- --staged
assert_eq "O6/pinned-list-excludes-sh" "0" "$(cb_warn_count)"
run_cb "$EXTR" "CODE_FILE_EXTENSIONS=sh" -- --staged
assert_eq "O6/pinned-list-includes-sh" "1" "$(cb_warn_count)"

# The removed variable cannot resurrect an extension the pinned list excludes.
run_cb "$EXTR" "CODE_FILE_EXTENSIONS=js" "COMMENT_BLOCK_FILE_EXTENSIONS=sh" -- --staged
assert_eq "O6/removed-knob-cannot-widen" "0" "$(cb_warn_count)"
assert_contains "O6/summary-lists-the-pinned-value" "(extensions: js;" "$CB_OUT"
# ...nor take one away from a list that admits it.
run_cb "$EXTR" "CODE_FILE_EXTENSIONS=sh" "COMMENT_BLOCK_FILE_EXTENSIONS=js" -- --staged
assert_eq "O6/removed-knob-cannot-narrow" "1" "$(cb_warn_count)"

# With nothing pinned the built-in default applies, and the removed variable
# cannot stand in for it either.
raw_cb "$EXTR" "COMMENT_BLOCK_MAX_LINES=10" -- --staged
assert_eq "O6/built-in-default-includes-sh" "1" "$(cb_warn_count)"
assert_contains "O6/built-in-default-listed-in-summary" "(extensions: js;sh;py;" "$CB_OUT"
raw_cb "$EXTR" "COMMENT_BLOCK_FILE_EXTENSIONS=js" "COMMENT_BLOCK_MAX_LINES=10" -- --staged
assert_eq "O6/removed-knob-cannot-replace-the-default" "1" "$(cb_warn_count)"

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
# O8 — the rc contract, asserted with literals
#
# This is the case that OWNS rc, so nothing here goes through cb_expect_rc:
# deriving the expectation from the same run would let a mode that stopped
# blocking pass silently. Every value in the contract gets a row, including the
# two "not this one" directions (rc 2 never appears; rc 1 never appears without
# findings and never appears in --all).
# ---------------------------------------------------------------------------
echo ""
echo "=== O8: exit-code contract (0 / 1 / 2-reserved / 3) ==="

# staged + findings -> 1
run_cb "$MANY" -- --staged
if [ "$(cb_finding_count)" -gt 0 ]; then
    pass "O8/premise-staged-run-has-findings"
else
    fail "O8/premise-staged-run-has-findings" "fixture produced no findings; rc row below is vacuous"
fi
assert_eq "O8/staged-with-findings-is-1" "1" "$CB_RC"

# same tree, --all -> findings but rc 0 (advisory inventory, deliberately
# asymmetric with --staged: CPR-SC, two modes with two different jobs)
run_cb "$MANY" -- --all
if [ "$(cb_finding_count)" -gt 0 ]; then
    pass "O8/premise-all-run-has-findings"
else
    fail "O8/premise-all-run-has-findings" "fixture produced no findings; rc row below is vacuous"
fi
assert_eq "O8/all-with-findings-is-0" "0" "$CB_RC"

# staged, no findings -> 0
# A fresh new_repo() has nothing staged (its only commit is README.md at
# creation time). OREPO is reused above with one.sh staged (a 12-line
# comment run, over the default 10-line threshold) — so it is not a valid
# fixture for this premise, and a dedicated clean repo is used instead.
NOFIND="$(new_repo outc-nofind)"
run_cb "$NOFIND" -- --staged
assert_eq "O8/staged-without-findings-is-0" "0" "$CB_RC"

# bad arguments: still not a blocking verdict, and never the reserved 2
run_cb "$OREPO" -- --bogus
case "$CB_RC" in
    1) fail "O8/bad-args-not-mistaken-for-a-block" "rc=1 — a usage error would block a commit" ;;
    2) fail "O8/bad-args-not-reserved-rc2" "rc=2 is reserved and must never be returned" ;;
    *) pass "O8/bad-args-rc-is-not-1-or-2" ;;
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
    cb_expect_rc "O12/rc-matches-mode"
    assert_eq "O12/header" \
        "## Comment-block Size Review: SKIPPED — not a git repository" "$(cb_header)"
    assert_eq "O12/no-warn-line" "0" "$(cb_warn_count)"
    # Symmetric counterpart for --all: the guard is about the CWD, not the mode.
    run_cb "$NOGIT" -- --all
    cb_expect_rc "O12/all-mode-rc-matches-mode"
    assert_eq "O12/all-mode-header" \
        "## Comment-block Size Review: SKIPPED — not a git repository" "$(cb_header)"
fi
