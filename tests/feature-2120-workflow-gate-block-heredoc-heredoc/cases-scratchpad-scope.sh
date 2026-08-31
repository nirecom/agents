# Tests: hooks/lib/claude-scratchpad-base.js, hooks/enforce-worktree.js, hooks/lib/alt-target-remedy.js
# Tags: enforce-worktree, scratchpad, session-scope, scope:issue-specific
# M12 — the SCRATCHPAD-present branch of getScratchpadAllowRootNorm(), plus the
# pinned gap between the session-scoped gate and the broader remedy wording.
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

    # The remedy wording, PINNED AS OBSERVED. buildAltTargetRemedy() advertises
    # getClaudeBaseNorm() — the BROAD base — while the gate above admits only the
    # session-scoped root. The gap is real; it is pinned here rather than asserted
    # away, so narrowing the remedy to the scoped root is a visible, deliberate change.
    out="$(SCRATCHPAD="$sess_a" ew_run "$MAIN" "$(bash_payload "$(hd "$sess_b/note.md")")")"
    r="$(reason_of "$out")"
    if [ -z "$r" ]; then fail "M12d: block produced no reason — the wording assertions would be vacuous"; return; fi
    pass "M12d: the SCRATCHPAD-scoped block produced a reason string"
    has  "M12d: reason names the BROAD claude base (observed remedy wording)" "$CLAUDE_BASE_RAW" "$r"
    lacks "M12d: reason does NOT name the session-scoped root (pinned gap: remedy is broader than the gate)" \
        "t2120-session-a" "$r"
    alt_target_wording "M12d SCRATCHPAD-scoped block" "$r"

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
}
