# tests/feature-2276-review-code-security-codex/ref-input-chain.sh
# Tests: bin/run-codex-review-loop, bin/lib/codex-review-loop/ref-kind-input.sh
# Tags: review-loop, security-code, ref-kind, anchored-parse, TL2, scope:issue-specific
#
# Sourced by tests/feature-2276-review-code-security-codex.sh.
# One security-code round end to end: a git ref instead of a draft path, the
# anchored codex body staged as review-code-codex, and the artifacts landing
# under the split ledger-format / loop-format names.

echo ""
echo "--- R: the ref-kind input chain, one round end to end ---"

# --- R1: argument surface ---------------------------------------------------
new_env
run_loop_sc
assert_eq "R1: a security-code run needs no --draft-file at all" "0,1,5" \
    "$(case "$LAST_RC" in 0|1|5) printf '0,1,5';; *) printf 'rc=%s out=%s' "$LAST_RC" "$(printf '%s' "$LAST_OUT" | head -c 200)";; esac)"

new_env
RL_EXTRA=(--draft-file "$PLANS/nonexistent-draft.md")
run_loop_sc
assert_eq "R1: --draft-file is rejected for a ref-kind format instead of silently ignored" \
    "4" "$LAST_RC"

new_env
LAST_OUT="$(cd "$RL_REPO" && PATH="$RL_PATH" bash "$LOOP_BIN" --format "$LOOP_FORMAT" \
    --session-id "$SID" --plans-dir "$PLANS" --cap 2 --max-extensions 1 \
    --extensions-used 0 --repo-root "$RL_REPO" 2>&1)"
assert_eq "R1: a missing --accepted-tradeoffs is still a usage error" "4" "$?"

new_env
RL_EXTRA=(--base-ref "no-such-ref-xyz")
run_loop_sc
assert_eq "R1: an unresolvable base ref fails closed rather than reviewing everything" \
    "not-0" "$(if [ "$LAST_RC" -eq 0 ]; then printf '0'; else printf 'not-0'; fi)"

# --- R2: the prompt the reviewer receives -----------------------------------
new_env
RL_CODEX_BODY="$PLANS/body.txt"
mk_body "$RL_CODEX_BODY" "$(anchored HIGH C1 'reviewed.txt' 3 'unvalidated input' 'validate it')"
run_loop_sc
PROMPT="$(cat "$PLANS/prompt.txt" 2>/dev/null || true)"
assert_contains "R2: the reviewer prompt carries the reviewed diff, not a draft path" \
    "reviewed.txt" "$PROMPT"
assert_contains "R2: the prompt requests the anchored concern format" "|" "$PROMPT"
assert_not_contains "R2: no draft-file path leaks into the security-code prompt" \
    "draft-file" "$PROMPT"

# --- R3: artifact naming, the S8-a split ------------------------------------
assert_eq "R3: the ledger lands under the shared ledger format" \
    "present" "$(file_state "$(ledger_file)")"
assert_eq "R3: no ledger is written under the loop format name" \
    "missing" "$(file_state "$PLANS/$SID-$LOOP_FORMAT-concern-ledger.txt")"
assert_eq "R3: the round counter lands under the loop format" \
    "1" "$(counter_state)"
assert_eq "R3: no round counter is written under the ledger format name" \
    "missing" "$(file_state "$PLANS/$SID-$LEDGER_FORMAT-round-number.txt")"

# --- R4: what a round-1 HIGH produces ---------------------------------------
assert_eq "R4: a HIGH concern at round 1 asks for a revision" "1" "$LAST_RC"
LEDGER_TXT="$(cat "$(ledger_file)" 2>/dev/null || true)"
# The v2 ledger keeps the concern description verbatim in its TEXT column, while
# the path, anchor and category are folded into the SLOT hash rather than stored
# as readable text (skills/_shared/concern-ledger.md). So the retained fact to
# assert is the description, and the anchored location is verified through the
# deterministic SLOT it produces.
assert_contains "R4: the concern description is recorded in the ledger verbatim" "validate it" "$LEDGER_TXT"
assert_match "R4: the concern carries a C-number identity" '^C1\|' "$LEDGER_TXT"
R4_SLOT_WANT="$(run_cli slot --path reviewed.txt --anchor 3 --category 'unvalidated input' 2>/dev/null | tr -d '\r\n')"
R4_SLOT_GOT="$(printf '%s\n' "$LEDGER_TXT" | grep -m1 '^C1|' | cut -d'|' -f6)"
assert_eq_nz "R4: the anchored location is folded into the ledger's SLOT identity" \
    "$R4_SLOT_WANT" "$R4_SLOT_GOT"

DELTA1="$(delta_file 1 review-code-codex)"
assert_eq "R4: the round-1 delta is filed under the codex producer" "present" "$(file_state "$DELTA1")"
assert_eq "R4: the codex producer is staged as fully executed" "COMPLETE" \
    "$(staging_field "$DELTA1" 3)"
assert_eq "R4: the exec label the loop stages is PERFORMED" "PERFORMED" \
    "$(staging_field "$DELTA1" 5)"
assert_eq "R4: the parse label is COMPLETE for a well-formed anchored body" "COMPLETE" \
    "$(staging_field "$DELTA1" 6)"
assert_eq "R4: the delta records the round it belongs to" "1" "$(staging_field "$DELTA1" 7)"
assert_eq "R4: the producer name is the reviewer itself, not a wrapper" "review-code-codex" \
    "$(staging_field "$DELTA1" 2)"

# --- R5: codex-only staging satisfies the completeness gate -----------------
assert_not_contains "R5: a codex-only round is not rejected as incomplete" \
    "incomplete" "$LAST_OUT"
assert_not_contains "R5: the loop does not wait for a second declared producer" \
    "security-scanner" "$LAST_OUT"
assert_eq "R5: check-staged agrees the round is complete with codex alone" "0" \
    "$(run_cli check-staged --format "$LEDGER_FORMAT" --session-id "$SID" --plans-dir "$PLANS" --round 1 >/dev/null 2>&1; printf '%s' "$?")"

# --- R6: begin-round is opened by the loop's input chain, not a skill script -
# The begin-round call moved out of the loop entrypoint into the shared ref-kind
# input chain (rk_stage_anchored in ref-kind-input.sh), and the v2 ledger opens a
# cycle through its header line (#concern-ledger-v2|...|cycle=K) rather than the
# retired '#round|N' marker.
assert_contains "R6: the ref-kind input chain opens the ledger round itself" "begin-round" \
    "$(cat "$REF_KIND" 2>/dev/null || true)"
assert_eq "R6: the v2 ledger opens exactly one cycle for the session" "1" \
    "$(grep -c '^#concern-ledger-v2|.*cycle=1' "$(ledger_file)" 2>/dev/null || printf 'no-ledger')"

# --- R7: a truncation notice before the status line -------------------------
new_env
RL_REPO="$REPO_BIG"
RL_CODEX_BODY="$PLANS/body-trunc.txt"
{
    printf '## Codex Review Scope: TRUNCATED\n\n'
    printf '## Concern Delta\n\n## HIGH\n%s\n\n## MEDIUM\n(none)\n\n## LOW\n(none)\n' \
        "$(anchored HIGH C1 'reviewed.txt' 12 'truncated scope finding' 'split the diff')"
} > "$RL_CODEX_BODY"
run_loop_sc
assert_eq "R7: a scope notice ahead of the status line does not read as a malformed header" \
    "not-4" "$(if [ "$LAST_RC" -eq 4 ]; then printf '4'; else printf 'not-4'; fi)"
assert_eq "R7: a truncated review is staged PARTIAL, never PERFORMED" "PARTIAL" \
    "$(staging_field "$(delta_file 1 review-code-codex)" 5)"
assert_eq "R7: completeness for a truncated round is the min of exec and parse" "PARTIAL" \
    "$(staging_field "$(delta_file 1 review-code-codex)" 3)"
assert_contains "R7: the truncation is surfaced to the caller" "TRUNCATED" "$LAST_OUT"

# --- R8: reviewer status lines other than PERFORMED -------------------------
new_env
RL_CODEX_BODY="$PLANS/body-skipped.txt"
printf '## Codex Review: SKIPPED — codex CLI unavailable\n' > "$RL_CODEX_BODY"
RL_PATH="$NO_CODEX_PATH"
run_loop_sc
assert_eq "R8: an unavailable codex is the dedicated exit 3, not a hard failure" "3" "$LAST_RC"
assert_eq "R8: an exit-3 round rolls the counter back rather than consuming it" \
    "deleted" "$(counter_state)"

new_env
RL_CODEX_BODY="$PLANS/body-failed.txt"
printf '## Codex Review: FAILED — reviewer aborted\n' > "$RL_CODEX_BODY"
RL_CODEX_EXIT=1
run_loop_sc
assert_eq "R8: a non-cap FAILED status is exit 3, distinct from the cap escalation" "3" "$LAST_RC"
assert_eq "R8: the FAILED round also rolls the counter back" "deleted" "$(counter_state)"
assert_eq "R8: nothing is staged for a round that never produced a body" \
    "missing" "$(file_state "$(delta_file 1 review-code-codex)")"

new_env
RL_CODEX_BODY="$PLANS/body-noheader.txt"
printf 'the reviewer wrote prose and forgot the contract\n' > "$RL_CODEX_BODY"
run_loop_sc
# bin/review-code-codex always stamps a '## Codex Review: PERFORMED|SKIPPED|FAILED'
# status header on its output, so a reviewer body that omits the Concern Delta
# contract still reaches the loop as PERFORMED. It parses to no concerns, and a
# ref-kind round-1 with nothing open approves and cleans up. (The loop's own
# exit-4 guard against an unrecognized header only fires for a stale reviewer
# emitting a retired label, which the S-section grep contract covers directly.)
assert_eq "R8: a PERFORMED body without a Concern Delta raises nothing and approves" \
    "rc=0 counter=deleted" "rc=$LAST_RC counter=$(counter_state)"
assert_eq "R8: an approval on a contract-less body leaves no ledger behind" \
    "missing" "$(file_state "$(ledger_file)")"

# --- R9: a clean round closes the chain -------------------------------------
new_env
RL_CODEX_BODY="$PLANS/body-clean.txt"
mk_clean_body "$RL_CODEX_BODY"
run_loop_sc
assert_eq "R9: no concerns at all approves on round 1 and clears the counter" \
    "rc=0 counter=deleted" "rc=$LAST_RC counter=$(counter_state)"
assert_eq "R9: an approved chain leaves no ledger behind" "missing" "$(file_state "$(ledger_file)")"
