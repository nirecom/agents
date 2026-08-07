#!/usr/bin/env bash
# Tests: bin/audit-tests-common.sh
# Tags: TL2, audit-tests, retire, scope:issue-specific
#
# TL2 test of bin/audit-tests-common.sh orphan detection. An orphan is a
# common-scope test dispatcher whose `# Tests:` header lists only paths that
# no longer exist on disk. Spawns the real script against a throwaway git
# fixture.
#
# Revised for #1833. Two contracts changed:
#   1. The script now shares the survival predicate with audit-tests.sh, so a
#      prose / non-path `# Tests:` token is UNDECIDABLE (MALFORMED_HEADER) and
#      no longer counts as a missing path — that conflation is what made 25 of
#      26 reported common-scope orphans false positives.
#   2. Write mode is apply-by-default, so every report-only case must pass
#      --dry-run explicitly.
#
# TL3 gap (what this test does NOT catch):
# - Interaction with the online audit-tests.sh candidate emission
# Closest-to-action mitigation: manual full audit run before merge.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="${AUDIT_TESTS_COMMON_BIN:-$REPO_ROOT/bin/audit-tests-common.sh}"

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); echo "ok - $1"; }
fail() { FAIL=$((FAIL+1)); echo "not ok - $1"; echo "    $2" >&2; }

if [[ ! -f "$SCRIPT" ]]; then
  fail "script exists" "script not found: $SCRIPT (implemented by #1557)"
  echo "1..1"; echo "# PASS=$PASS FAIL=$FAIL"; exit 1
fi

# --- Fixture builder -------------------------------------------------------
# Creates a git repo with a tests/ tree. Each dispatcher's `# Tests:` header
# and the set of real bin paths are controlled by the caller so orphan and
# non-orphan states can both be exercised.
new_repo() {
  local root; root="$(mktemp -d)"
  git -C "$root" init -q
  git -C "$root" config core.hooksPath /dev/null 2>/dev/null || true
  git -C "$root" config user.email "t@example.com"
  git -C "$root" config user.name "t"
  mkdir -p "$root/tests" "$root/bin"
  echo "$root"
}

# add_dispatcher <root> <name> <tests-header-value>
add_dispatcher() {
  local root="$1"; local name="$2"; local header="$3"
  {
    echo '#!/usr/bin/env bash'
    echo "# Tests: $header"
    echo '# Tags: TL2, scope:common'
    echo 'echo hi'
  } > "$root/tests/$name"
}

# add_dispatcher_nohdr <root> <name>
add_dispatcher_nohdr() {
  local root="$1"; local name="$2"
  {
    echo '#!/usr/bin/env bash'
    echo '# Tags: TL2, scope:common'
    echo 'echo hi'
  } > "$root/tests/$name"
}

add_bin() {
  local root="$1"; local rel="$2"
  mkdir -p "$root/$(dirname "$rel")"
  echo 'echo x' > "$root/$rel"
}

commit() {
  local root="$1"
  git -C "$root" add -A >/dev/null 2>&1
  git -C "$root" commit -q -m fixture >/dev/null 2>&1 || true
}

# run_common <root> [args...] -> sets OUT ERR RC
# Always report-only: the script applies by default, and every case in this
# file asserts on the REPORT. The apply-by-default behaviour itself is covered
# by tests/bin-sweep-write-mode-default.sh and the #1833 delete-gate group.
run_common() {
  local root="$1"; shift
  local outf errf
  outf="$(mktemp)"; errf="$(mktemp)"
  set +e
  ( cd "$root" && bash "$SCRIPT" --dry-run "$@" ) >"$outf" 2>"$errf"
  RC=$?
  set -e
  OUT="$(cat "$outf")"
  ERR="$(cat "$errf")"
  rm -f "$outf" "$errf"
}

# --- Cases -----------------------------------------------------------------

# TC1: all `# Tests:` paths missing => ORPHAN emitted, exit 0
root="$(new_repo)"
add_dispatcher "$root" "cc-gone.sh" "bin/does-not-exist.sh"
commit "$root"
run_common "$root"
if [[ $RC -eq 0 && "$OUT" == *"ORPHAN:"*"cc-gone.sh"* ]]; then
  pass "TC1 all-missing paths flagged as orphan"
else
  fail "TC1 all-missing paths flagged as orphan" "rc=$RC out=<<$OUT>>"
fi
rm -rf "$root"

# TC2: at least one `# Tests:` path exists => not an orphan, exit 1
root="$(new_repo)"
add_bin "$root" "bin/present.sh"
add_dispatcher "$root" "cc-live.sh" "bin/present.sh, bin/does-not-exist.sh"
commit "$root"
run_common "$root"
if [[ $RC -eq 1 && "$OUT" != *"ORPHAN:"* ]]; then
  pass "TC2 dispatcher with a live path is not an orphan"
else
  fail "TC2 dispatcher with a live path is not an orphan" "rc=$RC out=<<$OUT>>"
fi
rm -rf "$root"

# TC3: no `# Tests:` header => not an orphan, but reported as a diagnostic
# rather than silently dropped.
root="$(new_repo)"
add_dispatcher_nohdr "$root" "cc-nohdr.sh"
commit "$root"
run_common "$root"
if [[ $RC -eq 1 && "$OUT" != *"ORPHAN:"* ]]; then
  pass "TC3 dispatcher without # Tests: header is not an orphan"
else
  fail "TC3 dispatcher without # Tests: header is not an orphan" "rc=$RC out=<<$OUT>>"
fi
if [[ "$OUT" == *"NO_TESTS_HEADER: tests/cc-nohdr.sh"* ]]; then
  pass "TC3b dispatcher without # Tests: header is reported as NO_TESTS_HEADER"
else
  fail "TC3b dispatcher without # Tests: header is reported as NO_TESTS_HEADER" "rc=$RC out=<<$OUT>>"
fi
rm -rf "$root"

# TC3c: prose / non-path `# Tests:` token => UNDECIDABLE, never an orphan.
# This is the #1833 false-positive class: `Missing paths: bin/x.sh (prose)`
# used to be reported as a missing path because the whole annotated token was
# stat'ed as if it were a filename.
root="$(new_repo)"
add_bin "$root" "bin/present.sh"
add_dispatcher "$root" "cc-prose.sh" "bin/present.sh (and the notes below)"
commit "$root"
run_common "$root"
if [[ "$OUT" != *"ORPHAN:"*"cc-prose.sh"* ]]; then
  pass "TC3c prose-annotated header is not reported as an orphan"
else
  fail "TC3c prose-annotated header is not reported as an orphan" "rc=$RC out=<<$OUT>>"
fi
if [[ "$OUT" == *"MALFORMED_HEADER: tests/cc-prose.sh"* ]]; then
  pass "TC3d prose-annotated header is reported as MALFORMED_HEADER"
else
  fail "TC3d prose-annotated header is reported as MALFORMED_HEADER" "rc=$RC out=<<$OUT>>"
fi
rm -rf "$root"

# TC4: feature-NNN-*.sh is out of scope (owned by audit-tests.sh) => skipped
root="$(new_repo)"
add_dispatcher "$root" "feature-1557-gone.sh" "bin/does-not-exist.sh"
commit "$root"
run_common "$root"
if [[ $RC -eq 1 && "$OUT" != *"ORPHAN:"* ]]; then
  pass "TC4 feature-NNN dispatcher excluded from orphan scan"
else
  fail "TC4 feature-NNN dispatcher excluded from orphan scan" "rc=$RC out=<<$OUT>>"
fi
rm -rf "$root"

# TC5: --format json emits an orphans array containing the dispatcher
root="$(new_repo)"
add_dispatcher "$root" "cc-gone.sh" "bin/does-not-exist.sh"
commit "$root"
run_common "$root" --format json
if [[ $RC -eq 0 && "$OUT" == *'"orphans"'* && "$OUT" == *"cc-gone.sh"* ]]; then
  pass "TC5 json output includes orphans array"
else
  fail "TC5 json output includes orphans array" "rc=$RC out=<<$OUT>>"
fi
rm -rf "$root"

# TC6: exit code semantics — 0 when orphans exist, 1 when none
root="$(new_repo)"
add_bin "$root" "bin/present.sh"
add_dispatcher "$root" "cc-live.sh" "bin/present.sh"
commit "$root"
run_common "$root"
rc_none=$RC
root2="$(new_repo)"
add_dispatcher "$root2" "cc-gone.sh" "bin/does-not-exist.sh"
commit "$root2"
run_common "$root2"
rc_some=$RC
if [[ $rc_some -eq 0 && $rc_none -eq 1 ]]; then
  pass "TC6 exit 0 with orphans, exit 1 without"
else
  fail "TC6 exit 0 with orphans, exit 1 without" "rc_some=$rc_some rc_none=$rc_none"
fi
rm -rf "$root" "$root2"

# TC7: empty `# Tests:` value => not an orphan (no missing path to detect),
# but reported on the diagnostics channel like the header-less case.
root="$(new_repo)"
{
  echo '#!/usr/bin/env bash'
  echo '# Tests:'
  echo '# Tags: TL2, scope:common'
  echo 'echo hi'
} > "$root/tests/cc-empty-tests-header.sh"
commit "$root"
run_common "$root"
if [[ $RC -eq 1 && "$OUT" != *"ORPHAN:"* ]]; then
  pass "TC7 empty # Tests: value is not an orphan"
else
  fail "TC7 empty # Tests: value is not an orphan" "rc=$RC out=<<$OUT>>"
fi
if [[ "$OUT" == *"NO_TESTS_HEADER: tests/cc-empty-tests-header.sh"* ]]; then
  pass "TC7b empty # Tests: value is reported as NO_TESTS_HEADER"
else
  fail "TC7b empty # Tests: value is reported as NO_TESTS_HEADER" "rc=$RC out=<<$OUT>>"
fi
rm -rf "$root"

# --- Summary ---------------------------------------------------------------
echo "1..$((PASS+FAIL))"
echo "# PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
