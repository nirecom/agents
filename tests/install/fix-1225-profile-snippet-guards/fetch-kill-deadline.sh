# Tests: profile-snippet.sh
# Tags: installer, profile-snippet, session-sync, fetch-deadline, timeout, set-e, process-tree, config-dependent, scope:issue-specific
# Part of tests/install/fix-1225-profile-snippet-guards.sh — sourced by that dispatcher, not run alone; uses make_mirror_sandbox / run_mirror_driver / pass / fail.
# Issue #2160: the startup fetch is killed once its deadline passes, so a hung remote cannot hold the login shell open.
# Issue #1770 / #2658: the startup is `session-sync-engine startup --deadline-ms <SESSION_SYNC_STARTUP_DEADLINE_MS>`,
# whose kill takes the whole process tree — the helper git spawned (SSH / credential helper / upload-pack) and its children.
# A real git fetches from a real bare origin whose `remote.origin.uploadpack` is a script that hangs and spawns a grandchild.
# Cases pin SESSION_SYNC_STARTUP_DEADLINE_MS in the driver prologue; only TC-DEADLINE6 writes a mirror .env.

# Seconds the upload-pack script hangs: far past every deadline a timing case pins plus
# the margin, yet inside run_mirror_driver's own 30s outer timeout.
_FKD_HANG_SECS=12
# Fixed allowance on top of the pinned deadline for snippet, get-config-var and node start-up
# and the kill itself. The pass line is "deadline + margin", never a constant.
_FKD_MARGIN_MS=2000
# A source that returns this much earlier than the deadline never waited for the hung fetch.
_FKD_EARLY_MS=200
_FKD_DEFAULT_MS=3000
_FKD_TABLE="$SCRIPT_CHECKOUT_ROOT/tests/fixtures/session-sync-startup-deadline-table.txt"

_fkd_native_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# _fkd_real_origin <sandbox> — replaces the fake git with the real one, mirrors the engine,
# and seeds ~/.claude/projects as a real clone of a bare origin.
_fkd_real_origin() {
    local sb="$1"
    mirror_install_real_engine "$sb"
    local proj="$sb/home/.claude/projects" origin="$sb/origin.git"
    rm -rf "$proj"
    git init -q --bare "$origin"
    git init -q "$proj"
    git -C "$proj" config core.hooksPath /dev/null
    git -C "$proj" config core.autocrlf false
    printf '{"uuid":"seed"}\n' > "$proj/seed.jsonl"
    git -C "$proj" add -A
    git -C "$proj" -c user.name=fkd -c user.email=fkd@example.invalid -c commit.gpgSign=false commit -qm seed
    git -C "$proj" remote add origin "$(_fkd_native_path "$origin")"
    git -C "$proj" push -q origin HEAD:refs/heads/main 2>/dev/null
}

# _fkd_hang_fetch <sandbox> — _fkd_real_origin plus an upload-pack (hang.sh) that records
# GIT_TERMINAL_PROMPT and its PID, starts a grandchild, then sleeps. Either completion
# marker appears only if nothing killed that process.
_fkd_hang_fetch() {
    local sb="$1"
    _fkd_real_origin "$sb"
    cat > "$sb/hang.sh" <<EOF
#!/bin/sh
printf '%s' "\${GIT_TERMINAL_PROMPT-UNSET}" > "$sb/gtp.out"
printf '%s' "\$\$" > "$sb/fetchpid.out"
( sleep $_FKD_HANG_SECS; printf 'completed' > "$sb/grandchild-completed.out" ) &
printf '%s' "\$!" > "$sb/grandchildpid.out"
sleep $_FKD_HANG_SECS
printf 'completed' > "$sb/fetch-completed.out"
EOF
    git -C "$sb/home/.claude/projects" config remote.origin.uploadpack "sh '$(_fkd_native_path "$sb/hang.sh")'"
}

# _fkd_stub_engine <sandbox> — an engine that only records its argv to <sandbox>/engine-argv.out.
_fkd_stub_engine() {
    cat > "$1/agents/bin/session-sync-engine" <<'EOF'
const fs = require("fs");
const path = require("path");
fs.writeFileSync(path.join(__dirname, "..", "..", "engine-argv.out"), process.argv.slice(2).join("\n") + "\n");
EOF
}

# _fkd_pin <unset|set> [<value>] — the driver prologue line pinning the deadline variable.
_fkd_pin() {
    if [ "$1" = "unset" ]; then echo "unset SESSION_SYNC_STARTUP_DEADLINE_MS"
    else printf "export SESSION_SYNC_STARTUP_DEADLINE_MS='%s'\n" "${2:-}"; fi
}

# _fkd_write_driver <path> [<prologue>] — times the source itself in milliseconds, so the
# measurement excludes sandbox construction and shell start-up.
_fkd_write_driver() {
    local path="$1" prologue="${2:-}"
    cat > "$path" <<EOF
$prologue
_fkd_ms() { if [ -n "\${EPOCHREALTIME:-}" ]; then local t="\${EPOCHREALTIME//[.,]/}"; echo \$(( t / 1000 )); else echo \$(( \$(date +%s) * 1000 )); fi; }
_t0=\$(_fkd_ms)
. "\$SNIPPET"
_t1=\$(_fkd_ms)
echo "ELAPSED_MS=\$(( _t1 - _t0 ))"
echo "DONE"
EOF
}

# _fkd_elapsed <output> — the driver's ELAPSED_MS value, empty when the driver never
# got that far (outer timeout killed it).
_fkd_elapsed() {
    echo "$1" | grep -o 'ELAPSED_MS=[0-9][0-9]*' | head -1 | cut -d= -f2
}

# _fkd_alive <pidfile> — yes / no / unknown (no PID recorded).
_fkd_alive() {
    local pid; pid="$(cat "$1" 2>/dev/null || true)"
    if [ -z "$pid" ]; then echo unknown; elif kill -0 "$pid" 2>/dev/null; then echo yes; else echo no; fi
}

# TC-DEADLINE1 — a hung fetch is killed at the default deadline (variable unset): the source
#   returns inside 3000 + margin, the upload-pack PID is gone, and it never completed.
tc_deadline_kills_hung_fetch() {
    local sb; sb="$(make_mirror_sandbox 0)"
    _fkd_hang_fetch "$sb"
    local drv="$sb/drv_deadline_kill.sh"; _fkd_write_driver "$drv" "$(_fkd_pin unset)"
    local out; out="$(run_mirror_driver bash "$sb" "$drv" on)"
    local elapsed max=$(( _FKD_DEFAULT_MS + _FKD_MARGIN_MS )); elapsed="$(_fkd_elapsed "$out")"
    # Give the kill a beat to be reaped before asking whether the PID is alive.
    sleep 1
    local alive; alive="$(_fkd_alive "$sb/fetchpid.out")"
    if [ -f "$sb/gtp.out" ] && [ -n "$elapsed" ] && [ "$elapsed" -le "$max" ] \
        && [ "$alive" = "no" ] && [ ! -f "$sb/fetch-completed.out" ]; then
        pass "TC-DEADLINE1: hung fetch killed at the default deadline (source ${elapsed}ms, upload-pack PID dead)"
    else
        fail "TC-DEADLINE1: elapsed_ms='$elapsed' (max $max) attempted=$([ -f "$sb/gtp.out" ] && echo yes || echo no) upload-pack-alive=$alive completed=$([ -f "$sb/fetch-completed.out" ] && echo yes || echo no) — with SESSION_SYNC_STARTUP_DEADLINE_MS unset, a ${_FKD_HANG_SECS}s fetch must be killed by the ${_FKD_DEFAULT_MS}ms default. Output: $out"
    fi
    rm -rf "$sb"
}

# TC-DEADLINE2 — the kill path must not abort a login shell under `set -eu`.
tc_deadline_kill_survives_set_e() {
    local sb; sb="$(make_mirror_sandbox 0)"
    _fkd_hang_fetch "$sb"
    local drv="$sb/drv_deadline_sete.sh"; _fkd_write_driver "$drv" "set -eu
$(_fkd_pin unset)"
    local out rc
    out="$(run_mirror_driver bash "$sb" "$drv" on)"
    rc=$?
    local elapsed max=$(( _FKD_DEFAULT_MS + _FKD_MARGIN_MS )); elapsed="$(_fkd_elapsed "$out")"
    if [ "$rc" -eq 0 ] && echo "$out" | grep -q "DONE" && [ -f "$sb/gtp.out" ] \
        && [ -n "$elapsed" ] && [ "$elapsed" -le "$max" ]; then
        pass "TC-DEADLINE2: shell survives sourcing under 'set -eu' when the deadline kills the fetch (${elapsed}ms)"
    else
        fail "TC-DEADLINE2: exit=$rc done=$(echo "$out" | grep -c DONE) elapsed_ms='$elapsed' (max $max) attempted=$([ -f "$sb/gtp.out" ] && echo yes || echo no) — the deadline kill must not abort a login shell under 'set -eu'. Output: $out"
    fi
    rm -rf "$sb"
}

# TC-DEADLINE3 — the configured deadline bounds the wall clock from both sides: upper
#   "pinned deadline + margin" (a dropped kill goes RED); lower "pinned deadline - early"
#   (a hard-coded 3000 that ignores the setting, or a fixture that stopped hanging, goes RED).
#   6000 is far from the 3000 default and still well under the 12s hang.
tc_deadline_bounds_source_wall_clock() {
    local pinned=6000
    local sb; sb="$(make_mirror_sandbox 0)"
    _fkd_hang_fetch "$sb"
    local drv="$sb/drv_deadline_bounds.sh"; _fkd_write_driver "$drv" "$(_fkd_pin set "$pinned")"
    local out; out="$(run_mirror_driver bash "$sb" "$drv" on)"
    local elapsed; elapsed="$(_fkd_elapsed "$out")"
    local max=$(( pinned + _FKD_MARGIN_MS )) min=$(( pinned - _FKD_EARLY_MS ))
    if [ -z "$elapsed" ]; then
        fail "TC-DEADLINE3: sourcing never returned inside run_mirror_driver's outer timeout — the ${_FKD_HANG_SECS}s fetch holds the shell. Output: $out"
    elif [ ! -f "$sb/gtp.out" ]; then
        fail "TC-DEADLINE3: the fetch never reached upload-pack, so the deadline was never exercised. Output: $out"
    elif [ "$elapsed" -gt "$max" ]; then
        fail "TC-DEADLINE3: sourcing took ${elapsed}ms with SESSION_SYNC_STARTUP_DEADLINE_MS=$pinned (max $max) — the configured deadline is not honored or its kill is gone. Output: $out"
    elif [ "$elapsed" -lt "$min" ]; then
        fail "TC-DEADLINE3: sourcing took only ${elapsed}ms (min $min) — the configured deadline was ignored (hard-coded) or the fetch did not hang. Output: $out"
    else
        pass "TC-DEADLINE3: sourcing bounded to ${elapsed}ms ($min..$max) with SESSION_SYNC_STARTUP_DEADLINE_MS=$pinned"
    fi
    rm -rf "$sb"
}

# TC-DEADLINE4 (#1770) — the kill takes the whole tree: after the hang window both PIDs
#   must be dead and neither completion marker may exist.
tc_deadline_kills_process_tree() {
    local sb; sb="$(make_mirror_sandbox 0)"
    _fkd_hang_fetch "$sb"
    local drv="$sb/drv_deadline_tree.sh"; _fkd_write_driver "$drv" "$(_fkd_pin unset)"
    local t0; t0="$(date +%s)"
    local out; out="$(run_mirror_driver bash "$sb" "$drv" on)"
    # Wait out the hang window, so a survivor has had time to write its marker.
    local left=$(( t0 + _FKD_HANG_SECS + 2 - $(date +%s) ))
    if [ "$left" -gt 0 ]; then sleep "$left"; fi
    local a1 a2
    a1="$(_fkd_alive "$sb/fetchpid.out")"; a2="$(_fkd_alive "$sb/grandchildpid.out")"
    if [ -f "$sb/gtp.out" ] && [ "$a1" = "no" ] && [ "$a2" = "no" ] \
        && [ ! -f "$sb/fetch-completed.out" ] && [ ! -f "$sb/grandchild-completed.out" ]; then
        pass "TC-DEADLINE4: deadline kill took the fetch's helper and its grandchild"
    else
        fail "TC-DEADLINE4: attempted=$([ -f "$sb/gtp.out" ] && echo yes || echo no) upload-pack-alive=$a1 grandchild-alive=$a2 upload-pack-completed=$([ -f "$sb/fetch-completed.out" ] && echo yes || echo no) grandchild-completed=$([ -f "$sb/grandchild-completed.out" ] && echo yes || echo no) — the startup deadline must kill the whole process tree, not only git. Output: $out"
    fi
    rm -rf "$sb"
}

# TC-DEADLINE5-<label> — one row of the shared table: the snippet hands the normalized
#   SESSION_SYNC_STARTUP_DEADLINE_MS to the engine as `startup ... --deadline-ms <n>`.
tc_deadline_config_row() {
    local label="$1" mode="$2" value="$3" want="$4"
    local sb; sb="$(make_mirror_sandbox 0)"
    _fkd_real_origin "$sb"
    _fkd_stub_engine "$sb"
    local drv="$sb/drv_deadline_cfg.sh"; _fkd_write_driver "$drv" "$(_fkd_pin "$mode" "$value")"
    local out; out="$(run_mirror_driver bash "$sb" "$drv" on)"
    local argv="$sb/engine-argv.out" got="" first="" count=0
    if [ -f "$argv" ]; then
        first="$(head -1 "$argv" | tr -d '\r')"
        got="$(awk '{ sub(/\r$/, "") } prev == "--deadline-ms" { print; exit } { prev = $0 }' "$argv")"
        count="$(grep -c -x -e '--deadline-ms' "$argv" || true)"
    fi
    if [ "$first" = "startup" ] && [ "$count" = "1" ] && [ "$got" = "$want" ]; then
        pass "TC-DEADLINE5-$label: $mode '$value' -> --deadline-ms $got"
    else
        fail "TC-DEADLINE5-$label: $mode '$value' must reach the engine as 'startup ... --deadline-ms $want'; engine-called=$([ -f "$argv" ] && echo yes || echo no) action='$first' deadline-flags=$count value='$got'. Output: $out"
    fi
    rm -rf "$sb"
}

tc_deadline_config_table() {
    local label mode value want rows=0
    while IFS='|' read -r label mode value want <&3; do
        case "$label" in ''|'#'*) continue ;; esac
        rows=$(( rows + 1 ))
        tc_deadline_config_row "$label" "$mode" "$value" "$want"
    done 3< "$_FKD_TABLE"
    [ "$rows" -gt 0 ] || fail "TC-DEADLINE5: no rows read from $_FKD_TABLE"
}

# TC-DEADLINE6 — the value comes from .env: the mirror gets $AGENTS_MAIN_ROOT/.env holding the
#   deadline while the process variable is unset, and the snippet must pass that value on.
tc_deadline_from_env_file() {
    local want=7500
    local sb; sb="$(make_mirror_sandbox 0)"
    _fkd_real_origin "$sb"
    _fkd_stub_engine "$sb"
    printf 'SESSION_SYNC_STARTUP_DEADLINE_MS=%s\n' "$want" > "$sb/agents/.env"
    local drv="$sb/drv_deadline_envfile.sh"; _fkd_write_driver "$drv" "$(_fkd_pin unset)"
    local out; out="$(run_mirror_driver bash "$sb" "$drv" on)"
    local argv="$sb/engine-argv.out" got=""
    if [ -f "$argv" ]; then
        got="$(awk '{ sub(/\r$/, "") } prev == "--deadline-ms" { print; exit } { prev = $0 }' "$argv")"
    fi
    if [ "$got" = "$want" ]; then
        pass "TC-DEADLINE6: .env SESSION_SYNC_STARTUP_DEADLINE_MS=$want (process variable unset) -> --deadline-ms $got"
    else
        fail "TC-DEADLINE6: .env SESSION_SYNC_STARTUP_DEADLINE_MS=$want with the process variable unset must reach the engine as --deadline-ms $want; engine-called=$([ -f "$argv" ] && echo yes || echo no) value='$got'. Output: $out"
    fi
    rm -rf "$sb"
}

tc_deadline_kills_hung_fetch          # TC-DEADLINE1
tc_deadline_kill_survives_set_e       # TC-DEADLINE2
tc_deadline_bounds_source_wall_clock  # TC-DEADLINE3
tc_deadline_kills_process_tree        # TC-DEADLINE4
tc_deadline_config_table              # TC-DEADLINE5-<label>
tc_deadline_from_env_file             # TC-DEADLINE6
