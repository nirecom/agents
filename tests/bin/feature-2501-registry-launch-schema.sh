#!/usr/bin/env bash
# tests/bin/feature-2501-registry-launch-schema.sh
# Tests: hooks/lib/test-language-registry.js, bin/lib/test-language-registry.sh, hooks/lib/test-language-registry.json
# Tags: TL2, bin, hooks, test-language-registry, launch, wrapper, test-lang-exception, scope:issue-specific, pwsh-not-required
# #2501 launch schema: launch.wrapper (repo-relative, no "..", must exist under the loader's
# repo root), launch.minVersion {runtime, version}, the {wrapper}/{minVersion} placeholders
# (only with their field), and timeoutSeconds as a positive integer or null (bash ships null).
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

TMPBASE="$(make_tmp)"
trap 'rm -rf "$TMPBASE"' EXIT
harness_isolate "$TMPBASE/iso"

# shellcheck source=test-language-registry/_lib.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/test-language-registry/_lib.sh"

# A fixture checkout whose CLI and reader resolve wrappers against its own root. It
# carries the real wrappers (install_test_language_registry does not copy them) and a
# fixture-only wrapper, so the accept cases do not depend on the real wrapper set.
CO="$TMPBASE/co"
SCH="$TMPBASE/schema"
mkdir -p "$SCH"
install_test_language_registry "$CO" "$SCRIPT_CHECKOUT_ROOT" || echo "fixture: install_test_language_registry failed" >&2
if [ -d "$SCRIPT_CHECKOUT_ROOT/bin/lib/test-wrappers" ]; then cp -R "$SCRIPT_CHECKOUT_ROOT/bin/lib/test-wrappers" "$CO/bin/lib/"; fi
mkdir -p "$CO/bin/lib"
printf '#!/usr/bin/env bash\nexec bash "$@"\n' >"$CO/bin/lib/fx-wrap.sh"
CO_CLI_M="$(np "$CO/bin/test-language-registry")"
CO_READER="$CO/hooks/lib/test-language-registry.js"
BASE="$FIXTURES/fake-suite.json"

# co_cli <table.json> — the fixture checkout's CLI on <table>; sets CLI_RC / CLI_OUT.
co_cli() {
  CLI_RC=0
  node "$CO_CLI_M" --format shell --file "$(np "$1")" >"$TMPBASE/co.out" 2>"$TMPBASE/co.err" || CLI_RC=$?
  CLI_OUT="$(cat "$TMPBASE/co.out")"
  case "$(cat "$TMPBASE/co.err")" in *MODULE_NOT_FOUND* | *"Cannot find module"*) CLI_RC="missing-cli" ;; esac
}

# expect_table <accept|reject> <name> <table.json> — CLI exit and loadRegistry agree.
expect_table() {
  local want_rc=0 want_load=OK got
  if [ "$1" = reject ]; then want_rc=1; want_load=THROW; fi
  co_cli "$3"
  if [ "$CLI_RC" = "$want_rc" ]; then
    pass "CLI ${1}s $2 (exit $want_rc)"
  else
    fail "CLI ${1}s $2 (exit $want_rc)" "rc=$CLI_RC err=$(head -n 2 "$TMPBASE/co.err" | tr '\n' ' ')"
  fi
  got="$(drv load "$CO_READER" "$3")"
  assert_eq "$2 loadRegistry=$got" "$2 loadRegistry=$want_load"
}

# rows <accept|reject> — "name|js" rows on stdin; js edits t (l = entries[0].launch, bash).
rows() {
  local mode="$1" name body
  while IFS='|' read -r name body; do
    [ -n "$name" ] || continue
    fx_table_edit "$BASE" "$SCH/$name.json" "const l = t.entries[0].launch; $body"
    expect_table "$mode" "$name" "$SCH/$name.json"
  done
}

case_begin "launch-wrapper-field" "hooks/lib/test-language-registry.js"
# Control: the unmodified base table is valid in this checkout.
expect_table accept base-control "$BASE"
rows accept <<'ROWS'
wrapper-repo-relative-existing|l.wrapper = "bin/lib/fx-wrap.sh"; l.command = ["bash", "{wrapper}", "{path}"];
ROWS
rows reject <<'ROWS'
wrapper-with-dotdot|l.wrapper = "bin/lib/../lib/fx-wrap.sh"; l.command = ["bash", "{wrapper}", "{path}"];
wrapper-missing-file|l.wrapper = "bin/lib/no-such-wrap.sh"; l.command = ["bash", "{wrapper}", "{path}"];
wrapper-placeholder-without-field|l.command = ["bash", "{wrapper}", "{path}"];
ROWS
# Absolute: the file exists, so only the absoluteness can reject it.
fx_table_edit "$BASE" "$SCH/wrapper-absolute.json" "t.entries[0].launch.wrapper = \"$(np "$CO/bin/lib/fx-wrap.sh")\";"
expect_table reject wrapper-absolute "$SCH/wrapper-absolute.json"
# A suite (entries[1]) reaches its wrapper the same way; only the test-path placeholders are refused.
while IFS='|' read -r mode name body; do
  [ -n "$name" ] || continue
  fx_table_edit "$BASE" "$SCH/$name.json" "const s = t.entries[1].launch; $body"
  expect_table "$mode" "$name" "$SCH/$name.json"
done <<'ROWS'
accept|suite-wrapper-placeholder|s.wrapper = "bin/lib/fx-wrap.sh"; s.command = ["bash", "{wrapper}"];
accept|suite-wrapper-in-prepare|s.wrapper = "bin/lib/fx-wrap.sh"; s.prepare = ["bash", "{wrapper}"];
reject|suite-wrapper-placeholder-without-field|s.command = ["bash", "{wrapper}"];
reject|suite-path-placeholder|s.command = ["bash", "{path}"];
reject|suite-native-path-placeholder|s.command = ["bash", "{nativePath}"];
reject|suite-native-path-sq-placeholder|s.command = ["bash", "{nativePathSq}"];
reject|suite-path-beside-wrapper|s.wrapper = "bin/lib/fx-wrap.sh"; s.command = ["bash", "{wrapper}", "{path}"];
ROWS
case_end

case_begin "launch-min-version-field" "hooks/lib/test-language-registry.js"
rows accept <<'ROWS'
min-version-major|l.minVersion = { runtime: "fx", version: "5" };
min-version-minor|l.minVersion = { runtime: "fx", version: "5.0" };
min-version-patch|l.minVersion = { runtime: "fx", version: "5.0.1" };
min-version-placeholder-with-field|l.minVersion = { runtime: "fx", version: "5.0" }; l.command = ["bash", "{path}", "{minVersion}"];
ROWS
rows reject <<'ROWS'
min-version-v-prefix|l.minVersion = { runtime: "fx", version: "v5" };
min-version-wildcard|l.minVersion = { runtime: "fx", version: "5.x" };
min-version-no-runtime|l.minVersion = { version: "5.0" };
min-version-placeholder-without-field|l.command = ["bash", "{path}", "{minVersion}"];
ROWS
case_end

case_begin "supported-timeout-positive-int-or-null" "hooks/lib/test-language-registry.js"
# null / absent = no per-file kill (the caller's RUN_ALL_TIMEOUT_SECONDS or --deadline bounds it).
rows accept <<'ROWS'
supported-timeout-null|l.timeoutSeconds = null;
supported-timeout-missing|delete l.timeoutSeconds;
supported-timeout-one|l.timeoutSeconds = 1;
supported-timeout-int|l.timeoutSeconds = 180;
ROWS
rows reject <<'ROWS'
supported-timeout-zero|l.timeoutSeconds = 0;
supported-timeout-negative|l.timeoutSeconds = -5;
supported-timeout-fraction|l.timeoutSeconds = 1.5;
supported-timeout-string|l.timeoutSeconds = "60";
ROWS
case_end

# launch.runtimeProbe was removed (#2501, one timer per file): uv supplying pytest is install-time
# setup, so no entry declares a pre-launch probe and neither loader exposes one.
case_begin "real-table-has-no-runtime-probe" "hooks/lib/test-language-registry.json"
js_table="$(cat <<'JS'
const t = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const has = (o) => o && typeof o === "object" && Object.prototype.hasOwnProperty.call(o, "runtimeProbe");
const ids = t.entries.filter((e) => has(e) || has(e.launch)).map((e) => e.id);
process.stdout.write("entries=" + t.entries.length + " withProbe=[" + ids.join(",") + "]");
JS
)"
got="$(node -e "$js_table" "$(np "$TABLE")" 2>&1)"
case "$got" in
  "entries=0 "* | "entries= "* | "") fail "real table read" "got [$got]" ;;
  *) assert_eq "real table runtimeProbe keys: ${got#* }" "real table runtimeProbe keys: withProbe=[]" ;;
esac
case_end

case_begin "loaders-expose-no-runtime-probe" "bin/lib/test-language-registry.sh"
# The js loader's launch objects, over the real table copied into the fixture checkout.
js_loader="$(cat <<'JS'
const t = require(process.argv[1]).loadRegistry();
const ids = t.entries.filter((e) => e.launch && Object.prototype.hasOwnProperty.call(e.launch, "runtimeProbe")).map((e) => e.id);
process.stdout.write("loaded=" + t.entries.length + " withProbe=[" + ids.join(",") + "]");
JS
)"
got_js="$(node -e "$js_loader" "$(np "$CO_READER")" 2>&1)"
case "$got_js" in
  "loaded=0 "* | "loaded= "* | "") fail "js loader read" "got [$got_js]" ;;
  *) assert_eq "js loader runtimeProbe: ${got_js#* }" "js loader runtimeProbe: withProbe=[]" ;;
esac
# The sh loader's argv kinds are only prepare and command; the shell dump carries no probe row.
sh_kinds=""
IFS= read -r -d '' sh_kinds <<'SH' || true
tlr_load || exit 96
n=0 i=0 other=""
while [ "$i" -lt "${#_TLR_A_ID[@]}" ]; do
  case "${_TLR_A_KIND[$i]}" in
    prepare | command) ;;
    *) case " $other " in *" ${_TLR_A_KIND[$i]} "*) ;; *) other="${other:+$other }${_TLR_A_KIND[$i]}" ;; esac ;;
  esac
  n=$((n + 1)) i=$((i + 1))
done
printf "argv=%s other=[%s]" "$n" "$other"
SH
got_sh="$(tlr_bash "$CO" "$sh_kinds")"
case "$got_sh" in
  "argv=0 "* | "") fail "sh loader read" "got [$got_sh]" ;;
  *) assert_eq "sh loader argv kinds: ${got_sh#* }" "sh loader argv kinds: other=[]" ;;
esac
cli --format shell
T=$'\t'
probe_rows="$(printf '%s\n' "$CLI_OUT" | grep -ciE "^(arg|field)${T}[^${T}]*${T}(launch\.)?runtimeProbe" || true)"
assert_eq "real table shell rc=$CLI_RC runtimeProbe rows=${probe_rows:-0}" "real table shell rc=0 runtimeProbe rows=0"
case_end

# Real-table facts, read straight from the JSON (the reader is not the oracle here).
case_begin "real-table-launch-entries" "hooks/lib/test-language-registry.json"
got="$(node -e '
const t = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const e = (id) => t.entries.find((x) => x.id === id) || { launch: {} };
const out = [];
out.push("bash.timeout=" + e("bash").launch.timeoutSeconds);
for (const id of ["pester", "pytest", "js"]) {
  const x = e(id), l = x.launch || {};
  out.push(id + ".status=" + x.status);
  out.push(id + ".command=" + JSON.stringify(l.command));
  out.push(id + ".wrapper=" + l.wrapper);
  out.push(id + ".minVersion=" + (l.minVersion ? l.minVersion.runtime + ">=" + l.minVersion.version : "none"));
  out.push(id + ".requires=" + l.requires);
  out.push(id + ".timeout=" + l.timeoutSeconds);
}
process.stdout.write(out.join("\n") + "\n");
' "$(np "$TABLE")" 2>&1)"
for want in "bash.timeout=null" \
  'pester.command=["pwsh","-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File","{wrapper}","-Path","{nativePath}","-MinVersion","{minVersion}"]' \
  "pester.wrapper=bin/lib/test-wrappers/pester.ps1" "pester.minVersion=Pester>=5.0" \
  "pester.requires=pwsh" "pester.timeout=180" \
  'pytest.command=["uv","run","--no-project","--with","pytest>={minVersion}","python","{wrapper}","{nativePath}","{minVersion}"]' \
  "pytest.wrapper=bin/lib/test-wrappers/pytest.py" "pytest.minVersion=pytest>=7.0" \
  "pytest.requires=uv" "pytest.timeout=180" \
  "js.status=supported" 'js.command=["node","{wrapper}","{nativePath}","{minVersion}"]' \
  "js.wrapper=bin/lib/test-wrappers/node.js" "js.requires=node" "js.timeout=180"; do
  has_line "real table: $want" "$got" "$want"
done
case_end

case_begin "shell-dump-wrapper-fields" "bin/lib/test-language-registry.sh"
# The real table through the real CLI: the loader reads these rows via tlr_field.
cli --format shell
assert_eq "real table shell rc=$CLI_RC" "real table shell rc=0"
T=$'\t'
for want in "field${T}pester${T}launch.wrapper${T}bin/lib/test-wrappers/pester.ps1" \
  "field${T}pester${T}launch.minVersion${T}Pester>=5.0" \
  "field${T}js${T}launch.wrapper${T}bin/lib/test-wrappers/node.js" \
  "field${T}pester${T}launch.timeoutSeconds${T}180"; do
  has_line "shell row $(printf '%q' "$want")" "$CLI_OUT" "$want"
done
# The bash entry's timeoutSeconds is null, so the dump carries no row for it.
bash_to_rows="$(printf '%s\n' "$CLI_OUT" | grep -c "^field${T}bash${T}launch.timeoutSeconds${T}" || true)"
assert_eq "bash timeoutSeconds rows=$bash_to_rows" "bash timeoutSeconds rows=0"
# The loader in the fixture checkout (real table + copied wrappers) exposes the same values.
got="$(tlr_bash "$CO" 'tlr_load || exit 96; printf "[%s][%s]" "$(tlr_field pester launch.wrapper)" "$(tlr_field pester launch.minVersion)"')"
assert_eq "tlr_field pester wrapper/minVersion=$got" "tlr_field pester wrapper/minVersion=[bin/lib/test-wrappers/pester.ps1][Pester>=5.0]"
case_end

case_begin "tlr-lang-exceptions" "bin/lib/test-language-registry.sh"
# #2502 S4-6: the allowed test-lang-exception values are one top-level key of the table, a
# shell row of the CLI, and TLR_LANG_EXCEPTIONS in the loader — exactly these three, in order.
got="$(node -e '
const t = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.stdout.write(JSON.stringify(t.testLanguageExceptions === undefined ? null : t.testLanguageExceptions));
' "$(np "$TABLE")" 2>&1)"
assert_eq "table testLanguageExceptions=$got" 'table testLanguageExceptions=["text-only","symmetry","e2e"]'
cli --format shell
has_line "shell row testLanguageExceptions" "$CLI_OUT" "testLanguageExceptions${T}text-only symmetry e2e"
got="$(tlr_bash "$CO" 'tlr_load || exit 96; printf "[%s]" "${TLR_LANG_EXCEPTIONS-unset}"')"
assert_eq "TLR_LANG_EXCEPTIONS=$got" "TLR_LANG_EXCEPTIONS=[text-only symmetry e2e]"
case_end

case_begin "issue-name-prefix-field" "hooks/lib/test-language-registry.js"
# #2502 S5-4c: an entry's issueNamePrefix is a string (checked like nameStrip); anything else fails.
rows accept <<'ROWS'
issue-name-prefix-string|t.entries[0].issueNamePrefix = "test_";
issue-name-prefix-empty|t.entries[0].issueNamePrefix = "";
ROWS
rows reject <<'ROWS'
issue-name-prefix-number|t.entries[0].issueNamePrefix = 5;
issue-name-prefix-array|t.entries[0].issueNamePrefix = ["test_"];
issue-name-prefix-object|t.entries[0].issueNamePrefix = { prefix: "test_" };
ROWS
# The real table: pytest carries "test_", every other entry "".
got="$(node -e '
const t = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.stdout.write(t.entries.map((e) => e.id + "=" + JSON.stringify(e.issueNamePrefix)).join(" "));
' "$(np "$TABLE")" 2>&1)"
for want in 'pytest="test_"' 'bash=""' 'pester=""' 'js=""'; do
  case " $got " in
    *" $want "*) pass "real table issueNamePrefix $want" ;;
    *) fail "real table issueNamePrefix $want" "got [$got]" ;;
  esac
done
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
