#!/bin/bash
# tests/feature-990-scan-repo-range-filters.sh
# Tests: skills/scan-offensive/scripts/scan-repo.sh range filters / --apply preflight / stale check
# Tags: scan, offensive, skill, jsonl, manifest, range-filter, apply, scope:issue-specific
# RED for issue #990 — scan-repo.sh must accept --until/--from-issue/--to-issue/--manifest-out
# and require --manifest-path + --confirm-ids in --apply mode with stale-content check.
#
# L3 gap (what this test does NOT catch):
# - real `gh api` pagination + filtering against GitHub
# - real `gh issue edit` round-trip
# Closest-to-action mitigation: manual dry-run on a sample repo before --apply.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$AGENTS_DIR/skills/scan-offensive/scripts/scan-repo.sh"
SCANNER="$AGENTS_DIR/bin/scan-offensive"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

require_script() {
    if [ ! -f "$SCRIPT" ]; then
        skip "$1 (skills/scan-offensive/scripts/scan-repo.sh not implemented yet)"
        return 1
    fi
    return 0
}

require_scanner() {
    if [ ! -f "$SCANNER" ]; then
        skip "$1 (bin/scan-offensive not present)"
        return 1
    fi
    return 0
}

# Create a stub `gh` shim in a temp PATH directory. The shim emits canned JSON for
# `gh api ...` lookups based on its argument shape.
make_gh_stub() {
    local dir="$1"
    local fixture_body="${2:-some clean issue body}"
    mkdir -p "$dir"
    cat > "$dir/gh" <<EOF
#!/bin/bash
# Minimal gh stub for scan-repo range-filter tests.
case "\$1" in
  repo)
    # gh repo view --json owner,name --jq ...
    echo "owner/repo"
    exit 0
    ;;
  api)
    shift
    target="\$1"
    case "\$target" in
      repos/*/issues*)
        # Emit a small fixture array of issues (paginate is a no-op for stub).
        cat <<JSON
[
  {"number": 1, "body": "$fixture_body", "updated_at": "2024-01-15T10:00:00Z", "pull_request": null},
  {"number": 5, "body": "another clean body", "updated_at": "2025-06-15T10:00:00Z", "pull_request": null},
  {"number": 10, "body": "yet another clean body", "updated_at": "2026-02-15T10:00:00Z", "pull_request": null},
  {"number": 7, "body": "pr should be excluded", "updated_at": "2025-01-01T00:00:00Z", "pull_request": {"url":"x"}}
]
JSON
        exit 0
        ;;
      repos/*/issues/*/comments*)
        echo "[]"
        exit 0
        ;;
      repos/*)
        # gh api repos/OWNER/REPO --jq .private
        echo "false"
        exit 0
        ;;
    esac
    ;;
  issue)
    # gh issue edit — pretend success
    exit 0
    ;;
esac
exit 0
EOF
    chmod +x "$dir/gh"
}

run_r1() {
    require_script "R1: accepts --since/--until/--from-issue/--to-issue/--manifest-out without rc=3" || return
    require_scanner "R1: scanner missing" || return
    local stubdir manifest rc out
    stubdir=$(mktemp -d)
    manifest=$(mktemp)
    make_gh_stub "$stubdir"
    rc=0
    out=$(PATH="$stubdir:$PATH" run_with_timeout 60 bash "$SCRIPT" owner/repo \
        --since 2024-01-01 --until 2026-12-31 --from-issue 1 --to-issue 99 \
        --manifest-out "$manifest" 2>&1) || rc=$?
    rm -rf "$stubdir"; rm -f "$manifest"
    if [ "$rc" -eq 3 ]; then
        fail "R1: usage error rc=3 for valid range flags; out=$out"
        return
    fi
    pass "R1: accepts range flags without rc=3 (rc=$rc)"
}

run_r2() {
    require_script "R2: invalid --from-issue abc → rc=3 with descriptive stderr" || return
    local stubdir manifest rc out
    stubdir=$(mktemp -d)
    manifest=$(mktemp)
    make_gh_stub "$stubdir"
    rc=0
    out=$(PATH="$stubdir:$PATH" run_with_timeout 30 bash "$SCRIPT" owner/repo \
        --from-issue abc --manifest-out "$manifest" 2>&1) || rc=$?
    rm -rf "$stubdir"; rm -f "$manifest"
    if [ "$rc" -ne 3 ]; then
        fail "R2: expected rc=3 for --from-issue abc, got rc=$rc; out=$out"
        return
    fi
    if ! echo "$out" | grep -Eiq "from-issue|integer|numeric|invalid"; then
        fail "R2: stderr missing descriptive message; out=$out"
        return
    fi
    pass "R2: invalid --from-issue rejected with descriptive stderr"
}

run_r3() {
    require_script "R3: jq predicate filters by --from-issue/--to-issue/--until" || return
    require_scanner "R3: scanner missing" || return
    if ! command -v jq >/dev/null 2>&1; then
        skip "R3: jq missing"
        return
    fi
    local stubdir manifest rc nlines
    stubdir=$(mktemp -d)
    manifest=$(mktemp)
    make_gh_stub "$stubdir"
    rc=0
    PATH="$stubdir:$PATH" run_with_timeout 60 bash "$SCRIPT" owner/repo \
        --from-issue 4 --to-issue 8 --until 2025-12-31 \
        --manifest-out "$manifest" >/dev/null 2>&1 || rc=$?
    # Issues fixture: #1(2024-01) #5(2025-06) #10(2026-02). PR #7 always excluded.
    # Filter 4..8 + updated_at <= 2025-12-31 should select only #5.
    local item_count has_5 has_1 has_10
    item_count=$(grep -c '"type":"item"' "$manifest" 2>/dev/null); item_count=${item_count:-0}
    has_5=$(grep -c '"issue":5\|"issue": 5' "$manifest" 2>/dev/null); has_5=${has_5:-0}
    has_1=$(grep -c '"issue":1\|"issue": 1' "$manifest" 2>/dev/null); has_1=${has_1:-0}
    has_10=$(grep -c '"issue":10\|"issue": 10' "$manifest" 2>/dev/null); has_10=${has_10:-0}
    rm -rf "$stubdir"; rm -f "$manifest"
    if [ "$has_5" -ge 1 ] && [ "$has_1" -eq 0 ] && [ "$has_10" -eq 0 ]; then
        pass "R3: jq predicate filters correctly (only issue#5 selected)"
    else
        fail "R3: filter incorrect; has_1=$has_1 has_5=$has_5 has_10=$has_10 items=$item_count"
    fi
}

run_r4() {
    require_script "R4: --manifest-out writes JSONL to FILE; stdout has no JSONL" || return
    require_scanner "R4: scanner missing" || return
    local stubdir manifest rc stdout_capture stderr_capture
    stubdir=$(mktemp -d)
    manifest=$(mktemp)
    stdout_capture=$(mktemp)
    stderr_capture=$(mktemp)
    make_gh_stub "$stubdir"
    rc=0
    PATH="$stubdir:$PATH" run_with_timeout 60 bash "$SCRIPT" owner/repo \
        --manifest-out "$manifest" >"$stdout_capture" 2>"$stderr_capture" || rc=$?
    # Manifest file should have non-zero size and contain JSONL.
    local mfsz stdout_jsonl stderr_banner
    mfsz=$(wc -c < "$manifest" 2>/dev/null); mfsz=${mfsz:-0}
    stdout_jsonl=$(grep -c '^{' "$stdout_capture" 2>/dev/null); stdout_jsonl=${stdout_jsonl:-0}
    stderr_banner=$(grep -ci "scan\|repo\|manifest\|issues scanned\|done" "$stderr_capture" 2>/dev/null); stderr_banner=${stderr_banner:-0}
    rm -rf "$stubdir"; rm -f "$manifest" "$stdout_capture" "$stderr_capture"
    if [ "$mfsz" -eq 0 ]; then
        fail "R4: --manifest-out file empty"
        return
    fi
    if [ "$stdout_jsonl" -ne 0 ]; then
        fail "R4: stdout contains JSONL lines when --manifest-out set ($stdout_jsonl lines)"
        return
    fi
    if [ "$stderr_banner" -eq 0 ]; then
        fail "R4: stderr missing human-readable banner"
        return
    fi
    pass "R4: --manifest-out writes JSONL; stdout has none; stderr has banner"
}

run_r5() {
    require_script "R5: first line of --manifest-out is preamble matching --print-standing-instruction" || return
    require_scanner "R5: scanner missing" || return
    if ! command -v jq >/dev/null 2>&1; then
        skip "R5: jq missing"
        return
    fi
    local stubdir manifest rc
    stubdir=$(mktemp -d)
    manifest=$(mktemp)
    make_gh_stub "$stubdir"
    rc=0
    PATH="$stubdir:$PATH" run_with_timeout 60 bash "$SCRIPT" owner/repo \
        --manifest-out "$manifest" >/dev/null 2>&1 || rc=$?
    local first_line preamble_type preamble_schema instr_field expected_instr
    first_line=$(head -1 "$manifest" 2>/dev/null)
    preamble_type=$(printf '%s' "$first_line" | jq -r '.type' 2>/dev/null)
    preamble_schema=$(printf '%s' "$first_line" | jq -r '.schema' 2>/dev/null)
    instr_field=$(printf '%s' "$first_line" | jq -r '.instruction' 2>/dev/null)
    expected_instr=$(node "$SCANNER" --print-standing-instruction 2>/dev/null)
    # Strip trailing newline from --print-standing-instruction output
    expected_instr=$(printf '%s' "$expected_instr")
    rm -rf "$stubdir"; rm -f "$manifest"
    if [ "$preamble_type" != "preamble" ]; then
        fail "R5: first line type='$preamble_type' (expected 'preamble')"
        return
    fi
    if [ "$preamble_schema" != "scan-offensive/skill-manifest/v1" ]; then
        fail "R5: first line schema='$preamble_schema'"
        return
    fi
    if [ "$instr_field" != "$expected_instr" ]; then
        fail "R5: instruction field mismatch (len=${#instr_field} vs expected=${#expected_instr})"
        return
    fi
    pass "R5: preamble first line matches --print-standing-instruction byte-for-byte"
}

run_r6() {
    require_script "R6: --apply without --manifest-path → rc=3 mentioning --manifest-path" || return
    local rc out stubdir
    stubdir=$(mktemp -d)
    make_gh_stub "$stubdir"
    rc=0
    out=$(PATH="$stubdir:$PATH" run_with_timeout 30 bash "$SCRIPT" owner/repo --apply 2>&1) || rc=$?
    rm -rf "$stubdir"
    if [ "$rc" -ne 3 ]; then
        fail "R6: expected rc=3, got rc=$rc; out=$out"
        return
    fi
    if ! echo "$out" | grep -q -- "--manifest-path"; then
        fail "R6: stderr missing '--manifest-path'; out=$out"
        return
    fi
    pass "R6: --apply without --manifest-path rejected with descriptive error"
}

run_r7() {
    require_script "R7: --apply with unknown --confirm-ids → rc=3 mentioning 'unknown'" || return
    local stubdir manifest rc out
    stubdir=$(mktemp -d)
    manifest=$(mktemp)
    make_gh_stub "$stubdir"
    cat > "$manifest" <<'EOF'
{"type":"preamble","schema":"scan-offensive/skill-manifest/v1","instruction":"x","scan":{}}
{"type":"item","schema":"scan-offensive/skill-manifest/v1","id":"valid-id","source":{"kind":"issue-body","repo":"o/r","issue":1,"comment_id":null,"url":"x"},"keyword_verdict":"hard","keyword_hits":[{"lineno":1,"tier":"hard","match":"x"}],"content_length":3,"content_sha256":"deadbeef","envelope":"<item id=\"valid-id\" source=\"issue-body\" keyword-verdict=\"hard\" content-length=\"3\">\n<content>\nabc\n</content>\n</item>"}
EOF
    rc=0
    out=$(PATH="$stubdir:$PATH" run_with_timeout 30 bash "$SCRIPT" owner/repo \
        --apply --manifest-path "$manifest" --confirm-ids unknown-id 2>&1) || rc=$?
    rm -rf "$stubdir"; rm -f "$manifest"
    if [ "$rc" -ne 3 ]; then
        fail "R7: expected rc=3, got rc=$rc; out=$out"
        return
    fi
    if ! echo "$out" | grep -qi "unknown"; then
        fail "R7: stderr missing 'unknown'; out=$out"
        return
    fi
    pass "R7: --apply with unknown confirm-id rejected"
}

run_r8() {
    require_script "R8: --apply detects STALE content via sha256 mismatch → rc=5" || return
    local stubdir manifest rc out
    stubdir=$(mktemp -d)
    manifest=$(mktemp)
    # Stub returns "some clean issue body" for issue #1; sha256 of an unrelated string
    # placed in the manifest will not match → STALE.
    make_gh_stub "$stubdir" "some clean issue body"
    cat > "$manifest" <<'EOF'
{"type":"preamble","schema":"scan-offensive/skill-manifest/v1","instruction":"x","scan":{}}
{"type":"item","schema":"scan-offensive/skill-manifest/v1","id":"o-r-issue-1","source":{"kind":"issue-body","repo":"owner/repo","issue":1,"comment_id":null,"url":"https://github.com/owner/repo/issues/1"},"keyword_verdict":"hard","keyword_hits":[{"lineno":1,"tier":"hard","match":"x"}],"content_length":3,"content_sha256":"0000000000000000000000000000000000000000000000000000000000000000","envelope":"<item id=\"o-r-issue-1\" source=\"issue-body\" keyword-verdict=\"hard\" content-length=\"3\">\n<content>\nabc\n</content>\n</item>"}
EOF
    rc=0
    out=$(PATH="$stubdir:$PATH" run_with_timeout 30 bash "$SCRIPT" owner/repo \
        --apply --manifest-path "$manifest" --confirm-ids o-r-issue-1 2>&1) || rc=$?
    rm -rf "$stubdir"; rm -f "$manifest"
    if [ "$rc" -ne 5 ]; then
        fail "R8: expected rc=5 for STALE content, got rc=$rc; out=$out"
        return
    fi
    if ! echo "$out" | grep -q "STALE:"; then
        fail "R8: stderr missing 'STALE:' marker; out=$out"
        return
    fi
    pass "R8: --apply STALE detection → rc=5 with 'STALE:' marker"
}

run_r1
run_r2
run_r3
run_r4
run_r5
run_r6
run_r7
run_r8

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
