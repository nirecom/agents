# shellcheck shell=bash
# Case group: Section 1 — State Inheritance.
# Sourced by main-workflow-state-machine.sh; relies on helpers from common.sh.
# Tests: hooks/workflow-state/inheritance.js
# Tags: helper, state-inheritance, scope:common

run_state_inheritance_tests() {
    # ---------------------------------------------------------------------------
    # Section 1: State Inheritance
    # (Smoke — full gate matrix in tests/feature-1305-inheritance-lineage.sh)
    #
    # Since #1305 a donor is reached through the heir's OWN transcript lineage,
    # never through a cwd+branch scan, so every case here seeds a heir sid with
    # `forkedFrom` (or a copied announce line) pointing at the donor.
    # ---------------------------------------------------------------------------
    echo ""
    echo "=== Section 1: State Inheritance ==="

    # L1-a: donor with research=complete + fork lineage → resolveInheritanceDonor returns it
    CWD_1A="/users/test/repo-l1a-$$"
    ENC_1A=$(encode_path "$CWD_1A")
    HOME_1A="$TMPDIR_BASE/home-1a"
    mkdir -p "$HOME_1A/.claude/projects/$ENC_1A"
    SID_1A="l1a-$(printf '%04x%04x' $RANDOM $RANDOM)"
    HEIR_1A="l1aheir-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_1A" "$(INHERIT_STATE_JSON "$SID_1A" "main")"
    write_forked_transcript_line "$HOME_1A/.claude/projects/$ENC_1A/${HEIR_1A}.jsonl" \
        "$HEIR_1A" "$SID_1A"
    RESULT_1A=$(call_resolve_donor "$CWD_1A" "main" "$HOME_1A" "$HEIR_1A")
    RESEARCH_1A=$(get_json_step_status "$RESULT_1A" "research")
    if [ "$RESEARCH_1A" = "complete" ]; then
        pass "L1-a. fork lineage + research=complete donor → inherited research=complete"
    else
        fail "L1-a. inheritance smoke — expected research=complete, got: $RESEARCH_1A (result: $RESULT_1A)"
    fi

    # L1-b: donor with user_verification=complete → NOT inherited (S1 boundary),
    # even though the lineage evidence itself is impeccable.
    HOME_1B="$TMPDIR_BASE/home-1b"
    CWD_1B="/users/test/repo-l1b-$$"
    ENC_1B=$(encode_path "$CWD_1B")
    mkdir -p "$HOME_1B/.claude/projects/$ENC_1B"
    SID_1B="l1b-$(printf '%04x%04x' $RANDOM $RANDOM)"
    HEIR_1B="l1bheir-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_1B" "$(ALL_COMPLETE_JSON "$SID_1B" "main")"
    write_forked_transcript_line "$HOME_1B/.claude/projects/$ENC_1B/${HEIR_1B}.jsonl" \
        "$HEIR_1B" "$SID_1B"
    RESULT_1B=$(call_resolve_donor "$CWD_1B" "main" "$HOME_1B" "$HEIR_1B")
    expect_not_inherited "L1-b. user_verification=complete → not inherited (returns null)" "$RESULT_1B"

    # L1-c: session-start called twice on same session ID → state not overwritten (idempotency)
    REPO_1C=$(setup_repo)
    SID_1C="l1c-$(printf '%04x%04x' $RANDOM $RANDOM)"
    ENV_FILE_1C="$TMPDIR_BASE/1c.env"
    write_state "$SID_1C" "$(INHERIT_STATE_JSON "$SID_1C" "main")"
    for _i in 1 2; do
        echo "{\"session_id\":\"$SID_1C\"}" | \
            CLAUDE_PROJECT_DIR="$REPO_1C" CLAUDE_ENV_FILE="$ENV_FILE_1C" \
            CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$SESSION_START" 2>/dev/null || true
    done
    expect_state_step "L1-c. session-start 2 runs → research remains complete (idempotent)" \
        "$SID_1C" "research" "complete"

    # L1-d: the second lineage evidence shape. A compact copies the donor's
    # PostCompact announce line into the heir's transcript; that must be honoured
    # exactly like a `forkedFrom` row (#1305 / CPR-ORTH). This replaces the old
    # "newest transcript mtime wins" case — mtime no longer selects a donor.
    HOME_1D="$TMPDIR_BASE/home-1d"
    CWD_1D="/users/test/repo-l1d-$$"
    ENC_1D=$(encode_path "$CWD_1D")
    mkdir -p "$HOME_1D/.claude/projects/$ENC_1D"
    SID_1D_PC="l1d-pc-$(printf '%04x%04x' $RANDOM $RANDOM)"   # donor: research+outline+detail=complete
    HEIR_1D="l1dheir-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_1D_PC" "$(cat <<EOF
{
  "version": 1, "session_id": "$SID_1D_PC", "git_branch": "main",
  "created_at": "$NOW_ISO",
  "steps": {
    "research":          {"status": "complete", "updated_at": "$NOW_ISO"},
    "outline":           {"status": "complete", "updated_at": "$NOW_ISO"},
    "detail":            {"status": "complete", "updated_at": "$NOW_ISO"},
    "write_tests":       {"status": "pending",  "updated_at": null},
    "review_tests":      {"status": "pending",  "updated_at": null},
    "review_security":   {"status": "pending",  "updated_at": null},
    "run_tests":         {"status": "pending",  "updated_at": null},
    "docs":              {"status": "pending",  "updated_at": null},
    "user_verification": {"status": "pending",  "updated_at": null}
  }
}
EOF
)"
    # The heir's transcript carries ONLY the copied PostCompact announce line —
    # no forkedFrom row — so this isolates the announce-line evidence path.
    write_postcompact_line "$HOME_1D/.claude/projects/$ENC_1D/${HEIR_1D}.jsonl" \
        "$SID_1D_PC" "$(to_node_path "$WORKFLOW_DIR/${SID_1D_PC}.json")"
    RESULT_1D=$(call_resolve_donor "$CWD_1D" "main" "$HOME_1D" "$HEIR_1D" compact)
    PLAN_1D=$(get_json_step_status "$RESULT_1D" "detail")
    if [ "$PLAN_1D" = "complete" ]; then
        pass "L1-d. copied PostCompact announce line is lineage evidence → detail=complete"
    else
        fail "L1-d. announce-line lineage — expected detail=complete, got: $PLAN_1D (result: $RESULT_1D)"
    fi

    run_state_inheritance_derivation_tests
}

# ---------------------------------------------------------------------------
# #1305 / #1681: read-time derivation of the RESUMABILITY verdict.
#
# Why the boundary moved (#1305): staleness used to be the only thing standing
# between an unrelated session and someone else's steps, so it was drawn early
# and defensively at the verification tier (review_security). Lineage now does
# that job — a donor is only ever the heir's own ancestor — so the verification
# tier is no longer a boundary at all (S2 removed). What survives is the set of
# states that are genuinely unusable to their OWN continuation: a finished
# session (S1, user_verification complete), a fresh one with nothing to give
# (S0), and one whose recorded intent has no intent.md behind it (S3).
# ---------------------------------------------------------------------------

# Fixture builder: one step-status map, everything else pending.
# $1 sid, $2 extra JSON step entries (already comma-terminated), $3 branch
DERIVATION_STATE_JSON() {
    local sid="$1" extra="$2" branch="${3:-main}"
    cat <<EOF
{
  "version": 1, "session_id": "$sid", "git_branch": "$branch",
  "created_at": "$NOW_ISO",
  "steps": {
    $extra
    "research":          {"status": "complete", "updated_at": "$NOW_ISO"},
    "write_tests":       {"status": "pending",  "updated_at": null},
    "review_tests":      {"status": "pending",  "updated_at": null},
    "run_tests":         {"status": "pending",  "updated_at": null},
    "docs":              {"status": "pending",  "updated_at": null},
    "user_verification": {"status": "pending",  "updated_at": null}
  }
}
EOF
}

# Set up an isolated cwd-context + transcript dir. Sets CWD_X / ENC_X / HOME_X.
derivation_ctx() {
    local tag="$1"
    D_CWD="/users/test/repo-${tag}-$$"
    D_ENC=$(encode_path "$D_CWD")
    D_HOME="$TMPDIR_BASE/home-${tag}"
    mkdir -p "$D_HOME/.claude/projects/$D_ENC"
}

# An ERROR: result means resolveInheritanceDonor threw or is missing — that
# must never be reported as "correctly declined to inherit" (false green).
expect_not_inherited() {
    local desc="$1" result="$2"
    case "$result" in
        ERROR:*) fail "$desc — the resolver did not run: $result"; return ;;
    esac
    if [ "$result" = "null" ] || [ -z "$result" ]; then
        pass "$desc"
    else
        fail "$desc — expected null, got: $result"
    fi
}

# seed_lineage <tag-sid> <heir-sid> — heir transcript forked from the donor,
# written into the derivation_ctx transcript dir.
seed_lineage() {
    write_forked_transcript_line "$D_HOME/.claude/projects/$D_ENC/${2}.jsonl" "$2" "$1"
}

run_state_inheritance_derivation_tests() {
    echo ""
    echo "=== Section 1b: State Inheritance — read-time derivation (#1305/#1681) ==="

    # L1-e: S2 REMOVED (#1305). review_security=complete no longer blocks: with
    # lineage proving the heir IS this session's continuation, stopping it from
    # resuming its own verified work has no protective value left.
    derivation_ctx "l1e"
    SID_1E="l1e-$(printf '%04x%04x' $RANDOM $RANDOM)"
    HEIR_1E="l1eheir-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_1E" "$(DERIVATION_STATE_JSON "$SID_1E" \
        '"review_security":   {"status": "complete", "updated_at": "'"$NOW_ISO"'"},')"
    seed_lineage "$SID_1E" "$HEIR_1E"
    RESULT_1E=$(call_resolve_donor "$D_CWD" "main" "$D_HOME" "$HEIR_1E")
    RESEARCH_1E=$(get_json_step_status "$RESULT_1E" "research")
    if [ "$RESEARCH_1E" = "complete" ]; then
        pass "L1-e. review_security=complete no longer blocks inheritance (S2 removed)"
    else
        fail "L1-e. S2 removal — expected the donor to be returned, got: $RESULT_1E"
    fi

    # L1-f: clarify_intent literally recorded complete but no intent.md artifact.
    # A recorded-complete intent stage with no artifact is unusable state.
    derivation_ctx "l1f"
    SID_1F="l1f-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_1F" "$(DERIVATION_STATE_JSON "$SID_1F" \
        '"clarify_intent":    {"status": "complete", "updated_at": "'"$NOW_ISO"'"},
    "review_security":   {"status": "pending",  "updated_at": null},')"
    rm -f "$TEST_PLANS_DIR/${SID_1F}-intent.md"
    HEIR_1F="l1fheir-$(printf '%04x%04x' $RANDOM $RANDOM)"
    seed_lineage "$SID_1F" "$HEIR_1F"
    RESULT_1F=$(call_resolve_donor "$D_CWD" "main" "$D_HOME" "$HEIR_1F")
    expect_not_inherited \
        "L1-f. clarify_intent recorded complete without intent.md → not inherited" \
        "$RESULT_1F"

    # L1-g (positive control): outline+detail reach "complete" via the plan→
    # outline/detail migration inside readState(), with NO plan artifacts on disk.
    # That is legitimate legacy state — narrowing the artifact check to
    # clarify_intent must NOT break it.
    derivation_ctx "l1g"
    SID_1G="l1g-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_1G" "$(DERIVATION_STATE_JSON "$SID_1G" \
        '"plan":              {"status": "complete", "updated_at": "'"$NOW_ISO"'"},
    "review_security":   {"status": "pending",  "updated_at": null},')"
    rm -f "$TEST_PLANS_DIR/${SID_1G}-outline.md" "$TEST_PLANS_DIR/${SID_1G}-detail.md"
    HEIR_1G="l1gheir-$(printf '%04x%04x' $RANDOM $RANDOM)"
    seed_lineage "$SID_1G" "$HEIR_1G"
    RESULT_1G=$(call_resolve_donor "$D_CWD" "main" "$D_HOME" "$HEIR_1G")
    DETAIL_1G=$(get_json_step_status "$RESULT_1G" "detail")
    if [ "$DETAIL_1G" = "complete" ]; then
        pass "L1-g. synthesized outline/detail complete without artifacts → still inherited"
    else
        fail "L1-g. expected inherited detail=complete, got: $DETAIL_1G (result: $RESULT_1G)"
    fi

    # L1-h (boundary): a mid-review-cycle round-number file must not make the
    # prior session look stale — plan-artifact presence, not completion evidence,
    # is what the inheritance check may consult.
    derivation_ctx "l1h"
    SID_1H="l1h-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_1H" "$(DERIVATION_STATE_JSON "$SID_1H" \
        '"clarify_intent":    {"status": "complete", "updated_at": "'"$NOW_ISO"'"},
    "outline":           {"status": "complete", "updated_at": "'"$NOW_ISO"'"},
    "review_security":   {"status": "pending",  "updated_at": null},')"
    printf 'intent\n'  > "$TEST_PLANS_DIR/${SID_1H}-intent.md"
    printf 'outline\n' > "$TEST_PLANS_DIR/${SID_1H}-outline.md"
    printf '2\n'       > "$TEST_PLANS_DIR/${SID_1H}-outline-plan-round-number.txt"
    HEIR_1H="l1hheir-$(printf '%04x%04x' $RANDOM $RANDOM)"
    seed_lineage "$SID_1H" "$HEIR_1H"
    RESULT_1H=$(call_resolve_donor "$D_CWD" "main" "$D_HOME" "$HEIR_1H")
    OUTLINE_1H=$(get_json_step_status "$RESULT_1H" "outline")
    if [ "$OUTLINE_1H" = "complete" ]; then
        pass "L1-h. outline.md present + in-flight review round → still inherited"
    else
        fail "L1-h. expected inherited outline=complete, got: $OUTLINE_1H (result: $RESULT_1H)"
    fi

    # L1-i (#1305 core): the ancestor chain has a single decision-maker — the
    # NEAREST ancestor holding state. Before #1305 mtime ordering plus the S2
    # staleness rule made this pair resolve to "nothing"; now the nearest
    # ancestor answers and the grandparent is never consulted at all.
    derivation_ctx "l1i"
    SID_1I_OLD="l1iold-$(printf '%04x%04x' $RANDOM $RANDOM)"   # grandparent
    SID_1I_NEW="l1inew-$(printf '%04x%04x' $RANDOM $RANDOM)"   # nearest ancestor
    HEIR_1I="l1iheir-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_1I_OLD" "$(INHERIT_STATE_JSON "$SID_1I_OLD" "main")"
    write_state "$SID_1I_NEW" "$(DERIVATION_STATE_JSON "$SID_1I_NEW" \
        '"review_security":   {"status": "complete", "updated_at": "'"$NOW_ISO"'"},')"
    # heir → NEW → OLD
    seed_lineage "$SID_1I_NEW" "$HEIR_1I"
    write_forked_transcript_line \
        "$D_HOME/.claude/projects/$D_ENC/${SID_1I_NEW}.jsonl" "$SID_1I_NEW" "$SID_1I_OLD"
    RESULT_1I=$(call_resolve_donor "$D_CWD" "main" "$D_HOME" "$HEIR_1I")
    case "$RESULT_1I" in
        ERROR:*) fail "L1-i. the resolver did not run: $RESULT_1I" ;;
        *)
            if echo "$RESULT_1I" | grep -qF "$SID_1I_OLD"; then
                fail "L1-i. the walk went past the nearest ancestor to the grandparent ($SID_1I_OLD)"
            elif echo "$RESULT_1I" | grep -qF "$SID_1I_NEW"; then
                pass "L1-i. the nearest ancestor with state is the donor (grandparent never consulted)"
            else
                fail "L1-i. expected the nearest ancestor $SID_1I_NEW, got: $RESULT_1I"
            fi
            ;;
    esac
}
