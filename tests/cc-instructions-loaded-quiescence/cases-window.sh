# shellcheck shell=bash
# Tests: hooks/lib/instructions-loaded-receipt.js
# Tags: rules-injection, instructions-loaded, quiescence, table-driven, late-arrival, TL2, scope:common
#
# The Q1 completeness barrier and the Q2 stability window on the happy paths.

echo ""
echo "=== Q1 barrier / Q2 stability window ==="

# --- table-driven: name | scenario | want_status | want_hastarget ---
while IFS='|' read -r name scenario want_status want_target; do
    [ -z "${name// /}" ] && continue
    case "$name" in \#*) continue ;; esac
    name="${name//[[:space:]]/}"; scenario="${scenario//[[:space:]]/}"
    want_status="${want_status//[[:space:]]/}"; want_target="${want_target//[[:space:]]/}"
    out="$(run_scenario "$scenario")"
    got_status="$(field STATUS "$out")"
    got_target="$(field HASTARGET "$out")"
    if [ "$got_status" != "$want_status" ]; then
        fail "$name: want STATUS=$want_status, got '$got_status' — driver said: $out"
    elif [ "$got_target" != "$want_target" ]; then
        fail "$name: want HASTARGET=$want_target, got '$got_target' — driver said: $out"
    else
        pass "$name (STATUS=$got_status HASTARGET=$got_target)"
    fi
done <<'TABLE'
Q-i-satisfied-stable        | satisfied-stable           | OK         | no
Q-ii-member-missing         | member-missing             | INCOMPLETE | no
Q-iii-late-arrival          | late-arrival-midwindow     | OK         | yes
Q-iv-target-before-deadline | target-just-before-deadline| OK         | yes
Q-v-temp-not-aggregated     | temp-file-not-aggregated   | OK         | no
Q-vi-dir-absent             | dir-absent                 | INCOMPLETE | no
TABLE

# --- Q-iii-reset: the late arrival must RESET the stability timer, not merely be
# picked up. With W=5s and the target dropped at t=3s, a non-resetting
# implementation settles at ~5s; a correct one cannot settle before ~8s.
out_iii="$(run_scenario late-arrival-midwindow)"
elapsed_iii="$(field ELAPSED "$out_iii")"
if [ -n "$elapsed_iii" ] && [ "$elapsed_iii" -ge 8 ] 2>/dev/null; then
    pass "Q-iii-reset: mid-window arrival reset the stability window (settled at ${elapsed_iii}s >= 8s)"
else
    fail "Q-iii-reset: window was not reset by the late entry (ELAPSED=$elapsed_iii, want >=8) — driver said: $out_iii"
fi

# --- Q-v-count: exactly the three published entries are aggregated; the two
# half-written publications are invisible.
out_v="$(run_scenario temp-file-not-aggregated)"
count_v="$(field COUNT "$out_v")"
[ "$count_v" = "3" ] && pass "Q-v-count: half-written temp files are not aggregated (COUNT=3)" \
    || fail "Q-v-count: want COUNT=3, got '$count_v' — driver said: $out_v"

# --- same-key republication (C8) ------------------------------------------------
# Every case above changes the entry SET when something happens. A re-fired
# InstructionsLoaded event for a file the session already loaded does not: the receipt
# count stays constant and only fired_at moves. An implementation that treats "the
# directory listing stopped changing" as stability settles early here and would then
# let the TL3 gate read absence out of a session that was still loading.
#
# CONTRACT NOTE (asserted here): stability is over the PAIR (entry set, max fired_at).
# A newer timestamp on an existing key restarts the window; an older one does not.

out_rn="$(run_scenario republish-newer-midwindow)"
st_rn="$(field STATUS "$out_rn")"; ct_rn="$(field COUNT "$out_rn")"; el_rn="$(field ELAPSED "$out_rn")"
if [ "$st_rn" != "OK" ] || [ "$ct_rn" != "3" ]; then
    fail "Q-republish-newer: want STATUS=OK COUNT=3, got $st_rn/$ct_rn — driver said: $out_rn"
elif [ -n "$el_rn" ] && [ "$el_rn" -ge 8 ] 2>/dev/null; then
    pass "Q-republish-newer: a same-key republish with a newer fired_at reset the window (${el_rn}s >= 8s)"
else
    fail "Q-republish-newer: the window did not reset on a same-key republish (ELAPSED=$el_rn, want >=8) — the entry count never changed, so only the timestamp could have signalled it; driver said: $out_rn"
fi

out_ro="$(run_scenario republish-older-midwindow)"
st_ro="$(field STATUS "$out_ro")"; el_ro="$(field ELAPSED "$out_ro")"
if [ "$st_ro" != "OK" ]; then
    fail "Q-republish-older: want STATUS=OK, got '$st_ro' — driver said: $out_ro"
elif [ -n "$el_ro" ] && [ "$el_ro" -le 7 ] 2>/dev/null; then
    pass "Q-republish-older: a stale republish did not restart the window (${el_ro}s <= 7s)"
else
    fail "Q-republish-older: an older fired_at restarted the window (ELAPSED=$el_ro, want <=7) — a replayed or clock-skewed receipt can hold the gate open; driver said: $out_ro"
fi

out_rf="$(run_scenario republish-newer-forever)"
st_rf="$(field STATUS "$out_rf")"; el_rf="$(field ELAPSED "$out_rf")"
if printf '%s' "$out_rf" | grep -q 'RUNAWAY=yes'; then
    fail "Q-republish-forever: the run never terminated — $out_rf"
elif [ "$st_rf" != "INCOMPLETE" ]; then
    fail "Q-republish-forever: a set in motion for the whole run must be INCOMPLETE, got '$st_rf' — driver said: $out_rf"
elif [ -n "$el_rf" ] && [ "$el_rf" -le 91 ] 2>/dev/null; then
    pass "Q-republish-forever: perpetual same-key republication ends INCOMPLETE at the deadline (${el_rf}s)"
else
    fail "Q-republish-forever: want ELAPSED <= 91, got '$el_rf' — driver said: $out_rf"
fi

# --- Q-ii-deadline: the incomplete run must stop at the combined deadline, not spin ---
out_ii="$(run_scenario member-missing)"
elapsed_ii="$(field ELAPSED "$out_ii")"
if [ -n "$elapsed_ii" ] && [ "$elapsed_ii" -le 91 ] 2>/dev/null && [ "$elapsed_ii" -ge 60 ] 2>/dev/null; then
    pass "Q-ii-deadline: Q1 failure returns between the 60s and 90s bounds (${elapsed_ii}s)"
else
    fail "Q-ii-deadline: want 60 <= ELAPSED <= 91, got '$elapsed_ii' — driver said: $out_ii"
fi
