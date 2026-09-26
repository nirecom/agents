#!/bin/bash
# tests/feature-2278-pretool-lang-gates/gate-worktree-notes-lang-cases.sh
# Tests: hooks/gate-worktree-notes-lang.js, hooks/lib/pretool-lang-gate.js
# Tags: lang, hook, pretooluse, worktree-notes, TL2, scope:issue-specific
# Sourced by ../feature-2278-pretool-lang-gates.sh — helpers come from there.
# WNG-T1..T28: hooks/gate-worktree-notes-lang.js PreToolUse gate. Visibility is
# decided by the hook's own isPrivateRepo(process.cwd()), so every case runs
# with cwd = a fixture repo (non-GitHub origin → private; no origin → public).
# lang-check: ignore -- this file intentionally contains CJK test fixtures for language-policy tests

echo ""
echo "=== WNG: hooks/gate-worktree-notes-lang.js PreToolUse gate ==="

WNG_PREFIX='[gate-worktree-notes-lang] WORKTREE_NOTES.md language check failed'
EN_BULLET='This is an English only history bullet'
JA_BULLET='日本語の履歴エントリ'

PRIV_REPO="$(make_fixture_repo 'https://gitlab.example.com/acme/thing.git')"
PUB_REPO="$(make_fixture_repo '')"
PRIV_NOTES="$PRIV_REPO/WORKTREE_NOTES.md"
PUB_NOTES="$PUB_REPO/WORKTREE_NOTES.md"

CFG_NOTES_PRIV_JA="$(make_env "" "" japanese)"
CFG_NOTES_PUB_EN="$(make_env "" english "")"
CFG_NOTES_PRIV_FR="$(make_env "" "" french)"

# Full-document fixtures (Write payloads)
DOC_HIST_EN=$'## History Notes\n- '"$EN_BULLET"$'\n\n## Changelog Notes\n- (none)'
DOC_HIST_JA=$'## History Notes\n- '"$JA_BULLET"$'\n\n## Changelog Notes\n- (none)'
DOC_CHG_JA=$'## History Notes\n- (none)\n\n## Changelog Notes\n- '"$JA_BULLET"
DOC_NONE=$'## History Notes\n- (none)\n\n## Changelog Notes\n- (none)'

# WNG-T1 (C1): private repo, DOCS_LANG_PRIVATE=japanese only, English History bullet → block
run_gate "$NOTES_GATE" "$(mk_payload Write "$PRIV_NOTES" content "$DOC_HIST_EN")" "$CFG_NOTES_PRIV_JA" "$PRIV_REPO"
assert_block_prefix "WNG-T1a: private repo + DOCS_LANG_PRIVATE=japanese, English History bullet → block" "$WNG_PREFIX"
assert_reason_has "WNG-T1b: reason names the History Notes section" "[History Notes:"
assert_reason_has "WNG-T1c: reason states the PRIVATE policy was selected (expected japanese)" "(expected japanese)"

# WNG-T2: same, Japanese bullet → approve
run_gate "$NOTES_GATE" "$(mk_payload Write "$PRIV_NOTES" content "$DOC_HIST_JA")" "$CFG_NOTES_PRIV_JA" "$PRIV_REPO"
assert_approve "WNG-T2: private repo, Japanese History bullet → approve"

# WNG-T3: public repo, DOCS_LANG_PUBLIC=english only, Japanese Changelog bullet → block
run_gate "$NOTES_GATE" "$(mk_payload Write "$PUB_NOTES" content "$DOC_CHG_JA")" "$CFG_NOTES_PUB_EN" "$PUB_REPO"
assert_block_prefix "WNG-T3a: public repo + DOCS_LANG_PUBLIC=english, Japanese Changelog bullet → block" "$WNG_PREFIX"
assert_reason_has "WNG-T3b: reason states the PUBLIC policy was selected (expected english)" "(expected english)"
assert_reason_has "WNG-T3c: reason names the Changelog Notes section" "[Changelog Notes:"

# WNG-T4: private repo with only DOCS_LANG_PUBLIC set → private side is noop → approve
run_gate "$NOTES_GATE" "$(mk_payload Write "$PRIV_NOTES" content "$DOC_HIST_EN")" "$CFG_NOTES_PUB_EN" "$PRIV_REPO"
assert_approve "WNG-T4: private repo, only DOCS_LANG_PUBLIC=english set, English bullet → approve (routing → private → noop)"

# WNG-T5: Edit whose new_string carries the heading → fragment linted on its own (file absent)
[ -e "$PRIV_NOTES" ] && rm -f "$PRIV_NOTES"
run_gate "$NOTES_GATE" "$(mk_edit Edit "$PRIV_NOTES" "- (none)" $'## History Notes\n- '"$EN_BULLET")" "$CFG_NOTES_PRIV_JA" "$PRIV_REPO"
assert_block_prefix "WNG-T5: Edit new_string with heading + English bullet, file absent → block (self-contained fragment)" "$WNG_PREFIX"

# WNG-T6: bullet-only Edit; disk pre-content reconstructed via applyEdits → block
printf '%s\n' "$DOC_NONE" > "$PRIV_NOTES"
run_gate "$NOTES_GATE" "$(mk_edit Edit "$PRIV_NOTES" "- (none)" "- $EN_BULLET")" "$CFG_NOTES_PRIV_JA" "$PRIV_REPO"
assert_block_prefix "WNG-T6: bullet-only Edit replacing '- (none)' under History Notes on disk → block after reconstruction" "$WNG_PREFIX"

# WNG-T7: same but old_string not on disk → approve (fail-open, PostToolUse backstop)
run_gate "$NOTES_GATE" "$(mk_edit Edit "$PRIV_NOTES" "- nothing like this on disk" "- $EN_BULLET")" "$CFG_NOTES_PRIV_JA" "$PRIV_REPO"
assert_approve "WNG-T7: bullet-only Edit whose old_string is absent from disk → approve (fail-open)"

# WNG-T8: bullet-only Edit, file absent → approve (fail-open)
rm -f "$PRIV_NOTES"
run_gate "$NOTES_GATE" "$(mk_edit Edit "$PRIV_NOTES" "- (none)" "- $EN_BULLET")" "$CFG_NOTES_PRIV_JA" "$PRIV_REPO"
assert_approve "WNG-T8: bullet-only Edit on absent file → approve (fail-open)"

# WNG-T9: English bullet under a non-target section → approve
run_gate "$NOTES_GATE" "$(mk_payload Write "$PRIV_NOTES" content $'## Notes\n- '"$EN_BULLET")" "$CFG_NOTES_PRIV_JA" "$PRIV_REPO"
assert_approve "WNG-T9: English bullet under '## Notes' (not a target section) → approve"

# WNG-T10: hint tier → silent approve
run_gate "$NOTES_GATE" "$(mk_payload Write "$PRIV_NOTES" content "$DOC_HIST_EN")" "$CFG_NOTES_PRIV_FR" "$PRIV_REPO"
assert_approve "WNG-T10: DOCS_LANG_PRIVATE=french (hint tier) → approve without additionalContext"

# WNG-T11: other basename → approve
run_gate "$NOTES_GATE" "$(mk_payload Write "$PRIV_REPO/NOTES.md" content "$DOC_HIST_EN")" "$CFG_NOTES_PRIV_JA" "$PRIV_REPO"
assert_approve "WNG-T11: basename NOTES.md → approve (not targeted)"

# WNG-T12: non-JSON stdin → approve
run_gate "$NOTES_GATE" 'not-json' "$CFG_NOTES_PRIV_JA" "$PRIV_REPO"
assert_approve "WNG-T12: non-JSON stdin → approve (fail-open)"

# WNG-T13 (C2): innocent top-level path, notes path on the element → block
_wng13_el="$(mk_edit_elem file_path "$PRIV_NOTES" "- (none)" $'## History Notes\n- '"$EN_BULLET")"
run_gate "$NOTES_GATE" "$(mk_multiedit MultiEdit "$PRIV_REPO/src/app.js" "$_wng13_el")" "$CFG_NOTES_PRIV_JA" "$PRIV_REPO"
assert_block_prefix "WNG-T13: MultiEdit top-level src/app.js, edits[0].file_path = WORKTREE_NOTES.md with English bullet → block" "$WNG_PREFIX"

# WNG-T14 (C3): two heading-bearing fragments on one path, only the second violates → exactly 1 violation
_wng14_e0="$(mk_edit_elem - "" "a" $'## History Notes\n- '"$JA_BULLET")"
_wng14_e1="$(mk_edit_elem - "" "b" $'## History Notes\n- '"$EN_BULLET")"
run_gate "$NOTES_GATE" "$(mk_multiedit MultiEdit "$PRIV_NOTES" "$_wng14_e0" "$_wng14_e1")" "$CFG_NOTES_PRIV_JA" "$PRIV_REPO"
assert_block_prefix "WNG-T14a: MultiEdit with Japanese fragment + English fragment → block" "$WNG_PREFIX"
_wng14_n="$(reason_count '(expected japanese)')"
if [ "$_wng14_n" = "1" ]; then
    pass "WNG-T14b: exactly 1 violation reported (fragments linted independently; edits[0] passes)"
else
    fail "WNG-T14b: expected 1 violation line, got $_wng14_n in: $(gate_reason)"
fi

# WNG-T15 (C3): editFiles end-to-end — `path` spelling + content → block
run_gate "$NOTES_GATE" "$(mk_payload_pathkey editFiles path "$PRIV_NOTES" content "$DOC_HIST_EN")" "$CFG_NOTES_PRIV_JA" "$PRIV_REPO"
assert_block_prefix "WNG-T15: editFiles {path: WORKTREE_NOTES.md, content: English History bullet} private+japanese → block" "$WNG_PREFIX"

# WNG-T16 (C3): editFiles carrying edits[] with file_path = WORKTREE_NOTES.md → block
_wng16_el="$(mk_edit_elem file_path "$PRIV_NOTES" "- (none)" $'## History Notes\n- '"$EN_BULLET")"
run_gate "$NOTES_GATE" "$(mk_multiedit editFiles "$PRIV_REPO/src/app.js" "$_wng16_el")" "$CFG_NOTES_PRIV_JA" "$PRIV_REPO"
assert_block_prefix "WNG-T16: editFiles edits[0].file_path = WORKTREE_NOTES.md with English bullet → block" "$WNG_PREFIX"

# WNG-T17 (C4): one MultiEdit target mixing a heading-self-contained compliant
# fragment (edits[0]) with a headingless English bullet (edits[1]) whose
# old_string exists on disk under ## History Notes → the headingless fragment
# goes through the reconstruct path → block with exactly 1 violation.
printf '%s\n' "$DOC_NONE" > "$PRIV_NOTES"
_wng17_e0="$(mk_edit_elem - "" "## History Notes" $'## History Notes\n- '"$JA_BULLET")"
_wng17_e1="$(mk_edit_elem - "" "- (none)" "- $EN_BULLET")"
run_gate "$NOTES_GATE" "$(mk_multiedit MultiEdit "$PRIV_NOTES" "$_wng17_e0" "$_wng17_e1")" "$CFG_NOTES_PRIV_JA" "$PRIV_REPO"
assert_block_prefix "WNG-T17a: MultiEdit edits[0] heading+Japanese (self-contained), edits[1] headingless English bullet (on-disk old_string) → block" "$WNG_PREFIX"
_wng17_n="$(reason_count '(expected japanese)')"
if [ "$_wng17_n" = "1" ]; then
    pass "WNG-T17b: exactly 1 violation (reconstructed document carries the English bullet; edits[0] clean)"
else
    fail "WNG-T17b: expected 1 violation line, got $_wng17_n in: $(gate_reason)"
fi
rm -f "$PRIV_NOTES"

# WNG-T18 (C3): strict-English allow path — public repo + DOCS_LANG_PUBLIC=english, English bullet → approve
run_gate "$NOTES_GATE" "$(mk_payload Write "$PUB_NOTES" content "$DOC_HIST_EN")" "$CFG_NOTES_PUB_EN" "$PUB_REPO"
assert_approve "WNG-T18: public repo + DOCS_LANG_PUBLIC=english, English History bullet → approve"

# WNG-T19 (C6): malformed tool_input shapes on WORKTREE_NOTES.md, strict policy → approve (fail-open)
# Columns: name | tool | tool_input JSON (NOTES = $PRIV_NOTES)
while IFS='|' read -r _name _tool _raw; do
    [[ -z "$_name" || "$_name" =~ ^[[:space:]]*# ]] && continue
    _name="${_name//[[:space:]]/}"; _tool="${_tool//[[:space:]]/}"; _raw="${_raw//[[:space:]]/}"
    _raw="${_raw/NOTES/$PRIV_NOTES}"
    run_gate "$NOTES_GATE" "$(mk_payload_raw "$_tool" "$_raw")" "$CFG_NOTES_PRIV_JA" "$PRIV_REPO"
    assert_approve "WNG-T19/$_name: $_tool tool_input=$_raw → approve (fail-open)"
done <<'TABLE'
# name           | tool      | tool_input
null-input       | Write     | null
content-number   | Write     | {"file_path":"NOTES","content":42}
newstring-object | Edit      | {"file_path":"NOTES","old_string":"a","new_string":{"x":1}}
edits-empty      | MultiEdit | {"file_path":"NOTES","edits":[]}
edits-notarray   | MultiEdit | {"file_path":"NOTES","edits":"notarray"}
TABLE

# WNG-T20 (C1 mirror): on-disk notes violate (English History bullet); the Edit
# replaces that bullet with Japanese → post-edit document is compliant → approve.
printf '%s\n' "$DOC_HIST_EN" > "$PRIV_NOTES"
run_gate "$NOTES_GATE" "$(mk_edit Edit "$PRIV_NOTES" "- $EN_BULLET" "- $JA_BULLET")" "$CFG_NOTES_PRIV_JA" "$PRIV_REPO"
assert_approve "WNG-T20a: Edit swaps the on-disk English bullet for Japanese → approve (post-edit content only)"
_wng20_e0="$(mk_edit_elem - "" "- $EN_BULLET" "- $JA_BULLET")"
_wng20_e1="$(mk_edit_elem - "" "- (none)" "- $JA_BULLET")"
run_gate "$NOTES_GATE" "$(mk_multiedit MultiEdit "$PRIV_NOTES" "$_wng20_e0" "$_wng20_e1")" "$CFG_NOTES_PRIV_JA" "$PRIV_REPO"
assert_approve "WNG-T20b: MultiEdit on violating disk, every fragment Japanese → approve"
rm -f "$PRIV_NOTES"

# WNG-T21 (C2): cross-target allow — compliant fragment on WORKTREE_NOTES.md plus an
# English History fragment whose file_path is an unrelated file → approve (no aggregation across paths).
_wng21_e0="$(mk_edit_elem - "" "a" $'## History Notes\n- '"$JA_BULLET")"
_wng21_e1="$(mk_edit_elem file_path "$PRIV_REPO/other.md" "b" $'## History Notes\n- '"$EN_BULLET")"
run_gate "$NOTES_GATE" "$(mk_multiedit MultiEdit "$PRIV_NOTES" "$_wng21_e0" "$_wng21_e1")" "$CFG_NOTES_PRIV_JA" "$PRIV_REPO"
assert_approve "WNG-T21: Japanese fragment on WORKTREE_NOTES.md + English fragment on other.md → approve"

# WNG-T22 (C3): violating notes fixture carrying a synthetic secret on a compliant
# bullet → block, and the secret must not surface in stdout/stderr/reason.
_wng22_doc=$'## History Notes\n- '"$JA_BULLET $SYNTHETIC_SECRET"$'\n- '"$EN_BULLET"$'\n\n## Changelog Notes\n- (none)'
run_gate "$NOTES_GATE" "$(mk_payload Write "$PRIV_NOTES" content "$_wng22_doc")" "$CFG_NOTES_PRIV_JA" "$PRIV_REPO"
assert_block_prefix "WNG-T22a: Write with Japanese+secret bullet and English bullet → block" "$WNG_PREFIX"
assert_not_leaked "WNG-T22b: synthetic secret from the compliant bullet is not echoed in stdout/stderr/reason" "$SYNTHETIC_SECRET"

# WNG-T23 (C1): disk carries an UNTOUCHED English History violation plus a Japanese
# Changelog bullet. A heading-bearing Edit fragment is linted on its own (detail.md item 5:
# no reconstruction) → approve; a bullet-only Edit forces whole-document reconstruction,
# which still contains the untouched violation → block. Either way the gate never writes.
DOC_HIST_EN_CHG_JA=$'## History Notes\n- '"$EN_BULLET"$'\n\n## Changelog Notes\n- '"$JA_BULLET"
printf '%s\n' "$DOC_HIST_EN_CHG_JA" > "$PRIV_NOTES"
_wng23_before="$(sha1sum "$PRIV_NOTES")"
run_gate "$NOTES_GATE" "$(mk_edit Edit "$PRIV_NOTES" $'## Changelog Notes\n- '"$JA_BULLET" $'## Changelog Notes\n- 日本語に書き直した変更履歴')" "$CFG_NOTES_PRIV_JA" "$PRIV_REPO"
assert_approve "WNG-T23a: heading-bearing Japanese Changelog Edit, untouched English History bullet on disk → approve (fragment linted alone)"
run_gate "$NOTES_GATE" "$(mk_edit Edit "$PRIV_NOTES" "- $JA_BULLET" "- 日本語に書き直した変更履歴")" "$CFG_NOTES_PRIV_JA" "$PRIV_REPO"
assert_block_prefix "WNG-T23b: bullet-only Japanese Changelog Edit → reconstructed document still carries the English History bullet → block" "$WNG_PREFIX"
assert_reason_has "WNG-T23c: reconstruction block names the untouched History Notes section" "[History Notes:"
_wng23_after="$(sha1sum "$PRIV_NOTES")"
# Guarded on a real verdict: an absent gate trivially leaves bytes alone (no false green).
if [ -n "$GATE_STDOUT" ] && [ -n "$_wng23_before" ] && [ "$_wng23_before" = "$_wng23_after" ]; then
    pass "WNG-T23d: notes bytes unchanged after both gate runs (PreToolUse gate never writes)"
else
    fail "WNG-T23d: gate verdict missing or bytes changed — stdout='$GATE_STDOUT' before='$_wng23_before' after='$_wng23_after'"
fi
rm -f "$PRIV_NOTES"

# WNG-T24 (C2): MultiEdit with NO top-level path; edits[0].path names WORKTREE_NOTES.md
_wng24_e0="$(mk_edit_elem path "$PRIV_NOTES" "a" $'## History Notes\n- '"$EN_BULLET")"
run_gate "$NOTES_GATE" "$(mk_multiedit MultiEdit - "$_wng24_e0")" "$CFG_NOTES_PRIV_JA" "$PRIV_REPO"
assert_block_prefix "WNG-T24: MultiEdit without top-level file_path, edits[0].path = WORKTREE_NOTES.md English → block" "$WNG_PREFIX"

# WNG-T25 (C4): compliant notes on disk, self-contained violating Edit submitted twice →
# identical block stdout both times, on-disk bytes never change (idempotent, read-only gate).
printf '%s\n' "$DOC_HIST_JA" > "$PRIV_NOTES"
_wng25_before="$(sha1sum "$PRIV_NOTES")"
_wng25_payload="$(mk_edit Edit "$PRIV_NOTES" "- $JA_BULLET" $'## History Notes\n- '"$EN_BULLET")"
run_gate "$NOTES_GATE" "$_wng25_payload" "$CFG_NOTES_PRIV_JA" "$PRIV_REPO"
assert_block_prefix "WNG-T25a: first run — heading-bearing English Edit over compliant notes → block" "$WNG_PREFIX"
_wng25_out1="$GATE_STDOUT"
run_gate "$NOTES_GATE" "$_wng25_payload" "$CFG_NOTES_PRIV_JA" "$PRIV_REPO"
assert_block_prefix "WNG-T25b: second run (identical payload) → block" "$WNG_PREFIX"
if [ -n "$GATE_STDOUT" ] && [ "$_wng25_out1" = "$GATE_STDOUT" ]; then
    pass "WNG-T25c: both runs produced byte-identical stdout"
else
    fail "WNG-T25c: stdout differs or empty — run1='$_wng25_out1' run2='$GATE_STDOUT'"
fi
_wng25_after="$(sha1sum "$PRIV_NOTES")"
if [ -n "$GATE_STDOUT" ] && [ -n "$_wng25_before" ] && [ "$_wng25_before" = "$_wng25_after" ]; then
    pass "WNG-T25d: notes bytes unchanged after two blocking runs"
else
    fail "WNG-T25d: gate verdict missing or bytes changed — stdout='$GATE_STDOUT' before='$_wng25_before' after='$_wng25_after'"
fi
rm -f "$PRIV_NOTES"

# WNG-T26 (C2): path-alias evasion — two spellings of the SAME file in one MultiEdit.
# edits[0] (absolute top-level path) parks a compliant placeholder; edits[1] spells the
# path relatively ("./WORKTREE_NOTES.md") and rewrites that placeholder into an English
# bullet. Grouping by raw path string split these into two groups, so edits[1]'s
# old_string was missing from the on-disk text and applyEdits bailed → silent approve.
# Canonicalized grouping applies both in order → the English bullet is seen → block.
printf '%s\n' "$DOC_NONE" > "$PRIV_NOTES"
_wng26_e0="$(mk_edit_elem file_path "$PRIV_NOTES" "- (none)" "- 仮の記述")"
_wng26_e1="$(mk_edit_elem file_path "./$(basename "$PRIV_NOTES")" "- 仮の記述" "- $EN_BULLET")"
run_gate "$NOTES_GATE" "$(mk_multiedit MultiEdit "$PRIV_NOTES" "$_wng26_e0" "$_wng26_e1")" "$CFG_NOTES_PRIV_JA" "$PRIV_REPO"
assert_block_prefix "WNG-T26: MultiEdit mixing absolute and relative spellings of WORKTREE_NOTES.md → both edits reconstructed together → block" "$WNG_PREFIX"
rm -f "$PRIV_NOTES"

# WNG-T27/T28 (C4): Changelog Notes matrix, mirroring WNG-T5's History Notes matrix —
# a heading-bearing Edit fragment (not Write) targeting "## Changelog Notes" on a file
# that does not yet exist on disk. WNG-T3 covers the Changelog heading only via Write
# (which bypasses HEADING_RE entirely — the whole payload is linted, no fragment match
# needed); WNG-T5 covers the Edit+self-contained-fragment path only for History Notes.
# Without these, a regression that special-cases HEADING_RE to match "History Notes"
# only (dropping the "Changelog Notes" alternative) would fail-open here and go
# undetected, since no other case exercises Edit+Changelog+absent-file together.

# WNG-T27: Edit new_string carries "## Changelog Notes" heading + violating (English)
# bullet, file absent → block (self-contained fragment, HEADING_RE matches Changelog).
[ -e "$PRIV_NOTES" ] && rm -f "$PRIV_NOTES"
run_gate "$NOTES_GATE" "$(mk_edit Edit "$PRIV_NOTES" "- (none)" $'## Changelog Notes\n- '"$EN_BULLET")" "$CFG_NOTES_PRIV_JA" "$PRIV_REPO"
assert_block_prefix "WNG-T27: Edit new_string with Changelog heading + English bullet, file absent → block (self-contained fragment)" "$WNG_PREFIX"
assert_reason_has "WNG-T27b: reason names the Changelog Notes section" "[Changelog Notes:"

# WNG-T28: same shape, compliant (Japanese) bullet under the Changelog heading → approve.
[ -e "$PRIV_NOTES" ] && rm -f "$PRIV_NOTES"
run_gate "$NOTES_GATE" "$(mk_edit Edit "$PRIV_NOTES" "- (none)" $'## Changelog Notes\n- '"$JA_BULLET")" "$CFG_NOTES_PRIV_JA" "$PRIV_REPO"
assert_approve "WNG-T28: Edit new_string with Changelog heading + Japanese bullet, file absent → approve (self-contained fragment, compliant)"
