# shellcheck shell=bash
# L-12 .. L-19 — ancestor-chain walking (gate D) and the two-context guard
# (gate E). Sourced by tests/feature-1305-inheritance-lineage.sh.

echo ""
echo "=== #1305 L-12..L-19: ancestor chain + context guard ==="

# chain <heir> <mid> <root> — heir forked from mid, mid forked from root.
chain() {
    write_forked_transcript "$TDIR_A/$1.jsonl" "$1" "$2"
    write_forked_transcript "$TDIR_A/$2.jsonl" "$2" "$3"
}

# --- L-12: the NEAREST ancestor holding a state file is the SOLE decision-maker.
# When it is not resumable the search STOPS. Walking past it to a healthier
# grandparent would resurrect steps the intervening session already superseded.
R12="l12root-$$"; M12="l12mid-$$"; H12="l12heir-$$"
write_state_v1 "$R12" "$CWD_A" "$BRANCH_A" "$STEPS_INHERITABLE"
write_state_v1 "$M12" "$CWD_A" "$BRANCH_A" "$STEPS_USER_VERIFIED"
chain "$H12" "$M12" "$R12"
O="$(resolve_donor "$H12" resume "$TDIR_A/$H12.jsonl" "$CWD_A" "$BRANCH_A")"
assert_prefix "L-12a. a non-resumable nearest ancestor ends the search" "$O" decision not-resumable
assert_kv "L-12b. no donor is produced" "$O" donor NONE
assert_ne "L-12c. the search does NOT fall through to the grandparent" "$O" donor "$R12"
assert_kv "L-12d. the decision is attributed to the nearest ancestor" "$O" candidate "$M12"

# --- L-13: inheritance is a READ of the donor. The donor's state file belongs
# to a session that may still be alive; copying must never write back into it.
D13="l13donor-$$"; H13="l13heir-$$"
write_state_v1 "$D13" "$CWD_A" "$BRANCH_A" "$STEPS_INHERITABLE"
write_forked_transcript "$TDIR_A/$H13.jsonl" "$H13" "$D13"
BEFORE_13="$(cksum < "$WORKFLOW_DIR/$D13.json")"
O="$(resolve_donor "$H13" resume "$TDIR_A/$H13.jsonl" "$CWD_A" "$BRANCH_A")"
AFTER_13="$(cksum < "$WORKFLOW_DIR/$D13.json")"
assert_kv "L-13a. precondition: this fixture does inherit" "$O" decision inherited
if [ "$(get_kv "$O" decision)" = "MISSING_KEY" ]; then
    fail "L-13b. donor immutability unproven — resolution did not run at all"
elif [ "$BEFORE_13" = "$AFTER_13" ]; then
    pass "L-13b. donor state file is untouched by donor resolution"
else
    fail "L-13b. donor state file was mutated: '$BEFORE_13' -> '$AFTER_13'"
fi

# --- L-14: same stopping rule, different reason. An all-pending nearest
# ancestor is a fresh session with nothing to give — that is still an answer,
# not a reason to keep climbing.
R14="l14root-$$"; M14="l14mid-$$"; H14="l14heir-$$"
write_state_v1 "$R14" "$CWD_A" "$BRANCH_A" "$STEPS_INHERITABLE"
write_state_v1 "$M14" "$CWD_A" "$BRANCH_A" "$STEPS_ALL_PENDING"
chain "$H14" "$M14" "$R14"
O="$(resolve_donor "$H14" resume "$TDIR_A/$H14.jsonl" "$CWD_A" "$BRANCH_A")"
assert_prefix "L-14a. an all-pending nearest ancestor is not resumable (S0)" "$O" decision not-resumable
assert_ne "L-14b. the all-pending ancestor does not unlock the grandparent" "$O" donor "$R14"
assert_kv "L-14c. no donor" "$O" donor NONE

# --- L-15: the walk skips ancestors with NO state file at all. Those sessions
# never recorded anything, so they are not decision-makers — only *state* makes
# an ancestor authoritative.
R15="l15root-$$"; M15="l15mid-$$"; H15="l15heir-$$"
write_state_v1 "$R15" "$CWD_A" "$BRANCH_A" "$STEPS_INHERITABLE"
chain "$H15" "$M15" "$R15"
O="$(resolve_donor "$H15" resume "$TDIR_A/$H15.jsonl" "$CWD_A" "$BRANCH_A")"
assert_kv "L-15a. a stateless ancestor is skipped, not treated as a verdict" "$O" decision inherited
assert_kv "L-15b. the grandparent that HAS state becomes the donor" "$O" donor "$R15"

# --- L-16..L-18: a donor that moved (worktree entered) has TWO contexts. The
# heir matches if it matches EITHER pair — but the pairs must not be crossed.
REPO_C="$(setup_repo c)"; REPO_D="$(setup_repo d)"
CWD_C="$(resolve_path "$REPO_C")"; CWD_D="$(resolve_path "$REPO_D")"
TDIR_C="$(transcript_dir "$CWD_C")"; TDIR_D="$(transcript_dir "$CWD_D")"

# --- L-16: heir sits where the donor ENDED UP (the worktree it entered).
D16="l16donor-$$"; H16="l16heir-$$"
write_state_v2_worktree "$D16" "$CWD_C" "main" "$CWD_D" "feat/x"
write_forked_transcript "$TDIR_D/$H16.jsonl" "$H16" "$D16"
O="$(resolve_donor "$H16" resume "$TDIR_D/$H16.jsonl" "$CWD_D" "feat/x")"
assert_kv "L-16a. heir matching the donor's CURRENT context inherits" "$O" decision inherited
assert_kv "L-16b. donor is the relocated session" "$O" donor "$D16"

# --- L-17: heir sits where the donor STARTED (it never followed the move).
D17="l17donor-$$"; H17="l17heir-$$"
write_state_v2_worktree "$D17" "$CWD_C" "main" "$CWD_D" "feat/x"
write_forked_transcript "$TDIR_C/$H17.jsonl" "$H17" "$D17"
O="$(resolve_donor "$H17" resume "$TDIR_C/$H17.jsonl" "$CWD_C" "main")"
assert_kv "L-17a. heir matching the donor's START context inherits" "$O" decision inherited
assert_kv "L-17b. donor is the same relocated session" "$O" donor "$D17"

# --- L-18: the guard is per-PAIR, not per-field. Taking cwd from one context
# and branch from the other describes a place the donor never was.
D18="l18donor-$$"; H18="l18heir-$$"
write_state_v2_worktree "$D18" "$CWD_C" "main" "$CWD_D" "feat/x"
write_forked_transcript "$TDIR_D/$H18.jsonl" "$H18" "$D18"
O="$(resolve_donor "$H18" resume "$TDIR_D/$H18.jsonl" "$CWD_D" "main")"
assert_kv "L-18a. a cross-paired cwd/branch is a mismatch, not a match" "$O" decision context-mismatch
assert_kv "L-18b. cross-pairing yields no donor" "$O" donor NONE

# --- L-19 (added: edge cases of the lineage READER itself, which every gate
# above depends on but none isolates — a reader that silently returns [] would
# make L-1/L-9/L-10 pass for the wrong reason).
H19="l19heir-$$"; A19="l19a-$$"; B19="l19b-$$"
{
    printf '{"type":"user","uuid":"a","sessionId":"%s","forkedFrom":{"sessionId":"%s","messageUuid":"m1"}}\n' "$H19" "$A19"
    printf '{"type":"user","uuid":"b","sessionId":"%s","forkedFrom":{"sessionId":"%s","messageUuid":"m2"}}\n' "$H19" "$A19"
    printf '{"type":"attachment","attachment":{"hookEvent":"SessionStart","exitCode":0,"stdout":"Current workflow session_id: %s"}}\n' "$B19"
    printf '{"type":"attachment","attachment":{"hookEvent":"SessionStart","exitCode":0,"stdout":"Current workflow session_id: %s"}}\n' "$H19"
    printf 'not json at all\n'
} > "$TDIR_A/$H19.jsonl"
O="$(read_lineage "$TDIR_A/$H19.jsonl")"
assert_kv "L-19a. a readable transcript reports readable=true" "$O" readable true
assert_kv "L-19b. ancestors are de-duplicated, self-excluded, nearest-first" "$O" ancestors "$A19,$B19"
: > "$TDIR_A/empty-$H19.jsonl"
O="$(read_lineage "$TDIR_A/empty-$H19.jsonl")"
assert_kv "L-19c. an EMPTY transcript is readable (distinct from unreadable)" "$O" readable true
assert_kv "L-19d. an empty transcript has no ancestors" "$O" ancestors ""
