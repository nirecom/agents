#!/usr/bin/env bash
# tests/bin/feature-2687-test-host-load/internal-cases.sh — IN1-IN5: agents internal
# processes in _thl_load_compute. Roots (a) are the roots file; roots (b) are processes whose
# lower-cased name minus one trailing `.exe` is exactly `claude`; descendants follow ppid.
# The external game.exe always adds 1 core so every case has a nonzero positive control.

# in_pair <name> <proc-line ...> — prev/cur snapshots: the own root, game.exe +2000 ms, and each
# given process `<pid> <ppid> <name>` +4000 ms (rss 1 GiB).
in_pair() {
    local n="$1" p c a
    shift
    local -a prev=("$R0" "7100 1 0 4096 game.exe") cur=("$R0" "7100 1 2000 4096 game.exe")
    for a in "$@"; do
        set -- $a
        prev+=("$1 $2 0 1048576 $3"); cur+=("$1 $2 4000 1048576 $3")
    done
    p="$CD/$n.prev"; c="$CD/$n.cur"
    snap2 "$p" 600000 - "${prev[@]}"
    snap2 "$c" 602000 - "${cur[@]}"
    compute "$p" "$c"
}

case_begin "internal-claude" "bin/lib/test-host-load.sh"
# ── IN1 claude and its descendants are internal ─────────────────────────────
in_pair in1 "7400 1 claude" "7401 7400 node" "7402 7401 bash"
assert_eq "IN1 state=ok" "ok" "$(kv_of "$OUT" state)"
assert_near "IN1 claude, its child and grandchild excluded: only game.exe" 100 "$(kv_of "$OUT" external_centicores)" 2
case_ran IN1

# ── IN2 no partial match: a widget named after Claude is external ───────────
in_pair in2 "7500 1 Claude-Usage-Widget.exe"
assert_near "IN2 Claude-Usage-Widget.exe counts (2 + 1 cores)" 300 "$(kv_of "$OUT" external_centicores)" 2
in_pair in2b "7501 1 claude-code"
assert_near "IN2 claude-code counts (no prefix match)" 300 "$(kv_of "$OUT" external_centicores)" 2
case_ran IN2

# ── IN3 the match lower-cases the name and strips one .exe ──────────────────
in_pair in3 "7600 1 CLAUDE.EXE" "7601 7600 node.exe"
assert_near "IN3 CLAUDE.EXE and its child excluded" 100 "$(kv_of "$OUT" external_centicores)" 2
in_pair in3b "7602 1 claude.exe.exe"
assert_near "IN3 claude.exe.exe strips only one .exe: counts" 300 "$(kv_of "$OUT" external_centicores)" 2
case_ran IN3
case_end

case_begin "internal-roots" "bin/lib/test-host-load.sh"
# ── IN4 no (a) root: unmeasurable even when a claude (b) root exists ────────
snap2 "$CD/in4.prev" 600000 - "7400 1 0 4096 claude" "7100 1 0 4096 game.exe"
snap2 "$CD/in4.cur" 602000 - "7400 1 4000 4096 claude" "7100 1 2000 4096 game.exe"
compute "$CD/in4.prev" "$CD/in4.cur"
assert_eq "IN4 roots (a) absent: unmeasurable" "unmeasurable" "$(kv_of "$OUT" state)"
assert_eq "IN4 roots (a) absent: reason=roots" "roots" "$(kv_of "$OUT" reason)"
case_ran IN4

# ── IN5 mem_tests_mb is the rss of the (a) closure only ─────────────────────
snap2 "$CD/in5.prev" 600000 - "$R0" "7001 $ROOT_PID 0 20480 node" "7400 1 0 1048576 claude" "7100 1 0 4096 game.exe"
snap2 "$CD/in5.cur" 602000 - "$R0" "7001 $ROOT_PID 0 20480 node" "7400 1 4000 1048576 claude" "7100 1 2000 4096 game.exe"
compute "$CD/in5.prev" "$CD/in5.cur"
assert_eq "IN5 root 10 MB + child 20 MB; claude's 1 GiB and game.exe not added" "30" "$(kv_of "$OUT" mem_tests_mb)"
assert_near "IN5 positive control: game.exe is external" 100 "$(kv_of "$OUT" external_centicores)" 2
case_ran IN5
case_end

grp_done internal-cases.sh
