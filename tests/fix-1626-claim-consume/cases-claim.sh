# Part of tests/fix-1626-claim-consume.sh (sourced, not standalone).
# C1-C6 — the atomic claim itself: normal claim, the concurrent TOCTOU race,
# spent/stale .claimed refusal, mint-time recovery, and the I/O error path.

# ============================================================================
# C1 — normal claim: valid bare token → allow + atomic rename into .claimed
# ============================================================================
run_C1() {
    local tmp tn r rc out ok=1 fields
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    write_bare "$tn" "c1sid"
    r=$(run_shim "$tn" "c1sid" "$WF_BOUND"); rc="${r%%|*}"; out="${r#*|}"
    [ "$rc" = "0" ] || ok=0
    is_block "$out" && ok=0
    [ -f "$tmp/c1sid.off-clearance.claimed" ] || ok=0
    [ -f "$tmp/c1sid.off-clearance" ] && ok=0
    fields=$("$RWT" 10 node -e "
try{const t=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
process.stdout.write((t.claimed_at&&t.claimed_target&&t.claimed_reason)?'OK':'MISSING');}
catch(e){process.stdout.write('UNREADABLE');}" "$tmp/c1sid.off-clearance.claimed" 2>/dev/null)
    [ "$fields" = "OK" ] || ok=0
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$ok" = "1" ]; then
        pass "C1: valid bare token → shim allows AND atomically claims it (.claimed written, bare gone, claim metadata present)"
    else
        fail "C1: RED-EXPECTED (claim not implemented): rc=$rc claimed_fields=$fields out=$out"
    fi
}

# ============================================================================
# C2 — CONCURRENT claim race (the core TOCTOU regression case).
#
# NOTE: sequential execution CANNOT exercise this race. Running the shim twice
# one after the other only proves "second run sees no bare token"; it never puts
# two validators inside the same check-then-act window. The bug only manifests
# when both processes read the bare token BEFORE either has claimed it, which
# requires genuinely concurrent processes (`run_shim ... & run_shim ... & wait`).
#
# Repeated 5x. A single flaky iteration is a REAL bug (the wx claim is not
# atomic) — do NOT raise the tolerance, fail the test.
# ============================================================================
run_C2() {
    local iter tmp tn hi rc1 rc2 out1 out2 ok=1 detail=""
    for iter in 1 2 3 4 5; do
        tmp=$(make_tmp); tn=$(node_path "$tmp")
        write_bare "$tn" "c2sid"
        hi=$(mk_input "c2sid" "$WF_BOUND")   # same stdin JSON for both racers
        ( WORKFLOW_PLANS_DIR="$tn" CLAUDE_WORKFLOW_DIR="$tn" AGENTS_CONFIG_DIR="$tn" \
            "$RWT" 12 node "$SHIM" <<< "$hi" > "$tmp/out1" 2>/dev/null; echo $? > "$tmp/rc1" ) &
        ( WORKFLOW_PLANS_DIR="$tn" CLAUDE_WORKFLOW_DIR="$tn" AGENTS_CONFIG_DIR="$tn" \
            "$RWT" 12 node "$SHIM" <<< "$hi" > "$tmp/out2" 2>/dev/null; echo $? > "$tmp/rc2" ) &
        wait
        rc1=$(cat "$tmp/rc1" 2>/dev/null || echo X); rc2=$(cat "$tmp/rc2" 2>/dev/null || echo X)
        out1=$(cat "$tmp/out1" 2>/dev/null || echo ""); out2=$(cat "$tmp/out2" 2>/dev/null || echo "")

        # (i) exactly one winner (exit 0)
        local zeros=0
        [ "$rc1" = "0" ] && zeros=$((zeros + 1))
        [ "$rc2" = "0" ] && zeros=$((zeros + 1))
        [ "$zeros" -eq 1 ] || { ok=0; detail="$detail iter$iter:winners=$zeros(rc1=$rc1,rc2=$rc2)"; }
        # (ii) the loser exits 2 with a block decision
        if [ "$rc1" = "0" ]; then
            { [ "$rc2" = "2" ] && is_block "$out2"; } || { ok=0; detail="$detail iter$iter:loser2 rc=$rc2"; }
        elif [ "$rc2" = "0" ]; then
            { [ "$rc1" = "2" ] && is_block "$out1"; } || { ok=0; detail="$detail iter$iter:loser1 rc=$rc1"; }
        fi
        # (iii) exactly one .claimed file
        local nclaim; nclaim=$(count_glob "$tmp/*.off-clearance.claimed")
        [ "$nclaim" = "1" ] || { ok=0; detail="$detail iter$iter:claimed=$nclaim"; }
        # (iv) the bare token is gone
        [ -f "$tmp/c2sid.off-clearance" ] && { ok=0; detail="$detail iter$iter:bare-survived"; }

        rm -rf "$tmp" 2>/dev/null || true
    done
    if [ "$ok" = "1" ]; then
        pass "C2: 5x concurrent double-proposal — exactly one allow, one block, one .claimed, bare consumed (TOCTOU-safe)"
    else
        fail "C2: RED-EXPECTED (two-step claim still races): concurrent proposals not mutually exclusive;$detail"
    fi
}

# ============================================================================
# C3 — re-proposal against an already-.claimed-only token → block.
# Explicit regression guard: a .claimed file is SPENT. However legitimate its
# contents look, it must never be re-accepted as authorization.
# ============================================================================
run_C3() {
    local tmp tn r rc out ok=1
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    write_claimed "$tn" "c3sid"          # .claimed only — no bare token
    r=$(run_shim "$tn" "c3sid" "$WF_BOUND"); rc="${r%%|*}"; out="${r#*|}"
    [ "$rc" = "2" ] || ok=0
    is_block "$out" || ok=0
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$ok" = "1" ]; then
        pass "C3: already-.claimed token (no bare) → block (spent token is never re-accepted)"
    else
        fail "C3: RED-EXPECTED: a .claimed-only token must block; rc=$rc out=$out"
    fi
}

# ============================================================================
# C4 — stale .claimed + valid bare: CROSS-PLATFORM INVARIANT.
# The same expectation holds on every platform — there is deliberately NO
# `uname` branching here. fs.openSync(path,"wx") throws EEXIST on POSIX AND on
# Windows, so a pre-existing .claimed must always defeat the claim.
# If this case passes on one OS and fails on another, the wx claim primitive
# itself is broken (not the test): do not paper over it with a platform branch.
# ============================================================================
run_C4() {
    local tmp tn r rc out ok=1 h_before h_after
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    write_claimed "$tn" "c4sid"
    write_bare "$tn" "c4sid"
    h_before=$(file_hash "$tmp/c4sid.off-clearance.claimed")
    r=$(run_shim "$tn" "c4sid" "$WF_BOUND"); rc="${r%%|*}"; out="${r#*|}"
    h_after=$(file_hash "$tmp/c4sid.off-clearance.claimed")
    local bare_left=no; [ -f "$tmp/c4sid.off-clearance" ] && bare_left=yes
    local hash_same=no; [ "$h_before" = "$h_after" ] && hash_same=yes
    [ "$rc" = "2" ] || ok=0
    is_block "$out" || ok=0
    [ "$bare_left" = "yes" ] || ok=0                    # bare must survive un-consumed
    [ "$hash_same" = "yes" ] || ok=0                    # .claimed must be untouched
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$ok" = "1" ]; then
        pass "C4: stale .claimed + valid bare → block; bare un-consumed; .claimed untouched (same on all platforms)"
    else
        fail "C4: RED-EXPECTED (no wx claim yet): rc=$rc bare_left=$bare_left hash_same=$hash_same out=$out"
    fi
}

# ============================================================================
# C5 — stale-claim recovery via bin/request-off-clearance (mint-time reset).
# Starting from the C4 deadlock state, a fresh mint must clear the stale .claimed
# so the next proposal can succeed.
# ============================================================================
run_C5() {
    local tmp tn stubbin r rc out ok=1
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    write_claimed "$tn" "c5sid"
    write_bare "$tn" "c5sid"

    stubbin=$(make_tmp)
    write_examiner_stub "$stubbin/codex" ALLOW "legit workflow bug"
    PATH="$stubbin:$PATH" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" WORKFLOW_PLANS_DIR="$tn" \
        CLAUDE_WORKFLOW_DIR="$tn" SESSION_ID="c5sid" CLAUDE_CODE_SESSION_ID="c5sid" \
        "$RWT" 40 bash "$REQ" --target workflow --category workflow-bug --detail "next-step bug" >/dev/null 2>&1
    rm -rf "$stubbin" 2>/dev/null || true

    local stale_left=no; [ -f "$tmp/c5sid.off-clearance.claimed" ] && stale_left=yes
    [ "$stale_left" = "no" ] || ok=0                    # stale claim must be reset at mint time
    r=$(run_shim "$tn" "c5sid" "$WF_BOUND"); rc="${r%%|*}"; out="${r#*|}"
    [ "$rc" = "0" ] || ok=0
    is_block "$out" && ok=0
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$ok" = "1" ]; then
        pass "C5: re-mint clears the stale .claimed and the next OFF proposal is allowed again (deadlock recovery)"
    else
        fail "C5: RED-EXPECTED (no stale-claim reset at mint): stale_claimed_left=$stale_left rc=$rc out=$out"
    fi
}

# ============================================================================
# C6 — I/O error path: the .claimed path already exists as a DIRECTORY, so
# openSync(...,"wx") fails with EEXIST/EISDIR/EPERM depending on platform.
# The shim must block regardless of which error subtype it gets (fail-CLOSED).
# ============================================================================
run_C6() {
    local tmp tn r rc out ok=1
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    write_bare "$tn" "c6sid"
    mkdir -p "$tmp/c6sid.off-clearance.claimed"
    r=$(run_shim "$tn" "c6sid" "$WF_BOUND"); rc="${r%%|*}"; out="${r#*|}"
    [ "$rc" = "2" ] || ok=0
    is_block "$out" || ok=0
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$ok" = "1" ]; then
        pass "C6: .claimed path pre-created as a directory → claim fails → block (fail-CLOSED on any I/O error subtype)"
    else
        fail "C6: RED-EXPECTED: an unclaimable token must block; rc=$rc out=$out"
    fi
}
