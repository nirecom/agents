#!/usr/bin/env bash
# tests/enforce-clearance-token-write/wrapper-signal-transparency-cases.sh
# Tests: bin/request-off-mode-clearance, bin/request-off-clearance
# Tags: anti-cheat, off-clearance, clearance-token, wrapper, delegation, signal, interrupt, residue, mint, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap: a real Ctrl-C from a real terminal, where the tty sends SIGINT to the whole
# foreground process group rather than to one pid; see tests/TL3-hook-clearance-token-write.sh,
# gap-checked by bin/check-verification-gate.sh.

set -u

# #1821: the invitation tells users to run the RE-SPELLED wrapper, so the wrapper inherits
# the minter's interrupt contract. bin/request-off-mode-clearance is a plain `exec "$@"`
# shim — it replaces its own process image, so there is no extra process layer to swallow a
# signal or to mint after one. S* asserts that observable consequence rather than reading
# the shim: status, on-disk residue, and descendant fate must all match the direct minter.

SEC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$(cd "$SEC_DIR/../.." && pwd)"
MINTER_ABS="$AGENTS_DIR/bin/request-off-clearance"
WRAPPER_ABS="$AGENTS_DIR/bin/request-off-mode-clearance"

# shellcheck source=tests/lib/request-off-clearance-harness.sh
. "$AGENTS_DIR/tests/lib/request-off-clearance-harness.sh"

if [ -x "$WRAPPER_ABS" ] && [ -x "$MINTER_ABS" ]; then
    pass "S0 both entrypoints exist and are executable"
else
    fail "S0 both entrypoints must exist and be executable (wrapper=$WRAPPER_ABS minter=$MINTER_ABS)"
    offclr_report
fi

# A BLOCKING examiner is the only fixture that puts the minter in the exact state a user
# interrupts: past argument validation, inside the examination, before any token is written.
# The stub ticks a heartbeat file so "did the descendant outlive the signal?" is observable
# without ps, which reports MSYS and Win32 pids in different namespaces on this host.
blocking_stub() {  # <heartbeat-file>
    printf '#!/usr/bin/env bash\ni=0\nwhile [ $i -lt 200 ]; do i=$((i+1)); printf %%s "$i" > %s; sleep 0.2; done\n' "$(printf '%q' "$1")"
}

# run_signalled <entrypoint> -> sets SIG_RC, SIG_TOKENS, SIG_CLAIMS, SIG_TMPRES,
#                                    SIG_LEFTOVERS, SIG_DESCENDANT (lived|died|never-ran)
run_signalled() {
    local bin="$1" tmp tn stubbin hb pid at_kill later waited
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    stubbin=$(make_tmp); hb="$stubbin/hb"
    blocking_stub "$hb" > "$stubbin/codex"; chmod +x "$stubbin/codex"
    ( cd "$stubbin" && env -u SESSION_ID -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        -u WORKTREE_PATH -u AGENTS_CONFIG_DIR \
        "PATH=$stubbin:$OFFCLR_CLEAN_PATH" \
        "WORKFLOW_PLANS_DIR=$tn" "CLAUDE_WORKFLOW_DIR=$tn" \
        "AGENTS_CONFIG_DIR=$OFFCLR_AGENTS_NODE" "SESSION_ID=sigsid" \
        bash "$bin" --target workflow --category trivial-change --detail "signal transparency probe" \
    ) >"$stubbin/.stdout" 2>"$stubbin/.stderr" &
    pid=$!
    # Wait until the examination is genuinely under way: the heartbeat must have ticked,
    # otherwise the case degenerates into "a signal killed a process that had not started
    # working yet" and proves nothing about the interrupt point. Polled, not slept for a
    # fixed budget — a fixed wait turns ordinary slow scheduling into a spurious
    # "the examiner never started", while the ceiling still catches a genuine hang.
    SIG_STARTED=0; waited=0
    while [ "$waited" -lt 100 ]; do
        if [ -s "$hb" ]; then SIG_STARTED=1; break; fi
        sleep 0.1
        waited=$((waited + 1))
    done
    kill -TERM "$pid" 2>/dev/null
    wait "$pid"; SIG_RC=$?
    at_kill="$(cat "$hb" 2>/dev/null || echo 0)"
    sleep 2
    later="$(cat "$hb" 2>/dev/null || echo 0)"
    if [ "$SIG_STARTED" = "0" ]; then SIG_DESCENDANT="never-ran"
    elif [ "$later" != "$at_kill" ]; then SIG_DESCENDANT="lived"
    else SIG_DESCENDANT="died"; fi
    SIG_TOKENS="$(token_count "$tmp")"; SIG_CLAIMS="$(claim_count "$tmp")"
    SIG_TMPRES="$(tmpres_count "$tmp")"
    SIG_LEFTOVERS="$(ls -A "$tmp" 2>/dev/null | tr '\n' ' ')"
    rm -r -f "$tmp" "$stubbin" 2>/dev/null || true
}

echo "=== S1-S3: SIGTERM during the examination, wrapper vs direct minter ==="
run_signalled "$MINTER_ABS"
M_RC="$SIG_RC"; M_DESC="$SIG_DESCENDANT"; M_STARTED="$SIG_STARTED"
M_RESIDUE="$SIG_TOKENS/$SIG_CLAIMS/$SIG_TMPRES"; M_LEFT="$SIG_LEFTOVERS"
run_signalled "$WRAPPER_ABS"
W_RC="$SIG_RC"; W_DESC="$SIG_DESCENDANT"; W_STARTED="$SIG_STARTED"
W_RESIDUE="$SIG_TOKENS/$SIG_CLAIMS/$SIG_TMPRES"; W_LEFT="$SIG_LEFTOVERS"

# S1-pre: without this the whole file is vacuous — a stub that never ran would make every
# comparison below "two identical nothings".
if [ "$M_STARTED" = "1" ] && [ "$W_STARTED" = "1" ]; then
    pass "S1-pre both runs were interrupted mid-examination (the examiner had started on each)"
else
    fail "S1-pre the examiner never started (minter=$M_STARTED wrapper=$W_STARTED) — the signal did not land mid-examination and S1-S3 assert nothing"
fi

# 143 = 128 + SIGTERM. Asserting the absolute value as well as the equality is what stops a
# wrapper that traps the signal and exits 0 from passing by making the minter agree with it.
if [ "$M_RC" = "143" ]; then
    pass "S1-pre2 the direct minter reports the signal in its exit status (rc=143 = 128+SIGTERM)"
else
    fail "S1-pre2 the direct minter exited $M_RC on SIGTERM, expected 143 — the reference side of S1 is itself wrong"
fi
if [ "$W_RC" = "$M_RC" ]; then
    pass "S1 the wrapper's termination status is identical to the minter's (rc=$W_RC)"
else
    fail "S1 wrapper rc=$W_RC but minter rc=$M_RC — the exec shim is not signal-transparent"
fi

# S2 — the security-relevant half. An interrupt must never leave a usable token, a claimed
# token, or a half-written .mint.tmp / .consuming-*.tmp behind: any of those is an OFF-mode
# authorization that no examiner ever approved.
if [ "$W_RESIDUE" = "0/0/0" ]; then
    pass "S2 the interrupted wrapper left no token, no claim and no intermediate file (fixture dir: '${W_LEFT:-empty}')"
else
    fail "S2 the interrupted wrapper left residue tokens/claims/tmp=$W_RESIDUE in the fixture dir ('$W_LEFT') — an unapproved authorization survived the interrupt"
fi
if [ "$M_RESIDUE" = "0/0/0" ]; then
    pass "S2b the interrupted minter left no residue either (fixture dir: '${M_LEFT:-empty}')"
else
    fail "S2b the interrupted minter left residue tokens/claims/tmp=$M_RESIDUE ('$M_LEFT')"
fi

# S3 — descendant fate, asserted as EQUIVALENCE rather than as absence. Whether the examiner
# grandchild dies with its parent is a property of the platform's signal delivery, not of the
# wrapper; what the wrapper must not do is change it. Comparing the two sides holds whichever
# way the platform goes, so this case stays honest if the host semantics ever change.
if [ "$W_DESC" = "$M_DESC" ]; then
    pass "S3 the wrapper and the minter leave the examiner in the same state after the signal (both '$W_DESC')"
else
    fail "S3 after SIGTERM the examiner '$W_DESC' under the wrapper but '$M_DESC' under the minter — the extra layer changed descendant handling"
fi

# SKIPPED: directly verifying that no descendant process (the examiner) survives the SIGTERM.
# Because: on this host (Windows/MSYS2 Git Bash) kill reaches only a single pid, not a process
#   group, and empirically the examiner stub kept ticking its heartbeat after the signal on BOTH
#   the wrapper side and the direct-minter side (= identical behaviour). Asserting "no descendant
#   survives" would be a false positive that reddens a platform behaviour unrelated to the
#   wrapper; asserting "one survives" would wrongly pin today's behaviour as a spec. So S3
#   asserts only the EQUIVALENCE of the two paths, leaving absolute survival out of scope.
# TL3 gap: a real terminal's Ctrl-C delivers SIGINT to the whole foreground process group via the
#   tty, so it reaches descendants. Verifying descendant termination in an environment with real
#   process-group signal delivery stays in the TL3 lane of tests/TL3-hook-clearance-token-write.sh.
skip "S4 no-surviving-descendant is not directly assertable on this host (see the Skipped-Because block above); S3 asserts wrapper/minter equivalence instead"

offclr_report
