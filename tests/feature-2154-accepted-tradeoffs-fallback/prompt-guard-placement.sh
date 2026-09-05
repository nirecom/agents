# Tests: bin/review-plan-codex
# Tags: codex, review, prompt-assembly, settled-decisions, guard-sentence, scope:issue-specific
# MOCK LAYER B, case 15 — PLACEMENT SENSITIVITY of the #2154 guard sentence.
# The guard counts a deferral only "inside the SETTLED DECISIONS block above";
# "anywhere else in the context suppresses nothing". Cases 8a-8c pin that the
# sentence REACHES codex; nothing pinned that the assembler puts the two channels
# where that sentence's own logic needs them. Case 15 drives the SAME marker text
# through both channels and pins where each lands.
# Split per rules/coding/file-split.md (Pattern A) from layer-b-prompt.sh, sourced
# FIRST, which owns run_rpc / assert_in_prompt / prompt_* and the LB_* fixtures.
echo "=== Layer B: guard-sentence placement sensitivity (case 15) ==="

# Sourced by tests/feature-2154-accepted-tradeoffs-fallback.sh.
# TL3 gap: the codex CLI is mocked, so whether a real model honours the in-block
# deferral and ignores the out-of-block one is never observed — only that the
# assembler places the bytes where the sentence's logic depends on them being
# placed. Mitigation: operational observation after merge, per the dispatcher.

# The guard sentence's two load-bearing clauses, verbatim from bin/review-plan-codex.
PG_GUARD_IN='and that documentation stands inside the SETTLED DECISIONS block above'
PG_GUARD_OUT='A deferral appearing anywhere else in the context suppresses nothing.'

# ONE marker text, driven through both channels — that identity is the point: a
# difference in the assertions can only come from PLACEMENT.
PG_MARKER='PG_DEFERRAL_2154_QZWX: Error-path coverage is delegated to manual verification.'
# A second, always-in-block line so the settled block is non-empty in BOTH cases;
# without it the out-of-block run could pass with no block rendered at all.
PG_ANCHOR='PG_ANCHOR_2154_QZWX: class member review-tests — triage: MUST'

# Whole-line delimiter lookups: the prompt's own prose names delimiter pairs in
# running text, and a substring count would score that prose as structure.
pg_lines() { grep -nxF -- "$1" "$PROMPT_CAPTURE" 2>/dev/null | cut -d: -f1; }
# Every line the phrase occurs on — the out-of-block row must judge ALL of them,
# or a second in-block copy would go unnoticed.
pg_hits() { grep -nF -- "$1" "$PROMPT_CAPTURE" 2>/dev/null | cut -d: -f1; }

PG_CTX_BENIGN="$TMPROOT/pg-context-benign.md"
printf '## Test Case Categories\n\n- Normal cases\n- Error cases\n' > "$PG_CTX_BENIGN"

# pg_build_detail <path> <tradeoff-line> — a plan file whose `## Accepted
# Tradeoffs` section carries exactly the given line.
pg_build_detail() {
  {
    printf '# Detail plan\n\n'
    printf '## Accepted Tradeoffs\n\n'
    printf -- '- %s\n\n' "$2"
    printf '## Class members\n\n- %s\n' "$PG_ANCHOR"
  } > "$1"
}

# pg_run <detail-file> <context-file> — one test-review round through run_rpc,
# restoring the shared LB_* fixtures the sibling case files also read.
pg_run() {
  local sd="$LB_DETAIL" si="$LB_INPUT" sc="$LB_CONTEXT"
  LB_DETAIL="$1"; LB_CONTEXT="$2"
  run_rpc test-review
  LB_DETAIL="$sd"; LB_INPUT="$si"; LB_CONTEXT="$sc"
}

# --- Case 15A: the deferral is written INSIDE `## Accepted Tradeoffs`.
PG_DETAIL_IN="$TMPROOT/pg-detail-in-block.md"
pg_build_detail "$PG_DETAIL_IN" "$PG_MARKER"
pg_run "$PG_DETAIL_IN" "$PG_CTX_BENIGN"

# 15a — the guard sentence reaches the prompt at all. Every row below reads its
# position, so an absent sentence must fail here and name itself.
assert_in_prompt "15a: the guard sentence's in-block clause reaches the test-review prompt" "$PG_GUARD_IN"
assert_in_prompt "15a2: the guard sentence's out-of-block clause reaches the test-review prompt" "$PG_GUARD_OUT"

PG_START="$(pg_lines '[ACCEPTED TRADEOFFS START]' | head -1)"
PG_END="$(pg_lines '[ACCEPTED TRADEOFFS END]' | tail -1)"
PG_GUARD_LINE="$(prompt_first_line "$PG_GUARD_IN")"

# 15b — the block frame is real and non-degenerate. 15c/15d/15f all judge against
# this window; an unlocatable or empty window would make them vacuous.
if [[ -z "$PG_START" || -z "$PG_END" ]]; then
  fail "15b: the SETTLED DECISIONS block delimiters are not both present in the captured prompt (start=[$PG_START] end=[$PG_END])"
elif [[ $((PG_END - PG_START)) -ge 2 ]]; then
  pass "15b: the settled-decisions block spans lines $PG_START..$PG_END with content between the delimiters"
else
  fail "15b: the settled-decisions block is degenerate — nothing sits between its delimiters (start=$PG_START end=$PG_END)"
fi

# 15c — the deferral written inside `## Accepted Tradeoffs` lands inside the
# authoritative block: the placement the guard calls "the only place such a
# decision counts".
PG_MARKER_LINE="$(prompt_first_line "$PG_MARKER")"
if [[ -z "$PG_MARKER_LINE" || -z "$PG_START" || -z "$PG_END" ]]; then
  fail "15c: the in-block deferral or the block window is unlocatable (marker=[$PG_MARKER_LINE] window=[$PG_START..$PG_END])"
elif [[ "$PG_MARKER_LINE" -gt "$PG_START" && "$PG_MARKER_LINE" -lt "$PG_END" ]]; then
  pass "15c: the in-block deferral lands inside the settled-decisions block (line $PG_MARKER_LINE in $PG_START..$PG_END)"
else
  fail "15c: the in-block deferral did NOT land inside the settled-decisions block (line $PG_MARKER_LINE, block $PG_START..$PG_END)"
fi

# 15d — the guard sentence stands AFTER the block it calls "above". The wording is
# a positional reference: emit the instructions first and the sentence points at
# nothing. It is prompt instruction text, not promoted plan content, so being
# OUTSIDE the block is correct — its contract is to FOLLOW the block.
if [[ -z "$PG_GUARD_LINE" || -z "$PG_END" ]]; then
  fail "15d: the guard sentence or the block end is unlocatable (guard=[$PG_GUARD_LINE] end=[$PG_END])"
elif [[ "$PG_GUARD_LINE" -gt "$PG_END" ]]; then
  pass "15d: the guard sentence follows the block it calls 'above' (line $PG_GUARD_LINE > $PG_END)"
else
  fail "15d: the guard sentence precedes the block it calls 'above' — the reference is broken (guard line $PG_GUARD_LINE, block end $PG_END)"
fi

# --- Case 15B: the IDENTICAL deferral text, written only in ordinary context.
# The plan file keeps a different, benign tradeoff so the block still renders.
PG_DETAIL_OUT="$TMPROOT/pg-detail-out-of-block.md"
pg_build_detail "$PG_DETAIL_OUT" 'PG_BENIGN_2154_QZWX: log format is settled.'
PG_CTX_MARKED="$TMPROOT/pg-context-marked.md"
{
  printf '## Test Case Categories\n\n- Normal cases\n- Error cases\n\n'
  printf '## Notes\n\n- %s\n' "$PG_MARKER"
} > "$PG_CTX_MARKED"
pg_run "$PG_DETAIL_OUT" "$PG_CTX_MARKED"

PG_START2="$(pg_lines '[ACCEPTED TRADEOFFS START]' | head -1)"
PG_END2="$(pg_lines '[ACCEPTED TRADEOFFS END]' | tail -1)"

# 15e — anti-vacuity, two ways. The marker must still REACH codex (absence would
# satisfy 15f for the wrong reason), and the settled block must still be rendered
# and populated (an unrendered block makes "outside it" trivially true).
assert_in_prompt "15e: the out-of-block deferral still reaches the prompt (15f is not vacuous)" "$PG_MARKER"
assert_in_prompt "15e2: the settled-decisions block is still populated in the out-of-block run" "$PG_ANCHOR"

# 15f — PLACEMENT SENSITIVITY, the case's whole point: the same bytes that landed
# inside the block in 15c must now land outside it, at EVERY occurrence. The
# per-occurrence check is what rules out the assembler ALSO promoting context text
# into the authoritative block.
PG_OUT_HITS="$(pg_hits "$PG_MARKER")"
if [[ -z "$PG_OUT_HITS" || -z "$PG_START2" || -z "$PG_END2" ]]; then
  fail "15f: the out-of-block deferral or the block window is unlocatable (hits=[$PG_OUT_HITS] window=[$PG_START2..$PG_END2])"
else
  pg_inside=""
  for pg_ln in $PG_OUT_HITS; do
    if [[ "$pg_ln" -gt "$PG_START2" && "$pg_ln" -lt "$PG_END2" ]]; then pg_inside="$pg_inside $pg_ln"; fi
  done
  if [[ -z "$pg_inside" ]]; then
    pass "15f: every occurrence of the context-channel deferral stays OUTSIDE the settled block (lines$(printf ' %s' $PG_OUT_HITS) vs block $PG_START2..$PG_END2)"
  else
    fail "15f: a context-channel deferral was promoted INTO the settled block (line(s)$pg_inside, block $PG_START2..$PG_END2) — the guard's 'suppresses nothing' clause would be void"
  fi
fi

# 15g — the guard sentence is emitted once per prompt in this run too, so 15d's
# first-occurrence lookup names the only copy there is.
assert_eq "15g: the guard sentence's in-block clause appears exactly once" \
  "1" "$(prompt_count "$PG_GUARD_IN")"

# --- Cases 15C/15D (C2): sub-section attribution INSIDE the settled block. 15A/15B
# split the world at the block boundary, but both of the block's own sub-sections sit
# on the same side of it, and they are not interchangeable: `## Accepted Tradeoffs`
# records settled design decisions, `## Class members` is a CPR-E2C roster carrying
# triage. Deferral-shaped text in the roster is not a deferral record — so if
# assembly erased the boundary, a consumer keying suppression on Accepted Tradeoffs
# would suppress a genuinely open category. These rows pin that the boundary
# survives: both headers render, uniquely and in order, so every promoted line is
# attributable to exactly one sub-section by position.
PG_SUBSEC_MARKER='PG_SUBSEC_2154_QZWX: Idempotency cases are delegated to manual verification.'
# The category that must stay OPEN: named in the checklist, deferred by nothing in
# the Accepted Tradeoffs sub-section.
PG_OPEN_CAT='PG_OPEN_CATEGORY_2154_QZWX (Idempotency cases)'
PG_AT_HDR='## Accepted Tradeoffs'
PG_CM_HDR='## Class members'

PG_CTX_CAT="$TMPROOT/pg-context-categories.md"
{
  printf '## Test Case Categories\n\n- Normal cases\n- Error cases\n'
  printf -- '- %s\n' "$PG_OPEN_CAT"
} > "$PG_CTX_CAT"

# pg_build_subsec <path> <accepted-tradeoffs-line> <class-members-line> — the same
# two-sub-section shape as pg_build_detail, with each sub-section's body given
# separately so 15C and 15D differ ONLY in which sub-section carries the marker.
pg_build_subsec() {
  {
    printf '# Detail plan\n\n'
    printf '%s\n\n' "$PG_AT_HDR"
    printf -- '- %s\n\n' "$2"
    printf '%s\n\n' "$PG_CM_HDR"
    printf -- '- %s\n' "$PG_ANCHOR"
    printf -- '- %s\n' "$3"
  } > "$1"
}

# pg_subsec_frame — locates the block window and both sub-section headers in the
# current capture: PG_SS_START/_END/_AT/_CM (empty when unlocatable) plus the
# whole-line occurrence counts PG_SS_AT_N / PG_SS_CM_N.
pg_subsec_frame() {
  PG_SS_START="$(pg_lines '[ACCEPTED TRADEOFFS START]' | head -1)"
  PG_SS_END="$(pg_lines '[ACCEPTED TRADEOFFS END]' | tail -1)"
  PG_SS_AT="$(pg_lines "$PG_AT_HDR" | head -1)"
  PG_SS_CM="$(pg_lines "$PG_CM_HDR" | head -1)"
  PG_SS_AT_N="$(prompt_count_line "$PG_AT_HDR")"
  PG_SS_CM_N="$(prompt_count_line "$PG_CM_HDR")"
}

# pg_hits_between <phrase> <lo> <hi> — the phrase's occurrence lines strictly inside
# (lo, hi), space-separated; empty when none.
pg_hits_between() {
  local phrase="$1" lo="$2" hi="$3" ln out=""
  for ln in $(pg_hits "$phrase"); do
    if [[ "$ln" -gt "$lo" && "$ln" -lt "$hi" ]]; then out="$out $ln"; fi
  done
  printf '%s' "$out"
}

# --- Case 15C: the deferral is written under `## Accepted Tradeoffs`.
PG_DETAIL_AT="$TMPROOT/pg-detail-subsec-at.md"
pg_build_subsec "$PG_DETAIL_AT" "$PG_SUBSEC_MARKER" 'review-tests — triage: MUST'
pg_run "$PG_DETAIL_AT" "$PG_CTX_CAT"
pg_subsec_frame
# Recorded here for 15n's both-direction comparison: where the SAME marker lands
# relative to the BLOCK (not the sub-section) when written under Accepted Tradeoffs.
PG_AT_IN_BLOCK="$(pg_hits_between "$PG_SUBSEC_MARKER" "${PG_SS_START:-0}" "${PG_SS_END:-0}")"

# 15h — the boundary exists, is UNIQUE and is ordered. Every row below reads it; a
# missing, duplicated or reordered header must fail here and name itself rather than
# letting 15i/15j pass against an arbitrary window.
assert_eq "15h1: the settled block renders exactly one '$PG_AT_HDR' header line" "1" "$PG_SS_AT_N"
assert_eq "15h2: the settled block renders exactly one '$PG_CM_HDR' header line" "1" "$PG_SS_CM_N"
if [[ -z "$PG_SS_START" || -z "$PG_SS_END" || -z "$PG_SS_AT" || -z "$PG_SS_CM" ]]; then
  fail "15h3: the block window or a sub-section header is unlocatable (block=[$PG_SS_START..$PG_SS_END] at=[$PG_SS_AT] cm=[$PG_SS_CM])"
elif [[ "$PG_SS_START" -lt "$PG_SS_AT" && "$PG_SS_AT" -lt "$PG_SS_CM" && "$PG_SS_CM" -lt "$PG_SS_END" ]]; then
  pass "15h3: both sub-section headers stand inside the block in document order (start=$PG_SS_START at=$PG_SS_AT cm=$PG_SS_CM end=$PG_SS_END)"
else
  fail "15h3: the sub-sections are not nested in order inside the block (start=$PG_SS_START at=$PG_SS_AT cm=$PG_SS_CM end=$PG_SS_END)"
fi

# 15i — the SUPPRESSIBLE half: a deferral written under `## Accepted Tradeoffs` is
# attributable to that sub-section at every occurrence.
PG_AT_IN="$(pg_hits_between "$PG_SUBSEC_MARKER" "${PG_SS_AT:-0}" "${PG_SS_CM:-0}")"
PG_AT_ALL="$(pg_hits "$PG_SUBSEC_MARKER")"
if [[ -z "$PG_AT_ALL" || -z "$PG_SS_AT" || -z "$PG_SS_CM" ]]; then
  fail "15i: the deferral or the Accepted Tradeoffs sub-window is unlocatable (hits=[$PG_AT_ALL] window=[$PG_SS_AT..$PG_SS_CM])"
elif [[ "$(printf '%s' "$PG_AT_IN" | wc -w)" -eq "$(printf '%s' "$PG_AT_ALL" | wc -w)" ]]; then
  pass "15i: the deferral written under '$PG_AT_HDR' is attributable to that sub-section at every occurrence (lines$PG_AT_IN in $PG_SS_AT..$PG_SS_CM)"
else
  fail "15i: a copy of the Accepted-Tradeoffs deferral landed outside its own sub-section (all=[$PG_AT_ALL] inside=[$PG_AT_IN] window=$PG_SS_AT..$PG_SS_CM)"
fi

# --- Case 15D: the IDENTICAL bytes, moved one sub-section down. Nothing else changes,
# so any difference from 15i can only come from the sub-section it was written under.
PG_DETAIL_CM="$TMPROOT/pg-detail-subsec-cm.md"
pg_build_subsec "$PG_DETAIL_CM" 'PG_BENIGN_SUBSEC_2154_QZWX: log format is settled.' "$PG_SUBSEC_MARKER"
pg_run "$PG_DETAIL_CM" "$PG_CTX_CAT"
pg_subsec_frame

# 15j-0 — anti-vacuity: the marker must still reach codex (absence would satisfy 15j
# for the wrong reason) and both sub-sections must still be populated.
assert_in_prompt "15j-0: the class-members line still reaches the prompt (15j is not vacuous)" "$PG_SUBSEC_MARKER"
assert_eq "15j-0b: the roster sub-section is still rendered exactly once" "1" "$PG_SS_CM_N"
assert_in_prompt "15j-0c: the Accepted Tradeoffs sub-section is still populated by its own benign line" \
  'PG_BENIGN_SUBSEC_2154_QZWX: log format is settled.'

# 15j — the FALSE-POSITIVE half: deferral-shaped text sitting in the class-member
# roster must NOT be attributable to `## Accepted Tradeoffs`, so a consumer keying
# suppression on that sub-section cannot read it as a settled deferral.
PG_CM_IN_AT="$(pg_hits_between "$PG_SUBSEC_MARKER" "${PG_SS_AT:-0}" "${PG_SS_CM:-0}")"
PG_CM_IN_CM="$(pg_hits_between "$PG_SUBSEC_MARKER" "${PG_SS_CM:-0}" "${PG_SS_END:-0}")"
if [[ -z "$PG_SS_AT" || -z "$PG_SS_CM" || -z "$PG_SS_END" ]]; then
  fail "15j: the sub-section windows are unlocatable (at=[$PG_SS_AT] cm=[$PG_SS_CM] end=[$PG_SS_END])"
elif [[ -n "$PG_CM_IN_AT" ]]; then
  fail "15j: a class-members roster line was promoted into the Accepted Tradeoffs sub-section (line(s)$PG_CM_IN_AT, window $PG_SS_AT..$PG_SS_CM) — it would read as a settled deferral it is not"
elif [[ -n "$PG_CM_IN_CM" ]]; then
  pass "15j: the identical bytes stay in the class-members roster (lines$PG_CM_IN_CM in $PG_SS_CM..$PG_SS_END) and never enter the Accepted Tradeoffs sub-section"
else
  fail "15j: the class-members line is inside the block but in neither sub-window (cm=$PG_SS_CM end=$PG_SS_END) — the boundary cannot be read"
fi

# 15k — the block's own instruction about what a roster entry MEANS is intact and is
# prompt text, not promoted content: it stands before the block it describes. Without
# it the two sub-sections read as one undifferentiated authority list.
# One physical line of the block's preamble: the sentence is wrapped in the source,
# so a phrase spanning the wrap would never match the assembled prompt.
PG_TRIAGE="NA = do not raise why this wasn't fixed; OPTIONAL = do not demand"
assert_eq "15k1: the class-member triage-semantics instruction appears exactly once" \
  "1" "$(prompt_count "$PG_TRIAGE")"
PG_TRIAGE_LINE="$(prompt_first_line "$PG_TRIAGE")"
if [[ -z "$PG_TRIAGE_LINE" || -z "$PG_SS_START" ]]; then
  fail "15k2: the triage-semantics instruction or the block start is unlocatable (triage=[$PG_TRIAGE_LINE] start=[$PG_SS_START])"
elif [[ "$PG_TRIAGE_LINE" -lt "$PG_SS_START" ]]; then
  pass "15k2: the triage-semantics instruction introduces the block rather than sitting inside it (line $PG_TRIAGE_LINE < $PG_SS_START)"
else
  fail "15k2: the triage-semantics instruction no longer precedes the block it describes (line $PG_TRIAGE_LINE, block start $PG_SS_START)"
fi

# 15l — the anti-blanket clause survives: without it "everything in the block is
# settled" could be read as suppressing the whole checklist.
assert_eq "15l: the 'not documented as deferred' clause still appears exactly once" \
  "1" "$(prompt_count 'Categories not documented as deferred/N/A remain fully subject to the checklist below.')"

# 15m — the genuinely OPEN category is named in the checklist codex evaluates against,
# and no occurrence of it sits inside the Accepted Tradeoffs sub-section. The category
# the roster line names is therefore still presented as open — the outcome 15j's
# false positive would have destroyed.
assert_in_prompt "15m-0: the open category is named in the checklist codex evaluates against" "$PG_OPEN_CAT"
PG_OPEN_IN_AT="$(pg_hits_between "$PG_OPEN_CAT" "${PG_SS_AT:-0}" "${PG_SS_CM:-0}")"
PG_OPEN_AFTER="$(pg_hits_between "$PG_OPEN_CAT" "${PG_SS_END:-0}" 999999)"
if [[ -z "$PG_SS_AT" || -z "$PG_SS_CM" || -z "$PG_SS_END" ]]; then
  fail "15m: the block windows are unlocatable — the open category's placement cannot be judged"
elif [[ -n "$PG_OPEN_IN_AT" ]]; then
  fail "15m: the open category was promoted into the Accepted Tradeoffs sub-section (line(s)$PG_OPEN_IN_AT) — it would read as settled"
elif [[ -n "$PG_OPEN_AFTER" ]]; then
  pass "15m: the open category appears only after the settled block (lines$PG_OPEN_AFTER), in the checklist it belongs to"
else
  fail "15m: the open category does not appear after the settled block — the checklist reference is broken"
fi

# --- Case 15n (C3): the SUPPRESSION INSTRUCTION'S OWN SCOPE, read off the assembled
# prompt. 15h-15m pin that the two sub-sections stay distinguishable BY POSITION; they
# say nothing about which of them the instruction keys suppression on. It names ONE
# region — "inside the SETTLED DECISIONS block above" — and both sub-sections live in
# it, so by the prompt's own wording a deferral under `## Class members` is as eligible
# as one under `## Accepted Tradeoffs`. These rows pin that subsection-agnostic wording:
# scoping suppression to one sub-section, or dropping the block clause, must fail here.
# The capture in scope is 15D's — the marker sits under `## Class members`, the
# direction 15j proved is NOT attributable to Accepted Tradeoffs.
PG_SUPPRESS_SENT="$(grep -m1 -F -- "$PG_GUARD_IN" "$PROMPT_CAPTURE" 2>/dev/null || true)"
if [[ -z "$PG_SUPPRESS_SENT" ]]; then
  fail "15n-0: the suppression instruction could not be read out of the captured prompt — 15n1-15n4 would judge nothing"
else
  pass "15n-0: the suppression instruction was read out of the captured prompt as one physical line"
fi

# 15n1 — the instruction scopes suppression to the WHOLE settled-decisions block.
case "$PG_SUPPRESS_SENT" in
  *"$PG_GUARD_IN"*) pass "15n1: the suppression instruction scopes suppression to the whole SETTLED DECISIONS block" ;;
  *) fail "15n1: the suppression instruction no longer names the settled-decisions block as the region that counts: [$PG_SUPPRESS_SENT]" ;;
esac

# 15n2 — and it names NEITHER sub-section, so it draws no Accepted-Tradeoffs-only /
# Class-members-only distinction. Checked on the SENTENCE, not on the whole prompt:
# both header strings legitimately appear elsewhere in it.
PG_SUBSEC_QUALIFIERS=""
for pg_q in 'Accepted Tradeoffs' 'Class members'; do
  case "$PG_SUPPRESS_SENT" in *"$pg_q"*) PG_SUBSEC_QUALIFIERS="$PG_SUBSEC_QUALIFIERS [$pg_q]" ;; esac
done
if [[ -z "$PG_SUBSEC_QUALIFIERS" ]]; then
  pass "15n2: the suppression instruction qualifies its scope by NO sub-section — a deferral anywhere in the block is textually eligible"
else
  fail "15n2: the suppression instruction now scopes itself to a sub-section$PG_SUBSEC_QUALIFIERS — 15n4's both-direction reading no longer holds: [$PG_SUPPRESS_SENT]"
fi

# 15n3 — anti-vacuity for 15n2: those header strings ARE in the prompt at large, so
# 15n2's absence is a property of the sentence, not of an empty capture.
assert_in_prompt "15n3: the accepted-tradeoffs header does appear elsewhere in the prompt (15n2 is not vacuous)" "$PG_AT_HDR"
assert_in_prompt "15n3b: the class-members header appears in the prompt too" "$PG_CM_HDR"

# 15n4 — the both-direction consequence, stated on POSITION so it is checkable here:
# the identical marker lands inside the settled block under BOTH sub-sections. With
# 15i/15j (attribution differs) and 15n2 (the instruction ignores the sub-section), the
# prompt gives codex no textual basis for treating the roster copy differently.
PG_CM_IN_BLOCK="$(pg_hits_between "$PG_SUBSEC_MARKER" "${PG_SS_START:-0}" "${PG_SS_END:-0}")"
if [[ -z "$PG_AT_IN_BLOCK" || -z "$PG_CM_IN_BLOCK" ]]; then
  fail "15n4: the marker is not inside the settled block in both directions (accepted-tradeoffs=[$PG_AT_IN_BLOCK] class-members=[$PG_CM_IN_BLOCK]) — one run did not promote it"
else
  pass "15n4: the identical deferral text lands inside the settled block under BOTH sub-sections (accepted-tradeoffs lines$PG_AT_IN_BLOCK, class-members lines$PG_CM_IN_BLOCK) — the instruction's one region covers both"
fi

# SKIPPED: that codex treats the 15A/15C deferral as settled and the 15B out-of-block
#          and 15D roster ones as non-suppressing.
# Because: this layer mocks the codex CLI (TL2); model comprehension is not
#          observable, only the byte placement the guard sentence relies on. The
#          prompt names one authority region without distinguishing its two
#          sub-sections, so 15h-15m pin the boundary a consumer needs.
# TL3 gap: only a real codex round shows whether placement changes the verdict, and
#          whether roster text shaped like a deferral suppresses a category. 15n
#          therefore judges the INSTRUCTION TEXT's scope, never a model verdict.

echo ""
