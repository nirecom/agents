# shellcheck shell=bash
# L-1 .. L-11 — gate ordering and evidence handling in resolveInheritanceDonor.
# Gate order under test: A subagent → B source → C lineage → D nearest ancestor
# with a state file (SOLE decision-maker) → E context match → F resumability.

echo ""
echo "=== #1305 L-1..L-11: donor gates ==="

# --- L-1: `clear` is not a continuation. The user asked for a blank slate;
# lineage evidence in the transcript must not override that.
D1="l1donor-$$"; H1="l1heir-$$"
write_state_v1 "$D1" "$CWD_A" "$BRANCH_A" "$STEPS_INHERITABLE"
write_forked_transcript "$TDIR_A/$H1.jsonl" "$H1" "$D1"
O="$(resolve_donor "$H1" clear "$TDIR_A/$H1.jsonl" "$CWD_A" "$BRANCH_A")"
assert_kv "L-1a. source=clear is gated before lineage is consulted" "$O" decision source-gated
assert_kv "L-1b. source=clear yields no donor" "$O" donor NONE

# --- L-2: THE #1305 REGRESSION. A brand-new `startup` session that happens to
# share cwd+branch with an abandoned session must NOT auto-inherit. The prior
# session stays *discoverable* (so /workflow-init can offer adoption) but is
# never applied silently.
D2="l2donor-$$"; H2="l2heir-$$"
write_state_v1 "$D2" "$CWD_A" "$BRANCH_A" "$STEPS_INHERITABLE"
write_announce_transcript "$TDIR_A/$D2.jsonl" "$D2"
printf '{"type":"user","uuid":"x1","sessionId":"%s"}\n' "$H2" > "$TDIR_A/$H2.jsonl"
O="$(resolve_donor "$H2" startup "$TDIR_A/$H2.jsonl" "$CWD_A" "$BRANCH_A")"
assert_kv "L-2a. startup + no lineage does NOT auto-inherit (#1305 regression)" "$O" donor NONE
assert_kv "L-2b. decision names the startup-no-lineage path" "$O" decision startup-no-lineage
# The abandoned session must remain offerable to the adopt path; whichever
# surface carries it (candidateSessionId on the verdict, or the candidate
# listing), the donor's id has to be reachable.
CAND="$(get_kv "$O" candidate)"
LIST="$(list_candidates "$CWD_A" "$BRANCH_A")"
if [ "$CAND" = "$D2" ] || printf '%s' "$LIST" | grep -q "$D2"; then
    pass "L-2c. the abandoned session is still surfaced as an adoptable candidate"
else
    fail "L-2c. abandoned session not surfaced — candidate='$CAND' list='$(printf '%s' "$LIST" | tr '\n' '|')'"
fi

# --- L-3: a genuine fork. `forkedFrom` rows are proof of descent, so `resume`
# inherits.
D3="l3donor-$$"; H3="l3heir-$$"
write_state_v1 "$D3" "$CWD_A" "$BRANCH_A" "$STEPS_INHERITABLE"
write_forked_transcript "$TDIR_A/$H3.jsonl" "$H3" "$D3"
O="$(resolve_donor "$H3" resume "$TDIR_A/$H3.jsonl" "$CWD_A" "$BRANCH_A")"
assert_kv "L-3a. resume + forkedFrom evidence inherits" "$O" decision inherited
assert_kv "L-3b. the donor is the forked-from session" "$O" donor "$D3"

# --- L-4: the other evidence shape. A compact carries the donor's announce
# line forward; the SSOT contract string must still be recognised verbatim.
D4="l4donor-$$"; H4="l4heir-$$"
write_state_v1 "$D4" "$CWD_A" "$BRANCH_A" "$STEPS_INHERITABLE"
write_announce_transcript "$TDIR_A/$H4.jsonl" "$D4" PostCompact
O="$(resolve_donor "$H4" compact "$TDIR_A/$H4.jsonl" "$CWD_A" "$BRANCH_A")"
assert_kv "L-4a. compact + copied announce line inherits" "$O" decision inherited
assert_kv "L-4b. the announce line identifies the donor" "$O" donor "$D4"

# --- L-5: cwd+branch is demoted to a GUARD, not deleted. Proven descent across
# a branch boundary is still refused — the completed steps described other code.
REPO_B="$(setup_repo b)"
CWD_B="$(resolve_path "$REPO_B")"
git -C "$REPO_B" checkout -q -b other-branch
BRANCH_B="$(git -C "$REPO_B" rev-parse --abbrev-ref HEAD)"
TDIR_B="$(transcript_dir "$CWD_B")"
D5="l5donor-$$"; H5="l5heir-$$"
write_state_v1 "$D5" "$CWD_B" "main" "$STEPS_INHERITABLE"
write_forked_transcript "$TDIR_B/$H5.jsonl" "$H5" "$D5"
O="$(resolve_donor "$H5" resume "$TDIR_B/$H5.jsonl" "$CWD_B" "$BRANCH_B")"
assert_kv "L-5a. lineage does not override a branch mismatch" "$O" decision context-mismatch
assert_kv "L-5b. context mismatch yields no donor" "$O" donor NONE

# --- L-6: S1 survives the rewrite. A session whose user_verification is
# complete is finished; its steps must not be resurrected.
D6="l6donor-$$"; H6="l6heir-$$"
write_state_v1 "$D6" "$CWD_A" "$BRANCH_A" "$STEPS_USER_VERIFIED"
write_forked_transcript "$TDIR_A/$H6.jsonl" "$H6" "$D6"
O="$(resolve_donor "$H6" resume "$TDIR_A/$H6.jsonl" "$CWD_A" "$BRANCH_A")"
assert_prefix "L-6a. a user-verified session is not resumable (S1)" "$O" decision not-resumable
assert_kv "L-6b. S1 yields no donor" "$O" donor NONE

# --- L-7: S2 is REMOVED. review_security=complete used to block inheritance;
# with proven descent it no longer does, because the same session is continuing.
D7="l7donor-$$"; H7="l7heir-$$"
write_state_v1 "$D7" "$CWD_A" "$BRANCH_A" "$STEPS_SECURITY_DONE"
write_forked_transcript "$TDIR_A/$H7.jsonl" "$H7" "$D7"
O="$(resolve_donor "$H7" resume "$TDIR_A/$H7.jsonl" "$CWD_A" "$BRANCH_A")"
assert_kv "L-7a. review_security=complete no longer blocks (S2 removed)" "$O" decision inherited
assert_kv "L-7b. the security-complete session is the donor" "$O" donor "$D7"

# --- L-8: S3 survives. clarify_intent genuinely recorded complete but the
# intent.md artifact is gone → the plan the steps rest on is unrecoverable.
D8="l8donor-$$"; H8="l8heir-$$"
write_state_v1 "$D8" "$CWD_A" "$BRANCH_A" "$STEPS_INTENT_DONE"
write_forked_transcript "$TDIR_A/$H8.jsonl" "$H8" "$D8"
O="$(resolve_donor "$H8" resume "$TDIR_A/$H8.jsonl" "$CWD_A" "$BRANCH_A")"
assert_prefix "L-8a. clarify_intent complete without intent.md is not resumable (S3)" "$O" decision not-resumable
# Positive control: restore the artifact and the same fixture must inherit —
# proves L-8a failed on the missing artifact, not on the fixture being broken.
printf 'intent placeholder\n' > "$PLANS_DIR/${D8}-intent.md"
O="$(resolve_donor "$H8" resume "$TDIR_A/$H8.jsonl" "$CWD_A" "$BRANCH_A")"
assert_kv "L-8b. positive control: with intent.md present the same donor inherits" "$O" decision inherited

# --- L-9: no transcript = no evidence. Fail closed rather than falling back to
# the old cwd+branch scan — that fallback IS the #1305 bug.
D9="l9donor-$$"; H9="l9heir-$$"
write_state_v1 "$D9" "$CWD_A" "$BRANCH_A" "$STEPS_INHERITABLE"
O="$(resolve_donor "$H9" resume "$TDIR_A/does-not-exist-$H9.jsonl" "$CWD_A" "$BRANCH_A")"
assert_kv "L-9a. a missing transcript file fails closed" "$O" decision unreadable-transcript
O="$(resolve_donor "$H9" resume NONE "$CWD_A" "$BRANCH_A")"
assert_kv "L-9b. an absent transcript_path fails closed too" "$O" decision unreadable-transcript
assert_kv "L-9c. neither shape produces a donor" "$O" donor NONE

# --- L-10: an unknown/absent `source` is treated as non-continuation. Older
# Claude Code builds omit the field; the safe default is to NOT inherit.
D10="l10donor-$$"; H10="l10heir-$$"
write_state_v1 "$D10" "$CWD_A" "$BRANCH_A" "$STEPS_INHERITABLE"
write_forked_transcript "$TDIR_A/$H10.jsonl" "$H10" "$D10"
O="$(resolve_donor "$H10" NONE "$TDIR_A/$H10.jsonl" "$CWD_A" "$BRANCH_A")"
assert_kv "L-10a. a missing source field does not inherit" "$O" decision source-gated
assert_kv "L-10b. a missing source field yields no donor" "$O" donor NONE

# --- L-11: gate A runs first. A subagent shares its parent's transcript and
# would otherwise satisfy every later gate — it must short-circuit immediately.
D11="l11donor-$$"; H11="l11heir-$$"
write_state_v1 "$D11" "$CWD_A" "$BRANCH_A" "$STEPS_INHERITABLE"
write_forked_transcript "$TDIR_A/$H11.jsonl" "$H11" "$D11"
O="$(resolve_donor "$H11" resume "$TDIR_A/$H11.jsonl" "$CWD_A" "$BRANCH_A" "agent-abc")"
assert_kv "L-11a. agent_id short-circuits ahead of the lineage gate" "$O" decision subagent
assert_kv "L-11b. a subagent never receives a donor" "$O" donor NONE
