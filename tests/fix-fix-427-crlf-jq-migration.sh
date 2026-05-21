#!/bin/bash
# Tests for CRLF defense in migrate-repo's state/jq pipeline (Windows jq.exe).
# RED before jq_text() exists in state.sh — expected before write-code step.
#
# CRLF shim note: only injects \r when jq is invoked with -r/--raw-output.
# Real jq.exe on Windows emits CRLF for all output; the shim covers the
# subset relevant to this fix (scalar -r captures).
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_SCRIPT="$AGENTS_DIR/bin/github-issues/migration/state.sh"
BACKFILL_SCRIPT="$AGENTS_DIR/bin/github-issues/migration/backfill-content-date.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

missing=()
[ -f "$STATE_SCRIPT" ]    || missing+=("$STATE_SCRIPT")
[ -f "$BACKFILL_SCRIPT" ] || missing+=("$BACKFILL_SCRIPT")
if [ "${#missing[@]}" -gt 0 ]; then
    for f in "${missing[@]}"; do echo "FAIL: precondition missing — $f"; done
    echo "Results: 0 passed, ${#missing[@]} failed"
    exit 1
fi

# CRLF-injecting jq shim factory.
# Scans full argv for -r/--raw-output in any position.
make_crlf_shim() {
    local shim_dir="$1"
    local real_jq; real_jq="$(command -v jq)"
    mkdir -p "$shim_dir"
    cat > "$shim_dir/jq" <<EOF
#!/bin/bash
raw=0
for a in "\$@"; do
    case "\$a" in
        -r|--raw-output) raw=1 ;;
    esac
done
if [ "\$raw" -eq 1 ]; then
    "$real_jq" "\$@" | sed 's/$/\r/'
else
    "$real_jq" "\$@"
fi
EOF
    chmod +x "$shim_dir/jq"

    # gh shim: gh.exe is a Go binary (LF-only stdout); outputs LF-only to match.
    cat > "$shim_dir/gh" <<'GHEOF'
#!/bin/bash
set -u
cmd="${1:-}"; shift || true
case "$cmd" in
  repo)
    sub="${1:-}"; shift || true
    jq_expr=""
    prev=""
    for a in "$@"; do [ "$prev" = "--jq" ] && jq_expr="$a"; prev="$a"; done
    case "$jq_expr" in
      *.owner.login|.owner.login) echo "mockowner" ;;
      *.name|.name) echo "mockrepo" ;;
      *) echo "mockvalue" ;;
    esac
    exit 0
    ;;
  *) exit 0 ;;
esac
GHEOF
    chmod +x "$shim_dir/gh"
}

# T1: state_load returns 0 when jq emits CRLF on schema_version
TMP1="$(mktemp -d)"
make_crlf_shim "$TMP1/shim"
(
    set +e
    export PATH="$TMP1/shim:$PATH"
    source "$STATE_SCRIPT"
    state_init "$TMP1" >/dev/null 2>&1
    state_load "$TMP1" >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 0 ] && echo "__T1_OK__" || echo "__T1_FAIL__ rc=$rc"
) > "$TMP1/out" 2>&1
if grep -q '__T1_OK__' "$TMP1/out"; then
    pass "T1: state_load returns 0 when jq emits CRLF on schema_version"
else
    fail "T1: state_load failed under CRLF jq shim"
    sed 's/^/    /' "$TMP1/out"
fi
rm -rf "$TMP1"

# T2: state_count_migrated returns purely numeric output under CRLF jq
TMP2="$(mktemp -d)"
make_crlf_shim "$TMP2/shim"
(
    set +e
    export PATH="$TMP2/shim:$PATH"
    source "$STATE_SCRIPT"
    state_init "$TMP2" >/dev/null 2>&1
    state_load "$TMP2" >/dev/null 2>&1
    state_record_migrated history E1 101 "t1" >/dev/null 2>&1
    state_record_migrated history E2 102 "t2" >/dev/null 2>&1
    n="$(state_count_migrated history)"
    if printf '%s' "$n" | LC_ALL=C grep -Eq '^[0-9]+$'; then
        echo "__T2_OK__ n=$n"
    else
        echo "__T2_FAIL__ raw=$(printf '%s' "$n" | od -c | head -1)"
    fi
) > "$TMP2/out" 2>&1
if grep -q '__T2_OK__' "$TMP2/out"; then
    pass "T2: state_count_migrated output is purely numeric under CRLF jq"
else
    fail "T2: state_count_migrated emitted non-numeric output under CRLF jq"
    sed 's/^/    /' "$TMP2/out"
fi
rm -rf "$TMP2"

# T3: backfill-content-date.sh exits 0 on empty-migrated path under CRLF jq+gh shim.
# - jq shim: appends \r to -r output (migrated_numbers="\r" if jq_text absent)
# - gh shim: handles gh repo view --jq at lines 27-28 (LF-only like gh.exe Go binary)
# Empty migrated list → early-exit at line 32. Without jq_text, "\r" bypasses -z guard.
TMP3="$(mktemp -d)"
make_crlf_shim "$TMP3/shim"
(
    set +e
    export PATH="$TMP3/shim:$PATH"
    source "$STATE_SCRIPT"
    state_init "$TMP3" >/dev/null 2>&1
    MIGRATE_PROJECT_ID=PVT_x \
    MIGRATE_FIELD_ID=PVTF_x \
    MIGRATE_PROJECT_NUM=1 \
        run_with_timeout 30 bash "$BACKFILL_SCRIPT" "$TMP3" > "$TMP3/bfout" 2>&1
    echo "__T3_RC__=$?" >> "$TMP3/bfout"
)
if grep -q '__T3_RC__=0' "$TMP3/bfout" && grep -iE 'nothing to backfill|no migrated' "$TMP3/bfout" >/dev/null 2>&1; then
    pass "T3: backfill-content-date.sh exits 0 on empty-migrated path under CRLF jq+gh shim"
else
    fail "T3: backfill-content-date.sh failed under CRLF jq+gh shim"
    sed 's/^/    /' "$TMP3/bfout"
fi
rm -rf "$TMP3"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
