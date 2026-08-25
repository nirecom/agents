#!/usr/bin/env bash
# tests/fix-2025-recovery-artifact-mode.sh
# Tests: bin/lib/concern-ledger/finalize.sh, bin/lib/safe-plans-path.sh, bin/concern-ledger
# Tags: concern-ledger, finalize, recovery, file-mode, publish-failure, security, scope:issue-specific, pwsh-not-required
#
# When the artifact's publish fails, cl_write_json holds the only verified copy
# of a whole review cycle's findings and saves it to a recovery file under
# $TMPDIR rather than losing it — which makes a temp directory shared with every
# process on the host the store for an unpublished artifact, so the file is
# chmod'd 0600 before its bytes are written (#2025 C8). The failure is injected
# the way an attacker gets one: a directory pre-placed at the destination.
set -uo pipefail

# TL2. The real bin/concern-ledger finalizes a real ledger into a plans dir; no
# library function is stubbed, so the recovery path is the one the shipped code
# takes rather than one the test arranged.

# TL3 gap (mitigation category: environment-specific)
#   Not covered on every host: the mode itself. Git Bash on Windows reports 644
#   whatever chmod is given, so the 0600 assertion can only run where modes are
#   real — probed for, and skipped by name rather than silently.
#   Mitigation: the chmod, and its ordering before the copy, are pinned
#   structurally so a removal fails everywhere.

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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

# An expectation that could not be computed is itself a failure.
assert_eq_nz() {
    local name="$1" want="$2" got="$3"
    if [ -z "$want" ]; then
        echo "FAIL: $name — the expected value could not be computed (empty)"
        FAIL=$((FAIL + 1))
        return
    fi
    assert_eq "$name" "$want" "$got"
}

# --- fixture isolation (rules/test/fixture-isolation.md) --------------------
TMPDIR_BASE="$(mktemp -d)"
trap 'cd / 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans-root"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
cd "$TMPDIR_BASE" || exit 1

# The recovery store is $TMPDIR, so it is pinned inside the sandbox: a case that
# leaked one of these files into the developer's real temp directory would be
# leaking exactly the content this file is about.
export TMPDIR="$TMPDIR_BASE/tmp"
mkdir -p "$TMPDIR"

[ -f "$CLI" ] || fail "implementation missing: bin/concern-ledger"

SID="sess-c8"
FMT="review-security-shared"
FINDING="the finding that must survive a failed publish"

file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

# Modes are only assertable where the filesystem keeps them.
MODES_OK=no
: > "$TMPDIR_BASE/.mode-probe"
chmod 600 "$TMPDIR_BASE/.mode-probe" 2>/dev/null || true
[ "$(file_mode "$TMPDIR_BASE/.mode-probe")" = "600" ] && MODES_OK=yes

# mk_plans <name> [block] — a plans dir holding one open concern. With 'block',
# a directory is pre-placed at the artifact's destination: rename(2) cannot
# replace a directory, so the publish fails while the verified bytes still exist.
mk_plans() {
    local p="$TMPDIR_BASE/$1"
    mkdir -p "$p"
    {
        printf '#concern-ledger-v2|%s|%s|cycle=1\n' "$FMT" "$SID"
        printf 'C1|HIGH|open|1|1|bin/x#fn:security|dc801|review-code-codex|review-code-codex|-|%s\n' "$FINDING"
    } > "$p/$SID-$FMT-concern-ledger.txt"
    [ "${2:-}" = "block" ] && mkdir -p "$p/$SID-$FMT-unresolved-concerns.json"
    printf '%s' "$p"
}

# finalize <plans> — the real CLI. Echoes "rc=<n>" then its combined output.
finalize() {
    local rc=0 out
    out="$(bash "$CLI" finalize --plans-dir "$1" --session-id "$SID" \
        --format "$FMT" --round 2 --cap 2 --mode terminal \
        --reason 'publish blocked' 2>&1)" || rc=$?
    printf 'rc=%s\n%s' "$rc" "$out"
}

recovered() { find "$TMPDIR" -maxdepth 1 -name '*.recovered.*' -type f 2>/dev/null; }
count_recovered() { recovered | wc -l | tr -d ' '; }

echo "--- recovery 1: the control, where the publish succeeds ---"

# 1. No recovery file may exist after a normal finalize. Without this, "exactly
#    one appeared" in case 2 would also pass against a build that wrote one on
#    every run — which would be the leak, not the fix.
{
    P1="$(mk_plans ok)"
    OUT1="$(finalize "$P1")"
    assert_eq "1: a finalize that can publish succeeds" \
        "rc=0" "$(printf '%s' "$OUT1" | head -n 1)"
    assert_eq_nz "1: the artifact is at its destination, holding the round's finding" \
        "1" "$(grep -c -F "$FINDING" "$P1/$SID-$FMT-unresolved-concerns.json" 2>/dev/null | tr -d ' ')"
    assert_eq "1: and nothing was left in the recovery store" \
        "0" "$(count_recovered)"
}

echo ""
echo "--- recovery 2: the publish blocked, with the bytes already verified ---"

# 2. The failure this file is about. The round's findings are not lost, they do
#    not stay in the plans dir under a predictable name, and nothing is parked
#    inside the directory the attacker pre-placed.
{
    P2="$(mk_plans blocked block)"
    OUT2="$(finalize "$P2")"
    REC2="$(recovered)"

    assert_eq "2: finalize reports the artifact failure rather than a path" \
        "rc=5" "$(printf '%s' "$OUT2" | head -n 1)"
    assert_eq "2: naming the failure the loop already knows how to read" \
        "yes" "$(printf '%s' "$OUT2" | grep -q -F 'FINALIZE-FAILED' && printf yes || printf no)"
    assert_eq "2: exactly one recovery file was written" \
        "1" "$(count_recovered)"
    assert_eq_nz "2: and its path is the one the operator is told to look at" \
        "$([ -n "$REC2" ] && printf yes)" \
        "$(printf '%s' "$OUT2" | grep -q -F "$REC2" && printf yes || printf no)"
    assert_eq_nz "2: the recovered bytes are a complete artifact, not a truncated one" \
        "1" "$(grep -c -F 'unresolved-concerns/v1-end' "$REC2" 2>/dev/null | tr -d ' ')"
    assert_eq_nz "2: carrying the round's finding" \
        "1" "$(grep -c -F "$FINDING" "$REC2" 2>/dev/null | tr -d ' ')"

    # Where it is NOT is half the property: the plans dir keeps no readable
    # leftover, and the pre-placed directory receives nothing.
    assert_eq "2: no temporary artifact was left behind in the plans dir" \
        "0" "$(find "$P2" \( -name '*.tmp.*' -o -name '*XXXXXX*' \) 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "2: and nothing was parked inside the directory pre-placed at the destination" \
        "0" "$(find "$P2/$SID-$FMT-unresolved-concerns.json" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"

    # The diagnostic is the operator's other way in, so it must agree.
    DIAG2="$P2/$SID-$FMT-finalize-diagnostic.txt"
    assert_eq_nz "2: the diagnostic beside the plans dir names the same recovery path" \
        "1" "$(grep -c -F "$REC2" "$DIAG2" 2>/dev/null | tr -d ' ')"
}

echo ""
echo "--- recovery 3: the recovery file's shape and mode ---"

# 3. The store is shared with every other process on the host, so where the file
#    lands and who can read it are the security half of the same step.
{
    REC3="$REC2"
    RBASE3="${REC3##*/}"

    assert_eq "3: the recovery file lives under TMPDIR, not in the plans dir" \
        "in-tmpdir" \
        "$(case "$REC3" in "$TMPDIR"/*) printf in-tmpdir ;; *) printf 'elsewhere' ;; esac)"
    assert_eq "3: its name is a bare basename, so no part of the destination path leaks into it" \
        "bare" \
        "$(case "$RBASE3" in *[/\\]*) printf 'has-separator' ;; *) printf bare ;; esac)"
    assert_eq "3: and the name is unpredictable, not the destination's name reused verbatim" \
        "suffixed" \
        "$(case "$RBASE3" in *.recovered.??????) printf suffixed ;; *) printf 'predictable' ;; esac)"

    if [ "$MODES_OK" = "yes" ]; then
        # A default-umask file in the same directory is the comparison: without
        # it, "600" could be what this host gives everything.
        : > "$TMPDIR/umask-control.txt"
        assert_eq "3: the recovery file is readable only by its owner" \
            "600" "$(file_mode "$REC3")"
        assert_eq "3: which is narrower than what the umask would have given it" \
            "narrower" \
            "$([ "$(file_mode "$REC3")" != "$(file_mode "$TMPDIR/umask-control.txt")" ] \
                && printf narrower || printf same)"
    else
        echo "SKIP: 3: the recovery file is readable only by its owner (this filesystem does not keep modes)"
        echo "SKIP: 3: which is narrower than what the umask would have given it (this filesystem does not keep modes)"
    fi
}

echo ""
echo "--- recovery 4: the ordering the mode depends on ---"

# 4. chmod after the copy would leave the bytes world-readable for the length of
#    the copy, and a recovery that copied first would still pass every
#    behavioural row above. Pinned in the source, since the window is not
#    observable from outside — and because case 3's mode rows do not run on
#    every host (Skipped-Because: this filesystem does not keep modes).
{
    SRC4="$AGENTS_ROOT/bin/lib/concern-ledger/finalize.sh"
    src_lines() { grep -n -F "$1" "$SRC4" | cut -d: -f1 | tr '\n' ' '; }
    CHMOD4="$(src_lines 'chmod 600 "$rec"')"
    CP4="$(src_lines 'cp "$kept" "$rec"')"

    # Each step must appear exactly once, or "the one before the other" would be
    # comparing whichever occurrence happened to sort first.
    assert_eq "4: the chmod and the copy each appear once in the module" \
        "chmod=1 cp=1" \
        "chmod=$(printf '%s' "$CHMOD4" | wc -w | tr -d ' ') cp=$(printf '%s' "$CP4" | wc -w | tr -d ' ')"
    assert_eq_nz "4: the recovery file is chmod'd and then copied into, in that order" \
        "chmod-then-copy" \
        "$([ -n "${CHMOD4% }" ] && [ -n "${CP4% }" ] && [ "${CHMOD4% }" -lt "${CP4% }" ] \
            && printf chmod-then-copy || printf 'out-of-order:%s/%s' "$CHMOD4" "$CP4")"
    assert_eq_nz "4: and the whole recovery is abandoned if either step fails" \
        "1" "$(grep -c -F 'rm -f "$rec"' "$SRC4" | tr -d ' ')"
    assert_eq_nz "4: the template is a basename with no separator of its own" \
        "1" "$(grep -c -F 'rbase="concern-ledger-artifact"' "$SRC4" | tr -d ' ')"
}

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
exit 1
