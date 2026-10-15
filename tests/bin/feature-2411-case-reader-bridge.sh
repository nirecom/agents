#!/usr/bin/env bash
# tests/bin/feature-2411-case-reader-bridge.sh
# Tests: bin/lib/case-reader-bridge.sh, bin/lib/case-record-reader.sh, bin/lib/test-language-parts/pester.sh, bin/lib/test-language-parts/pytest.sh, bin/lib/test-language-parts/js.sh, bin/check-case-markers.sh
# Tags: TL2, bin, case-markers, test-language-registry, scope:issue-specific
# crb_run turns a reader child's FILE/CASE TSV into the parser globals; the per-language parts
# only choose the command line. Children here are stubs and PATH shims, never a real runtime.
# TL3 gap: the real pwsh / uv / node readers behind the parts run only in their own suites.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

TMPBASE="$(make_tmp)"
readonly TMPBASE
trap 'rm -rf "$TMPBASE"' EXIT
harness_isolate "$TMPBASE/iso"
export HOME="$TMPBASE/home"
mkdir -p "$HOME"
# shellcheck source=test-language-registry/_lib.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/test-language-registry/_lib.sh"
# shellcheck source=../lib/tool-shim-path.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/tool-shim-path.sh"

T=$'\t'
PARTS=bin/lib/test-language-parts
ABSENT=no-such-command-2411
STUB="$TMPBASE/child.sh"
RUNNER="$TMPBASE/run-bridge.sh"
PART_RUNNER="$TMPBASE/run-part.sh"
SHIM="$TMPBASE/shim"
SAMPLE="$TMPBASE/sample.Tests.ps1"
SPACED="$TMPBASE/dir with space/two cases.Tests.ps1"
mkdir -p "$SHIM" "$TMPBASE/dir with space" "$TMPBASE/cwd"
printf 'placeholder\n' | tee "$SAMPLE" >"$SPACED"
touch "$TMPBASE/cwd/f1" "$TMPBASE/cwd/f2"
CONFORMING="FILE\tconforming\t\t\nCASE\t0\talpha\tbin/a.sh\t5\t7\t\t\nCASE\t1\tbeta\tbin/lib/b.ps1\t9\t13\t\t\n"

# The stub child: records its arguments, replays <stub>.out, exits with <stub>.rc.
cat >"$STUB" <<'CHILD'
: >"$0.argv"
for a in "$@"; do printf '%s\n' "$a" >>"$0.argv"; done
printf 'ran\n' >"$0.ran"
[ -f "$0.out" ] && cat "$0.out"
exit "$(cat "$0.rc")"
CHILD

# Both runners start from stale globals, call the unit, then print rc, state and every case.
cat >"$TMPBASE/dump.sh" <<'DUMP'
stale_globals() {
  TRP_CASE_BEGIN_LINES=(1); TRP_CASE_END_LINES=(2); TRP_CASE_NAMES=(stale); TRP_CASE_TARGETS=(bin/stale.sh)
  TRP_CASE_COUNT=1; TRP_HAS_MARKERS=1
  _TRP_MARKER_MALFORMED=1; _TRP_MARKER_MALFORMED_LINE=99; _TRP_MARKER_MALFORMED_REASON=stale; _TRP_MARKER_UNCERTAIN=1
}
dump_globals() {
  local i
  printf 'rc=%s\n' "$1"
  trp_marker_state_from_globals
  printf 'state=%s|%s|%s\n' "$TRP_MARKER_STATE" "$TRP_MARKER_LINE" "$TRP_MARKER_REASON"
  printf 'count=%s|%s|%s|%s|%s\n' "$TRP_CASE_COUNT" "${#TRP_CASE_NAMES[@]}" "${#TRP_CASE_TARGETS[@]}" "${#TRP_CASE_BEGIN_LINES[@]}" "${#TRP_CASE_END_LINES[@]}"
  for ((i = 0; i < ${#TRP_CASE_NAMES[@]}; i++)); do
    printf 'range%s=%s-%s\n' "$i" "${TRP_CASE_BEGIN_LINES[$i]}" "${TRP_CASE_END_LINES[$i]}"
    printf 'name%s=%s\n' "$i" "${TRP_CASE_NAMES[$i]}"
    printf 'target%s=%s\n' "$i" "${TRP_CASE_TARGETS[$i]}"
  done
}
DUMP
cat >"$RUNNER" <<'RUN'
root="$1"; file="$2"; shift 2
. "$root/bin/lib/test-retire-predicate.sh" || exit 97
. "$root/bin/lib/case-reader-bridge.sh" || exit 97
. "${BASH_SOURCE[0]%/*}/dump.sh" || exit 97
stale_globals
crb_run "$file" "$@"
dump_globals "$?"
RUN
cat >"$PART_RUNNER" <<'RUN'
root="$1"; part="$2"; fn="$3"; file="$4"; child_path="$5"
. "$root/bin/lib/test-retire-predicate.sh" || exit 97
. "$root/bin/lib/case-reader-bridge.sh" || exit 97
. "$root/bin/lib/test-language-parts/$part" || exit 97
declare -F "$fn" >/dev/null || exit 96
. "${BASH_SOURCE[0]%/*}/dump.sh" || exit 97
stale_globals
PATH="$child_path"
"$fn" "$file"
dump_globals "$?"
RUN
for tool in pwsh uv node; do
  cat >"$SHIM/$tool" <<'SHIMBODY'
#!/usr/bin/env bash
for a in "$@"; do printf '%s\n' "$a"; done >"$SHIM_ARGV"
cat "$SHIM_OUT"
SHIMBODY
  chmod +x "$SHIM/$tool"
done
export SHIM_ARGV="$TMPBASE/shim.argv" SHIM_OUT="$TMPBASE/shim.out"

# bridge <child-stdout (printf %b)> <child-rc> <file> [extra child args...] — sets BR_OUT.
bridge() {
  local out="$1" rc="$2" file="$3"
  shift 3
  printf '%b' "$out" >"$STUB.out"
  printf '%s\n' "$rc" >"$STUB.rc"
  rm -f "$STUB.argv" "$STUB.ran"
  BR_OUT="$(cd "$TMPBASE/cwd" && run_with_timeout 120 bash "$RUNNER" "$SCRIPT_CHECKOUT_ROOT" "$file" bash "$STUB" "$@" 2>"$TMPBASE/bridge.err")"
}
# br <key> — the value of the runner's <key>= line; `absent` when the runner printed none.
br() {
  local line
  line="$(printf '%s\n' "$BR_OUT" | grep -m1 "^$1=")" || { printf 'absent'; return 0; }
  printf '%s' "${line#*=}"
}

case_begin "bridge-library-present" "bin/lib/case-reader-bridge.sh"
got="$(bash -c '. "$1" || exit 97; declare -F crb_run >/dev/null && echo defined' _ "$SCRIPT_CHECKOUT_ROOT/bin/lib/case-reader-bridge.sh" 2>/dev/null)"
assert_eq "crb_run: ${got:-missing}" "crb_run: defined"
case_end

case_begin "valid-output-fills-globals" "bin/lib/case-reader-bridge.sh"
bridge "$CONFORMING" 0 "$SAMPLE"
assert_eq "rc=$(br rc) state=$(br state) count=$(br count)" "rc=0 state=conforming|| count=2|2|2|2|2"
assert_eq "$(br name0)|$(br target0)|$(br range0)" "alpha|bin/a.sh|5-7"
assert_eq "$(br name1)|$(br target1)|$(br range1)" "beta|bin/lib/b.ps1|9-13"
assert_eq "child argv: $(tr '\n' '|' <"$STUB.argv" 2>/dev/null)" "child argv: $(np "$SAMPLE")|"
case_end

case_begin "non-conforming-states-replace-stale-globals" "bin/lib/case-reader-bridge.sh"
while IFS='|' read -r rname rout rstate rline rreason; do
  [ -n "$rname" ] || continue
  bridge "$rout" 0 "$SAMPLE"
  assert_eq "$rname: rc=$(br rc) state=$(br state) count=$(br count)" "$rname: rc=0 state=$rstate|$rline|$rreason count=0|0|0|0|0"
done <<'ROWS'
none|FILE\tnone\t\t\n|none||
malformed-target|FILE\tmalformed\t4\ttarget\n|malformed|4|target
malformed-grammar|FILE\tmalformed\t3\tgrammar\n|malformed|3|grammar
malformed-balance|FILE\tmalformed\t12\tbalance\n|malformed|12|balance
malformed-constant|FILE\tmalformed\t5\tconstant\n|malformed|5|constant
malformed-missing-target|FILE\tmalformed\t6\tmissing-target\n|malformed|6|missing-target
malformed-duplicate-target|FILE\tmalformed\t7\tduplicate-target\n|malformed|7|duplicate-target
malformed-nested-target|FILE\tmalformed\t8\tnested-target\n|malformed|8|nested-target
uncertain|FILE\tuncertain\t5\tdepth\n|uncertain|5|depth
ROWS
case_end

case_begin "absent-command-is-79" "bin/lib/case-reader-bridge.sh"
rm -f "$STUB.ran"
BR_OUT="$(run_with_timeout 120 bash "$RUNNER" "$SCRIPT_CHECKOUT_ROOT" "$SAMPLE" "$ABSENT" "$STUB" 2>"$TMPBASE/bridge.err")"
assert_eq "rc=$(br rc) child ran=$([ -e "$STUB.ran" ] && echo yes || echo no)" "rc=79 child ran=no"
case_end

case_begin "broken-child-output-is-nonzero-and-not-79" "bin/lib/case-reader-bridge.sh"
while IFS='|' read -r rname rrc rout; do
  [ -n "$rname" ] || continue
  bridge "$rout" "$rrc" "$SAMPLE"
  got="$(br rc)"
  case "$got" in
    absent | 0 | 79 | *[!0-9]*) fail "$rname" "crb_run rc=$got, want non-zero other than 79" ;;
    *) pass "$rname: crb_run rc=$got" ;;
  esac
  assert_eq "$rname: child ran=$(cat "$STUB.ran" 2>/dev/null)" "$rname: child ran=ran"
done <<'ROWS'
child-exit-1|1|FILE\tconforming\t\t\nCASE\t0\talpha\tbin/a.sh\t5\t7\t\t\n
child-exit-79|79|FILE\tconforming\t\t\nCASE\t0\talpha\tbin/a.sh\t5\t7\t\t\n
child-exit-2-no-output|2|
empty-output|0|
no-file-line|0|CASE\t0\talpha\tbin/a.sh\t5\t7\t\t\n
file-3-columns|0|FILE\tnone\t\n
file-5-columns|0|FILE\tnone\t\t\t\n
case-7-columns|0|FILE\tconforming\t\t\nCASE\t0\talpha\tbin/a.sh\t5\t7\t\n
case-9-columns|0|FILE\tconforming\t\t\nCASE\t0\talpha\tbin/a.sh\t5\t7\t\t\t\n
state-unknown|0|FILE\tweird\t\t\n
state-unsupported|0|FILE\tunsupported\t\t\n
state-unavailable|0|FILE\tunavailable\t\tpwsh\n
state-uppercase|0|FILE\tNONE\t\t\n
duplicate-file-line|0|FILE\tnone\t\t\nFILE\tnone\t\t\n
duplicate-file-line-around-cases|0|FILE\tconforming\t\t\nCASE\t0\talpha\tbin/a.sh\t5\t7\t\t\nFILE\tconforming\t\t\n
conforming-zero-cases|0|FILE\tconforming\t\t\n
case-empty-name|0|FILE\tconforming\t\t\nCASE\t0\t\tbin/a.sh\t5\t7\t\t\n
case-empty-target|0|FILE\tconforming\t\t\nCASE\t0\talpha\t\t5\t7\t\t\n
ROWS
case_end

case_begin "path-with-space-reaches-the-child-as-one-argument" "bin/lib/case-reader-bridge.sh"
bridge "$CONFORMING" 0 "$SPACED" --flag "two words"
assert_eq "rc=$(br rc) state=$(br state)" "rc=0 state=conforming||"
assert_eq "child argv: $(tr '\n' '|' <"$STUB.argv" 2>/dev/null)" "child argv: --flag|two words|$(np "$SPACED")|"
case_end

case_begin "odd-characters-are-data-not-code" "bin/lib/case-reader-bridge.sh"
ODD_NAMES=('$(touch pwned-1)' '`touch pwned-2`' 'a; touch pwned-3' '*' 'two  spaces' '"dq" and '\''sq'\''' '-n' '%s%d' 'back\slash\n' '${HOME}' '[f]?' ' lead')
ODD_TARGETS=('bin/$(touch pwned-4).sh' '*' 'bin/a b.sh' 'bin/`touch pwned-5`' 'bin/a;touch pwned-6' 'bin/"q".sh' '-e' 'bin/%s' 'bin\a.sh' '~/x' 'f?' 'bin/&&x')
printf 'FILE\tconforming\t\t\n' >"$TMPBASE/odd.out"
for i in "${!ODD_NAMES[@]}"; do
  printf '%s\n' "CASE$T$i$T${ODD_NAMES[$i]}$T${ODD_TARGETS[$i]}$T$((i + 1))$T$((i + 2))$T$T" >>"$TMPBASE/odd.out"
done
cp "$TMPBASE/odd.out" "$STUB.out"
printf '0\n' >"$STUB.rc"
BR_OUT="$(cd "$TMPBASE/cwd" && run_with_timeout 120 bash "$RUNNER" "$SCRIPT_CHECKOUT_ROOT" "$SAMPLE" bash "$STUB" 2>"$TMPBASE/bridge.err")"
assert_eq "rc=$(br rc) state=$(br state) count=$(br count | cut -d'|' -f1)" "rc=0 state=conforming|| count=${#ODD_NAMES[@]}"
for i in "${!ODD_NAMES[@]}"; do
  assert_eq "$i: $(br "name$i")" "$i: ${ODD_NAMES[$i]}"
  assert_eq "$i: $(br "target$i")" "$i: ${ODD_TARGETS[$i]}"
done
assert_eq "cwd entries: $(ls -A "$TMPBASE/cwd" | tr '\n' ' ')" "cwd entries: f1 f2 "
case_end

# part <part-file> <function> <file> <PATH for the part> — sets BR_OUT; the shim replays $CONFORMING.
part() {
  printf '%b' "$CONFORMING" >"$SHIM_OUT"
  rm -f "$SHIM_ARGV"
  BR_OUT="$(run_with_timeout 120 bash "$PART_RUNNER" "$SCRIPT_CHECKOUT_ROOT" "$1" "$2" "$3" "$4" 2>"$TMPBASE/part.err")"
}
# part_checks <tool> <part-file> <function> <reader-file> <argv before the reader path, |-joined>
# Both runs are on tool wrappers without <tool>; the first puts the $SHIM stub in front of them.
part_checks() {
  local tool="$1" pfile="$2" fn="$3" reader="$4" lead="$5" argv n reader_arg file_arg no_tool
  if ! no_tool="$(tsp_base_path "$TMPBASE/shim-no-$tool" "$tool" 2>"$TMPBASE/shim-no-$tool.err")"; then
    fail "$fn: PATH without $tool" "$(cat "$TMPBASE/shim-no-$tool.err")"
    return 0
  fi
  part "$pfile" "$fn" "$SPACED" "$SHIM:$no_tool"
  assert_eq "$fn: rc=$(br rc) state=$(br state) count=$(br count | cut -d'|' -f1)" "$fn: rc=0 state=conforming|| count=2"
  assert_eq "$fn: $(br name1)|$(br target1)|$(br range1)" "$fn: beta|bin/lib/b.ps1|9-13"
  argv="$(tr '\\' '/' <"$SHIM_ARGV" 2>/dev/null)"
  n="$(printf '%s\n' "$argv" | grep -c .)"
  file_arg="$(printf '%s\n' "$argv" | sed -n "${n}p" 2>/dev/null)"
  reader_arg="$(printf '%s\n' "$argv" | sed -n "$((n - 1))p" 2>/dev/null)"
  assert_eq "$tool argv before the reader: $(printf '%s\n' "$argv" | head -n "$((n > 2 ? n - 2 : 0))" | tr '\n' '|')" "$tool argv before the reader: $lead"
  case "$reader_arg" in
    */"$PARTS/$reader" | "$PARTS/$reader") pass "$tool reader argument names $PARTS/$reader" ;;
    *) fail "$tool reader argument" "want a path ending in $PARTS/$reader, got [$reader_arg]" ;;
  esac
  assert_eq "$tool file argument: $file_arg" "$tool file argument: $(np "$SPACED")"
  part "$pfile" "$fn" "$SPACED" "$no_tool"
  assert_eq "$fn without $tool: rc=$(br rc)" "$fn without $tool: rc=79"
  assert_eq "$fn without $tool: shim not run: $([ -e "$SHIM_ARGV" ] && echo ran || echo no)" "$fn without $tool: shim not run: no"
}

case_begin "pester-part-launches-pwsh-with-the-reader" "bin/lib/test-language-parts/pester.sh"
part_checks pwsh pester.sh pester_case_markers pester-case-reader.ps1 "-NoProfile|-NonInteractive|-File|"
case_end

case_begin "pytest-part-launches-uv-python-with-the-reader" "bin/lib/test-language-parts/pytest.sh"
part_checks uv pytest.sh pytest_case_markers pytest-case-reader.py "run|--no-project|python|"
case_end

case_begin "js-part-launches-node-with-the-reader" "bin/lib/test-language-parts/js.sh"
part_checks node js.sh js_case_markers js-case-reader.js ""
case_end

# Fixture checkout: the pester entry's reader part is a stub that calls the real crb_run with
# the command named by $BRIDGE_STUB_CMD, so crr_read is seen end to end without a real runtime.
CO="$TMPBASE/co"
fx_table_edit "$SCRIPT_CHECKOUT_ROOT/hooks/lib/test-language-registry.json" "$TMPBASE/bridge-stub.json" \
  't.entries.find((e) => e.id === "pester").caseMarkerReader = { file: "bin/lib/test-language-parts/bridge-stub.sh", function: "bridge_stub_markers" };'
fx_checkout "$CO" "$TMPBASE/bridge-stub.json"
cat >"$CO/$PARTS/bridge-stub.sh" <<'PART'
declare -F crb_run >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../case-reader-bridge.sh"
bridge_stub_markers() { crb_run "$1" "$BRIDGE_STUB_CMD" "$BRIDGE_STUB_ARG"; }
PART
export BRIDGE_STUB_ARG="$STUB"
REQUIRES="$(tlr_bash "$CO" 'tlr_load || exit 96; tlr_field pester launch.requires')"

# crr <child-stdout (printf %b)> <child-rc> <command> — crr_read on $SPACED in the fixture checkout; sets CRR_OUT.
crr() {
  printf '%b' "$1" >"$STUB.out"
  printf '%s\n' "$2" >"$STUB.rc"
  export BRIDGE_STUB_CMD="$3"
  CRR_OUT="$(run_with_timeout 120 bash -c '. "$1/bin/lib/case-record-reader.sh" || exit 97; crr_read "$2"; printf "rc=%s cases=%s\n" "$?" "${#TRP_CASE_NAMES[@]}"' _ "$CO" "$SPACED" 2>"$TMPBASE/crr.err")"
}

case_begin "record-reader-reports-a-bridged-reader" "bin/lib/case-record-reader.sh"
crr "$CONFORMING" 0 bash
assert_eq "$CRR_OUT" "FILE${T}conforming${T}${T}
CASE${T}0${T}alpha${T}bin/a.sh${T}5${T}7${T}?${T}
CASE${T}1${T}beta${T}bin/lib/b.ps1${T}9${T}13${T}?${T}
rc=0 cases=2"
crr 'FILE\tmalformed\t4\tmissing-target\n' 0 bash
assert_eq "$CRR_OUT" "FILE${T}malformed${T}4${T}missing-target
rc=0 cases=0"
case_end

case_begin "record-reader-absent-runtime-is-unavailable" "bin/lib/case-record-reader.sh"
crr "$CONFORMING" 0 "$ABSENT"
assert_eq "requires=$REQUIRES" "requires=pwsh"
assert_eq "$CRR_OUT" "FILE${T}unavailable${T}${T}$REQUIRES
rc=0 cases=0"
case_end

case_begin "record-reader-broken-child-stays-malformed-reader" "bin/lib/case-record-reader.sh"
while IFS='|' read -r rname rrc rout; do
  [ -n "$rname" ] || continue
  crr "$rout" "$rrc" bash
  assert_eq "$rname: $CRR_OUT" "$rname: FILE${T}malformed${T}${T}reader
rc=0 cases=0"
done <<'ROWS'
child-exit-1|1|FILE\tconforming\t\t\nCASE\t0\talpha\tbin/a.sh\t5\t7\t\t\n
child-exit-79|79|FILE\tnone\t\t\n
no-file-line|0|CASE\t0\talpha\tbin/a.sh\t5\t7\t\t\n
state-unknown|0|FILE\tweird\t\t\n
conforming-zero-cases|0|FILE\tconforming\t\t\n
case-empty-name|0|FILE\tconforming\t\t\nCASE\t0\t\tbin/a.sh\t5\t7\t\t\n
case-empty-target|0|FILE\tconforming\t\t\nCASE\t0\talpha\t\t5\t7\t\t\n
ROWS
case_end

# The checker (the verdict both gates read) on the same rejected reader output: a reader
# failure, never a silent conforming pass.
cp "$SCRIPT_CHECKOUT_ROOT/bin/check-case-markers.sh" "$CO/bin/check-case-markers.sh"
TWO_PATHS="$TMPBASE/two-paths.Tests.ps1"
printf '# Tests: bin/a.sh, bin/lib/b.ps1\n# Tags: scope:common\n' >"$TWO_PATHS"
case_begin "checker-rejected-reader-output-is-a-reader-failure" "bin/check-case-markers.sh"
while IFS='|' read -r rname rout; do
  [ -n "$rname" ] || continue
  printf '%b' "$rout" >"$STUB.out"
  printf '0\n' >"$STUB.rc"
  export BRIDGE_STUB_CMD=bash
  CK_OUT="$(run_with_timeout 120 bash "$CO/bin/check-case-markers.sh" "$TWO_PATHS" 2>"$TMPBASE/ck.err")"
  CK_RC=$?
  assert_eq "$rname: rc=$CK_RC stdout=$CK_OUT" "$rname: rc=2 stdout="
  case "$(cat "$TMPBASE/ck.err")" in
    *"case-marker reader unavailable: $TWO_PATHS"*) pass "$rname: stderr names the reader failure" ;;
    *) fail "$rname stderr" "$(cat "$TMPBASE/ck.err")" ;;
  esac
done <<'ROWS'
conforming-zero-cases|FILE\tconforming\t\t\n
case-empty-name|FILE\tconforming\t\t\nCASE\t0\t\tbin/a.sh\t5\t7\t\t\n
case-empty-target|FILE\tconforming\t\t\nCASE\t0\talpha\t\t5\t7\t\t\n
ROWS
printf '%b' "$CONFORMING" >"$STUB.out"
CK_OUT="$(run_with_timeout 120 bash "$CO/bin/check-case-markers.sh" "$TWO_PATHS" 2>"$TMPBASE/ck.err")"
assert_eq "well-formed: rc=$? stdout=$CK_OUT" "well-formed: rc=0 stdout="
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
