#!/usr/bin/env bash
# tests/tests/feature-2561-root-decoy-build/ensure-cases.sh — sourced by
# tests/tests/feature-2561-root-decoy-build.sh: the driver and the case bodies for
# root_decoy_ensure. Functions only.

# ensure_write_driver — writes $TMP_ROOT/ensure-driver.sh: it sources <checkout>/tests/lib/root-decoy.sh
# (and ENSURE_PRELOAD when set), calls root_decoy_ensure and prints what that exported.
# With ENSURE_GUARD_ROOT set it exits 93 BEFORE the call unless TEST_HOST_TMPDIR, HOME and
# USERPROFILE all lie under that directory, so a default-location case can never build outside it.
ensure_write_driver() {
  cat >"$TMP_ROOT/ensure-driver.sh" <<'DRIVER'
source "$1/tests/lib/root-decoy.sh" || exit 90
if [[ -n "${ENSURE_PRELOAD:-}" ]]; then source "$ENSURE_PRELOAD" || exit 92; fi
if [[ -n "${ENSURE_GUARD_ROOT:-}" ]]; then
  [[ "${TEST_HOST_TMPDIR:-}" == "$ENSURE_GUARD_ROOT"/* && "${HOME:-}" == "$ENSURE_GUARD_ROOT"/* && "${USERPROFILE:-}" == "$ENSURE_GUARD_ROOT"/* ]] || exit 93
fi
if declare -F run_all_cache_dir >/dev/null 2>&1; then echo "FN=yes"; else echo "FN=no"; fi
root_decoy_ensure || { printf 'FAILED-MAIN=<%s>\nFAILED-DIR=<%s>\n' "${AGENTS_MAIN_ROOT:-}" "${ROOT_DECOY_DIR:-}"; exit 91; }
printf 'DIR=%s\nMAIN=%s\nREAL=%s\n' "$ROOT_DECOY_DIR" "$AGENTS_MAIN_ROOT" "$ROOT_DECOY_REAL_AGENTS_MAIN_ROOT"
for n in "${@:2}"; do printf 'OLD:%s=%s\n' "$n" "${!n:-}"; done
bash -c 'printf "CHILD_MAIN=%s\n" "$AGENTS_MAIN_ROOT"'
DRIVER
}

ensure_dir_of() { printf '%s\n' "$1" | sed -n 's/^DIR=//p'; }
# A path in one comparable form: mixed slashes, lower case (realpath may change the drive case).
ensure_norm() { np "$1" | tr 'A-Z\\' 'a-z/'; }
ensure_user() { node -e 'process.stdout.write(require("os").userInfo().username)'; }

ensure_case_builds_under_the_cache_dir() {
  local out dir host="$TMP_ROOT/host tmp a"
  mkdir -p "$host"
  out="$(AGENTS_MAIN_ROOT="$TMP_ROOT/pretend real" TEST_HOST_TMPDIR="$host" env -u ROOT_DECOY_DIR -u ROOT_DECOY_REAL_AGENTS_MAIN_ROOT bash "$TMP_ROOT/ensure-driver.sh" "$FX" "$OLD_ENV_NAME" "$FAKE_RETIRED_NAME")"
  expect_eq "ensure exits 0" "$?" "0"
  dir="$(ensure_dir_of "$out")"
  expect_has "decoy lives under the host temp cache base" "$(ensure_norm "$dir")" "$(ensure_norm "$host")/agents-test-cache-"
  expect_has "main root is exported to the child" "$out" "CHILD_MAIN=$dir/main"
  expect_eq "exported main root holds the main marker" "$(cat "$dir/main/.env" 2>/dev/null)" "ROOT_DECOY_MARKER=main"
  expect_has "retired name points at old" "$out" "OLD:$OLD_ENV_NAME=$dir/old"
  expect_has "every listed retired name points at old" "$out" "OLD:$FAKE_RETIRED_NAME=$dir/old"
  expect_has "the value before the switch is kept" "$out" "REAL=$TMP_ROOT/pretend real"
}

# ensure_in_fake_home <fake home> <preload or ""> <guard root> [host tmp] — root_decoy_ensure with
# HOME, USERPROFILE and TEST_HOST_TMPDIR all pinned under the fixture; RUN_ALL_CACHE_DIR is given
# on purpose, since it must no longer move the decoy.
ensure_in_fake_home() {
  HOME="$1" USERPROFILE="$1" TEST_HOST_TMPDIR="${4:-$1/host tmp}" ENSURE_PRELOAD="$2" ENSURE_GUARD_ROOT="$3" AGENTS_MAIN_ROOT="$TMP_ROOT/pretend real" \
    RUN_ALL_CACHE_DIR="$TMP_ROOT/ignored cache" env -u ROOT_DECOY_DIR -u ROOT_DECOY_REAL_AGENTS_MAIN_ROOT bash "$TMP_ROOT/ensure-driver.sh" "$FX"
}

# ensure_default_location_path <label> <fake home> <preload or ""> — one of the two ways the
# caller looks: with run_all_cache_dir defined (preload) or without it. Neither moves the decoy.
ensure_default_location_path() {
  local label="$1" home="$2" preload="$3" fn=no host base want out
  [[ -z "$preload" ]] || fn=yes
  host="$home/host tmp"
  mkdir -p "$home" "$host"
  base="$(ensure_norm "$host")/agents-test-cache-$(ensure_user | tr 'A-Z' 'a-z')/root-decoy"
  want="$(TEST_HOST_TMPDIR="$host" build --cache-dir)"
  out="$(ensure_in_fake_home "$home" "$preload" "$TMP_ROOT" "$host")"
  expect_eq "$label: ensure exits 0" "$?" "0"
  expect_has "$label: run_all_cache_dir defined is $fn" "$out" "FN=$fn"
  expect_eq "$label: builder names <TEST_HOST_TMPDIR>/agents-test-cache-<user>/root-decoy/<key>" "$(printf '%s' "$(ensure_norm "$want")" | grep -c -F -- "$base/" || true):$(printf '%s' "$want" | grep -c -E '/root-decoy/[0-9a-f]{16}$' || true)" "1:1"
  expect_eq "$label: decoy is at the builder's cache dir" "$(ensure_norm "$(ensure_dir_of "$out")")" "$(ensure_norm "$want")"
  expect_eq "$label: the decoy is built there" "$(cat "$want/main/.env" 2>/dev/null):$(cat "$want/old/.env" 2>/dev/null)" "ROOT_DECOY_MARKER=main:ROOT_DECOY_MARKER=old"
  expect_eq "$label: nothing is created under HOME outside the host temp" "$(find "$home" -mindepth 1 -maxdepth 1 ! -name 'host tmp' | wc -l | tr -d ' ')" "0"
  expect_eq "$label: RUN_ALL_CACHE_DIR does not move the decoy" "$(rc_of test -e "$TMP_ROOT/ignored cache/root-decoy")" "1"
  printf 'keep\n' 2>/dev/null >"$want/main/sentinel"
  out="$(ensure_in_fake_home "$home" "$preload" "$TMP_ROOT" "$host")"
  expect_eq "$label: a second call names the same directory" "$?:$(ensure_norm "$(ensure_dir_of "$out")")" "0:$(ensure_norm "$want")"
  expect_eq "$label: a second call reuses the tree" "$(cat "$want/main/sentinel" 2>/dev/null)" "keep"
  expect_eq "$label: no second decoy or temporary sibling appears" "$(find "${want%/*}" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')" "1"
}

ensure_case_default_location() {
  local refused="$TMP_ROOT/guard/home refused"
  ensure_default_location_path "no helper" "$TMP_ROOT/home plain" ""
  ensure_default_location_path "with helper" "$TMP_ROOT/home helper" "$1"
  mkdir -p "$refused"
  ensure_in_fake_home "$refused" "" "$TMP_ROOT/not the parent" "$TMP_ROOT/guard/host" >/dev/null 2>&1
  expect_eq "a home outside the guard root stops the driver before the call" "$?" "93"
  TEST_HOST_TMPDIR="$TMP_ROOT/outside host" HOME="$refused" USERPROFILE="$refused" ENSURE_GUARD_ROOT="$TMP_ROOT/guard" bash "$TMP_ROOT/ensure-driver.sh" "$FX" >/dev/null 2>&1
  expect_eq "a host temp outside the guard root stops the guarded driver before the call" "$?" "93"
  expect_eq "a stopped driver builds nothing" "$(find "$refused" -mindepth 1 | wc -l | tr -d ' '):$(rc_of test -e "$TMP_ROOT/guard/host"):$(rc_of test -e "$TMP_ROOT/outside host")" "0:1:1"
}

ensure_case_reuses_a_launcher_decoy() {
  local out
  out="$(ROOT_DECOY_DIR="$OUT" ROOT_DECOY_REAL_AGENTS_MAIN_ROOT="$TMP_ROOT/launcher real" TEST_HOST_TMPDIR="$TMP_ROOT/unused host" env -u "$OLD_ENV_NAME" -u "$FAKE_RETIRED_NAME" bash "$TMP_ROOT/ensure-driver.sh" "$FX" "$OLD_ENV_NAME" "$FAKE_RETIRED_NAME")"
  expect_has "launcher decoy is used as is" "$out" "MAIN=$OUT/main"
  expect_has "retired name points at the provided old tree" "$out" "OLD:$OLD_ENV_NAME=$OUT/old"
  expect_has "every listed retired name points at the provided old tree" "$out" "OLD:$FAKE_RETIRED_NAME=$OUT/old"
  expect_has "launcher-recorded real value is not overwritten" "$out" "REAL=$TMP_ROOT/launcher real"
  expect_eq "no second decoy is built" "$(rc_of test -e "$TMP_ROOT/unused host")" "1"
  expect_eq "reused tree is left untouched" "$(cat "$OUT/main/sentinel" 2>/dev/null)" "keep"
}

ensure_case_fails_without_the_name_list() {
  local out rc
  mv "$FX/$NAMES_REL" "$TMP_ROOT/names.aside"
  out="$(AGENTS_MAIN_ROOT="$TMP_ROOT/pretend real" TEST_HOST_TMPDIR="$TMP_ROOT/fail host" env -u ROOT_DECOY_DIR bash "$TMP_ROOT/ensure-driver.sh" "$FX" 2>&1)"
  rc=$?
  mv "$TMP_ROOT/names.aside" "$FX/$NAMES_REL"
  expect_eq "ensure reports failure" "$rc" "91"
  expect_has "failure names the missing list" "$out" "retired environment names are unavailable"
  expect_has "the main root is left as it was" "$out" "FAILED-MAIN=<$TMP_ROOT/pretend real>"
  expect_has "no decoy directory is exported" "$out" "FAILED-DIR=<>"
  expect_eq "no decoy is built after the failure" "$(find "$TMP_ROOT/fail host" -path '*root-decoy/*' 2>/dev/null | wc -l | tr -d ' ')" "0"
}
