#!/usr/bin/env bash
# tests/bin/feature-2502-self-impl-window.sh
# Tests: bin/lib/test-self-impl-window.sh
# Tags: TL2, bin, test-language-registry, sweep-tests, pester, pytest, js, scope:issue-specific
# The shared window `tsi_report <file> [<match-path>]` over the caseEmbedRules self-impl op of
# the four languages: harness-redef and counter-init lines per language (line<TAB>kind<TAB>
# detail), a renamed self-implementation is NOT reported (the accepted limit), rc 3 for a
# language without caseEmbedRules or no language, rc 70 when the part is unreachable, rc 69
# without the runtime, and <match-path> choosing the registry entry for a temporary copy.
# Fixtures: tests/bin/feature-2502-self-impl-window/fixtures.sh.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

TMPBASE="$(make_tmp)"
readonly TMPBASE
trap 'rm -rf "$TMPBASE"' EXIT
export HOME="$TMPBASE/home"
mkdir -p "$HOME"
export NO_LOG=true
harness_isolate "$TMPBASE/state"
unset CASE_EMBED_CACHE_DIR

# fx_checkout / fx_table_edit / path_without: the registry suite's helpers (one owner).
# shellcheck source=test-language-registry/_lib.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/test-language-registry/_lib.sh"

FXD="$TMPBASE/fx"
# shellcheck source=feature-2502-self-impl-window/fixtures.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2502-self-impl-window/fixtures.sh"
B="$FXD/tests/bin"

# tsi_batch <checkout> <path|-> <spec>... — ONE shell that loads <checkout>'s registry and
# window, then (with PATH=<path>; "-" keeps it) runs `tsi_report <file> [<match-path>]` per
# spec "<file>" or "<file>|<match-path>". Prints "@@ <spec> rc=<n>" and the stdout per spec.
tsi_batch() {
  run_with_timeout 120 bash -c '. "$1/bin/lib/test-language-registry.sh" || exit 97
. "$1/bin/lib/test-self-impl-window.sh" || exit 98
tlr_load || exit 96
p="$2"; shift 2
[ "$p" = - ] || PATH="$p"
for s in "$@"; do
  f="${s%%|*}" r=0
  if [ "$f" = "$s" ]; then out="$(tsi_report "$f")" || r=$?; else out="$(tsi_report "$f" "${s#*|}")" || r=$?; fi
  printf "@@ %s rc=%s\n%s\n" "$s" "$r" "$out"
done' _ "$@" 2>"$TMPBASE/tsi.err"
}

sect() {
  printf '%s\n' "$1" | awk -v h="@@ $2 rc=" 'index($0, "@@ ") == 1 { s = (index($0, h) == 1); next } s && NF'
}
sect_rc() {
  printf '%s\n' "$1" | awk -v h="@@ $2 rc=" 'index($0, h) == 1 { print substr($0, length(h) + 1); exit }'
}

# pairs <lines> — "line:kind" per detection, sorted by line, space-joined.
pairs() {
  printf '%s\n' "$1" | awk -F'\t' 'NF { print $1 ":" $2 }' | sort -n | tr '\n' ' '
}

# detail_at <lines> <line> — the detail column of the detection on <line>.
detail_at() {
  printf '%s\n' "$1" | awk -F'\t' -v l="$2" '$1 == l { print $3; exit }'
}

# expect_report <out> <file> <want-pairs> — rc 0 and exactly <want-pairs>.
expect_report() {
  local lines
  lines="$(sect "$1" "$2")"
  assert_eq "${2##*/}: rc=$(sect_rc "$1" "$2") detections=[$(pairs "$lines")]" "${2##*/}: rc=0 detections=[$3]"
}

# expect_detail <out> <file> <line> <word> — the detail on <line> names <word>.
expect_detail() {
  local d
  d="$(detail_at "$(sect "$1" "$2")" "$3")"
  case "$d" in
    *"$4"*) pass "${2##*/} line $3 detail names $4" ;;
    *) fail "${2##*/} line $3 detail names $4" "detail=[$d]" ;;
  esac
}

# --- detection through the real registry, every language in one shell ---
OUT="$(tsi_batch "$SCRIPT_CHECKOUT_ROOT" - "$B/self.Tests.ps1" "$B/clean.Tests.ps1" "$B/test_self.py" "$B/test_clean.py" "$B/self.js" "$B/clean.js" "$B/self.sh" "$B/clean.sh" "$B/notes.txt")"
if [ -z "$OUT" ]; then
  fail "window loads" "no output; stderr: $(head -c 300 "$TMPBASE/tsi.err")"
fi

if command -v pwsh >/dev/null 2>&1; then
  expect_report "$OUT" "$B/self.Tests.ps1" "4:counter-init 5:counter-init 6:harness-redef "
  expect_detail "$OUT" "$B/self.Tests.ps1" 4 PASS
  expect_detail "$OUT" "$B/self.Tests.ps1" 5 Failed
  assert_eq "pester harness-redef detail=$(detail_at "$(sect "$OUT" "$B/self.Tests.ps1")" 6)" "pester harness-redef detail=Enter-HarnessIsolation"
  # Renamed counter / helper and a counter inside an It block: the accepted limit, rc 0.
  expect_report "$OUT" "$B/clean.Tests.ps1" ""
else
  skip "pester detection: pwsh not available"
fi

if command -v uv >/dev/null 2>&1; then
  expect_report "$OUT" "$B/test_self.py" "7:counter-init 8:counter-init 11:harness-redef 15:harness-redef "
  expect_detail "$OUT" "$B/test_self.py" 7 PASS
  expect_detail "$OUT" "$B/test_self.py" 8 failed
  assert_eq "pytest harness-redef details=$(detail_at "$(sect "$OUT" "$B/test_self.py")" 11),$(detail_at "$(sect "$OUT" "$B/test_self.py")" 15)" "pytest harness-redef details=isolate,_tl3_value"
  # my_isolate, a counter inside a function and a method named isolate are not reported.
  expect_report "$OUT" "$B/test_clean.py" ""
else
  skip "pytest detection: uv not available"
fi

expect_report "$OUT" "$B/self.js" "5:counter-init 6:counter-init 8:harness-redef 12:harness-redef "
expect_detail "$OUT" "$B/self.js" 5 PASS
expect_detail "$OUT" "$B/self.js" 6 failed
assert_eq "js harness-redef details=$(detail_at "$(sect "$OUT" "$B/self.js")" 8),$(detail_at "$(sect "$OUT" "$B/self.js")" 12)" "js harness-redef details=isolate,gitInit"
# A destructured require of the helper's own names is not a redefinition.
expect_report "$OUT" "$B/clean.js" ""

expect_report "$OUT" "$B/self.sh" "4:counter-init 5:counter-init 6:harness-redef "
assert_eq "bash details=$(detail_at "$(sect "$OUT" "$B/self.sh")" 4),$(detail_at "$(sect "$OUT" "$B/self.sh")" 6)" "bash details=PASS=0,pass"
expect_report "$OUT" "$B/clean.sh" ""

assert_eq "no language: rc=$(sect_rc "$OUT" "$B/notes.txt") out=[$(sect "$OUT" "$B/notes.txt")]" "no language: rc=3 out=[]"

# --- rc 3 / rc 70 through an edited table ---
# pytest has no caseEmbedRules (unsupported); js names a part file that does not exist.
fx_table_edit "$SCRIPT_CHECKOUT_ROOT/hooks/lib/test-language-registry.json" "$TMPBASE/edited.json" \
  't.entries.find((e) => e.id === "pytest").caseEmbedRules = null; t.entries.find((e) => e.id === "js").caseEmbedRules = { file: "bin/lib/test-language-parts/no-such-case-embed.sh", function: "js_case_embed" };'
CO="$TMPBASE/co-edited"
fx_checkout "$CO" "$TMPBASE/edited.json"
OUT2="$(tsi_batch "$CO" - "$B/test_self.py" "$B/self.js")"
assert_eq "pytest without caseEmbedRules: rc=$(sect_rc "$OUT2" "$B/test_self.py") out=[$(sect "$OUT2" "$B/test_self.py")]" "pytest without caseEmbedRules: rc=3 out=[]"
assert_eq "js part unreachable: rc=$(sect_rc "$OUT2" "$B/self.js") out=[$(sect "$OUT2" "$B/self.js")]" "js part unreachable: rc=70 out=[]"

# --- rc 69: the runtime is hidden after tlr_load ---
for spec in "pwsh self.Tests.ps1" "uv test_self.py" "node self.js"; do
  rt="${spec%% *}" f="$B/${spec#* }"
  if ! command -v "$rt" >/dev/null 2>&1; then
    skip "rc 69 for ${f##*/}: $rt not available"
    continue
  fi
  OUT3="$(tsi_batch "$SCRIPT_CHECKOUT_ROOT" "$(path_without "$rt")" "$f")"
  assert_eq "${f##*/} without $rt: rc=$(sect_rc "$OUT3" "$f") out=[$(sect "$OUT3" "$f")]" "${f##*/} without $rt: rc=69 out=[]"
done

# --- <match-path>: a temporary copy whose name matches no entry is read as the original path's language ---
if command -v uv >/dev/null 2>&1; then
  mkdir -p "$TMPBASE/x"
  cp "$B/test_self.py" "$TMPBASE/x/copy.tmp"
  C="$TMPBASE/x/copy.tmp"
  OUT4="$(tsi_batch "$SCRIPT_CHECKOUT_ROOT" - "$C|tests/bin/test_x.py" "$C")"
  got="$(sect "$OUT4" "$C|tests/bin/test_x.py" | awk -F'\t' '$2 == "counter-init" { print $1 }' | sort -n | tr '\n' ' ')"
  assert_eq "copy with match-path: rc=$(sect_rc "$OUT4" "$C|tests/bin/test_x.py") counter-init lines=[$got]" "copy with match-path: rc=0 counter-init lines=[7 8 ]"
  assert_eq "copy without match-path: rc=$(sect_rc "$OUT4" "$C")" "copy without match-path: rc=3"
else
  skip "match-path: uv not available"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
