#!/usr/bin/env bash
# Tests: bin/audit-tests.sh
# Tags: TL2, audit-tests, retire, scope:issue-specific
#
# TL2 test of bin/audit-tests.sh closed_at-based candidate selection.
# Spawns the real script against a throwaway git fixture with a mocked `gh`
# CLI on PATH so no network is touched. Source under test is being migrated
# from last-commit-date logic to closed_at logic (#1557) — cases assert the
# post-migration behaviour and go green once the migration lands.
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
# Builds a self-contained git repo whose tests/ holds one feature dispatcher,
# and installs a `gh` mock on PATH that answers based on env fixtures.
#   MOCK_STATE      : issue state returned by the state query (open|closed)
#   MOCK_CLOSED_AT  : closed_at value returned by the closed_at query
make_fixture() {
  local root; root="$(mktemp -d)"
  git -C "$root" init -q
  git -C "$root" config user.email "t@example.com"
  git -C "$root" config user.name "t"
  mkdir -p "$root/tests" "$root/bin"
  cat > "$root/bin/foo.sh" <<'EOF'
#!/usr/bin/env bash
echo foo
EOF
  cat > "$root/tests/feature-1557-foo.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/foo.sh
# Tags: TL2, scope:issue-specific
echo foo
EOF
  git -C "$root" add -A >/dev/null 2>&1
  GIT_AUTHOR_DATE="2020-01-01T00:00:00" GIT_COMMITTER_DATE="2020-01-01T00:00:00" \
    git -C "$root" commit -q -m init >/dev/null 2>&1
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
    "")
      printf '{"state":"%s","closed_at":%s}\n' "$state" "$closed_json" ;;
    *)
      printf '{"state":"%s","closed_at":%s}\n' "$state" "$closed_json" ;;
  esac
  exit 0
fi
exit 0
EOF
  chmod +x "$bindir/gh"
}

# Run audit inside a fixture with a gh mock. Captures stdout+exit.
# Args: state closed_at [extra audit args...]
# Sets: OUT, ERR, RC
run_audit() {
  local state="$1"; local closed_at="$2"; shift 2
  local root; root="$(make_fixture)"
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
  rm -rf "$root" "$outf" "$errf"
}

# Offline run (no gh needed).
run_audit_offline() {
  local root; root="$(make_fixture)"
  local outf errf
  outf="$(mktemp)"; errf="$(mktemp)"
  set +e
  ( cd "$root" && bash "$AUDIT" --offline "$@" ) >"$outf" 2>"$errf"
  RC=$?
  set -e
  OUT="$(cat "$outf")"
  ERR="$(cat "$errf")"
  rm -rf "$root" "$outf" "$errf"
}

# --- Cases -----------------------------------------------------------------

# TC1: closed + closed_at older than cutoff => CANDIDATE, exit 0
run_audit closed "2020-01-01T00:00:00Z"
if [[ $RC -eq 0 && "$OUT" == *"CANDIDATE"*"feature-1557-foo.sh"* ]]; then
  pass "TC1 old closed issue is a candidate"
else
  fail "TC1 old closed issue is a candidate" "rc=$RC out=<<$OUT>>"
fi

# TC2: closed but closed_at newer than cutoff => no candidate, exit 1
run_audit closed "${TODAY_ISO:-$(date +%Y-%m-%d)}T00:00:00Z"
if [[ $RC -eq 1 && "$OUT" != *"CANDIDATE"* ]]; then
  pass "TC2 recently-closed issue is not a candidate"
else
  fail "TC2 recently-closed issue is not a candidate" "rc=$RC out=<<$OUT>>"
fi

# TC3: open issue => no candidate, exit 1
run_audit open ""
if [[ $RC -eq 1 && "$OUT" != *"CANDIDATE"* ]]; then
  pass "TC3 open issue is not a candidate"
else
  fail "TC3 open issue is not a candidate" "rc=$RC out=<<$OUT>>"
fi

# TC4: closed but closed_at empty => WARNING on stderr, skipped, exit 1.
# The fixture's `# Tests: bin/foo.sh` path resolves, so the only WARNING that
# can appear is the missing-closed_at one emitted by the migrated logic.
run_audit closed ""
if [[ $RC -eq 1 && "$OUT" != *"CANDIDATE"* && "$ERR" == *"WARNING"* && "$ERR" == *closed_at* ]]; then
  pass "TC4 closed with empty closed_at warns and skips"
else
  fail "TC4 closed with empty closed_at warns and skips" "rc=$RC err=<<$ERR>> out=<<$OUT>>"
fi

# TC5: offline mode => no candidates, exit 1
run_audit_offline
if [[ $RC -eq 1 && "$OUT" != *"CANDIDATE"* ]]; then
  pass "TC5 offline mode emits no candidates"
else
  fail "TC5 offline mode emits no candidates" "rc=$RC out=<<$OUT>>"
fi

# TC6: json format includes closed_at field for the candidate
run_audit closed "2020-01-01T00:00:00Z" --format json
if [[ $RC -eq 0 && "$OUT" == *"closed_at"* ]]; then
  pass "TC6 json output includes closed_at field"
else
  fail "TC6 json output includes closed_at field" "rc=$RC out=<<$OUT>>"
fi

# make_fixture_recent_commit: like make_fixture but the dispatcher commit date
# is set to today so that last-commit-based logic would NOT flag it as stale.
make_fixture_recent_commit() {
  local root; root="$(mktemp -d)"
  git -C "$root" init -q
  git -C "$root" config user.email "t@example.com"
  git -C "$root" config user.name "t"
  mkdir -p "$root/tests" "$root/bin"
  cat > "$root/bin/foo.sh" <<'EOF'
#!/usr/bin/env bash
echo foo
EOF
  cat > "$root/tests/feature-1557-foo.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/foo.sh
# Tags: TL2, scope:issue-specific
echo foo
EOF
  git -C "$root" add -A >/dev/null 2>&1
  git -C "$root" commit -q -m init >/dev/null 2>&1
  echo "$root"
}

# run_audit_with_root: like run_audit but uses a caller-provided fixture root.
# Args: root state closed_at [extra audit args...]
# Sets: OUT, ERR, RC; does NOT rm root (caller must clean up).
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

# Compute the CUTOFF_DATE as the script would (default 3 stale-months = 90 days).
CUTOFF_90_DAYS_AGO=""
if date -d "90 days ago" +%Y-%m-%d >/dev/null 2>&1; then
  CUTOFF_90_DAYS_AGO="$(date -d "90 days ago" +%Y-%m-%d)"
else
  CUTOFF_90_DAYS_AGO="$(python3 -c "import datetime; print((datetime.date.today() - datetime.timedelta(days=90)).isoformat())")"
fi

# TC7: migration regression — old last-commit + recent closed_at => NOT a candidate
# Verifies that old last-commit date alone does not trigger candidacy; closed_at
# (post-migration logic) is what counts, and a recent closed_at means NOT a candidate.
RECENT_CLOSED_AT="$(date +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || python3 -c "import datetime; print(datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'))")"
run_audit closed "$RECENT_CLOSED_AT"
if [[ $RC -eq 1 && "$OUT" != *"CANDIDATE"* ]]; then
  pass "TC7 old last-commit + recent closed_at is not a candidate (migration regression)"
else
  fail "TC7 old last-commit + recent closed_at is not a candidate (migration regression)" "rc=$RC out=<<$OUT>>"
fi

# TC8: symmetric regression — old closed_at + recent last-commit => IS a candidate
# Verifies that a recent last-commit date does not prevent candidacy; old closed_at
# alone is sufficient for the post-migration logic to flag the dispatcher.
OLD_CLOSED_AT="2020-01-01T00:00:00Z"
root_recent="$(make_fixture_recent_commit)"
run_audit_with_root "$root_recent" closed "$OLD_CLOSED_AT"
if [[ $RC -eq 0 && "$OUT" == *"CANDIDATE"*"feature-1557-foo.sh"* ]]; then
  pass "TC8 old closed_at + recent last-commit is a candidate"
else
  fail "TC8 old closed_at + recent last-commit is a candidate" "rc=$RC out=<<$OUT>>"
fi
rm -rf "$root_recent"

# TC9: boundary — closed_at == CUTOFF_DATE => NOT a candidate (strict < comparison)
run_audit closed "${CUTOFF_90_DAYS_AGO}T00:00:00Z"
if [[ $RC -eq 1 && "$OUT" != *"CANDIDATE"* ]]; then
  pass "TC9 closed_at equal to cutoff boundary is not a candidate"
else
  fail "TC9 closed_at equal to cutoff boundary is not a candidate" "rc=$RC out=<<$OUT>>"
fi

# TC10: --stale-months custom value changes the cutoff boundary
# closed_at = 120 days ago is a candidate with --stale-months 3 (cutoff=90d)
# but NOT a candidate with --stale-months 6 (cutoff=180d).
# Verifies the cutoff is derived from the argument, not hardcoded.
CLOSED_AT_120D=""
if date -d "120 days ago" +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
  CLOSED_AT_120D="$(date -d "120 days ago" +%Y-%m-%dT%H:%M:%SZ)"
else
  CLOSED_AT_120D="$(python3 -c "import datetime; d=datetime.date.today()-datetime.timedelta(days=120); print(d.isoformat()+'T00:00:00Z')")"
fi
run_audit closed "$CLOSED_AT_120D" --stale-months 3
if [[ $RC -eq 0 && "$OUT" == *"CANDIDATE"* ]]; then
  pass "TC10a 120-day-old closed_at is a candidate with --stale-months 3"
else
  fail "TC10a 120-day-old closed_at is a candidate with --stale-months 3" "rc=$RC out=<<$OUT>>"
fi
run_audit closed "$CLOSED_AT_120D" --stale-months 6
if [[ $RC -eq 1 && "$OUT" != *"CANDIDATE"* ]]; then
  pass "TC10b 120-day-old closed_at is NOT a candidate with --stale-months 6"
else
  fail "TC10b 120-day-old closed_at is NOT a candidate with --stale-months 6" "rc=$RC out=<<$OUT>>"
fi

# --- Summary ---------------------------------------------------------------
echo "1..$((PASS+FAIL))"
echo "# PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
