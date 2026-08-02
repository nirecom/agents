#!/usr/bin/env bash
# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, bin/lib/test-frontmatter-fix.sh, bin/lib/test-frontmatter-constants.sh
# Tags: TL2, scope:issue-specific, fix-1576-test-frontmatter, fix-1782-normalize-token-glob
#
# TL2 test of the #1576 --fix-headers feature added to audit-tests.sh and
# audit-tests-common.sh. Exercises A/B/C token classification, the
# normalize_token path-likeness heuristic, report vs --apply behaviour, and
# the atomic exec-bit-preserving rewrite. B-tokens are exercised with a real
# git rename so rename tracking has something to find.
#
# Fail-before-fix: --fix-headers does not exist yet. Every TC below is
# EXPECTED TO FAIL until #1576 write-code lands the feature.
#
# TC11-TC23 (added for #1782): normalize_token()'s unquoted `for word in $pre`
# undergoes unwanted glob expansion, and both normalize_token() and the
# classify_tests_header()/_rebuild_tests_value() direct-match branches accept
# root-equivalent tokens (bare "/", ".", "..", "./", "../") as valid existing
# paths via `[[ -e "$word" ]]`. TC11/TC12/TC14-TC23 are EXPECTED TO FAIL until
# #1782 lands; TC13 guards against over-exclusion breaking the normal case.
#
# TC15-TC17 extend root-equivalent coverage to the remaining case-list members
# (".", "..", "../") as standalone CSV tokens (same direct-match branch as
# TC14's bare "/"). TC18-TC19 exercise the --apply rewrite path
# (_rebuild_tests_value) against sandboxed synthetic fixtures to confirm a
# root-equivalent or glob token cannot survive/silently-substitute into the
# rewritten header (both now assert RC==0 explicitly on the --apply
# invocation, not just byte-comparison, so a crash can't masquerade as an
# "unchanged" pass). TC20-TC21 extend glob coverage (TC11 covers "*") to "?"
# and a pure bracket-expression glob containing no "*"/"?" at all, matching
# normalize_token()'s skip-guard (`*"*"*` / `*"?"*` only — bracket expressions
# are not special-cased). TC22 covers "./" as its own standalone CSV token
# (distinct from TC13's "./" embedded in prose). TC23 mirrors TC14's bare "/"
# regression through bin/audit-tests-common.sh's --fix-headers path (CPR-5
# symmetry with bin/audit-tests.sh).
#
#
# Round-3 Codex test-coverage review (gaps C1/C2, addressed in this revision):
# - C1: TC24-TC26 broaden root-equivalent-spelling coverage beyond the 5
#   literal case-list members. TC24 ("bin/.") is a sanctioned non-root
#   negative control; TC25 ("tests/..") and TC26 (absolute path to the
#   fixture's own sandbox root) document the approved fix design's literal-
#   match-only, no-path-resolution boundary (see comments at each case) —
#   verified by direct execution against synthetic fixtures rather than
#   assumed.
# - C2: TC18/TC19 now additionally assert the exact `SKIP_APPLY_HAS_AC: <file>`
#   diagnostic line via `grep -qxF` when the file is unchanged, closing the
#   gap where "nothing changed" could otherwise mean either "correctly
#   detected and preserved" or "crashed/matched nothing for an unrelated
#   reason."
# TL3 gap (what this test does NOT catch):
# - Real pre-commit hook firing via actual git commit attempt
# - gh API timeout behavior in a live GitHub environment
# Closest-to-action mitigation: gap checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AUDIT="${AUDIT_TESTS_BIN:-$REPO_ROOT/bin/audit-tests.sh}"
AUDIT_COMMON="${AUDIT_TESTS_COMMON_BIN:-$REPO_ROOT/bin/audit-tests-common.sh}"

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); echo "ok - $1"; }
fail() { FAIL=$((FAIL+1)); echo "not ok - $1"; echo "    $2" >&2; }

if [[ ! -f "$AUDIT" ]]; then
  fail "script exists" "script not found: $AUDIT"
  echo "1..1"; echo "# PASS=$PASS FAIL=$FAIL"; exit 1
fi

# --- Fixture builder -------------------------------------------------------
# make_fixture -> echoes a fresh git repo root with bin/foo.sh + bin/bar.sh.
make_fixture() {
  local root; root="$(mktemp -d)"
  git -C "$root" init -q
  git -C "$root" config core.hooksPath /dev/null 2>/dev/null || true
  git -C "$root" config user.email "t@example.com"
  git -C "$root" config user.name "t"
  mkdir -p "$root/tests" "$root/bin"
  echo '#!/usr/bin/env bash' > "$root/bin/foo.sh"
  echo '#!/usr/bin/env bash' > "$root/bin/bar.sh"
  git -C "$root" add -A >/dev/null 2>&1
  git -C "$root" commit -q --no-verify -m init >/dev/null 2>&1
  echo "$root"
}

# write_dispatcher <root> <name> <tests-header>
write_dispatcher() {
  local root="$1"; local name="$2"; local hdr="$3"
  {
    echo '#!/usr/bin/env bash'
    echo "$hdr"
    echo '# Tags: TL2, scope:issue-specific'
    echo 'echo hi'
  } > "$root/tests/$name"
  chmod +x "$root/tests/$name"
}

# run_in <root> <script> <args...> -> sets OUT ERR RC
run_in() {
  local root="$1"; local script="$2"; shift 2
  local outf errf
  outf="$(mktemp)"; errf="$(mktemp)"
  set +e
  ( cd "$root" && bash "$script" "$@" ) >"$outf" 2>"$errf"
  RC=$?
  set -e
  OUT="$(cat "$outf")"; ERR="$(cat "$errf")"
  rm -f "$outf" "$errf"
}

# --- Cases -----------------------------------------------------------------
# Test case bodies (TC1-TC26) live in the sibling directory below, split by
# logical grouping (HARD file-split limit, rules/coding/file-split.md). Each
# fragment is *sourced* (not executed as a separate script) so it shares this
# file's PASS/FAIL counters, pass()/fail() helpers, and fixture helpers, and
# so tests/run-all.sh's non-recursive `tests/*.sh` glob never discovers or
# double-runs them independently. Physical execution order below closely
# reproduces the pre-split monolithic file's order (TC1-10, TC11, TC12,
# TC22-26, TC13-17, TC18-21); the round-4 table-driven refactor (test-review
# gap C1) regroups TC22 alongside TC24-26 (was before TC23, now after — a
# harmless reorder of independent cases) and TC14-17 into their own table
# within root-like-tokens-direct-match.sh. The TAP `1..26` numbering and
# pass/fail semantics are unchanged: each table row still calls pass()/fail()
# exactly once per logical TC.
CASES_DIR="$SCRIPT_DIR/fix-1576-audit-tests-fix-headers"
# shellcheck source=fix-1576-audit-tests-fix-headers/token-classification-abc.sh
source "$CASES_DIR/token-classification-abc.sh"       # TC1-TC10
# shellcheck source=fix-1576-audit-tests-fix-headers/root-like-tokens-report.sh
source "$CASES_DIR/root-like-tokens-report.sh"        # TC11, TC12, TC22-TC26
# shellcheck source=fix-1576-audit-tests-fix-headers/root-like-tokens-direct-match.sh
source "$CASES_DIR/root-like-tokens-direct-match.sh"  # TC13-TC17
# shellcheck source=fix-1576-audit-tests-fix-headers/apply-rewrite-and-extra-globs.sh
source "$CASES_DIR/apply-rewrite-and-extra-globs.sh"  # TC18-TC21

# --- Summary ---------------------------------------------------------------
echo "1..$((PASS+FAIL))"
echo "# PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
