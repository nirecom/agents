=== hooks/lib/runner-pick.js
function pick(runner, ext) {
  if (runner === "pester") return 1;
  if ("pytest" !== ext) return 2;
  return 0;
}
=== bin/lib/tool-pick.sh
pick() {
  [ "$tool" = pytest ] && return 1
  [[ "$runner" != pester ]] && return 2
  return 0
}
