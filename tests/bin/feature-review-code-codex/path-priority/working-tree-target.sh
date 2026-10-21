# Part of tests/bin/feature-review-code-codex/path-priority.sh (sourced, not standalone).
# Tests: bin/review-code-codex
# Tags: codex, review, working-tree, merge-base, budget, deletion, scope:issue-specific, pwsh-not-required, TL2
# P20-P23 (E24 redefinition, origin #1702): the working tree vs merge-base(BASE, HEAD) is the review target — a committed deletion recreated untracked, a committed path deleted in the working tree, the budget judged on the combined chunk, and the TRUNCATED M/N count spanning all four kinds of path; P24-P25 cover an index-removed path re-added untracked and the committed+untracked chunk's one-chunk budget and first-tier order; P26-P27 cover the uncommitted+untracked chunk's one-chunk budget and its once-only listing in the empty-committed fallback. Split out beside exclusion-and-cross-reference.sh at the 500-line hard limit.
# TL3 gap: codex is a shell mock, so these rows observe which diff the script assembled, never what the installed binary did with it; deletions and recreations are built by explicit git commands, so editor-driven renames are unexercised. Mitigation: WORKFLOW_USER_VERIFIED preflight, category merge-base-suspect.

# Earlier sub-files stub the reviewer or swap the mock; every row here needs the plain recorder.
PP_SCRIPT=""
pp_install_capturing_mock

# ---------------------------------------------------------------------------
# P20 — a path whose deletion was committed is recreated as an untracked file of the same name.
#       The recreated content must reach the body — as one chunk or as a committed plus an
#       untracked chunk, either is acceptable — with no EXCLUDED line and no FAILED verdict.
# ---------------------------------------------------------------------------
PP_R20="$(pp_new_base_repo pp-p20)"
pp_gen "$PP_R20/reborn.txt" 5 "pp-p20-original"
git -C "$PP_R20" add reborn.txt
git -C "$PP_R20" commit -q -m "seed reborn.txt on BASE"
git -C "$PP_R20" checkout -q -b feature-pp-p20
git -C "$PP_R20" rm -q reborn.txt
git -C "$PP_R20" commit -q -m "branch deletes reborn.txt"
pp_gen "$PP_R20/reborn.txt" 5 "pp-p20-recreated"

PP_ENV=(CODEX_REVIEW_MAX_DIFF_LINES=5000)
pp_exec "$PP_R20" --base main --base-state RECORDED --no-log
PP_ENV=()
if [ "$PP_RC" -ne 0 ] || pp_has "$PP_OUT_TEXT" "^## Codex Review: FAILED"; then
    fail "P20-verdict: a recreated deleted path broke the review (rc=$PP_RC). Output: $PP_OUT_TEXT"
else
    pass "P20-verdict: a recreated deleted path does not fail the review"
fi
if pp_has "$PP_OUT_TEXT" "^## Codex Review Scope: EXCLUDED"; then
    fail "P20-no-excluded: the recreated file was excluded although the working tree is the review target. Output: $PP_OUT_TEXT"
else
    pass "P20-no-excluded: no EXCLUDED line for the recreated path"
fi
if pp_diff_body "$PP_CAPTURE" | grep -q "^+pp-p20-recreated"; then
    pass "P20-content: the recreated file's content reaches the body"
else
    fail "P20-content: the recreated reborn.txt content is missing from the body. Output: $PP_OUT_TEXT"
fi
# The committed+untracked kind carries both sides; treating the path as plain untracked would drop the deletion.
pp_20_rec_body="$(pp_diff_body "$PP_CAPTURE")"
if pp_has "$pp_20_rec_body" "^deleted file mode" || pp_has "$pp_20_rec_body" "^-pp-p20-original"; then
    pass "P20-deletion: the committed deletion side reaches the body beside the recreated content"
else
    fail "P20-deletion: the body carries neither 'deleted file mode' nor the removed lines of reborn.txt. Output: $PP_OUT_TEXT"
fi

# P20 degraded twin (same mechanism as P19): under SUSPECT/FALLBACK/UNRESOLVED the recreated
# file is untracked content and stays withheld — even though its path is also a committed
# path, whose merge-base-to-working-tree chunk must not become a side door for it. The
# committed deletion itself is still reviewed.
PP_ENV=(CODEX_REVIEW_MAX_DIFF_LINES=5000)
for pp_state in SUSPECT FALLBACK UNRESOLVED; do
    pp_exec "$PP_R20" --base main --base-state "$pp_state" --no-log
    if { [ -f "$PP_CAPTURE" ] && grep -qF "pp-p20-recreated" "$PP_CAPTURE"; } || pp_has_fixed "$PP_OUT_TEXT" "pp-p20-recreated"; then
        fail "P20-withheld[$pp_state]: recreated untracked content reached the prompt or the output under a degraded base state"
    else
        pass "P20-withheld[$pp_state]: recreated untracked content stays out of prompt and output, committed chunk included"
    fi
    if [ "$PP_RC" -ne 0 ] || pp_has "$PP_OUT_TEXT" "^## Codex Review: FAILED"; then
        fail "P20-verdict[$pp_state]: the review failed (rc=$PP_RC). Output: $PP_OUT_TEXT"
    else
        pass "P20-verdict[$pp_state]: rc 0 and not FAILED"
    fi
    pp_20_body="$(pp_diff_body "$PP_CAPTURE")"
    if pp_has "$pp_20_body" "^deleted file mode" || pp_has "$pp_20_body" "^-pp-p20-original"; then
        pass "P20-deletion[$pp_state]: the committed deletion side is reviewed"
    else
        fail "P20-deletion[$pp_state]: the body carries neither 'deleted file mode' nor the removed lines of reborn.txt. Output: $PP_OUT_TEXT"
    fi
done
PP_ENV=()

# ---------------------------------------------------------------------------
# P21 — a committed path removed from the working tree (unstaged rm). Diffed from merge-base
#       to the working tree it is a deletion, so the body carries `deleted file mode` or the
#       file's removed lines; the review is PERFORMED with rc 0, never FAILED.
# ---------------------------------------------------------------------------
PP_R21="$(pp_new_base_repo pp-p21)"
pp_gen "$PP_R21/gone.txt" 5 "pp-p21-original"
git -C "$PP_R21" add gone.txt
git -C "$PP_R21" commit -q -m "seed gone.txt on BASE"
git -C "$PP_R21" checkout -q -b feature-pp-p21
echo "pp-p21-branch-edit" >> "$PP_R21/gone.txt"
git -C "$PP_R21" commit -q -am "branch edits gone.txt"
rm -f "$PP_R21/gone.txt"

PP_ENV=(CODEX_REVIEW_MAX_DIFF_LINES=5000)
pp_exec "$PP_R21" --base main --base-state RECORDED --no-log
PP_ENV=()
if [ "$PP_RC" -ne 0 ] || pp_has "$PP_OUT_TEXT" "^## Codex Review: FAILED"; then
    fail "P21-verdict: a committed path deleted in the working tree broke the review (rc=$PP_RC). Output: $PP_OUT_TEXT"
elif ! pp_has "$PP_OUT_TEXT" "^## Codex Review: PERFORMED"; then
    fail "P21-verdict: the review was not PERFORMED. Output: $PP_OUT_TEXT"
else
    pass "P21-verdict: rc 0 and PERFORMED with a committed path deleted in the working tree"
fi
pp_21_body="$(pp_diff_body "$PP_CAPTURE")"
if pp_has "$pp_21_body" "^deleted file mode" || pp_has "$pp_21_body" "^-pp-p21-original"; then
    pass "P21-deletion: the body shows gone.txt as deleted in the working tree"
else
    fail "P21-deletion: the body carries neither 'deleted file mode' nor the removed lines of gone.txt. Output: $PP_OUT_TEXT"
fi

# ---------------------------------------------------------------------------
# P22 — the budget is judged on the COMBINED chunk (committed + staged on top). Committed
#       alone is 96 lines and would fit a 100-line cap; with 30 staged lines on top the chunk
#       is 126 lines, so the path cannot be adopted whole: TRUNCATED, body within the cap.
#       P22-wide is the pair: a 5000-line cap adopts the whole chunk, staged lines included.
# ---------------------------------------------------------------------------
PP_R22="$(pp_new_repo pp-p22)"
pp_gen "$PP_R22/combined.txt" 90 "pp-p22-committed"
git -C "$PP_R22" add combined.txt
git -C "$PP_R22" commit -q -m "committed 90 lines"
awk 'BEGIN { for (i = 0; i < 30; i++) print "pp-p22-staged line " i }' >> "$PP_R22/combined.txt"
git -C "$PP_R22" add combined.txt

PP_ENV=(CODEX_REVIEW_MAX_DIFF_LINES=100)
PP_OUT="$(pp_run "$PP_R22" --base main --base-state RECORDED --no-log)"
PP_ENV=()
pp_22_lines="$(pp_diff_body_lines "$PP_CAPTURE")"
if ! pp_has "$PP_OUT" "^## Codex Review Scope: TRUNCATED"; then
    fail "P22-narrow: the 126-line combined chunk passed a 100-line cap untruncated — the budget was judged on the committed part alone. Output: $PP_OUT"
elif [ "${pp_22_lines:-0}" -gt 100 ]; then
    fail "P22-narrow: the body is $pp_22_lines lines, past the 100-line cap"
else
    pass "P22-narrow: the combined chunk is judged against the cap (TRUNCATED, body $pp_22_lines lines)"
fi

PP_ENV=(CODEX_REVIEW_MAX_DIFF_LINES=5000)
PP_OUT="$(pp_run "$PP_R22" --base main --base-state RECORDED --no-log)"
PP_ENV=()
pp_22_body="$(pp_diff_body "$PP_CAPTURE")"
if pp_has "$PP_OUT" "^## Codex Review Scope: TRUNCATED"; then
    fail "P22-wide: a 5000-line cap truncated a 126-line chunk. Output: $PP_OUT"
elif pp_has "$pp_22_body" "^+pp-p22-committed line 89" && pp_has "$pp_22_body" "^+pp-p22-staged line 29"; then
    pass "P22-wide: with room in the budget the whole combined chunk is adopted, staged lines included"
else
    fail "P22-wide: the combined chunk is incomplete in the body — committed or staged lines missing. Output: $PP_OUT"
fi

# ---------------------------------------------------------------------------
# P23 — the TRUNCATED M/N count spans every kind of path. One huge committed file, one
#       uncommitted-only file, one untracked file, cap 300: the two small paths are adopted
#       first and the huge committed path is the only one dropped, so the headline says 2/3.
# ---------------------------------------------------------------------------
PP_R23="$(pp_new_base_repo pp-p23)"
pp_gen "$PP_R23/unc-only.txt" 5 "pp-p23-unc-base"
git -C "$PP_R23" add unc-only.txt
git -C "$PP_R23" commit -q -m "seed the file edited without committing"
git -C "$PP_R23" checkout -q -b feature-pp-p23
pp_gen "$PP_R23/huge.txt" 400 "pp-p23-huge"
git -C "$PP_R23" add huge.txt
git -C "$PP_R23" commit -q -m "one huge committed file"
echo "pp-p23-unc-edit" >> "$PP_R23/unc-only.txt"
pp_gen "$PP_R23/new-untracked.txt" 5 "pp-p23-untracked"

PP_ENV=(CODEX_REVIEW_MAX_DIFF_LINES=300)
PP_OUT="$(pp_run "$PP_R23" --base main --base-state RECORDED --no-log)"
PP_ENV=()
if printf '%s\n' "$PP_OUT" | grep -E "^## Codex Review Scope: TRUNCATED" | grep -q "2/3 changed files"; then
    pass "P23-total: the TRUNCATED headline counts uncommitted-only and untracked-only paths (2/3)"
else
    fail "P23-total: the TRUNCATED headline does not report 2/3 changed files. Output: $PP_OUT"
fi
pp_23_dropped="$(pp_scope_paths "$PP_OUT" Dropped | tr '\n' ' ')"
if [ "$pp_23_dropped" = "huge.txt " ]; then
    pass "P23-dropped: Dropped lists only the huge committed file"
else
    fail "P23-dropped: Dropped lists [$pp_23_dropped], not 'huge.txt'. Output: $PP_OUT"
fi
if pp_has "$PP_OUT" "^## Codex Review Scope: EXCLUDED"; then
    fail "P23-no-excluded: an EXCLUDED line was printed although the working tree is the review target. Output: $PP_OUT"
else
    pass "P23-no-excluded: no EXCLUDED line"
fi

# ---------------------------------------------------------------------------
# P24 — a tracked path removed from the index only (`git rm --cached`) and re-added as an
#       untracked file. It is not a committed path, so it is the uncommitted+untracked kind:
#       the body carries both the deletion side and the re-added content.
# ---------------------------------------------------------------------------
PP_R24="$(pp_new_base_repo pp-p24)"
pp_gen "$PP_R24/keep.txt" 5 "pp-p24-original"
git -C "$PP_R24" add keep.txt
git -C "$PP_R24" commit -q -m "seed keep.txt on BASE"
git -C "$PP_R24" checkout -q -b feature-pp-p24
pp_gen "$PP_R24/other.txt" 3 "pp-p24-other"
git -C "$PP_R24" add other.txt
git -C "$PP_R24" commit -q -m "branch commits another file"
git -C "$PP_R24" rm -q --cached keep.txt
pp_gen "$PP_R24/keep.txt" 5 "pp-p24-readded"

PP_ENV=(CODEX_REVIEW_MAX_DIFF_LINES=5000)
pp_exec "$PP_R24" --base main --base-state RECORDED --no-log
PP_ENV=()
if [[ "$PP_RC" -ne 0 ]] || pp_has "$PP_OUT_TEXT" "^## Codex Review: FAILED"; then
    fail "P24-verdict: an index-removed path re-added untracked broke the review (rc=$PP_RC). Output: $PP_OUT_TEXT"
elif ! pp_has "$PP_OUT_TEXT" "^## Codex Review: PERFORMED"; then
    fail "P24-verdict: the review was not PERFORMED. Output: $PP_OUT_TEXT"
else
    pass "P24-verdict: rc 0 and PERFORMED with an index-removed path re-added untracked"
fi
if pp_has "$PP_OUT_TEXT" "^## Codex Review Scope: EXCLUDED"; then
    fail "P24-no-excluded: the re-added file was excluded although the working tree is the review target. Output: $PP_OUT_TEXT"
else
    pass "P24-no-excluded: no EXCLUDED line for the re-added path"
fi
pp_24_body="$(pp_diff_body "$PP_CAPTURE")"
if pp_has "$pp_24_body" "^+pp-p24-readded"; then
    pass "P24-content: the re-added untracked content reaches the body"
else
    fail "P24-content: the re-added keep.txt content is missing from the body — the path was diffed as plain uncommitted. Output: $PP_OUT_TEXT"
fi
if pp_has "$pp_24_body" "^deleted file mode" || pp_has "$pp_24_body" "^-pp-p24-original"; then
    pass "P24-deletion: the index-removal side reaches the body"
else
    fail "P24-deletion: the body carries neither 'deleted file mode' nor the removed lines of keep.txt. Output: $PP_OUT_TEXT"
fi

# P24 degraded twin (same mechanism as P20): the re-added file is untracked content and stays
# withheld; the deletion of the tracked path is still reviewed.
PP_ENV=(CODEX_REVIEW_MAX_DIFF_LINES=5000)
for pp_state in SUSPECT FALLBACK UNRESOLVED; do
    pp_exec "$PP_R24" --base main --base-state "$pp_state" --no-log
    if { [[ -f "$PP_CAPTURE" ]] && grep -qF "pp-p24-readded" "$PP_CAPTURE"; } || pp_has_fixed "$PP_OUT_TEXT" "pp-p24-readded"; then
        fail "P24-withheld[$pp_state]: re-added untracked content reached the prompt or the output under a degraded base state"
    else
        pass "P24-withheld[$pp_state]: re-added untracked content stays out of prompt and output"
    fi
    if [[ "$PP_RC" -ne 0 ]] || pp_has "$PP_OUT_TEXT" "^## Codex Review: FAILED"; then
        fail "P24-verdict[$pp_state]: the review failed (rc=$PP_RC). Output: $PP_OUT_TEXT"
    else
        pass "P24-verdict[$pp_state]: rc 0 and not FAILED"
    fi
    pp_24_deg_body="$(pp_diff_body "$PP_CAPTURE")"
    if pp_has "$pp_24_deg_body" "^deleted file mode" || pp_has "$pp_24_deg_body" "^-pp-p24-original"; then
        pass "P24-deletion[$pp_state]: the index-removal side is reviewed"
    else
        fail "P24-deletion[$pp_state]: the body carries neither 'deleted file mode' nor the removed lines of keep.txt. Output: $PP_OUT_TEXT"
    fi
done
PP_ENV=()

# ---------------------------------------------------------------------------
# P25 — a committed+untracked path is budgeted as ONE chunk and adopted first. z-reborn.txt
#       (deleted on the branch, recreated untracked) sorts after a-first.txt (committed only).
#       P25-whole: the cap fits the deletion side and a-first.txt but not the combined chunk,
#       so z-reborn.txt is dropped whole. P25-order: the cap fits the combined chunk but not
#       both paths, so tier order — not name order — decides that a-first.txt is dropped.
# ---------------------------------------------------------------------------
PP_R25="$(pp_new_base_repo pp-p25)"
pp_gen "$PP_R25/z-reborn.txt" 5 "pp-p25-original"
git -C "$PP_R25" add z-reborn.txt
git -C "$PP_R25" commit -q -m "seed z-reborn.txt on BASE"
git -C "$PP_R25" checkout -q -b feature-pp-p25
git -C "$PP_R25" rm -q z-reborn.txt
pp_gen "$PP_R25/a-first.txt" 20 "pp-p25-first"
git -C "$PP_R25" add a-first.txt
git -C "$PP_R25" commit -q -m "branch deletes z-reborn.txt and adds a-first.txt"
pp_gen "$PP_R25/z-reborn.txt" 40 "pp-p25-recreated"

pp_25_del="$(pp_committed_chunk_lines "$PP_R25" main z-reborn.txt)"
pp_25_unt="$(pp_untracked_chunk_lines "$PP_R25" z-reborn.txt)"
pp_25_first="$(pp_committed_chunk_lines "$PP_R25" main a-first.txt)"
pp_25_comb=$(( pp_25_del + pp_25_unt ))
pp_25_cap_whole=$(( pp_25_del > pp_25_first ? pp_25_del : pp_25_first ))
pp_25_cap_order=$(( pp_25_comb + pp_25_first - 1 ))
if (( pp_25_del == 0 || pp_25_first == 0 || pp_25_cap_whole >= pp_25_comb )); then
    fail "P25-fixture: chunk sizes (deletion $pp_25_del, untracked $pp_25_unt, a-first $pp_25_first) cannot separate the cases"
else
    pass "P25-fixture: chunk sizes separate the cases (deletion $pp_25_del, combined $pp_25_comb, a-first $pp_25_first)"
fi

PP_ENV=(CODEX_REVIEW_MAX_DIFF_LINES="$pp_25_cap_whole")
PP_OUT="$(pp_run "$PP_R25" --base main --base-state RECORDED --no-log)"
PP_ENV=()
pp_25_body="$(pp_diff_body "$PP_CAPTURE")"
pp_25_dropped="$(pp_scope_paths "$PP_OUT" Dropped | tr '\n' ' ')"
if [[ "$pp_25_dropped" != "z-reborn.txt " ]]; then
    fail "P25-whole: Dropped lists [$pp_25_dropped], not 'z-reborn.txt' (cap $pp_25_cap_whole). Output: $PP_OUT"
elif pp_has "$pp_25_body" "pp-p25-original" || pp_has "$pp_25_body" "pp-p25-recreated"; then
    fail "P25-whole: part of the dropped combined chunk still reached the body (cap $pp_25_cap_whole). Output: $PP_OUT"
elif ! pp_has "$pp_25_body" "^+pp-p25-first line 19"; then
    fail "P25-whole: a-first.txt, which fits the cap, is missing from the body. Output: $PP_OUT"
else
    pass "P25-whole: the combined chunk is judged as one and dropped whole; a-first.txt is reviewed"
fi

PP_ENV=(CODEX_REVIEW_MAX_DIFF_LINES="$pp_25_cap_order")
PP_OUT="$(pp_run "$PP_R25" --base main --base-state RECORDED --no-log)"
PP_ENV=()
pp_25_body="$(pp_diff_body "$PP_CAPTURE")"
pp_25_dropped="$(pp_scope_paths "$PP_OUT" Dropped | tr '\n' ' ')"
if [[ "$pp_25_dropped" != "a-first.txt " ]]; then
    fail "P25-order: Dropped lists [$pp_25_dropped], not 'a-first.txt' — the committed+untracked path was not adopted first (cap $pp_25_cap_order). Output: $PP_OUT"
elif ! pp_has "$pp_25_body" "^+pp-p25-recreated line 39"; then
    fail "P25-order: the recreated content of the first-tier path is missing from the body. Output: $PP_OUT"
else
    pass "P25-order: the committed+untracked path is adopted before a committed-only path that sorts earlier"
fi

# ---------------------------------------------------------------------------
# P26 — the uncommitted+untracked chunk is budgeted as ONE chunk. keep.txt (index-removed,
#       re-added untracked) is first tier; other.txt (committed only) is last tier.
#       P26-whole: the cap fits the deletion side and other.txt but not the combined chunk, so
#       keep.txt is dropped whole with no deletion-only partial. P26-wide: the cap fits the
#       combined chunk, so keep.txt is adopted once and other.txt is the one dropped.
# ---------------------------------------------------------------------------
PP_R26="$(pp_new_base_repo pp-p26)"
pp_gen "$PP_R26/keep.txt" 5 "pp-p26-original"
git -C "$PP_R26" add keep.txt
git -C "$PP_R26" commit -q -m "seed keep.txt on BASE"
git -C "$PP_R26" checkout -q -b feature-pp-p26
pp_gen "$PP_R26/other.txt" 3 "pp-p26-other"
git -C "$PP_R26" add other.txt
git -C "$PP_R26" commit -q -m "branch commits another file"
git -C "$PP_R26" rm -q --cached keep.txt
pp_gen "$PP_R26/keep.txt" 40 "pp-p26-readded"

pp_26_del="$(git -C "$PP_R26" diff --no-renames HEAD -- keep.txt | wc -l | tr -d '[:space:]')"
pp_26_unt="$(pp_untracked_chunk_lines "$PP_R26" keep.txt)"
pp_26_other="$(pp_committed_chunk_lines "$PP_R26" main other.txt)"
pp_26_comb=$(( pp_26_del + pp_26_unt ))
pp_26_cap_whole=$(( pp_26_del > pp_26_other ? pp_26_del : pp_26_other ))
pp_26_cap_wide=$(( pp_26_comb + pp_26_other - 1 ))
if (( pp_26_del == 0 || pp_26_other == 0 || pp_26_cap_whole >= pp_26_comb || pp_26_cap_wide < pp_26_comb )); then
    fail "P26-fixture: chunk sizes (deletion $pp_26_del, untracked $pp_26_unt, other $pp_26_other) cannot separate the cases"
else
    pass "P26-fixture: chunk sizes separate the cases (deletion $pp_26_del, combined $pp_26_comb, other $pp_26_other)"
fi

PP_ENV=(CODEX_REVIEW_MAX_DIFF_LINES="$pp_26_cap_whole")
PP_OUT="$(pp_run "$PP_R26" --base main --base-state RECORDED --no-log)"
PP_ENV=()
pp_26_body="$(pp_diff_body "$PP_CAPTURE")"
pp_26_dropped="$(pp_scope_paths "$PP_OUT" Dropped | tr '\n' ' ')"
if ! pp_has "$PP_OUT" "^## Codex Review Scope: TRUNCATED"; then
    fail "P26-whole: the combined chunk passed a $pp_26_cap_whole-line cap untruncated. Output: $PP_OUT"
elif [[ "$pp_26_dropped" != "keep.txt " ]]; then
    fail "P26-whole: Dropped lists [$pp_26_dropped], not 'keep.txt' (cap $pp_26_cap_whole). Output: $PP_OUT"
elif pp_has "$pp_26_body" "pp-p26-readded" || pp_has "$pp_26_body" "pp-p26-original" || pp_has "$PP_OUT" "^Partially reviewed"; then
    fail "P26-whole: part of the dropped combined chunk (deletion side or re-added content) still reached the body (cap $pp_26_cap_whole). Output: $PP_OUT"
elif ! pp_has "$pp_26_body" "^+pp-p26-other line 2"; then
    fail "P26-whole: other.txt, which fits the cap, is missing from the body. Output: $PP_OUT"
else
    pass "P26-whole: the uncommitted+untracked chunk is judged as one and dropped whole; other.txt is reviewed"
fi

PP_ENV=(CODEX_REVIEW_MAX_DIFF_LINES="$pp_26_cap_wide")
PP_OUT="$(pp_run "$PP_R26" --base main --base-state RECORDED --no-log)"
PP_ENV=()
pp_26_body="$(pp_diff_body "$PP_CAPTURE")"
pp_26_reviewed="$(pp_scope_paths "$PP_OUT" Reviewed | tr '\n' ' ')"
pp_26_readded_n="$(pp_count_matching "$pp_26_body" "^+pp-p26-readded line 0$")"
if [[ "$pp_26_reviewed" != "keep.txt " ]]; then
    fail "P26-wide: Reviewed lists [$pp_26_reviewed], not 'keep.txt' once (cap $pp_26_cap_wide). Output: $PP_OUT"
elif [[ "$pp_26_readded_n" != "1" ]]; then
    fail "P26-wide: the re-added content appears $pp_26_readded_n times in the body, not once. Output: $PP_OUT"
elif ! pp_has "$pp_26_body" "^-pp-p26-original line 4"; then
    fail "P26-wide: the deletion side of keep.txt is missing from the body. Output: $PP_OUT"
else
    pass "P26-wide: keep.txt is adopted once as one chunk, both sides in the body"
fi

# ---------------------------------------------------------------------------
# P27 — the same index-removed, re-added path with NO commit beyond BASE (BASE...HEAD empty).
#       The fallback must list it once as the uncommitted+untracked kind: the re-added content
#       appears once, and a TRUNCATED headline counts it as one of the distinct changed paths.
# ---------------------------------------------------------------------------
PP_R27="$(pp_new_base_repo pp-p27)"
pp_gen "$PP_R27/keep.txt" 5 "pp-p27-original"
git -C "$PP_R27" add keep.txt
git -C "$PP_R27" commit -q -m "seed keep.txt on BASE"
git -C "$PP_R27" checkout -q -b feature-pp-p27
git -C "$PP_R27" rm -q --cached keep.txt
pp_gen "$PP_R27/keep.txt" 5 "pp-p27-readded"

PP_ENV=(CODEX_REVIEW_MAX_DIFF_LINES=5000)
pp_exec "$PP_R27" --base main --base-state RECORDED --no-log
PP_ENV=()
pp_27_body="$(pp_diff_body "$PP_CAPTURE")"
if [[ "$PP_RC" -ne 0 ]] || ! pp_has "$PP_OUT_TEXT" "^## Codex Review: PERFORMED"; then
    fail "P27-verdict: the fallback review was not PERFORMED with rc 0 (rc=$PP_RC). Output: $PP_OUT_TEXT"
else
    pass "P27-verdict: rc 0 and PERFORMED"
fi
if pp_has "$PP_OUT_TEXT" "^Note: BASE...HEAD empty"; then
    pass "P27-note: the empty-committed fallback is announced"
else
    fail "P27-note: no 'Note: BASE...HEAD empty' line. Output: $PP_OUT_TEXT"
fi
pp_27_readded_n="$(pp_count_matching "$pp_27_body" "^+pp-p27-readded line 0$")"
if [[ "$pp_27_readded_n" == "1" ]]; then
    pass "P27-content-once: the re-added content appears exactly once in the body"
else
    fail "P27-content-once: the re-added content appears $pp_27_readded_n times in the body, not once. Output: $PP_OUT_TEXT"
fi
if pp_has "$pp_27_body" "^deleted file mode" || pp_has "$pp_27_body" "^-pp-p27-original"; then
    pass "P27-deletion: the index-removal side reaches the body"
else
    fail "P27-deletion: the body carries neither 'deleted file mode' nor the removed lines of keep.txt. Output: $PP_OUT_TEXT"
fi

# P27 degraded twin (same mechanism as P20/P24): untracked content stays withheld in the fallback too.
PP_ENV=(CODEX_REVIEW_MAX_DIFF_LINES=5000)
for pp_state in SUSPECT FALLBACK UNRESOLVED; do
    pp_exec "$PP_R27" --base main --base-state "$pp_state" --no-log
    if { [[ -f "$PP_CAPTURE" ]] && grep -qF "pp-p27-readded" "$PP_CAPTURE"; } || pp_has_fixed "$PP_OUT_TEXT" "pp-p27-readded"; then
        fail "P27-withheld[$pp_state]: re-added untracked content reached the prompt or the output under a degraded base state"
    else
        pass "P27-withheld[$pp_state]: re-added untracked content stays out of prompt and output"
    fi
    if [[ "$PP_RC" -ne 0 ]] || pp_has "$PP_OUT_TEXT" "^## Codex Review: FAILED"; then
        fail "P27-verdict[$pp_state]: the review failed (rc=$PP_RC). Output: $PP_OUT_TEXT"
    else
        pass "P27-verdict[$pp_state]: rc 0 and not FAILED"
    fi
    pp_27_deg_body="$(pp_diff_body "$PP_CAPTURE")"
    if pp_has "$pp_27_deg_body" "^deleted file mode" || pp_has "$pp_27_deg_body" "^-pp-p27-original"; then
        pass "P27-deletion[$pp_state]: the index-removal side is reviewed"
    else
        fail "P27-deletion[$pp_state]: the body carries neither 'deleted file mode' nor the removed lines of keep.txt. Output: $PP_OUT_TEXT"
    fi
done
PP_ENV=()

# A big untracked file forces TRUNCATED: keep.txt fits and is adopted, big.txt is dropped.
pp_gen "$PP_R27/big.txt" 400 "pp-p27-big"
PP_ENV=(CODEX_REVIEW_MAX_DIFF_LINES=300)
PP_OUT="$(pp_run "$PP_R27" --base main --base-state RECORDED --no-log)"
PP_ENV=()
pp_27_body="$(pp_diff_body "$PP_CAPTURE")"
if printf '%s\n' "$PP_OUT" | grep -E "^## Codex Review Scope: TRUNCATED" | grep -q " 1/2 changed files"; then
    pass "P27-total: the TRUNCATED headline counts the 2 distinct changed paths (1/2)"
else
    fail "P27-total: the TRUNCATED headline does not report 1/2 changed files — keep.txt counted twice. Output: $PP_OUT"
fi
pp_27_listed="$( { pp_scope_paths "$PP_OUT" Reviewed; pp_scope_paths "$PP_OUT" Dropped; } | grep -cx "keep.txt" || true)"
if [[ "$pp_27_listed" == "1" ]]; then
    pass "P27-listed-once: keep.txt appears once across Reviewed and Dropped"
else
    fail "P27-listed-once: keep.txt appears $pp_27_listed times across Reviewed and Dropped. Output: $PP_OUT"
fi
pp_27_readded_n="$(pp_count_matching "$pp_27_body" "^+pp-p27-readded line 0$")"
if [[ "$pp_27_readded_n" == "1" ]]; then
    pass "P27-trunc-content-once: the re-added content is adopted with its deletion side, exactly once"
else
    fail "P27-trunc-content-once: the re-added content appears $pp_27_readded_n times in the truncated body, not once. Output: $PP_OUT"
fi
