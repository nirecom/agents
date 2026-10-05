=== hooks/lib/interp.js
function head(interp, base, t) {
  if (interp === "bash") return 1;
  if (base === "sh" || base === "bash") return 2;
  if ("bash" !== t.cmd0) return 3;
  return 0;
}
=== bin/lib/shell-pick.sh
pick() {
  if [[ "$shell" == bash ]]; then return 1; fi
  [ "$interp" = bash ] && return 2
  return 0
}
