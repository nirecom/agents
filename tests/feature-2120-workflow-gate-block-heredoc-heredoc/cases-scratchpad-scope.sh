# Tests: hooks/lib/claude-scratchpad-base.js, hooks/enforce-worktree.js, hooks/lib/alt-target-remedy.js
# Tags: enforce-worktree, scratchpad, session-scope, scope:issue-specific
# M12 — the SCRATCHPAD-present branch of getScratchpadAllowRootNorm(), plus the
# remedy wording matching the session-scoped gate root.
# Sourced by feature-2120-workflow-gate-block-heredoc-heredoc.sh.

run_M12() {
    # M12 (C2, test-review round 3) — the SCRATCHPAD-present branch of
    # getScratchpadAllowRootNorm() (claude-scratchpad-base.js H2). The rest of this
    # suite deliberately `unset SCRATCHPAD` so the allow root falls back to the whole
    # claude base; nothing exercised the session-SCOPED root the harness actually
    # sets. When SCRATCHPAD resolves under the claude base, the allow root tightens
    # to THAT directory — a sibling session's dir under the same base is rejected.
    local sess_a sess_b out r
    if [ -z "$CLAUDE_BASE_FWD" ] || [ -z "$CLAUDE_BASE_RAW" ]; then
        fail "M12: could not resolve the claude scratchpad base — the SCRATCHPAD-scoped branch is UNTESTED"
        return
    fi
    sess_a="$CLAUDE_BASE_FWD/t2120-session-a"
    sess_b="$CLAUDE_BASE_FWD/t2120-session-b"

    # In-scope: strictly under the session-scoped allow root. SCRATCHPAD is set on
    # the ew_run call (not on bash_payload) — the HOOK process is what must see it.
    out="$(SCRATCHPAD="$sess_a" ew_run "$MAIN" "$(bash_payload "$(hd "$sess_a/note.md")")")"
    case "$(verdict_of "$out")" in
        (allow) pass "M12a: with SCRATCHPAD set, a heredoc write UNDER that exact root is ALLOWED" ;;
        (block) fail "M12a: expected allow for a write under the SCRATCHPAD root, got block: $out" ;;
        (*)     fail "M12a: hook stdout is not a parseable JSON verdict: $out" ;;
    esac

    # Sibling session dir: under the BROAD claude base, outside the scoped root.
    out="$(SCRATCHPAD="$sess_a" ew_run "$MAIN" "$(bash_payload "$(hd "$sess_b/note.md")")")"
    case "$(verdict_of "$out")" in
        (block) pass "M12b: a sibling dir under the claude base but OUTSIDE the SCRATCHPAD root is BLOCKED" ;;
        (allow) fail "M12b: cross-session scratchpad write was ALLOWED — H2 session scoping is not enforced: $out" ;;
        (*)     fail "M12b: hook stdout is not a parseable JSON verdict: $out" ;;
    esac

    # CPR-ORTH control: the very path M10a2 allows with SCRATCHPAD unset must now
    # be blocked, proving the tightening is caused by SCRATCHPAD and not by the path.
    out="$(SCRATCHPAD="$sess_a" ew_run "$MAIN" "$(bash_payload "$(hd "$SCRATCH_N/note.md")")")"
    case "$(verdict_of "$out")" in
        (block) pass "M12c: the M10a2 path (allowed with SCRATCHPAD unset) is BLOCKED once SCRATCHPAD scopes the root" ;;
        (allow) fail "M12c: SCRATCHPAD did not tighten the allow root — M10a2's path is still allowed: $out" ;;
        (*)     fail "M12c: hook stdout is not a parseable JSON verdict: $out" ;;
    esac

    # The remedy wording. buildAltTargetRemedy() delegates to describeAllowedTargets()
    # (the early-gate allowlist's own SSOT), so it now names the SAME session-scoped
    # root the gate above admits — no gap between what is advertised and what writes.
    out="$(SCRATCHPAD="$sess_a" ew_run "$MAIN" "$(bash_payload "$(hd "$sess_b/note.md")")")"
    r="$(reason_of "$out")"
    if [ -z "$r" ]; then fail "M12d: block produced no reason — the wording assertions would be vacuous"; return; fi
    pass "M12d: the SCRATCHPAD-scoped block produced a reason string"
    alt_target_wording "M12d SCRATCHPAD-scoped block" "$r"

    # C1 (test-review round, post-fix) — exact-match, not substring: extract the
    # parenthesized plans/scratchpad values from the reason and compare them against
    # the RESOLVED paths the gate itself uses (PLANS_N / path.resolve(sess_a)), so a
    # wrong path that merely CONTAINS the "t2120-session-a" basename cannot pass.
    local advertised_plans advertised_scratchpad expected_scratchpad expected_plans
    advertised_plans="$(printf '%s' "$r" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const m=d.match(/plans dir \(([^)]*)\)/);process.stdout.write(m?m[1]:"");})')"
    advertised_scratchpad="$(printf '%s' "$r" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const m=d.match(/scratchpad \(([^)]*)\)/);process.stdout.write(m?m[1]:"");})')"
    expected_scratchpad="$(node -e 'process.stdout.write(require("path").resolve(process.argv[1]))' "$sess_a" 2>/dev/null)"
    # Both sides re-resolved through the SAME node path.resolve() call before comparing
    # — advertised_plans comes from path.resolve() in product code (native backslash
    # form on Windows) while PLANS_N comes from the fixture's cygpath -m (forward-slash
    # form); an exact-match on the raw strings would spuriously fail on slash direction
    # alone despite both denoting the same path.
    expected_plans="$(node -e 'process.stdout.write(require("path").resolve(process.argv[1]))' "$PLANS_N" 2>/dev/null)"
    if [ "$(node -e 'process.stdout.write(require("path").resolve(process.argv[1]))' "$advertised_plans" 2>/dev/null)" = "$expected_plans" ]; then
        pass "M12d: advertised plans dir EXACTLY equals the resolved plans dir (not a substring match)"
    else
        fail "M12d: advertised plans dir [$advertised_plans] != resolved plans dir [$PLANS_N]"
    fi
    if [ "$advertised_scratchpad" = "$expected_scratchpad" ]; then
        pass "M12d: advertised scratchpad EXACTLY equals the resolved SCRATCHPAD-scoped root (not a substring match)"
    else
        fail "M12d: advertised scratchpad [$advertised_scratchpad] != resolved SCRATCHPAD root [$expected_scratchpad]"
    fi

    # M12e (review round 4) — the COMPLEMENTARY POSITIVE for the gap M12d pins.
    # M12b/M12c/M12d only ever show the advertised BROAD base being refused; read
    # alone they say the remedy sends the agent somewhere it cannot write. These
    # rows prove it is not a dead end, and cover the gate's other verdict
    # (skills/_shared/test-design.md, "Classifier / guard cases").
    #   e1: the PLANS DIR the same remedy sentence names stays writable.
    #   e2: a NESTED path under the scoped root is writable — a subtree allow, not
    #       one exact path (M12a only ever wrote an immediate child).
    out="$(SCRATCHPAD="$sess_a" ew_run "$MAIN" "$(bash_payload "$(hd "$PLANS_N/m12-remedy.md")")")"
    case "$(verdict_of "$out")" in
        (allow) pass "M12e1: the plans dir the remedy names is STILL writable while SCRATCHPAD scopes the root" ;;
        (block) fail "M12e1: the remedy's plans-dir half is a DEAD END under SCRATCHPAD scoping — blocked: $out" ;;
        (*)     fail "M12e1: hook stdout is not a parseable JSON verdict: $out" ;;
    esac

    out="$(SCRATCHPAD="$sess_a" ew_run "$MAIN" "$(bash_payload "$(hd "$sess_a/nested/deep/note.md")")")"
    case "$(verdict_of "$out")" in
        (allow) pass "M12e2: a NESTED path under the session-scoped root is writable (subtree allow, not one exact path)" ;;
        (block) fail "M12e2: the session-scoped allow root admits only immediate children: $out" ;;
        (*)     fail "M12e2: hook stdout is not a parseable JSON verdict: $out" ;;
    esac

    # M12f (C2, test-review round post-fix) — SCRATCHPAD set but pointing OUTSIDE the
    # claude base. isAtOrUnderClaudeBase() rejects it, so getScratchpadAllowRootNorm()
    # (the gate) and scratchpadAllowRootForDisplay() (the remedy, via
    # describeAllowedTargets()) must BOTH fall back to the broad claude base — the
    # same fallback M10/M12b-unset-SCRATCHPAD behavior exercises, now proven to
    # trigger from the "SCRATCHPAD present but out-of-base" branch specifically.
    local outside_sp
    outside_sp="$TMP_N/t2120-outside-base"
    out="$(SCRATCHPAD="$outside_sp" ew_run "$MAIN" "$(bash_payload "$(hd "$SCRATCH_N/note.md")")")"
    case "$(verdict_of "$out")" in
        (allow) pass "M12f: out-of-base SCRATCHPAD falls back to the broad claude base — nested target still allowed" ;;
        (block) fail "M12f: out-of-base SCRATCHPAD wrongly narrowed the allow root — fallback broke: $out" ;;
        (*)     fail "M12f: hook stdout is not a parseable JSON verdict: $out" ;;
    esac

    # The block target here must be OUTSIDE the fallback allow root itself (the whole
    # claude base) — sess_b is INSIDE that base and would be wrongly ALLOWED under the
    # fallback, producing no reason to assert against. A path under $TMP_N unrelated to
    # $CLAUDE_BASE_FWD is genuinely rejected by the fallback root, so the block reason
    # exists and the wording assertions below are non-vacuous.
    local unrelated_target
    unrelated_target="$TMP_N/t2120-unrelated-target"
    out="$(SCRATCHPAD="$outside_sp" ew_run "$MAIN" "$(bash_payload "$(hd "$unrelated_target/note.md")")")"
    r="$(reason_of "$out")"
    if [ -n "$r" ]; then
        has "M12f: remedy falls back to naming the BROAD claude base when SCRATCHPAD is out-of-base" "$CLAUDE_BASE_RAW" "$r"
        lacks "M12f: remedy does NOT name the rejected out-of-base SCRATCHPAD path" "t2120-outside-base" "$r"
    else
        fail "M12f: block produced no reason — the fallback wording assertions would be vacuous"
    fi
}
