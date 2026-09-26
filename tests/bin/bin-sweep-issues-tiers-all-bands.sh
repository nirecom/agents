#!/bin/bash
# tests/bin/bin-sweep-issues-tiers-all-bands.sh
# Tests: bin/sweep-issues.sh, bin/sweep-issues/list-band.sh, bin/sweep-issues/summary.sh
# Tags: sweep, issues, snapshot, scope:common, TL2, dup-group-keep:size-hard-limit
# Split from bin-sweep-issues-tiers.sh (500-line HARD limit): pins the all-bands
# snapshot sweep (default mode) — one issue-list fetch, per-band SI-2 scan, a single
# tier-1 pass, one aggregated tier-2 gate, band_index=all CI contract, --max-bands,
# on a mid-sweep band failure. Self-contained fixture (shadow AGENTS_CONFIG_DIR).
# TL3 gap: real gh API (rate limits, pagination) and SKILL.md AskUserQuestion gates
# are stubbed; residual gap checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ORCH="$AGENTS_DIR/bin/sweep-issues.sh"
REPO_SLUG="testowner/testrepo"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

TMPDIR_BASE="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMPDIR_BASE" 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Fixture builder — sets FAKE / REPO / RECORD / GHREC / GHDIR for tag $1.
# ─────────────────────────────────────────────────────────────────────────────

make_fixture() {
    local tag="$1"
    FAKE="$TMPDIR_BASE/$tag/agents"
    REPO="$TMPDIR_BASE/$tag/repo"
    RECORD="$TMPDIR_BASE/$tag/record.txt"
    GHREC="$TMPDIR_BASE/$tag/gh-calls.txt"
    GHDIR="$TMPDIR_BASE/$tag/ghbin"

    mkdir -p "$FAKE/bin/sweep-issues" "$FAKE/bin/github-issues" "$FAKE/bin/lib" \
             "$GHDIR" "$REPO/bin"
    : > "$RECORD"
    : > "$GHREC"

    cp "$AGENTS_DIR/bin/sweep-issues.sh"   "$FAKE/bin/"                 2>/dev/null
    cp "$AGENTS_DIR"/bin/sweep-issues/*    "$FAKE/bin/sweep-issues/"    2>/dev/null
    cp "$AGENTS_DIR"/bin/lib/*.sh          "$FAKE/bin/lib/"             2>/dev/null
    cp "$AGENTS_DIR/bin/run-with-timeout.sh" "$FAKE/bin/"               2>/dev/null
    [ -f "$AGENTS_DIR/bin/workflow-plans-dir" ] && \
        cp "$AGENTS_DIR/bin/workflow-plans-dir" "$FAKE/bin/" 2>/dev/null
    # gh-outbound-guard.sh (sourced by close-batch.sh) resolves scan-outbound.sh at
    # runtime and is fail-closed if it is missing — see assert_fixture_lib_deps_resolved.
    cp "$AGENTS_DIR/bin/scan-outbound.sh"  "$FAKE/bin/"                 2>/dev/null
    chmod -R u+rwx "$FAKE/bin" 2>/dev/null
    [ -f "$AGENTS_DIR/.private-info-allowlist" ] && \
        cp "$AGENTS_DIR/.private-info-allowlist" "$FAKE/" 2>/dev/null
    [ -f "$AGENTS_DIR/.private-info-blocklist" ] && \
        cp "$AGENTS_DIR/.private-info-blocklist" "$FAKE/" 2>/dev/null

    printf '#!/bin/bash\nexit 0\n' > "$FAKE/bin/is-github-dotcom-remote"
    chmod +x "$FAKE/bin/is-github-dotcom-remote"

    # Recording stubs for every close helper (SSOT of "what was actually called").
    local h
    for h in parent-body-update close-completed post-close-sentinels wip-state; do
        cat > "$FAKE/bin/github-issues/$h.sh" <<STUB
#!/bin/bash
printf '%s %s [GH_REPO=%s]\n' "$h" "\$*" "\${GH_REPO:-}" >> "$RECORD"
exit 0
STUB
        chmod +x "$FAKE/bin/github-issues/$h.sh"
    done

    # close-not-planned: fails for the issue named in CNP_FAIL_FOR (partial-mutation case).
    cat > "$FAKE/bin/github-issues/close-not-planned.sh" <<STUB
#!/bin/bash
printf '%s %s [GH_REPO=%s]\n' "close-not-planned" "\$*" "\${GH_REPO:-}" >> "$RECORD"
for a in "\$@"; do
    if [ -n "\${CNP_FAIL_FOR:-}" ] && [ "\$a" = "\$CNP_FAIL_FOR" ]; then exit 1; fi
done
exit 0
STUB
    chmod +x "$FAKE/bin/github-issues/close-not-planned.sh"

    # parent-all-closed-check.sh <owner/repo> <N>: 0=all closed, 1=has open, 2=no sub-issues.
    cat > "$FAKE/bin/github-issues/parent-all-closed-check.sh" <<STUB
#!/bin/bash
printf '%s %s\n' "parent-all-closed-check" "\$*" >> "$RECORD"
case "\$2" in
    900) exit 0 ;;
    901) exit 2 ;;
    *)   exit 1 ;;
esac
STUB
    chmod +x "$FAKE/bin/github-issues/parent-all-closed-check.sh"

    # gh stub: records every invocation, serves the band and the meta-parent list.
    cat > "$GHDIR/gh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$GHREC"
case "\$*" in
    *"--label meta"*)
        printf '%s\n' '[{"number":900,"title":"Group: alpha"},{"number":901,"title":"Group: beta"},{"number":902,"title":"Group: gamma"}]'
        exit 0 ;;
    *"issue list"*)
        printf '%s\n' '[{"number":101,"title":"a","body":"broken bin/gone-a.sh","labels":[],"createdAt":"2024-01-01T00:00:00Z"},{"number":102,"title":"b","body":"live bin/existing.sh","labels":[],"createdAt":"2024-01-02T00:00:00Z"},{"number":103,"title":"c","body":"broken bin/gone-c.sh","labels":[],"createdAt":"2024-01-03T00:00:00Z"},{"number":104,"title":"d","body":"broken bin/gone-d.sh","labels":[],"createdAt":"2024-01-04T00:00:00Z"}]'
        exit 0 ;;
    *"repo view"*)
        printf '%s\n' "$REPO_SLUG"; exit 0 ;;
    *)
        exit 0 ;;
esac
STUB
    chmod +x "$GHDIR/gh"

    # Working repo: bin/existing.sh exists so issue 102 classifies as live.
    git -c init.defaultBranch=main init -q "$REPO"
    git -C "$REPO" config core.hooksPath /dev/null 2>/dev/null || true
    git -C "$REPO" config user.email t@example.com
    git -C "$REPO" config user.name t
    printf '#!/bin/bash\n' > "$REPO/bin/existing.sh"
    git -C "$REPO" add -A 2>/dev/null
    git -C "$REPO" commit -q --no-verify -m init

    assert_fixture_lib_deps_resolved "$tag"
}

# Guard-completeness precondition (SI-6 class): a bin/lib/*.sh sourced by the
# copied entrypoints may resolve a sibling helper by basename at runtime; if it
# is absent from the fixture bin/, the security gate fails closed silently rather
# than exercising the real scan path. Discovered dynamically from the copied
# files (not a hardcoded name). Hard-aborts on an incomplete fixture: that is a
# setup defect, not a test-case outcome.
assert_fixture_lib_deps_resolved() {
    local tag="$1"
    local sourced_libs missing="" lib dep libpath

    sourced_libs="$(grep -hoE 'lib/[A-Za-z0-9_-]+\.sh' \
        "$FAKE/bin/sweep-issues.sh" "$FAKE/bin/sweep-issues/"*.sh 2>/dev/null | sort -u)"

    for lib in $sourced_libs; do
        libpath="$FAKE/bin/$lib"
        if [ ! -f "$libpath" ]; then
            missing="$missing $lib(not-copied-to-fixture)"
            continue
        fi
        while IFS= read -r dep; do
            [ -z "$dep" ] && continue
            [ "$dep" = "$(basename "$libpath")" ] && continue
            find "$FAKE/bin" -name "$dep" 2>/dev/null | grep -q . || \
                missing="$missing $dep(referenced-by:$lib)"
        done < <(grep -oE '[A-Za-z0-9_-]+\.sh\b' "$libpath" | sort -u)
    done

    if [ -n "$missing" ]; then
        fail "fixture[$tag]: shadow bin/ is missing helper(s) that a sourced library resolves at runtime:$missing"
        echo ""
        echo "Results: $PASS passed, $FAIL failed"
        exit 1
    fi
}

# Run the orchestrator from the fixture repo. Sets globals OUT and RC.
run_sweep() {
    OUT="$(cd "$REPO" && PATH="$GHDIR:$PATH" AGENTS_CONFIG_DIR="$FAKE" \
        CNP_FAIL_FOR="${CNP_FAIL_FOR:-}" \
        run_with_timeout bash "$FAKE/bin/sweep-issues.sh" --repo "$REPO_SLUG" "$@" 2>&1)"
    RC=$?
}
OUT=""
RC=0

# `--` is required: needles start with `--`, which grep would otherwise eat as flags.
record_has() { grep -qF -- "$1" "$RECORD" 2>/dev/null; }

# Band-fetch gh calls only: the meta-parent scan also runs `gh issue list --label
# meta`, so a bare "issue list" match would double-count. Band fetch = no --label.
gh_band_fetch_count() {
    grep -F 'issue list' "$GHREC" 2>/dev/null | grep -cvF -- '--label meta' || true
}

# How many times parent-all-closed-check ran for issue $1 (line: "... <repo> <N>").
parent_check_count() {
    grep -Ec "^parent-all-closed-check .* $1\$" "$RECORD" 2>/dev/null || true
}

# Overwrite list-band.sh so band index 1 fails; count/snapshot calls and band 0
# delegate to the real implementation. Robust to the exact snapshot protocol — it
# only special-cases the presence of `--band-index 1`.
stub_list_band_fail_band1() {
    cp "$FAKE/bin/sweep-issues/list-band.sh" "$FAKE/bin/sweep-issues/list-band.real.sh"
    cat > "$FAKE/bin/sweep-issues/list-band.sh" <<'STUB'
#!/bin/bash
prev=""
for a in "$@"; do
    if [ "$prev" = "--band-index" ] && [ "$a" = "1" ]; then
        printf 'ERROR: injected failure for band index 1\n' >&2
        exit 1
    fi
    prev="$a"
done
exec "$(dirname "$0")/list-band.real.sh" "$@"
STUB
    chmod +x "$FAKE/bin/sweep-issues/list-band.sh"
}

# Replace scan-stale-paths.js so it fails when band 1 data (issue 103) arrives.
stub_scan_fail_band1() {
    cp "$FAKE/bin/sweep-issues/scan-stale-paths.js" \
       "$FAKE/bin/sweep-issues/scan-stale-paths.real.js"
    cat > "$FAKE/bin/sweep-issues/scan-stale-paths.js" <<'STUB'
#!/usr/bin/env node
const chunks = [];
process.stdin.on('data', c => chunks.push(c));
process.stdin.on('end', () => {
    const data = Buffer.concat(chunks).toString();
    if (data.includes('"number":103') || data.includes('"number": 103')) {
        process.stderr.write('ERROR: injected scan failure for band 1\n');
        process.exit(1);
    }
    const cp = require('child_process');
    const path = require('path');
    const real = path.join(__dirname, 'scan-stale-paths.real.js');
    const child = cp.spawnSync(process.execPath, [real, ...process.argv.slice(2)], {
        input: data, stdio: ['pipe', 'inherit', 'inherit']
    });
    process.exit(child.status || 0);
});
STUB
}

if [ ! -f "$ORCH" ]; then
    fail "setup: orchestrator not found at $ORCH (bin/sweep-issues.sh is not implemented yet)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# ── C12 (B1): default (all-bands) sweeps every band in one run ───────────────
C12_all_bands_sweeps_all() {
    make_fixture c12
    local out; run_sweep --band-size 2; out="$OUT"
    [ "$RC" -eq 0 ] \
        && pass "C12: exit 0" \
        || fail "C12: exit=$RC (want 0)"
    echo "$out" | grep -q 'scanned=4' \
        && pass "C12: summary reports scanned=4 (all 4 issues)" \
        || fail "C12: scanned!=4, out=$out"
    # #101 is in band 0, #103 in band 1: both bands must have been scanned.
    echo "$out" | grep -q 'TIER2-CANDIDATE: issue=101' \
        && pass "C12: band 0 candidate #101 reported" \
        || fail "C12: no TIER2-CANDIDATE for #101 (band 0), out=$out"
    echo "$out" | grep -q 'TIER2-CANDIDATE: issue=103' \
        && pass "C12: band 1 candidate #103 reported" \
        || fail "C12: no TIER2-CANDIDATE for #103 (band 1), out=$out"
    echo "$out" | grep -qF 'TIER2-CANDIDATE: issue=102' \
        && fail "C12: #102 is live (existing.sh exists) — must NOT be a candidate" \
        || pass "C12: #102 correctly absent from candidates"
    echo "$out" | grep -qF 'TIER2-CANDIDATE: issue=104' \
        && pass "C12: #104 is stale (gone-d.sh missing) — correctly a candidate" \
        || fail "C12: #104 missing from candidates, out=$out"
}

# ── C13 (B2): snapshot — the issue list is fetched exactly once ──────────────
C13_all_bands_single_fetch() {
    make_fixture c13
    run_sweep --band-size 2
    local n; n="$(gh_band_fetch_count)"
    [ "${n:-0}" -eq 1 ] \
        && pass "C13: gh issue list (band fetch) called exactly once" \
        || fail "C13: band fetch ran ${n:-0} times (want 1); gh calls=$(tr '\n' '|' < "$GHREC")"
}

# ── C14 (B3): tier 1 evaluated once, not per band ────────────────────────────
C14_all_bands_tier1_once() {
    make_fixture c14
    run_sweep --band-size 2
    local n; n="$(parent_check_count 900)"
    [ "${n:-0}" -eq 1 ] \
        && pass "C14: parent-all-closed-check #900 ran exactly once" \
        || fail "C14: tier-1 check #900 ran ${n:-0} times (want 1); record=$(tr '\n' '|' < "$RECORD")"
    local c; c="$(grep -cE '^close-completed 900' "$RECORD" 2>/dev/null || true)"
    [ "${c:-0}" -eq 1 ] \
        && pass "C14: close-completed #900 executed exactly once" \
        || fail "C14: close-completed #900 ran ${c:-0} times (want 1); record=$(tr '\n' '|' < "$RECORD")"
}

# ── C15 (B4): --deep aggregates ONE tier-2 gate across all bands ─────────────
C15_all_bands_deep_single_gate() {
    make_fixture c15
    local out; run_sweep --deep --band-size 2; out="$OUT"
    [ "$RC" -eq 0 ] \
        && pass "C15 --deep: exit 0" \
        || fail "C15 --deep: exit=$RC (want 0)"
    local g; g="$(echo "$out" | grep -c '<<<TIER2-GATE-SI3' || true)"
    [ "${g:-0}" -eq 1 ] \
        && pass "C15 --deep: exactly one TIER2-GATE-SI3 block" \
        || fail "C15 --deep: found ${g:-0} gate blocks (want 1), out=$out"
    # Gate rows are '<number><TAB>...': #101 (band0) and #104 (band1) must appear.
    if echo "$out" | grep -q '^101' && echo "$out" | grep -q '^104'; then
        pass "C15 --deep: aggregated gate lists #101 (band0) and #104 (band1)"
    else
        fail "C15 --deep: gate missing cross-band candidates, out=$out"
    fi
}

# ── C16 (B5): CI summary carries band_index=all + bands_swept/total_bands ────
C16_all_bands_ci_contract() {
    make_fixture c16
    local out; run_sweep --band-size 2 --ci-mode; out="$OUT"
    echo "$out" | grep -q '"band_index":"all"' \
        && pass "C16 --ci-mode: band_index is the string all" \
        || fail "C16 --ci-mode: no band_index=all in JSON, out=$out"
    echo "$out" | grep -q '"bands_swept":2' \
        && pass "C16 --ci-mode: bands_swept=2" \
        || fail "C16 --ci-mode: bands_swept!=2, out=$out"
    echo "$out" | grep -q '"total_bands":2' \
        && pass "C16 --ci-mode: total_bands=2" \
        || fail "C16 --ci-mode: total_bands!=2, out=$out"
}

# ── C17 (B6): --max-bands caps the sweep and warns ───────────────────────────
C17_max_bands_upper_bound() {
    make_fixture c17
    local out; run_sweep --max-bands 1 --band-size 2 --ci-mode; out="$OUT"
    echo "$out" | grep -q '"scanned":2' \
        && pass "C17 --max-bands 1: only band 0 swept (scanned=2)" \
        || fail "C17 --max-bands 1: scanned!=2, out=$out"
    echo "$out" | grep -q '"bands_swept":1' \
        && pass "C17 --max-bands 1: bands_swept=1" \
        || fail "C17 --max-bands 1: bands_swept!=1, out=$out"
    echo "$out" | grep -q '"total_bands":2' \
        && pass "C17 --max-bands 1: total_bands=2 (cap is below the real total)" \
        || fail "C17 --max-bands 1: total_bands!=2, out=$out"
    echo "$out" | grep -qi 'WARNING' \
        && pass "C17 --max-bands 1: WARNING emitted about the cap" \
        || fail "C17 --max-bands 1: no WARNING about capped sweep, out=$out"
}

# ── C18 (B7): a band-K failure aborts before tier 1 (exit 1, no gate) ────────
C18_band_failure_aborts() {
    make_fixture c18
    stub_list_band_fail_band1
    local out; run_sweep --band-size 2; out="$OUT"
    [ "$RC" -eq 1 ] \
        && pass "C18 band failure: run exits 1" \
        || fail "C18 band failure: exit=$RC (want 1), out=$out"
    record_has "close-completed 900" \
        && fail "C18 band failure: tier-1 close-completed #900 ran despite a failed band" \
        || pass "C18 band failure: tier 1 (#900) not executed after a band failure"
    echo "$out" | grep -q 'TIER2-GATE' \
        && fail "C18 band failure: emitted a TIER2-GATE block despite the failure, out=$out" \
        || pass "C18 band failure: no TIER2-GATE block emitted"
}

# ── C19 (B8): --deep --dry-run calls no write helpers ────────────────────────
C19_all_bands_deep_dry_run() {
    make_fixture c19
    local out; run_sweep --deep --dry-run --band-size 2; out="$OUT"
    [ "$RC" -eq 0 ] \
        && pass "C19 --deep --dry-run: exit 0" \
        || fail "C19 --deep --dry-run: exit=$RC (want 0), out=$out"
    record_has "close-completed" \
        && fail "C19 --deep --dry-run: close-completed was called (must not write under --dry-run)" \
        || pass "C19 --deep --dry-run: close-completed not called"
    record_has "close-not-planned" \
        && fail "C19 --deep --dry-run: close-not-planned was called (must not write under --dry-run)" \
        || pass "C19 --deep --dry-run: close-not-planned not called"
}

# ── C20 (B9): --verify-candidates / --decisions skip band fetch and tier 1 ────
C20_verify_decisions_skip_band_fetch() {
    local tsv="$TMPDIR_BASE/c20-survivors.tsv"
    printf 'number\ttokens_csv\tclass\n101\tbin/gone-a.sh\tobsolete\n' > "$tsv"
    local dec="$TMPDIR_BASE/c20-decisions.tsv"
    printf 'number\taction\targ\trationale\n101\tclose-not-planned\t-\tobsolete\n' > "$dec"

    make_fixture c20vc
    run_sweep --deep --verify-candidates "$tsv"
    local nvc; nvc="$(gh_band_fetch_count)"
    [ "${nvc:-0}" -eq 0 ] \
        && pass "C20 --verify-candidates: gh band fetch not called (count=0)" \
        || fail "C20 --verify-candidates: unexpected band fetch count=$nvc"
    local mvc; mvc="$(parent_check_count 900)"
    [ "${mvc:-0}" -eq 0 ] \
        && pass "C20 --verify-candidates: tier-1 not called" \
        || fail "C20 --verify-candidates: tier-1 ran $mvc times (want 0)"

    make_fixture c20dec
    run_sweep --deep --decisions "$dec"
    local ndc; ndc="$(gh_band_fetch_count)"
    [ "${ndc:-0}" -eq 0 ] \
        && pass "C20 --decisions: gh band fetch not called (count=0)" \
        || fail "C20 --decisions: unexpected band fetch count=$ndc"
    local mdc; mdc="$(parent_check_count 900)"
    [ "${mdc:-0}" -eq 0 ] \
        && pass "C20 --decisions: tier-1 not called" \
        || fail "C20 --decisions: tier-1 ran $mdc times (want 0)"
}

# ── C21 (B10): SI-2 scan failure for a band: tier 1 is independent ──────────────
C21_all_bands_scan_fail_tier1_independent() {
    make_fixture c21
    stub_scan_fail_band1
    local out; run_sweep --band-size 2; out="$OUT"
    [ "$RC" -ne 0 ] \
        && pass "C21 SI-2 scan fail: run exits non-zero" \
        || fail "C21 SI-2 scan fail: exit=$RC (want non-zero), out=$out"
    record_has "close-completed 900" \
        && pass "C21 SI-2 scan fail: tier 1 (#900) executed independently of scan failure" \
        || fail "C21 SI-2 scan fail: tier 1 (#900) not executed — expected independent of scan failure"
    echo "$out" | grep -q 'TIER2-GATE' \
        && fail "C21 SI-2 scan fail: TIER2-GATE emitted despite the scan failure, out=$out" \
        || pass "C21 SI-2 scan fail: no TIER2-GATE block emitted"
}

C12_all_bands_sweeps_all
C13_all_bands_single_fetch
C14_all_bands_tier1_once
C15_all_bands_deep_single_gate
C16_all_bands_ci_contract
C17_max_bands_upper_bound
C18_band_failure_aborts
C19_all_bands_deep_dry_run
C20_verify_decisions_skip_band_fetch
C21_all_bands_scan_fail_tier1_independent

# ── C22: no flags → default is all-bands (band_index=all in CI summary) ──────
C22_no_flags_defaults_to_all_bands() {
    make_fixture c22
    local out; run_sweep --band-size 2 --ci-mode; out="$OUT"
    echo "$out" | grep -q '"band_index":"all"' \
        && pass "C22 no flags: band_index=all (default is all-bands)" \
        || fail "C22 no flags: band_index is not all — default not applied, out=$out"
    echo "$out" | grep -q '"bands_swept":2' \
        && pass "C22 no flags: bands_swept=2" \
        || fail "C22 no flags: bands_swept!=2, out=$out"
}

C22_no_flags_defaults_to_all_bands

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
