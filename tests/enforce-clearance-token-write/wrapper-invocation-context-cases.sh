#!/usr/bin/env bash
# tests/enforce-clearance-token-write/wrapper-invocation-context-cases.sh
# Tests: bin/request-off-mode-clearance, bin/request-off-clearance
# Tags: anti-cheat, off-clearance, clearance-token, wrapper, delegation, cwd, argv, residue, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap: a real user pasting the invitation from their project directory, where the cwd is a
# real worktree and the sibling minter is the installed one; see
# tests/TL3-hook-clearance-token-write.sh, gap-checked by bin/check-verification-gate.sh.

set -u

# #1821: the invitation names the RE-SPELLED wrapper, so everything the minter reads out of its
# INVOCATION CONTEXT — not out of its arguments — must survive the extra hop. The sibling
# wrapper-equivalence-cases.sh pins arguments and verdicts with a session id supplied by the
# environment; this file pins the three context properties that suite cannot see:
#   W  the cwd is not changed before delegating (the minter resolves its session id from
#      ./WORKTREE_NOTES.md, so a `cd` in the wrapper silently changes WHO the token is for)
#   D  a delegation target that is missing or cannot be exec'd fails loudly and mints nothing
#   Z  a genuinely EMPTY argv (E1-E3 there pass an empty STRING, which is one argument)

SEC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$(cd "$SEC_DIR/../.." && pwd)"
MINTER_ABS="$AGENTS_DIR/bin/request-off-clearance"
WRAPPER_ABS="$AGENTS_DIR/bin/request-off-mode-clearance"

# shellcheck source=tests/lib/request-off-clearance-harness.sh
. "$AGENTS_DIR/tests/lib/request-off-clearance-harness.sh"

if [ -x "$WRAPPER_ABS" ] && [ -x "$MINTER_ABS" ]; then
    pass "C0 both entrypoints exist and are executable"
else
    fail "C0 both entrypoints must exist and be executable (wrapper=$WRAPPER_ABS minter=$MINTER_ABS)"
    offclr_report
fi

# Paths, nonces and timestamps differ per run by design; anything else differing between the
# two entrypoints is a real divergence.
norm() { printf '%s' "$1" | sed -e "s#$2#@DIR@#g" -e 's#[0-9a-f]\{12,\}#@NONCE@#g' \
    -e 's#[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9:]*Z#@TS@#g'; }

echo "=== W: the wrapper delegates from the caller's cwd, not from its own directory ==="
# Every case in wrapper-equivalence-cases.sh pins SESSION_ID, so a wrapper that chdir'd before
# exec would pass all of them. The minter's LAST session-id source is
# "${WORKTREE_PATH:-$PWD}/WORKTREE_NOTES.md" (bin/request-off-clearance:67), so with the env
# vars gone the cwd alone decides the token's OWNER and therefore its FILENAME. That makes the
# minted filename a direct, load-bearing readout of the cwd the delegation ran in.
CWD_SID="cwdownersid"
ALLOW="$(allow_stub 'legitimate workflow bug')"

# cwd_probe <binary> -> sets CW_RC / CW_TOKENS / CW_NAMES / CW_IO
cwd_probe() {
    local bin="$1" tmp tn proj f
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    proj=$(make_tmp)
    printf 'Session-ID: %s\n' "$CWD_SID" > "$proj/WORKTREE_NOTES.md"
    OFFCLR_REQ="$bin"; REQ_SID=""; REQ_CWD="$proj"
    run_req "$tn" "$ALLOW" --target workflow --category trivial-change --detail "cwd transparency probe"
    CW_RC="$RC"; CW_TOKENS="$(token_count "$tmp")"
    CW_NAMES=""
    for f in "$tmp"/*.off-clearance; do
        [ -e "$f" ] || continue
        CW_NAMES="${CW_NAMES}$(basename "$f") "
    done
    CW_IO="$(norm "$OUT" "$tn")@@ERR@@$(norm "$ERR" "$tn")"
    rm -r -f "$tmp" "$proj" 2>/dev/null || true
}

cwd_probe "$MINTER_ABS"
M_RC="$CW_RC"; M_TOKENS="$CW_TOKENS"; M_NAMES="$CW_NAMES"; M_IO="$CW_IO"
cwd_probe "$WRAPPER_ABS"
W_RC="$CW_RC"; W_TOKENS="$CW_TOKENS"; W_NAMES="$CW_NAMES"; W_IO="$CW_IO"
OFFCLR_REQ="$MINTER_ABS"

# W-pre: the reference side. Without a minter that genuinely resolved its session id out of the
# cwd, W1 would be comparing two identical "session id unresolvable" failures and prove nothing.
if [ "$M_RC" = "0" ] && [ "$M_TOKENS" = "1" ] && [ "$M_NAMES" = "$CWD_SID.off-clearance " ]; then
    pass "W-pre the direct minter resolved its session id from the cwd's WORKTREE_NOTES.md (minted $M_NAMES)"
else
    fail "W-pre the direct minter did not resolve the cwd's session id (rc=$M_RC tokens=$M_TOKENS names='$M_NAMES') — W1/W2 below would compare two failures"
fi

if [ "$W_RC" = "$M_RC" ] && [ "$W_NAMES" = "$M_NAMES" ] && [ "$W_TOKENS" = "$M_TOKENS" ]; then
    pass "W1 the wrapper minted the same token for the same cwd-derived owner (rc=$W_RC, $W_NAMES)"
else
    fail "W1 the wrapper changed the cwd before delegating: rc=$W_RC tokens=$W_TOKENS names='$W_NAMES' vs minter rc=$M_RC tokens=$M_TOKENS names='$M_NAMES'"
fi
# The absolute value as well as the equality: a wrapper AND a minter that both resolved some
# other owner would agree with each other while writing a token for the wrong session.
if [ "$W_NAMES" = "$CWD_SID.off-clearance " ]; then
    pass "W1b the token the wrapper minted is owned by the cwd's session id, not by any other"
else
    fail "W1b the wrapper minted '$W_NAMES', expected '$CWD_SID.off-clearance' — the delegation ran under a different owner"
fi
if [ "$W_IO" = "$M_IO" ]; then
    pass "W2 wrapper and minter emit identical stdout and stderr from the same cwd"
else
    fail "W2 output differs from the same cwd: wrapper='$(printf '%.220s' "$W_IO")' vs minter='$(printf '%.220s' "$M_IO")'"
fi

echo ""
echo "=== D: the sibling minter is missing, or present but not executable ==="
# The wrapper is `exec <sibling> "$@"` and owns no diagnostic of its own, so what a user sees
# when the delegation target is broken is whatever bash says. MEASURED, not assumed: the shape
# of the message is bash's, and this pins the properties that matter — loud, non-zero, and no
# token. See the SOURCE OBSERVATION note at the foot of this file.

# broken_probe <absent|nonexec> -> sets D_RC / D_OUT / D_ERR / D_TOKENS / D_SHAPE
broken_probe() {
    local shape="$1" cfg outf errf
    cfg=$(make_tmp)
    mkdir -p "$cfg/bin" "$cfg/plans"
    cp "$WRAPPER_ABS" "$cfg/bin/request-off-mode-clearance"
    chmod +x "$cfg/bin/request-off-mode-clearance"
    D_SHAPE="absent"
    if [ "$shape" = "nonexec" ]; then
        printf '%s\n' '#!/usr/bin/env bash' 'echo DELEGATED-ANYWAY' > "$cfg/bin/request-off-clearance"
        chmod 000 "$cfg/bin/request-off-clearance" 2>/dev/null || true
        if [ -x "$cfg/bin/request-off-clearance" ]; then
            # Git Bash / MSYS2 reports every existing file as executable, so `chmod 000` cannot
            # produce a non-executable regular file on this host (the same limitation the
            # harness documents for its codex-free PATH). A directory at the sibling's path is
            # the portable "the path exists and cannot be exec'd" shape, and it exercises the
            # same wrapper branch: exec fails and nothing downstream runs.
            rm -f "$cfg/bin/request-off-clearance"
            mkdir -p "$cfg/bin/request-off-clearance"
            D_SHAPE="present-but-not-executable (directory; chmod is a no-op on this host)"
        else
            D_SHAPE="present-but-not-executable (chmod 000)"
        fi
    fi
    outf="$cfg/.stdout"; errf="$cfg/.stderr"
    ( cd "$cfg" && env -u SESSION_ID -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        -u WORKTREE_PATH -u AGENTS_CONFIG_DIR "PATH=$OFFCLR_CLEAN_PATH" \
        "WORKFLOW_PLANS_DIR=$cfg/plans" "CLAUDE_WORKFLOW_DIR=$cfg/plans" \
        "AGENTS_CONFIG_DIR=$cfg" "SESSION_ID=brokensid" \
        "$OFFCLR_RWT" 30 bash "$cfg/bin/request-off-mode-clearance" \
            --target workflow --category trivial-change --detail "broken delegation probe" \
    ) >"$outf" 2>"$errf"
    D_RC=$?
    D_OUT="$(cat "$outf" 2>/dev/null)"; D_ERR="$(cat "$errf" 2>/dev/null)"
    # Counted across the WHOLE fixture, not just the workflow dir: a token written anywhere
    # under a fixture whose examination never happened is an unapproved authorization.
    D_TOKENS="$(find "$cfg" -name '*.off-clearance*' 2>/dev/null | wc -l | tr -d ' ')"
    rm -r -f "$cfg" 2>/dev/null || true
}

assert_broken() {  # <label> <absent|nonexec>
    local label="$1"
    broken_probe "$2"
    if [ "$D_RC" != "0" ]; then
        pass "$label-rc the wrapper failed loudly instead of exiting 0 (rc=$D_RC, shape: $D_SHAPE)"
    else
        fail "$label-rc the wrapper exited 0 with a broken delegation target (shape: $D_SHAPE) — the caller would read that as a granted clearance"
    fi
    if [ -n "$D_ERR" ]; then
        pass "$label-err a diagnostic reached stderr: '$(printf '%.100s' "$D_ERR")'"
    else
        fail "$label-err nothing was written to stderr — the failure is silent (rc=$D_RC, stdout='$(printf '%.100s' "$D_OUT")')"
    fi
    # The message must NAME the thing that is broken; "line 15: ..." alone would leave the
    # caller with no idea which file to look for.
    case "$D_ERR" in
        *request-off-clearance*) pass "$label-name the diagnostic names the sibling minter it could not run" ;;
        *) fail "$label-name the diagnostic does not name the sibling minter: '$(printf '%.160s' "$D_ERR")'" ;;
    esac
    if [ -z "$D_OUT" ]; then
        pass "$label-out stdout is empty — no verdict-shaped text a caller could mistake for an ALLOW"
    else
        fail "$label-out stdout was not empty: '$(printf '%.160s' "$D_OUT")'"
    fi
    if [ "$D_TOKENS" = "0" ]; then
        pass "$label-residue no clearance token, claim or intermediate was left anywhere in the fixture"
    else
        fail "$label-residue $D_TOKENS token-shaped file(s) survived a delegation that never reached an examiner"
    fi
}
assert_broken "D1 missing sibling" absent
assert_broken "D2 unrunnable sibling" nonexec

echo ""
echo "=== Z: a genuinely EMPTY argv, not an empty-string argument ==="
# E1-E3 in wrapper-equivalence-cases.sh pass '' — ARGC=1. `"$@"` with nothing in it is a
# different expansion, and a wrapper written `exec ... "$*"` or `exec ... "${1:-}"` passes E3
# while turning zero arguments into one empty one here.

# Z-pre: prove the invocation below really carries zero arguments, with the paired contrast
# that the probe CAN see the difference — otherwise Z1 could be reporting on ARGC=1 all along.
Z_CFG=$(make_tmp)
mkdir -p "$Z_CFG/bin"
cp "$WRAPPER_ABS" "$Z_CFG/bin/request-off-mode-clearance"
printf '%s\n' '#!/usr/bin/env bash' 'printf "ARGC=%s\n" "$#"' \
    'for a in "$@"; do printf "ARG<%s>\n" "$a"; done' > "$Z_CFG/bin/request-off-clearance"
chmod +x "$Z_CFG/bin/request-off-mode-clearance" "$Z_CFG/bin/request-off-clearance"
Z_ZERO="$( cd "$Z_CFG" && "$OFFCLR_RWT" 20 bash "$Z_CFG/bin/request-off-mode-clearance" 2>&1 )"
Z_ONE="$( cd "$Z_CFG" && "$OFFCLR_RWT" 20 bash "$Z_CFG/bin/request-off-mode-clearance" '' 2>&1 )"
rm -r -f "$Z_CFG" 2>/dev/null || true
if [ "$Z_ZERO" = "ARGC=0" ]; then
    pass "Z-pre the wrapper hands the sibling a genuinely empty argv (ARGC=0)"
else
    fail "Z-pre the zero-argument invocation delivered '$Z_ZERO', not 'ARGC=0' — Z1/Z2 below are not about zero argv"
fi
if [ "$Z_ONE" = "ARGC=1
ARG<>" ]; then
    pass "Z-pre2 the same probe reports ARGC=1 for an empty-string argument (it can tell the two apart)"
else
    fail "Z-pre2 the empty-string contrast delivered '$Z_ONE' — the probe cannot distinguish zero argv from one empty argument"
fi

# run_zero <binary> -> sets Z_RC / Z_IO
run_zero() {
    local bin="$1" tmp tn
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    OFFCLR_REQ="$bin"; REQ_SID="zerosid"
    run_req "$tn" "$ALLOW"
    Z_RC="$RC"; Z_IO="$(norm "$OUT" "$tn")@@ERR@@$(norm "$ERR" "$tn")"
    Z_TOKENS="$(token_count "$tmp")"
    rm -r -f "$tmp" 2>/dev/null || true
}
run_zero "$MINTER_ABS"; ZM_RC="$Z_RC"; ZM_IO="$Z_IO"; ZM_N="$Z_TOKENS"
run_zero "$WRAPPER_ABS"; ZW_RC="$Z_RC"; ZW_IO="$Z_IO"; ZW_N="$Z_TOKENS"
OFFCLR_REQ="$MINTER_ABS"

# Absolute expectation first (bin/request-off-clearance:47-49: an unset --target is a usage
# error, exit 2). Equality alone would be satisfied by two entrypoints that both exit 0.
if [ "$ZM_RC" = "2" ] && [ "$ZM_N" = "0" ]; then
    pass "Z-pre3 the direct minter rejects a zero-argument invocation with a usage error (rc=2, no token)"
else
    fail "Z-pre3 the direct minter gave rc=$ZM_RC tokens=$ZM_N on zero argv, expected rc=2 and no token — the reference side of Z1 is itself wrong"
fi
if [ "$ZW_RC" = "$ZM_RC" ] && [ "$ZW_N" = "$ZM_N" ]; then
    pass "Z1 the wrapper's zero-argv exit status and token count match the minter's (rc=$ZW_RC, tokens=$ZW_N)"
else
    fail "Z1 wrapper rc=$ZW_RC tokens=$ZW_N vs minter rc=$ZM_RC tokens=$ZM_N on a zero-argument invocation"
fi
if [ "$ZW_IO" = "$ZM_IO" ]; then
    pass "Z2 wrapper and minter emit identical stdout and stderr on zero argv"
else
    fail "Z2 zero-argv output differs: wrapper='$(printf '%.220s' "$ZW_IO")' vs minter='$(printf '%.220s' "$ZM_IO")'"
fi

# SOURCE OBSERVATION (not a defect this suite fixes): the wrapper emits no diagnostic of its
# own for a broken delegation target — D1/D2 pass on bash's `exec` message, which does name the
# missing path. Adding a wrapper-owned message would cost the `exec` transparency that
# wrapper-signal-transparency-cases.sh pins, so the measured behaviour is pinned as-is.

offclr_report
