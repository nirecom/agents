=== bin/lib/launch-pick.sh
pick() {
  if [[ "$TLR_ID" == js ]]; then
    return 78
  fi
  case "$TLR_ID" in
    *) return 0 ;;
  esac
}
=== hooks/lib/kind.js
function kind(entry) {
  if (entry.id === 'bash') return 1;
  if ("pester" !== entry.id) return 2;
  return entry.tableDrivenFallbackEntry;
}
