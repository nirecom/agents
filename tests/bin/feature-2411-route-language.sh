#!/usr/bin/env bash
# tests/bin/feature-2411-route-language.sh
# Tests: bin/find-tests-for-source.sh, bin/lib/test-route-destination.sh, bin/lib/test-route-destination/language.sh
# Tags: TL2, bin, test-route, test-language-registry, scope:issue-specific
# Issue #2411: a source maps to the language of its tests, and an append destination is
# offered only among tests written in a language of the query. pin-* cases hold today's
# rows; the other cases need --with-language and the language filter.
# TL3 gap: /write-tests and /review-tests reading the two new columns in a live run
# (mitigation: tests/bin/feature-2075-append-destination.sh skill-wiring cases).
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMPBASE="$(make_tmp)"
readonly TMPBASE
trap 'rm -rf "$TMPBASE"' EXIT
harness_isolate "$TMPBASE/iso"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPBASE/transcripts"
export RUN_ALL_CACHE_DIR="$TMPBASE/run-all-cache"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR"
unset CLAUDE_CODE_SESSION_ID GIT_DIR GIT_WORK_TREE TEST_LANES_HELD TEST_LANES FIND_TESTS_CORPUS_CACHE \
  TEST_LANES_TTL TEST_LANES_HEARTBEAT TEST_LANES_WAIT_INTERVAL TEST_LANES_WAIT_CAP \
  TEST_MAX_JOBS_PER_HOST RUN_ALL_LANES_LIB

HELPER="$SCRIPT_CHECKOUT_ROOT/bin/find-tests-for-source.sh"
# shellcheck source=../../bin/lib/test-dup-group.sh
. "$SCRIPT_CHECKOUT_ROOT/bin/lib/test-dup-group.sh"

NEUTRAL_CWD="$TMPBASE/neutral"
REPO="$TMPBASE/repo"
mkdir -p "$NEUTRAL_CWD"
harness_git_init "$REPO"
mkdir -p "$REPO/tests/bin" "$REPO/src" "$REPO/bin" "$REPO/docs"
T="tests/bin"

# mk <name-under-tests/bin> <tests-csv> — a test file in the language its name says.
mk() {
  case "$1" in
    *.js) printf '// Tests: %s\n// Tags: scope:common\nconsole.log("fixture");\n' "$2" > "$REPO/$T/$1" ;;
    *.sh) printf '#!/usr/bin/env bash\n# Tests: %s\n# Tags: scope:common\necho fixture\n' "$2" > "$REPO/$T/$1" ;;
    *) printf '# Tests: %s\n# Tags: scope:common\n# fixture\n' "$2" > "$REPO/$T/$1" ;;
  esac
}

for _f in src/b.sh src/extra.sh src/one.js src/two.js src/m.sh src/m.js src/p.sh src/p.js src/x.js \
  src/a.sh src/a.ps1 src/a.psm1 src/a.py src/a.js src/r.ps1 src/rm.sh src/rm.ps1 src/pa.py src/pb.py src/pc.py \
  docs/u.md docs/v.md docs/x.md docs/r.md; do
  printf 'fixture\n' > "$REPO/$_f"
done
printf '#!/usr/bin/env bash\necho tool\n' > "$REPO/bin/tool"
printf '#!/bin/sh\necho tool\n' > "$REPO/bin/tool-sh"

# Extensionless sources told apart by line 1 alone: "<file>|<line 1>|<language set>". Each
# interpreter appears through env and by its own path, then after an env option or an env
# assignment; the last rows name no known one.
SHEBANG_ROWS=(
  'bin/she-bash-path|#!/bin/bash|bash'
  'bin/she-sh-env|#!/usr/bin/env sh|bash'
  'bin/she-python-env|#!/usr/bin/env python3|pytest'
  'bin/she-python-path|#!/usr/bin/python3|pytest'
  'bin/she-pwsh-env|#!/usr/bin/env pwsh|pester'
  'bin/she-pwsh-path|#!/usr/bin/pwsh|pester'
  'bin/she-node-env|#!/usr/bin/env node|js'
  'bin/she-node-path|#!/usr/bin/node|js'
  'bin/she-python-env-opts|#!/usr/bin/env -S python3 -I|pytest'
  'bin/she-node-env-assign|#!/usr/bin/env FOO=1 node|js'
  'bin/she-ruby-env|#!/usr/bin/env ruby|unsupported'
  'bin/she-perl-path|#!/usr/bin/perl|unsupported'
  'bin/she-none|echo no interpreter line|unsupported'
)
for _row in "${SHEBANG_ROWS[@]}"; do
  IFS='|' read -r _f _line _lang <<< "$_row"
  printf '%s\necho tool\n' "$_line" > "$REPO/$_f"
done

mk b1.sh "src/b.sh"
mk b2.sh "src/b.sh, src/extra.sh"
mk b.js "src/b.sh"
mk b.Tests.ps1 "src/b.sh"
mk test_b.py "src/b.sh"
mk doc.sh "docs/u.md"
mk doc2.sh "docs/u.md"
mk single_js.sh "src/one.js"
mk single_js.js "src/one.js"
mk only_bash.sh "src/two.js"
mk only_bash2.sh "src/two.js"
mk multi.sh "src/m.sh, src/m.js"
mk multi.js "src/m.sh, src/m.js"
mk multi.Tests.ps1 "src/m.sh, src/m.js"
mk ponly.Tests.ps1 "src/p.sh, src/p.js"
mk ponly2.Tests.ps1 "src/p.sh, src/p.js"
mk docv.sh "docs/v.md"
mk docv.js "docs/v.md"
mk mix.sh "src/x.js, docs/x.md"
mk mix.js "src/x.js, docs/x.md"
mk rt.Tests.ps1 "src/r.ps1"
mk rt-probe.sh "src/r.ps1"
mk rtm.sh "src/rm.sh, src/rm.ps1"
mk rtm2.sh "src/rm.sh, src/rm.ps1"
mk rtm.Tests.ps1 "src/rm.sh, src/rm.ps1"
mk rtd.sh "docs/r.md"
mk rtd2.sh "docs/r.md"
mk rtd.Tests.ps1 "docs/r.md"
# Python sources with pytest and bash tests side by side; pc.py has bash tests only.
mk test_pa.py "src/pa.py"
mk test_pa2.py "src/pa.py"
mk pa.sh "src/pa.py"
mk pa2.sh "src/pa.py"
mk test_pb.py "src/pb.py"
mk pb.sh "src/pb.py"
mk pb2.sh "src/pb.py"
mk pc.sh "src/pc.py"
mk pc2.sh "src/pc.py"

# One source per row, with the language set it maps to (registry ids, registry order).
MAP_SRC=(src/a.sh src/a.ps1 src/a.psm1 src/a.py src/a.js bin/tool bin/tool-sh bin/ghost)
MAP_LANG=(bash pester pester pytest js bash bash unsupported)
MAP_NOTE=("" "" "" "" "" " (#!/usr/bin/env bash)" " (#!/bin/sh)" " (no such file)")
for _row in "${SHEBANG_ROWS[@]}"; do
  IFS='|' read -r _f _line _lang <<< "$_row"
  MAP_SRC+=("$_f")
  MAP_LANG+=("$_lang")
  MAP_NOTE+=(" ($_line)")
done
for _i in "${!MAP_SRC[@]}"; do
  mk "lang-$_i.sh" "${MAP_SRC[$_i]}"
done

# Queries for the new file name shape: each language alone, then several at once, the last
# two given out of registry order. shape-<i>.sh is the test file form of SHAPE_Q[i].
SHAPE_Q=(src/a.sh src/a.ps1 src/a.py src/a.js "src/a.sh,src/a.ps1" "src/a.py,src/a.js"
  "src/a.js,src/a.sh" "src/a.js,src/a.py,src/a.ps1,src/a.sh")
SHAPE_LANG=(bash pester pytest js "bash,pester" "pytest,js" "bash,js" "bash,pester,pytest,js")
SHAPE_TF=()
for _i in "${!SHAPE_Q[@]}"; do
  mk "shape-$_i.sh" "${SHAPE_Q[$_i]//,/, }"
  SHAPE_TF+=("$T/shape-$_i.sh")
done

SRC_Q=(src/b.sh docs/u.md src/one.js src/two.js "src/m.sh,src/m.js" "src/p.sh,src/p.js" docs/v.md
  "src/x.js,docs/x.md" "src/a.sh,src/a.py" src/r.ps1 docs/r.md "${MAP_SRC[@]}")
SRC_LANG=(bash unsupported js js "bash,js" "bash,js" unsupported js "bash,pytest" pester unsupported "${MAP_LANG[@]}")
TF_Q=("$T/b1.sh" "$T/doc.sh" "$T/single_js.sh" "$T/single_js.js" "$T/only_bash.sh" "$T/multi.Tests.ps1"
  "$T/multi.sh" "$T/ponly.Tests.ps1" "$T/docv.sh" "$T/mix.sh")
TF_LANG=(bash unsupported js js js "bash,js" "bash,js" "bash,js" unsupported js "${MAP_LANG[@]}")
for _i in "${!MAP_SRC[@]}"; do
  TF_Q+=("$T/lang-$_i.sh")
done
MAP_AT_SRC=11
MAP_AT_TF=10
RT_SRC_Q=(src/r.ps1 "src/rm.sh,src/rm.ps1" docs/r.md)
RT_TF_Q=("$T/rt-probe.sh" "$T/rtm.sh" "$T/rtd.sh")

# run_q <flag> <query>... — one helper run. Sets Q_RC Q_OUT Q_ERR. Q_PATH replaces PATH;
# Q_WITH=1 adds --with-language.
Q_RC=0; Q_OUT=""; Q_ERR=""; Q_PATH=""; Q_WITH=0
run_q() {
  local flag="$1" q
  shift
  local -a args=(--root "$REPO")
  for q in "$@"; do args+=("$flag" "$q"); done
  [ "$Q_WITH" = 1 ] && args+=(--with-language)
  Q_RC=0
  (
    cd "$NEUTRAL_CWD" || exit 99
    [ -n "$Q_PATH" ] && PATH="$Q_PATH"
    bash "$RWT" 100 bash "$HELPER" "${args[@]}"
  ) >"$TMPBASE/q.out" 2>"$TMPBASE/q.err" || Q_RC=$?
  Q_OUT="$(cat "$TMPBASE/q.out")"
  Q_ERR="$(cat "$TMPBASE/q.err")"
}

# shellcheck source=../lib/tool-shim-path.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/tool-shim-path.sh"
# BASE_PATH: tool wrappers and no pwsh / uv, whatever the host has. A runtime is "present" through
# a stub dir in front of it: launch.requires is only a command -v check, the stub never runs.
BASE_PATH="$(tsp_base_path "$TMPBASE/shim-base" pwsh uv 2>"$TMPBASE/shim-base.err")" || BASE_PATH=""
BASE_PATH_ERR="$(cat "$TMPBASE/shim-base.err")"

# stub_dir <dir> <tool> — <dir> holding a <tool> that exits 0; prints <dir>.
stub_dir() {
  mkdir -p "$1"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$1/$2"
  chmod +x "$1/$2"
  printf '%s' "$1"
}

# row <output> <zero-based index> / col <row> <n>
row() { printf '%s\n' "$1" | sed -n "$(($2 + 1))p"; }
col() { printf '%s\n' "$1" | cut -f "$2"; }

# files_of <list column> — the file paths of columns 6-8, sorted, comma-joined; `-` when empty.
files_of() {
  local colv="$1" e
  local -a outer=() inner=() res=()
  if [ -z "$colv" ] || [ "$colv" = "-" ]; then printf '%s' "$colv"; return 0; fi
  tdg_split_escaped_csv "$colv" outer 2>/dev/null
  for e in "${outer[@]}"; do
    inner=()
    tdg_split_escaped_csv "$e" inner 2>/dev/null
    res+=("${inner[0]}")
  done
  printf '%s\n' "${res[@]}" | LC_ALL=C sort | paste -sd, -
}

# expect <label> <row> <verdict> <reason> <files> — <files> is the sorted candidate set; the
# viable column must equal it, the excluded column must be empty, the target must be in it.
expect() {
  local r="$2" target
  assert_eq "$1 -> $(col "$r" 2)/$(col "$r" 3)" "$1 -> $3/$4"
  assert_eq "$1 candidates=$(files_of "$(col "$r" 6)")" "$1 candidates=$5"
  assert_eq "$1 viable=$(files_of "$(col "$r" 7)")" "$1 viable=$5"
  assert_eq "$1 excluded=$(col "$r" 8)" "$1 excluded=-"
  target="$(col "$r" 4)"
  case ",$5," in
    ",-,") assert_eq "$1 target=$target" "$1 target=-" ;;
    *",$target,"*) pass "$1: target $target is a candidate" ;;
    *) fail "$1 target" "[$target] is not one of [$5]" ;;
  esac
}

run_q --sources "${SRC_Q[@]}"; N_SRC="$Q_OUT"; N_SRC_RC="$Q_RC"; N_SRC_ERR="$Q_ERR"
run_q --test-file "${TF_Q[@]}"; N_TF="$Q_OUT"; N_TF_RC="$Q_RC"; N_TF_ERR="$Q_ERR"
Q_WITH=1
run_q --sources "${SRC_Q[@]}"; F_SRC="$Q_OUT"; F_SRC_RC="$Q_RC"
run_q --test-file "${TF_Q[@]}"; F_TF="$Q_OUT"; F_TF_RC="$Q_RC"
Q_WITH=0
PWSH_STUB_DIR="$(stub_dir "$TMPBASE/pwsh-stub" pwsh)"
RP_SRC=""; RP_RC=""; R_SRC=""; R_TF=""; R_RC=""; R_ERR=""; R_RAN=0
if [ -n "$BASE_PATH" ]; then
  Q_PATH="$PWSH_STUB_DIR:$BASE_PATH"
  run_q --sources "${RT_SRC_Q[@]}"; RP_SRC="$Q_OUT"; RP_RC="$Q_RC/$Q_ERR"
  Q_PATH="$BASE_PATH"
  run_q --sources "${RT_SRC_Q[@]}"; R_SRC="$Q_OUT"; R_RC="$Q_RC"; R_ERR="$Q_ERR"
  run_q --test-file "${RT_TF_Q[@]}"; R_TF="$Q_OUT"; R_RC="$R_RC/$Q_RC"; R_ERR="$R_ERR$Q_ERR"
  Q_PATH=""
  R_RAN=1
fi

case_begin "pin-no-flag-run-has-eight-columns" "bin/find-tests-for-source.sh"
assert_eq "--sources rc=$N_SRC_RC err=$N_SRC_ERR" "--sources rc=0 err="
assert_eq "--test-file rc=$N_TF_RC err=$N_TF_ERR" "--test-file rc=0 err="
assert_eq "--sources rows=$(printf '%s\n' "$N_SRC" | grep -c .)" "--sources rows=${#SRC_Q[@]}"
assert_eq "--test-file rows=$(printf '%s\n' "$N_TF" | grep -c .)" "--test-file rows=${#TF_Q[@]}"
assert_eq "field counts=$(printf '%s\n%s\n' "$N_SRC" "$N_TF" | awk -F'\t' '{print NF}' | sort -u | paste -sd, -)" "field counts=8"
case_end

CASE_DIR="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2411-route-language"
# shellcheck source=feature-2411-route-language/pin.sh
. "$CASE_DIR/pin.sh"
# shellcheck source=feature-2411-route-language/filter.sh
. "$CASE_DIR/filter.sh"
# shellcheck source=feature-2411-route-language/columns.sh
. "$CASE_DIR/columns.sh"
# shellcheck source=feature-2411-route-language/shapes.sh
. "$CASE_DIR/shapes.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
