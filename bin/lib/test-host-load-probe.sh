#!/usr/bin/env bash
# The load probe (#2687, format 2 #2692): one snapshot of wall_ms, snapshot=2, the node host
# lines and every process's `<pid> <ppid> <cpu_ms> <rss_kb> <name>`. Sourced by
# test-host-lanes.sh; `bash <this file> probe` runs the real probe (Linux /proc, Windows CIM,
# else ps), bounded by bin/run-with-timeout.sh.

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
_THL_PROBE_LINE_RE='^(snapshot=2|host_busy_ms=[0-9]+|host_cpus=[0-9]+|host_mem_avail_kb=[0-9]+|host_mem_total_kb=[0-9]+|host_mem_scope=(host|cgroup)|[0-9]+ [0-9]+ [0-9]+ [0-9]+ [A-Za-z0-9._?-]{1,64})$'

# _thl_probe_bounded <cmd...> — run <cmd> under bin/run-with-timeout.sh; a copy of bin/lib
# without that helper (a relocated runner) falls back to timeout(1), then to an unbounded run.
_thl_probe_bounded() {
    local secs="$_THL_PROBE_SECS"
    # Clamped to one heartbeat so a hung probe cannot outlive the sampler claim's heartbeat.
    _thl_int "${TEST_LANES_HEARTBEAT:-}" "$THL_HEARTBEAT_DEFAULT"
    [ "$_THL_INT" -lt "$secs" ] && secs="$_THL_INT"
    if [ -f "$_THL_PROBE_TIMEOUT" ]; then
        bash "$_THL_PROBE_TIMEOUT" "$secs" "$@"
    elif command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
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

# _thl_load_probe_host [platform=] [availableMemory=] [constrainedMemory=] [freemem=] [totalmem=]
# — the node host lines (busy ms, CPU count, memory in kB and its scope); each argument
# overrides what node reports (bytes; `absent` = the API is missing). Nothing without node.
# shellcheck disable=SC2120  # the overrides are passed by the tests only
_thl_load_probe_host() {
    command -v node >/dev/null 2>&1 || return 0
    # shellcheck disable=SC2016  # the program is JavaScript, not bash
    node -e '
const os = require("os"), o = {};
for (const a of process.argv.slice(1)) { const i = a.indexOf("="); if (i > 0) o[a.slice(0, i)] = a.slice(i + 1); }
const pick = (k, f) => { try { if (k in o) return o[k] === "absent" ? undefined : Number(o[k]); return f(); } catch (e) { return undefined; } };
const plat = ("platform" in o) ? o.platform : process.platform;
let busy = 0; const c = os.cpus() || [];
for (const x of c) { const t = x.times; busy += t.user + t.nice + t.sys + t.irq; }
const out = ["host_busy_ms=" + Math.floor(busy), "host_cpus=" + c.length];
const tm = pick("totalmem", () => os.totalmem()), fm = pick("freemem", () => os.freemem());
const am = pick("availableMemory", () => typeof process.availableMemory === "function" ? process.availableMemory() : undefined);
const cm = pick("constrainedMemory", () => typeof process.constrainedMemory === "function" ? process.constrainedMemory() : undefined);
if (Number.isFinite(tm) && tm > 0) {
  let total = tm, scope = "host", avail;
  if (!Number.isFinite(am)) { if (plat !== "darwin") avail = fm; }
  else if (!Number.isFinite(cm)) avail = fm;
  else {
    avail = am;
    if (cm > 0 && cm < tm) { total = cm; scope = "cgroup"; }
  }
  if (Number.isFinite(avail) && avail >= 0) out.push("host_mem_avail_kb=" + Math.floor(Math.min(avail, total) / 1024));
  out.push("host_mem_total_kb=" + Math.floor(total / 1024), "host_mem_scope=" + scope);
}
console.log(out.join("\n"));' "$@" 2>/dev/null | tr -d '\r'
}

_thl_load_probe_linux() {
    local tck pk
    tck="$(getconf CLK_TCK 2>/dev/null)"
    [[ $tck =~ ^[1-9][0-9]*$ ]] || tck=100
    pk="$(getconf PAGESIZE 2>/dev/null)"
    [[ $pk =~ ^[1-9][0-9]*$ ]] || pk=4096
    _thl_load_wall_ms
    printf 'wall_ms=%s\nsnapshot=2\n' "$_THL_WALL_MS"
    _thl_load_probe_host
    # %.0f, not %s: mawk renders an integer past 2^31 in CONVFMT (scientific) notation.
    awk -v tck="$tck" -v pk="$pk" 'BEGIN {
        for (i = 1; i < ARGC; i++) {
            if ((getline line < ARGV[i]) > 0) {
                pid = ARGV[i]; sub(/^\/proc\//, "", pid); sub(/\/stat$/, "", pid)
                nm = line; sub(/^[^(]*\(/, "", nm); sub(/\) [^)]*$/, "", nm)
                gsub(/[^A-Za-z0-9._-]/, "?", nm); nm = substr(nm, 1, 64); if (nm == "") nm = "?"
                rest = line; sub(/^.*\) /, "", rest)
                n = split(rest, r, " ")
                if (n >= 22 && pid ~ /^[0-9]+$/)
                    printf "%s %s %.0f %.0f %s\n", pid, r[2], int((r[12] + r[13]) * 1000 / tck), int(r[22] * pk / 1024), nm
            }
            close(ARGV[i])
        }
    }' /proc/[0-9]*/stat 2>/dev/null
}

_thl_load_probe_windows() {
    _thl_load_wall_ms
    printf 'wall_ms=%s\nsnapshot=2\n' "$_THL_WALL_MS"
    _thl_load_probe_host
    # shellcheck disable=SC2016  # the PowerShell program is expanded by PowerShell, not bash
    powershell.exe -NoProfile -NonInteractive -Command '
        foreach ($p in Get-CimInstance -ClassName Win32_Process) {
            $n = ([string]$p.Name) -replace "[^A-Za-z0-9._-]", "?"
            if ($n.Length -gt 64) { $n = $n.Substring(0, 64) }
            if ($n -eq "") { $n = "?" }
            "{0} {1} {2} {3} {4}" -f $p.ProcessId, $p.ParentProcessId,
                [uint64][math]::Floor(([decimal]$p.KernelModeTime + [decimal]$p.UserModeTime) / 10000),
                [uint64][math]::Floor([decimal]$p.WorkingSetSize / 1024), $n
        }' 2>/dev/null | tr -d '\r'
}

_thl_load_probe_ps() {
    _thl_load_wall_ms
    printf 'wall_ms=%s\nsnapshot=2\n' "$_THL_WALL_MS"
    _thl_load_probe_host
    ps -A -o pid=,ppid=,time=,rss=,comm= 2>/dev/null | awk '{
        t = $3; d = 0
        if (t ~ /-/) { d = t; sub(/-.*/, "", d); sub(/^[^-]*-/, "", t) }
        n = split(t, a, ":"); s = 0
        for (i = 1; i <= n; i++) s = s * 60 + a[i]
        nm = $5; for (i = 6; i <= NF; i++) nm = nm " " $i
        sub(/.*\//, "", nm); gsub(/[^A-Za-z0-9._-]/, "?", nm); nm = substr(nm, 1, 64); if (nm == "") nm = "?"
        if ($1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/) printf "%s %s %.0f %s %s\n", $1, $2, int((d * 86400 + s) * 1000), $4, nm
    }'
}

# _thl_load_probe_real — the platform probe; stdout is the snapshot.
_thl_load_probe_real() {
    case "${OSTYPE:-}" in
        msys*|cygwin*) command -v powershell.exe >/dev/null 2>&1 && { _thl_load_probe_windows; return 0; } ;;
        linux*) [ -d /proc/self ] && { _thl_load_probe_linux; return 0; } ;;
    esac
    _thl_load_probe_ps
}

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = probe ]; then
    _thl_load_probe_real
    exit $?
fi
