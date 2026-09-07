#!/usr/bin/env bash
# tests/enforce-clearance-token-write/wrapper-equivalence-cases.sh
# Tests: bin/request-off-mode-clearance, bin/request-off-clearance, hooks/lib/off-clearance-invocation.js
# Tags: anti-cheat, off-clearance, clearance-token, spelling, wrapper, delegation, arg-injection, mint, idempotency, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap: a real user pasting the re-spelled invitation into a real session; see
# tests/TL3-hook-clearance-token-write.sh, gap-checked by bin/check-verification-gate.sh.
# #1821: the invitation is re-spelled so the mention gate cannot fire on it, which is only
# safe if the SSOT names a real program and that program IS the minter. B* binds the SSOT
# value to the file under test; E1-E3 compare argument handling; E4-E6 compare mint, REJECT
# and re-invocation; V1-V3 execute the SSOT string itself, unmodified, as a shell command.

set -u

SEC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$(cd "$SEC_DIR/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
EXPECTED_WRAPPER_REL="bin/request-off-mode-clearance"
MINTER_ABS="$AGENTS_DIR/bin/request-off-clearance"

# Sourced FIRST, before any counting: the harness initialises its own PASS/FAIL, so
# sourcing it later would silently discard everything asserted above it.
# shellcheck source=tests/lib/request-off-clearance-harness.sh
. "$AGENTS_DIR/tests/lib/request-off-clearance-harness.sh"

echo "=== B: the SSOT invitation is bound to the file this suite actually runs ==="
# The invitation is a STRING; nothing else in the tree forces it to name a program that
# exists. Deriving the binary under test FROM that string is what makes every E* case
# below a statement about the command users are told to run, not about a path this test
# happened to hardcode. B3 then pins the derived path to the expected spelling, so a
# silently re-pointed SSOT cannot quietly retarget the whole suite.
SSOT_VALUE="$("$OFFCLR_RWT" 10 node -e "const m=require(process.argv[1]+'/hooks/lib/off-clearance-invocation.js');process.stdout.write(String(m.OFF_CLEARANCE_INVOCATION||''))" "$_AGENTS_DIR_NODE" 2>/dev/null)"
SSOT_REL="$("$OFFCLR_RWT" 10 node -e "const m=String(process.argv[1]).match(/bin[/][A-Za-z0-9._-]+/);process.stdout.write(m?m[0]:'')" "$SSOT_VALUE" 2>/dev/null)"

if [ -n "$SSOT_VALUE" ] && [ -n "$SSOT_REL" ]; then
    pass "B1 the SSOT invitation resolves to a repo path ($SSOT_REL)"
    WRAPPER_REL="$SSOT_REL"
else
    fail "B1 no bin/<script> path could be derived from OFF_CLEARANCE_INVOCATION ('${SSOT_VALUE:-<unset>}') — falling back to $EXPECTED_WRAPPER_REL so the E* cases still report"
    WRAPPER_REL="$EXPECTED_WRAPPER_REL"
fi
WRAPPER_ABS="$AGENTS_DIR/$WRAPPER_REL"

if [ "$WRAPPER_REL" = "$EXPECTED_WRAPPER_REL" ]; then
    pass "B3 the SSOT-derived path is the expected re-spelled entrypoint"
else
    fail "B3 the SSOT names '$WRAPPER_REL' but the re-spelled entrypoint is '$EXPECTED_WRAPPER_REL' — the invitation and the shipped script have drifted"
fi

if [ ! -f "$WRAPPER_ABS" ]; then
    fail "B2 $WRAPPER_REL does not exist — the invitation would point at nothing"
    for m in "E1 validation-rejection equivalence" "E2 argument transparency" "E3 empty-argument transparency" \
             "E4 successful-mint equivalence" "E5 rejected-examination equivalence" "E6 re-invocation equivalence"; do
        fail "$m untestable without $WRAPPER_REL"
    done
    offclr_report
fi
if [ -x "$WRAPPER_ABS" ]; then pass "B2 $WRAPPER_REL exists and is executable"
else fail "B2 $WRAPPER_REL exists but is not executable"; fi

echo ""
echo "=== E1-E3: argument handling is identical on both entrypoints ==="
# E1 is the cheap one: early validation rejection. On its own it is satisfied by a wrapper
# that ignores its arguments and exits 2, which is why E2/E3 exist. The minter's unknown-
# argument branch echoes the argument back verbatim ("ERROR: unknown argument: $1"), so it
# is an exact probe: a wrapper written as `$MINTER $*` word-splits and glob-expands, and an
# argument carrying spaces and a `*` comes back mangled. Only `exec ... "$@"` survives.
W_OUT="$("$OFFCLR_RWT" 20 bash "$WRAPPER_ABS" --target workflow --category x --detail y 2>&1)"; W_RC=$?
M_OUT="$("$OFFCLR_RWT" 20 bash "$MINTER_ABS" --target workflow --category x --detail y 2>&1)"; M_RC=$?
if [ "$W_RC" = "$M_RC" ] && [ "$W_OUT" = "$M_OUT" ]; then
    pass "E1 wrapper and minter agree on a rejected invocation (rc=$W_RC, identical output)"
else
    fail "E1 wrapper/minter diverge: wrapper rc=$W_RC out='$(printf '%.120s' "$W_OUT")' vs minter rc=$M_RC out='$(printf '%.120s' "$M_OUT")'"
fi

probe_arg() {  # <label> <argument>
    local label="$1" arg="$2" w_out w_rc m_out m_rc
    w_out="$("$OFFCLR_RWT" 20 bash "$WRAPPER_ABS" "$arg" 2>&1)"; w_rc=$?
    m_out="$("$OFFCLR_RWT" 20 bash "$MINTER_ABS" "$arg" 2>&1)"; m_rc=$?
    if [ "$w_rc" = "$m_rc" ] && [ "$w_out" = "$m_out" ]; then
        pass "$label (rc=$w_rc, argument reached the minter byte-for-byte)"
    else
        fail "$label: wrapper rc=$w_rc out='$(printf '%.160s' "$w_out")' vs minter rc=$m_rc out='$(printf '%.160s' "$m_out")'"
    fi
}
probe_arg "E2 an argument with spaces and a glob passes through unchanged" '--bogus a b*c "q" $HOME'
probe_arg "E3 an empty-string argument survives" ''
probe_arg "E3b an argument that looks like a flag bundle survives" '-abc --x=1'

echo ""
echo "=== E4-E6: the authorization path itself, end to end, through both entrypoints ==="
# Everything past argument validation — the examiner call, the nonce, the audit append,
# the token write — only runs on a VALID invocation, and that is the whole reason the
# invitation exists. Paths, nonces and timestamps differ per run by design; anything else
# differing between the two entrypoints is a real divergence. stderr is compared as well
# as stdout: a wrapper that swallowed or duplicated diagnostics would otherwise pass.
normalize() { printf '%s' "$1" | sed -e "s#$2#@DIR@#g" -e 's#[0-9a-f]\{12,\}#@NONCE@#g' -e 's#[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9:]*Z#@TS@#g'; }

# run_case <binary> <stub-body> <repeats> -> "<rc>|<token_count>|<norm stdout>@@ERR@@<norm stderr>"
# <repeats> = 2 exercises re-invocation inside ONE fixture dir, which is the only place a
# second mint could double-write, leave a stale intermediate, or fail on an existing token.
run_case() {
    local bin="$1" stub="$2" reps="$3" tmp tn n i
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    for ((i = 0; i < reps; i++)); do
        OFFCLR_REQ="$bin"
        REQ_SID="eqsid"
        run_req "$tn" "$stub" --target workflow --category trivial-change --detail "one-line typo fix"
    done
    n="$(token_count "$tmp")"
    printf '%s|%s|%s@@ERR@@%s' "$RC" "$n" "$(normalize "$OUT" "$tn")" "$(normalize "$ERR" "$tn")"
    rm -r -f "$tmp" 2>/dev/null || true
}
# Prefix-based, not `cut`: the payload is multi-line and cut splits fields per LINE, so
# it returned the whole first line of stdout as the "rc" field.
field_rc() { local raw="$1"; printf '%s' "${raw%%|*}"; }
field_n()  { local raw="$1" rest; rest="${raw#*|}"; printf '%s' "${rest%%|*}"; }

compare_case() {  # <label> <stub-body> <repeats> <want-rc> <want-tokens>
    local label="$1" stub="$2" reps="$3" wrc="$4" wn="$5" m w m_rc m_n w_rc w_n
    m="$(run_case "$MINTER_ABS" "$stub" "$reps")"; w="$(run_case "$WRAPPER_ABS" "$stub" "$reps")"
    m_rc="$(field_rc "$m")"; m_n="$(field_n "$m")"
    w_rc="$(field_rc "$w")"; w_n="$(field_n "$w")"
    if [ "$m_rc" = "$wrc" ] && [ "$m_n" = "$wn" ]; then
        pass "$label-pre the minter behaves as specified (rc=$m_rc, tokens=$m_n)"
    else
        fail "$label-pre the minter gave rc=$m_rc tokens=$m_n, want rc=$wrc tokens=$wn — the comparison below would compare two wrong answers"
    fi
    if [ "$w_rc" = "$m_rc" ] && [ "$w_n" = "$m_n" ]; then
        pass "$label-a wrapper matches the minter (rc=$w_rc, tokens=$w_n)"
    else
        fail "$label-a wrapper rc=$w_rc tokens=$w_n vs minter rc=$m_rc tokens=$m_n"
    fi
    if [ "$w" = "$m" ]; then
        pass "$label-b wrapper and minter emit identical stdout and stderr"
    else
        fail "$label-b output differs: wrapper='$(printf '%.220s' "$w")' vs minter='$(printf '%.220s' "$m")'"
    fi
}

compare_case "E4 successful mint" "$(allow_stub 'legitimate workflow bug')" 1 0 1
# E5 — the AUTHORIZATION path. E4 alone cannot distinguish a real examination from a
# wrapper that mints unconditionally: the decisive property is that a REJECT verdict ends
# with a non-zero exit and ZERO tokens on disk, on both entrypoints.
compare_case "E5 rejected examination" "$(reject_stub 'use the sanctioned path')" 1 1 0
# E6 — idempotency (test-design.md Idempotency cases). Running the invitation twice is
# what a real user does when the first token expires, so a second ALLOW must land the same
# single token rather than accumulating one file per attempt.
compare_case "E6 re-invocation" "$(allow_stub 'legitimate workflow bug')" 2 0 1
OFFCLR_REQ="$MINTER_ABS"

echo ""
echo "=== V: the SSOT string is EXECUTED verbatim, exactly as a user would paste it ==="
# B/E run the wrapper by a path PARSED out of the invitation, discarding the rest of the
# string: the `bash ` prefix, the quoting, and the `$AGENTS_CONFIG_DIR` expansion that is
# the only thing making the constant runnable on a user's machine. Re-spelled to
# `bash "$AGENTS_HOME/bin/request-off-mode-clearance"` it would keep every B/E case green
# and be unrunnable for everyone. V* hands the constant to `bash -c` UNMODIFIED.

# run_verbatim <tn> <stub-body> <pin-config:1|0> <arg-string> -> sets RC / OUT / ERR
# AGENTS_CONFIG_DIR is PINNED, not inherited (test-design.md "Config-dependent branches"):
# the live session exports it, so an ambient value would make V* a statement about this
# machine instead of about the string. V3 is the paired negative proving the pin matters.
run_verbatim() {
    local tn="$1" body="$2" pin="$3" args="$4" stubbin outf errf
    local -a envargs
    stubbin=$(make_tmp)
    printf '%s' "$body" > "$stubbin/codex"; chmod +x "$stubbin/codex"
    outf="$stubbin/.stdout"; errf="$stubbin/.stderr"
    envargs=(-u SESSION_ID -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u WORKTREE_PATH
             -u AGENTS_CONFIG_DIR
             "PATH=$stubbin:$OFFCLR_CLEAN_PATH"
             "WORKFLOW_PLANS_DIR=$tn" "CLAUDE_WORKFLOW_DIR=$tn" "SESSION_ID=verbsid")
    [ "$pin" = "1" ] && envargs+=("AGENTS_CONFIG_DIR=$_AGENTS_DIR_NODE")
    ( cd "$stubbin" && env "${envargs[@]}" "$OFFCLR_RWT" 60 bash -c "$SSOT_VALUE $args" ) >"$outf" 2>"$errf"
    RC=$?; OUT="$(cat "$outf" 2>/dev/null)"; ERR="$(cat "$errf" 2>/dev/null)"
    rm -r -f "$stubbin" 2>/dev/null || true
}

VALID_ARGS='--target workflow --category trivial-change --detail "one-line typo fix"'
compare_verbatim() {  # <label> <stub-body> <want-rc> <want-tokens>
    local label="$1" stub="$2" wrc="$3" wn="$4" tmp tn v_rc v_n v_out m_rc m_n m_out
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    run_verbatim "$tn" "$stub" 1 "$VALID_ARGS"
    v_rc="$RC"; v_n="$(token_count "$tmp")"; v_out="$(normalize "$OUT" "$tn")@@ERR@@$(normalize "$ERR" "$tn")"
    rm -r -f "$tmp" 2>/dev/null || true
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    OFFCLR_REQ="$MINTER_ABS"; REQ_SID="verbsid"
    run_req "$tn" "$stub" --target workflow --category trivial-change --detail "one-line typo fix"
    m_rc="$RC"; m_n="$(token_count "$tmp")"; m_out="$(normalize "$OUT" "$tn")@@ERR@@$(normalize "$ERR" "$tn")"
    rm -r -f "$tmp" 2>/dev/null || true
    if [ "$m_rc" = "$wrc" ] && [ "$m_n" = "$wn" ]; then
        pass "$label-pre the minter behaves as specified (rc=$m_rc, tokens=$m_n)"
    else
        fail "$label-pre the minter gave rc=$m_rc tokens=$m_n, want rc=$wrc tokens=$wn — the comparison below would compare two wrong answers"
    fi
    if [ "$v_rc" = "$m_rc" ] && [ "$v_n" = "$m_n" ] && [ "$v_out" = "$m_out" ]; then
        pass "$label-a the verbatim SSOT command matches the minter (rc=$v_rc, tokens=$v_n, identical stdout+stderr)"
    else
        fail "$label-a verbatim rc=$v_rc tokens=$v_n out='$(printf '%.200s' "$v_out")' vs minter rc=$m_rc tokens=$m_n out='$(printf '%.200s' "$m_out")'"
    fi
}
compare_verbatim "V1 verbatim successful mint" "$(allow_stub 'legitimate workflow bug')" 0 1
compare_verbatim "V2 verbatim rejected examination" "$(reject_stub 'use the sanctioned path')" 1 0

# V3 — the paired negative (test-design.md Pattern 4). Without it V1/V2 would still pass if
# the constant hardcoded an absolute path and ignored AGENTS_CONFIG_DIR entirely.
TMP_V3=$(make_tmp); TN_V3=$(node_path "$TMP_V3")
run_verbatim "$TN_V3" "$(allow_stub 'legitimate workflow bug')" 0 "$VALID_ARGS"
if [ "$RC" != "0" ] && [ "$(token_count "$TMP_V3")" = "0" ]; then
    pass "V3 with AGENTS_CONFIG_DIR unset the same string resolves nothing and mints nothing (rc=$RC)"
else
    fail "V3 the SSOT string still ran (rc=$RC, tokens=$(token_count "$TMP_V3")) without AGENTS_CONFIG_DIR — it does not depend on the documented variable, so V1/V2 prove nothing about a user's machine"
fi
rm -r -f "$TMP_V3" 2>/dev/null || true

echo ""
echo "=== V4: argv survives an AGENTS_CONFIG_DIR whose path contains a space ==="
# V1-V3 run in a sandbox whose path has no space, so they cannot tell a correctly quoted
# SSOT from one that word-splits. The wrapper re-execs a sibling by a path built from its
# own location, so a lost quote there splits the PROGRAM path as well as the arguments.
# The stub prints one argument per line inside delimiters: asserting on a joined string
# could not tell one argument containing a space from two arguments.
argv_probe() {  # <config-dir> -> sets RC / OUT
    local cfg="$1" outf
    mkdir -p "$cfg/bin"
    cp "$WRAPPER_ABS" "$cfg/bin/request-off-mode-clearance"
    printf '%s\n' '#!/usr/bin/env bash' 'printf "ARGC=%s\n" "$#"' \
        'for a in "$@"; do printf "ARG<%s>\n" "$a"; done' > "$cfg/bin/request-off-clearance"
    chmod +x "$cfg/bin/request-off-mode-clearance" "$cfg/bin/request-off-clearance"
    outf="$cfg/.out"
    ( cd "$cfg" && env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u SESSION_ID \
        -u WORKTREE_PATH -u AGENTS_CONFIG_DIR "PATH=$OFFCLR_CLEAN_PATH" \
        "WORKFLOW_PLANS_DIR=$cfg/plans" "CLAUDE_WORKFLOW_DIR=$cfg/plans" \
        "AGENTS_CONFIG_DIR=$cfg" \
        "$OFFCLR_RWT" 60 bash -c "$SSOT_VALUE $VALID_ARGS" ) >"$outf" 2>&1
    RC=$?; OUT="$(cat "$outf" 2>/dev/null)"
}
V4_WANT='ARGC=6
ARG<--target>
ARG<workflow>
ARG<--category>
ARG<trivial-change>
ARG<--detail>
ARG<one-line typo fix>'

TMP_V4=$(make_tmp); SPACED="$TMP_V4/cfg dir with spaces"
case "$SPACED" in
    *" "*) pass "V4-fixture the config dir path genuinely contains a space" ;;
    *) fail "V4-fixture no space in '$SPACED' — V4a below would restate V1 and prove nothing" ;;
esac
argv_probe "$SPACED"
if [ "$OUT" = "$V4_WANT" ]; then
    pass "V4a the verbatim SSOT delivers all 6 arguments intact through a spaced config dir"
else
    fail "V4a argv mangled through a spaced AGENTS_CONFIG_DIR (rc=$RC): got '$(printf '%.300s' "$OUT")'"
fi
# The paired control: the identical probe in a space-free dir. If it also fails, V4a is
# reporting a broken probe rather than a quoting defect.
argv_probe "$TMP_V4/nospace"
if [ "$OUT" = "$V4_WANT" ]; then
    pass "V4b the same probe in a space-free config dir delivers the same argv (V4a is about the space)"
else
    fail "V4b the probe itself is broken in a space-free dir (rc=$RC): got '$(printf '%.300s' "$OUT")' — V4a's verdict is not interpretable"
fi
rm -r -f "$TMP_V4" 2>/dev/null || true

offclr_report
