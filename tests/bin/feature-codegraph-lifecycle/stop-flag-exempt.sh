# shellcheck shell=bash
# Tests: bin/codegraph-lifecycle.js, bin/codegraph-lifecycle/daemon-stop.js
# Tags: codegraph, lifecycle, env-flag, stop-verb, fail-safe, idempotency, scope:issue-specific
# LS1-LS12 (#2150 security review): `stop` is exempt from the CODEGRAPH gate.
# WHY: the uninstall path runs `stop` precisely BECAUSE the flag has just turned
# off, so gating it would strand the daemon it is meant to release. env-silence.sh
# owns the two verbs that ARE gated; this file owns the exempt one.

echo "--- LS1-LS4: stop runs with the flag OFF (attack-shape: silent before the fix) ---"
# Pattern 2 structure — the pre-fix binary exited at the gate and printed nothing,
# so `exactly 1 stderr warning line` is the assertion that fails against it. The
# warning is proof the run reached daemon-stop.js's readPid, not merely exit 0.
while IFS='|' read -r case_id env_value; do
    [ -n "$case_id" ] || continue
    reset_env
    write_env "$env_value"
    root="$(mkroot "stopexempt-$case_id")"
    make_db "$root" fake-schema || continue
    write_pidfile "$root" 'this is not json'
    run_cli stop "$root"
    assert_warned "$case_id/stop (CODEGRAPH=$env_value) — stop is not gated"
    assert_no_spawn "$case_id/stop (CODEGRAPH=$env_value)"
done <<'TABLE'
LS1|__none__
LS2|off
LS3|
LS4|garbage
TABLE

echo "--- LS5: OFF + stop + no daemon.pid at all is silent ---"
# The absent-pidfile branch returns before any diagnostic, so exemption must not
# turn a repo nobody indexed into a noisy one.
reset_env
write_env off
root="$(mkroot "stopexempt-ls5")"
make_db "$root" absent
run_cli stop "$root"
assert_silent "LS5 (OFF, stop, no daemon.pid)"
assert_no_spawn "LS5 (OFF, stop, no daemon.pid)"

echo "--- LS6/LS7: the codegraph binary being absent is still a silent exit 0 ---"
# CPR-ORTH: the presence check warns for init/sync (L5) but must stay quiet for
# stop, in BOTH flag states — stopping a daemon needs no binary on PATH.
while IFS='|' read -r case_id env_value; do
    [ -n "$case_id" ] || continue
    reset_env
    write_env "$env_value"
    CG_PATH_MODE=empty
    root="$(mkroot "stopexempt-$case_id")"
    make_db "$root" absent
    write_pidfile "$root" 'this is not json'
    run_cli stop "$root"
    assert_silent "$case_id/stop (CODEGRAPH=$env_value, codegraph off PATH)"
done <<'TABLE'
LS6|off
LS7|on
TABLE

echo "--- LS8: ON + sync + no codegraph binary still warns (the gated counterpart) ---"
reset_env
CG_PATH_MODE=empty
root="$(mkroot "stopexempt-ls8")"
make_db "$root" absent
run_cli sync "$root"
assert_warned "LS8 (ON, sync, codegraph off PATH)"

echo "--- LS9: init and sync stay silent no-ops with the flag OFF ---"
# Restated here, against the same fixture the LS1-LS4 stop rows use, so the
# exemption is visibly scoped to one verb rather than having widened to all three.
for verb in init sync; do
    reset_env
    write_env off
    root="$(mkroot "stopexempt-ls9-$verb")"
    make_db "$root" fake-schema || continue
    write_pidfile "$root" 'this is not json'
    run_cli "$verb" "$root"
    assert_silent "LS9/$verb (CODEGRAPH=off) — still gated"
    assert_eq "LS9/$verb — codegraph was never launched" "0" "$(total_calls)"
    if [ -f "$(root_sh "stopexempt-ls9-$verb")/.codegraph/daemon.pid" ]; then
        pass "LS9/$verb — the gated verb left daemon.pid untouched"
    else
        fail "LS9/$verb — daemon.pid disappeared, so the gated verb reached the stop path"
    fi
done

echo "--- LS10: OFF + stop is idempotent (same verdict, same leftovers) ---"
reset_env
write_env off
root="$(mkroot "stopexempt-ls10")"
root_p="$(root_sh stopexempt-ls10)"
write_pidfile "$root" 'this is not json'
run_cli stop "$root"
LS10_RC1="$RC"; LS10_ERR1="$(err_lines)"
LS10_PID1="$(cat "$root_p/.codegraph/daemon.pid" 2>/dev/null || printf 'ABSENT')"
run_cli stop "$root"
assert_eq "LS10 — second run repeats the first exit code" "$LS10_RC1" "$RC"
assert_eq "LS10 — second run repeats the first stderr line count" "$LS10_ERR1" "$(err_lines)"
assert_eq "LS10 — an unreadable daemon.pid is never deleted by either run" \
    "$LS10_PID1" "$(cat "$root_p/.codegraph/daemon.pid" 2>/dev/null || printf 'ABSENT')"
assert_eq "LS10 — the first run really did leave the file behind" "this is not json" "$LS10_PID1"

echo "--- LS11: OFF + stop still refuses an out-of-range pid before any signal ---"
# The exemption must not have relaxed the pid validation that protects unrelated
# processes: a hostile daemon.pid is refused on the OFF path exactly as on ON.
while IFS='|' read -r case_id body; do
    [ -n "$case_id" ] || continue
    case_id="$(trim_field "$case_id")"
    body="$(trim_field "$body")"
    reset_env
    write_env off
    root="$(mkroot "stopexempt-$case_id")"
    root_p="$(root_sh "stopexempt-$case_id")"
    write_pidfile "$root" "$body"
    run_cli stop "$root"
    assert_warned "$case_id (OFF, daemon.pid=$body)"
    assert_no_query "$case_id (OFF, daemon.pid=$body)"
    if [ -f "$root_p/.codegraph/daemon.pid" ]; then
        pass "$case_id — the refused daemon.pid is still on disk"
    else
        fail "$case_id — the refused daemon.pid was deleted, so the run acted on it"
    fi
done <<'TABLE'
LS11-zero     | {"pid":0}
LS11-negative | {"pid":-1}
LS11-string   | {"pid":"12345"}
TABLE
