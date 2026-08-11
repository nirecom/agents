#!/usr/bin/env bash
# tests/cc-tl3-rules-injection-gate.sh
# Tests: hooks/instructions-loaded-audit.js, hooks/lib/instructions-loaded-receipt.js, hooks/lib/rules-injection-policy.js
# Tags: rules-injection, on-demand-rules, off-switch, gate-logic, inconclusive, decision-table, TL2, scope:common
#
# The TL3 off-switch gate concludes "the reserved glob suppressed injection" from an ABSENCE of receipts. Absence is only evidence when the run that was supposed to produce them actually completed: a subprocess killed at the timeout, or one that exited non-zero before the loader ran, leaves byte-for-byte the same empty receipt directory as a perfectly working off-switch. This file pins the rule that a non-zero subprocess result yields G-INCONCLUSIVE, never G-PASS.
# The TL3 body itself is RUN_TL3-gated and skips (exit 77) on every ordinary run, so its decision table would otherwise never execute in CI. The table lives in tests/TL3-rules-injection-off-switch/helpers.sh (SSOT) and is sourced here — this file drives it directly with synthesized rc / observation / quiescence inputs, no claude subprocess and no filesystem. Layer: TL2 (sources the real gate helpers; pure function calls).
# TL3 gap: whether a real `claude -p` timeout actually surfaces as rc 124/137 on this host, and whether the receipt directory is genuinely empty at that moment. Mitigated at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPERS="$AGENTS_DIR/tests/TL3-rules-injection-off-switch/helpers.sh"
HOOK="$AGENTS_DIR/hooks/instructions-loaded-audit.js"
RECEIPT_LIB="$AGENTS_DIR/hooks/lib/instructions-loaded-receipt.js"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- Tier 1: implementation-missing guard.
# The gate exists to judge these two modules; with neither in the tree the verdicts
# below describe nothing that can run, so the file reports one intentional failure
# rather than a misleading green. ---
MISSING=0
for f in "$HOOK" "$RECEIPT_LIB"; do
    [ -f "$f" ] || { echo "FAIL: IMPLEMENTATION MISSING: $f"; MISSING=1; }
done
if [ ! -f "$HELPERS" ]; then
    echo "FAIL: IMPLEMENTATION MISSING: $HELPERS (the gate decision table)"
    MISSING=1
fi
if [ "$MISSING" -eq 1 ]; then
    echo ""
    echo "Results: 0 passed, 1 failed (targets not yet implemented — detail plan S2-2 / S2-4)"
    exit 1
fi

# shellcheck source=/dev/null
. "$HELPERS"

for fn in ril_rc_label ril_gate_base_status ril_gate_judge_verdict ril_f1_verdict; do
    if ! command -v "$fn" >/dev/null 2>&1; then
        echo "FAIL: IMPLEMENTATION MISSING: $HELPERS does not define $fn()"
        echo ""
        echo "Results: 0 passed, 1 failed"
        exit 1
    fi
done

# =================================================================================
# L1: rc labelling — the failure message must name the cause, because an operator
# reading "G-INCONCLUSIVE" needs to know whether to re-run or to fix a registration.
# =================================================================================
echo "=== L1: subprocess rc labels ==="
while IFS='|' read -r name rc want; do
    [ -z "${name:-}" ] && continue
    got="$(ril_rc_label "$rc")"
    if [ "$got" = "$want" ]; then
        pass "L1 [$name]: rc=$rc labelled '$got'"
    else
        fail "L1 [$name]: rc=$rc want label '$want', got '$got'"
    fi
done <<'TABLE'
rc-ok|0|ok
rc-timeout-sigterm|124|timed out
rc-timeout-sigkill|137|timed out
rc-skip|77|skipped
rc-cd-failed|90|could not enter the fixture repo
rc-generic|1|non-zero exit
rc-generic-high|255|non-zero exit
TABLE

# =================================================================================
# L2: RUN-BASE gate. EXPECTED_SET, the span S and the stability window W are all
# derived from this run; a partial run poisons every later judgement, so the rc is
# checked BEFORE any receipt-shape condition. The first two rows differ only in rc
# with a fully healthy receipt set — that pair is the whole point of C4.
# Columns: name | rc | dir_exists | n_entries | target_seen | want_status
# =================================================================================
echo ""
echo "=== L2: RUN-BASE must have completed before its baseline is trusted ==="
while IFS='|' read -r name rc dir n tgt want; do
    [ -z "${name:-}" ] && continue
    out="$(ril_gate_base_status "$rc" "$dir" "$n" "$tgt")"
    got="${out%% *}"
    if [ "$got" = "$want" ]; then
        pass "L2 [$name]: $got"
    else
        fail "L2 [$name]: want $want, got $got — [$out]"
    fi
done <<'TABLE'
base-healthy|0|1|4|1|OK
base-healthy-but-timed-out|124|1|4|1|INCONCLUSIVE
base-killed|137|1|4|1|INCONCLUSIVE
base-nonzero|1|1|4|1|INCONCLUSIVE
base-partial-set-after-timeout|124|1|2|1|INCONCLUSIVE
base-empty-after-timeout|124|0|0|0|INCONCLUSIVE
base-no-receipt-dir|0|0|0|0|INCONCLUSIVE
base-dir-but-no-entries|0|1|0|0|INCONCLUSIVE
base-no-target-anchor|0|1|3|0|INCONCLUSIVE
TABLE

# --- L2-msg: a timed-out RUN-BASE must be reported as such, not as "no entries".
# Misattributing a timeout to a missing registration sends the operator to the wrong
# fix, which is how a flaky gate becomes a permanent "known failure". ---
MSG="$(ril_gate_base_status 124 1 4 1)"
if printf '%s' "$MSG" | grep -q 'timed out'; then
    pass "L2-msg: the timeout cause appears in the RUN-BASE reason"
else
    fail "L2-msg: RUN-BASE timeout reason does not mention the timeout — [$MSG]"
fi

# =================================================================================
# L3: RUN-JUDGE verdict. Asymmetric by design — one observation of probe-target.md
# is decisive (G-FAIL) even from a crashed run, because a leak observed is a leak;
# but absence requires rc=0 AND demonstrated quiescence AND a clean re-read.
# Columns: name | rc | seen | quiescence | seen_after | want_verdict
# =================================================================================
echo ""
echo "=== L3: RUN-JUDGE verdicts (asymmetric: G-FAIL cheap, G-PASS expensive) ==="
while IFS='|' read -r name rc seen q after want; do
    [ -z "${name:-}" ] && continue
    out="$(ril_gate_judge_verdict "$rc" "$seen" "$q" "$after")"
    got="${out%% *}"
    if [ "$got" = "$want" ]; then
        pass "L3 [$name]: $got"
    else
        fail "L3 [$name]: want $want, got $got — [$out]"
    fi
done <<'TABLE'
judge-clean-pass|0|0|OK|0|G-PASS-PENDING
judge-leak-observed|0|1|OK|0|G-FAIL
judge-leak-observed-despite-timeout|124|1|NOT_RUN|0|G-FAIL
judge-leak-observed-despite-crash|1|1|NOT_RUN|0|G-FAIL
judge-timed-out-no-observation|124|0|NOT_RUN|0|G-INCONCLUSIVE
judge-killed-no-observation|137|0|NOT_RUN|0|G-INCONCLUSIVE
judge-nonzero-no-observation|1|0|NOT_RUN|0|G-INCONCLUSIVE
judge-nonzero-even-with-quiescence-ok|1|0|OK|0|G-INCONCLUSIVE
judge-quiescence-incomplete|0|0|INCOMPLETE|0|G-INCONCLUSIVE
judge-quiescence-threw|0|0|THREW|0|G-INCONCLUSIVE
judge-quiescence-missing-status|0|0|NO_STATUS|0|G-INCONCLUSIVE
judge-quiescence-not-run|0|0|NOT_RUN|0|G-INCONCLUSIVE
judge-arrived-during-window|0|0|OK|1|G-FAIL
TABLE

# --- L3-nopass: the single invariant this whole file exists to protect.
# Enumerate every non-zero rc and every non-OK quiescence status and assert that no
# combination without a positive observation can ever reach G-PASS-PENDING. ---
LEAKED=""
for rc in 1 2 77 90 124 130 137 255; do
    for q in OK INCOMPLETE THREW NO_STATUS NOT_RUN TIMEOUT ""; do
        v="$(ril_gate_judge_verdict "$rc" 0 "$q" 0)"
        case "${v%% *}" in
            G-PASS-PENDING) LEAKED="$LEAKED rc=$rc/q=${q:-EMPTY}" ;;
        esac
    done
done
if [ -z "$LEAKED" ]; then
    pass "L3-nopass: no non-zero-rc combination reaches G-PASS-PENDING (56 combinations)"
else
    fail "L3-nopass: absence was accepted as proof after a failed subprocess —$LEAKED"
fi

# --- L3-pass-needs-everything: the converse. With rc=0 the verdict must still be
# blocked by any non-OK quiescence status, so G-PASS depends on all three inputs. ---
BAD=""
for q in INCOMPLETE THREW NO_STATUS NOT_RUN TIMEOUT ""; do
    v="$(ril_gate_judge_verdict 0 0 "$q" 0)"
    case "${v%% *}" in
        G-PASS-PENDING) BAD="$BAD q=${q:-EMPTY}" ;;
    esac
done
if [ -z "$BAD" ]; then
    pass "L3-pass-needs-everything: rc=0 alone never yields G-PASS-PENDING"
else
    fail "L3-pass-needs-everything: unproven quiescence accepted as stable —$BAD"
fi

# --- L3-msg: an inconclusive RUN-JUDGE must say why absence is not evidence. ---
JMSG="$(ril_gate_judge_verdict 124 0 NOT_RUN 0)"
if printf '%s' "$JMSG" | grep -q 'timed out' && printf '%s' "$JMSG" | grep -qi 'absence'; then
    pass "L3-msg: the RUN-JUDGE inconclusive reason names both the timeout and the absence claim"
else
    fail "L3-msg: reason is not actionable — [$JMSG]"
fi

# =================================================================================
# L4: the F1 model-probe fallback. It is reached only after G1 already failed, so it
# runs in exactly the situation nobody exercises by hand, and its input is a model
# self-report rather than a filesystem fact. A substring match such as
# `present.*absent` grades a refusal, an error message, or an echoed prompt as a clean
# result; strict two-token parsing plus an rc gate is the contract.
# Columns: name | rc | model output (\n escapes expanded) | want_verdict
# =================================================================================
echo ""
echo "=== L4: F1 model-probe fallback parsing ==="
while IFS='|' read -r name rc out want; do
    [ -z "${name// /}" ] && continue
    case "$name" in \#*) continue ;; esac
    name="$(printf '%s' "$name" | sed 's/^ *//; s/ *$//')"
    rc="$(printf '%s' "$rc" | sed 's/^ *//; s/ *$//')"
    want="$(printf '%s' "$want" | sed 's/^ *//; s/ *$//')"
    out="$(printf '%b' "$out")"
    res="$(ril_f1_verdict "$rc" "$out")"
    got="${res%% *}"
    if [ "$got" = "$want" ]; then
        pass "L4 [$name]: $got"
    else
        fail "L4 [$name]: want $want, got $got — [$res]"
    fi
done <<'TABLE'
f1-clean-pass            | 0   | present absent                                            | F1-PASS
f1-json-wrapped          | 0   | {"type":"result","result":"present absent"}               | F1-PASS
f1-capitalized           | 0   | Present Absent                                            | F1-PASS
f1-punctuated            | 0   | present, absent.                                          | F1-PASS
f1-leak                  | 0   | present present                                           | F1-FAIL
f1-control-missing       | 0   | absent absent                                             | F1-INCONCLUSIVE
f1-control-missing-leak  | 0   | absent present                                            | F1-INCONCLUSIVE
f1-one-token             | 0   | absent                                                    | F1-INCONCLUSIVE
f1-no-tokens             | 0   | I cannot answer that.                                     | F1-INCONCLUSIVE
f1-empty                 | 0   |                                                           | F1-INCONCLUSIVE
f1-three-tokens          | 0   | present absent absent                                     | F1-INCONCLUSIVE
f1-prompt-echoed         | 0   | reply present or absent -> present absent                 | F1-INCONCLUSIVE
f1-refusal-with-word     | 0   | The requested string may be present in some contexts.     | F1-INCONCLUSIVE
f1-error-json            | 0   | {"type":"error","message":"session absent"}               | F1-INCONCLUSIVE
f1-timeout-clean-looking | 124 | present absent                                            | F1-INCONCLUSIVE
f1-crash-clean-looking   | 1   | present absent                                            | F1-INCONCLUSIVE
f1-cd-failed             | 90  | present absent                                            | F1-INCONCLUSIVE
TABLE

# --- L4-loose: the exact regression the old implementation had. A single output that
# merely CONTAINS "present" before "absent" must not be graded as a pass. ---
LOOSE="$(ril_f1_verdict 0 'Both nonces are present; neither is absent from my context.')"
if [ "${LOOSE%% *}" = "F1-PASS" ]; then
    fail "L4-loose: a prose answer matching present.*absent was accepted as a clean result"
else
    pass "L4-loose: a prose answer matching present.*absent is not a pass (${LOOSE%% *})"
fi

# --- L4-disjoint: no F1 outcome may speak the gate's pass vocabulary. The fallback is
# diagnostic evidence about why the receipt route saw nothing; it never converts the
# G1 failure that led here into a green gate. ---
BADV=""
for rc in 0 1 124; do
    for o in "present absent" "present present" "absent absent" "" "garbage"; do
        v="$(ril_f1_verdict "$rc" "$o")"; v="${v%% *}"
        case "$v" in
            F1-PASS|F1-FAIL|F1-INCONCLUSIVE) ;;
            *) BADV="$BADV rc=$rc/[$o]->$v" ;;
        esac
    done
done
if [ -z "$BADV" ]; then
    pass "L4-disjoint: every F1 outcome stays in the F1-* vocabulary, never G-PASS"
else
    fail "L4-disjoint: the fallback emitted a gate-level verdict —$BADV"
fi

# --- C5: post-quiescence sticky verdict. Split into the sibling folder to keep this
# entry file under the 300-line WARN (rules/coding/file-split.md Pattern A). ---
ORCH="$AGENTS_DIR/tests/cc-tl3-rules-injection-gate/cases-orchestration.sh"
if [ -f "$ORCH" ]; then
    # shellcheck source=/dev/null
    . "$ORCH"
else
    fail "IMPLEMENTATION MISSING: $ORCH (post-quiescence orchestration cases)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
