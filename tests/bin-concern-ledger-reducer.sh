#!/usr/bin/env bash
# tests/bin-concern-ledger-reducer.sh
# Tests: bin/lib/concern-ledger.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/parse.sh, bin/concern-ledger
# Tags: concern-ledger, reducer, bind, merge, completeness, table-driven, scope:common, pwsh-not-required
#
# TL1 dispatcher for the shared concern-ledger reducer (#1992 / #1996).
# Cases are split into tests/bin-concern-ledger-reducer/ per rules/coding/file-split.md.
# Expectations are taken from the detail plan's "ledger schema v2" / "cl_reduce state
# transition table" / "Test plan" sections. The reducer does not exist yet: until
# /write-code lands it every case below FAILS, and the SKIP-BLOCKED notice states why.
set -uo pipefail

# TL3 gap (mitigation category: filesystem-semantics)
#   - The library is sourced, so the real `bin/concern-ledger` CLI's own
#     argument handling and its `set -uo pipefail` are not what runs here.
#   - Host paths: a real plans dir is `C:\Users\...`, and NTFS case-insensitive
#     names and 8.3 aliases can make two spellings name one file.
#   Mitigation, closest to the action: tests/bin-concern-ledger-cli-contract.sh
#   drives the real CLI, and pattern-discovery.sh builds a genuine
#   backslash-bearing directory via `cygpath -w` where one exists.

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$AGENTS_ROOT/bin/lib/concern-ledger.sh"
CLI="$AGENTS_ROOT/bin/concern-ledger"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$name"
    else
        echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
        FAIL=$((FAIL + 1))
    fi
}

# Like assert_eq, but an expectation that could not be computed (empty) is itself
# a failure — otherwise '' == '' would pass while the implementation is missing.
assert_eq_nz() {
    local name="$1" want="$2" got="$3"
    if [ -z "$want" ]; then
        echo "FAIL: $name — the expected value could not be computed (empty)"
        FAIL=$((FAIL + 1))
        return
    fi
    assert_eq "$name" "$want" "$got"
}

assert_match() {
    local name="$1" re="$2" got="$3"
    if printf '%s' "$got" | grep -Eq -- "$re"; then
        pass "$name"
    else
        echo "FAIL: $name — value=$(printf '%q' "$got") does not match /$re/"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local name="$1" needle="$2" hay="$3"
    if printf '%s' "$hay" | grep -Fq -- "$needle"; then
        pass "$name"
    else
        echo "FAIL: $name — output does not contain $(printf '%q' "$needle"). Got: $hay"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local name="$1" needle="$2" hay="$3"
    if printf '%s' "$hay" | grep -Fq -- "$needle"; then
        echo "FAIL: $name — output unexpectedly contains $(printf '%q' "$needle"). Got: $hay"
        FAIL=$((FAIL + 1))
    else
        pass "$name"
    fi
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Fixture isolation (rules/test/fixture-isolation.md): dual-pinned plans dir,
# no inherited session id, neutral CWD.
# ---------------------------------------------------------------------------
TMPDIR_BASE=$(mktemp -d)
trap 'cd / 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT
export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
export AGENTS_CONFIG_DIR="$AGENTS_ROOT"

WORK="$TMPDIR_BASE/work"
mkdir -p "$WORK"
cd "$TMPDIR_BASE" || exit 1

# ---------------------------------------------------------------------------
# Library / CLI drivers. Every library call runs in its own subshell so a
# sourced implementation can never clobber the harness (pass/fail/counters).
# ---------------------------------------------------------------------------
cl() {
    ( set +u; source "$LIB" >/dev/null 2>&1 || exit 127; "$@" )
}

run_cli() { bash "$CLI" "$@"; }

# ---------------------------------------------------------------------------
# Ledger-v2 fixture builders (schema: 11 fields, TEXT last — detail plan
# "ledger schema v2"). SLOT and DISCRIM are always computed with the real
# helpers so fixtures never hardcode a digest.
# ---------------------------------------------------------------------------
mk_ledger() { # mk_ledger <file> <format> <session-id> <cycle>
    printf '#concern-ledger-v2|%s|%s|cycle=%s\n' "$2" "$3" "$4" > "$1"
}

# add_entry <file> <id> <sev> <state> <first> <last> <slot> <discrim> <origin> <producers> <flags> <text>
add_entry() {
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}" >> "$1"
}

# anchored <sev> <ref> <path> <anchor> <category> <text>  → one reviewer delta line
anchored() { printf '[%s] %s | %s#%s | %s | %s\n' "$1" "$2" "$3" "$4" "$5" "$6"; }

# mk_delta_report <file> <delta-line>...  → reviewer report carrying a Concern Delta section
mk_delta_report() {
    local f="$1" l
    shift
    {
        printf '## Codex Review: PERFORMED\n\n'
        printf '## Concern Delta\n'
        for l in "$@"; do printf '%s\n' "$l"; done
        printf '\n'
    } > "$f"
}

# A COMPLETE report with an explicit empty delta. Staged for the second producer
# whenever a case expects an absence-driven 'resolved' transition, so the
# completeness gate (detail plan decision c) sees every declared producer.
NONE_REPORT="$TMPDIR_BASE/none-delta.txt"
mk_delta_report "$NONE_REPORT" "(none)"

# Field indices of the v2 entry row (see mk_ledger/add_entry above).
F_SEV=2; F_STATE=3; F_FIRST=4; F_LAST=5; F_SLOT=6; F_DISCRIM=7
F_ORIGIN=8; F_PRODUCERS=9; F_FLAGS=10

entry_field() { grep -m1 -- "^$2|" "$1" 2>/dev/null | cut -d'|' -f"$3"; }
entry_text()  { grep -m1 -- "^$2|" "$1" 2>/dev/null | cut -d'|' -f11-; }
entry_count() { grep -cE '^C[0-9]+\|' "$1" 2>/dev/null || true; }
entry_ids()   { grep -oE '^C[0-9]+' "$1" 2>/dev/null | tr '\n' ',' ; }

# id_class <id> <forbidden-id>... → new | inherited | invalid
# 'invalid' covers the missing-implementation case, so "is not C1" can never pass
# just because no ID was produced at all.
id_class() {
    local id="$1" f
    shift
    [[ "$id" =~ ^C[0-9]+$ ]] || { printf 'invalid'; return; }
    for f in "$@"; do
        [[ "$id" == "$f" ]] && { printf 'inherited'; return; }
    done
    printf 'new'
}

# flag_state <ledger> <id> <flag> → has | absent | missing-entry
flag_state() {
    local row
    row="$(grep -m1 -- "^$2|" "$1" 2>/dev/null || true)"
    if [[ -z "$row" ]]; then printf 'missing-entry'; return; fi
    if printf '%s' "$row" | cut -d'|' -f10 | grep -Fq -- "$3"; then
        printf 'has'
    else
        printf 'absent'
    fi
}

# id_for_text <ledger> <text> → the ID whose TEXT is exactly <text>, or NONE.
id_for_text() {
    local f="$1" t="$2" line body
    [[ -f "$f" ]] || { printf 'NONE'; return; }
    while IFS= read -r line; do
        [[ "$line" =~ ^C[0-9]+\| ]] || continue
        body="$(printf '%s' "$line" | cut -d'|' -f11-)"
        [[ "$body" == "$t" ]] || continue
        printf '%s' "$(printf '%s' "$line" | cut -d'|' -f1)"
        return
    done < "$f"
    printf 'NONE'
}

# ---------------------------------------------------------------------------
# reduce_round <in-ledger> <out-ledger> <round> <format> <spec>...
#   spec = "<producer>@<exec-label>@<raw-delta-file>[@<adapter>]"
#   adapter = anchored (default) | cnref | numbered
# Uses '@' (never present in temp paths) as the field separator so Windows-style
# drive-letter paths cannot corrupt the split.
# Sets LAST_TALLY / LAST_REDUCE_RC / LAST_REDUCE_ERR / LAST_RUN_DIR.
# ---------------------------------------------------------------------------
reduce_round() {
    local inl="$1" outl="$2" round="$3" fmt="$4"
    shift 4
    local run spec prod exec raw adapter rest norm plabel
    run=$(mktemp -d "$TMPDIR_BASE/rr-XXXXXX")
    mkdir -p "$run/staging" "$run/norm"
    : > "$run/err.txt"
    for spec in "$@"; do
        prod="${spec%%@*}"; rest="${spec#*@}"
        exec="${rest%%@*}"; rest="${rest#*@}"
        raw="${rest%%@*}"
        if [[ "$rest" == *"@"* ]]; then adapter="${rest#*@}"; else adapter="anchored"; fi
        norm="$run/norm/$prod.txt"
        : > "$norm"
        if [[ "$adapter" == "cnref" ]]; then
            cl cl_parse_cnref "$raw" "$inl" "$norm" >/dev/null 2>>"$run/err.txt"
            plabel="COMPLETE"
        elif [[ "$adapter" == "numbered" ]]; then
            cl cl_parse_numbered "$raw" "$norm" >/dev/null 2>>"$run/err.txt"
            plabel="COMPLETE"
        else
            plabel=$(cl cl_parse_anchored "$raw" "$prod" "$norm" 2>>"$run/err.txt" | head -n1)
        fi
        plabel="$(trim "${plabel:-}")"
        [[ -n "$plabel" ]] || plabel="ABSENT"
        cl cl_stage "$run/staging" "$fmt" "$round" "$prod" "$exec" "$plabel" "$norm" \
            >/dev/null 2>>"$run/err.txt"
    done
    LAST_TALLY=$(cl cl_reduce "$inl" "$run/staging/*" "$round" "$fmt" "$outl" 2>>"$run/err.txt")
    LAST_REDUCE_RC=$?
    LAST_REDUCE_ERR="$run/err.txt"
    LAST_RUN_DIR="$run"
}
LAST_TALLY=""
LAST_REDUCE_RC=0
LAST_REDUCE_ERR=""
LAST_RUN_DIR=""

# ---------------------------------------------------------------------------
# Implementation presence. A missing implementation is reported as a FAILURE
# (never absorbed into PASS or SKIP) so the suite exits non-zero until
# /write-code lands the reducer.
# ---------------------------------------------------------------------------
for _f in "$LIB" "$CLI"; do
    if [[ ! -f "$_f" ]]; then
        echo "SKIP-BLOCKED: ${_f#"$AGENTS_ROOT/"} not implemented yet"
        fail "implementation missing: ${_f#"$AGENTS_ROOT/"} (every case below fails for this reason)"
    fi
done

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------
SUITE_DIR="$AGENTS_ROOT/tests/bin-concern-ledger-reducer"

# shellcheck source=./bin-concern-ledger-reducer/slot-discrim.sh
. "$SUITE_DIR/slot-discrim.sh"
# shellcheck source=./bin-concern-ledger-reducer/bind.sh
. "$SUITE_DIR/bind.sh"
# shellcheck source=./bin-concern-ledger-reducer/merge.sh
. "$SUITE_DIR/merge.sh"
# shellcheck source=./bin-concern-ledger-reducer/transitions.sh
. "$SUITE_DIR/transitions.sh"
# shellcheck source=./bin-concern-ledger-reducer/completeness.sh
. "$SUITE_DIR/completeness.sh"
# shellcheck source=./bin-concern-ledger-reducer/cycle-migration-static.sh
. "$SUITE_DIR/cycle-migration-static.sh"
# shellcheck source=./bin-concern-ledger-reducer/pattern-discovery.sh
. "$SUITE_DIR/pattern-discovery.sh"
# shellcheck source=./bin-concern-ledger-reducer/path-shapes-and-framing.sh
. "$SUITE_DIR/path-shapes-and-framing.sh"
# shellcheck source=./bin-concern-ledger-reducer/backslash-reduce.sh
. "$SUITE_DIR/backslash-reduce.sh"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -eq 0 ]]; then
    echo "All tests passed."
    exit 0
fi
exit 1
