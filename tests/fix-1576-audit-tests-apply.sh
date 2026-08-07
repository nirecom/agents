#!/usr/bin/env bash
# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh
# Tags: TL2, scope:issue-specific, fix-1576-test-frontmatter
#
# TL2 test of the #1576 --apply feature in audit-tests.sh. --apply performs a
# real `git rm` of a deletion candidate. Uses a mocked gh CLI on PATH so no
# network is touched.
#
# Revised for #1833: candidacy is decided by TARGET SURVIVAL (every # Tests:
# token format-OK, missing, and not renamed), and the issue's state is only a
# delete-time gate. Consequences for the cases below:
#   - a prose/A-flag header is undecidable, so it is neither a candidate nor a
#     deletion — and the retired SKIP_DELETE_HAS_A_OR_B label is gone;
#   - a resolvable rename means the target is ALIVE, so the file is not a
#     candidate at all;
#   - a recently-closed issue no longer suppresses the candidate, it only holds
#     the deletion (SKIP_DELETE_ISSUE_ACTIVE);
#   - --apply on audit-tests-common.sh is now supported and does delete.
#
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

# --- gh mock ---------------------------------------------------------------
# Answers gh repo view and gh api repos/.../issues/N from MOCK_STATE/MOCK_CLOSED_AT.
install_gh_mock() {
  local bindir="$1"
  mkdir -p "$bindir"
  cat > "$bindir/gh" <<'EOF'
#!/usr/bin/env bash
sub="$1"; shift || true
if [[ "$sub" == "repo" && "$1" == "view" ]]; then
  echo "acme/widget"
  exit 0
fi
if [[ "$sub" == "api" ]]; then
  jq_expr=""
  args=("$@")
  for ((i=0; i<${#args[@]}; i++)); do
    if [[ "${args[$i]}" == "--jq" || "${args[$i]}" == "-q" ]]; then
      jq_expr="${args[$((i+1))]}"
    fi
  done
  state="${MOCK_STATE:-closed}"
  closed_at="${MOCK_CLOSED_AT:-}"
  if [[ -n "$closed_at" ]]; then closed_json="\"$closed_at\""; else closed_json="null"; fi
  case "$jq_expr" in
    *closed_at*state*|*state*closed_at*) echo "$state $closed_at" ;;
    *closed_at*) echo "$closed_at" ;;
    *state*) echo "$state" ;;
    *) printf '{"state":"%s","closed_at":%s}\n' "$state" "$closed_json" ;;
  esac
  exit 0
fi
exit 0
EOF
  chmod +x "$bindir/gh"
}

# make_fixture <tests-header> -> echoes git repo root.
# Dispatcher references the given header; bin/foo.sh exists unless header omits it.
make_fixture() {
  local hdr="$1"
  local root; root="$(mktemp -d)"
  git -C "$root" init -q
  git -C "$root" config core.hooksPath /dev/null 2>/dev/null || true
  git -C "$root" config user.email "t@example.com"
  git -C "$root" config user.name "t"
  mkdir -p "$root/tests" "$root/bin"
  echo '#!/usr/bin/env bash' > "$root/bin/foo.sh"
  {
    echo '#!/usr/bin/env bash'
    echo "$hdr"
    echo '# Tags: TL2, scope:issue-specific'
    echo 'echo hi'
  } > "$root/tests/feature-1576-target.sh"
  git -C "$root" add -A >/dev/null 2>&1
  GIT_AUTHOR_DATE="2020-01-01T00:00:00" GIT_COMMITTER_DATE="2020-01-01T00:00:00" \
    git -C "$root" commit -q --no-verify -m init >/dev/null 2>&1
  echo "$root"
}

# run_apply <root> <state> <closed_at> <script> <args...> -> sets OUT ERR RC
run_apply() {
  local root="$1"; local state="$2"; local closed_at="$3"; local script="$4"; shift 4
  local bindir="$root/.mockbin"
  install_gh_mock "$bindir"
  local outf errf
  outf="$(mktemp)"; errf="$(mktemp)"
  set +e
  ( cd "$root" && PATH="$bindir:$PATH" MOCK_STATE="$state" MOCK_CLOSED_AT="$closed_at" \
      bash "$script" "$@" ) >"$outf" 2>"$errf"
  RC=$?
  set -e
  OUT="$(cat "$outf")"; ERR="$(cat "$errf")"
  rm -f "$outf" "$errf"
}

OLD_CLOSED_AT="2020-01-01T00:00:00Z"
TODAY_CLOSED_AT="$(date +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || uv run python -c "import datetime;print(datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'))")"

# --- Cases -----------------------------------------------------------------

# TC1: all-C tokens (path deleted, no rename) + CLOSED + past cutoff => --apply git-rm's the file
# Header references bin/gone.sh which never existed => C. Format is valid => A-flag=false.
R1="$(make_fixture '# Tests: bin/gone.sh')"
run_apply "$R1" closed "$OLD_CLOSED_AT" "$AUDIT" --apply
gone_removed=0
[[ ! -f "$R1/tests/feature-1576-target.sh" ]] && gone_removed=1
# Also verify git index shows the removal (git rm stages it).
index_removed=0
staged_files="$(git -C "$R1" diff --cached --name-only 2>/dev/null || true)"
if echo "$staged_files" | grep -q "tests/feature-1576-target.sh"; then
  index_removed=1
fi
if [[ "$gone_removed" -eq 1 && "$index_removed" -eq 1 ]]; then
  pass "TC1 all-C closed-stale candidate is git-rm'd by --apply (filesystem + index)"
else
  fail "TC1 all-C closed-stale candidate is git-rm'd by --apply (filesystem + index)" "rc=$RC gone=$gone_removed idx=$index_removed out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R1"

# TC2: prose / A-flag header is UNDECIDABLE — never a candidate, never deleted,
# and reported on the diagnostics channel rather than as a skipped deletion.
R2="$(make_fixture '# Tests: bin/gone.sh (annotation)')"
run_apply "$R2" closed "$OLD_CLOSED_AT" "$AUDIT" --apply
if [[ -f "$R2/tests/feature-1576-target.sh" && "$OUT" != *"CANDIDATE"* \
      && "$OUT$ERR" == *"MALFORMED_HEADER"* ]]; then
  pass "TC2 prose header is reported MALFORMED_HEADER, is no candidate, is not deleted"
else
  fail "TC2 prose header is reported MALFORMED_HEADER, is no candidate, is not deleted" "rc=$RC exists=$([[ -f "$R2/tests/feature-1576-target.sh" ]] && echo yes || echo no) out=<<$OUT>> err=<<$ERR>>"
fi
if [[ "$OUT$ERR" != *"SKIP_DELETE_HAS_A_OR_B"* ]]; then
  pass "TC2b retired SKIP_DELETE_HAS_A_OR_B label is no longer emitted"
else
  fail "TC2b retired SKIP_DELETE_HAS_A_OR_B label is no longer emitted" "out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R2"

# TC3: renamed path resolvable => the target is ALIVE, so the file is not a
# candidate and is never deleted.
R3="$(mktemp -d)"
git -C "$R3" init -q
git -C "$R3" config core.hooksPath /dev/null 2>/dev/null || true
git -C "$R3" config user.email "t@example.com"; git -C "$R3" config user.name "t"
mkdir -p "$R3/tests" "$R3/bin"
echo '#!/usr/bin/env bash' > "$R3/bin/old.sh"
git -C "$R3" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE="2020-01-01T00:00:00" GIT_COMMITTER_DATE="2020-01-01T00:00:00" git -C "$R3" commit -q --no-verify -m init >/dev/null 2>&1
git -C "$R3" mv bin/old.sh bin/new.sh >/dev/null 2>&1
GIT_AUTHOR_DATE="2020-01-02T00:00:00" GIT_COMMITTER_DATE="2020-01-02T00:00:00" git -C "$R3" commit -q --no-verify -m rename >/dev/null 2>&1
{
  echo '#!/usr/bin/env bash'
  echo '# Tests: bin/old.sh'
  echo '# Tags: TL2, scope:issue-specific'
  echo 'echo hi'
} > "$R3/tests/feature-1576-target.sh"
git -C "$R3" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE="2020-01-03T00:00:00" GIT_COMMITTER_DATE="2020-01-03T00:00:00" git -C "$R3" commit -q --no-verify -m disp >/dev/null 2>&1
run_apply "$R3" closed "$OLD_CLOSED_AT" "$AUDIT" --apply
if [[ -f "$R3/tests/feature-1576-target.sh" && "$OUT" != *"CANDIDATE"* \
      && "$OUT$ERR" != *"DELETED: tests/feature-1576-target.sh"* ]]; then
  pass "TC3 resolvable rename counts as survival: no candidate, no deletion"
else
  fail "TC3 resolvable rename counts as survival: no candidate, no deletion" "rc=$RC exists=$([[ -f "$R3/tests/feature-1576-target.sh" ]] && echo yes || echo no) out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R3"

# TC4: all targets gone but the issue closed only moments ago => still a
# CANDIDATE (survival decides candidacy), deletion HELD by the issue gate.
R4="$(make_fixture '# Tests: bin/gone.sh')"
run_apply "$R4" closed "$TODAY_CLOSED_AT" "$AUDIT" --apply
if [[ -f "$R4/tests/feature-1576-target.sh" && "$OUT" == *"CANDIDATE"* \
      && "$OUT$ERR" == *"SKIP_DELETE_ISSUE_ACTIVE"* ]]; then
  pass "TC4 recently-closed issue holds the deletion but not the candidacy"
else
  fail "TC4 recently-closed issue holds the deletion but not the candidacy" "rc=$RC exists=$([[ -f "$R4/tests/feature-1576-target.sh" ]] && echo yes || echo no) out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R4"

# TC5: audit-tests-common.sh --apply => supported; a common-scope file whose
# name carries no issue reference passes the delete gate (ok-no-issue-ref).
if [[ ! -f "$AUDIT_COMMON" ]]; then
  fail "TC5 audit-tests-common.sh --apply deletes an orphan" "script not found: $AUDIT_COMMON"
else
  R5="$(mktemp -d)"
  git -C "$R5" init -q
  git -C "$R5" config core.hooksPath /dev/null 2>/dev/null || true
  git -C "$R5" config user.email "t@example.com"; git -C "$R5" config user.name "t"
  mkdir -p "$R5/tests" "$R5/bin"
  {
    echo '#!/usr/bin/env bash'
    echo '# Tests: bin/gone.sh'
    echo '# Tags: TL2, scope:common'
    echo 'echo hi'
  } > "$R5/tests/check-orphan.sh"
  git -C "$R5" add -A >/dev/null 2>&1
  git -C "$R5" commit -q --no-verify -m init >/dev/null 2>&1
  run_apply "$R5" closed "$OLD_CLOSED_AT" "$AUDIT_COMMON" --apply
  if [[ ! -f "$R5/tests/check-orphan.sh" && "$OUT$ERR" == *"DELETED: tests/check-orphan.sh"* ]]; then
    pass "TC5 audit-tests-common.sh --apply deletes an orphan with no issue reference"
  else
    fail "TC5 audit-tests-common.sh --apply deletes an orphan with no issue reference" "rc=$RC exists=$([[ -f "$R5/tests/check-orphan.sh" ]] && echo yes || echo no) out=<<$OUT>> err=<<$ERR>>"
  fi
  if [[ "$RC" -ne 2 || "$ERR" != *"--apply is not supported"* ]]; then
    pass "TC5b --apply is no longer rejected by audit-tests-common.sh"
  else
    fail "TC5b --apply is no longer rejected by audit-tests-common.sh" "rc=$RC err=<<$ERR>>"
  fi
  rm -rf "$R5"
fi

# --- Summary ---------------------------------------------------------------
echo "1..$((PASS+FAIL))"
echo "# PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
