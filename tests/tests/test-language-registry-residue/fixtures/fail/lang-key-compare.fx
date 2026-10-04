=== hooks/lib/lang-pick.js
function pick(entry, lang, kind) {
  if (lang === "pester") return 1;
  if (kind !== 'pytest') return 2;
  if ("bash" === entry.language) return 3;
  return 0;
}
=== bin/lib/lang-pick.sh
pick() {
  [ "$test_kind" = pester ] && return 1
  [[ "${TEST_LANG}" != pytest ]] && return 2
  return 0
}
