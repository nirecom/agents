# Edge cases of the script-root-form check (#2561). Sourced by
# tests/bin/feature-2561-root-names-script-root-form.sh, which defines tree, scan,
# msg_of and the fixture heads first. Defines functions only.

PS_STD="$PS_VAR = (Resolve-Path (Join-Path \$PSScriptRoot '..')).Path"
SH_STD0="$N_SCR=\"\$(cd \"\$(dirname \"\${BASH_SOURCE[0]}\")\" && pwd)\""

c_reassignment() {
  tree reassign
  write_good_tree
  fx "$REPO/bin/x-plus.sh" "${SH_HEAD[@]}" "$(std_sh ..)" "$N_SCR+=/x"
  fx "$REPO/bin/x-read.sh" "${SH_HEAD[@]}" "$(std_sh ..)" "read -r $N_SCR"
  fx "$REPO/bin/x-for.sh" "${SH_HEAD[@]}" "$(std_sh ..)" "for $N_SCR in a b; do :; done"
  fx "$REPO/hooks/x-reassign.js" "${JS_HEAD[@]}" "$(std_js 1)" "$N_SCR = other;"
  fx "$REPO/hooks/x-destructure.js" "${JS_HEAD[@]}" "const { $N_SCR } = require(\"./anchors\");"
  fx "$REPO/hooks/x-rename.js" "${JS_HEAD[@]}" "const { root: $N_SCR } = anchors;"
  fx "$REPO/install/x-reassign.ps1" "$PS_STD" "$PS_VAR = 'x'"
  scan
  expect "reassign: a second write of the name exits 1" rc_is 1
  expect_rows "reassign" script-root-form <<'TABLE'
bin/x-plus.sh|twice@5
bin/x-read.sh|twice@5
bin/x-for.sh|twice@5
hooks/x-reassign.js|twice@4
hooks/x-destructure.js|form@3
hooks/x-rename.js|form@3
install/x-reassign.ps1|twice@2
bin/g-top.sh|accepted
hooks/g-node.js|accepted
TABLE
}

# The head of a file is its first 40 lines of code: comment and blank lines are free.
c_head_limit() {
  local i sh39=() js38=() sh_notes=() js_notes=()
  for ((i = 1; i <= 39; i++)); do sh39+=("echo $i"); done
  for ((i = 1; i <= 38; i++)); do js38+=("use($i);"); done
  for ((i = 0; i < 30; i++)); do
    sh_notes+=('# a note' '')
    js_notes+=('// a note' '')
  done
  tree head
  fx "$REPO/bin/g-edge.sh" "${SH_HEAD[@]}" "${sh39[@]}" "$(std_sh ..)"
  fx "$REPO/bin/x-edge.sh" "${SH_HEAD[@]}" "${sh39[@]}" 'echo 40' "$(std_sh ..)"
  fx "$REPO/bin/g-notes.sh" "${SH_HEAD[@]}" "${sh39[@]}" "${sh_notes[@]}" "$(std_sh ..)"
  fx "$REPO/hooks/g-edge.js" "${JS_HEAD[@]}" "${js38[@]}" "$(std_js 1)"
  fx "$REPO/hooks/x-edge.js" "${JS_HEAD[@]}" "${js38[@]}" 'use(39);' "$(std_js 1)"
  fx "$REPO/hooks/g-notes.js" "${JS_HEAD[@]}" "${js38[@]}" "${js_notes[@]}" "$(std_js 1)"
  scan
  expect "head: one line of code too many exits 1" rc_is 1
  expect_rows "head" script-root-form <<'TABLE'
bin/g-edge.sh|accepted
bin/x-edge.sh|late@44
bin/g-notes.sh|accepted
hooks/g-edge.js|accepted
hooks/x-edge.js|late@42
hooks/g-notes.js|accepted
TABLE
}

# "Unconditional" is judged by where the line stands, not by how it is indented.
c_nesting() {
  tree nesting
  write_good_tree
  fx "$REPO/bin/x-if0.sh" "${SH_HEAD[@]}" 'if [ -n "${X:-}" ]; then' "$(std_sh ..)" 'fi'
  fx "$REPO/bin/x-fn0.sh" "${SH_HEAD[@]}" 'setup() {' "$(std_sh ..)" '}'
  fx "$REPO/bin/x-inline-if.sh" "${SH_HEAD[@]}" "if true; then $(std_sh ..); fi"
  fx "$REPO/bin/x-and.sh" "${SH_HEAD[@]}" "[ -n \"\${X:-}\" ] && $(std_sh ..)"
  fx "$REPO/hooks/x-if0.js" "${JS_HEAD[@]}" 'if (cond) {' "$(std_js 1)" '}'
  fx "$REPO/hooks/x-fn0.js" "${JS_HEAD[@]}" 'function f() {' "$(std_js 1)" '}'
  fx "$REPO/install/x-if0.ps1" 'if ($x) {' "$PS_STD" '}'
  fx "$REPO/bin/x-while0.sh" "${SH_HEAD[@]}" 'while true; do' "$(std_sh ..)" 'done'
  fx "$REPO/bin/x-for0.sh" "${SH_HEAD[@]}" 'for f in a b; do' "$(std_sh ..)" 'done'
  fx "$REPO/bin/x-case0.sh" "${SH_HEAD[@]}" 'case "${X:-}" in' 'a)' "$(std_sh ..)" ';;' 'esac'
  fx "$REPO/bin/x-subshell0.sh" "${SH_HEAD[@]}" '(' "$(std_sh ..)" ')'
  fx "$REPO/bin/g-after-loop.sh" "${SH_HEAD[@]}" 'for f in a b; do' ':' 'done' "$(std_sh ..)"
  fx "$REPO/bin/g-after-case.sh" "${SH_HEAD[@]}" 'case "${X:-}" in' 'a) : ;;' 'esac' "$(std_sh ..)"
  fx "$REPO/bin/g-after-subshell.sh" "${SH_HEAD[@]}" '(' ':' ')' "$(std_sh ..)"
  scan
  expect "nesting: an assignment inside a branch or a function exits 1" rc_is 1
  expect_rows "nesting" script-root-form <<'TABLE'
bin/x-if0.sh|form@5
bin/x-fn0.sh|form@5
bin/x-inline-if.sh|form@4
bin/x-and.sh|form@4
hooks/x-if0.js|form@4
hooks/x-fn0.js|form@4
install/x-if0.ps1|form@2
bin/x-while0.sh|form@5
bin/x-for0.sh|form@5
bin/x-case0.sh|form@6
bin/x-subshell0.sh|form@5
bin/g-after-loop.sh|accepted
bin/g-after-case.sh|accepted
bin/g-after-subshell.sh|accepted
bin/g-top.sh|accepted
hooks/g-node.js|accepted
TABLE
}

# A file at the root climbs nothing; a PowerShell file climbs a fixed number of levels.
c_root_depth() {
  tree rootdepth
  fx "$REPO/g-root.sh" "${SH_HEAD[@]}" "$SH_STD0"
  fx "$REPO/g-root.js" "${JS_HEAD[@]}" "$(std_js 0)"
  fx "$REPO/g-root.ps1" "$PS_VAR = \$PSScriptRoot"
  fx "$REPO/install/g-split.ps1" "$PS_VAR = Split-Path -Parent \$PSScriptRoot"
  fx "$REPO/install/win/g-two.ps1" "$PS_VAR = (Resolve-Path (Join-Path \$PSScriptRoot '..\\..')).Path"
  scan
  expect "root depth: no climb at the root and a fixed climb below it exit 0" rc_is 0
  fx "$REPO/x-root.sh" "${SH_HEAD[@]}" "$(std_sh ..)"
  fx "$REPO/x-root.js" "${JS_HEAD[@]}" "$(std_js 1)"
  fx "$REPO/x-root.ps1" "$PS_STD"
  fx "$REPO/bin/x-zero.sh" "${SH_HEAD[@]}" "$SH_STD0"
  fx "$REPO/install/win/x-short.ps1" "$PS_STD"
  fx "$REPO/install/x-noclimb.ps1" "$PS_VAR = \$PSScriptRoot"
  fx "$REPO/install/x-leaf.ps1" "$PS_VAR = Split-Path -Leaf \$PSScriptRoot"
  scan
  expect "root depth: a climb that leaves or misses the root exits 1" rc_is 1
  expect_rows "root depth" script-root-form <<'TABLE'
x-root.sh|depth@4
x-root.js|depth@3
x-root.ps1|depth@1
bin/x-zero.sh|depth@4
install/win/x-short.ps1|depth@1
install/x-noclimb.ps1|depth@1
install/x-leaf.ps1|form@1
g-root.sh|accepted
g-root.js|accepted
g-root.ps1|accepted
install/g-split.ps1|accepted
install/win/g-two.ps1|accepted
TABLE
}
