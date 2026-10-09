#!/usr/bin/env bash
# Tests: bin/check-root-names.sh, bin/check-root-names/env-name.js
# Tags: root-names, env-name, gate, static-check, bin, pwsh-not-required, scope:issue-specific, TL2
# #2561: the agents root name is an environment variable only — set in few places,
# in few ways — and the other three names are never environment variables.
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

# Fixture lines are assembled from fragments so that no line of this file has a
# shape the gate rejects.
exc_set() {
  printf '{"file":"%s","allow":["%s"],"forms":["set-agents-root"],"reason":"fixture"}' "$1" "$N_AMR"
}
EXCEPTIONS=("$(exc_set profile-snippet.sh)" "$(exc_set profile-snippet.ps1)"
  "$(exc_set hooks/k-excepted.js)" "$(exc_set ci/k-excepted.yml)")

# msg_of <key> — the text that tells the three messages of this check apart.
msg_of() {
  case "$1" in
    local) printf 'never a local variable' ;;
    set) printf 'neither a test nor a named exception' ;;
    never) printf 'never becomes an environment variable' ;;
    *) printf 'unknown message key %s' "$1" ;;
  esac
}

# Fixture tables, columns: <repo-relative path>|<verdict>|<content>. The verdict is
# accepted, or <message key>@<line>. The bodies are expanded: a name is written as
# its variable, a literal dollar sign as \$, and <NL> starts a new line.
# Ways of writing a value that are never allowed, in any file.
table SHELL_BAD <<TABLE
bin/k-plain.sh|local@1|$N_AMR=/x
tests/k-plain-test.sh|local@1|$N_AMR=/x
bin/k-local.sh|local@1|f() { local $N_AMR=/x; }
bin/k-readonly.sh|local@1|readonly $N_AMR=/x
bin/k-declare.sh|local@1|declare $N_AMR=/x
bin/k-typeset.sh|local@1|typeset $N_AMR=/x
bin/k-read.sh|local@1|read -r $N_AMR
bin/k-for.sh|local@1|for $N_AMR in a b; do :; done
tests/k-local-test.sh|local@1|f() { local $N_AMR=/x; }
TABLE
table OTHER_LANG_BAD <<TABLE
install/k-var.ps1|local@1|\$$N_AMR = 'x'
tests/k-var-test.ps1|local@1|\$$N_AMR = 'x'
hooks/k-const.js|local@1|const $N_AMR = process.env.$N_AMR;
hooks/k-let.js|local@1|let $N_AMR = 1;
hooks/k-var.js|local@1|var $N_AMR = 1;
hooks/k-destructure.js|local@1|const { $N_AMR } = process.env;
tests/k-const-test.js|local@1|const $N_AMR = root;
hooks/k-bare-assign.js|local@1|$N_AMR = root;
TABLE
# The language comes from the first line when it names an interpreter, else from the
# extension; a file with neither is read as shell.
table SHEBANG_BAD <<TABLE
bin/k-node-tool|local@2|#!/usr/bin/env node<NL>const $N_AMR = 1;
bin/k-node-named.sh|local@2|#!/usr/bin/env node<NL>let $N_AMR = 1;
bin/k-pwsh-tool|local@2|#!/usr/bin/env pwsh<NL>\$$N_AMR = 'x'
bin/k-sh-tool|local@2|#!/bin/sh<NL>$N_AMR=/x
bin/k-bash-tool|set@2|#!/usr/bin/env bash<NL>export $N_AMR=/x
bin/k-bare-tool|local@1|$N_AMR=/x
TABLE
# Allowed ways of writing, in a file that is neither a test nor an exception.
table PLACE_BAD <<TABLE
bin/k-export.sh|set@1|export $N_AMR=/x
bin/k-prefix.sh|set@1|$N_AMR=/x node tool.js
bin/k-env-cmd.sh|set@1|env $N_AMR=/x node tool.js
hooks/k-penv.js|set@1|process.env.$N_AMR = root;
hooks/k-bracket.js|set@1|process.env["$N_AMR"] = root;
hooks/k-envkey.js|set@1|spawn("node", [], { env: { $N_AMR: root } });
install/k-env.ps1|set@1|\$env:$N_AMR = 'x'
install/k-setenv.ps1|set@1|[Environment]::SetEnvironmentVariable("$N_AMR", 'x')
profile-snippet.sh.bak|set@1|export $N_AMR=/x
ci/k-env.yml|set@2|env:<NL>  $N_AMR: /x
ci/k-list.yaml|set@1|- $N_AMR: /x
ci/k-env.json|set@1|{"env": {"$N_AMR": "/x"}}
TABLE
# The symmetric half: the other names never become environment variables.
table SYMMETRIC_BAD <<TABLE
tests/k-export-script.sh|never@1|export $N_SCR=/x
tests/k-export-tmr.sh|never@1|export $N_TMR=/x
bin/k-export-tcr.sh|never@1|export $N_TCR
hooks/k-read-script.js|never@1|const r = process.env.$N_SCR;
hooks/k-read-bracket.js|never@1|const r = process.env["$N_SCR"];
hooks/k-set-tmr.js|never@1|process.env.$N_TMR = x;
hooks/k-set-tcr.js|never@1|process.env.$N_TCR = x;
hooks/k-set-bracket.js|never@1|process.env["$N_TCR"] = x;
install/k-read-script.ps1|never@1|\$r = \$env:$N_SCR
install/k-set-tcr.ps1|never@1|\$env:$N_TCR = 'x'
install/k-set-tmr.ps1|never@1|\$env:$N_TMR = 'x'
tests/k-read-script-test.js|never@1|const r = process.env.$N_SCR;
TABLE
# The two target names reach a child as arguments: handing one down, reading one from
# the environment, or keying an object with one is reported — in a test file too.
table TARGET_BAD <<TABLE
bin/k-prefix-tmr.sh|never@1|$N_TMR=/x node tool.js
tests/k-prefix-tcr-test.sh|never@1|$N_TCR=/x bash tool.sh
tests/k-prefix-pair-test.sh|never@1|$N_AMR=/a $N_TCR=/x bash tool.sh
bin/k-env-tcr.sh|never@1|env $N_TCR=/x node tool.js
tests/k-env-tmr-test.sh|never@1|env -u OTHER $N_TMR=/x node tool.js
hooks/k-read-tmr.js|never@1|use(process.env.$N_TMR, process.env.$N_TCR);
hooks/k-read-tcr-bracket.js|never@1|if (process.env["$N_TCR"] === y) use();
tests/k-read-tmr-test.js|never@1|const r = process.env.$N_TMR;
hooks/k-key-tmr.js|never@1|spawn("node", [], { env: { $N_TMR: root } });
hooks/k-key-tcr-quoted.js|never@1|const env = { "$N_TCR": root };
hooks/k-key-own-line.js|never@2|const env = {<NL>  $N_TCR: root,<NL>};
tests/k-key-tmr-test.js|never@1|run({ $N_TMR: root });
install/k-read-tmr.ps1|never@1|\$r = \$env:$N_TMR
install/k-read-tcr.ps1|never@1|if (\$env:$N_TCR -eq 'x') { Write-Output 1 }
install/k-get-tmr.ps1|never@1|\$r = [Environment]::GetEnvironmentVariable("$N_TMR")
tests/k-read-tcr-test.ps1|never@1|\$r = \$env:$N_TCR
bin/k-env-quoted-tmr.sh|never@1|env "$N_TMR=\$x" node tool.js
tests/k-env-wrapped-tcr-test.sh|never@1|timeout 60 env $N_TCR=/x node tool.js
tests/k-env-array-tcr-test.sh|never@1|envs+=("$N_TCR=\$x")
bin/k-declare-x-tmr.sh|never@1|declare -x $N_TMR=/x
tests/k-typeset-x-tcr-test.sh|never@1|typeset -x $N_TCR=/x
bin/k-local-x-tmr.sh|never@1|local -x $N_TMR=/x
hooks/k-bound-tmr.js|never@1|const { $N_TMR } = process.env;
tests/k-bound-rename-tcr-test.js|never@1|const { $N_TCR: root } = process.env;
hooks/k-spread-tmr.js|never@1|const env = { ...process.env, $N_TMR };
install/k-brace-tmr.ps1|never@1|\$r = \${env:$N_TMR}
TABLE
table GOOD_ROWS <<TABLE
tests/k-ok-export.sh|accepted|export $N_AMR=/x
tests/k-ok-prefix.sh|accepted|$N_AMR=/x node tool.js
tests/k-ok-env-cmd.sh|accepted|env $N_AMR=/x node tool.js
tests/k-ok-penv.js|accepted|process.env.$N_AMR = root;
tests/k-ok-envkey.js|accepted|spawn("node", [], { env: { $N_AMR: root } });
tests/k-ok-env.yml|accepted|  $N_AMR: /x
profile-snippet.sh|accepted|export $N_AMR="\$HOME/agents"
profile-snippet.ps1|accepted|\$env:$N_AMR = 'x'
hooks/k-excepted.js|accepted|process.env.$N_AMR = root;
ci/k-excepted.yml|accepted|  $N_AMR: /x
docs/k-ok-prose.md|accepted|$N_AMR: /x, then \`export $N_AMR=/x\`
bin/k-ok-read.sh|accepted|echo "$V_AMR"; [ "$V_AMR" == /x ]
hooks/k-ok-read.js|accepted|if (process.env.$N_AMR === root) use(process.env.$N_AMR);
hooks/k-ok-rename.js|accepted|const { $N_AMR: x } = process.env;
install/k-ok-read.ps1|accepted|if (\$env:$N_AMR -eq 'x') { Write-Output \$env:$N_AMR }
hooks/k-ok-compare.js|accepted|if ($N_AMR === root) use();
hooks/k-ok-target-local.js|accepted|const $N_TMR = x; let $N_TCR = y;
hooks/k-ok-target-rename.js|accepted|const { $N_TMR: main, $N_TCR: checkout } = roots;
tests/k-ok-target-rename-test.js|accepted|const { "$N_TCR": checkout } = roots;
install/k-ok-target-local.ps1|accepted|\$$N_TMR = 'x'; \$$N_TCR = 'y'
bin/k-ok-target-local.sh|accepted|$N_TMR=/x; local $N_TCR=/y
bin/k-ok-target-flag.sh|accepted|node tool.js --target-main-root "\$$N_TMR" "\$$N_TCR"
bin/k-ok-env-unset.sh|accepted|env -u $N_TCR node tool.js
bin/k-ok-env-value.sh|accepted|env "OTHER=\$$N_TMR" node tool.js
tests/k-ok-echo-pair.sh|accepted|echo "$N_TMR=\$x"
hooks/k-ok-target-bound.js|accepted|const { $N_TMR } = roots;
bin/k-ok-node-e.sh|accepted|$N_SCR="$V_SCR" node -e 'use(process.env.$N_SCR)'
bin/k-ok-bash-c.sh|accepted|$N_SCR="$V_SCR" bash -c 'echo ok'
tests/k-ok-bash-c-test.sh|accepted|$N_SCR="$V_SCR" bash -c 'echo ok'
tests/k-ok-derived.sh|accepted|SAVED_$N_AMR=/x
bin/k-ok-none.sh|accepted|echo plain
bin/k-ok-py-tool|accepted|#!/usr/bin/env python3<NL>$N_AMR="/x"
TABLE
# Text inside a comment or a string is not code.
table QUIET_ROWS <<TABLE
bin/k-ok-comment.sh|accepted|true # export $N_AMR=/x
bin/k-ok-quoted.sh|accepted|echo "export $N_AMR=/x" '$N_AMR=/y'
hooks/k-ok-comment.js|accepted|use(1); // const $N_AMR = 1; process.env.$N_AMR = root;
hooks/k-ok-block.js|accepted|/* const $N_AMR = 1; */ use(1);
hooks/k-ok-block2.js|accepted|/*<NL>process.env.$N_AMR = root;<NL>*/
hooks/k-ok-string.js|accepted|log("const $N_AMR = 1");
install/k-ok-comment.ps1|accepted|Write-Output 1 # \$$N_AMR = 'x'
install/k-ok-block.ps1|accepted|<# \$env:$N_AMR = 'x' #> Write-Output 1
install/k-ok-block2.ps1|accepted|<#<NL>\$$N_AMR = 'x'<NL>#>
TABLE

# run_rows <kit-name> <table>... — one committed fixture tree; runs the one check.
run_rows() {
  local name="$1" rows
  shift
  make_kit "$name"
  write_table "$KIT" "${EXCEPTIONS[@]}"
  new_repo "$name"
  for rows in "$@"; do seed "$REPO" "$rows" 1; done
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only env-name
}

c_group() {
  local label="$1" bad="$2" path _rest
  run_rows "$label" GOOD_ROWS "$bad"
  expect "$label: exits 1" rc_is 1
  expect_rows "$label" env-name <<<"${!bad}"
  expect_rows "$label" env-name <<<"$GOOD_ROWS"
  while IFS='|' read -r path _rest; do
    expect "$label: $path gets one line, not two" test "$(lines_for "$path")" = 1
  done <<<"${!bad}"
}

c_allowed() {
  run_rows allowed GOOD_ROWS QUIET_ROWS
  expect "allowed: sanctioned writes, every read and inert text exit 0" rc_is 0
  expect_rows "allowed" env-name <<<"$GOOD_ROWS"
  expect_rows "inert" env-name <<<"$QUIET_ROWS"
}

c_exception_scope() {
  run_rows exception GOOD_ROWS
  fx "$REPO/hooks/k-excepted.js" "process.env.$N_AMR = root;" "const $N_AMR = root;" \
    "const r = process.env.$N_SCR;"
  fx "$REPO/hooks/lib/k-excepted.js" "process.env.$N_AMR = root;"
  fx "$REPO/ci/sub/k-excepted.yml" "$N_AMR: /x"
  fx "$REPO/profile-snippet.sh" "export $N_AMR=/x" "export $N_SCR=/y"
  # The second excepted file, written here in its sanctioned form (good variant).
  fx "$REPO/profile-snippet.ps1" "\$env:$N_AMR = 'x'"
  commit_all "$REPO"
  expect "exception: the second excepted file is committed in its sanctioned form" \
    git -C "$REPO" grep -qF -e "env:$N_AMR = 'x'" HEAD -- profile-snippet.ps1
  run_gate "$KIT" --root "$REPO" --only env-name
  expect "exception: exits 1" rc_is 1
  expect_rows "exception" env-name <<'TABLE'
hooks/k-excepted.js|local@2
hooks/k-excepted.js|never@3
hooks/lib/k-excepted.js|set@1
ci/sub/k-excepted.yml|set@1
profile-snippet.sh|never@2
profile-snippet.ps1|accepted
ci/k-excepted.yml|accepted
TABLE
  expect "exception: the freed form stays free beside the other findings" \
    silent_on "hooks/k-excepted.js" env-name 1
  expect "exception: the sanctioned export stays free beside the symmetric finding" \
    silent_on "profile-snippet.sh" env-name 1
  # Bad variant of the same file: a plain variable and a read of another root name.
  fx "$REPO/profile-snippet.ps1" "\$env:$N_AMR = 'x'" "\$$N_AMR = 'x'" "\$r = \$env:$N_SCR"
  commit_all "$REPO"
  expect "exception: the bad variant of the second excepted file is committed" \
    git -C "$REPO" grep -qF -e "r = \$env:$N_SCR" HEAD -- profile-snippet.ps1
  run_gate "$KIT" --root "$REPO" --only env-name
  expect "exception: the bad variant exits 1" rc_is 1
  expect_rows "exception, bad variant" env-name <<'TABLE'
profile-snippet.ps1|local@2
profile-snippet.ps1|never@3
TABLE
  expect "exception: its sanctioned line stays free" silent_on "profile-snippet.ps1" env-name 1
}

c_rerun_stable() {
  make_kit rerun
  write_table "$KIT" "${EXCEPTIONS[@]}"
  new_repo rerun
  seed "$REPO" GOOD_ROWS 1
  seed "$REPO" SHELL_BAD 1
  seed "$REPO" SYMMETRIC_BAD 1
  commit_all "$REPO"
  expect_rerun_stable "rerun" 1 "$REPO" "$KIT" --root "$REPO" --only env-name
}

c_hostile_text() {
  make_kit hostile
  write_table "$KIT"
  new_repo hostile
  fx "$REPO/bin/\$(touch PWNED_A).sh" "$N_AMR=\$(touch PWNED_B)"
  fx "$REPO/bin/z;touch PWNED_C;.sh" "$N_AMR=\`touch PWNED_D\`"
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only env-name
  expect "hostile: the assignments are read and reported (exit 1)" rc_is 1
  expect "hostile: the metacharacter file is reported" \
    reports "bin/z;touch PWNED_C;.sh" env-name 1 "$(msg_of local)"
  expect "hostile: the substitution file is reported" \
    reports "bin/\$(touch PWNED_A).sh" env-name 1 "$(msg_of local)"
  expect "hostile: no file name or content was executed" no_marker_file
}

case_begin "sanctioned-writes-and-reads-pass" "bin/check-root-names/env-name.js"
c_allowed
case_end

case_begin "shell-local-forms-are-reported" "bin/check-root-names/env-name.js"
c_group "shell" SHELL_BAD
case_end

case_begin "node-and-powershell-local-forms-are-reported" "bin/check-root-names/env-name.js"
c_group "other-lang" OTHER_LANG_BAD
case_end

case_begin "first-line-interpreter-decides-the-language" "bin/check-root-names/line-scan.js"
c_group "shebang" SHEBANG_BAD
case_end

case_begin "allowed-form-in-an-unlisted-file-is-reported" "bin/check-root-names/env-name.js"
c_group "place" PLACE_BAD
case_end

case_begin "other-names-never-become-environment-variables" "bin/check-root-names/env-name.js"
c_group "symmetric" SYMMETRIC_BAD
case_end

case_begin "target-names-reach-a-child-as-arguments-only" "bin/check-root-names/env-name.js"
c_group "target" TARGET_BAD
case_end

case_begin "exception-frees-one-form-of-one-file" "bin/check-root-names/env-name.js"
c_exception_scope
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
