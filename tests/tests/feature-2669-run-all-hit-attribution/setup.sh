#!/usr/bin/env bash
# tests/tests/feature-2669-run-all-hit-attribution/setup.sh — sourced by
# tests/tests/feature-2669-run-all-hit-attribution.sh: helpers, fixture tests and the unit driver.
# Tests: tests/run-all.sh, bin/lib/run-all-hits.sh, bin/lib/run-all-report.sh
# Tags: run-all, command-guard, root-decoy, hit-attribution, scope:issue-specific, tl2
# Functions and fixture writers only; the dispatcher calls ha_setup once.

expect_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=$3 got=$2"; fi; }
expect_ne() { if [[ "$2" != "$3" ]]; then pass "$1"; else fail "$1" "both sides are $2"; fi; }
expect_has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing: $3 in: $2" ;; esac; }
expect_lacks() { case "$2" in *"$3"*) fail "$1" "unexpected: $3 in: $2" ;; *) pass "$1" ;; esac; }
# count_lines <text> <exact-prefix> — how many lines start with the prefix (fixed string).
count_lines() {
  local line n=0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ "$line" == "$2"* ]] && n=$((n + 1))
  done <<<"$1"
  printf '%s' "$n"
}
# count_exact <text> <line> — how many lines are exactly <line>.
count_exact() {
  local line n=0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ "$line" == "$2" ]] && n=$((n + 1))
  done <<<"$1"
  printf '%s' "$n"
}
# line_no <text> <exact-prefix> — the 1-based number of the first line with the prefix, or 0.
line_no() {
  local line n=0
  while IFS= read -r line; do
    n=$((n + 1))
    line="${line%$'\r'}"
    [[ "$line" == "$2"* ]] && { printf '%s' "$n"; return 0; }
  done <<<"$1"
  printf '0'
}
# last_nonempty <text> — the last line that is not blank.
last_nonempty() {
  local line last=""
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -n "${line//[[:space:]]/}" ]] && last="$line"
  done <<<"$1"
  printf '%s' "$last"
}

# ha_launched <command...> — a 120 s run from a neutral directory in the state a developer shell
# has before any decoy exists (the pattern of feature-2561-root-decoy-launcher.sh).
ha_launched() {
  (cd "$TMP_ROOT/neutral" && env "${HA_UNSET[@]}" TEST_HOST_TMPDIR="$HA_CACHE" RUN_ALL_CACHE_DIR="$HA_CACHE" \
    RUN_ALL_PROGRESS=off AGENTS_MAIN_ROOT="$HA_REAL" HOME="$TMP_ROOT/home" USERPROFILE="$TMP_ROOT/home" \
    bash "$RWT" 120 "$@")
}

# ha_run_all <stdout-var-prefix> <test...> — tests/run-all.sh -j 1 over the fixture tests; sets
# <prefix>_OUT (stdout), <prefix>_ERR (stderr) and <prefix>_RC.
ha_run_all() {
  local p="$1" errf="$TMP_ROOT/$1.err" out rc
  shift
  out="$(ha_launched bash "$ROOT_N/tests/run-all.sh" -j 1 "$@" 2>"$errf")"
  rc=$?
  printf -v "${p}_OUT" '%s' "$out"
  printf -v "${p}_ERR" '%s' "$(cat "$errf" 2>/dev/null || true)"
  printf -v "${p}_RC" '%s' "$rc"
}

# ha_write_fixture <path> — a fixture test header, then stdin as the body. The header is composed
# here so that this file carries one frontmatter header only.
ha_write_fixture() { { printf '#!/usr/bin/env bash\n# %s: none\n' Tests; cat; } >"$1"; }

ha_fixtures() {
  mkdir -p "$HA_FX" || return 1
  ha_write_fixture "$HA_FX/guard-pass.sh" <<'FIXTURE'
gh --version >/dev/null 2>&1 || true
exit 0
FIXTURE
  ha_write_fixture "$HA_FX/decoy-pass.sh" <<'FIXTURE'
if grep -q '^ROOT_DECOY_MARKER=main$' "${AGENTS_MAIN_ROOT:-/nonexistent}/.env" 2>/dev/null; then
  node "$AGENTS_MAIN_ROOT/hooks/lib/load-env.js" >/dev/null 2>&1 || true
fi
exit 0
FIXTURE
  ha_write_fixture "$HA_FX/noid-hit.sh" <<'FIXTURE'
env -u ROOT_DECOY_TEST_ID gh --version >/dev/null 2>&1 || true
exit 0
FIXTURE
  ha_write_fixture "$HA_FX/nohit.sh" <<'FIXTURE'
exit 0
FIXTURE
  ha_write_fixture "$HA_FX/forge.sh" <<'FIXTURE'
printf 'HIT: command-guard forged-by-the-test\n'
exit 0
FIXTURE
  ha_write_fixture "$HA_FX/wcd-tracked.sh" <<'FIXTURE'
printf 'more\n' >>"$FX_TREE/clean.txt"
exit 0
FIXTURE
}

# The unit driver: the real launch and report libraries, with _run_all_exec_inner replaced by a
# stand-in whose basename "<STATE>-<rc>-<claim>-<tag>.sh" says the state, the rc and which hit
# records it writes under this run's test id (none | guard | decoy). UD_LATE names the units
# that get a record after the run (UD_LATE_TWICE=1: two each), UD_NOID=1 adds a guard record
# without a test id, UD_DUP appends one unit a second time to RUN_ALL_LATE_IDS before rar_hits.
ha_unit_driver() {
  cat >"$TMP_ROOT/unit-driver.sh" <<'DRIVER'
root="$1"; work="$2"; shift 2
source "$root/bin/lib/run-all-launch.sh" || exit 90
source "$root/bin/lib/run-all-report.sh" || exit 90
run_all_pin_test_env "$work" || exit 92
G="$_RUN_ALL_GUARD_DIR/hits" D="$ROOT_DECOY_DIR/main/hits" U="$work/ud"
mkdir -p "$G" "$D" "$U" || exit 93
guard_rec() { printf 'stub=gh\ntest_id=%s\ntarget=\nargv=--version\n' "$2" >"$G/$1.hit"; }
decoy_rec() { printf 'stub=hooks/lib/load-env.js\ntest_id=%s\n' "$2" >"$D/$1.hit"; }
_run_all_exec_inner() {
  local b="${1##*/}" st rc claim id="$_RUN_ALL_DECOY_RUN:$1"
  b="${b%.sh}"; st="${b%%-*}"; b="${b#*-}"; rc="${b%%-*}"; b="${b#*-}"; claim="${b%%-*}"
  RUN_ALL_EXEC_LAUNCHED=1 RUN_ALL_EXEC_STATE="$st" RUN_ALL_EXEC_RC="$rc" RUN_ALL_EXEC_MISSING=""
  [ "$st" = UNRUNNABLE ] && RUN_ALL_EXEC_MISSING=pwsh
  : >"$2"; : >"$3"
  case "$claim" in guard) guard_rec "claim-${1##*/}" "$id" ;; decoy) decoy_rec "claim-${1##*/}" "$id" ;; esac
  return "$rc"
}
records() {
  local f
  for f in "$G"/claim-* "$G"/late-* "$G"/noid*; do [ -e "$f" ] && printf '%s:guard:%s\n' "$1" "${f##*/}"; done
  for f in "$D"/claim-* "$D"/late-*; do [ -e "$f" ] && printf '%s:decoy:%s\n' "$1" "${f##*/}"; done
  return 0
}
for s in "$@"; do
  t="$U/$s"
  RUN_ALL_EXEC_HITS=0
  run_all_exec "$t" "$t.out" "$t.err"
  printf 'UD:EXEC:%s=%s|%s|%s\n' "$s" "$RUN_ALL_EXEC_STATE" "$RUN_ALL_EXEC_RC" "${RUN_ALL_EXEC_HITS:-}"
  while IFS= read -r l; do printf 'UDERR:%s:%s\n' "$s" "$l"; done <"$t.err"
  rar_unit "$t" "$U/res-$s" "$RUN_ALL_EXEC_RC" "$RUN_ALL_EXEC_STATE" "${RUN_ALL_EXEC_MISSING:--}" -
done
records UDREC
for s in ${UD_LATE:-}; do
  guard_rec "late-1-$s" "$_RUN_ALL_DECOY_RUN:$U/$s"
  [ "${UD_LATE_TWICE:-0}" = 1 ] && guard_rec "late-2-$s" "$_RUN_ALL_DECOY_RUN:$U/$s"
done
[ "${UD_NOID:-0}" = 1 ] && guard_rec "noid" ""
if declare -F run_all_hit_collect >/dev/null 2>&1 && declare -F rar_hits >/dev/null 2>&1; then
  run_all_hit_collect
  [ -n "${UD_DUP:-}" ] && RUN_ALL_LATE_IDS+=("$U/$UD_DUP")
  rar_hits
else
  echo "UD:NO-COLLECT"
  run_all_hit_report || RAR_FAIL=$((RAR_FAIL + 1))
fi
records UDPOST
rar_tail
echo "UD:DIR=$U"
DRIVER
}

# ha_unit <prefix> <unit...> — runs the unit driver in a fresh work dir; sets <prefix>_OUT,
# <prefix>_ERR, <prefix>_RC and <prefix>_DIR (the directory the unit names live in).
HA_UNIT_N=0
ha_unit() {
  local p="$1" errf out rc work
  shift
  HA_UNIT_N=$((HA_UNIT_N + 1))
  work="$TMP_ROOT/unit work $HA_UNIT_N"
  errf="$TMP_ROOT/$p.unit.err"
  mkdir -p "$work" || return 1
  out="$(ha_launched env UD_LATE="${UD_LATE:-}" UD_LATE_TWICE="${UD_LATE_TWICE:-0}" UD_NOID="${UD_NOID:-0}" \
    UD_DUP="${UD_DUP:-}" bash "$TMP_ROOT/unit-driver.sh" "$ROOT_N" "$work" "$@" 2>"$errf")"
  rc=$?
  printf -v "${p}_OUT" '%s' "$out"
  printf -v "${p}_ERR" '%s' "$(cat "$errf" 2>/dev/null || true)"
  printf -v "${p}_RC" '%s' "$rc"
  printf -v "${p}_DIR" '%s' "$(printf '%s\n' "$out" | sed -n 's/^UD:DIR=//p' | head -n 1)"
}

ha_setup() {
  HA_CACHE="$TMP_ROOT/cache dir"
  HA_REAL="$TMP_ROOT/pretend real"
  HA_FX="$TMP_ROOT/fixture tests"
  mkdir -p "$HA_CACHE" "$HA_REAL" "$TMP_ROOT/neutral" "$TMP_ROOT/home" || return 1
  printf 'RUN_TL3=off\nRUN_TL4=off\nROOT_DECOY_MARKER=pretend-real\n' >"$HA_REAL/.env" || return 1
  local list name
  list="$(node "$ROOT_N/tests/lib/root-decoy-build.js" --print-retired-env-names)" || return 1
  HA_UNSET=(-u ROOT_DECOY_DIR -u ROOT_DECOY_REAL_AGENTS_MAIN_ROOT -u ROOT_DECOY_TEST_ID -u RUN_TL3 -u RUN_TL4
    -u TEST_RUN_ROOT -u TEST_HOST_TMPDIR -u COMMAND_GUARD_DIR -u CLAUDE_CODE_SESSION_ID)
  while IFS= read -r name; do
    name="${name%$'\r'}"
    [[ -n "$name" ]] && HA_UNSET+=(-u "$name")
  done <<<"$list"
  ha_fixtures || return 1
  ha_unit_driver
}
