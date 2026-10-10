#!/usr/bin/env bash
# tests/tests/feature-2561-root-decoy-build.sh
# Tests: tests/lib/root-decoy-build.js, tests/lib/root-decoy.sh
# Tags: tests, root-decoy, fixture, security, idempotency, scope:issue-specific, tl2
# TL3 gap (what this test does NOT catch):
# - whether tests/run-all.sh and tests/lib/harness.sh route every test through the decoy
# - PowerShell stubs on a host without pwsh
# Closest-to-action mitigation: tests/tests/feature-2561-root-decoy-launcher.sh pins the wiring.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
# Run standalone, the harness would build its decoy under the real ~/.claude/run-all.
OWN_CACHE_DIR=""
if [[ -z "${RUN_ALL_CACHE_DIR:-}" ]]; then
  OWN_CACHE_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t root-decoy-cache)"
  [[ -n "$OWN_CACHE_DIR" && -d "$OWN_CACHE_DIR" ]] || { echo "cannot create a decoy cache directory" >&2; exit 1; }
  export RUN_ALL_CACHE_DIR="$OWN_CACHE_DIR"
fi
readonly OWN_CACHE_DIR
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/lib/root-decoy.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/root-decoy.sh"

TMP_ROOT="$(np "$(make_tmp)")"
[[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]] || { echo "cannot create a temp root" >&2; exit 1; }
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"; [[ -z "$OWN_CACHE_DIR" ]] || rm -rf "$OWN_CACHE_DIR"' EXIT
harness_isolate "$TMP_ROOT"
unset ROOT_DECOY_TEST_ID
. "$(dirname "$0")/feature-2561-root-decoy-build/stub-cases.sh"
. "$(dirname "$0")/feature-2561-root-decoy-build/ensure-cases.sh"

readonly FX="$TMP_ROOT/fx checkout"
readonly TREE="$TMP_ROOT/single tree"
readonly OUT="$TMP_ROOT/out dir"
readonly BUILDER="$FX/tests/lib/root-decoy-build.js"
readonly LIB="$SCRIPT_CHECKOUT_ROOT/tests/lib/root-decoy.sh"
readonly OLD_ENV_NAME="AGENTS_CON""FIG_D""IR"
readonly FAKE_RETIRED_NAME="ROOT_DECOY_FIXTURE_RETIRED"
readonly META_REL="bin/it's \$(touch INJECTED);x.sh"
readonly NAMES_REL="tests/bin/feature-2561-root-names-residue.sh"
TAB="$(printf '\t')"
readonly TAB

expect_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=$3 got=$2"; fi; }
expect_ne() { if [[ "$2" != "$3" ]]; then pass "$1"; else fail "$1" "both sides are $2"; fi; }
expect_has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing: $3 in: $2" ;; esac; }
expect_lacks() { case "$2" in *"$3"*) fail "$1" "unexpected: $3" ;; *) pass "$1" ;; esac; }
build() { run_with_timeout 120 node "$BUILDER" "$@"; }
rc_of() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }
hit_count() { root_decoy_hit_count "$TREE"; }
hit_lines() { root_decoy_hits "$TREE" | grep -c -F -x -- "$1" || true; }
tracked_list() { git -C "$1" -c core.quotePath=false ls-files -z -- bin hooks skills | tr '\0' '\n' | LC_ALL=C sort; }
tree_list() { (cd "$1" && find bin hooks skills -type f | LC_ALL=C sort); }

mkdir -p "$FX/tests/lib" "$FX/tests/bin" "$FX/bin/sub dir" "$FX/hooks/lib" "$FX/skills/demo"
cp "$SCRIPT_CHECKOUT_ROOT/tests/lib/root-decoy-build.js" "$SCRIPT_CHECKOUT_ROOT/tests/lib/root-decoy.sh" "$FX/tests/lib/"
printf '#!/usr/bin/env node\nprocess.stdout.write("REAL-CONTENT\\n");\n' >"$FX/bin/nodecli"
printf '#!/usr/bin/env bash\necho REAL-CONTENT\n' >"$FX/bin/bashcli"
printf 'no shebang REAL-CONTENT\n' >"$FX/bin/plainfile"
printf 'echo REAL-CONTENT\n' >"$FX/bin/sub dir/spaced tool.sh"
printf 'echo REAL-CONTENT\n' >"$FX/$META_REL"
printf 'print("REAL-CONTENT")\n' >"$FX/bin/tool.py"
printf 'Write-Output "REAL-CONTENT"\n' >"$FX/bin/tool.ps1"
printf 'console.log("REAL-CONTENT");\n' >"$FX/hooks/hook.js"
printf 'console.log("REAL-CONTENT");\n' >"$FX/hooks/esm.mjs"
printf 'module.exports = "REAL-CONTENT";\n' >"$FX/hooks/lib/mod.cjs"
printf '# REAL-CONTENT\n' >"$FX/skills/demo/SKILL.md"
printf 'REAL-CONTENT\n' >"$FX/outside.txt"
printf '%s\n' '#!/usr/bin/env bash' '# retired-names:begin' "# env $OLD_ENV_NAME" "# env $FAKE_RETIRED_NAME" '# name someName' '# stem some-stem' '# keep GH_SOMETHING' '# retired-names:end' >"$FX/$NAMES_REL"
harness_git_init "$FX"
git -C "$FX" add -A
printf 'echo REAL-CONTENT\n' >"$FX/bin/untracked.sh"
ensure_write_driver
build --single "$TREE" --marker solo
BUILD_RC=$?

case_begin "single-tree-mirrors-tracked-paths" "tests/lib/root-decoy-build.js"
expect_eq "single build exits 0" "$BUILD_RC" "0"
expect_eq "stub paths equal the tracked bin/hooks/skills paths" "$(tree_list "$TREE")" "$(tracked_list "$FX")"
expect_eq "untracked file is not mirrored" "$(rc_of test -e "$TREE/bin/untracked.sh")" "1"
expect_eq "path outside the mirrored prefixes is not mirrored" "$(rc_of test -e "$TREE/outside.txt")" "1"
expect_eq "single tree carries its marker" "$(cat "$TREE/.env")" "ROOT_DECOY_MARKER=solo"
expect_eq "no stub keeps real content" "$(grep -r -l REAL-CONTENT "$TREE" | wc -l | tr -d ' ')" "0"
case_end

case_begin "real-checkout-tree-mirrors-tracked-paths" "tests/lib/root-decoy-build.js"
run_with_timeout 120 node "$(np "$SCRIPT_CHECKOUT_ROOT/tests/lib/root-decoy-build.js")" --single "$TMP_ROOT/real tree" --marker real
expect_eq "real checkout build exits 0" "$?" "0"
REAL_WANT="$(tracked_list "$SCRIPT_CHECKOUT_ROOT")"
expect_ne "the real checkout tracks mirrored files" "$REAL_WANT" ""
expect_eq "real checkout stub paths equal its tracked paths" "$(tree_list "$TMP_ROOT/real tree")" "$REAL_WANT"
case_end

case_begin "node-stub-records-hit-and-fails" "tests/lib/root-decoy-build.js"
stub_case_node
case_end

case_begin "bash-stub-records-hit-when-run-or-sourced" "tests/lib/root-decoy-build.js"
stub_case_bash
case_end

case_begin "shebang-selects-stub-kind-without-extension" "tests/lib/root-decoy-build.js"
stub_case_shebang
case_end

case_begin "python-stub-records-hit-and-fails" "tests/lib/root-decoy-build.js"
stub_case_python
case_end

case_begin "powershell-stub-records-hit-and-fails" "tests/lib/root-decoy-build.js"
stub_case_powershell
case_end

case_begin "stripped-environment-still-records-hit" "tests/lib/root-decoy-build.js"
stub_case_stripped_environment
case_end

case_begin "test-id-is-recorded-with-the-hit" "tests/lib/root-decoy-build.js"
stub_case_test_id
case_end

case_begin "metacharacter-path-and-environment-stay-inert" "tests/lib/root-decoy-build.js"
stub_case_metacharacters
case_end

case_begin "out-builds-main-and-old-with-markers" "tests/lib/root-decoy-build.js"
build --out "$OUT"
expect_eq "out build exits 0" "$?" "0"
expect_eq "main marker" "$(cat "$OUT/main/.env")" "ROOT_DECOY_MARKER=main"
expect_eq "old marker" "$(cat "$OUT/old/.env")" "ROOT_DECOY_MARKER=old"
expect_eq "main mirrors the tracked paths" "$(tree_list "$OUT/main")" "$(tracked_list "$FX")"
expect_eq "old mirrors the tracked paths" "$(tree_list "$OUT/old")" "$(tracked_list "$FX")"
node "$OUT/old/hooks/hook.js" >/dev/null 2>&1
expect_eq "a hit lands in its own tree only" "$(root_decoy_hit_count "$OUT/old"):$(root_decoy_hit_count "$OUT/main")" "1:0"
case_end

case_begin "rebuild-of-existing-out-is-a-no-op" "tests/lib/root-decoy-build.js"
printf 'keep\n' >"$OUT/main/sentinel"
build --out "$OUT"
expect_eq "second out build exits 0" "$?" "0"
expect_eq "existing tree is left untouched" "$(cat "$OUT/main/sentinel" 2>/dev/null)" "keep"
expect_eq "earlier hits survive the rebuild" "$(root_decoy_hit_count "$OUT/old")" "1"
expect_eq "no temporary sibling is left" "$(find "$TMP_ROOT" -maxdepth 1 -name 'out dir.tmp-*' | wc -l | tr -d ' ')" "0"
case_end

case_begin "half-built-out-is-never-reported-as-a-decoy" "tests/lib/root-decoy-build.js"
HALF="$TMP_ROOT/half out"
mkdir -p "$HALF/main"
printf 'ROOT_DECOY_MARKER=main\n' >"$HALF/main/.env"
HALF_ERR="$(build --out "$HALF" 2>&1 >/dev/null)"
HALF_RC=$?
HALF_STATE="main:$(rc_of test -f "$HALF/main/.env") old:$(rc_of test -f "$HALF/old/.env")"
if [[ "$HALF_RC" -eq 0 ]]; then
  expect_eq "a build that reports success left both trees" "$HALF_STATE" "main:0 old:0"
else
  expect_has "a build that cannot replace the half-built dir says so" "$HALF_ERR" "cannot publish the decoy"
fi
expect_eq "the half-built dir leaves no temporary sibling" "$(find "$TMP_ROOT" -maxdepth 1 -name 'half out.tmp-*' | wc -l | tr -d ' ')" "0"
mkdir -p "$TMP_ROOT/empty out"
build --out "$TMP_ROOT/empty out"
expect_eq "an empty existing dir is filled" "$?:$(rc_of test -f "$TMP_ROOT/empty out/main/.env"):$(rc_of test -f "$TMP_ROOT/empty out/old/.env")" "0:0:0"
case_end

case_begin "bash-stub-still-fails-loudly-without-its-hits-dir" "tests/lib/root-decoy-build.js"
build --single "$TMP_ROOT/no hits tree" --marker nohits
rm -rf "$TMP_ROOT/no hits tree/hits"
NOHITS_ERR="$(bash "$TMP_ROOT/no hits tree/bin/bashcli" 2>&1 >/dev/null)"
expect_ne "the stub exits non-zero" "$?" "0"
expect_has "the stub names itself on stderr" "$NOHITS_ERR" "root-decoy: stub reached: bin/bashcli"
SOURCED="$(bash -c 'source "$1" 2>/dev/null; printf "%s:alive" "$?"' _ "$TMP_ROOT/no hits tree/bin/bashcli")"
expect_ne "the sourced stub returns non-zero" "${SOURCED%%:*}" "0"
expect_eq "the sourcing shell is not killed" "${SOURCED#*:}" "alive"
case_end

case_begin "parallel-out-builds-leave-one-intact-tree" "tests/lib/root-decoy-build.js"
build --out "$TMP_ROOT/par out" &
PID_A=$!
build --out "$TMP_ROOT/par out" &
PID_B=$!
wait "$PID_A"
RC_A=$?
wait "$PID_B"
RC_B=$?
expect_eq "both parallel builds exit 0" "$RC_A:$RC_B" "0:0"
expect_eq "parallel main is intact" "$(tree_list "$TMP_ROOT/par out/main")" "$(tracked_list "$FX")"
expect_eq "parallel old is intact" "$(tree_list "$TMP_ROOT/par out/old")" "$(tracked_list "$FX")"
expect_eq "parallel builds leave no temporary sibling" "$(find "$TMP_ROOT" -maxdepth 1 -name 'par out.tmp-*' | wc -l | tr -d ' ')" "0"
case_end

case_begin "retired-env-names-come-from-the-marked-region" "tests/lib/root-decoy-build.js"
NAMES_FILE="$TMP_ROOT/names list.sh"
printf '%s\n' "# env OUTSIDE_BEFORE" '# retired-names:begin' "# env $OLD_ENV_NAME" '# name otherKind' "# env $FAKE_RETIRED_NAME" '# retired-names:end' '# env OUTSIDE_AFTER' >"$NAMES_FILE"
expect_eq "only env entries inside the region are printed" "$(build --print-retired-env-names --retired-names-from "$NAMES_FILE")" "$OLD_ENV_NAME"$'\n'"$FAKE_RETIRED_NAME"
expect_eq "default list is read from the builder's own checkout" "$(build --print-retired-env-names)" "$OLD_ENV_NAME"$'\n'"$FAKE_RETIRED_NAME"
expect_eq "missing list file exits 2" "$(rc_of build --print-retired-env-names --retired-names-from "$TMP_ROOT/absent.sh")" "2"
printf '%s\n' "# env $OLD_ENV_NAME" >"$NAMES_FILE"
expect_eq "list without the region exits 2" "$(rc_of build --print-retired-env-names --retired-names-from "$NAMES_FILE")" "2"
printf '%s\n' '# retired-names:begin' '# name onlyOtherKinds' '# retired-names:end' >"$NAMES_FILE"
expect_eq "region without an env entry exits 2" "$(rc_of build --print-retired-env-names --retired-names-from "$NAMES_FILE")" "2"
printf '%s\n' '# retired-names:begin' '# env BAD;touch${IFS}INJECTED' '# retired-names:end' >"$NAMES_FILE"
expect_eq "entry that is not a variable name exits 2" "$(rc_of build --print-retired-env-names --retired-names-from "$NAMES_FILE")" "2"
case_end

case_begin "cache-key-follows-the-tracked-path-list" "tests/lib/root-decoy-build.js"
KEY_A="$(build --cache-key)"
expect_eq "cache key is a 16-digit hex string" "$(printf '%s' "$KEY_A" | grep -c -E '^[0-9a-f]{16}$' || true)" "1"
expect_eq "cache key is stable" "$(build --cache-key)" "$KEY_A"
git -C "$FX" add bin/untracked.sh
expect_ne "cache key changes when a tracked path is added" "$(build --cache-key)" "$KEY_A"
git -C "$FX" rm -q --cached bin/untracked.sh
expect_eq "cache key returns with the path list" "$(build --cache-key)" "$KEY_A"
case_end

case_begin "usage-errors-exit-2" "tests/lib/root-decoy-build.js"
expect_eq "unknown argument" "$(rc_of build --no-such-option)" "2"
expect_eq "no mode" "$(rc_of build)" "2"
expect_eq "single without marker" "$(rc_of build --single "$TMP_ROOT/never")" "2"
expect_eq "two modes at once" "$(rc_of build --cache-key --print-retired-env-names)" "2"
expect_eq "rejected single build writes nothing" "$(rc_of test -e "$TMP_ROOT/never")" "1"
expect_eq "marker with a line break" "$(rc_of build --single "$TMP_ROOT/never two" --marker $'first\nSECOND_KEY=injected')" "2"
# Assigned outside the substitution: bash on MSYS drops a CR written inside $( ).
CR_MARKER=$'first\rsecond'
expect_eq "marker with a carriage return" "$(rc_of build --single "$TMP_ROOT/never two" --marker "$CR_MARKER")" "2"
expect_eq "rejected marker writes nothing" "$(rc_of test -e "$TMP_ROOT/never two")" "1"
case_end

case_begin "ensure-builds-under-the-cache-dir-and-exports" "tests/lib/root-decoy.sh"
ensure_case_builds_under_the_cache_dir
case_end

case_begin "ensure-without-a-cache-dir-builds-under-home-and-reuses-it" "tests/lib/root-decoy.sh"
ensure_case_default_location "$SCRIPT_CHECKOUT_ROOT/bin/lib/run-all-parallelism.sh"
case_end

case_begin "ensure-reuses-a-launcher-provided-decoy" "tests/lib/root-decoy.sh"
ensure_case_reuses_a_launcher_decoy
case_end

case_begin "ensure-fails-loudly-without-the-retired-name-list" "tests/lib/root-decoy.sh"
ensure_case_fails_without_the_name_list
case_end

case_begin "use-real-main-root-restores-or-refuses" "tests/lib/root-decoy.sh"
cat >"$TMP_ROOT/real-driver.sh" <<'DRIVER'
source "$1" || exit 90
root_decoy_use_real_main_root 2>/dev/null
printf '%s|%s|' "$?" "$AGENTS_MAIN_ROOT"
bash -c 'printf "%s" "$AGENTS_MAIN_ROOT"'
DRIVER
expect_eq "recorded value is exported back" "$(ROOT_DECOY_REAL_AGENTS_MAIN_ROOT="$TMP_ROOT/real root" AGENTS_MAIN_ROOT="$OUT/main" bash "$TMP_ROOT/real-driver.sh" "$LIB")" "0|$TMP_ROOT/real root|$TMP_ROOT/real root"
expect_eq "empty record is refused and the decoy stays" "$(ROOT_DECOY_REAL_AGENTS_MAIN_ROOT="" AGENTS_MAIN_ROOT="$OUT/main" bash "$TMP_ROOT/real-driver.sh" "$LIB")" "1|$OUT/main|$OUT/main"
expect_eq "unset record is refused" "$(AGENTS_MAIN_ROOT="$OUT/main" env -u ROOT_DECOY_REAL_AGENTS_MAIN_ROOT bash "$TMP_ROOT/real-driver.sh" "$LIB")" "1|$OUT/main|$OUT/main"
case_end

case_begin "hit-readers-report-an-empty-tree-as-zero" "tests/lib/root-decoy.sh"
mkdir -p "$TMP_ROOT/empty tree/hits"
expect_eq "empty tree has no hits" "$(root_decoy_hit_count "$TMP_ROOT/empty tree")" "0"
expect_eq "empty tree lists nothing" "$(root_decoy_hits "$TMP_ROOT/empty tree")" ""
expect_eq "missing tree argument is a usage error" "$(rc_of root_decoy_hit_count)" "2"
case_end

echo ""
echo "Results: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]
