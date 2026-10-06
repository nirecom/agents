#!/usr/bin/env bash
# tests/bin/bin-verify-case-embed.sh
# Tests: bin/verify-case-embed.sh, bin/verify-case-embed/checks.sh, bin/verify-case-embed/run-compare.sh
# Tags: TL2, bin, case-markers, sweep-tests, verifier, scope:common
# The five-check verifier that gates every case-marker embedding rewrite. Each run
# happens inside a fixture checkout (whole bin/, the registry, the shared harness) so the
# after-file can stand in at its repo path. Cases: tests/bin/bin-verify-case-embed/*.sh.
# TL3 gap: real rewrites by the embed subagent, real flaky tests and a SIGKILL of a real
# stage-3 run are only met when the first band is applied in a later PR.
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$AGENTS_DIR/tests/lib/harness.sh"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

TMPBASE="$(make_tmp)"
trap 'rm -rf "$TMPBASE"' EXIT
export HOME="$TMPBASE/home"
mkdir -p "$HOME"
export NO_LOG=true
# shellcheck source=../../bin/lib/run-all-launch.sh
. "$AGENTS_DIR/bin/lib/run-all-launch.sh"
run_all_pin_state_dirs "$TMPBASE/state" || { echo "FAIL: cannot pin state dirs"; exit 1; }
export RUN_ALL_DURATIONS_LIB=/nonexistent RUN_ALL_PROGRESS=off

# fx_table_edit / has_line: the registry suite's helpers (one owner).
# shellcheck source=test-language-registry/_lib.sh
. "$AGENTS_DIR/tests/bin/test-language-registry/_lib.sh"

VCE_CASES="$AGENTS_DIR/tests/bin/bin-verify-case-embed"
WD="$TMPBASE/work"
mkdir -p "$WD"
T=$'\t'
REAL_TABLE="$AGENTS_DIR/hooks/lib/test-language-registry.json"

# vce_checkout <dir> [<table.json>] — a git checkout holding the whole bin/, the registry
# (optionally replaced by <table.json>), the shared harness, the sweep-tests skill docs,
# the sources the fixture headers name (bin/a.sh bin/b.sh bin/c.sh; bin/gone.sh is
# deliberately absent) and tests/bin/sample.sh + tests/bin/killme.sh holding before.sh.
vce_checkout() {
  local d="$1" t="${2:-}" n
  mkdir -p "$d/tests/lib" "$d/tests/bin"
  cp -R "$AGENTS_DIR/bin" "$d/bin"
  install_test_language_registry "$d" "$AGENTS_DIR"
  if [ -n "$t" ]; then cp "$t" "$d/hooks/lib/test-language-registry.json"; fi
  cp "$AGENTS_DIR/tests/lib/harness.sh" "$d/tests/lib/harness.sh"
  if [ -d "$AGENTS_DIR/skills/sweep-tests" ]; then
    mkdir -p "$d/skills"
    cp -R "$AGENTS_DIR/skills/sweep-tests" "$d/skills/sweep-tests"
  fi
  for n in a b c; do printf '#!/usr/bin/env bash\necho %s\n' "$n" >"$d/bin/$n.sh"; done
  cp "$WD/before.sh" "$d/tests/bin/sample.sh"
  cp "$WD/before.sh" "$d/tests/bin/killme.sh"
  harness_git_init "$d"
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name t
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -q -m fixture >/dev/null 2>&1
}

# vce <checkout> <args...> — that checkout's verifier, run from its root.
# Sets V_RC / V_OUT / V_ERR.
vce() {
  local co="$1"
  shift
  V_RC=0
  V_OUT="$(cd "$co" && run_with_timeout 240 bash "$co/bin/verify-case-embed.sh" "$@" 2>"$TMPBASE/vce.err")" || V_RC=$?
  V_ERR="$(cat "$TMPBASE/vce.err")"
}

# vce_static <checkout> <after-file> [extra args...] — static mode against
# tests/bin/sample.sh with a fresh, empty backup dir (left in V_BK).
vce_static() {
  local co="$1" after="$2"
  shift 2
  V_BK="$(mktemp -d "$TMPBASE/bk.XXXXXX")"
  vce "$co" "$after" --relpath tests/bin/sample.sh --backup-dir "$V_BK" "$@"
}

# check_of <n> — "<status>|<detail>" of the CHECK<n> line in V_OUT (empty when absent).
check_of() {
  printf '%s\n' "$V_OUT" | awk -F'\t' -v n="CHECK$1" '$1 == n { print $2 "|" $3; exit }'
}

# expect_check <label> <n> <status> — one assertion on CHECK<n>'s status.
expect_check() {
  local got
  got="$(check_of "$2")"
  assert_eq "$1: CHECK$2=${got%%|*}" "$1: CHECK$2=$3"
}

# detail_has <label> <n> <substring> — CHECK<n>'s detail contains <substring>.
detail_has() {
  local got
  got="$(check_of "$2")"
  case "${got#*|}" in
    *"$3"*) pass "$1: CHECK$2 detail has $3" ;;
    *) fail "$1: CHECK$2 detail has $3" "line=[$got]" ;;
  esac
}

# intact <label> <checkout> [<relpath>] [<want-file>] — the relpath holds <want-file>
# (default before.sh) again and the last backup dir is empty.
intact() {
  local rel="${3:-tests/bin/sample.sh}" want="${4:-$WD/before.sh}"
  if cmp -s "$2/$rel" "$want"; then pass "$1: $rel restored"; else fail "$1: $rel restored" "content differs"; fi
  if [ -z "$(ls -A "$V_BK" 2>/dev/null)" ]; then pass "$1: backup dir empty"; else fail "$1: backup dir empty" "$(ls -A "$V_BK" | tr '\n' ' ')"; fi
}

# shellcheck source=bin-verify-case-embed/fixtures.sh
. "$VCE_CASES/fixtures.sh"

VCO="$TMPBASE/co"
vce_checkout "$VCO"

case_begin "verifier-entrypoint-present" "bin/verify-case-embed.sh"
for f in bin/verify-case-embed.sh bin/verify-case-embed/checks.sh bin/verify-case-embed/run-compare.sh; do
  if [ -f "$AGENTS_DIR/$f" ]; then pass "present: $f"; else fail "present: $f" "missing"; fi
done
case_end

# shellcheck source=bin-verify-case-embed/static.sh
. "$VCE_CASES/static.sh"
# shellcheck source=bin-verify-case-embed/check4.sh
. "$VCE_CASES/check4.sh"
# shellcheck source=bin-verify-case-embed/compare.sh
. "$VCE_CASES/compare.sh"
# shellcheck source=bin-verify-case-embed/backup.sh
. "$VCE_CASES/backup.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
