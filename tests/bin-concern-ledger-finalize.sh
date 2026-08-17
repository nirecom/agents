#!/usr/bin/env bash
# tests/bin-concern-ledger-finalize.sh
# Tests: bin/concern-ledger, bin/lib/concern-ledger.sh, bin/lib/concern-ledger/finalize.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/render.sh, bin/run-codex-review-loop, skills/review-code-security/scripts/close-concern-round.sh
# Tags: concern-ledger, finalize, fail-closed, atomic-write, json-artifact, table-driven, scope:common, pwsh-not-required
# lang-check: ignore -- NASTY_TEXT below deliberately embeds a non-ASCII fixture value

# TL2 dispatcher for the non-convergence artifact and its fail-CLOSED
# termination path (#1992 / #1996). Drives the real bin/concern-ledger CLI over
# ledger fixtures written by hand, so the serialization and the atomic
# replacement are observed at the filesystem rather than inferred.
# Cases live in tests/bin-concern-ledger-finalize/ (rules/coding/file-split.md).

# TL3 gap (mitigation category: skill-orchestration)
#   Not covered here, and covered nowhere below TL3:
#     - The consuming skills actually obeying exit 7. Cases 8/9 grep SKILL.md
#       for the exit-7 row and for the check-finalized sentence; a skill whose
#       table lists exit 7 but whose prose still emits
#       WORKFLOW_MARK_STEP_review_security_complete on the failure branch still
#       passes here. Only a real /review-code-security or /make-detail-plan run
#       against an injected finalize failure catches that.

#     - A real out-of-space / killed-mid-write filesystem. The serialization
#       failure is injected by shadowing `awk`, and the unwritable destination
#       is injected by placing a directory at the artifact path (chmod 555 is a
#       no-op on Windows, so it cannot be used as the injection — CPR-UNV).
#     - Real concurrency between a finalize and a competing writer on the same
#       destination path.

#   Mitigation: the day-to-day runner for the skill wiring is a manual
#   /review-code-security run; the exit-7 propagation itself is exercised at
#   TL2 by case 6(e) through the real bin/run-codex-review-loop.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$AGENTS_ROOT/bin/concern-ledger"
LIB="$AGENTS_ROOT/bin/lib/concern-ledger.sh"
LOOP_BIN="$AGENTS_ROOT/bin/run-codex-review-loop"
LEDGER_BIN="$AGENTS_ROOT/bin/review-code-ledger"

PASS=0
FAIL=0

# Known-gap assertions (case 9c). Sourced after FAIL exists, which the helpers
# increment on an XPASS. See tests/lib/xfail.sh for the contract.
# shellcheck source=./lib/xfail.sh
. "$AGENTS_ROOT/tests/lib/xfail.sh"

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

# assert_eq with a guard: an expectation that could not be computed (empty) is
# itself a failure, so '' == '' can never pass while the implementation is absent.
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
        echo "FAIL: $name — output does not contain $(printf '%q' "$needle")"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local name="$1" needle="$2" hay="$3"
    if printf '%s' "$hay" | grep -Fq -- "$needle"; then
        echo "FAIL: $name — output unexpectedly contains $(printf '%q' "$needle")"
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
# Fixture isolation (rules/test/fixture-isolation.md).
# ---------------------------------------------------------------------------
TMPDIR_BASE=$(mktemp -d)
trap 'cd / 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
export AGENTS_CONFIG_DIR="$AGENTS_ROOT"
cd "$TMPDIR_BASE" || exit 1

# The recovery copy of a failed finalize is written under $TMPDIR — pin it into
# the fixture so case 6(c) can look for it without touching the real temp dir.
RECOVERY_DIR="$TMPDIR_BASE/recovery"
mkdir -p "$RECOVERY_DIR"
export TMPDIR="$RECOVERY_DIR"

# --- environment per case ---------------------------------------------------
ENV_SEQ=0
PLANS=""
SID=""
new_env() {
    ENV_SEQ=$((ENV_SEQ + 1))
    SID="clfin$ENV_SEQ"
    PLANS="$TMPDIR_BASE/plans-$ENV_SEQ"
    mkdir -p "$PLANS"
}

# --- artifact paths ---------------------------------------------------------
# All take <plans> <sid> <format>.
ledger_file()   { printf '%s/%s-%s-concern-ledger.txt' "$1" "$2" "$3"; }
snapshot_file() { printf '%s/%s-%s-concern-ledger-cap-snapshot.txt' "$1" "$2" "$3"; }
json_file()     { printf '%s/%s-%s-unresolved-concerns.json' "$1" "$2" "$3"; }
diag_file()     { printf '%s/%s-%s-finalize-diagnostic.txt' "$1" "$2" "$3"; }
round_file()    { printf '%s/%s-%s-round-number.txt' "$1" "$2" "$3"; }
cycle_file()    { printf '%s/%s-%s-concern-ledger-cycle%s.txt' "$1" "$2" "$3" "$4"; }
delta_file()    { printf '%s/%s-%s-round-%s-delta-%s.txt' "$1" "$2" "$3" "$4" "$5"; }

# --- ledger fixtures --------------------------------------------------------
# row <id> <sev> <state> <first> <last> <slot> <discrim> <origin> <producers> <flags> <text>
row() {
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}"
}

# mk_ledger <file> <format> <sid> <cycle> [raw-line]...
mk_ledger() {
    local f="$1" fmt="$2" sid="$3" cyc="$4" l
    shift 4
    {
        printf '#concern-ledger-v2|%s|%s|cycle=%s\n' "$fmt" "$sid" "$cyc"
        for l in "$@"; do printf '%s\n' "$l"; done
    } > "$f"
}

# mk_staging <file> <producer> <completeness> <exec> <parse> <round> [body-line]...
mk_staging() {
    local f="$1" l
    {
        printf '#producer|%s|%s|%s|%s|%s\n' "$2" "$3" "$4" "$5" "$6"
        shift 6
        for l in "$@"; do printf '%s\n' "$l"; done
    } > "$f"
}

# --- runners ----------------------------------------------------------------
LAST_OUT=""; LAST_ERR_FILE=""; LAST_RC=0
RUN_SEQ=0

# run_cli <args...> — bin/concern-ledger. Sets LAST_OUT / LAST_RC / LAST_ERR_FILE.
run_cli() {
    RUN_SEQ=$((RUN_SEQ + 1))
    LAST_ERR_FILE="$TMPDIR_BASE/cli-err-$RUN_SEQ.txt"
    : > "$LAST_ERR_FILE"
    LAST_RC=0
    LAST_OUT="$(bash "$CLI" "$@" 2>"$LAST_ERR_FILE")" || LAST_RC=$?
}

# run_cli_path <PATH> <args...> — same, with PATH replaced (injection cases).
run_cli_path() {
    local p="$1"
    shift
    RUN_SEQ=$((RUN_SEQ + 1))
    LAST_ERR_FILE="$TMPDIR_BASE/cli-err-$RUN_SEQ.txt"
    : > "$LAST_ERR_FILE"
    LAST_RC=0
    LAST_OUT="$(PATH="$p" bash "$CLI" "$@" 2>"$LAST_ERR_FILE")" || LAST_RC=$?
}

last_err() { cat "$LAST_ERR_FILE" 2>/dev/null || true; }

# rc_of <args...> — exit code only (table rows that assert nothing else).
rc_of() {
    bash "$CLI" "$@" >/dev/null 2>&1
    printf '%s' "$?"
}

# cl <fn> <args...> — direct library probe in an isolated subshell.
cl() { ( set +u; source "$LIB" >/dev/null 2>&1 || exit 127; "$@" ); }

# --- observation helpers ----------------------------------------------------
# file_state <path> → present | empty | missing | not-a-file
file_state() {
    if [ -d "$1" ]; then printf 'not-a-file'
    elif [ ! -e "$1" ]; then printf 'missing'
    elif [ ! -s "$1" ]; then printf 'empty'
    else printf 'present'; fi
}

# fingerprint <path> → cksum of the contents, or 'missing'. Used to prove a
# destination file was left byte-for-byte alone by a failed finalize.
fingerprint() {
    [ -f "$1" ] || { printf 'missing'; return; }
    cksum < "$1" 2>/dev/null | tr -s ' ' ' '
}

# intact_state <path> <expected-fingerprint>
#   → present-and-unchanged | present-but-changed | empty | missing | not-a-file
# One value for "the file is still there AND still says what it said", so a run
# that never produced the file cannot pass as "the file was left alone".
intact_state() {
    local st
    st="$(file_state "$1")"
    [ "$st" = "present" ] || { printf '%s' "$st"; return; }
    if [ "$(fingerprint "$1")" = "$2" ]; then
        printf 'present-and-unchanged'
    else
        printf 'present-but-changed'
    fi
}

# tmp_residue <dir> → the number of '.tmp.' leftovers in <dir>.
tmp_residue() {
    ls -a "$1" 2>/dev/null | grep -c '\.tmp\.' || true
}

# tail2 <path> → the last two lines joined with '/', or 'missing'.
tail2() {
    [ -f "$1" ] || { printf 'missing'; return; }
    tail -n 2 "$1" | tr '\n' '/'
}

# json_of <path> → the whole artifact, or the empty string when absent.
json_of() { cat "$1" 2>/dev/null || true; }

# has_jq → yes | no
has_jq() { if command -v jq >/dev/null 2>&1; then printf 'yes'; else printf 'no'; fi; }

# path_without <name> — PATH with every directory holding <name> removed.
# chmod-based denial is a no-op on Windows, so removal from PATH is the portable
# way to make a tool genuinely absent (CPR-UNV: no environment assumption).
path_without() {
    local want="$1" out="" d
    local OLDIFS="$IFS"
    IFS=':'
    for d in $PATH; do
        [ -n "$d" ] || continue
        if [ -x "$d/$want" ] || [ -x "$d/$want.exe" ] || [ -x "$d/$want.cmd" ]; then
            continue
        fi
        out="${out:+$out:}$d"
    done
    IFS="$OLDIFS"
    printf '%s' "$out"
}

# shadow_dir <name> <script-body> → a directory to prepend to PATH that shadows
# <name> with the given body. Used to inject a serialization failure.
SHADOW_SEQ=0
shadow_dir() {
    SHADOW_SEQ=$((SHADOW_SEQ + 1))
    local d="$TMPDIR_BASE/shadow-$SHADOW_SEQ"
    mkdir -p "$d"
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$d/$1"
    chmod +x "$d/$1"
    printf '%s' "$d"
}

# --- shared concern texts ---------------------------------------------------
OPEN_TEXT="the finalize artifact must list this unresolved concern"
DONE_TEXT="this one was resolved and must not reach the artifact"
NASTY_TEXT=$'a "quoted" \\backslash\ttab \001ctl 日本語 and a | pipe'

# ---------------------------------------------------------------------------
# Implementation presence. Reported as a FAILURE (never PASS, never a silent
# skip) so the suite exits non-zero until /write-code lands the CLI.
# ---------------------------------------------------------------------------
for _f in "$CLI" "$LIB" "$LEDGER_BIN"; do
    if [ ! -f "$_f" ]; then
        echo "SKIP-BLOCKED: ${_f#"$AGENTS_ROOT/"} not implemented yet"
        fail "implementation missing: ${_f#"$AGENTS_ROOT/"} (every case below fails for this reason)"
    fi
done

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------
SUITE_DIR="$AGENTS_ROOT/tests/bin-concern-ledger-finalize"

# shellcheck source=./bin-concern-ledger-finalize/modes-schema.sh
. "$SUITE_DIR/modes-schema.sh"
# shellcheck source=./bin-concern-ledger-finalize/atomic-failclosed.sh
. "$SUITE_DIR/atomic-failclosed.sh"
# shellcheck source=./bin-concern-ledger-finalize/static-contracts.sh
. "$SUITE_DIR/static-contracts.sh"
# shellcheck source=./bin-concern-ledger-finalize/loop-integration.sh
. "$SUITE_DIR/loop-integration.sh"
# shellcheck source=./bin-concern-ledger-finalize/cap-outline-detail.sh
. "$SUITE_DIR/cap-outline-detail.sh"
# shellcheck source=./bin-concern-ledger-finalize/convergence-after-nonconverged.sh
. "$SUITE_DIR/convergence-after-nonconverged.sh"
# shellcheck source=./bin-concern-ledger-finalize/corrupted-json.sh
. "$SUITE_DIR/corrupted-json.sh"

xfail_summary
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
exit 1
