# tests/bin/feature-2276-review-code-security-codex/ref-input-chain.sh
# Tests: bin/run-codex-review-loop, bin/lib/codex-review-loop/ref-kind-input.sh
# Tags: review-loop, security-code, ref-kind, anchored-parse, TL2, scope:issue-specific, issue-2344
#
# Sourced by tests/bin/feature-2276-review-code-security-codex.sh.
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

# ===========================================================================
# Group A: change-1 open-ledger prior injection at ROUND=1 (issue #2344)
# A1+A2: RED until change 1 ships. A3+A4: invariant (GREEN always).
# TL2 via run_loop_sc; --concerns-file presence inferred from CODEX_MOCK_PROMPT.
# # TL3 gap: real codex run confirms the full render-prior pipeline.
# ===========================================================================

echo ""
echo "--- A: change-1 open-ledger prior injection (issue #2344) ---"

# --- A1: ROUND=1 with open C1 → rk_build_args must inject --concerns-file --
# Seed run creates C1 open; reset counter; second run re-enters at ROUND=1.
# RED now (ROUND<2 guard); GREEN after change 1 (ledger-entry guard replaces it).
new_env
RL_CODEX_BODY="$PLANS/body-a1-seed.txt"
mk_body "$RL_CODEX_BODY" \
    "$(anchored HIGH C1 'reviewed.txt' 3 'unvalidated input' 'validate-a1-prior')"
run_loop_sc   # round 1 → C1 open, exit 1; round counter = 1

rm -f "$(round_file)"
RL_CODEX_BODY="$PLANS/body-a1-r2.txt"
mk_body "$RL_CODEX_BODY" \
    "$(anchored HIGH C1 'reviewed.txt' 3 'unvalidated input' 'validate-a1-r2')"
run_loop_sc   # ROUND=1 with existing open ledger

A1_PROMPT="$(cat "$PLANS/prompt.txt" 2>/dev/null || true)"
assert_contains \
    "A1: ROUND=1 with open ledger → --concerns-file passed ([PRIOR CONCERNS START] in prompt)" \
    "[PRIOR CONCERNS START]" "$A1_PROMPT"
assert_contains \
    "A1: prior concern text (validate-a1-prior) from seed round is in the injected block" \
    "validate-a1-prior" "$A1_PROMPT"

# --- A2: APPROVED + ROUND=1 + open C → NEEDS_LEDGER_PASS=1, ledger survives --
# After change 1: C row triggers NEEDS_LEDGER_PASS; provenance gate keeps C1
# open (scanner never staged) → HIGH_N=1 → exit 1 → ledger not deleted.
# RED now (ROUND<2 → else cleanup_ledger → exit 0, ledger deleted).
new_env
RL_CODEX_BODY="$PLANS/body-a2-seed.txt"
mk_body "$RL_CODEX_BODY" \
    "$(anchored HIGH C1 'reviewed.txt' 5 'sql injection' 'parameterize-a2')"
run_loop_sc   # round 1 → C1 open, exit 1

rm -f "$(round_file)"
RL_CODEX_BODY="$PLANS/body-a2-clean.txt"
mk_clean_body "$RL_CODEX_BODY"
run_loop_sc   # ROUND=1, open ledger, APPROVED verdict from codex

assert_eq \
    "A2: APPROVED at ROUND=1 with open C triggers ledger pass, open C1 persists, exit 1" \
    "1" "$LAST_RC"
assert_eq \
    "A2: ledger survives (else-branch cleanup_ledger not reached when NEEDS_LEDGER_PASS=1)" \
    "present" "$(file_state "$(ledger_file)")"

# --- A3: new ROUND=1 with no ledger → no --concerns-file (invariant) --------
# No C row → have_prior_entries=0 after change 1 (same path as old ROUND<2 guard).
new_env
RL_CODEX_BODY="$PLANS/body-a3.txt"
mk_clean_body "$RL_CODEX_BODY"
run_loop_sc

A3_PROMPT="$(cat "$PLANS/prompt.txt" 2>/dev/null || true)"
assert_not_contains \
    "A3: no --concerns-file when ledger is absent (fresh session)" \
    "[PRIOR CONCERNS START]" "$A3_PROMPT"
assert_contains \
    "A3: non-empty prompt guard (review actually ran)" \
    "Concern Delta" "$A3_PROMPT"
assert_eq "A3: clean ROUND=1 with no ledger approves, exits 0" "0" "$LAST_RC"
assert_eq "A3: no ledger after clean first round" "missing" "$(file_state "$(ledger_file)")"

# --- A4: ROUND=1 with resolved-only ledger → inner L44 guard, no --concerns-file
# After change 1 the outer guard enters (C row exists), but cl_render_prior
# returns empty for a resolved entry → inner [[ -n "$prior" ]] (L44) prevents
# --concerns-file. GREEN before and after change 1 (regression guard for L44).
new_env
A4_SLOT="$(run_cli slot --path 'reviewed.txt' --anchor 3 \
    --category 'unvalidated input' 2>/dev/null | tr -d '\r\n')"
A4_LEDGER="$(ledger_file)"
{
    printf '#concern-ledger-v2|review-security-shared|%s|cycle=1\n' "$SID"
    printf 'C1|HIGH|resolved|1|1|%s|discrim-a4|review-code-codex|review-code-codex|-|validate-a4-prior text\n' \
        "${A4_SLOT:-placeholder-slot}"
} > "$A4_LEDGER"

RL_CODEX_BODY="$PLANS/body-a4.txt"
mk_clean_body "$RL_CODEX_BODY"
run_loop_sc

A4_PROMPT="$(cat "$PLANS/prompt.txt" 2>/dev/null || true)"
assert_not_contains \
    "A4: resolved-only ledger → render-prior empty → inner L44 guard prevents --concerns-file" \
    "[PRIOR CONCERNS START]" "$A4_PROMPT"
assert_contains \
    "A4: non-empty prompt guard (review ran despite existing resolved-only ledger)" \
    "Concern Delta" "$A4_PROMPT"

# ===========================================================================
# Group C: the REAL /review-code-security wrapper end to end (issue #2344).
# Groups R/A drive bin/run-codex-review-loop directly; C is the only coverage of
# skills/review-code-security/scripts/run-codex-review-loop.sh — the terminal
# fingerprint guard + resolve-accepted-tradeoffs-file + loop + prior injection
# stitched together over a live git repo, with codex the sole mock. The seam:
# a terminal exit arms the guard; an unchanged tree stays blocked; a real edit
# flips the fingerprint, clears the guard, restarts at round 1, and the open
# ledger's prior concerns must reach the reviewer prompt.
# ===========================================================================
echo ""
echo "--- C: /review-code-security wrapper — terminal guard, fingerprint, prior injection ---"

WRAPPER="$AGENTS_ROOT/skills/review-code-security/scripts/run-codex-review-loop.sh"
[ -f "$WRAPPER" ] || fail "C: wrapper missing: skills/review-code-security/scripts/run-codex-review-loop.sh"

# The wrapper is env-driven (SESSION_ID/PLANS_DIR/EXTENSIONS_USED) and builds its
# own loop args; CTX_* are pinned empty so an inherited real-session var cannot
# leak a --context file into the isolated fixture.
run_wrapper_sc() {
    WRAP_OUT="$(cd "$RL_REPO" && PATH="$RL_PATH" \
        AGENTS_CONFIG_DIR="$AGENTS_ROOT" SESSION_ID="$SID" PLANS_DIR="$PLANS" \
        EXTENSIONS_USED="$RL_EXT_USED" \
        CTX_SURVEY_CODE="" CTX_SURVEY_HISTORY="" CTX_CONCERNS_LOG="" \
        CODEX_MOCK_BODY="$RL_CODEX_BODY" CODEX_MOCK_EXIT="$RL_CODEX_EXIT" \
        CODEX_MOCK_PROMPT="$PLANS/prompt.txt" \
        bash "$WRAPPER" "$@" 2>&1)"
    WRAP_RC=$?
}
term_file() { printf '%s/%s-security-code-terminal.txt' "$PLANS" "$SID"; }

# --- C1: never-armed wrapper runs the loop (positive control, invariant) -----
new_env
printf 'none\n' > "$PLANS/$SID-detail.md"   # resolve-accepted-tradeoffs-file source
RL_CODEX_BODY="$PLANS/body-c1.txt"; mk_clean_body "$RL_CODEX_BODY"
run_wrapper_sc
assert_eq "C1: no terminal guard file → wrapper is not the re-invoke exit 8" \
    "not-8" "$(if [ "$WRAP_RC" -eq 8 ]; then printf '8'; else printf 'not-8'; fi)"
assert_contains "C1: the wrapper actually reached the reviewer (prompt written)" \
    "Concern Delta" "$(cat "$PLANS/prompt.txt" 2>/dev/null || true)"

# --- C2: armed guard + uncomparable fingerprint fails CLOSED (exit 8) --------
# PREV_FP empty (line 2 blank) → the guard cannot prove the tree changed, so it
# stays armed and blocks. Robust: needs no real fingerprint value.
new_env
printf 'none\n' > "$PLANS/$SID-detail.md"
printf '6\n\n' > "$(term_file)"
RL_CODEX_BODY="$PLANS/body-c2.txt"; mk_clean_body "$RL_CODEX_BODY"
run_wrapper_sc
assert_eq "C2: armed guard + uncomparable fingerprint → re-invoke exit 8" "8" "$WRAP_RC"
assert_contains "C2: the block explains a prior terminal exit armed the guard" \
    "terminal exit" "$WRAP_OUT"
assert_eq "C2: a blocked re-invoke leaves the guard file armed" "present" \
    "$(file_state "$(term_file)")"

# --- C3: fingerprint MISMATCH clears the guard, restarts round 1, injects prior
# A stale seeded fingerprint can never match the live tree, so the guard clears
# without replicating the wrapper's hash pipeline. An open ledger is pre-seeded;
# the reviewer prompt must then carry the prior concern.
new_env
printf 'none\n' > "$PLANS/$SID-detail.md"
printf '6\nstale-fingerprint-never-matches-live-tree\n' > "$(term_file)"

C3_SLOT="$(run_cli slot --path 'reviewed.txt' --anchor 3 \
    --category 'unvalidated input' 2>/dev/null | tr -d '\r\n')"
{
    printf '#concern-ledger-v2|%s|%s|cycle=1\n' "$LEDGER_FORMAT" "$SID"
    printf 'C1|HIGH|open|1|1|%s|discrim-c3|review-code-codex|review-code-codex|-|validate-c3-prior text\n' \
        "${C3_SLOT:-placeholder-slot}"
} > "$(ledger_file)"

RL_CODEX_BODY="$PLANS/body-c3.txt"; mk_clean_body "$RL_CODEX_BODY"
run_wrapper_sc

assert_eq "C3: fingerprint mismatch → guard clears, not the re-invoke exit 8" \
    "not-8" "$(if [ "$WRAP_RC" -eq 8 ]; then printf '8'; else printf 'not-8'; fi)"
assert_eq "C3: the stale guard file is auto-cleared on a real edit" "missing" \
    "$(file_state "$(term_file)")"
assert_contains "C3: the loop restarted and reached the reviewer at round 1" \
    "Concern Delta" "$(cat "$PLANS/prompt.txt" 2>/dev/null || true)"
# RED until change 1: ROUND=1 with an open ledger must inject prior concerns.
assert_contains "C3: prior open concern injected on restart (RED until change 1)" \
    "[PRIOR CONCERNS START]" "$(cat "$PLANS/prompt.txt" 2>/dev/null || true)"
assert_contains "C3: the prior concern's text reaches the prompt (RED until change 1)" \
    "validate-c3-prior" "$(cat "$PLANS/prompt.txt" 2>/dev/null || true)"
