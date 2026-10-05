=== bin/lib/test-retire-predicate.sh
trp_unit_stem() {
  local name="${1##*/}"
  local stem="${name%.sh}"; stem="${stem%.Tests.ps1}"; stem="${stem%.py}"
  printf '%s' "$stem"
}
