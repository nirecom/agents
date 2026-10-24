# Shared helpers for tests/bin/feature-2502-case-embed-order.sh and its parts (deps.sh,
# cache.sh). Sourced after the dispatcher's setup (harness, TMPBASE, harness_isolate,
# test-language-registry/_lib.sh).
# shellcheck shell=bash

CASES_DIR="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2502-case-embed-order"
FXD="$TMPBASE/fx"
mkdir -p "$FXD"
PARTS=bin/lib/test-language-parts

# shellcheck source=fixtures.sh
. "$CASES_DIR/fixtures.sh"

# lang_info <id> — L_RT (runtime command), L_REL (sample path), L_ANALYZER (analyzer file),
# L_STUB (its order-mismatch stub), L_B0/L_E0 (case 0's range) and the roles A/B/V/U the
# fixtures header describes.
lang_info() {
  case "$1" in
    pester) L_RT=pwsh L_REL=tests/bin/sample.Tests.ps1 L_ANALYZER=pester-case-analyzer.ps1 L_STUB=stub-analyzer.ps1 L_HELPER=tests/lib/harness.ps1
      L_B0=12 L_E0=16 L_A=Get-Alpha L_B=Get-Beta L_V=Shared L_U=Get-Unused ;;
    pytest) L_RT=uv L_REL=tests/bin/test_sample.py L_ANALYZER=pytest-case-analyzer.py L_STUB=stub-analyzer.py L_HELPER=tests/lib/harness.py
      L_B0=25 L_E0=27 L_A=helper_alpha L_B=beta_value L_V=LIMIT L_U=helper_unused ;;
    js) L_RT=node L_REL=tests/bin/sample.js L_ANALYZER=js-case-analyzer.js L_STUB=stub-analyzer.js L_HELPER=tests/lib/harness.js
      L_B0=17 L_E0=21 L_A=helperAlpha L_B=factor L_V=LIMIT L_U=helperUnused ;;
  esac
}

# embed_checkout <dir> — a fixture checkout on the real registry table, with every language's
# helper library and the three samples under tests/bin/.
embed_checkout() {
  local d="$1" f
  fx_checkout "$d"
  for f in harness.ps1 harness.py harness.js; do cp "$SCRIPT_CHECKOUT_ROOT/tests/lib/$f" "$d/tests/lib/$f"; done
  cp "$FXD/sample.Tests.ps1" "$FXD/test_sample.py" "$FXD/sample.js" "$d/tests/bin/"
}

# batch <checkout> <file> <path-for-ops> <id> <op-spec>... — ONE shell: crr_read <file>, then
# with PATH=<path-for-ops> ("-" keeps PATH; the registry is already loaded, so a PATH without
# node still reaches the part) each op-spec "op [arg...]" as `tlr_call_part <id>
# caseEmbedRules op arg...`. In a spec the word FILE stands for <file>. Each step prints "@@ <spec> rc=<n>" and then its stdout; its
# stderr is kept as $TMPBASE/b.<step-no>.err (step 0 is crr_read).
batch() {
  run_with_timeout 120 bash -c '. "$1/bin/lib/case-record-reader.sh" || exit 97
t="$2" f="$3" p="$4" id="$5"; shift 5
r=0; out="$(crr_read "$f" 2>"$t/b.0.err")" || r=$?
printf "@@ crr rc=%s\n%s\n" "$r" "$out"
[ "$p" = - ] || PATH="$p"
n=0
for spec in "$@"; do
  n=$((n + 1)) a=()
  for w in $spec; do
    [ "$w" = FILE ] && w="$f"
    a+=("$w")
  done
  r=0; out="$(tlr_call_part "$id" caseEmbedRules "${a[@]}" 2>"$t/b.$n.err")" || r=$?
  printf "@@ %s rc=%s\n%s\n" "$spec" "$r" "$out"
done' _ "$1" "$TMPBASE" "$2" "$3" "$4" "${@:5}"
}

# sect <batch-output> <spec> — the stdout lines of that step. sect_rc — its rc.
sect() {
  printf '%s\n' "$1" | awk -v h="@@ $2 rc=" 'index($0, "@@ ") == 1 { s = (index($0, h) == 1); next } s && NF'
}
sect_rc() {
  printf '%s\n' "$1" | awk -v h="@@ $2 rc=" 'index($0, h) == 1 { print substr($0, length(h) + 1); exit }'
}

# deps_of <crr-lines> <idx> — the deps column of the idx-th CASE line ("<none>" when absent).
deps_of() {
  printf '%s\n' "$1" | awk -F'\t' -v n="$2" '$1 == "CASE" { if (i++ == n) { print $6; f = 1; exit } } END { if (!f) print "<none>" }'
}

# file_line <crr-lines> — "verdict|reason|detail" of the FILE line.
file_line() {
  printf '%s\n' "$1" | awk -F'\t' '$1 == "FILE" { print $2 "|" $3 "|" $4 }'
}

# csv_has <csv> <name> — rc 0 when <name> is one item (a leading `$` on an item is ignored).
csv_has() {
  local item IFS=,
  for item in $1; do [ "${item#\$}" = "$2" ] && return 0; done
  return 1
}

# expect_deps <label> <csv> <want-names> <unwanted-names> — names are space-separated.
expect_deps() {
  local n
  for n in $3; do
    if csv_has "$2" "$n"; then pass "$1: has $n"; else fail "$1: has $n" "deps=[$2]"; fi
  done
  for n in $4; do
    if csv_has "$2" "$n"; then fail "$1: lacks $n" "deps=[$2]"; else pass "$1: lacks $n"; fi
  done
}

# need_rt <id> — rc 0 when the language's runtime is on PATH; a SKIP line otherwise.
need_rt() {
  lang_info "$1"
  command -v "$L_RT" >/dev/null 2>&1 && return 0
  skip "$1: $L_RT not available"
  return 1
}
