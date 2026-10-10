#!/usr/bin/env bash
# Tests: bin/check-root-names.sh, bin/check-root-names/script-root-form.js
# Tags: root-names, script-root-form, gate, static-check, bin, pwsh-not-required, scope:issue-specific, TL2
# #2561: a file assigns its own checkout root once, unconditionally, without
# export, at the top, in the one standard form for its language and depth.
# TL3 gap (what this test does NOT catch):
# - the real tree; the scan test runs every check over the checkout.
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
T="$(np "$(make_tmp)")"
readonly T
harness_isolate "$T/iso"
trap 'rm -rf "$T"' EXIT
REAL_GATE="$SCRIPT_CHECKOUT_ROOT/bin/check-root-names.sh"
RETIRED_LIST="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2561-root-names-residue.sh"
. "$(dirname "$0")/feature-2561-root-names/common.sh"

# Fixture lines are assembled from fragments: the only assignment of the name in
# this file is the standard one above.
SUB_UP1='$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)'
SH_HEAD=('#!/usr/bin/env bash' '# a fixture script' 'set -euo pipefail')
JS_HEAD=('"use strict";' 'const path = require("path");')
PS_VAR='$'"$N_SCR"
EXC_FORM="{\"file\":\"bin/g-excepted.sh\",\"allow\":[\"$N_SCR\"],\"forms\":[\"own-script-root-form\"],\"reason\":\"fixture\"}"

# tree <name> — fresh gate copy, fixture table and empty fixture repo.
tree() {
  make_kit "$1"
  write_table "$KIT" "$EXC_FORM"
  new_repo "$1"
}

# scan — commit the fixture tree and run the one check over it.
scan() {
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only script-root-form
}

# msg_of <key> — the text that tells the messages of this check apart.
msg_of() {
  case "$1" in
    twice) printf 'assigned more than once' ;;
    form) printf 'not assigned in the standard form' ;;
    depth) printf 'level(s) but this file sits' ;;
    late) printf 'too far from the top of the file' ;;
    prefix) printf 'under its own prefixed name only' ;;
    unassigned) printf 'read but not assigned in this file' ;;
    *) printf 'unknown message key %s' "$1" ;;
  esac
}

# expect_verdicts <label> — one assertion per row of the table on stdin.
# Columns: <repo-relative path>|<verdict>; the verdict is accepted, or
# <message key>@<line> for the one line the check reports.
expect_verdicts() { expect_rows "$1" script-root-form; }

write_good_tree() {
  fx "$REPO/bin/g-top.sh" "${SH_HEAD[@]}" "$(std_sh ..)" "echo \"$V_SCR\"" "ls \"$V_SCR/bin\""
  fx "$REPO/bin/sub/g-deep.sh" "${SH_HEAD[@]}" "$(std_sh ../..)"
  fx "$REPO/skills/s/scripts/g-three.sh" "${SH_HEAD[@]}" "$(std_sh ../../..)"
  fx "$REPO/hooks/g-node.js" "${JS_HEAD[@]}" "$(std_js 1)" "use($N_SCR);"
  fx "$REPO/hooks/lib/g-node2.js" "${JS_HEAD[@]}" "$(std_js 2)"
  fx "$REPO/bin/g-none.sh" "${SH_HEAD[@]}" 'echo "no root needed"'
}

c_standard_forms() {
  tree standard
  write_good_tree
  scan
  expect "standard: bash and Node forms at every depth exit 0" rc_is 0
  expect_verdicts "standard" <<'TABLE'
bin/g-top.sh|accepted
bin/sub/g-deep.sh|accepted
skills/s/scripts/g-three.sh|accepted
hooks/g-node.js|accepted
hooks/lib/g-node2.js|accepted
bin/g-none.sh|accepted
TABLE
}

c_bash_forms() {
  local late=() i
  for ((i = 0; i < 80; i++)); do late+=("echo $i"); done
  tree bash
  write_good_tree
  fx "$REPO/bin/x-twice.sh" "${SH_HEAD[@]}" "$(std_sh ..)" 'echo mid' "$(std_sh ..)"
  fx "$REPO/bin/x-default.sh" "${SH_HEAD[@]}" "$N_SCR=\"\${$N_SCR:-$SUB_UP1}\""
  fx "$REPO/bin/x-colon.sh" "${SH_HEAD[@]}" ": \"\${$N_SCR:=$SUB_UP1}\""
  fx "$REPO/bin/x-cond.sh" "${SH_HEAD[@]}" "if [ -z \"\${$N_SCR:-}\" ]; then" "  $(std_sh ..)" 'fi'
  fx "$REPO/bin/x-export.sh" "${SH_HEAD[@]}" "export $(std_sh ..)"
  fx "$REPO/bin/x-late.sh" "${SH_HEAD[@]}" "${late[@]}" "$(std_sh ..)"
  fx "$REPO/bin/x-arg0.sh" "${SH_HEAD[@]}" "$N_SCR=\"\$(cd \"\$(dirname \"\$0\")/..\" && pwd)\""
  fx "$REPO/bin/x-git.sh" "${SH_HEAD[@]}" "$N_SCR=\"\$(git rev-parse --show-toplevel)\""
  fx "$REPO/bin/x-literal.sh" "${SH_HEAD[@]}" "$N_SCR=/opt/checkout"
  fx "$REPO/bin/x-fn.sh" "${SH_HEAD[@]}" 'setup() {' "  $(std_sh ..)" '}'
  scan
  expect "bash: non-standard assignments exit 1" rc_is 1
  expect_verdicts "bash" <<'TABLE'
bin/x-twice.sh|twice@6
bin/x-default.sh|form@4
bin/x-colon.sh|form@4
bin/x-cond.sh|form@5
bin/x-export.sh|form@4
bin/x-late.sh|late@84
bin/x-arg0.sh|form@4
bin/x-git.sh|form@4
bin/x-literal.sh|form@4
bin/x-fn.sh|form@5
bin/g-top.sh|accepted
bin/sub/g-deep.sh|accepted
bin/g-none.sh|accepted
TABLE
}

c_node_forms() {
  tree node
  write_good_tree
  fx "$REPO/hooks/x-envor.js" "${JS_HEAD[@]}" "const $N_SCR = process.env.OTHER_ROOT || path.resolve(__dirname, \"..\");"
  fx "$REPO/hooks/x-let.js" "${JS_HEAD[@]}" "let $N_SCR = path.resolve(__dirname, \"..\");"
  fx "$REPO/hooks/x-cwd.js" "${JS_HEAD[@]}" "const $N_SCR = process.cwd();"
  fx "$REPO/hooks/x-twice.js" "${JS_HEAD[@]}" "$(std_js 1)" 'function f() {' "  $(std_js 1)" '}'
  fx "$REPO/hooks/x-join.js" "${JS_HEAD[@]}" "const $N_SCR = path.join(__dirname, \"..\");"
  fx "$REPO/hooks/x-extra.js" "${JS_HEAD[@]}" "const $N_SCR = path.resolve(__dirname, \"..\", \"bin\");"
  scan
  expect "node: non-standard assignments exit 1" rc_is 1
  expect_verdicts "node" <<'TABLE'
hooks/x-envor.js|form@3
hooks/x-let.js|form@3
hooks/x-cwd.js|form@3
hooks/x-twice.js|twice@5
hooks/x-join.js|form@3
hooks/x-extra.js|form@3
hooks/g-node.js|accepted
hooks/lib/g-node2.js|accepted
TABLE
}

c_depth() {
  tree depth
  write_good_tree
  fx "$REPO/bin/x-deep.sh" "${SH_HEAD[@]}" "$(std_sh ../..)"
  fx "$REPO/bin/sub/x-shallow.sh" "${SH_HEAD[@]}" "$(std_sh ..)"
  fx "$REPO/skills/s/scripts/x-two.sh" "${SH_HEAD[@]}" "$(std_sh ../..)"
  fx "$REPO/hooks/x-levels.js" "${JS_HEAD[@]}" "$(std_js 2)"
  fx "$REPO/hooks/lib/x-levels.js" "${JS_HEAD[@]}" "$(std_js 1)"
  fx "$REPO/hooks/x-zero.js" "${JS_HEAD[@]}" "$(std_js 0)"
  scan
  expect "depth: a climb that does not match the file depth exits 1" rc_is 1
  expect_verdicts "depth" <<'TABLE'
bin/x-deep.sh|depth@4
bin/sub/x-shallow.sh|depth@4
skills/s/scripts/x-two.sh|depth@4
hooks/x-levels.js|depth@3
hooks/lib/x-levels.js|depth@3
hooks/x-zero.js|depth@3
bin/sub/g-deep.sh|accepted
skills/s/scripts/g-three.sh|accepted
hooks/lib/g-node2.js|accepted
TABLE
}

c_sourced() {
  tree sourced
  fx "$REPO/bin/sourced/g-lib.sh" '# a sourced library' "$(std_sh ../.. "_G_LIB_$N_SCR")" "echo \"\$_G_LIB_$N_SCR\""
  fx "$REPO/bin/sourced/g-two.part.sh" '# a sourced library' "$(std_sh ../.. "_G_TWO_PART_$N_SCR")"
  fx "$REPO/bin/sourced/g-none.sh" '# a sourced library without a root' 'helper() { :; }'
  scan
  expect "sourced: the prefixed name in the standard form exits 0" rc_is 0
  fx "$REPO/bin/sourced/x-noprefix.sh" '# a sourced library' "$(std_sh ../..)"
  fx "$REPO/bin/sourced/x-stem.sh" '# a sourced library' "$(std_sh ../.. "_OTHER_$N_SCR")"
  fx "$REPO/bin/sourced/x-depth.sh" '# a sourced library' "$(std_sh .. "_X_DEPTH_$N_SCR")"
  fx "$REPO/bin/sourced/x-twice.sh" '# a sourced library' "$(std_sh ../.. "_X_TWICE_$N_SCR")" \
    "$(std_sh ../.. "_X_TWICE_$N_SCR")"
  scan
  expect "sourced: a wrong name, depth or count exits 1" rc_is 1
  expect_verdicts "sourced" <<'TABLE'
bin/sourced/x-noprefix.sh|prefix@2
bin/sourced/x-stem.sh|prefix@2
bin/sourced/x-depth.sh|depth@2
bin/sourced/x-twice.sh|twice@3
bin/sourced/g-lib.sh|accepted
bin/sourced/g-two.part.sh|accepted
bin/sourced/g-none.sh|accepted
TABLE
}

c_powershell() {
  tree pwsh
  fx "$REPO/install/g.ps1" "$PS_VAR = (Resolve-Path (Join-Path \$PSScriptRoot '..')).Path" "Write-Output $PS_VAR"
  scan
  expect "powershell: a root taken from the script's own folder exits 0" rc_is 0
  fx "$REPO/install/x-env.ps1" "$PS_VAR = Join-Path (Join-Path \$PSScriptRoot '..') \$env:OTHER_ROOT"
  fx "$REPO/install/x-git.ps1" "$PS_VAR = Join-Path (Join-Path \$PSScriptRoot '..') (git rev-parse --show-prefix)"
  fx "$REPO/install/x-none.ps1" "$PS_VAR = (Resolve-Path '..').Path"
  fx "$REPO/install/x-twice.ps1" "$PS_VAR = (Resolve-Path (Join-Path \$PSScriptRoot '..')).Path" \
    "$PS_VAR = (Resolve-Path (Join-Path \$PSScriptRoot '..')).Path"
  fx "$REPO/install/x-cond.ps1" "if (-not $PS_VAR) { $PS_VAR = (Resolve-Path (Join-Path \$PSScriptRoot '..')).Path }"
  scan
  expect "powershell: other origins exit 1" rc_is 1
  expect_verdicts "powershell" <<'TABLE'
install/x-env.ps1|form@1
install/x-git.ps1|form@1
install/x-none.ps1|form@1
install/x-twice.ps1|twice@2
install/x-cond.ps1|form@1
install/g.ps1|accepted
TABLE
}

c_out_of_scope() {
  tree scope
  fx "$REPO/bin/g-excepted.sh" "${SH_HEAD[@]}" "$N_SCR=\"\$(cd \"\$(dirname \"\$0\")/..\" && pwd)\""
  fx "$REPO/tests/g-derived.sh" "${SH_HEAD[@]}" "$(std_sh ..)" "FAKE_$N_SCR=/tmp/a" "FAKE_$N_SCR=/tmp/b" \
    "export FAKE_$N_SCR"
  fx "$REPO/tests/g-derived.js" "${JS_HEAD[@]}" "let FAKE_$N_SCR = process.cwd();"
  fx "$REPO/docs/g-prose.md" "Write \`$N_SCR=/opt/checkout\` nowhere."
  scan
  expect "scope: an exception, derived names and prose exit 0" rc_is 0
  fx "$REPO/bin/sub/g-excepted.sh" "${SH_HEAD[@]}" "$N_SCR=/opt/checkout"
  scan
  expect_verdicts "scope" <<'TABLE'
bin/sub/g-excepted.sh|form@4
bin/g-excepted.sh|accepted
tests/g-derived.sh|accepted
tests/g-derived.js|accepted
docs/g-prose.md|accepted
TABLE
}

c_rerun_stable() {
  tree rerun
  write_good_tree
  fx "$REPO/bin/x-twice.sh" "${SH_HEAD[@]}" "$(std_sh ..)" "$(std_sh ..)"
  commit_all "$REPO"
  expect_rerun_stable "rerun" 1 "$REPO" "$KIT" --root "$REPO" --only script-root-form
}

c_hostile_text() {
  tree hostile
  fx "$REPO/bin/\$(touch PWNED_A).sh" "$N_SCR=\"\$(touch PWNED_B)\""
  fx "$REPO/bin/y;touch PWNED_C;.sh" "$N_SCR=\`touch PWNED_D\`"
  scan
  expect "hostile: the assignments are read and reported (exit 1)" rc_is 1
  expect "hostile: the metacharacter file is reported" \
    reports "bin/y;touch PWNED_C;.sh" script-root-form 1 "$(msg_of form)"
  expect "hostile: the substitution file is reported" \
    reports "bin/\$(touch PWNED_A).sh" script-root-form 1 "$(msg_of form)"
  expect "hostile: no file name or content was executed" no_marker_file
}

case_begin "standard-forms-pass-at-every-depth" "bin/check-root-names/script-root-form.js"
c_standard_forms
case_end

case_begin "nonstandard-bash-assignment-is-reported" "bin/check-root-names/script-root-form.js"
c_bash_forms
case_end

case_begin "nonstandard-node-assignment-is-reported" "bin/check-root-names/script-root-form.js"
c_node_forms
case_end

case_begin "climb-must-match-the-file-depth" "bin/check-root-names/script-root-form.js"
c_depth
case_end

case_begin "sourced-library-uses-its-prefixed-name" "bin/check-root-names/script-root-form.js"
c_sourced
case_end

case_begin "powershell-root-comes-from-its-own-folder" "bin/check-root-names/script-root-form.js"
c_powershell
case_end

case_begin "exceptions-and-derived-names-are-not-checked" "bin/check-root-names/script-root-form.js"
c_out_of_scope
case_end

. "$(dirname "$0")/feature-2561-root-names/script-root-form-edges.sh"

case_begin "second-write-and-destructuring-are-reported" "bin/check-root-names/script-root-form.js"
c_reassignment
case_end

case_begin "head-limit-counts-code-lines-only" "bin/check-root-names/script-root-form.js"
c_head_limit
case_end

case_begin "assignment-inside-a-branch-or-function-is-reported" "bin/check-root-names/script-root-form.js"
c_nesting
case_end

case_begin "root-file-and-powershell-climb-match-the-depth" "bin/check-root-names/script-root-form.js"
c_root_depth
case_end

case_begin "read-without-an-assignment-is-reported" "bin/check-root-names/script-root-form.js"
c_read_without_assignment
case_end

case_begin "rerun-is-stable-and-read-only" "bin/check-root-names.sh"
c_rerun_stable
case_end

case_begin "hostile-names-and-content-are-not-executed" "bin/check-root-names.sh"
c_hostile_text
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]]
