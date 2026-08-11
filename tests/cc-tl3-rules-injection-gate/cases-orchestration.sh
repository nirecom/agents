# shellcheck shell=bash
# Tests: hooks/instructions-loaded-audit.js, hooks/lib/instructions-loaded-receipt.js
# Tags: rules-injection, off-switch, gate-logic, orchestration, sticky-verdict, TL2, scope:common
#
# Post-quiescence orchestration (C5). The gate's G4 classification checks and its G5
# terminal re-read used to run as independent `if` blocks, each printing its own
# verdict while the pending state stayed G-PASS-PENDING — so a FAILED G4 still left G5
# free to print the pass token. A gate that reports a clean off-switch on a run which
# already produced a failed assertion is worse than no gate: it is a green light bought
# with a known defect.
#
# CONTRACT NOTE (asserted here, honoured by ril_post_quiescence in
# TL3-rules-injection-off-switch/decisions.sh):
#   - The verdict is MONOTONE. Once it leaves G-PASS-PENDING it never returns to it.
#   - The bare token `G-PASS` appears in the output only when EVERY post-quiescence
#     check held. `G-PASS-PENDING` is a different token and is not a pass.
#   - Failure prose may not contain the bare token, so a downstream grep can trust it.
#   - Q3 is cumulative: a terminal re-read shorter than the required span is
#     G-INCONCLUSIVE, never a pass — a short look cannot tell "absent" from
#     "has not arrived yet".
#
# Assumes pass(), fail() and the sourced gate helpers are already available.

echo ""
echo "=== C5: post-quiescence sticky verdict ==="

if ! command -v ril_post_quiescence >/dev/null 2>&1; then
    fail "O0: ril_post_quiescence() is not defined — the post-quiescence state machine is missing"
    return 0 2>/dev/null || true
fi

# has_pass_token <text> -> 0 when a BARE G-PASS token is present.
# `G-PASS-PENDING` contains `G-PASS` as a substring, and `grep -w` would match it
# (the following `-` is a non-word character), so the tokens are extracted whole and
# compared for equality instead.
has_pass_token() {
    printf '%s\n' "$1" | grep -oE 'G-[A-Z-]+' | grep -qx 'G-PASS'
}

verdict_of() { printf '%s\n' "$1" | grep '^VERDICT=' | head -1 | cut -d= -f2-; }

# orch <label> <want-verdict> <want-pass-token:yes|no> <args...>
orch() {
    local label="$1" want="$2" want_tok="$3"; shift 3
    local out got
    out="$(ril_post_quiescence "$@")"
    got="$(verdict_of "$out")"
    if [ "$got" != "$want" ]; then
        fail "$label: want VERDICT=$want, got '$got' — [$(printf '%s' "$out" | tr '\n' '/')]"
        return
    fi
    if has_pass_token "$out"; then
        if [ "$want_tok" = "no" ]; then
            fail "$label: a bare G-PASS token reached the output of a failing run — [$(printf '%s' "$out" | tr '\n' '/')]"
            return
        fi
    elif [ "$want_tok" = "yes" ]; then
        fail "$label: the clean run produced no G-PASS token — [$(printf '%s' "$out" | tr '\n' '/')]"
        return
    fi
    pass "$label (VERDICT=$got)"
}

# --- O1: the only shape that may pass. Everything below is this row with exactly one
# post-quiescence assertion broken, so each failure is attributable. ---
orch "O1: all post-quiescence checks hold -> G-PASS" \
     "G-PASS" yes   "G-PASS-PENDING" "S-MISSING" "MISSING_RECEIPT" 0 30 30

# --- O2..O4: each post-quiescence assertion forced to fail INDEPENDENTLY. This is the
# regression for the original defect: before the state machine, O2 printed the pass
# token because G4's failure never reached G5. ---
orch "O2: G4 control misclassified -> sticky G-FAIL, no pass token" \
     "G-FAIL" no    "G-PASS-PENDING" "ok" "MISSING_RECEIPT" 0 30 30
orch "O2b: G4 control receipt missing entirely -> sticky G-FAIL" \
     "G-FAIL" no    "G-PASS-PENDING" "MISSING_RECEIPT" "MISSING_RECEIPT" 0 30 30
orch "O3: the target appears on the terminal re-read -> G-FAIL" \
     "G-FAIL" no    "G-PASS-PENDING" "S-MISSING" "S-LEAK" 1 30 30
orch "O4: the terminal re-read was cut short -> G-INCONCLUSIVE, not a pass" \
     "G-INCONCLUSIVE" no "G-PASS-PENDING" "S-MISSING" "MISSING_RECEIPT" 0 4 30
orch "O4b: a zero-length terminal re-read is never a pass" \
     "G-INCONCLUSIVE" no "G-PASS-PENDING" "S-MISSING" "MISSING_RECEIPT" 0 0 30
orch "O4c: one second past the required span is enough" \
     "G-PASS" yes   "G-PASS-PENDING" "S-MISSING" "MISSING_RECEIPT" 0 31 30

# --- O5: a verdict that arrived already settled must stay settled. G4/G5 may not
# rehabilitate a run the judge stage already failed. ---
orch "O5: an upstream G-FAIL with a correct S-LEAK classification stays G-FAIL" \
     "G-FAIL" no    "G-FAIL" "S-MISSING" "S-LEAK" 0 30 30
orch "O5b: an upstream G-FAIL whose leak was misclassified is still G-FAIL" \
     "G-FAIL" no    "G-FAIL" "S-MISSING" "ok" 0 30 30
orch "O6: an upstream G-INCONCLUSIVE is never upgraded by later checks" \
     "G-INCONCLUSIVE" no "G-INCONCLUSIVE" "S-MISSING" "MISSING_RECEIPT" 0 30 30
orch "O6b: an empty pending verdict degrades to G-INCONCLUSIVE" \
     "G-INCONCLUSIVE" no "" "S-MISSING" "MISSING_RECEIPT" 0 30 30

# --- O7: exhaustive sweep. Every combination that contains at least one broken
# post-quiescence condition must be free of the bare pass token; this is the assertion
# that survives future edits to the branch structure. ---
O7_BAD=""
O7_GREEN=0
for ctrl in "S-MISSING" "ok" "S-MALFORMED" "MISSING_RECEIPT"; do
    for seen in 0 1; do
        for el in 0 29 30; do
            o="$(ril_post_quiescence "G-PASS-PENDING" "$ctrl" "MISSING_RECEIPT" "$seen" "$el" 30)"
            clean=0
            [ "$ctrl" = "S-MISSING" ] && [ "$seen" = "0" ] && [ "$el" -ge 30 ] && clean=1
            if has_pass_token "$o"; then
                if [ "$clean" = "1" ]; then O7_GREEN=$((O7_GREEN + 1)); else
                    O7_BAD="$O7_BAD [ctrl=$ctrl seen=$seen elapsed=$el]"
                fi
            elif [ "$clean" = "1" ]; then
                O7_BAD="$O7_BAD [clean row produced no pass: ctrl=$ctrl seen=$seen elapsed=$el]"
            fi
        done
    done
done
if [ -z "$O7_BAD" ] && [ "$O7_GREEN" = "1" ]; then
    pass "O7: across all 24 combinations exactly one (the fully clean row) yields a G-PASS token"
else
    fail "O7: pass-token leakage or a lost green —$O7_BAD (green rows: $O7_GREEN, want 1)"
fi

# --- O8: the failure prose itself must not carry the token. A reason string such as
# "G-PASS retracted" (the wording this refactor removed) would make every downstream
# grep for the token report a pass on a failed run. ---
O8_BAD=""
for row in "ok|0|30" "S-MISSING|1|30" "S-MISSING|0|3"; do
    c="${row%%|*}"; rest="${row#*|}"; s="${rest%%|*}"; e="${rest##*|}"
    o="$(ril_post_quiescence "G-PASS-PENDING" "$c" "MISSING_RECEIPT" "$s" "$e" 30)"
    body="$(printf '%s\n' "$o" | grep -v '^VERDICT=')"
    if printf '%s\n' "$body" | grep -oE 'G-[A-Z-]+' | grep -qx 'G-PASS'; then
        O8_BAD="$O8_BAD [$row]"
    fi
done
if [ -z "$O8_BAD" ]; then
    pass "O8: no failure REASON line contains the bare pass token"
else
    fail "O8: failure prose contains the bare pass token, poisoning every downstream grep —$O8_BAD"
fi

# --- O9: the harness's own Q3 collector must be able to observe for the full span and
# must stop early when the needle appears. It is exercised here against a real
# directory rather than mocked, but with a 2-second span so the file stays fast. ---
if command -v ril_terminal_recheck >/dev/null 2>&1; then
    O9_WF="$(mktemp -d)"
    mkdir -p "$O9_WF/o9sid.instructions-loaded"
    o9_out="$(ril_terminal_recheck "$O9_WF" "o9sid" 'probe-target.md' 2)"
    o9_seen="$(printf '%s' "$o9_out" | tr ' ' '\n' | grep '^SEEN=' | cut -d= -f2)"
    o9_el="$(printf '%s' "$o9_out" | tr ' ' '\n' | grep '^ELAPSED=' | cut -d= -f2)"
    if [ "$o9_seen" = "0" ] && [ "${o9_el:-0}" -ge 2 ]; then
        pass "O9: the terminal re-read observes the full requested span when nothing arrives (${o9_el}s)"
    else
        fail "O9: want SEEN=0 and ELAPSED>=2 from an empty receipt dir, got '$o9_out'"
    fi
    rm -rf "$O9_WF"
else
    fail "O9: ril_terminal_recheck() is not defined — Q3 has no cumulative collector"
fi
