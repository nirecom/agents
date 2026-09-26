# shellcheck shell=bash
# Tests: bin/review-doc-heading-order, rules/docs/readme.md
# Tags: TL2, docs, review-docs, staged, git, ssot, scope:issue-specific, pwsh-not-required
#
# GROUP B: the README section-order gate. Canonical order + alias map is the SSOT
# in rules/docs/readme.md (readme-section-order:start/end block); the tool reads
# it, never hardcodes. --staged blocks (exit 1) on an inverted order; --all is
# advisory. Fixtures use canonical labels: What / Quickstart / Usage / Configuration.

# stage_readme <repo> <heading-lines...> — README.md with exactly these H2
# sections in order, staged.
stage_readme() {
  local repo="$1"; shift
  local f="$repo/README.md" h
  {
    echo "# Project"
    echo ""
    for h in "$@"; do
      echo "## $h"
      echo ""
      echo "body of $h"
      echo ""
    done
  } > "$f"
  git -C "$repo" add README.md >/dev/null 2>&1
}

run_group_b() {
  # B1: SSOT existence — rules/docs/readme.md carries a well-formed
  # readme-section-order block, the source-of-truth the tool parses.
  local ssot="$AGENTS_DIR/rules/docs/readme.md"
  if grep -qF -- "<!-- readme-section-order:start -->" "$ssot" 2>/dev/null \
     && grep -qF -- "<!-- readme-section-order:end -->" "$ssot" 2>/dev/null; then
    pass "B1: rules/docs/readme.md declares a readme-section-order SSOT block"
  else
    fail "B1: SSOT MISSING — rules/docs/readme.md has no readme-section-order:start/end block (not yet implemented)"
  fi

  # B1-SSOT-ORDER: verify the canonical ORDER inside the SSOT block directly, not
  # just the markers' presence. intent.md pins "Why/Quickstart before Configuration",
  # so BOTH the what/why class and quickstart must precede configuration — asserting
  # quickstart alone would miss a What-after-Configuration inversion. Scoped to the
  # block between the markers so unrelated prose does not match.
  local ssot_block what_ln qs_ln cfg_ln
  ssot_block="$(awk '/readme-section-order:start/{f=1;next} /readme-section-order:end/{f=0} f' "$ssot" 2>/dev/null)"
  what_ln="$(printf '%s\n' "$ssot_block" | grep -in -- "what" | head -1 | cut -d: -f1)"
  qs_ln="$(printf '%s\n' "$ssot_block" | grep -in -- "quickstart" | head -1 | cut -d: -f1)"
  cfg_ln="$(printf '%s\n' "$ssot_block" | grep -in -- "configuration" | head -1 | cut -d: -f1)"
  if [ -n "$what_ln" ] && [ -n "$qs_ln" ] && [ -n "$cfg_ln" ] \
     && [ "$what_ln" -lt "$cfg_ln" ] && [ "$qs_ln" -lt "$cfg_ln" ]; then
    pass "B1-SSOT-ORDER: SSOT block lists what & quickstart before configuration"
  else
    fail "B1-SSOT-ORDER: SSOT block must list what & quickstart before configuration (what=[$what_ln] qs=[$qs_ln] cfg=[$cfg_ln]) — not yet implemented"
  fi

  require_bin "B" "bin/review-doc-heading-order" || return 0
  local repo

  # B2: canonical order staged → no violation.
  repo="$(new_doc_repo)"
  stage_readme "$repo" "What" "Quickstart" "Usage" "Configuration"
  run_tool "$repo" "bin/review-doc-heading-order" --staged
  assert_eq "B2: correct heading order staged → --staged exits 0" "0" "$TOOL_RC"

  # B3: Configuration before Quickstart is inverted → violation.
  repo="$(new_doc_repo)"
  stage_readme "$repo" "What" "Configuration" "Quickstart" "Usage"
  run_tool "$repo" "bin/review-doc-heading-order" --staged
  assert_eq "B3: Configuration before Quickstart staged → --staged exits 1" "1" "$TOOL_RC"

  # B4: --all is advisory even on an inverted order on disk.
  repo="$(new_doc_repo)"
  stage_readme "$repo" "Configuration" "Quickstart"
  run_tool "$repo" "bin/review-doc-heading-order" --all
  assert_eq "B4: wrong order on disk → --all exits 0 (advisory)" "0" "$TOOL_RC"

  # B5: README not in the staged diff → nothing to check, SKIP.
  repo="$(new_doc_repo)"
  gen_md "$repo/notes.md" 20
  git -C "$repo" add notes.md >/dev/null 2>&1
  run_tool "$repo" "bin/review-doc-heading-order" --staged
  assert_eq "B5: README not staged → --staged exits 0 (SKIP)" "0" "$TOOL_RC"

  # B6: alias match — "Quick Start" (with a space) resolves to quickstart, so
  # the order stays canonical and does not fire.
  repo="$(new_doc_repo)"
  stage_readme "$repo" "What" "Quick Start" "Usage" "Configuration"
  run_tool "$repo" "bin/review-doc-heading-order" --staged
  assert_eq "B6: 'Quick Start' alias matches quickstart → --staged exits 0" "0" "$TOOL_RC"

  # B7: an unknown heading (in no alias table) is skipped, not a violation.
  repo="$(new_doc_repo)"
  stage_readme "$repo" "What" "Quickstart" "Frequently Asked Questions" "Usage" "Configuration"
  run_tool "$repo" "bin/review-doc-heading-order" --staged
  assert_eq "B7: unknown heading is skipped, not a violation → --staged exits 0" "0" "$TOOL_RC"

  # --- B-NEW: table-driven canonical / alias / duplicate coverage (#2340 gap C3) ---
  # Vocabulary is this repo's committed SSOT (What / Quickstart / Usage /
  # Configuration), same as B2-B7 — NOT a foreign Overview/Examples/API-Reference
  # set. Each row: "<comma-separated H2 headings>|<expected exit>|<description>".
  # Alias rows assert normalization is whitespace- AND case-insensitive (B6 proves
  # whitespace; case is the orthogonal sibling — aliases map to the same class).
  local -a b_rows=(
    "What|0|B-NEW-1: canonical 'What' alone → --staged exits 0"
    "Quickstart|0|B-NEW-2: canonical 'Quickstart' alone → --staged exits 0"
    "Usage|0|B-NEW-3: canonical 'Usage' alone → --staged exits 0"
    "Configuration|0|B-NEW-4: canonical 'Configuration' alone → --staged exits 0"
    "What,Quickstart,Usage,Configuration|0|B-NEW-5: full canonical order → --staged exits 0"
    "Quick Start|0|B-NEW-6: alias 'Quick Start' (spaced) → quickstart, exits 0"
    "quickstart|0|B-NEW-7: alias 'quickstart' (lowercase) → quickstart, exits 0"
    "QUICKSTART|0|B-NEW-8: alias 'QUICKSTART' (uppercase) → quickstart, exits 0"
    "what,quickstart,usage,configuration|0|B-NEW-9: full order, all lowercase → exits 0"
    "Configuration,Usage|1|B-NEW-10: Configuration before Usage → inverted, exits 1"
    "Usage,Usage|1|B-NEW-dup: two headings of the same class (Usage) → violation, exits 1"
  )
  local b_row b_headings b_expect b_desc
  local -a b_hs
  for b_row in "${b_rows[@]}"; do
    IFS='|' read -r b_headings b_expect b_desc <<< "$b_row"
    IFS=',' read -r -a b_hs <<< "$b_headings"
    repo="$(new_doc_repo)"
    stage_readme "$repo" "${b_hs[@]}"
    run_tool "$repo" "bin/review-doc-heading-order" --staged
    assert_eq "$b_desc" "$b_expect" "$TOOL_RC"
  done
}
