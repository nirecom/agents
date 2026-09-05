# shellcheck shell=bash
# Tests: tests/bin-concern-ledger-reducer/namespace-guard.sh
# Tags: concern-ledger, test-harness, namespace-guard, positive-control, TL2, scope:common, scenarios
# The stand-in harness, the scenario driver and the two expectation helpers every case
# file below is written against. Each scenario runs in its own bash process, so a
# clobbered name can never reach this suite's own counters. Emits no PASS/FAIL lines.
SCEN_COMMON="$WORK/common.sh"
SCEN="$WORK/scenario.sh"

cat > "$SCEN_COMMON" <<'COMMON_EOF'
# shellcheck shell=bash
# The harness surface tests/bin-concern-ledger-reducer.sh presents to the guard: the
# same scalar names, the same pass/fail entry points, the same `set +u` load context.
set +u
AGENTS_ROOT="$NSG_AGENTS_ROOT"
LIB="$NSG_LIB"
CLI="$AGENTS_ROOT/bin/concern-ledger"
SUITE_DIR="$AGENTS_ROOT/tests/bin-concern-ledger-reducer"
GUARD="$NSG_GUARD"
TMPDIR_BASE="$NSG_CASE_DIR"
WORK="$TMPDIR_BASE/work"
mkdir -p "$WORK" "$TMPDIR_BASE/ns-guard"
PASS=0
FAIL=0
NSG_REPORT="$TMPDIR_BASE/reports.txt"
: > "$NSG_REPORT"
pass() { printf 'PASS: %s\n' "$1"; }
# A TRIPWIRE, not the report channel: the guard prints its own `FAIL:` line and bumps the
# FAIL counter itself, so anything reaching $NSG_REPORT means it routed the verdict through
# a harness name a case file can replace with a no-op. Recording instead of counting keeps
# direction A's retained FAIL value the guard's alone to move.
fail() { printf 'REPORT %s\n' "$1" >> "$NSG_REPORT"; }
nsg_outer() { nsg_inner; }
nsg_inner() { clg_assert_library_intact "ctx-G7b"; }
# nsg_emit <assert-rc> <mode> — the channels a swallowing fail() cannot suppress, one
# per line so the reader can anchor them, plus an end marker naming the mode. Without
# the marker a scenario that died mid-way is indistinguishable from one that ran.
# NSG-FAIL carries the counter the dispatcher's banner is computed from: a collision the
# guard prints but never counts still lets the suite end on "All tests passed".
nsg_emit() {
    printf 'NSG-RC=%s\n' "$1" >&2
    printf 'NSG-COUNT=%s\n' "${CLG_REPORT_COUNT-unset}" >&2
    printf 'NSG-LAST=%s\n' "${CLG_LAST_REPORT-unset}" >&2
    printf 'NSG-FAIL=%s\n' "${FAIL-unset}" >&2
    printf 'NSG-DONE=%s\n' "$2" >&2
}
COMMON_EOF

cat > "$SCEN" <<'SCEN_EOF'
#!/usr/bin/env bash
# One scenario per invocation. The file-scope order below is the contract the guard is
# written against: variable names are captured at FILE scope (never inside a function,
# where FUNCNAME/BASH_LINENO would join the set) on both sides of the library load.
. "$NSG_COMMON"
MODE="$1"

hx_probe() { printf 'original\n'; }

# Installed BEFORE the guard's baseline, so neither is itself a collision: G1un's no-op
# fail() is the starting state it has to stay silent about, and G12's non-zero counters
# are what a backward move is measured against (from 0 nothing can move backward).
case "$MODE" in
    G1un) fail() { :; } ;;
    G12*) PASS=5; FAIL=4 ;;
esac

. "$GUARD"
# G9 skips both setup calls on purpose: it asserts against a state the guard was
# never told about.
if [ "$MODE" != "G9" ]; then
    compgen -v | sort > "$TMPDIR_BASE/ns-guard/var-before.txt"
    clg_snapshot_before
fi

# The window between the two captures is what a naive diff attributes to the library,
# so the names the exclusion rules must drop are planted here.
if [ "${MODE#G7}" != "$MODE" ]; then
    CLG_LIB_LOADED=1
    clg_probe_flag=1
fi
# G13w — a harness helper born in that same window. It is the LAST position at
# which a post-snapshot name is still attributed to a watched set (the library's,
# by the declare -F diff), so it is the covered side of G13's boundary.
if [ "$MODE" = "G13w" ]; then
    hx_window() { printf 'window-original\n'; }
fi

if [ "$MODE" != "G8" ]; then
    source "$LIB"
fi
if [ "$MODE" != "G9" ]; then
    compgen -v | sort > "$TMPDIR_BASE/ns-guard/var-after.txt"
    clg_record_library_names
fi

# Real order (tests/bin-concern-ledger-reducer.sh): cl/run_cli/reduce_round are
# defined at 146-151 and CL_SHA_TOOL is created by the cl_sha256 probe at 139 —
# every one of them AFTER both baselines above have been taken.
case "$MODE" in
    G13a|G13z|G13n) hx_late() { printf 'late-original\n'; } ;;
    G13s) cl_sha256 "cl-identity-probe" >/dev/null 2>&1 || true ;;
esac

case "$MODE" in
    G1) hx_probe() { printf 'clobbered\n'; }
        clg_assert_harness_intact "ctx-G1" ;;
    G1v) WORK="$WORK/tampered"
         clg_assert_harness_intact "ctx-G1v" ;;
    G1w) PASS=99
         clg_assert_harness_intact "ctx-G1w" ;;
    # G1s-* is G1v/G1w's table: the same tampering over the rest of the retained scalar
    # set, each name in its own process so one report can never mask another.
    G1s-*) _nsg_hs="${MODE#G1s-}"
           declare -g "$_nsg_hs=${!_nsg_hs}/nsg-tampered"
           clg_assert_harness_intact "ctx-$MODE" ;;
    # G1x/G1y clobber the reporting primitives themselves. G1y's replacement keeps the
    # original body and only appends to it, so the tripwire still fires if the guard ever
    # goes back to reporting THROUGH fail() — the collision itself arrives on stdout.
    G1x) pass() { printf 'clobbered\n'; }
         clg_assert_harness_intact "ctx-G1x" ;;
    G1y) fail() { printf 'REPORT %s\n' "$1" >> "$NSG_REPORT"; : clobbered; }
         clg_assert_harness_intact "ctx-G1y" ;;
    # G1u is the attack the report path is hardened against: a COMPLETE no-op reporter.
    # The collision must still reach stdout AND still bump the counter the banner is
    # computed from, so this arm adds the guard's own tally and rc via nsg_emit.
    G1u) fail() { :; }
         clg_assert_harness_intact "ctx-G1u"
         nsg_emit "$?" G1u ;;
    # G1un — G1u's allow side. The same no-op fail(), but present since before the
    # baseline and with nothing shadowed: a guard that reported whenever it could not
    # read fail() would satisfy G1u while saying nothing about the namespace.
    G1un) clg_assert_harness_intact "ctx-G1un"
          nsg_emit "$?" G1un ;;
    # G1z/G3x/G7d/G7e are the disappearance-and-retype series: a name stops being what it
    # was without any re-definition. G7f is their negative control.
    G1z) unset -f pass
         clg_assert_harness_intact "ctx-G1z" ;;
    G2) clg_assert_harness_intact "ctx-G2" ;;
    G2v) WORK="$WORK"
         PASS="$PASS"
         clg_assert_harness_intact "ctx-G2v" ;;
    G2x) pass() { printf 'PASS: %s\n' "$1"; }
         fail() { printf 'REPORT %s\n' "$1" >> "$NSG_REPORT"; }
         clg_assert_harness_intact "ctx-G2x" ;;
    G3) cl_slot() { printf 'clobbered\n'; }
        clg_assert_library_intact "ctx-G3" ;;
    G3x) unset -f cl_slot
         clg_assert_library_intact "ctx-G3x" ;;
    # G3p-* is G3's table over the library's PRIVATE surface: the _cl_* helpers the
    # public entry points call, which a case file can shadow without touching cl_*.
    G3p-*) _nsg_lf="${MODE#G3p-}"
           eval "$_nsg_lf() { printf 'clobbered\n'; }"
           clg_assert_library_intact "ctx-$MODE" ;;
    G4) clg_assert_library_intact "ctx-G4" ;;
    # G5all/G3u take the whole owned set NSG_ALL_NAMES was DERIVED from the library for,
    # in one process each: overwritten, then made to disappear. A per-name process would
    # be 70+ bash spawns for the same claim.
    G5all) for _nsg_n in $NSG_ALL_NAMES; do eval "$_nsg_n() { printf 'clobbered\n'; }"; done
           clg_assert_library_intact "ctx-G5all" ;;
    G3u) for _nsg_n in $NSG_ALL_NAMES; do unset -f "$_nsg_n"; done
         clg_assert_library_intact "ctx-G3u" ;;
    # G11 — the guard's own entry points. Whichever one is clobbered cannot be the one
    # that reports it, so the sibling assert is called instead; the verdict is read off
    # nsg_emit, never off fail(), for the same reason G1u is.
    G11o-*|G11z-*) _nsg_g="${MODE#G11?-}"
         case "$MODE" in
             G11o-*) eval "$_nsg_g() { : ; }" ;;
             *) unset -f "$_nsg_g" ;;
         esac
         if [ "$_nsg_g" = "clg_assert_harness_intact" ]; then
             clg_assert_library_intact "ctx-$MODE"
         else
             clg_assert_harness_intact "ctx-$MODE"
         fi
         nsg_emit "$?" "$MODE" ;;
    G11n) clg_assert_harness_intact "ctx-G11n"
          nsg_emit "$?" G11n ;;
    G7a) CLG_LIB_LOADED=tampered
         clg_probe_flag=tampered
         clg_assert_library_intact "ctx-G7a" ;;
    G7b) SECONDS=0
         : "$RANDOM"
         nsg_outer ;;
    G7c-*) _nsg_scalar="${MODE#G7c-}"
           declare -g "$_nsg_scalar=nsg-tampered"
           clg_assert_library_intact "ctx-$MODE" ;;
    G7d) unset CL_DISCOVERY_FLAG
         clg_assert_library_intact "ctx-G7d" ;;
    G7e) unset CL_HASH_CACHE
         declare -g CL_HASH_CACHE="no-longer-an-array"
         clg_assert_library_intact "ctx-G7e" ;;
    G7f) CL_HASH_CACHE[nsg-key]=first
         CL_HASH_CACHE[nsg-key]=second
         CL_HASH_CACHE[nsg-other]=third
         clg_assert_library_intact "ctx-G7f" ;;
    G8) clg_assert_library_intact "ctx-G8-empty"
        case_probe_one() { :; }
        case_probe_two() { :; }
        clg_assert_library_intact "ctx-G8-after-cases" ;;
    G9) clg_assert_harness_intact "ctx-G9"
        clg_assert_library_intact "ctx-G9" ;;
    G10) for _i in 1 2 3 4 5 6; do
             clg_assert_harness_intact "ctx-G10-h$_i"
             clg_assert_library_intact "ctx-G10-l$_i"
         done ;;
    # G12 — clg_rearm_counters, the re-pin the dispatcher runs before its post-cases
    # check point. G12f is the by-design advance across nine case files; G12b/G12p are
    # the same call reached after a counter moved BACKWARD, which no test run produces
    # and a blind re-pin would launder into ordinary progress.
    G12f) PASS=$((PASS + 7))
          FAIL=$((FAIL + 3))
          clg_rearm_counters
          clg_assert_harness_intact "ctx-G12f" ;;
    G12b) FAIL=1
          clg_rearm_counters ;;
    G12p) PASS=2
          clg_rearm_counters ;;
    # G12c-<counter>-<shape> — the counter did not move backward, it stopped being
    # a number. `` and `abc` both make the dispatcher's `[[ $FAIL -eq 0 ]]` banner
    # read "All tests passed"; `-1` is a count no run can produce. None is an
    # advance, so none may be re-pinned as the new baseline unreported.
    G12c-*) _nsg_c="${MODE#G12c-}"
            case "${_nsg_c#*-}" in
                empty) declare -g "${_nsg_c%%-*}=" ;;
                negative) declare -g "${_nsg_c%%-*}=-1" ;;
                alpha) declare -g "${_nsg_c%%-*}=abc" ;;
            esac
            clg_rearm_counters ;;
    # G13 — the real-order series. hx_window is covered (it is in the library's
    # derived set); hx_late and CL_SHA_TOOL are the shapes cl/run_cli/reduce_round
    # and the sha probe actually take, and both asserts are called so a report
    # from either direction counts.
    G13w) hx_window() { printf 'clobbered\n'; }
          clg_assert_library_intact "ctx-G13w" ;;
    G13a) hx_late() { printf 'clobbered\n'; }
          clg_assert_harness_intact "ctx-G13a"
          clg_assert_library_intact "ctx-G13a" ;;
    G13z) unset -f hx_late
          clg_assert_harness_intact "ctx-G13z"
          clg_assert_library_intact "ctx-G13z" ;;
    G13s) CL_SHA_TOOL=nsg-tampered
          clg_assert_harness_intact "ctx-G13s"
          clg_assert_library_intact "ctx-G13s" ;;
    G13n) clg_assert_harness_intact "ctx-G13n"
          clg_assert_library_intact "ctx-G13n" ;;
    # G14 — clg_close_window's own disarm contract (#2111 gap): G13w proves the DEBUG
    # trap fires while the window is open; nothing before proves it actually clears.
    # A stuck-open trap silently re-imposes the per-command declare -F/file-write cost
    # #2111 removes, on every later command any case file runs.
    G14) clg_assert_harness_intact "ctx-G14"
         printf 'NSG-TRAP=%s\n' "$(trap -p DEBUG)" >&2
         printf 'NSG-DONE=G14\n' >&2 ;;
    *) printf 'unknown scenario mode: %s\n' "$MODE" >&2; exit 2 ;;
esac
SCEN_EOF

export NSG_AGENTS_ROOT="$AGENTS_ROOT"
export NSG_LIB="$LIB"
export NSG_GUARD="$GUARD"
export NSG_COMMON="$SCEN_COMMON"

# The guard's own report line, verbatim from clg_report: `FAIL: <message>` where the
# message is `namespace collision at <context>: <name> <what>`. It is the assertion
# channel because clg_report echoes it directly instead of calling fail(), which is
# itself a harness name and therefore replaceable by any case file.
NSG_COLLISION_RE='^FAIL: namespace collision at '

SC_OUT=""; SC_REPORT=""; SC_RC=0; SC_COLLISION=""; SC_NOISE=""
run_scenario() {
    local mode="$1" dir="$WORK/$1"
    rm -rf "$dir"
    mkdir -p "$dir/ns-guard"
    export NSG_CASE_DIR="$dir"
    SC_RC=0
    SC_OUT="$(bash "$TIMEOUT" 60 bash "$SCEN" "$mode" 2>&1)" || SC_RC=$?
    SC_REPORT="$(cat "$dir/reports.txt" 2>/dev/null || true)"
    SC_COLLISION="$(printf '%s\n' "$SC_OUT" | grep -E "$NSG_COLLISION_RE" || true)"
    SC_NOISE="$(printf '%s\n' "$SC_OUT" | grep -vE "$NSG_COLLISION_RE" | grep -v '^[[:space:]]*$' || true)"
}

# nsg_has_collision <collision lines> <name> <context> — one line whose context AND
# colliding name are both exactly the expected ones. Substring matching would grade a
# case green off the report's own `FAIL:` prefix, or off a context that merely embeds
# the name; the split is done here so the two fields are compared as fields.
nsg_has_collision() {
    local nsg_l
    while IFS= read -r nsg_l; do
        [[ "$nsg_l" =~ ^FAIL:\ namespace\ collision\ at\ (.+):\ ([A-Za-z_][A-Za-z0-9_]*)\  ]] || continue
        [[ "${BASH_REMATCH[1]}" == "$3" && "${BASH_REMATCH[2]}" == "$2" ]] && return 0
    done <<< "$1"
    return 1
}

brief() { printf '%s' "$1" | head -4 | tr '\n' ' ' | cut -c1-320; }

# tbl_input_at <raw table field> — drop the padding; `~` is a space, `@` a newline.
tbl_input_at() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    s="${s//\~/ }"
    printf '%s' "${s//@/$'\n'}"
}

# expect_silent <label> <mode> — nothing was shadowed, so the guard must print no
# collision line, reach the stand-in fail() not at all, add no other output, and exit 0.
expect_silent() {
    run_scenario "$2"
    if [[ -n "$SC_COLLISION" ]]; then
        fail "$1 — the guard reported a collision on an untouched namespace: $(brief "$SC_COLLISION")"
    elif [[ -n "$SC_REPORT" ]]; then
        fail "$1 — nothing was shadowed, yet the harness fail() was called: $(brief "$SC_REPORT")"
    elif [[ -n "$SC_OUT" ]]; then
        fail "$1 — the guard wrote to stdout/stderr where silence is required: $(brief "$SC_OUT")"
    elif [[ "$SC_RC" != "0" ]]; then
        fail "$1 — scenario exited $SC_RC; the guard must never exit on its own"
    else
        pass "$1"
    fi
}

# expect_report <label> <mode> <colliding-name> <context> — the guard must print its own
# `FAIL: namespace collision at <context>: <name> …` line, route nothing through the
# harness fail() (a name any case file can neuter — the whole reason that channel is no
# longer the one read here), add no other output, and still not exit.
# Presence, not exclusivity: bumping FAIL is itself a change to a watched harness scalar,
# so a direction-A report is routinely followed by a second line naming FAIL. SC_NOISE
# holds everything that is not a collision line and is what must stay empty.
expect_report() {
    run_scenario "$2"
    if [[ -z "$SC_COLLISION" ]]; then
        fail "$1 — no collision reported (rc=$SC_RC); output: $(brief "$SC_OUT")"
    elif ! nsg_has_collision "$SC_COLLISION" "$3" "$4"; then
        fail "$1 — a collision was reported but no line names $3 at context $4: $(brief "$SC_COLLISION")"
    elif [[ -n "$SC_REPORT" ]]; then
        fail "$1 — the report is right but it travelled through the harness fail(), which one line in a case file can turn into a no-op: $(brief "$SC_REPORT")"
    elif [[ -n "$SC_NOISE" ]]; then
        fail "$1 — the report is right but $(printf '%s' "$SC_NOISE" | wc -c | tr -d '[:space:]') byte(s) of non-report output also leaked to stdout/stderr, where silence is required: $(brief "$SC_NOISE")"
    elif [[ "$SC_RC" != "0" ]]; then
        fail "$1 — the report is right but the scenario exited $SC_RC; the guard reports and returns, it never exits"
    else
        pass "$1"
    fi
}

# nsg_verdict <scenario output> <mode> -> absent | incomplete | no-verdict | ok
# The classifier for every case whose reporting path is the thing being clobbered.
# It is a PURE function of text, which is what lets G1uc drive it over synthetic output.
# `ok` needs the mode's own end marker AND one anchored guard-owned channel carrying a
# non-empty verdict: a bare non-zero exit, a stray "fail" anywhere in the output, or a
# marker left by some other mode are all things a broken scenario produces on its own.
nsg_verdict() {
    local out="$1" mode="$2"
    if printf '%s\n' "$out" | grep -Fq 'command not found'; then printf 'absent'; return 0; fi
    if ! printf '%s\n' "$out" | grep -qxF "NSG-DONE=$mode"; then printf 'incomplete'; return 0; fi
    if printf '%s\n' "$out" | grep -qE '^NSG-RC=[1-9][0-9]*$'; then printf 'ok'; return 0; fi
    if printf '%s\n' "$out" | grep -qE '^NSG-COUNT=[1-9][0-9]*$'; then printf 'ok'; return 0; fi
    if printf '%s\n' "$out" | grep -qE '^NSG-LAST=.+$' \
        && ! printf '%s\n' "$out" | grep -qxF 'NSG-LAST=unset'; then printf 'ok'; return 0; fi
    printf 'no-verdict'
}
