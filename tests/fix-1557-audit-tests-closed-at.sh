#!/usr/bin/env bash
# Tests: bin/audit-tests.sh
# Tags: TL2, audit-tests, retire, scope:issue-specific
#
# TL2 test of how bin/audit-tests.sh uses an issue's closed_at.
# Spawns the real script against a throwaway git fixture with a mocked `gh`
# CLI on PATH so no network is touched.
#
# Revised for #1833. closed_at used to decide CANDIDACY; it now decides only
# whether a candidate may be DELETED. Candidacy is decided by target survival:
# a file is a candidate when every `# Tests:` token is format-OK, missing, and
# not resolvable through a rename. So each case below fixes one axis and varies
# the other:
#   - target dead  => candidate, regardless of issue state (TC1-TC5, TC8-TC10)
#   - target alive => never a candidate, however old the closed issue is (TC7)
#   - closed_at    => only gates the deletion (SKIP_DELETE_* labels)
#
# TL3 gap (what this test does NOT catch):
# - Real `gh api` transport / auth against github.com
# - Real repo-slug resolution via `gh repo view`
# Closest-to-action mitigation: manual online run before merge.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AUDIT="${AUDIT_TESTS_BIN:-$REPO_ROOT/bin/audit-tests.sh}"

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); echo "ok - $1"; }
fail() { FAIL=$((FAIL+1)); echo "not ok - $1"; echo "    $2" >&2; }

if [[ ! -f "$AUDIT" ]]; then
  fail "script exists" "script not found: $AUDIT"
  echo "1..1"; echo "# PASS=$PASS FAIL=$FAIL"; exit 1
fi

# --- Fixture builder -------------------------------------------------------
# Builds a self-contained git repo whose tests/ holds one feature dispatcher.
# Arg 1 (optional): `# Tests:` target. Default bin/gone.sh — a path that never
# existed, i.e. a DEAD target, which is what makes the file a candidate.
# Arg 2 (optional): "recent" to date the commit today instead of 2020.
make_fixture() {
  local target="${1:-bin/gone.sh}" when="${2:-old}"
  local root; root="$(mktemp -d)"
  git -C "$root" init -q
  git -C "$root" config core.hooksPath /dev/null 2>/dev/null || true
  git -C "$root" config user.email "t@example.com"
  git -C "$root" config user.name "t"
  mkdir -p "$root/tests" "$root/bin"
  cat > "$root/bin/foo.sh" <<'EOF'
#!/usr/bin/env bash
echo foo
EOF
  {
    echo '#!/usr/bin/env bash'
    echo "# Tests: $target"
    echo '# Tags: TL2, scope:issue-specific'
    echo 'echo foo'
  } > "$root/tests/feature-1557-foo.sh"
  git -C "$root" add -A >/dev/null 2>&1
  if [[ "$when" == "recent" ]]; then
    git -C "$root" commit -q --no-verify -m init >/dev/null 2>&1
  else
    GIT_AUTHOR_DATE="2020-01-01T00:00:00" GIT_COMMITTER_DATE="2020-01-01T00:00:00" \
      git -C "$root" commit -q --no-verify -m init >/dev/null 2>&1
  fi
  echo "$root"
}

# Install a gh mock in a bin dir prepended to PATH.
# The mock recognises `gh repo view` and `gh api repos/.../issues/N`,
# emitting fields from MOCK_STATE / MOCK_CLOSED_AT. It supports both a
# combined JSON object (no --jq) and individual --jq field extraction so
# the test does not couple to the exact jq expression the script uses.
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
  if [[ -n "$closed_at" ]]; then
    closed_json="\"$closed_at\""
  else
    closed_json="null"
  fi
  case "$jq_expr" in
    *closed_at*state*|*state*closed_at*)
      echo "$state $closed_at" ;;
    *closed_at*)
      echo "$closed_at" ;;
    *state*)
      echo "$state" ;;
    *)
      printf '{"state":"%s","closed_at":%s}\n' "$state" "$closed_json" ;;
  esac
  exit 0
fi
exit 0
EOF
  chmod +x "$bindir/gh"
}

# run_audit_with_root <root> <state> <closed_at> [audit args...]
# Sets OUT / ERR / RC. Does NOT remove the root — callers that inspect the
# filesystem after an --apply run need it to survive.
run_audit_with_root() {
  local root="$1"; local state="$2"; local closed_at="$3"; shift 3
  local bindir="$root/.mockbin"
  install_gh_mock "$bindir"
  local outf errf
  outf="$(mktemp)"; errf="$(mktemp)"
  set +e
  ( cd "$root" && PATH="$bindir:$PATH" MOCK_STATE="$state" MOCK_CLOSED_AT="$closed_at" \
      bash "$AUDIT" "$@" ) >"$outf" 2>"$errf"
  RC=$?
  set -e
  OUT="$(cat "$outf")"
  ERR="$(cat "$errf")"
  rm -f "$outf" "$errf"
}

# run_audit <state> <closed_at> [audit args...] — report-only, disposable root.
run_audit() {
  local state="$1"; local closed_at="$2"; shift 2
  local root; root="$(make_fixture)"
  run_audit_with_root "$root" "$state" "$closed_at" --dry-run "$@"
  rm -rf "$root"
}

# run_audit_offline [audit args...] — report-only, no gh at all.
run_audit_offline() {
  local root; root="$(make_fixture)"
  local outf errf
  outf="$(mktemp)"; errf="$(mktemp)"
  set +e
  ( cd "$root" && bash "$AUDIT" --dry-run --offline "$@" ) >"$outf" 2>"$errf"
  RC=$?
  set -e
  OUT="$(cat "$outf")"
  ERR="$(cat "$errf")"
  rm -rf "$root" "$outf" "$errf"
}

DISPATCHER="tests/feature-1557-foo.sh"

# --- Cases -----------------------------------------------------------------

# TC1: dead target + closed long ago => CANDIDATE, exit 0, deletion authorised.
R1="$(make_fixture)"
run_audit_with_root "$R1" closed "2020-01-01T00:00:00Z" --apply
if [[ $RC -eq 0 && "$OUT" == *"CANDIDATE"*"feature-1557-foo.sh"* && ! -f "$R1/$DISPATCHER" ]]; then
  pass "TC1 dead target + old closed issue is a candidate and is deleted"
else
  fail "TC1 dead target + old closed issue is a candidate and is deleted" "rc=$RC exists=$([[ -f "$R1/$DISPATCHER" ]] && echo yes || echo no) out=<<$OUT>>"
fi
rm -rf "$R1"

# TC2: dead target + issue closed today => still a CANDIDATE; the recent close
# only HOLDS the deletion.
TODAY_CLOSED_AT="$(date +%Y-%m-%dT%H:%M:%SZ)"
R2="$(make_fixture)"
run_audit_with_root "$R2" closed "$TODAY_CLOSED_AT" --apply
if [[ $RC -eq 0 && "$OUT" == *"CANDIDATE"* && "$OUT$ERR" == *"SKIP_DELETE_ISSUE_ACTIVE"* && -f "$R2/$DISPATCHER" ]]; then
  pass "TC2 recently-closed issue holds the deletion, not the candidacy"
else
  fail "TC2 recently-closed issue holds the deletion, not the candidacy" "rc=$RC exists=$([[ -f "$R2/$DISPATCHER" ]] && echo yes || echo no) out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R2"

# TC3: dead target + OPEN issue => candidate (this is the #1833 false negative:
# the work moved on and left the test behind while the issue stayed open),
# deletion held.
R3="$(make_fixture)"
run_audit_with_root "$R3" open "" --apply
if [[ $RC -eq 0 && "$OUT" == *"CANDIDATE"* && "$OUT$ERR" == *"SKIP_DELETE_ISSUE_ACTIVE"* && -f "$R3/$DISPATCHER" ]]; then
  pass "TC3 open issue does not suppress candidacy, only the deletion"
else
  fail "TC3 open issue does not suppress candidacy, only the deletion" "rc=$RC exists=$([[ -f "$R3/$DISPATCHER" ]] && echo yes || echo no) out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R3"

# TC4: closed but closed_at missing => metadata unavailable. Reporting still
# works; deletion is held rather than guessed.
R4="$(make_fixture)"
run_audit_with_root "$R4" closed "" --apply
if [[ "$OUT" == *"CANDIDATE"* && "$OUT$ERR" == *"SKIP_DELETE_METADATA_UNAVAILABLE"* && -f "$R4/$DISPATCHER" ]]; then
  pass "TC4 missing closed_at holds the deletion (metadata unavailable)"
else
  fail "TC4 missing closed_at holds the deletion (metadata unavailable)" "rc=$RC exists=$([[ -f "$R4/$DISPATCHER" ]] && echo yes || echo no) out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R4"

# TC5: offline mode => survival is a purely local judgement, so candidates ARE
# reported; no issue metadata means no deletion.
run_audit_offline
if [[ $RC -eq 0 && "$OUT" == *"CANDIDATE"*"feature-1557-foo.sh"* ]]; then
  pass "TC5 offline mode still reports survival candidates"
else
  fail "TC5 offline mode still reports survival candidates" "rc=$RC out=<<$OUT>>"
fi
R5="$(make_fixture)"
run_audit_with_root "$R5" closed "2020-01-01T00:00:00Z" --offline --apply
if [[ "$OUT$ERR" == *"SKIP_DELETE_METADATA_UNAVAILABLE"* && -f "$R5/$DISPATCHER" ]]; then
  pass "TC5b offline mode never deletes (metadata unavailable)"
else
  fail "TC5b offline mode never deletes (metadata unavailable)" "rc=$RC exists=$([[ -f "$R5/$DISPATCHER" ]] && echo yes || echo no) out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R5"

# TC6: json format keeps closed_at and adds the machine-readable gate verdict.
run_audit closed "2020-01-01T00:00:00Z" --format json
if [[ $RC -eq 0 && "$OUT" == *"closed_at"* && "$OUT" == *"ok-closed-stale"* ]]; then
  pass "TC6 json output keeps closed_at and reports the delete-gate verdict"
else
  fail "TC6 json output keeps closed_at and reports the delete-gate verdict" "rc=$RC out=<<$OUT>>"
fi

# TC7: the inverted-contract regression — the target is ALIVE, so no amount of
# issue staleness may make the file a candidate or delete it.
R7="$(make_fixture 'bin/foo.sh')"
run_audit_with_root "$R7" closed "2020-01-01T00:00:00Z" --apply
if [[ $RC -eq 1 && "$OUT" != *"CANDIDATE"* && -f "$R7/$DISPATCHER" ]]; then
  pass "TC7 live target + very old closed issue is not a candidate and is not deleted"
else
  fail "TC7 live target + very old closed issue is not a candidate and is not deleted" "rc=$RC exists=$([[ -f "$R7/$DISPATCHER" ]] && echo yes || echo no) out=<<$OUT>>"
fi
rm -rf "$R7"

# TC8: a recent last-commit date is irrelevant to candidacy — only survival is.
R8="$(make_fixture 'bin/gone.sh' recent)"
run_audit_with_root "$R8" closed "2020-01-01T00:00:00Z" --dry-run
if [[ $RC -eq 0 && "$OUT" == *"CANDIDATE"*"feature-1557-foo.sh"* ]]; then
  pass "TC8 recent last-commit does not prevent candidacy"
else
  fail "TC8 recent last-commit does not prevent candidacy" "rc=$RC out=<<$OUT>>"
fi
rm -rf "$R8"

# Compute the CUTOFF_DATE as the script would (default 3 stale-months = 90 days).
CUTOFF_90_DAYS_AGO=""
if date -d "90 days ago" +%Y-%m-%d >/dev/null 2>&1; then
  CUTOFF_90_DAYS_AGO="$(date -d "90 days ago" +%Y-%m-%d)"
else
  CUTOFF_90_DAYS_AGO="$(uv run python -c "import datetime; print((datetime.date.today() - datetime.timedelta(days=90)).isoformat())")"
fi

# TC9: boundary — closed_at exactly at the cutoff is NOT stale enough to
# authorise deletion (strict `<`), but the file is still reported.
R9="$(make_fixture)"
run_audit_with_root "$R9" closed "${CUTOFF_90_DAYS_AGO}T00:00:00Z" --apply
if [[ "$OUT" == *"CANDIDATE"* && "$OUT$ERR" == *"SKIP_DELETE_ISSUE_ACTIVE"* && -f "$R9/$DISPATCHER" ]]; then
  pass "TC9 closed_at exactly at the cutoff does not authorise deletion"
else
  fail "TC9 closed_at exactly at the cutoff does not authorise deletion" "rc=$RC exists=$([[ -f "$R9/$DISPATCHER" ]] && echo yes || echo no) out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R9"

# TC10: --stale-months moves the delete-gate boundary and nothing else.
# closed_at = 120 days ago authorises deletion at --stale-months 3 (cutoff 90d)
# but is held at --stale-months 6 (cutoff 180d); the CANDIDATE line is
# identical in both runs.
CLOSED_AT_120D=""
if date -d "120 days ago" +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
  CLOSED_AT_120D="$(date -d "120 days ago" +%Y-%m-%dT%H:%M:%SZ)"
else
  CLOSED_AT_120D="$(uv run python -c "import datetime; d=datetime.date.today()-datetime.timedelta(days=120); print(d.isoformat()+'T00:00:00Z')")"
fi
R10a="$(make_fixture)"
run_audit_with_root "$R10a" closed "$CLOSED_AT_120D" --stale-months 3 --apply
if [[ "$OUT" == *"CANDIDATE"* && ! -f "$R10a/$DISPATCHER" ]]; then
  pass "TC10a 120-day-old closed_at authorises deletion with --stale-months 3"
else
  fail "TC10a 120-day-old closed_at authorises deletion with --stale-months 3" "rc=$RC exists=$([[ -f "$R10a/$DISPATCHER" ]] && echo yes || echo no) out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R10a"

R10b="$(make_fixture)"
run_audit_with_root "$R10b" closed "$CLOSED_AT_120D" --stale-months 6 --apply
if [[ "$OUT" == *"CANDIDATE"* && "$OUT$ERR" == *"SKIP_DELETE_ISSUE_ACTIVE"* && -f "$R10b/$DISPATCHER" ]]; then
  pass "TC10b 120-day-old closed_at is held with --stale-months 6, still reported"
else
  fail "TC10b 120-day-old closed_at is held with --stale-months 6, still reported" "rc=$RC exists=$([[ -f "$R10b/$DISPATCHER" ]] && echo yes || echo no) out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R10b"

# --- Summary ---------------------------------------------------------------
echo "1..$((PASS+FAIL))"
echo "# PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
