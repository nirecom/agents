#!/usr/bin/env bash
# tests/bin/feat-2529-glossary-docs.sh
# Tests: rules/docs/glossary.md, rules/docs.md, docs/glossary.md, docs/glossary-user.md, docs/glossary-internal.md, docs/architecture/claude-code/shell-command-parsing.md, docs/architecture/claude-code/workflow.md, docs/architecture/claude-code/root-names.md, bin/check-root-names/classification.json, rules/handoff-emergency-flush.md, skills/_shared/combined-glossary.md, skills/update-docs/SKILL.md, skills/clarify-intent/SKILL.md, docs/architecture/claude-code/settings/hooks.md
# Tags: scope:issue-specific, TL1, static, docs, glossary, terminology, pwsh-not-required
# Issue #2529 — the glossary entry criteria become a rule (rules/docs/glossary.md), the
# glossary splits by category into glossary-user.md / glossary-internal.md with one entry
# form, single-subsystem terms move to their owning documents, every reference follows the
# move, and writers / reviewers reach the combined glossary through one shared fragment.
# Static: reads the checkout's own files; no fixture repo, no process under test.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT"

R="$SCRIPT_CHECKOUT_ROOT"
RULE="$R/rules/docs/glossary.md"
GL_INDEX="$R/docs/glossary.md"
GL_USER="$R/docs/glossary-user.md"
GL_INTERNAL="$R/docs/glossary-internal.md"
FRAGMENT="$R/skills/_shared/combined-glossary.md"
A="$R/docs/architecture/claude-code"

has() {
    if [ -f "$2" ] && grep -Eqi -- "$3" "$2"; then pass "$1"
    else fail "$1" "/$3/ not found in ${2#"$R"/}"; fi
}
# An absence over a missing or empty file proves nothing.
lacks() {
    if [ ! -s "$2" ]; then fail "$1" "${2#"$R"/} missing or empty; absence not provable"
    elif grep -Eqi -- "$3" "$2"; then fail "$1" "/$3/ still present in ${2#"$R"/}"
    else pass "$1"; fi
}

# entry <file> <term> — the body of one "### <term>" entry.
entry() { awk -v h="### $2" '{ sub(/\r$/, "") } $0 == h { on = 1; next } /^##+ / { on = 0 } on' "$1" 2>/dev/null; }

# slugs <file> — GitHub anchor slugs of the file's "### " headings, one per line.
slugs() {
    awk '{ sub(/\r$/, "") } /^### / { s = tolower(substr($0, 5)); gsub(/[^a-z0-9 _-]/, "", s); gsub(/ /, "-", s); print s }' "$1" 2>/dev/null
}

# The entry-form checker program (bin/lib/glossary-format.js spec, restated independently).
FORMAT_AWK="$TMP_ROOT/glossary-format.awk"
cat > "$FORMAT_AWK" <<'AWK'
      function err(m) { print m }
      function flush() {
        if (term == "") return
        if (defs != 1) err("entry \"" term "\": " defs " Definition line(s), want 1")
        if (deflines > 2) err("entry \"" term "\": Definition spans " deflines " lines, want <= 2")
        if (rels != 1) err("entry \"" term "\": " rels " Related line(s), want 1")
        if (rels == 1 && links != 1) err("entry \"" term "\": Related has " links " link(s), want 1")
      }
      { sub(/\r$/, "") }
      /^# / { h1++; if (term != "") err("line " NR ": H1 after the first entry"); next }
      /^## / { err("line " NR ": section heading: " $0); next }
      /^####/ { err("line " NR ": deeper heading: " $0); next }
      /^### / {
        flush(); term = substr($0, 5); lt = tolower(term)
        if (prev != "" && lt < prev) err("order: \"" term "\" after \"" prevt "\"")
        prev = lt; prevt = term; defs = 0; deflines = 0; rels = 0; links = 0; indef = 0; next
      }
      term == "" { next }
      /^- \*\*Definition\*\*:/ { defs++; deflines = 1; indef = 1; next }
      /^- \*\*Related\*\*:/ { rels++; indef = 0; s = $0; links += gsub(/\]\([^)]*\)/, "", s); next }
      /^[ \t]*[-*+] / { err("entry \"" term "\": extra bullet: " $0); indef = 0; next }
      /^[ \t]*$/ { indef = 0; next }
      /^<!--.*-->$/ { next }
      { if (indef) deflines++; else err("entry \"" term "\": stray line: " $0) }
      END { flush(); if (h1 != 1) err("H1 count " h1 + 0 ", want 1") }
AWK

# format_violations <file> — one line per entry-form violation (empty when the file conforms).
format_violations() {
    LC_ALL=C awk -f "$FORMAT_AWK" "$1" 2>/dev/null
}

# related_violations <file> — every Related link must be an in-repo file, never an issue URL.
related_violations() {
    local file="$1" dir line target path
    dir="$(dirname "$file")"
    grep -E '^- \*\*Related\*\*:' "$file" 2>/dev/null | tr -d '\r' | grep -oE '\]\([^)]*\)' | sed -E 's/^\]\((.*)\)$/\1/' |
    while IFS= read -r target; do
        case "$target" in
            *"/issues/"*) echo "issue URL: $target"; continue ;;
            http://*|https://*) echo "external URL: $target"; continue ;;
        esac
        path="${target%%#*}"
        [ -e "$dir/$path" ] || echo "missing target: $target"
    done
}

# ============================================================================
case_begin "rule-file-exists-with-paths-and-naming" "rules/docs/glossary.md"
# ============================================================================
if [ -s "$RULE" ]; then pass "D1/rule-file-exists"; else fail "D1/rule-file-exists" "rules/docs/glossary.md missing or empty"; fi
FM="$(awk 'NR == 1 && /^---/ { on = 1; next } on && /^---/ { exit } on' "$RULE" 2>/dev/null)"
if printf '%s\n' "$FM" | grep -q '^paths:' && printf '%s\n' "$FM" | grep -qF 'docs/glossary.md'; then
    pass "D1/paths-covers-glossary-index"
else fail "D1/paths-covers-glossary-index" "frontmatter paths: lacks docs/glossary.md"; fi
if printf '%s\n' "$FM" | grep -qF 'docs/glossary-*.md'; then pass "D1/paths-covers-split-files"
else fail "D1/paths-covers-split-files" "frontmatter paths: lacks docs/glossary-*.md"; fi
has "D1/states-range-split-naming" "$RULE" 'glossary-<category>-<from>-<to>\.md'
has "D1/names-user-file" "$RULE" 'docs/glossary-user\.md'
has "D1/names-internal-file" "$RULE" 'docs/glossary-internal\.md'
case_end

# ============================================================================
case_begin "rule-categories-match-code-constant" "rules/docs/glossary.md"
# ============================================================================
CATS=""
if command -v node >/dev/null 2>&1 && [ -f "$R/hooks/lib/intent-glossary.js" ]; then
    CATS="$(run_with_timeout 30 node -e 'const m = require(process.argv[1]); const c = m.CATEGORIES; if (!Array.isArray(c)) process.exit(3); process.stdout.write(c.join(" "));' "$(np "$R/hooks/lib/intent-glossary.js")" 2>/dev/null)"
fi
if [ -n "$CATS" ]; then pass "D2/code-constant-readable ($CATS)"
else fail "D2/code-constant-readable" "hooks/lib/intent-glossary.js missing or exports no CATEGORIES array"; fi
for c in $CATS; do has "D2/rule-names-category-$c" "$RULE" "\`$c\`"; done
# Reverse direction: every concrete glossary-<x>.md the rule names is a known category.
for x in $(grep -oE 'glossary-[a-z]+\.md' "$RULE" 2>/dev/null | sed -E 's/^glossary-([a-z]+)\.md$/\1/' | sort -u); do
    if [ -n "$CATS" ] && [[ " $CATS " == *" $x "* ]]; then pass "D2/rule-file-category-$x-is-known"
    else fail "D2/rule-file-category-$x-is-known" "glossary-$x.md names a category absent from CATEGORIES ($CATS)"; fi
done
case_end

# ============================================================================
case_begin "docs-rule-index-points-to-glossary-rule" "rules/docs.md"
# ============================================================================
has "D3/sub-rules-lists-glossary" "$R/rules/docs.md" '^- \[docs/glossary\.md\]\(docs/glossary\.md\)'
case_end

# ============================================================================
case_begin "glossary-index-is-a-pointer" "docs/glossary.md"
# ============================================================================
has "D4/links-user-file" "$GL_INDEX" '\]\((\./)?glossary-user\.md\)'
has "D4/links-internal-file" "$GL_INDEX" '\]\((\./)?glossary-internal\.md\)'
lacks "D4/no-entries" "$GL_INDEX" '^### '
IDX_LINES="$(wc -l < "$GL_INDEX" 2>/dev/null | tr -d ' ')"
if [ -n "$IDX_LINES" ] && [ "$IDX_LINES" -le 30 ]; then pass "D4/index-is-short ($IDX_LINES lines)"
else fail "D4/index-is-short" "${IDX_LINES:-missing} lines, want <= 30"; fi
case_end

# ============================================================================
case_begin "glossary-user-passes-entry-form" "docs/glossary-user.md"
# ============================================================================
if [ -s "$GL_USER" ]; then
    V="$(format_violations "$GL_USER")"
    if [ -z "$V" ]; then pass "D5/user-entry-form"; else fail "D5/user-entry-form" "$(printf '%s' "$V" | head -5)"; fi
    lacks "D5/user-no-full-name-or-level" "$GL_USER" '\*\*(Full name|Level)\*\*'
else fail "D5/user-entry-form" "docs/glossary-user.md missing or empty"; fi
case_end

# ============================================================================
case_begin "glossary-internal-passes-entry-form" "docs/glossary-internal.md"
# ============================================================================
if [ -s "$GL_INTERNAL" ]; then
    V="$(format_violations "$GL_INTERNAL")"
    if [ -z "$V" ]; then pass "D6/internal-entry-form"; else fail "D6/internal-entry-form" "$(printf '%s' "$V" | head -5)"; fi
    lacks "D6/internal-no-full-name-or-level" "$GL_INTERNAL" '\*\*(Full name|Level)\*\*'
else fail "D6/internal-entry-form" "docs/glossary-internal.md missing or empty"; fi
case_end

# ============================================================================
case_begin "kept-terms-follow-category-table" "docs/glossary-user.md"
# ============================================================================
# The curated kept terms must each appear exactly once in their category file. The check
# asserts presence, not a total: a later PR adding a qualifying entry must not break it.
USER_TERMS=(AGENTS_MAIN_ROOT "confirm gate" "deliverable type" "delivery path" detail "handoff artifact"
            intent Jev meta outline plan-sync "PM type" "presentation turn" "release phase" RTK sentinel
            WF-CODE WF-META workflow "workflow step")
INTERNAL_TERMS=("canonical dispatch line" "delivery boundary" "delivery operation" GATE_ACTION "in-skill step" IR
                "native worktree isolation" "review round" SCRIPT_CHECKOUT_ROOT "step table" TARGET_CHECKOUT_ROOT
                TARGET_MAIN_ROOT turn "workflow state dir")
# kept_terms_missing <user-file> <internal-file> — one line per curated term not present exactly once.
kept_terms_missing() {
    local t n
    for t in "${USER_TERMS[@]}"; do
        n="$(grep -cxF "### $t" "$1" 2>/dev/null)"; [ "${n:-0}" = 1 ] || echo "user:$t count=${n:-0}"
    done
    for t in "${INTERNAL_TERMS[@]}"; do
        n="$(grep -cxF "### $t" "$2" 2>/dev/null)"; [ "${n:-0}" = 1 ] || echo "internal:$t count=${n:-0}"
    done
}
for t in "${USER_TERMS[@]}"; do
    n="$(grep -cxF "### $t" "$GL_USER" 2>/dev/null)"
    if [ "${n:-0}" = 1 ]; then pass "D7/user-has-$t"; else fail "D7/user-has-$t" "count=${n:-0} in glossary-user.md"; fi
done
for t in "${INTERNAL_TERMS[@]}"; do
    n="$(grep -cxF "### $t" "$GL_INTERNAL" 2>/dev/null)"
    if [ "${n:-0}" = 1 ]; then pass "D7/internal-has-$t"; else fail "D7/internal-has-$t" "count=${n:-0} in glossary-internal.md"; fi
done
case_end

# ============================================================================
case_begin "extra-qualifying-entry-keeps-kept-terms-check" "docs/glossary-user.md"
# ============================================================================
# A fixture copy of glossary-user.md with one extra valid entry appended last ("zz…" sorts
# after every kept term): the entry form still holds and the kept-terms check still passes.
if [ -s "$GL_USER" ] && [ -s "$GL_INTERNAL" ]; then
    EXTRA_USER="$TMP_ROOT/glossary-user-extra.md"
    { cat "$GL_USER"; printf '\n### zz extra term\n\n- **Definition**: A later qualifying term.\n- **Related**: [glossary](glossary.md)\n'; } > "$EXTRA_USER"
    V="$(format_violations "$EXTRA_USER")"
    if [ -z "$V" ]; then pass "D7b/extra-entry-is-valid-form"; else fail "D7b/extra-entry-is-valid-form" "$(printf '%s' "$V" | head -5)"; fi
    M="$(kept_terms_missing "$EXTRA_USER" "$GL_INTERNAL")"
    if [ -z "$M" ]; then pass "D7b/kept-terms-check-tolerates-extra-entry"
    else fail "D7b/kept-terms-check-tolerates-extra-entry" "$(printf '%s' "$M" | head -5)"; fi
    if [ "$(grep -c '^### ' "$EXTRA_USER")" -gt "$(grep -c '^### ' "$GL_USER")" ]; then pass "D7b/fixture-has-one-more-entry"
    else fail "D7b/fixture-has-one-more-entry" "extra entry not appended"; fi
else
    fail "D7b/kept-terms-check-tolerates-extra-entry" "glossary-user.md or glossary-internal.md missing or empty"
fi
case_end

# ============================================================================
case_begin "related-links-are-in-repo-files" "docs/glossary-internal.md"
# ============================================================================
for f in "$GL_USER" "$GL_INTERNAL"; do
    b="${f##*/}"
    if [ ! -s "$f" ]; then fail "D8/$b-related-in-repo" "$b missing or empty"; continue; fi
    V="$(related_violations "$f")"
    if [ -z "$V" ]; then pass "D8/$b-related-in-repo"; else fail "D8/$b-related-in-repo" "$(printf '%s' "$V" | head -5)"; fi
done
IR_REL="$(entry "$GL_INTERNAL" IR | grep -E '^- \*\*Related\*\*:')"
if printf '%s\n' "$IR_REL" | grep -qF 'shell-command-parsing.md'; then pass "D8/ir-related-is-shell-command-parsing"
else fail "D8/ir-related-is-shell-command-parsing" "IR Related: ${IR_REL:-none}"; fi
if entry "$GL_INTERNAL" IR | grep -qF 'hooks/lib/command-ir/'; then pass "D8/ir-definition-names-command-ir"
else fail "D8/ir-definition-names-command-ir" "IR entry does not name hooks/lib/command-ir/"; fi
case_end

# ============================================================================
case_begin "ir-owner-defines-ir" "docs/architecture/claude-code/shell-command-parsing.md"
# ============================================================================
has "D9/owner-defines-ir-in-bold" "$A/shell-command-parsing.md" '\*\*IR\*\*'
case_end

# removed_in_owner <owner-path> <term-regex>... — each removed term has no glossary heading
# and is defined in its owning document (tolerant to space / hyphen / underscore joins).
removed_in_owner() {
    local owner="$1" t re; shift
    for t in "$@"; do
        re="${t// /[ _-]}"
        if [ ! -s "$GL_USER" ] || [ ! -s "$GL_INTERNAL" ]; then
            fail "D10/$t-not-in-glossary" "glossary files missing; absence not provable"
        elif grep -Eqi "^### ($re)\$" "$GL_USER" "$GL_INTERNAL"; then
            fail "D10/$t-not-in-glossary" "a glossary heading still names it"
        else pass "D10/$t-not-in-glossary"; fi
        has "D10/$t-defined-in-${owner##*/}" "$R/$owner" "$re"
    done
}

case_begin "removed-terms-in-handoff-artifact" "docs/architecture/claude-code/handoff-artifact.md"
removed_in_owner docs/architecture/claude-code/handoff-artifact.md "workflow active period" "risk signal" "flush mark" "pressure baseline"
case_end

case_begin "removed-terms-in-supervisor-audit-ledger" "docs/architecture/claude-code/supervisor-audit-ledger.md"
removed_in_owner docs/architecture/claude-code/supervisor-audit-ledger.md trigger "audit ledger" "audit run identity" sub-check "freshness backstop" "null-freshness predicate"
case_end

case_begin "removed-terms-in-supervisor-audit-agent" "agents/supervisor-audit.md"
removed_in_owner agents/supervisor-audit.md "audit checklist" "arm */ *surface */ *clear"
case_end

case_begin "removed-terms-in-codex-review-loop" "skills/_shared/codex-review-loop.md"
removed_in_owner skills/_shared/codex-review-loop.md "prestaged report"
case_end

case_begin "removed-terms-in-supervisor-codex-input" "docs/architecture/claude-code/supervisor-codex-input.md"
removed_in_owner docs/architecture/claude-code/supervisor-codex-input.md "transcript cursor" "codex input guard"
case_end

case_begin "removed-terms-in-concern-ledger" "docs/architecture/concern-ledger.md"
removed_in_owner docs/architecture/concern-ledger.md DISCRIM
case_end

case_begin "removed-terms-in-test-result-contract" "docs/architecture/claude-code/test-result-contract.md"
removed_in_owner docs/architecture/claude-code/test-result-contract.md UNRUNNABLE "case-level result line" "dispatch settlement" outcome_source
case_end

case_begin "removed-terms-in-test-host-lanes" "docs/architecture/claude-code/test-host-lanes.md"
removed_in_owner docs/architecture/claude-code/test-host-lanes.md "test lane"
case_end

case_begin "removed-terms-in-test-runner-parallelism" "docs/architecture/claude-code/test-runner-parallelism.md"
removed_in_owner docs/architecture/claude-code/test-runner-parallelism.md "base segment" "abandoned segment" "expired record"
case_end

case_begin "removed-terms-in-test-language-registry" "docs/architecture/claude-code/test-language-registry.md"
removed_in_owner docs/architecture/claude-code/test-language-registry.md "test language registry"
case_end

case_begin "removed-terms-in-test-command-guard" "docs/architecture/claude-code/test-command-guard.md"
removed_in_owner docs/architecture/claude-code/test-command-guard.md "run root" "command guard" "spawn record"
case_end

case_begin "removed-terms-in-case-marker-gate" "docs/architecture/claude-code/case-marker-gate.md"
removed_in_owner docs/architecture/claude-code/case-marker-gate.md "case marker" "marker conformance"
case_end

case_begin "removed-terms-in-complexity-judge" "agents/complexity-judge.md"
removed_in_owner agents/complexity-judge.md complexity-judge normalize-judge-signals
case_end

case_begin "removed-terms-in-nfr-severity-calibration" "agents/lib/nfr-severity-calibration.md"
removed_in_owner agents/lib/nfr-severity-calibration.md nfr-severity-calibration project-nfr-block
case_end

case_begin "removed-terms-in-workflow-doc" "docs/architecture/claude-code/workflow.md"
removed_in_owner docs/architecture/claude-code/workflow.md 'UNRECOGNIZED\(N\)'
case_end

case_begin "removed-terms-in-sweep-issues" "skills/sweep-issues/SKILL.md"
removed_in_owner skills/sweep-issues/SKILL.md band all-bands
case_end

case_begin "removed-terms-in-pr-state" "bin/workflow/pr-state"
removed_in_owner bin/workflow/pr-state pr-state
case_end

case_begin "removed-terms-in-jev-doc" "docs/architecture/jev.md"
removed_in_owner docs/architecture/jev.md "Jev shadow mode"
case_end

case_begin "removed-terms-in-shell-snapshot-repair" "docs/architecture/claude-code/shell-snapshot-repair.md"
removed_in_owner docs/architecture/claude-code/shell-snapshot-repair.md "Windows-form snapshot"
case_end

# ============================================================================
case_begin "workflow-doc-anchor-resolves" "docs/architecture/claude-code/workflow.md"
# ============================================================================
has "D11/workflow-links-glossary-user" "$A/workflow.md" 'glossary-user\.md#deliverable-type'
USER_SLUGS="$(slugs "$GL_USER")"; INTERNAL_SLUGS="$(slugs "$GL_INTERNAL")"
# Every anchored link into either glossary file, anywhere in the prose tree, must land.
REFS="$(grep -rIhoE --include='*.md' 'glossary-(user|internal)\.md#[A-Za-z0-9_-]+' \
    "$R/README.md" "$R/docs" "$R/rules" "$R/skills" "$R/agents" 2>/dev/null | sort -u)"
if [ -n "$REFS" ]; then pass "D11/anchored-references-found"; else fail "D11/anchored-references-found" "no glossary-user/internal anchors referenced"; fi
for ref in $REFS; do
    anchor="${ref#*#}"
    case "$ref" in
        glossary-user.md*) pool="$USER_SLUGS" ;;
        *) pool="$INTERNAL_SLUGS" ;;
    esac
    if printf '%s\n' "$pool" | grep -qxF "$anchor"; then pass "D11/anchor-lands-$ref"
    else fail "D11/anchor-lands-$ref" "no '### ' heading slugs to $anchor"; fi
done
case_end

# ============================================================================
case_begin "no-reference-to-old-glossary-anchors" "docs/architecture/claude-code/root-names.md"
# ============================================================================
OLD="$(grep -rIlE --include='*.md' --include='*.json' --exclude='history*.md' --exclude='CHANGELOG*.md' \
    'glossary\.md#' "$R/README.md" "$R/docs" "$R/rules" "$R/skills" "$R/agents" "$R/bin" "$R/hooks" 2>/dev/null |
    grep -v '/_archive' | sed "s|^$R/||")"
if [ -z "$OLD" ]; then pass "D12/no-glossary.md-anchor-anywhere"
else fail "D12/no-glossary.md-anchor-anywhere" "$(printf '%s' "$OLD" | tr '\n' ' ')"; fi
lacks "D12/root-names-no-old-link" "$A/root-names.md" '\(\.\./\.\./glossary\.md\)'
has "D12/root-names-points-to-user" "$A/root-names.md" 'glossary-user\.md'
has "D12/root-names-points-to-internal" "$A/root-names.md" 'glossary-internal\.md'
lacks "D12/snapshot-doc-no-old-anchor" "$A/shell-snapshot-repair.md" 'glossary\.md#windows-form-snapshot'
has "D12/snapshot-doc-keeps-bold-definition" "$A/shell-snapshot-repair.md" '\*\*Windows-form snapshot\*\*'
if grep -oE '\]\(docs/glossary[^)]*\)' "$R/README.md" 2>/dev/null | sed -E 's/^\]\((.*)\)$/\1/' | grep -q .; then
    bad=""
    for p in $(grep -oE '\]\(docs/glossary[^)]*\)' "$R/README.md" | sed -E 's/^\]\((.*)\)$/\1/'); do
        [ -f "$R/${p%%#*}" ] || bad="$bad $p"
    done
    if [ -z "$bad" ]; then pass "D12/readme-glossary-links-resolve"; else fail "D12/readme-glossary-links-resolve" "$bad"; fi
else fail "D12/readme-glossary-links-resolve" "README.md no longer links the glossary"; fi
case_end

# ============================================================================
case_begin "root-names-exception-follows-split" "bin/check-root-names/classification.json"
# ============================================================================
CJ="$R/bin/check-root-names/classification.json"
has "D13/exception-on-internal-file" "$CJ" '"file" *: *"docs/glossary-internal\.md"'
lacks "D13/no-exception-on-index" "$CJ" '"docs/glossary\.md"'
case_end

# ============================================================================
case_begin "flush-rule-names-new-owner" "rules/handoff-emergency-flush.md"
# ============================================================================
has "D14/flush-rule-owner-is-user-file" "$R/rules/handoff-emergency-flush.md" '`docs/glossary-user\.md` owns the term'
lacks "D14/flush-rule-no-old-owner" "$R/rules/handoff-emergency-flush.md" 'docs/glossary\.md'
case_end

# ============================================================================
case_begin "writers-and-reviewers-reference-fragment" "skills/_shared/combined-glossary.md"
# ============================================================================
if [ -s "$FRAGMENT" ]; then pass "D15/fragment-exists"; else fail "D15/fragment-exists" "skills/_shared/combined-glossary.md missing or empty"; fi
WRITERS="agents/outline-planner.md agents/detail-planner.md skills/write-code/SKILL.md skills/write-tests/SKILL.md skills/update-docs/SKILL.md"
REVIEWERS="agents/outline-reviewer.md agents/detail-reviewer.md agents/test-reviewer.md skills/review-docs/SKILL.md"
for f in $WRITERS; do
    n="$(grep -cF '`skills/_shared/combined-glossary.md` (writer directives)' "$R/$f" 2>/dev/null)"
    if [ "${n:-0}" = 1 ]; then pass "D15/writer-ref-$f"; else fail "D15/writer-ref-$f" "writer reference count=${n:-0}, want 1"; fi
done
for f in $REVIEWERS; do
    n="$(grep -cF '`skills/_shared/combined-glossary.md` (reviewer directives)' "$R/$f" 2>/dev/null)"
    if [ "${n:-0}" = 1 ]; then pass "D15/reviewer-ref-$f"; else fail "D15/reviewer-ref-$f" "reviewer reference count=${n:-0}, want 1"; fi
done
# The fragment's own sentences stay in the fragment (CPR-SSOT): no long body line is copied.
FRAG_BODY="$TMP_ROOT/fragment-body.txt"
awk '{ sub(/\r$/, ""); l = $0; gsub(/^[ \t>*-]+|[ \t]+$/, "", l) } l !~ /^#/ && length(l) >= 40 { print l }' "$FRAGMENT" > "$FRAG_BODY" 2>/dev/null
if [ -s "$FRAG_BODY" ]; then
    copied=""
    for f in $WRITERS $REVIEWERS; do
        if grep -qF -f "$FRAG_BODY" "$R/$f" 2>/dev/null; then copied="$copied $f"; fi
    done
    if [ -z "$copied" ]; then pass "D15/fragment-body-not-copied"; else fail "D15/fragment-body-not-copied" "copied into:$copied"; fi
else fail "D15/fragment-body-not-copied" "fragment has no body lines to compare"; fi
case_end

# ============================================================================
case_begin "update-docs-uses-criteria-and-promote" "skills/update-docs/SKILL.md"
# ============================================================================
lacks "D16/no-every-term-duty" "$R/skills/update-docs/SKILL.md" 'every term'
has "D16/points-to-glossary-promote" "$R/skills/update-docs/SKILL.md" 'bin/glossary-promote'
has "D16/points-to-glossary-rule" "$R/skills/update-docs/SKILL.md" 'rules/docs/glossary\.md'
case_end

# ============================================================================
case_begin "clarify-intent-has-glossary-step" "skills/clarify-intent/SKILL.md"
# ============================================================================
has "D17/ci-3c-present" "$R/skills/clarify-intent/SKILL.md" '^CI-3c\.'
case_end

# ============================================================================
case_begin "hooks-doc-names-intent-glossary-check" "docs/architecture/claude-code/settings/hooks.md"
# ============================================================================
for h in gate-plan-lang check-plan-lang; do
    body="$(awk -v h="- \`$h.js\`" 'index($0, h) == 1 { on = 1; print; next } on && /^- `/ { exit } on' "$A/settings/hooks.md" 2>/dev/null)"
    if [ -z "$body" ]; then fail "D18/$h-entry-names-glossary" "no '$h.js' entry in settings/hooks.md"
    elif printf '%s\n' "$body" | grep -qi 'glossary' && printf '%s\n' "$body" | grep -qi 'intent'; then pass "D18/$h-entry-names-glossary"
    else fail "D18/$h-entry-names-glossary" "the $h.js entry does not mention the intent glossary check"; fi
done
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
