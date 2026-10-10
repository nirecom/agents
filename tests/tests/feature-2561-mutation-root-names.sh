#!/usr/bin/env bash
# tests/tests/feature-2561-mutation-root-names.sh
# Tests: tests/mutation/root-names.sh
# Tags: tests, mutation, worktree, security, idempotency, scope:issue-specific, tl2
# TL3 gap (what this test does NOT catch):
# - whether the rows of tests/mutation/root-names-targets.tsv are killed in the real checkout
# - the real bin/check-root-names.sh verdict (a stand-in check is used here)
# Closest-to-action mitigation: the one-off run of the probe recorded in the pull request.

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
# shellcheck source=tests/lib/script-checkout-fixture.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"

TMP_ROOT="$(np "$(make_tmp)")"
[[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]] || { echo "cannot create a temp root" >&2; exit 1; }
readonly TMP_ROOT
trap 'touch "$TMP_ROOT/stop"; rm -rf "$TMP_ROOT"; [[ -z "$OWN_CACHE_DIR" ]] || rm -rf "$OWN_CACHE_DIR"' EXIT
harness_isolate "$TMP_ROOT"
unset CLAUDE_CODE_SESSION_ID
. "$(dirname "$0")/feature-2561-mutation-root-names/timeout-cases.sh"

readonly FXM="$TMP_ROOT/fx-main"
readonly LK="$TMP_ROOT/fx-linked"
readonly TSV="$TMP_ROOT/targets.tsv"
readonly PROBE="tests/mutation/root-names.sh"
readonly NAMES_REL="tests/bin/feature-2561-root-names-residue.sh"
readonly S_NAME="SCRIPT_CHECKOUT""_ROOT"
readonly M_NAME="AGENTS_MAIN""_ROOT"
mkdir -p "$TMP_ROOT/mtmp"
export TMPDIR="$TMP_ROOT/mtmp"

expect_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=$3 got=$2"; fi; }
expect_has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing: $3 in: $2" ;; esac; }
# put <relative path> — writes stdin into the fixture, expanding the root-name placeholders.
fill() { sed -e "s/@S@/$S_NAME/g" -e "s/@M@/$M_NAME/g" -e "s/@TC@/TARGET_CHECKOUT_ROOT/g" -e "s/@TM@/TARGET_MAIN_ROOT/g"; }
put() {
  mkdir -p "$(dirname "$FXM/$1")"
  fill >"$FXM/$1"
}
rows() { : >"$TSV"; while [[ "$#" -ge 3 ]]; do printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$TSV"; shift 3; done; }
# probe [args...] — runs the linked-worktree copy against $TSV; sets OUT and RC.
probe() { OUT="$(run_with_timeout 180 bash "$LK/$PROBE" --targets "$TSV" "$@" 2>&1)"; RC=$?; }
tree_state() { git -C "$LK" status --porcelain; }
leftovers() { find "$TMP_ROOT/mtmp" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' '; }

script_checkout_fixture_copy "$FXM" bin/lib/run-all-launch.sh bin/lib/test-language-registry.sh bin/lib/run-all-parallelism.sh bin/run-with-timeout.sh bin/test-language-registry hooks/lib/test-language-registry.js hooks/lib/test-language-registry.json
mkdir -p "$FXM/tests/mutation" "$FXM/tests/lib" "$FXM/tests/bin" "$FXM/tests/unit"
cp "$SCRIPT_CHECKOUT_ROOT/$PROBE" "$FXM/tests/mutation/"
cp "$SCRIPT_CHECKOUT_ROOT/tests/lib/root-decoy-build.js" "$SCRIPT_CHECKOUT_ROOT/tests/lib/root-decoy.sh" "$FXM/tests/lib/"
printf '%s\n' '# retired-names:begin' "# env ROOT_NAMES_FIXTURE_RETIRED" '# retired-names:end' >"$FXM/$NAMES_REL"
printf 'DATA\n' >"$FXM/bin/data.txt"
printf 'exit 0\n' >"$FXM/bin/helper.sh"
printf 'not a known test language\n' >"$FXM/tests/unit/thing.unknownlang"
put bin/tool.sh <<'FIXTURE'
#!/usr/bin/env bash
@S@="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cat "$@S@/bin/data.txt"
FIXTURE
put bin/weak.sh <<'FIXTURE'
#!/usr/bin/env bash
@S@="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "$@S@" >/dev/null
FIXTURE
put bin/caller.sh <<'FIXTURE'
#!/usr/bin/env bash
@S@="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$@S@/bin/helper.sh" >/dev/null 2>&1 || true
FIXTURE
put bin/mod.js <<'FIXTURE'
const fs = require("fs");
const path = require("path");
const @S@ = path.resolve(__dirname, "..");
process.stdout.write(fs.readFileSync(path.join(process.env.@M@ || "", ".env"), "utf8"));
FIXTURE
put bin/tgt.sh <<'FIXTURE'
#!/usr/bin/env bash
@TM@="$1"
@TC@="$2"
printf '%s|%s\n' "$@TM@" "$@TC@"
FIXTURE
put bin/tgt.js <<'FIXTURE'
function show(targetMainRoot, targetCheckoutRoot) {
  return targetMainRoot + "|" + targetCheckoutRoot;
}
process.stdout.write(show(process.argv[2], process.argv[3]) + "\n");
FIXTURE
put bin/crash.sh <<'FIXTURE'
#!/usr/bin/env bash
set -u
@TM@="$1"
printf '%s\n' "${@TM@%/}"
FIXTURE
put bin/scope.js <<'FIXTURE'
function a(targetCheckoutRoot) {
  return targetCheckoutRoot;
}
function b(targetMainRoot) {
  return a(targetMainRoot);
}
process.stdout.write(b(process.argv[2]) + "\n");
FIXTURE
printf '#!/usr/bin/env bash\r\n%s="x"\r\necho "$%s/a"\r\n' "$S_NAME" "$S_NAME" >"$FXM/bin/crlf.sh"
# With ROOT_NAMES_CAPTURE set, the stand-in check keeps a copy of the file it is shown and
# reports any rewrite, so a case can read the rewritten bytes without running a dynamic test.
put bin/check-root-names.sh <<'FIXTURE'
#!/usr/bin/env bash
[[ "$#" -eq 1 && -f "$1" ]] || exit 2
[[ "${ROOT_NAMES_HANG:-}" != static ]] || sleep 60
if [[ -n "${ROOT_NAMES_CAPTURE:-}" ]]; then
  cp "$1" "$ROOT_NAMES_CAPTURE"
  git diff --quiet -- "$1" || exit 1
  exit 0
fi
grep -q -E '^export [A-Z_]*_ROOT=|^[A-Z_]*_ROOT="/nonexistent' "$1" && exit 1
exit 0
FIXTURE
put bin/find-tests-for-source.sh <<'FIXTURE'
#!/usr/bin/env bash
target="-"
[[ "${ROOT_NAMES_HANG:-}" != finder ]] || sleep 60
[[ "$2" == "bin/tool.sh" ]] && target="tests/unit/tool-test.sh"
printf '%s\tappend\tfixture\t%s\t1\t-\t-\t-\n' "$2" "$target"
FIXTURE
put tests/unit/tool-test.sh <<'FIXTURE'
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ "$(bash "$here/bin/tool.sh" 2>/dev/null)" == "DATA" ]]
FIXTURE
put tests/unit/weak-test.sh <<'FIXTURE'
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bash "$here/bin/weak.sh"
bash "$here/bin/caller.sh"
exit 0
FIXTURE
put tests/unit/mod-test.sh <<'FIXTURE'
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ "$(node "$here/bin/mod.js" 2>/dev/null)" == "ROOT_DECOY_MARKER=main" ]]
FIXTURE
put tests/unit/tgt-test.sh <<'FIXTURE'
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ "$(bash "$here/bin/tgt.sh" A B)" == "A|B" && "$(node "$here/bin/tgt.js" A B)" == "A|B" ]]
FIXTURE
put tests/unit/red-test.sh <<'FIXTURE'
exit 1
FIXTURE
put tests/unit/crash-test.sh <<'FIXTURE'
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bash "$here/bin/crash.sh" /x/ >/dev/null 2>&1
FIXTURE
put tests/unit/scope-test.sh <<'FIXTURE'
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
node "$here/bin/scope.js" A >/dev/null
FIXTURE
put tests/unit/leak-test.sh <<'FIXTURE'
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: >"$here/leaked.txt"
exit 0
FIXTURE
put tests/unit/env-test.sh <<'FIXTURE'
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for name in HOME USERPROFILE RUN_ALL_CACHE_DIR CLAUDE_TRANSCRIPT_BASE_DIR; do
  printf '%s=%s\n' "$name" "${!name:-}"
done >"$here/../env.seen"
exit 0
FIXTURE
put tests/unit/slow-test.sh <<'FIXTURE'
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd /
n=0
if grep -q "@M@" "$here/bin/tool.sh"; then
  while [[ ! -e "$here/../stop" && "$n" -lt 300 ]]; do sleep 0.2; n=$((n + 1)); done
fi
exit 0
FIXTURE
# Columns: test | verdict | - or always (printed before the rewrite too) | the line printed.
# Each row is a test of bin/tool.sh that fails only on the rewrite and prints that one line.
cat >"$TMP_ROOT/diag.table" <<'TABLE'
type-error|KILLED-CRASH|-|TypeError: Cannot read properties of undefined (reading 'trim')
arg-type|KILLED-CRASH|-|  code: 'ERR_INVALID_ARG_TYPE'
command-failed|KILLED-CRASH|-|Error: Command failed: git rev-parse --show-toplevel
command-not-found|KILLED-CRASH|-|/x/bin/tool.sh: line 3: absent-tool: command not found
no-such-file|KILLED-CRASH|-|/x/bin/tool.sh: line 3: /x/bin/lib.sh: No such file or directory
tool-no-such-file|KILLED-DYNAMIC|-|cat: /x/bin/data.txt: No such file or directory
prose-command-failed|KILLED-DYNAMIC|-|FAIL: Command failed to print DATA
prose-not-found|KILLED-DYNAMIC|-|FAIL: the log says command not found
printed-before-too|KILLED-DYNAMIC|always|Error: Command failed: probe of an absent tool
TABLE
put tests/unit/diag.body <<'FIXTURE'
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
own="$dir/$(basename "${BASH_SOURCE[0]}" .sh)"
rewritten=0
grep -q "@M@" "$dir/../../bin/tool.sh" && rewritten=1
if [[ "$rewritten" == 1 || -e "$own.always" ]]; then cat "$own.txt" >&2; fi
exit "$rewritten"
FIXTURE
while IFS='|' read -r name _ always text; do
  cp "$FXM/tests/unit/diag.body" "$FXM/tests/unit/diag-$name.sh"
  printf '%s\n' "$text" >"$FXM/tests/unit/diag-$name.txt"
  [[ "$always" == always ]] && : >"$FXM/tests/unit/diag-$name.always"
done <"$TMP_ROOT/diag.table"
timeout_fixture
harness_git_init "$FXM"
git -C "$FXM" config core.autocrlf false
git -C "$FXM" add -A
git -C "$FXM" -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -q -m "fixture"
git -C "$FXM" worktree add -q -b probe-linked "$LK"
readonly TOOL_SUM="$(git -C "$LK" hash-object bin/tool.sh)"

case_begin "each-rename-mistake-is-killed-by-a-dynamic-test" "tests/mutation/root-names.sh"
rows script-to-main bin/tool.sh tests/unit/tool-test.sh \
  main-to-script bin/mod.js tests/unit/mod-test.sh \
  target-checkout-to-script bin/tgt.sh tests/unit/tgt-test.sh \
  target-main-to-target-checkout bin/tgt.sh tests/unit/tgt-test.sh \
  target-main-to-target-checkout bin/tgt.js tests/unit/tgt-test.sh
probe
expect_eq "all killed exits 0" "$RC" "0"
expect_eq "one verdict line per row" "$(printf '%s\n' "$OUT" | grep -c "^KILLED-DYNAMIC	")" "5"
expect_has "bash script-root mistake names its layer" "$OUT" "KILLED-DYNAMIC	script-to-main	bin/tool.sh	layer=dynamic-test"
expect_has "node main-to-script mistake names its layer" "$OUT" "KILLED-DYNAMIC	main-to-script	bin/mod.js	layer=dynamic-test"
expect_has "node target mistake skips the parameter list" "$OUT" "KILLED-DYNAMIC	target-main-to-target-checkout	bin/tgt.js	layer=dynamic-test	line 2;"
expect_has "summary counts the rows" "$OUT" "SUMMARY: KILLED-STATIC=0 KILLED-DYNAMIC=5 KILLED-CRASH=0 LIVE=0 NOT-RUN=0"
expect_eq "every target is restored" "$(tree_state)" ""
expect_eq "the work directory is removed" "$(leftovers)" "0"
case_end

case_begin "swallowed-wrong-root-is-killed-by-the-decoy" "tests/mutation/root-names.sh"
rows script-to-main bin/caller.sh tests/unit/weak-test.sh
probe
expect_eq "a decoy hit kills the mutant" "$RC" "0"
expect_has "the decoy layer is named" "$OUT" "KILLED-DYNAMIC	script-to-main	bin/caller.sh	layer=decoy-hit"
expect_eq "the target is restored" "$(tree_state)" ""
case_end

case_begin "env-name-mistakes-are-killed-by-the-static-check" "tests/mutation/root-names.sh"
rows export-script-root bin/tool.sh tests/unit/weak-test.sh bare-main-assign tests/unit/tool-test.sh tests/unit/weak-test.sh bare-main-assign bin/weak.sh tests/unit/weak-test.sh
probe
expect_eq "statically killed rows exit 0" "$RC" "0"
expect_has "export of the script root is caught statically" "$OUT" "KILLED-STATIC	export-script-root	bin/tool.sh	layer=static"
expect_has "bare assignment in a test is caught statically" "$OUT" "KILLED-STATIC	bare-main-assign	tests/unit/tool-test.sh	layer=static	line 1;"
expect_has "bare assignment lands after the interpreter line" "$OUT" "KILLED-STATIC	bare-main-assign	bin/weak.sh	layer=static	line 2;"
expect_eq "the targets are restored" "$(tree_state)" ""
case_end

case_begin "undetected-mistake-is-live-and-exits-1" "tests/mutation/root-names.sh"
rows script-to-main bin/weak.sh tests/unit/weak-test.sh script-to-main bin/tool.sh tests/unit/tool-test.sh
probe
expect_eq "a live mutant exits 1" "$RC" "1"
expect_has "the live row is reported" "$OUT" "LIVE	script-to-main	bin/weak.sh	layer=none"
expect_has "later rows still run" "$OUT" "KILLED-DYNAMIC	script-to-main	bin/tool.sh"
expect_has "summary counts the live row" "$OUT" "LIVE=1 NOT-RUN=0"
expect_eq "the targets are restored" "$(tree_state)" ""
case_end

case_begin "unlaunched-or-red-test-is-not-a-detection" "tests/mutation/root-names.sh"
rows script-to-main bin/tool.sh tests/unit/thing.unknownlang script-to-main bin/tool.sh tests/unit/red-test.sh target-checkout-to-script bin/weak.sh tests/unit/weak-test.sh script-to-main bin/weak.sh ""
probe
expect_eq "not-run rows exit 2" "$RC" "2"
expect_eq "four rows are not run" "$(printf '%s\n' "$OUT" | grep -c "^NOT RUN	")" "4"
expect_has "an unlaunched test is named" "$OUT" "tests/unit/thing.unknownlang:not-launched"
expect_has "a test that was already failing is named" "$OUT" "tests/unit/red-test.sh:red"
expect_has "a file without such a site is named" "$OUT" "NOT RUN	target-checkout-to-script	bin/weak.sh	layer=none	no site of this kind"
expect_has "a source without a selected test is named" "$OUT" "(none selected)"
expect_has "nothing is counted as killed" "$OUT" "SUMMARY: KILLED-STATIC=0 KILLED-DYNAMIC=0 KILLED-CRASH=0 LIVE=0 NOT-RUN=4"
expect_eq "the targets are restored" "$(tree_state)" ""
rows script-to-main bin/weak.sh tests/unit/weak-test.sh script-to-main bin/tool.sh tests/unit/thing.unknownlang
probe
expect_eq "a live row outranks a not-run row" "$RC" "1"
case_end

case_begin "empty-test-column-uses-the-test-finder" "tests/mutation/root-names.sh"
rows script-to-main bin/tool.sh ""
probe
expect_eq "the selected test kills the mutant" "$RC" "0"
expect_has "the selected test is named as the killer" "$OUT" "tests/unit/tool-test.sh (exit"
case_end

case_begin "dry-run-lists-the-plan-and-touches-nothing" "tests/mutation/root-names.sh"
rows script-to-main bin/tool.sh tests/unit/tool-test.sh export-script-root bin/weak.sh ""
probe --dry-run
expect_eq "dry run exits 0" "$RC" "0"
expect_eq "dry run prints exactly the plan" "$OUT" "PLAN	script-to-main	bin/tool.sh	tests/unit/tool-test.sh"$'\n'"PLAN	export-script-root	bin/weak.sh	(bin/find-tests-for-source.sh)"
expect_eq "dry run leaves the tree alone" "$(tree_state)$(leftovers)" "0"
OUT="$(run_with_timeout 120 bash "$FXM/$PROBE" --targets "$TSV" --dry-run 2>&1)"
expect_eq "dry run is allowed in a main worktree" "$?" "0"
OUT="$(cd "$TMP_ROOT" && run_with_timeout 120 bash "$SCRIPT_CHECKOUT_ROOT/$PROBE" --dry-run 2>&1)"
expect_eq "the tracked target table is well formed" "$?" "0"
for kind in script-to-main main-to-script target-checkout-to-script target-main-to-target-checkout bare-main-assign export-script-root; do
  if [[ "$(printf '%s\n' "$OUT" | grep -c "^PLAN	$kind	")" -ge 2 ]]; then pass "tracked table has two rows of $kind"; else fail "tracked table has two rows of $kind" "$OUT"; fi
done
expect_has "the tracked table holds the named reader" "$OUT" "PLAN	main-to-script	hooks/lib/load-env.js	"
case_end

case_begin "verify-names-rows-without-a-site-or-a-test" "tests/mutation/root-names.sh"
rows script-to-main bin/tool.sh tests/unit/tool-test.sh target-checkout-to-script bin/weak.sh tests/unit/weak-test.sh script-to-main bin/weak.sh tests/unit/absent-test.sh \
  target-main-to-target-checkout bin/crash.sh tests/unit/crash-test.sh script-to-main bin/weak.sh ""
probe --verify
expect_eq "a row without a site or a test exits 1" "$RC" "1"
expect_has "a row with a site and its test is verified" "$OUT" "VERIFIED	script-to-main	bin/tool.sh	line 3	cat \"\$$M_NAME/bin/data.txt\""
expect_has "a row without a site of its kind is named" "$OUT" "NO-SITE	target-checkout-to-script	bin/weak.sh"
expect_has "a row naming an absent test is named" "$OUT" "MISSING-TEST	script-to-main	bin/weak.sh	tests/unit/absent-test.sh"
expect_has "a rewrite that leaves an undefined name is named" "$OUT" "UNRESOLVED	target-main-to-target-checkout	bin/crash.sh	line 4	printf '%s\\n' \"\${TARGET_CHECKOUT_ROOT%/}\""
expect_has "a row the finder gives no test is named" "$OUT" "NO-TEST	script-to-main	bin/weak.sh	"
expect_eq "verify prints one line per row" "$(printf '%s\n' "$OUT" | grep -c .)" "5"
rows script-to-main bin/tool.sh tests/unit/tool-test.sh export-script-root bin/tool.sh ""
probe --verify
expect_eq "sound rows exit 0" "$RC" "0"
expect_eq "verify leaves the tree alone" "$(tree_state)$(leftovers)" "0"
OUT="$(run_with_timeout 120 bash "$FXM/$PROBE" --targets "$TSV" --verify 2>&1)"
expect_eq "verify is allowed in a main worktree" "$?" "0"
OUT="$(cd "$TMP_ROOT" && run_with_timeout 120 bash "$SCRIPT_CHECKOUT_ROOT/$PROBE" --verify 2>&1)"
expect_eq "every tracked row has a rewrite site and existing tests" "$?" "0"
if [[ "$OUT" == *NO-SITE* || "$OUT" == *MISSING-TEST* || "$OUT" == *UNRESOLVED* || "$OUT" == *NO-TEST* ]]; then fail "no tracked row is unusable" "$OUT"; else pass "no tracked row is unusable"; fi
case_end

# Columns: target | kind | file body (~ = line break) | rewritten line number | rewritten line.
fill >"$TMP_ROOT/rules.table" <<'TABLE'
r1.js|script-to-main|const @S@ = __dirname;~const p = @S@ + "/x";|2|const p = process.env.@M@ + "/x";
r2.js|target-checkout-to-script|const @S@ = __dirname;~function f(targetCheckoutRoot) {~  return targetCheckoutRoot;~}|3|  return @S@;
r3.js|main-to-script|const @S@ = __dirname;~const d = process.env["@M@"];|2|const d = @S@;
r4.js|target-main-to-target-checkout|const f = (targetMainRoot) => 1;~let targetCheckoutRoot;~targetMainRoot = 2;~use(targetMainRoot);|4|use(targetCheckoutRoot);
r5.js|main-to-script|const d = process.env.@M@;|1|const d = require("path").resolve(__dirname, "..");
r6.sh|script-to-main|x="${@S@}/a"|1|x="${@M@}/a"
r7.sh|script-to-main|x="$_LIB_@S@/a"|1|x="$@M@/a"
r8.sh|script-to-main|# reads $@S@ here~x="$@S@/a"|2|x="$@M@/a"
r9.sh|export-script-root|if true; then~  _LIB_@S@="x"~fi|2|  export _LIB_@S@="x"
r10.sh|main-to-script|x="$@M@/a"|1|x="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/a"
r11.sh|main-to-script|x="${@M@:-/d}"|1|x="${@S@:-/d}"
r12.sh#2|script-to-main|a="$@S@/1"~b="$@S@/2"|2|b="$@M@/2"
TABLE

case_begin "each-rewrite-rule-lands-on-the-expected-line" "tests/mutation/root-names.sh"
mkdir -p "$LK/rules"
: >"$TSV"
while IFS='|' read -r target kind body _ _; do
  printf '%s\n' "${body//\~/$'\n'}" >"$LK/rules/${target%%#*}"
  printf '%s\trules/%s\ttests/unit/weak-test.sh\n' "$kind" "$target" >>"$TSV"
done <"$TMP_ROOT/rules.table"
probe --verify
expect_eq "every rule row is sound" "$RC" "0"
while IFS='|' read -r target kind _ at want; do
  expect_has "$kind in $target" "$OUT"$'\n' "VERIFIED	$kind	rules/${target%%#*}	line $at	$want"$'\n'
done <"$TMP_ROOT/rules.table"
rm -rf "$LK/rules"
rows script-to-main bin/crlf.sh tests/unit/weak-test.sh
export ROOT_NAMES_CAPTURE="$TMP_ROOT/crlf.seen"
probe
unset ROOT_NAMES_CAPTURE
expect_has "the rewritten file reached the static check" "$OUT" "KILLED-STATIC	script-to-main	bin/crlf.sh	layer=static	line 3;"
expect_eq "the rewrite keeps every CRLF line ending" "$(grep -c $'\r$' "$TMP_ROOT/crlf.seen")" "3"
expect_eq "the rewrite adds no bare line ending" "$(tr -d '\r' <"$TMP_ROOT/crlf.seen" | wc -l | tr -d ' ')" "3"
expect_eq "the rewritten line carries the wrong name" "$(grep -c "echo \"\$$M_NAME/a\"" "$TMP_ROOT/crlf.seen")" "1"
expect_eq "the tree is clean after the rule rows" "$(tree_state)" ""
case_end

case_begin "death-on-a-missing-name-is-not-a-value-kill" "tests/mutation/root-names.sh"
rows target-main-to-target-checkout bin/crash.sh tests/unit/crash-test.sh target-main-to-target-checkout bin/scope.js tests/unit/scope-test.sh
probe
expect_eq "crash-only rows exit 2" "$RC" "2"
expect_has "an unresolved rewrite is a crash kill" "$OUT" "KILLED-CRASH	target-main-to-target-checkout	bin/crash.sh	layer=crash	line 4;"
expect_has "the unresolved rewrite is named" "$OUT" "rewrite=unresolved"
expect_has "a ReferenceError on stderr is a crash kill" "$OUT" "KILLED-CRASH	target-main-to-target-checkout	bin/scope.js	layer=crash	line 5;"
expect_has "the out-of-scope rewrite is named as resolved" "$OUT" "rewrite=resolved"
expect_has "no crash is counted as a value kill" "$OUT" "SUMMARY: KILLED-STATIC=0 KILLED-DYNAMIC=0 KILLED-CRASH=2 LIVE=0 NOT-RUN=0"
expect_eq "the targets are restored" "$(tree_state)" ""
rows script-to-main bin/weak.sh tests/unit/weak-test.sh target-main-to-target-checkout bin/crash.sh tests/unit/crash-test.sh
probe
expect_eq "a live row outranks a crash row" "$RC" "1"
case_end

case_begin "only-a-diagnostic-the-rewrite-added-is-a-crash-kill" "tests/mutation/root-names.sh"
: >"$TSV"
while IFS='|' read -r name _ _ _; do
  printf 'script-to-main\tbin/tool.sh\ttests/unit/diag-%s.sh\n' "$name" >>"$TSV"
done <"$TMP_ROOT/diag.table"
probe
expect_eq "rows with a crash kill exit 2" "$RC" "2"
while IFS='|' read -r name verdict _ text; do
  layer="dynamic-test"
  [[ "$verdict" == KILLED-CRASH ]] && layer="crash"
  expect_has "$name ($text)" "$OUT" "$verdict	script-to-main	bin/tool.sh	layer=$layer	line 3; static=clean; tests/unit/diag-$name.sh (exit 1)"
done <"$TMP_ROOT/diag.table"
expect_has "each row is counted once, by its verdict" "$OUT" "SUMMARY: KILLED-STATIC=0 KILLED-DYNAMIC=$(grep -c '|KILLED-DYNAMIC|' "$TMP_ROOT/diag.table") KILLED-CRASH=$(grep -c '|KILLED-CRASH|' "$TMP_ROOT/diag.table") LIVE=0 NOT-RUN=0"
expect_eq "the target is restored" "$(tree_state)" ""
case_end

case_begin "a-test-that-writes-into-the-checkout-ends-the-probe-as-leaked" "tests/mutation/root-names.sh"
rows script-to-main bin/tool.sh tests/unit/leak-test.sh script-to-main bin/tool.sh tests/unit/tool-test.sh
probe
expect_eq "a leak exits 3" "$RC" "3"
expect_has "the leaking row is named" "$OUT" "LEAKED	script-to-main	bin/tool.sh	layer=none"
expect_eq "no later row runs" "$(printf '%s\n' "$OUT" | grep -c "^KILLED-\|^SUMMARY")" "0"
expect_eq "the leaked file is what changed the tree" "$(tree_state)" "?? leaked.txt"
expect_eq "the target is restored before the leak is reported" "$(git -C "$LK" hash-object bin/tool.sh)" "$TOOL_SUM"
rm -f "$LK/leaked.txt"
expect_eq "the work directory is removed" "$(leftovers)" "0"
case_end

case_begin "launched-tests-see-no-real-home" "tests/mutation/root-names.sh"
rows script-to-main bin/tool.sh "tests/unit/env-test.sh,tests/unit/tool-test.sh"
probe
expect_eq "the row is still killed" "$RC" "0"
for name in HOME USERPROFILE RUN_ALL_CACHE_DIR CLAUDE_TRANSCRIPT_BASE_DIR; do
  seen="$(sed -n "s/^$name=//p" "$TMP_ROOT/env.seen" 2>/dev/null)"
  case "$(np "${seen:-/}")" in
    "$TMP_ROOT/mtmp/"*) pass "$name points inside the work directory" ;;
    *) fail "$name points inside the work directory" "got=$seen" ;;
  esac
done
case_end

case_begin "refuses-main-worktree-dirty-target-and-bad-input" "tests/mutation/root-names.sh"
rows script-to-main bin/tool.sh tests/unit/tool-test.sh
OUT="$(run_with_timeout 120 bash "$FXM/$PROBE" --targets "$TSV" 2>&1)"
expect_eq "a main worktree is refused" "$?" "3"
expect_has "the refusal names the main worktree" "$OUT" "main worktree"
expect_eq "the main worktree is untouched" "$(git -C "$FXM" status --porcelain)" ""
printf '# local edit\n' >>"$LK/bin/tool.sh"
probe
expect_eq "an uncommitted target is refused" "$RC" "3"
expect_has "the refusal names the target" "$OUT" "uncommitted changes: bin/tool.sh"
expect_eq "the local edit is kept" "$(tail -n 1 "$LK/bin/tool.sh")" "# local edit"
git -C "$LK" checkout -q -- bin/tool.sh
rows no-such-kind bin/tool.sh ""
probe
expect_eq "an unknown kind is refused" "$RC" "3"
rows script-to-main bin/absent.sh ""
probe
expect_eq "a missing target is refused" "$RC" "3"
rows script-to-main "../fx-main/bin/tool.sh" ""
probe
expect_eq "a target outside the checkout is refused" "$RC" "3"
rows script-to-main bin/tool.sh ""
probe --no-such-option
expect_eq "an unknown option is refused" "$RC" "3"
mv "$LK/$NAMES_REL" "$TMP_ROOT/names.aside"
probe
mv "$TMP_ROOT/names.aside" "$LK/$NAMES_REL"
expect_eq "a missing retired-name list is refused" "$RC" "3"
expect_has "the refusal names the decoy" "$OUT" "root decoy is unavailable"
expect_eq "no refusal changed a tracked file" "$(tree_state)" ""
expect_eq "no refusal left a work directory" "$(leftovers)" "0"
case_end

case_begin "a-test-over-the-time-limit-is-stopped-and-is-not-a-detection" "tests/mutation/root-names.sh"
timeout_case_mutant_over_the_limit 6
case_end

case_begin "a-test-over-the-limit-before-the-rewrite-is-not-green" "tests/mutation/root-names.sh"
timeout_case_baseline_over_the_limit 6
case_end

case_begin "static-check-and-finder-over-the-limit-are-unusable" "tests/mutation/root-names.sh"
timeout_case_static_check_and_finder 6
case_end

case_begin "time-limit-must-be-a-positive-whole-number" "tests/mutation/root-names.sh"
timeout_case_option_value
case_end

case_begin "termination-during-a-test-restores-the-target" "tests/mutation/root-names.sh"
rows script-to-main bin/tool.sh tests/unit/slow-test.sh
bash "$LK/$PROBE" --targets "$TSV" >"$TMP_ROOT/term.out" 2>&1 &
PROBE_PID=$!
WAITED=0
while ! grep -q "$M_NAME" "$LK/bin/tool.sh" && [[ "$WAITED" -lt 300 ]]; do sleep 0.2; WAITED=$((WAITED + 1)); done
expect_eq "the rewrite was in place when the signal was sent" "$(grep -c "$M_NAME" "$LK/bin/tool.sh")" "1"
kill -TERM "$PROBE_PID"
wait "$PROBE_PID"
expect_eq "termination exits 143" "$?" "143"
touch "$TMP_ROOT/stop"
expect_eq "the target is byte-identical again" "$(git -C "$LK" hash-object bin/tool.sh)" "$TOOL_SUM"
expect_eq "the tree is clean after termination" "$(tree_state)" ""
expect_eq "the work directory is removed after termination" "$(leftovers)" "0"
sleep 1
case_end

echo ""
echo "Results: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]
