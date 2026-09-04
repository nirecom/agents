#!/usr/bin/env bash
# Tests: hooks/block-capture-echo/shape.js, hooks/block-capture-echo/remedy.js, hooks/lib/unrecognized-exec-check.js, hooks/lib/egress-command-check.js, hooks/lib/display-only-mask.js
# Tags: mutation-probe, capture-echo-guard, scratchpad-allow, regex, security, scope:issue-specific, pwsh-not-required
# Serial: no

# Round 13, C10 — mutation evidence for the regex constants #2170 introduced or leans
# on. Each row neuters exactly ONE constant in a COPY of its module and asserts the
# probe input flips while a sibling input keeps its verdict, so a row cannot pass by
# breaking the whole module (a MODULE_MISSING / ERROR: verdict fails both halves).
# Harness: tests/feature-2170-regex-mutation/mutate.js.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export AGENTS_DIR
export AGENTS_CONFIG_DIR="$AGENTS_DIR"
MUT="$AGENTS_DIR/tests/feature-2170-regex-mutation/mutate.js"
command -v node >/dev/null 2>&1 || exit 77
[ -f "$MUT" ] || exit 77

PASS=0
FAIL=0
ROWS=0

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "PASS: $name"; PASS=$((PASS + 1))
    else
        echo "FAIL: $name — want=$want got=$got"; FAIL=$((FAIL + 1))
    fi
}

# A real allow-SSOT entry, so remedy.js reaches its matched (argument-rendering) branch.
ENTRY='bash "$AGENTS_CONFIG_DIR/bin/workflow/record-complexity-and-skip"'

judge() { # <module> <fragment> <predicate> <input>
    node "$MUT" "$1" "$2" "$3" "$4"
}

# id~module~fragment~predicate~input~baseline~mutated~control-input~control-verdict
while IFS='~' read -r id mod frag pred inp base mutv ctl ctlv; do
    [ -z "$id" ] && continue
    case "$id" in \#*) continue ;; esac
    ROWS=$((ROWS + 1))
    inp="${inp//@E@/$ENTRY}"
    ctl="${ctl//@E@/$ENTRY}"

    # Precondition: the UNMUTATED module gives the baseline verdict. Without it a
    # "flip" could be a probe input that never had the baseline verdict at all.
    assert_eq "$id-0-baseline" "$base" "$(judge "$mod" --none "$pred" "$inp")"
    # The kill: neutering this one constant changes THIS input's verdict.
    assert_eq "$id-1-mutant-flips-probe" "$mutv" "$(judge "$mod" "$frag" "$pred" "$inp")"
    # The survivor: a sibling input is untouched, so the module still works.
    assert_eq "$id-2-mutant-spares-sibling" "$ctlv" "$(judge "$mod" "$frag" "$pred" "$ctl")"
done <<'MUT_CASES'
M01-shape-NAME_RE~hooks/block-capture-echo/shape.js~([A-Za-z_][A-Za-z0-9_]*)=~shape~X=$(a); echo "$X"~true~false~ls~false
M02-shape-subst-paren~hooks/block-capture-echo/shape.js~^\$\(~shape~X=$(a); echo "$X"~true~false~X="$(a)"; echo "$X"~true
M03-shape-subst-quoted~hooks/block-capture-echo/shape.js~^"\$\(~shape~X="$(a)"; echo "$X"~true~false~X=$(a); echo "$X"~true
M04-shape-subst-backtick~hooks/block-capture-echo/shape.js~^`~shape~X=`a`; echo "$X"~true~false~X=$(a); echo "$X"~true
M05-remedy-SAFE_ARG_RE~hooks/block-capture-echo/remedy.js~^[A-Za-z0-9._/=:@,+-]+$~remedy~@E@ --target outline~bare~scratchpad~@E@~bare
M06-remedy-SECRET_NAME_RE~hooks/block-capture-echo/remedy.js~(?:token|secret|password|passwd|api[_-]?key|apikey|credential|private[_-]?key)~remedy~@E@ --token=hunter2~scratchpad~bare~@E@ --target ghp_TESTFIXTUREAAAABBBBCCCCDDDDEEEE1234~scratchpad
M07-remedy-OPAQUE_TOKEN_RE~hooks/block-capture-echo/remedy.js~^[A-Za-z0-9_+-]{20,}$~remedy~@E@ --target ghp_TESTFIXTUREAAAABBBBCCCCDDDDEEEE1234~scratchpad~bare~@E@ --token=hunter2~scratchpad
M08-exec-INTERPRETER_RE~hooks/lib/unrecognized-exec-check.js~(?:node|nodejs|python|python3|npx|pnpx|bunx|ruby|perl|source)~unrecognized~node x.js~true~false~eval "$CMD"~true
M09-exec-SUBSHELL_C_RE~hooks/lib/unrecognized-exec-check.js~(?:ba|z|k|da)?sh\s+-[a-zA-Z]*c~unrecognized~sh -c "x"~true~false~eval "$CMD"~true
M10-exec-DOT_SOURCE_RE~hooks/lib/unrecognized-exec-check.js~\\.\\s+\\S~unrecognized~. /etc/profile~true~false~eval "$CMD"~true
M11-exec-DIRECT_EXEC_RE~hooks/lib/unrecognized-exec-check.js~(?:\\.{1,2})?/[^\\s;|&]~unrecognized~./evil~true~false~eval "$CMD"~true
M12-exec-PWSH_NAME~hooks/lib/unrecognized-exec-check.js~(?:pwsh|powershell)(?:\\.exe)?~unrecognized~pwsh x.ps1~true~false~eval "$CMD"~true
M13-exec-BARE_EXE_RE~hooks/lib/unrecognized-exec-check.js~[^\\s;|&'\"]*\\.exe~unrecognized~evil.exe~true~false~eval "$CMD"~true
M14-exec-EVAL_RE~hooks/lib/unrecognized-exec-check.js~eval(?=\\s|$)~unrecognized~eval "$CMD"~true~false~node x.js~true
M15-exec-ALT_SHELL_NAME~hooks/lib/unrecognized-exec-check.js~(?:zsh|dash|ksh)(?:\\.exe)?~unrecognized~zsh x.sh~true~false~eval "$CMD"~true
M16-egress-EGRESS_CMD_RE~hooks/lib/egress-command-check.js~(?:curl|curl\.exe|wget|scp|sftp|ssh|telnet|nc|ncat|netcat)~egress~curl https://x~true~false~gh auth token~true
M17-egress-GH_CREDENTIAL_RE~hooks/lib/egress-command-check.js~gh(?:\.exe)?\s+(?:auth\s+token|secret)~egress~gh auth token~true~false~curl https://x~true
M18-egress-RSYNC_REMOTE_RE~hooks/lib/egress-command-check.js~rsync(?=\s)[\s\S]*\s\S+@\S+:~egress~rsync -a /a u@h:/b~true~false~curl https://x~true
M19-mask-DISPLAY_ONLY_RE~hooks/lib/display-only-mask.js~^\s*(?:echo|printf)(?:\.exe)?(?=\s)~mask~echo hi~true~false~ls -la~false
M20-mask-SUBSTITUTION_RE~hooks/lib/display-only-mask.js~\$\(|`~mask~echo `x`~false~true~echo hi~true
M21-mask-SEGMENT_SPLIT_RE~hooks/lib/display-only-mask.js~([;|&()\n])~mask~ls; echo hi~true~false~echo hi~true
MUT_CASES

# --- Harness self-checks: the probes must be able to fail --------------------------
assert_eq "MX-1-unknown-fragment-is-reported" "FRAGMENT_NOT_FOUND" \
    "$(judge hooks/block-capture-echo/shape.js 'NO_SUCH_FRAGMENT_XYZ' shape 'ls')"
assert_eq "MX-2-missing-module-is-reported" "MODULE_MISSING" \
    "$(judge hooks/no-such-module.js --none shape 'ls')"
assert_eq "MX-3-every-row-ran" "21" "$ROWS"

echo ""
echo "regex-mutation: PASS=$PASS FAIL=$FAIL ROWS=$ROWS"
exit "$FAIL"
