#!/usr/bin/env bash
# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, bin/lib/test-frontmatter-fix.sh, bin/lib/test-frontmatter-constants.sh
# Tags: TL2, scope:issue-specific, fix-1576-test-frontmatter, fix-1782-normalize-token-glob
#
# TL2 test of --fix-headers (#1576 + #1782). A/B/C classification, normalize_token
# glob fix, root-equivalent rejection (TC11-TC26, EXPECTED TO FAIL until #1782),
# atomic exec-bit-preserving rewrite. TL3 gap: real hook/gh timeout;
# mitigation: bin/check-verification-gate.sh category: hook-registration.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
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
  mkdir -p "$root/tests/bin" "$root/bin"
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
  } > "$root/tests/bin/$name"
  chmod +x "$root/tests/bin/$name"
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
# TC1-TC26 sourced from sibling dir (rules/coding/file-split.md Pattern A).
# Each fragment shares PASS/FAIL counters and fixture helpers via source.
CASES_DIR="$SCRIPT_DIR/fix-1576-audit-tests-fix-headers"

case_begin() { echo "--- group: $1 ---"; }
case_end()   { :; }

case_begin "token-classification" "bin/lib/test-frontmatter-constants.sh"
# shellcheck source=fix-1576-audit-tests-fix-headers/token-classification-abc.sh
source "$CASES_DIR/token-classification-abc.sh"       # TC1-TC10
case_end

case_begin "root-like-tokens-report" "bin/audit-tests.sh"
# shellcheck source=fix-1576-audit-tests-fix-headers/root-like-tokens-report.sh
source "$CASES_DIR/root-like-tokens-report.sh"        # TC11, TC12, TC22-TC26
case_end

case_begin "root-like-tokens-direct-match" "bin/audit-tests-common.sh"
# shellcheck source=fix-1576-audit-tests-fix-headers/root-like-tokens-direct-match.sh
source "$CASES_DIR/root-like-tokens-direct-match.sh"  # TC13-TC17
case_end

case_begin "apply-rewrite-extra-globs" "bin/lib/test-frontmatter-fix.sh"
# shellcheck source=fix-1576-audit-tests-fix-headers/apply-rewrite-and-extra-globs.sh
source "$CASES_DIR/apply-rewrite-and-extra-globs.sh"  # TC18-TC21
case_end

# --- Summary ---------------------------------------------------------------
echo "1..$((PASS+FAIL))"
echo "# PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
