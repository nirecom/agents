#!/usr/bin/env bash
# The load probe (#2687): one snapshot of wall_ms, the host busy counter and every process's
# `<pid> <ppid> <cpu_ms>`. Sourced by test-host-lanes.sh; `bash <this file> probe` runs the
# real probe (Linux /proc, Windows CIM, else ps), bounded by bin/run-with-timeout.sh.

_THL_PROBE_SELF="${BASH_SOURCE[0]}"
case "$_THL_PROBE_SELF" in
    */*) ;;
    *) _THL_PROBE_SELF="./$_THL_PROBE_SELF" ;;
esac
case "$_THL_PROBE_SELF" in
    [/]*|[A-Za-z]:*) ;;
    *) _THL_PROBE_SELF="$PWD/$_THL_PROBE_SELF" ;;
esac
_THL_PROBE_TIMEOUT="${_THL_PROBE_SELF%/*}/../run-with-timeout.sh"
_THL_PROBE_SECS=20
_THL_PROBE_LINE_RE='^(host_busy_ms=([0-9]+|unavailable)|host_idle_100ns=[0-9]+|host_ts_100ns=[0-9]+|host_cpus=[0-9]+|[0-9]+ [0-9]+ [0-9]+)$'

# _thl_probe_bounded <cmd...> — run <cmd> under bin/run-with-timeout.sh; a copy of bin/lib
# without that helper (a relocated runner) falls back to timeout(1), then to an unbounded run.
_thl_probe_bounded() {
    if [ -f "$_THL_PROBE_TIMEOUT" ]; then
        bash "$_THL_PROBE_TIMEOUT" "$_THL_PROBE_SECS" "$@"
    elif command -v timeout >/dev/null 2>&1; then
        timeout "$_THL_PROBE_SECS" "$@"
    else
        "$@"
    fi
}

# _thl_load_snapshot <out> — 0 with a well-formed snapshot in <out>; the
# TEST_LANES_LOAD_PROBE_CMD seam replaces the real probe.
_thl_load_snapshot() {
    local out="$1" line n=0
    if [ -n "${TEST_LANES_LOAD_PROBE_CMD:-}" ]; then
        _thl_probe_bounded "$TEST_LANES_LOAD_PROBE_CMD" > "$out" 2>/dev/null </dev/null || return 1
    else
        _thl_probe_bounded bash "$_THL_PROBE_SELF" probe > "$out" 2>/dev/null </dev/null || return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        if [ "$n" -eq 1 ]; then
            [[ $line =~ ^wall_ms=[0-9]+$ ]] || return 1
        else
            [[ $line =~ $_THL_PROBE_LINE_RE ]] || return 1
        fi
    done < "$out"
    [ "$n" -ge 2 ]
}

# _thl_load_wall_ms — _THL_WALL_MS = epoch milliseconds; the date fork is the fallback
# for a bash without EPOCHREALTIME.
_thl_load_wall_ms() {
    local t="${EPOCHREALTIME:-}"
    if [[ $t =~ ^[0-9]+[.,][0-9]{6}$ ]]; then
        t="${t//[.,]/}"; _THL_WALL_MS="${t%???}"; return 0
    fi
    t="$(date +%s%3N 2>/dev/null)"
    if [[ $t =~ ^[0-9]{13,}$ ]]; then _THL_WALL_MS="$t"; return 0; fi
    printf -v t '%(%s)T' -1
    _THL_WALL_MS="${t}000"
}

_thl_load_probe_linux() {
    local tck
    tck="$(getconf CLK_TCK 2>/dev/null)"
    [[ $tck =~ ^[1-9][0-9]*$ ]] || tck=100
    _thl_load_wall_ms
    printf 'wall_ms=%s\n' "$_THL_WALL_MS"
    awk -v tck="$tck" 'BEGIN {
        busy = "unavailable"
        while ((getline line < "/proc/stat") > 0) {
            if (line ~ /^cpu /) { split(line, f, " "); busy = int((f[2] + f[3] + f[4] + f[7] + f[8] + f[9]) * 1000 / tck); break }
        }
        close("/proc/stat")
        # %.0f, not %s: mawk renders an integer past 2^31 in CONVFMT (scientific) notation.
        if (busy == "unavailable") print "host_busy_ms=unavailable"; else printf "host_busy_ms=%.0f\n", busy
        for (i = 1; i < ARGC; i++) {
            if ((getline line < ARGV[i]) > 0) {
                pid = ARGV[i]; sub(/^\/proc\//, "", pid); sub(/\/stat$/, "", pid)
                rest = line; sub(/^.*\) /, "", rest)
                n = split(rest, r, " ")
                if (n >= 13 && pid ~ /^[0-9]+$/) printf "%s %s %.0f\n", pid, r[2], int((r[12] + r[13]) * 1000 / tck)
            }
            close(ARGV[i])
        }
    }' /proc/[0-9]*/stat 2>/dev/null
}

_thl_load_probe_windows() {
    # shellcheck disable=SC2016  # the PowerShell program is expanded by PowerShell, not bash
    powershell.exe -NoProfile -NonInteractive -Command '
        try {
            $c = @(Get-CimInstance -ClassName Win32_PerfRawData_PerfOS_Processor -ErrorAction Stop | Where-Object { $_.Name -ne "_Total" })
            $idle = [decimal]0; foreach ($x in $c) { $idle += [decimal]$x.PercentIdleTime }
            $ts = [decimal]$c[0].Timestamp_Sys100NS
            "wall_ms={0}" -f [uint64][math]::Floor([decimal][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
            "host_idle_100ns={0}" -f [uint64]$idle
            "host_ts_100ns={0}" -f [uint64]$ts
            "host_cpus={0}" -f $c.Count
        } catch {
            "wall_ms={0}" -f [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            "host_busy_ms=unavailable"
        }
        foreach ($p in Get-CimInstance -ClassName Win32_Process) {
            "{0} {1} {2}" -f $p.ProcessId, $p.ParentProcessId, [uint64][math]::Floor(([decimal]$p.KernelModeTime + [decimal]$p.UserModeTime) / 10000)
        }' 2>/dev/null | tr -d '\r'
}

_thl_load_probe_ps() {
    _thl_load_wall_ms
    printf 'wall_ms=%s\nhost_busy_ms=unavailable\n' "$_THL_WALL_MS"
    ps -A -o pid=,ppid=,time= 2>/dev/null | awk '{
        t = $3; d = 0
        if (t ~ /-/) { d = t; sub(/-.*/, "", d); sub(/^[^-]*-/, "", t) }
        n = split(t, a, ":"); s = 0
        for (i = 1; i <= n; i++) s = s * 60 + a[i]
        if ($1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/) printf "%s %s %d\n", $1, $2, (d * 86400 + s) * 1000
    }'
}

# _thl_load_probe_real — the platform probe; stdout is the snapshot.
_thl_load_probe_real() {
    case "${OSTYPE:-}" in
        msys*|cygwin*) command -v powershell.exe >/dev/null 2>&1 && { _thl_load_probe_windows; return 0; } ;;
        linux*) [ -r /proc/stat ] && { _thl_load_probe_linux; return 0; } ;;
    esac
    _thl_load_probe_ps
}

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = probe ]; then
    _thl_load_probe_real
    exit $?
fi
