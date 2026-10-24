# The pester caseEmbedRules part's CASE_EMBED_CACHE_DIR cache (#2502 S1-4): with the variable
# set, one analyzer launch (op `all`) answers crr_read's deps and the self-impl, leftover-defs
# and skip-reason ops for one (abs path, content) pair, and the answers equal the uncached
# ones; a different file or changed content launches again; the directory keeps one cache
# file. Without the variable every op launches the analyzer.
# Sourced by tests/bin/feature-2502-case-embed-order.sh.
# shellcheck shell=bash

echo ""
echo "=== pester cache ==="

# The checkout's pester analyzer sits behind the launch-counting wrapper (fixtures.sh).
CACHE_CO="$TMPBASE/co-count"
embed_checkout "$CACHE_CO"
if [ -f "$CACHE_CO/$PARTS/pester-case-analyzer.ps1" ]; then
  mv "$CACHE_CO/$PARTS/pester-case-analyzer.ps1" "$CACHE_CO/$PARTS/pester-case-analyzer.real.ps1"
fi
cp "$FXD/count-analyzer.ps1" "$CACHE_CO/$PARTS/pester-case-analyzer.ps1"
export CEA_LAUNCH_LOG="$TMPBASE/launch.log"
CACHE_SPECS=("self-impl FILE" "leftover-defs FILE" "skip-reason FILE")

# cache_run <cache-dir|-> <file> — batch over CACHE_SPECS with CASE_EMBED_CACHE_DIR=<cache-dir>
# ("-" leaves it unset).
cache_run() {
  if [ "$1" = - ]; then
    batch "$CACHE_CO" "$2" - pester "${CACHE_SPECS[@]}"
  else
    CASE_EMBED_CACHE_DIR="$1" batch "$CACHE_CO" "$2" - pester "${CACHE_SPECS[@]}"
  fi
}

# launches — the number of analyzer starts the counting wrapper logged.
launches() {
  if [ -f "$CEA_LAUNCH_LOG" ]; then grep -c . "$CEA_LAUNCH_LOG"; else echo 0; fi
}

cache_files() {
  find "$1" -type f | grep -c .
}

case_begin "pester-cache-one-launch-per-file" "bin/lib/test-language-parts/pester-case-embed.sh"
if need_rt pester; then
  F="$CACHE_CO/$L_REL"
  rm -f "$CEA_LAUNCH_LOG"
  mkdir -p "$TMPBASE/cache1"
  WITH="$(cache_run "$TMPBASE/cache1" "$F")"
  assert_eq "with cache: analyzer launches=$(launches)" "with cache: analyzer launches=1"
  assert_eq "with cache: launched op=$(head -n 1 "$CEA_LAUNCH_LOG" 2>/dev/null)" "with cache: launched op=all"
  assert_eq "with cache: cache files=$(cache_files "$TMPBASE/cache1")" "with cache: cache files=1"
  rm -f "$CEA_LAUNCH_LOG"
  WITHOUT="$(cache_run - "$F")"
  assert_eq "no cache: analyzer launches=$(launches)" "no cache: analyzer launches=4"
  # The answers must be real ones (leftover-defs names Get-Unused) and identical either way.
  if sect "$WITHOUT" "leftover-defs FILE" | grep -q 'Get-Unused' && [ "$WITH" = "$WITHOUT" ]; then
    pass "cached and uncached answers are identical"
  else
    fail "cached and uncached answers are identical" "with=[$(printf '%s' "$WITH" | head -c 300)] without=[$(printf '%s' "$WITHOUT" | head -c 300)]"
  fi
fi
case_end

case_begin "pester-cache-invalidation" "bin/lib/test-language-parts/pester-case-embed.sh"
if need_rt pester; then
  F="$CACHE_CO/$L_REL"
  G="$CACHE_CO/tests/bin/other.Tests.ps1"
  cp "$F" "$G"
  rm -f "$CEA_LAUNCH_LOG"
  mkdir -p "$TMPBASE/cache2"
  cache_run "$TMPBASE/cache2" "$F" >/dev/null
  cache_run "$TMPBASE/cache2" "$G" >/dev/null
  assert_eq "a different file launches again: launches=$(launches)" "a different file launches again: launches=2"
  # Changed content at the same path: one more launch, and the answer reflects the new text.
  printf '\nfunction Get-Extra { return 4 }\n' >>"$G"
  OUT="$(cache_run "$TMPBASE/cache2" "$G")"
  assert_eq "changed content launches again: launches=$(launches)" "changed content launches again: launches=3"
  if sect "$OUT" "leftover-defs FILE" | grep -q 'Get-Extra'; then
    pass "changed content: leftover-defs names Get-Extra"
  else
    fail "changed content: leftover-defs names Get-Extra" "$(printf '%s' "$OUT" | head -c 300)"
  fi
  assert_eq "one cache file is kept: cache files=$(cache_files "$TMPBASE/cache2")" "one cache file is kept: cache files=1"
fi
case_end
