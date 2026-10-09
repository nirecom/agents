#!/usr/bin/env bash
# tests/hooks/feature-2561-agents-main-root-unset-fallback.sh
# Tests: hooks/lib/load-env.js, hooks/lib/load-env.sh, bin/scan-outbound.sh
# Tags: hooks, load-env, scan-outbound, security, scope:issue-specific, tl2
# TL3 gap (what this test does NOT catch):
# - a real git hook or Claude Code hook process, which inherits its environment from the host
# - a reader installed through a symlink (the realpath fallback of the Node reader)
# Closest-to-action mitigation: the hook E2E tests that drive pre-commit against a fixture repo.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/lib/script-checkout-fixture.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"

TMP_ROOT="$(np "$(make_tmp)")"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT"

# Three places a reader could take its settings from, each with its own marker and secret.
readonly FAKE="$TMP_ROOT/copied checkout"
readonly CFG="$TMP_ROOT/configured root"
readonly BARE="$TMP_ROOT/keyless root"
readonly GONE="$TMP_ROOT/missing root"
readonly OTHER="$TMP_ROOT/retired root"
readonly NEUTRAL="$TMP_ROOT/neutral"
mkdir -p "$CFG" "$BARE" "$OTHER" "$NEUTRAL"
if ! script_checkout_fixture_copy "$FAKE" hooks/lib bin/scan-outbound.sh bin/env-os-filter; then
  echo "FAIL: fixture checkout copy — script_checkout_fixture_copy failed; no case can run"
  exit 1
fi
printf 'ROOT_PROBE=checkout\n' >"$FAKE/.env"
printf 'CHECKOUTSECRET\n' >"$FAKE/.private-info-blocklist"
printf 'ROOT_PROBE=configured\n' >"$CFG/.env"
printf 'CONFIGUREDSECRET\n' >"$CFG/.private-info-blocklist"
printf 'UNRELATED_KEY=1\n' >"$BARE/.env"
printf 'ROOT_PROBE=retired\n' >"$OTHER/.env"
printf 'RETIREDSECRET\n' >"$OTHER/.private-info-blocklist"
# Degenerate values of the variable: empty, whitespace only, and a path relative to the
# directory the reader runs from (the readers run from $NEUTRAL).
readonly EMPTY=""
readonly BLANK="   "
readonly REL="relative root"
mkdir -p "$NEUTRAL/$REL"
printf 'ROOT_PROBE=relative\n' >"$NEUTRAL/$REL/.env"
printf 'RELATIVESECRET\n' >"$NEUTRAL/$REL/.private-info-blocklist"

expect_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=$3 got=$2"; fi; }
expect_has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing: $3 in: $2" ;; esac; }
expect_lacks() { case "$2" in *"$3"*) fail "$1" "unexpected: $3 in: $2" ;; *) pass "$1" ;; esac; }

# Retired names never appear in this file: one is assembled from fragments, the rest come from
# the tracked list. A list that cannot be read stops the test: the "ignores the retired
# names" cases would otherwise run against one name and still report green.
OLD_NAMES=("AGENTS_CON""FIG_D""IR")
if ! RETIRED_LIST="$(node "$SCRIPT_CHECKOUT_ROOT/tests/lib/root-decoy-build.js" --print-retired-env-names)"; then
  echo "FAIL: retired-name list — root-decoy-build.js --print-retired-env-names failed"
  exit 1
fi
while IFS= read -r name; do
  name="${name%$'\r'}"
  [[ -n "$name" && "$name" != "${OLD_NAMES[0]}" ]] && OLD_NAMES+=("$name")
done <<<"$RETIRED_LIST"
UNSET_ARGS=(-u AGENTS_MAIN_ROOT -u ROOT_PROBE -u _cfg_dir)
for name in "${OLD_NAMES[@]}"; do UNSET_ARGS+=(-u "$name"); done

# reader <target-main-root|-> <retired-value|-> <command...> — a 120 s run from a neutral directory
# with the main root and the retired names set exactly as given ("-" leaves them unset). The
# project dir is pinned to that neutral directory so no reader can reach the live project.
reader() {
  local main="$1" old="$2" name
  shift 2
  local args=("${UNSET_ARGS[@]}" "CLAUDE_PROJECT_DIR=$NEUTRAL")
  [[ "$main" != "-" ]] && args+=("AGENTS_MAIN_ROOT=$main")
  if [[ "$old" != "-" ]]; then for name in "${OLD_NAMES[@]}"; do args+=("$name=$old"); done; fi
  (cd "$NEUTRAL" && env "${args[@]}" bash "$RWT" 120 "$@" 2>&1)
}

cat >"$TMP_ROOT/js-probe.js" <<'PROBE'
const m = require(process.argv[2]);
console.log("FILE=<" + (m.readDefaultEnvFile().ROOT_PROBE || "") + ">");
console.log("VAR=<" + m.resolveConfigVar("ROOT_PROBE", "dflt").value + ">");
PROBE
cat >"$TMP_ROOT/sh-probe.sh" <<'PROBE'
. "$1" || exit 90
printf 'ONLY=<%s>\n' "$(_load_env_only_value ROOT_PROBE:-dflt)"
_load_env_file
printf 'LOADED=<%s>\n' "${ROOT_PROBE:-}"
PROBE
cat >"$TMP_ROOT/scan-probe.sh" <<'PROBE'
printf 'a CHECKOUTSECRET\nb CONFIGUREDSECRET\nc RETIREDSECRET\nd RELATIVESECRET\n' | bash "$1" --stdin probe
echo "RC=<$?>"
PROBE
# The /c/... form is built INSIDE node: Git Bash rewrites such a value on the way to a
# native process, so passing it from here would never deliver the form under test.
cat >"$TMP_ROOT/js-posix-probe.js" <<'PROBE'
const win = process.argv[3];
if (process.platform !== "win32" || !/^[A-Za-z]:[\\/]/.test(win)) { console.log("NOT-WIN32"); process.exit(0); }
process.env.AGENTS_MAIN_ROOT = "/" + win[0].toLowerCase() + win.slice(2).replace(/\\/g, "/");
const m = require(process.argv[2]);
console.log("FILE=<" + (m.readDefaultEnvFile().ROOT_PROBE || "") + ">");
console.log("VAR=<" + m.resolveConfigVar("ROOT_PROBE", "dflt").value + ">");
PROBE
js_posix() { reader - - node "$TMP_ROOT/js-posix-probe.js" "$FAKE/hooks/lib/load-env.js" "$1"; }
js() { reader "$1" "$2" node "$TMP_ROOT/js-probe.js" "$FAKE/hooks/lib/load-env.js"; }
sh_() { reader "$1" "$2" bash "$TMP_ROOT/sh-probe.sh" "$FAKE/hooks/lib/load-env.sh"; }
scan() { reader "$1" "$2" bash "$TMP_ROOT/scan-probe.sh" "$FAKE/bin/scan-outbound.sh"; }

# --- hooks/lib/load-env.js ---------------------------------------------------------------

case_begin "js-reader-unset-uses-its-own-checkout" "hooks/lib/load-env.js"
OUT="$(js - -)"
expect_has "the file reader answers from the script's own checkout" "$OUT" "FILE=<checkout>"
expect_has "the variable resolver answers from the script's own checkout" "$OUT" "VAR=<checkout>"
expect_eq "a second run gives the same answer" "$(js - -)" "$OUT"
case_end

case_begin "js-reader-set-main-root-is-the-only-source" "hooks/lib/load-env.js"
OUT="$(js "$CFG" -)"
expect_has "the file reader answers from the main root" "$OUT" "FILE=<configured>"
expect_has "the variable resolver answers from the main root" "$OUT" "VAR=<configured>"
case_end

case_begin "js-reader-set-main-root-never-falls-through" "hooks/lib/load-env.js"
OUT="$(js "$BARE" -)"
expect_has "a key absent from the main root reads as unset" "$OUT" "FILE=<>"
expect_has "the resolver returns the default, not the checkout value" "$OUT" "VAR=<dflt>"
OUT="$(js "$GONE" -)"
expect_has "a missing main root reads as unset" "$OUT" "FILE=<>"
expect_has "a missing main root yields the default" "$OUT" "VAR=<dflt>"
case_end

case_begin "js-reader-ignores-the-retired-names" "hooks/lib/load-env.js"
OUT="$(js - "$OTHER")"
expect_has "the file reader still answers from its own checkout" "$OUT" "FILE=<checkout>"
expect_has "the resolver still answers from its own checkout" "$OUT" "VAR=<checkout>"
expect_lacks "nothing is read through a retired name" "$OUT" "retired"
case_end

# The three cases below pin CURRENT behaviour: the two entry points of this module read the
# variable differently (raw truthiness for the file reader, a trimmed and resolved directory
# for the variable resolver), so they disagree on a whitespace-only and on a /c/... value.
case_begin "js-reader-empty-main-root-reads-as-unset" "hooks/lib/load-env.js"
OUT="$(js "$EMPTY" -)"
expect_has "an empty value makes the file reader use its own checkout" "$OUT" "FILE=<checkout>"
expect_has "an empty value makes the resolver use its own checkout" "$OUT" "VAR=<checkout>"
case_end

case_begin "js-reader-whitespace-main-root-splits-the-two-entry-points" "hooks/lib/load-env.js"
OUT="$(js "$BLANK" -)"
expect_has "the file reader takes a whitespace-only value as a directory and finds nothing" "$OUT" "FILE=<>"
expect_has "the resolver treats a whitespace-only value as unset" "$OUT" "VAR=<checkout>"
case_end

case_begin "js-reader-relative-main-root-resolves-from-the-working-directory" "hooks/lib/load-env.js"
OUT="$(js "$REL" -)"
expect_has "the file reader follows a relative value from the working directory" "$OUT" "FILE=<relative>"
expect_has "the resolver follows a relative value from the working directory" "$OUT" "VAR=<relative>"
expect_lacks "the checkout is not consulted for a relative value" "$OUT" "checkout"
case_end

case_begin "js-reader-posix-drive-letter-main-root" "hooks/lib/load-env.js"
OUT="$(js_posix "$CFG")"
if [[ "$OUT" == *NOT-WIN32* ]]; then
  skip "POSIX drive-letter main root (the /c/... form only exists on win32)"
else
  expect_has "the file reader does not normalize a /c/... value and finds nothing" "$OUT" "FILE=<>"
  expect_has "the resolver normalizes a /c/... value and reads the main root" "$OUT" "VAR=<configured>"
fi
case_end

# --- hooks/lib/load-env.sh ---------------------------------------------------------------

case_begin "sh-reader-unset-uses-its-own-checkout" "hooks/lib/load-env.sh"
OUT="$(sh_ - -)"
expect_has "the file-only reader answers from the script's own checkout" "$OUT" "ONLY=<checkout>"
expect_has "the loader exports the checkout value" "$OUT" "LOADED=<checkout>"
expect_eq "a second run gives the same answer" "$(sh_ - -)" "$OUT"
case_end

case_begin "sh-reader-set-main-root-is-the-only-source" "hooks/lib/load-env.sh"
OUT="$(sh_ "$CFG" -)"
expect_has "the file-only reader answers from the main root" "$OUT" "ONLY=<configured>"
expect_has "the loader exports the main root value" "$OUT" "LOADED=<configured>"
case_end

case_begin "sh-reader-set-main-root-never-falls-through" "hooks/lib/load-env.sh"
OUT="$(sh_ "$BARE" -)"
expect_has "a key absent from the main root yields the default" "$OUT" "ONLY=<dflt>"
expect_has "the loader exports nothing for the absent key" "$OUT" "LOADED=<>"
OUT="$(sh_ "$GONE" -)"
expect_has "a missing main root yields the default" "$OUT" "ONLY=<dflt>"
expect_has "a missing main root exports nothing" "$OUT" "LOADED=<>"
case_end

case_begin "sh-reader-ignores-the-retired-names" "hooks/lib/load-env.sh"
OUT="$(sh_ - "$OTHER")"
expect_has "the file-only reader still answers from its own checkout" "$OUT" "ONLY=<checkout>"
expect_has "the loader still exports the checkout value" "$OUT" "LOADED=<checkout>"
expect_lacks "nothing is read through a retired name" "$OUT" "retired"
case_end

case_begin "sh-reader-empty-main-root-reads-as-unset" "hooks/lib/load-env.sh"
OUT="$(sh_ "$EMPTY" -)"
expect_has "an empty value makes the file-only reader use its own checkout" "$OUT" "ONLY=<checkout>"
expect_has "an empty value makes the loader export the checkout value" "$OUT" "LOADED=<checkout>"
case_end

case_begin "sh-reader-whitespace-main-root-is-taken-as-a-directory" "hooks/lib/load-env.sh"
OUT="$(sh_ "$BLANK" -)"
expect_has "a whitespace-only value yields the default, not the checkout value" "$OUT" "ONLY=<dflt>"
expect_has "a whitespace-only value exports nothing" "$OUT" "LOADED=<>"
case_end

case_begin "sh-reader-relative-main-root-resolves-from-the-working-directory" "hooks/lib/load-env.sh"
OUT="$(sh_ "$REL" -)"
expect_has "the file-only reader follows a relative value from the working directory" "$OUT" "ONLY=<relative>"
expect_has "the loader exports the value found through a relative value" "$OUT" "LOADED=<relative>"
case_end

# Which env-os-filter the bash reader EXECUTES. Each stub appends its label to one log and
# passes the file through, so the log is the list of filters that ran: the probe reads the
# file twice (file-only reader, then loader), so one source appears twice. The reader comes
# from a second checkout copy whose filter is a stub; the retired root carries a stub too.
readonly FILTER_LOG="$TMP_ROOT/filter.log"
readonly STUBBED="$TMP_ROOT/stubbed checkout"
readonly FILTERED="$TMP_ROOT/filtering root"
plant_filter() { # <root> <label>
  mkdir -p "$1/bin" || return 1
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >>"%s"\ncat "$1"\n' "$2" "$FILTER_LOG" >"$1/bin/env-os-filter"
  chmod +x "$1/bin/env-os-filter"
}
if ! script_checkout_fixture_copy "$STUBBED" hooks/lib; then
  echo "FAIL: stubbed checkout copy — script_checkout_fixture_copy failed"
  exit 1
fi
mkdir -p "$FILTERED"
printf 'ROOT_PROBE=checkout\n' >"$STUBBED/.env"
printf 'ROOT_PROBE=filtered\n' >"$FILTERED/.env"
plant_filter "$STUBBED" checkout
plant_filter "$FILTERED" filtering
plant_filter "$OTHER" retired
sh_stubbed() { reader "$1" "$2" bash "$TMP_ROOT/sh-probe.sh" "$STUBBED/hooks/lib/load-env.sh"; }

case_begin "sh-reader-filter-origin" "hooks/lib/load-env.sh"
FILTER_ROWS=0
while IFS='|' read -r label main old want_ran want_value; do
  label="${label%"${label##*[![:space:]]}"}"
  [[ -z "$label" ]] && continue
  FILTER_ROWS=$((FILTER_ROWS + 1))
  case "${main//[[:space:]]/}" in
    -) main="-" ;; filtered) main="$FILTERED" ;; plain) main="$CFG" ;;
    *) fail "$label" "unknown main column"; continue ;;
  esac
  case "${old//[[:space:]]/}" in
    -) old="-" ;; retired) old="$OTHER" ;;
    *) fail "$label" "unknown retired column"; continue ;;
  esac
  : >"$FILTER_LOG"
  OUT="$(sh_stubbed "$main" "$old")"
  expect_eq "$label: filters executed" "$(tr '\n' ',' <"$FILTER_LOG")" "${want_ran//[[:space:]]/},"
  expect_has "$label: value read through that filter" "$OUT" "ONLY=<${want_value//[[:space:]]/}>"
done <<'TABLE'
main root unset runs the filter of the reader's own checkout       | -        | -       | checkout,checkout   | checkout
a main root with its own filter runs that filter and no other      | filtered | -       | filtering,filtering | filtered
a main root without a filter falls back to the checkout's filter   | plain    | -       | checkout,checkout   | configured
a root named only by a retired variable never has its filter run   | -        | retired | checkout,checkout   | checkout
TABLE
expect_eq "the filter-origin table asserted every one of its rows" "$FILTER_ROWS" "4"
case_end

# --- bin/scan-outbound.sh ----------------------------------------------------------------

case_begin "scan-unset-uses-the-blocklist-of-its-own-checkout" "bin/scan-outbound.sh"
OUT="$(scan - -)"
expect_has "the checkout blocklist is applied" "$OUT" "[blocklist] CHECKOUTSECRET"
expect_lacks "the main root blocklist is not applied" "$OUT" "[blocklist] CONFIGUREDSECRET"
expect_has "the hard match fails the scan" "$OUT" "RC=<1>"
case_end

case_begin "scan-set-main-root-is-the-only-blocklist" "bin/scan-outbound.sh"
OUT="$(scan "$CFG" -)"
expect_has "the main root blocklist is applied" "$OUT" "[blocklist] CONFIGUREDSECRET"
expect_lacks "the checkout blocklist is not applied" "$OUT" "[blocklist] CHECKOUTSECRET"
expect_has "the hard match fails the scan" "$OUT" "RC=<1>"
case_end

case_begin "scan-set-main-root-without-a-blocklist-fails-closed" "bin/scan-outbound.sh"
OUT="$(scan "$BARE" -)"
expect_has "a main root without a blocklist stops the scan" "$OUT" "RC=<4>"
expect_lacks "the checkout blocklist is not used as a substitute" "$OUT" "[blocklist]"
OUT="$(scan "$GONE" -)"
expect_has "a missing main root stops the scan" "$OUT" "RC=<4>"
expect_lacks "nothing is scanned against another blocklist" "$OUT" "[blocklist]"
case_end

case_begin "scan-ignores-the-retired-names" "bin/scan-outbound.sh"
OUT="$(scan - "$OTHER")"
expect_has "the checkout blocklist is still applied" "$OUT" "[blocklist] CHECKOUTSECRET"
expect_lacks "a blocklist named by a retired variable is not applied" "$OUT" "[blocklist] RETIREDSECRET"
expect_has "the hard match fails the scan" "$OUT" "RC=<1>"
case_end

case_begin "scan-empty-main-root-reads-as-unset" "bin/scan-outbound.sh"
OUT="$(scan "$EMPTY" -)"
expect_has "an empty value applies the checkout blocklist" "$OUT" "[blocklist] CHECKOUTSECRET"
expect_has "the hard match fails the scan" "$OUT" "RC=<1>"
case_end

case_begin "scan-whitespace-main-root-fails-closed" "bin/scan-outbound.sh"
OUT="$(scan "$BLANK" -)"
expect_has "a whitespace-only value stops the scan" "$OUT" "RC=<4>"
expect_lacks "the checkout blocklist is not used as a substitute" "$OUT" "[blocklist]"
case_end

case_begin "scan-relative-main-root-resolves-from-the-working-directory" "bin/scan-outbound.sh"
OUT="$(scan "$REL" -)"
expect_has "the blocklist found through a relative value is applied" "$OUT" "[blocklist] RELATIVESECRET"
expect_lacks "the checkout blocklist is not applied" "$OUT" "[blocklist] CHECKOUTSECRET"
expect_has "the hard match fails the scan" "$OUT" "RC=<1>"
case_end

echo ""
echo "Results: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]
