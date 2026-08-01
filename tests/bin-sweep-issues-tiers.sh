#!/bin/bash
# tests/bin-sweep-issues-tiers.sh
# Tests: bin/sweep-issues.sh, bin/sweep-issues/close-batch.sh, bin/sweep-issues/meta-parent-scan.sh
# Tags: sweep, issues, tier, dry-run, deep, scope:common, TL2
#
# Pins the two orthogonal axes of /sweep-issues:
#   write mode : no flag = apply (tier 1 really closes) | --dry-run = write nothing
#   depth      : no flag = tier 1 only, non-interactive  | --deep = emit tier 2 gate blocks
# --deep must NOT change the write mode, and --dry-run must suppress tier 1 closes.
#
# Technique (after tests/feature-sweep-worktrees/gh-stub.sh): a shadow
# AGENTS_CONFIG_DIR holds real copies of bin/sweep-issues* plus RECORDING STUBS
# for every bin/github-issues/ close helper, so both `$AGENTS_CONFIG_DIR/bin/...`
# and `$(dirname $0)/../github-issues/...` resolution styles hit the stub. Each
# stub appends "<helper> <args>" to a record file, which is how call ORDER and
# ARGUMENTS are asserted (notably: post-close-sentinels must be called with the
# issue number ONLY — a second commit-hash argument would wrongly post a
# resolved-by sentinel on an admin_close_path close).
#
# TL3 gap (what this test does NOT catch):
# - Real `gh` API behaviour: rate limits, sub-issue pagination, and the actual
#   state transitions performed by the real close helpers are all stubbed here.
# - The SKILL.md human gates (AskUserQuestion) that drive pass 2 / pass 3 in a
#   real session — only the bash-side flag contract is exercised.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
    # gh-outbound-guard.sh (sourced by close-batch.sh) resolves this at runtime
    # via $AGENTS_CONFIG_DIR/bin/scan-outbound.sh and is fail-closed if it is
    # missing — see assert_fixture_lib_deps_resolved below for the general check.
    cp "$AGENTS_DIR/bin/scan-outbound.sh"  "$FAKE/bin/"                 2>/dev/null
    chmod -R u+rwx "$FAKE/bin" 2>/dev/null
    # scan-outbound.sh itself guards both of these with `-f` (absence tolerated),
    # but copy them when present so the fixture's scan behaviour matches production.
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
    git -C "$REPO" config user.email t@example.com
    git -C "$REPO" config user.name t
    printf '#!/bin/bash\n' > "$REPO/bin/existing.sh"
    git -C "$REPO" add -A 2>/dev/null
    git -C "$REPO" commit -q --no-verify -m init

    assert_fixture_lib_deps_resolved "$tag"
}

# Guard-completeness precondition (SI-6 class of bug): every bin/lib/*.sh file
# actually `source`d by the copied sweep-issues entrypoints may itself resolve
# a sibling helper by basename at runtime (the way gh-outbound-guard.sh resolves
# scan-outbound.sh). If that helper is not also present under the fixture's
# bin/, the security gate fails closed silently instead of exercising the real
# scan path. This is discovered dynamically from the copied files themselves —
# not a hardcoded "scan-outbound.sh" check — so the next such dependency
# surfaces here instead of as a batch of mysteriously-failing test cases.
#
# Hard-aborts like the "orchestrator not found" setup check below, rather than
# going through pass()/fail(): an incomplete fixture is a setup defect, not a
# test-case outcome.
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

# Replace the real verify-candidate.sh with a recorder (pass-2 wiring assertions).
stub_verify_candidate() {
    cat > "$FAKE/bin/sweep-issues/verify-candidate.sh" <<STUB
#!/bin/bash
printf '%s %s\n' "verify-candidate" "\$*" >> "$RECORD"
printf 'EVIDENCE-GREP: stubbed for %s\n' "\$*"
exit 0
STUB
    chmod +x "$FAKE/bin/sweep-issues/verify-candidate.sh"
}

# Run the orchestrator from the fixture repo. Sets globals OUT and RC.
# (Globals, not stdout: `x=$(run_sweep)` would run the whole function in a
# subshell and RC would never reach the caller.)
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

# Mutating helpers only. parent-all-closed-check is a READ and is expected to run
# even in --dry-run, so "wrote nothing" must not be spelled as "record is empty".
WRITE_HELPERS_RE='^(parent-body-update|close-completed|post-close-sentinels|wip-state|close-not-planned) '
record_no_writes() { ! grep -qE "$WRITE_HELPERS_RE" "$RECORD" 2>/dev/null; }
record_writes() { grep -E "$WRITE_HELPERS_RE" "$RECORD" 2>/dev/null | tr '\n' ' '; }

# Assert the tier-1 helper sequence G→H→J→K ran in order for issue $1.
assert_tier1_sequence() {
    local name="$1" issue="$2"
    local seq
    seq="$(grep -E '^(parent-body-update|close-completed|post-close-sentinels|wip-state) ' "$RECORD" 2>/dev/null \
        | grep -F "$issue" | awk '{print $1}' | tr '\n' ',')"
    if [ "$seq" = "parent-body-update,close-completed,post-close-sentinels,wip-state," ]; then
        pass "$name: tier 1 helpers ran G→H→J→K for #$issue"
    else
        fail "$name: tier 1 order for #$issue was '$seq', want 'parent-body-update,close-completed,post-close-sentinels,wip-state,'"
    fi

    # J must receive the issue number ONLY (no commit hash → appended sentinel only).
    local jline jargs
    jline="$(grep -E '^post-close-sentinels ' "$RECORD" | grep -F "$issue" | head -1)"
    jargs="${jline%% \[GH_REPO*}"
    jargs="${jargs#post-close-sentinels }"
    if [ "$jargs" = "$issue" ]; then
        pass "$name: post-close-sentinels called with #$issue only (no commit hash)"
    else
        fail "$name: post-close-sentinels args were '$jargs', want '$issue' (a 2nd arg posts resolved-by)"
    fi
}

if [ ! -f "$ORCH" ]; then
    fail "setup: orchestrator not found at $ORCH (bin/sweep-issues.sh is not implemented yet)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# ── C1: default (no flags) — tier 1 closes, tier 2 reports, never interactive ──
C1_default_closes_tier1_only() {
    make_fixture c1
    local out; run_sweep; out="$OUT"
    [ "$RC" -eq 0 ] && pass "C1 default: exit 0" || fail "C1 default: exit=$RC, out=$out"
    assert_tier1_sequence "C1 default" 900
    echo "$out" | grep -q 'TIER2-CANDIDATE:' \
        && pass "C1 default: tier 2 reported as TIER2-CANDIDATE lines" \
        || fail "C1 default: no TIER2-CANDIDATE line, out=$out"
    echo "$out" | grep -q 'TIER2-GATE' \
        && fail "C1 default: emitted a TIER2-GATE block without --deep, out=$out" \
        || pass "C1 default: no TIER2-GATE block (stays non-interactive)"
}

# ── C2: --dry-run — nothing written at all ────────────────────────────────────
C2_dry_run_writes_nothing() {
    make_fixture c2
    local out; run_sweep --dry-run; out="$OUT"
    if record_no_writes; then
        pass "C2 --dry-run: no close helper was invoked"
    else
        fail "C2 --dry-run: helpers ran: $(tr '\n' ' ' < "$RECORD")"
    fi
    echo "$out" | grep -q 'DRY-RUN:' \
        && pass "C2 --dry-run: planned closes reported as DRY-RUN lines" \
        || fail "C2 --dry-run: no DRY-RUN line, out=$out"
    echo "$out" | grep -q 'TIER2-GATE' \
        && fail "C2 --dry-run: emitted TIER2-GATE without --deep" \
        || pass "C2 --dry-run: no TIER2-GATE block"
}

# ── C3: --deep — gate block appears AND tier 1 still closes ───────────────────
C3_deep_gates_but_still_applies() {
    make_fixture c3
    local out; run_sweep --deep; out="$OUT"
    echo "$out" | grep -q '<<<TIER2-GATE-SI3' \
        && pass "C3 --deep: TIER2-GATE-SI3 block emitted" \
        || fail "C3 --deep: TIER2-GATE-SI3 block missing, out=$out"
    record_has "close-completed 900" \
        && pass "C3 --deep: tier 1 still closed (--deep does not change write mode)" \
        || fail "C3 --deep: tier 1 did not close; record=$(tr '\n' ' ' < "$RECORD")"
}

# ── C4: --deep --dry-run — the two axes are independent ──────────────────────
C4_deep_and_dry_run_are_orthogonal() {
    make_fixture c4
    local out; run_sweep --deep --dry-run; out="$OUT"
    echo "$out" | grep -q '<<<TIER2-GATE-SI3' \
        && pass "C4 --deep --dry-run: gate block still emitted" \
        || fail "C4 --deep --dry-run: gate block missing, out=$out"
    record_no_writes \
        && pass "C4 --deep --dry-run: no close helper invoked" \
        || fail "C4 --deep --dry-run: helpers ran: $(tr '\n' ' ' < "$RECORD")"
}

# ── C5: --deep is mandatory for both tier 2 passes; modes are exclusive ──────
C5_deep_required_symmetry() {
    make_fixture c5
    local tsv="$TMPDIR_BASE/c5.tsv"
    printf '101\tbin/gone-a.sh\tresolved\n' > "$tsv"
    local dec="$TMPDIR_BASE/c5-dec.tsv"
    printf '101\tcompleted\t-\tdone\n' > "$dec"

    run_sweep --verify-candidates "$tsv" >/dev/null
    [ "$RC" -eq 2 ] && pass "C5a --verify-candidates without --deep exits 2" \
                    || fail "C5a --verify-candidates without --deep exit=$RC, want 2"
    run_sweep --decisions "$dec" >/dev/null
    [ "$RC" -eq 2 ] && pass "C5b --decisions without --deep exits 2" \
                    || fail "C5b --decisions without --deep exit=$RC, want 2"
    run_sweep --deep --verify-candidates "$tsv" --decisions "$dec" >/dev/null
    [ "$RC" -eq 2 ] && pass "C5c --verify-candidates + --decisions together exits 2" \
                    || fail "C5c mutually exclusive modes exit=$RC, want 2"
}

# ── C6: pass 2 verifies exactly the survivors listed, and writes nothing ─────
C6_pass2_scoped_and_readonly() {
    make_fixture c6
    stub_verify_candidate
    local tsv="$TMPDIR_BASE/c6.tsv"
    printf '103\tbin/gone-c.sh\trefactored-away\n' > "$tsv"

    local out; run_sweep --deep --verify-candidates "$tsv"; out="$OUT"
    record_has "verify-candidate --issue 103" \
        && pass "C6a pass 2: verify-candidate received --issue from TSV column 1" \
        || fail "C6a pass 2: no '--issue 103' call; record=$(tr '\n' ' ' < "$RECORD")"
    record_has "--tokens bin/gone-c.sh" \
        && pass "C6b pass 2: verify-candidate received --tokens from TSV column 2" \
        || fail "C6b pass 2: no '--tokens bin/gone-c.sh' call; record=$(tr '\n' ' ' < "$RECORD")"
    record_has "verify-candidate --issue 101" \
        && fail "C6c pass 2: verified issue 101 which is not in the survivors TSV" \
        || pass "C6c pass 2: only TSV-listed issues were verified"
    grep -qE '^(close-completed|close-not-planned|parent-all-closed-check) ' "$RECORD" \
        && fail "C6d pass 2: SI-7 / close path ran during pass 2; record=$(tr '\n' ' ' < "$RECORD")" \
        || pass "C6d pass 2: neither SI-7 nor any close helper ran"
    echo "$out" | grep -q 'EVIDENCE-' \
        && pass "C6e pass 2: EVIDENCE- lines emitted" \
        || fail "C6e pass 2: no EVIDENCE- line, out=$out"
}

# ── C7: non-GitHub remote — skip cleanly, never close ────────────────────────
C7_non_github_remote_skips() {
    make_fixture c7
    printf '#!/bin/bash\nexit 1\n' > "$FAKE/bin/is-github-dotcom-remote"
    chmod +x "$FAKE/bin/is-github-dotcom-remote"
    local out; run_sweep; out="$OUT"
    [ "$RC" -eq 0 ] && pass "C7 non-GitHub remote: exit 0 (cron-safe)" \
                    || fail "C7 non-GitHub remote: exit=$RC, out=$out"
    record_no_writes && pass "C7 non-GitHub remote: no close helper invoked" \
                 || fail "C7 non-GitHub remote: helpers ran: $(tr '\n' ' ' < "$RECORD")"
}

# ── C8: pass 3 runs SI-6 only, and honours the close-not-planned contract ────
C8_pass3_is_si6_only() {
    make_fixture c8
    local dec="$TMPDIR_BASE/c8.tsv"
    {
        printf '800\tscope-reduce\t-\tnarrowed to the parser only\n'
        printf '801\tmigrated\t950\tfolded into 950\n'
    } > "$dec"

    local out; run_sweep --deep --decisions "$dec"; out="$OUT"
    if grep -q 'issue list' "$GHREC" 2>/dev/null; then
        fail "C8a pass 3: SI-1 band fetch ran (gh issue list called): $(tr '\n' ' ' < "$GHREC")"
    else
        pass "C8a pass 3: no band fetch — SI-1/SI-2 did not run"
    fi
    record_has "parent-all-closed-check" \
        && fail "C8b pass 3: SI-7 ran during pass 3" \
        || pass "C8b pass 3: SI-7 did not run"
    record_has "close-not-planned --type migrated --into 950 801" \
        && pass "C8c pass 3: migrated row called close-not-planned with --type/--into only" \
        || fail "C8c pass 3: expected 'close-not-planned --type migrated --into 950 801'; record=$(tr '\n' ' ' < "$RECORD")"
    grep -E '^close-not-planned ' "$RECORD" | grep -q -- '--repo' \
        && fail "C8d pass 3: --repo passed to close-not-planned (it exits 1 on unknown flags)" \
        || pass "C8d pass 3: no --repo passed to close-not-planned"
    grep -E '^close-not-planned ' "$RECORD" | grep -qF "[GH_REPO=$REPO_SLUG]" \
        && pass "C8e pass 3: GH_REPO exported to the helper environment" \
        || fail "C8e pass 3: GH_REPO not exported; record=$(tr '\n' ' ' < "$RECORD")"
    grep -E '^(close-completed|close-not-planned) ' "$RECORD" | grep -q '800' \
        && fail "C8f pass 3: scope-reduce row 800 was closed (must comment only)" \
        || pass "C8f pass 3: scope-reduce row 800 not closed"
    grep -q 'issue comment' "$GHREC" 2>/dev/null \
        && pass "C8g pass 3: rationale posted via gh issue comment" \
        || fail "C8g pass 3: no gh issue comment recorded; gh calls=$(tr '\n' ' ' < "$GHREC")"
}

# ── C9: band slicing ────────────────────────────────────────────────────────
C9_band_boundaries() {
    make_fixture c9
    local out; run_sweep --band-size 2 --band-index 1; out="$OUT"
    echo "$out" | grep -q 'issue=103' \
        && pass "C9a band 1 of size 2 includes the 3rd issue (#103)" \
        || fail "C9a band slice missing #103, out=$out"
    echo "$out" | grep -q 'issue=101' \
        && fail "C9b band 1 of size 2 leaked the 1st issue (#101), out=$out" \
        || pass "C9b band 1 of size 2 excludes the 1st issue (#101)"
}

# ── C10: exit 2 from parent-all-closed-check is NOT a tier 1 close ───────────
C10_no_sub_issues_is_conservative() {
    make_fixture c10
    local out; run_sweep; out="$OUT"
    record_has "close-completed 901" \
        && fail "C10a issue 901 (exit 2 = no sub-issues) was auto-closed; must be conservative" \
        || pass "C10a issue 901 (no sub-issues) not auto-closed"
    echo "$out" | grep -q 'no-sub-issues' \
        && pass "C10b issue 901 classified as no-sub-issues" \
        || fail "C10b no 'no-sub-issues' verdict in output, out=$out"
    record_has "close-completed 902" \
        && fail "C10c issue 902 (exit 1 = has open sub-issues) was auto-closed" \
        || pass "C10c issue 902 (has open sub-issues) not auto-closed"
}

# ── C11: a helper failure is reported as PARTIAL and does not stop the batch ─
C11_partial_mutation_reported() {
    make_fixture c11
    local dec="$TMPDIR_BASE/c11.tsv"
    {
        printf '802\tmigrated\t951\tfolded into 951\n'
        printf '803\tcancelled\t-\tno longer relevant\n'
    } > "$dec"

    local out
    CNP_FAIL_FOR=802
    run_sweep --deep --decisions "$dec"
    CNP_FAIL_FOR=""
    out="$OUT"
    echo "$out" | grep -q 'PARTIAL:' && echo "$out" | grep -q '802' \
        && pass "C11a failing helper row reported as PARTIAL: 802" \
        || fail "C11a no 'PARTIAL:' line for 802, out=$out"
    record_has "close-not-planned --type cancelled" \
        && pass "C11b batch continued to the next row (803) after the failure" \
        || fail "C11b row 803 was not processed; record=$(tr '\n' ' ' < "$RECORD")"
}

C1_default_closes_tier1_only
C2_dry_run_writes_nothing
C3_deep_gates_but_still_applies
C4_deep_and_dry_run_are_orthogonal
C5_deep_required_symmetry
C6_pass2_scoped_and_readonly
C7_non_github_remote_skips
C8_pass3_is_si6_only
C9_band_boundaries
C10_no_sub_issues_is_conservative
C11_partial_mutation_reported

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
