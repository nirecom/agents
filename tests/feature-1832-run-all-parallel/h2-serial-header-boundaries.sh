#!/usr/bin/env bash
# tests/feature-1832-run-all-parallel/h2-serial-header-boundaries.sh
# Tests: tests/run-all.sh, bin/lib/run-all-parallelism.sh
# Tags: tests, bin, parallel, frontmatter, convention, boundary, table-driven, TL2, scope:issue-specific
# Serial: observes real lane concurrency, so it must not share the host with another test

# WHY (CPR-WPH): `# Serial: <reason>` uses TWO windows — WRITER accepts the
# header only in the first 10 lines, RUNNER scans the first 20 (Postel: accept
# a slightly late author). This file walks the boundary (1/9/10/11/20/21) plus
# malformed shapes, asserting the lane the runner ACTUALLY used at runtime.

# HOW: each row's fixture has two FILLER tests marking an in-flight file while
# they sleep, plus a SUBJECT that counts in-flight markers it can see — parallel
# sees peers, serial (runs alone) sees zero. `absent-control` is the fence: a
# header-less file seeing zero peers means nothing ran concurrently at all.

# RED-FIRST: `--print-plan` and the serial lane don't exist yet — plan/runtime
# columns are red for every `parallel`-expecting row; `serial` rows are green
# today only because nothing runs concurrently (the control row proves it).

# TL3 gap (what this TL2 test does NOT catch): whether the 20-line reader window
# fits real corpus frontmatter shapes, and lane behavior under a loaded CI host.
# Mitigation: bin/check-verification-gate.sh at WORKFLOW_USER_VERIFIED preflight.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REAL_RUNNER="$AGENTS_DIR/tests/run-all.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/ra-h2-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# --- fixture isolation (rules/test/fixture-isolation.md) --------------------
export CLAUDE_WORKFLOW_DIR="$TMPD/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPD/workflow-plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
export RUN_ALL_CACHE_DIR="$TMPD/cache"
mkdir -p "$RUN_ALL_CACHE_DIR"

# --- ambient sanitization (M-ambient), self-contained ------------------------

# WHY: RUN_ALL_JOBS/DEADLINE/PROGRESS/REAP and FEATURE_644_PHASE change runner
# behavior; inherited values would rewrite verdicts, so every child goes through senv().

# CAVEAT: GNU `env` stops parsing options at the first NAME=VALUE, so `-u NAME`
# flags must precede pass-through assignments — senv() owns that ordering.
senv() {
    env -u RUN_ALL_JOBS -u RUN_ALL_DEADLINE -u RUN_ALL_PROGRESS -u RUN_ALL_REAP \
        -u FEATURE_644_PHASE "$@"
}

# run_pinned <secs> <NAME=VALUE>... -- <cmd> <args>...
# senv must sit OUTERMOST: bin/run-with-timeout.sh execs its argv directly, and a
# shell function is not an executable, so `run-with-timeout ... senv ...` would
# die with 127 and silently run nothing at all.
run_pinned() {
    local secs="$1"; shift
    local pins=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do pins+=("$1"); shift; done
    [ $# -gt 0 ] && shift
    senv ${pins[@]+"${pins[@]}"} bash "$RWT" "$secs" "$@"
}
AMBIENT_VARS="RUN_ALL_JOBS RUN_ALL_DEADLINE RUN_ALL_PROGRESS RUN_ALL_REAP FEATURE_644_PHASE"
unset RUN_ALL_JOBS RUN_ALL_DEADLINE RUN_ALL_PROGRESS RUN_ALL_REAP FEATURE_644_PHASE

case_ambient_sanitized() {
    local probe="$TMPD/ambient-probe.sh" got want v
    {
        printf '#!/usr/bin/env bash\n'
        printf 'for v in %s; do printf "%%s=%%s " "$v" "${!v-<unset>}"; done\n' "$AMBIENT_VARS"
    } > "$probe"
    want=""
    for v in $AMBIENT_VARS; do want="$want$v=<unset> "; done
    got="$(RUN_ALL_JOBS=hostile RUN_ALL_DEADLINE=1 RUN_ALL_PROGRESS=hostile \
        RUN_ALL_REAP=hostile FEATURE_644_PHASE=9 senv bash "$probe" 2>/dev/null)"
    assert_eq "h2/ambient/senv-strips-every-hostile-value" "$want" "$got"
    # And the pass-through half: a deliberate pin must survive the same call.
    got="$(RUN_ALL_JOBS=hostile senv "RUN_ALL_JOBS=4" bash "$probe" 2>/dev/null \
        | sed -n 's/^RUN_ALL_JOBS=\([^ ]*\).*/\1/p')"
    assert_eq "h2/ambient/senv-still-honours-a-deliberate-pin" "4" "$got"
}

# ===========================================================================
# Fixture construction
# ===========================================================================

# mk_row_root <root> <header-line-no> <header-text>
#   0 as the line number means "no header at all".
mk_row_root() {
    local root="$1" pos="$2" hdr="$3" i
    mkdir -p "$root/bin" "$root/tests" "$root/inflight"
    cp "$REAL_RUNNER" "$root/bin/run-all.sh"
    for i in 1 2; do
        {
            printf '#!/usr/bin/env bash\n'
            printf ': > "%s/f%s"\n' "$root/inflight" "$i"
            printf 'sleep 0.6\n'
            printf 'rm -f "%s/f%s"\n' "$root/inflight" "$i"
            printf 'exit 0\n'
        } > "$root/tests/a-fill$i.sh"
    done
    {
        if [ "$pos" = "1" ]; then
            printf '%s\n' "$hdr"
        else
            printf '#!/usr/bin/env bash\n'
            i=2
            while [ "$i" -lt "$pos" ]; do printf '# pad\n'; i=$((i + 1)); done
            [ "$pos" != "0" ] && printf '%s\n' "$hdr"
        fi
        printf 'sleep 0.25\n'
        printf 'find "%s" -type f 2>/dev/null | grep -c . > "%s"\n' "$root/inflight" "$root/obs"
        printf 'exit 0\n'
    } > "$root/tests/z-subject.sh"
}

# ===========================================================================
# WRITER-side verdicts: ok (header in first 10 lines), out-of-window (canonical
# shape below line 10), malformed (near-miss shape), no-header (nothing at all).
# ===========================================================================
writer_verdict() {
    local f="$1" n
    n="$(grep -nE '^# Serial:[[:space:]]*[^[:space:]]' "$f" 2>/dev/null | head -1 | cut -d: -f1)"
    if [ -n "$n" ]; then
        if [ "$n" -le 10 ]; then printf 'ok'; else printf 'out-of-window'; fi
        return
    fi
    if grep -qE '^#[[:space:]]*[Ss]erial' "$f" 2>/dev/null; then printf 'malformed'
    else printf 'no-header'; fi
}

# plan_lane_of <plan-stdout> <basename> — the lane --print-plan assigned.
plan_lane_of() {
    local v
    v="$(printf '%s\n' "$1" | awk -F'\t' -v b="$2" \
        '$1 == "plan" { n = split($4, a, /[\/\\]/); if (a[n] == b) print $3 }' | head -1)"
    [ -z "$v" ] && v="(no-plan-row)"
    printf '%s' "$v"
}

PEERS_SEEN=""
RUNTIME_LANE=""
# runtime_lane_of <root> — lane the runner ACTUALLY used, from the subject's own
# peer count. Writes to globals RUNTIME_LANE/PEERS_SEEN (not stdout) since a
# command substitution would run this in a subshell and discard them.
runtime_lane_of() {
    local root="$1" peers
    rm -f "$root/obs"
    run_pinned 45 "TESTS_DIR=$root/tests" "RUN_ALL_JOBS=4" \
        -- bash "$root/bin/run-all.sh" --all >/dev/null 2>&1
    if [ ! -f "$root/obs" ]; then
        PEERS_SEEN="(none)"; RUNTIME_LANE="(subject-never-ran)"; return
    fi
    peers="$(tr -d '[:space:]' < "$root/obs")"
    PEERS_SEEN="$peers"
    case "$peers" in
        ""|*[!0-9]*) RUNTIME_LANE="(unreadable-peer-count)" ;;
        0) RUNTIME_LANE="serial" ;;
        *) RUNTIME_LANE="parallel" ;;
    esac
}

# ===========================================================================
# The boundary table: header position x expected lane x expected writer verdict
# ===========================================================================

# {WS} expands to two trailing spaces; {NONE} means the file carries no header.
CONTROL_PEERS="(row-never-ran)"
case_boundary_table() {
    local name pos hdr lane writer root plan_out i=0
    while IFS='|' read -r name pos hdr lane writer; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="${name//[[:space:]]/}"
        pos="${pos//[[:space:]]/}"
        lane="${lane//[[:space:]]/}"
        writer="${writer//[[:space:]]/}"
        hdr="$(printf '%s' "$hdr" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        hdr="${hdr//\{WS\}/  }"
        [ "$hdr" = "{NONE}" ] && hdr=""

        i=$((i + 1))
        root="$TMPD/row$i"
        mk_row_root "$root" "$pos" "$hdr"

        assert_eq "h2/writer/$name" "$writer" "$(writer_verdict "$root/tests/z-subject.sh")"

        plan_out="$(run_pinned 45 "TESTS_DIR=$root/tests" "RUN_ALL_JOBS=4" \
            -- bash "$root/bin/run-all.sh" --print-plan --all 2>/dev/null)"
        assert_eq "h2/plan-lane/$name" "$lane" "$(plan_lane_of "$plan_out" z-subject.sh)"

        runtime_lane_of "$root"
        assert_eq "h2/runtime-lane/$name" "$lane" "$RUNTIME_LANE"
        [ "$name" = "absent-control" ] && CONTROL_PEERS="$PEERS_SEEN"
    done <<'TABLE'
first-line          | 1  | # Serial: boundary row at the very first line | serial   | ok
writer-window-inner | 9  | # Serial: comfortably inside both windows     | serial   | ok
writer-window-last  | 10 | # Serial: last line the writer rule accepts   | serial   | ok
reader-only-first   | 11 | # Serial: first line only the reader accepts  | serial   | out-of-window
reader-window-last  | 20 | # Serial: last line the reader rule accepts   | serial   | out-of-window
past-both-windows   | 21 | # Serial: one line past the reader window     | parallel | out-of-window
absent-control      | 0  | {NONE}                                       | parallel | no-header
mal-no-colon        | 5  | # Serial no colon at all                      | parallel | malformed
mal-empty-reason    | 5  | # Serial:                                     | parallel | malformed
mal-blank-reason    | 5  | # Serial:{WS}                                 | parallel | malformed
mal-no-space        | 5  | #Serial: no space after the hash              | parallel | malformed
mal-trailing-space  | 5  | # Serial: reason with trailing blanks{WS}     | serial   | ok
mal-wrong-case      | 5  | # serial: lowercase keyword                   | parallel | malformed
TABLE
}

# ===========================================================================
# The fence: without observed concurrency, every `serial` row above is vacuous
# ===========================================================================
case_control_fence() {
    case "$CONTROL_PEERS" in
        ""|*[!0-9]*)
            fail "h2/control/peer-detector-observed-concurrency" \
                "the header-less control row produced no readable peer count ($CONTROL_PEERS)" ;;
        0)
            fail "h2/control/peer-detector-observed-concurrency" \
                "a header-less test observed 0 in-flight peers — nothing ran concurrently, so every 'serial' verdict above is vacuous" ;;
        *) pass "h2/control/peer-detector-observed-concurrency" ;;
    esac
}

case_ambient_sanitized
case_boundary_table
case_control_fence

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
