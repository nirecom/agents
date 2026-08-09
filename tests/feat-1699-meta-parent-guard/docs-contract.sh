# tests/feat-1699-meta-parent-guard/docs-contract.sh
# Tests: rules/github-issues.md, skills/issue-create/SKILL.md
# Tags: issue-create, docs, meta-parent, admin-close-path, contract, scope:issue-specific, pwsh-not-required, TL1
# TL3 gap (what this test does NOT catch):
# - Whether the DEPLOYED $HOME/.claude copies of these files match the worktree, and
#   whether a model reading them actually behaves as they say. Static text checks only.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# Group D2 — the prose contract for the meta model.
#
# rules/github-issues.md and skills/issue-create/SKILL.md are what a human (and every model
# that loads them) reads before touching this route. #1699 changed two claims code alone
# cannot hold: the `Group: ` prefix is now dispatcher-enforced on make-parent, and
# make-parent creates two issues rather than promoting the proposal. A doc describing the
# old shape will be followed, so both claims are pinned — including the retired wording,
# in the negative.

DOC_RULES="$AGENTS_DIR/rules/github-issues.md"
DOC_SKILL="$AGENTS_DIR/skills/issue-create/SKILL.md"

# doc_assert <label> <file> <grep-flags…> — passes when the pattern matches; a missing
# file is reported as such rather than as an absent pattern.
doc_has() {  # <label> <file> <pattern> <why>
    local label="$1" f="$2" pat="$3" why="$4"
    if [ ! -f "$f" ]; then
        fail "$label" "document not found: $f"
    elif grep -qiE -- "$pat" "$f"; then
        pass "$label"
    else
        fail "$label" "$why (pattern: $pat, file: $f)"
    fi
}

# --- section scoping -------------------------------------------------------------------
# A "the meta section must say X" assertion run as a whole-file grep is satisfied by an X
# anywhere in the document, while the section a reader lands on says nothing. Every case
# whose message names a section is therefore run against that section's body only.
#
# doc_section <file> <heading-regex> → the body of the first matching `##`/`###` section,
# headings excluded. An unmatched heading yields empty output, which doc_section_has
# reports as a missing section rather than as a missing pattern.
doc_section() {
    [ -f "$1" ] || return 0
    awk -v re="$2" '
      /^#{2,}[[:space:]]/ { inb = ($0 ~ re) ? 1 : 0; next }
      inb { print }' "$1"
}

doc_section_has() {  # <label> <file> <heading-regex> <pattern> <why>
    local label="$1" f="$2" head="$3" pat="$4" why="$5" body
    if [ ! -f "$f" ]; then
        fail "$label" "document not found: $f"
        return
    fi
    body="$(doc_section "$f" "$head")"
    if [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
        fail "$label" "no section matching /$head/ in $f — the section this contract is about is gone or renamed"
        return
    fi
    # Flattened: a rule that happens to wrap across two lines is the same rule.
    if printf '%s' "$body" | tr '\n' ' ' | grep -qiE -- "$pat"; then
        pass "$label"
    else
        fail "$label" "$why (pattern: $pat, section: /$head/ of $f)"
    fi
}

doc_lacks() {  # <label> <file> <pattern> <why>
    local label="$1" f="$2" pat="$3" why="$4"
    if [ ! -f "$f" ]; then
        fail "$label" "document not found: $f"
    elif grep -qiE -- "$pat" "$f"; then
        fail "$label" "$why (still matches: $pat, file: $f)"
    else
        pass "$label"
    fi
}

# --- D2.1: rules/github-issues.md — the meta / admin_close_path contract ------------------
META_SEC='^##[[:space:]]+meta label and admin_close_path'
doc_section_has D2.1-meta-label-closes-via-admin-path "$DOC_RULES" "$META_SEC" \
    'admin_close_path' \
    "the meta section must name admin_close_path — it is the only close route a parent with no implementation can take"
doc_section_has D2.1b-meta-label-has-group-title-convention "$DOC_RULES" "$META_SEC" \
    'Group: ' \
    "the meta section must state the \`Group: \` title convention the dispatcher and the guard both key on"
doc_section_has D2.1c-admin-close-path-conditions "$DOC_RULES" "$META_SEC" \
    'admin_close_path.*(all sub-issues closed|OPEN)' \
    "admin_close_path must state WHEN it applies, not merely that it exists"

# Both the new claim and the absence of the old one are asserted: adding the new sentence
# while leaving the old one gives a self-contradicting doc.
doc_section_has D2.2-group-prefix-is-code-enforced-on-make-parent "$DOC_RULES" "$META_SEC" \
    'Group: .*(applied automatically|automatic).*make-parent|make-parent.*(applied automatically|automatic)' \
    "the meta section owns the title convention, so it is where the automatic-prefix claim has to live"
doc_lacks D2.2b-retired-not-code-enforced-claim "$DOC_RULES" \
    'not code-enforced|no code enforcement' \
    "the pre-#1699 claim that the Group: prefix is not code-enforced contradicts the dispatcher"

# The verdict table and its notes live under `## Issue creation`; that is the section a
# reader consults before dispatching, so that is where these four claims must be.
CREATE_SEC='^##[[:space:]]+Issue creation'
doc_section_has D2.3-make-parent-creates-two-issues "$DOC_RULES" "$CREATE_SEC" \
    'make-parent.*TWO issues|make-parent.*two issues' \
    "the issue-creation section must state that make-parent creates two issues (meta parent + the proposal as its child)"
doc_section_has D2.3b-make-parent-stdout-order "$DOC_RULES" "$CREATE_SEC" \
    'parent first, child last|parent first' \
    "the doc must state the stdout order, because every caller extracts the proposal with tail -n 1"
doc_section_has D2.4-guard-named-in-rules "$DOC_RULES" "$CREATE_SEC" \
    'require-meta-parent\.sh' \
    "sub-of / bulk-sub-of abort on an ineligible parent — the doc must name the guard that does it"
doc_section_has D2.4b-guard-aborts-before-creation "$DOC_RULES" "$CREATE_SEC" \
    'before any issue is created|aborts before' \
    "the doc must state that the abort happens BEFORE creation — that ordering is the whole point of the guard"

# --- D2.5: the conversion procedure is the documented alternative to a label bypass -------
# require-meta-parent.sh's rc=3 message points here by name. A pointer to a section that
# does not exist is worse than no pointer.
doc_has D2.5-conversion-section-exists "$DOC_RULES" \
    '^#+ .*[Cc]onverting an issue into a meta parent' \
    "require-meta-parent.sh's recovery message names this section by title"
doc_section_has D2.5b-conversion-rejects-label-only "$DOC_RULES" \
    '^##[[:space:]]+Converting an issue into a meta parent' \
    'labelling it .*meta.* does not make it one|label would only hide' \
    "the section must say that adding the label alone is not a conversion — that is the bypass the guard exists to block"
if [ -f "$DOC_RULES" ]; then
    steps=$(awk '/[Cc]onverting an issue into a meta parent/ { inSec = 1; next }
                 inSec && /^#+ / { inSec = 0 }
                 inSec && /^[0-9]+\. / { c++ }
                 END { print c + 0 }' "$DOC_RULES")
    if [ "${steps:-0}" -ge 3 ]; then
        pass "D2.5c-conversion-has-three-ordered-steps"
    else
        fail "D2.5c-conversion-has-three-ordered-steps" "want >=3 numbered steps in the conversion section (got: ${steps:-0}) — an unordered list would let 'apply the label' happen first"
    fi
else
    fail "D2.5c-conversion-has-three-ordered-steps" "document not found: $DOC_RULES"
fi

# --- D2.6: skills/issue-create/SKILL.md — the make-parent instructions ---------------------
# These claims belong to the dispatch phase, where the operator chooses a verdict and reads
# the URLs. Stated elsewhere they satisfy a whole-file grep but leave the procedure silent.
DISPATCH_SEC='^###[[:space:]]+Phase 4'
doc_section_has D2.6-skill-make-parent-two-issues "$DOC_SKILL" "$DISPATCH_SEC" \
    'make-parent creates TWO issues|make-parent.*two issues' \
    "the dispatch phase must tell the operator that make-parent produces two issues"
doc_section_has D2.6b-skill-parent-shape "$DOC_SKILL" "$DISPATCH_SEC" \
    'meta.*Group: |Group: .*meta' \
    "the skill must describe the parent's shape (meta label + Group: title), since the guard rejects anything else"
doc_section_has D2.6c-skill-proposal-is-the-child "$DOC_SKILL" "$DISPATCH_SEC" \
    'proposal verbatim as its child|proposal.*child' \
    "the skill must say the proposal becomes the CHILD — the pre-#1699 behaviour promoted it to parent"
doc_section_has D2.7-skill-stdout-two-lines "$DOC_SKILL" "$DISPATCH_SEC" \
    'make-parent emits two|two \(parent first' \
    "the stdout contract must state make-parent's two lines and their order"
doc_section_has D2.7b-skill-tail-n-1-still-works "$DOC_SKILL" "$DISPATCH_SEC" \
    'tail -n 1' \
    "the skill must keep the tail -n 1 extraction idiom visible — it is what the parent-first ordering protects"
doc_section_has D2.8-skill-guard-exit-codes "$DOC_SKILL" "$DISPATCH_SEC" \
    'exit 2.*exit 1|not .*meta.*exit 2' \
    "the skill must distinguish the ineligible-parent exit (2) from the indeterminate one (1)"
doc_section_has D2.8b-skill-points-at-conversion-section "$DOC_SKILL" "$DISPATCH_SEC" \
    'Converting an issue into a meta parent' \
    "the skill's recovery pointer must name the same rules section the guard's stderr names (one SSOT, two referrers)"

# --- D2.9: both files stay inside the prompt-file HARD limit ------------------------------
# Pattern B prompt files: HARD 200 lines (rules/coding/file-split.md). #1699 added to both.
for pair in "D2.9-rules-under-hard-limit:$DOC_RULES" "D2.9b-skill-under-hard-limit:$DOC_SKILL"; do
    label="${pair%%:*}"; f="${pair#*:}"
    if [ ! -f "$f" ]; then
        fail "$label" "document not found: $f"
        continue
    fi
    n=$(grep -c '' "$f")
    if [ "$n" -le 200 ]; then
        pass "$label"
    else
        fail "$label" "Pattern B HARD limit is 200 lines (got: $n) — $f must be split"
    fi
done
