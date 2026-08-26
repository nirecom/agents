#!/bin/bash
# tests/feature-2099-complexity-stage-routing/rubric-table-consistency.sh
# Tests: skills/_shared/judge-task-complexity.md, hooks/workflow-state/complexity-routing.js, bin/workflow/derive-complexity-level
# Tags: complexity, routing, rubric, docs-code-consistency, mutation-probe, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.
# Two layers (detail.md D5): L1 byte-compares the generated blocks; L2 parses the
# HAND-WRITTEN signal-definition headings, which L1 is structurally blind to.
# lang-check: ignore -- asserts the rubric's bilingual (English/Japanese) threshold wording

# Extract a named generated block's inner body from a markdown file.
d2099_extract_block() {
    DOC="$1" BLOCK="$2" run_with_timeout node -e '
const fs = require("fs");
const name = process.env.BLOCK;
const src = fs.readFileSync(process.env.DOC, "utf8");
const begin = "<!-- BEGIN GENERATED: " + name + " -->";
const end = "<!-- END GENERATED: " + name + " -->";
const i = src.indexOf(begin);
const j = src.indexOf(end);
if (i === -1 || j === -1 || j < i) { process.stdout.write("BLOCK_NOT_FOUND"); process.exit(0); }
process.stdout.write(src.slice(i + begin.length, j).replace(/^\n+/, "").replace(/\n+$/, ""));
' 2>&1
}

# Collect the signal ids used as hand-written definition headings, ignoring
# anything inside a generated block.
d2099_rubric_heading_ids() {
    DOC="$1" run_with_timeout node -e '
const fs = require("fs");
const src = fs.readFileSync(process.env.DOC, "utf8");
const stripped = src.replace(/<!-- BEGIN GENERATED:[\s\S]*?<!-- END GENERATED: [a-z-]+ -->/g, "");
const ids = [];
for (const line of stripped.split(/\r?\n/)) {
  const m = line.match(/^#{2,4}\s+(S\d[a-z]?-[A-Za-z][\w-]*)\s*$/);
  if (m) ids.push(m[1]);
}
process.stdout.write(ids.sort().join(","));
' 2>&1
}

d2099_rubric_layer1() {
    local generated doc_block
    generated=$(run_with_timeout node "$BIN_DERIVE" --print-markdown-table 2>&1)
    doc_block=$(d2099_extract_block "$RUBRIC" "stage-routing")
    assert_eq "RB-1 the stage-routing block in the rubric is byte-identical to renderStageRoutingMarkdown()" \
        "$generated" "$doc_block"

    generated=$(run_with_timeout node "$BIN_DERIVE" --print-signal-ids 2>&1)
    doc_block=$(d2099_extract_block "$RUBRIC" "signal-ids")
    assert_eq "RB-2 the signal-ids block in the rubric is byte-identical to renderSignalIdsMarkdown()" \
        "$generated" "$doc_block"

    # The renderers must be the same code path the module exports, not a CLI copy.
    local got
    got=$(run_node '
const m = require(process.env.CR_MOD_N);
const t = m.renderStageRoutingMarkdown();
const s = m.renderSignalIdsMarkdown();
console.log([
  /legacy_equivalent_escalation/.test(t) ? "HAS_LEGACY_COL" : "NO_LEGACY_COL",
  /combination_escalation/.test(t) ? "HAS_COMBO_COL" : "NO_COMBO_COL",
  /solo_escalation/.test(t) ? "HAS_SOLO_COL" : "NO_SOLO_COL",
  s.indexOf(m.UNDECIDABLE_SIGNAL) !== -1 ? "LISTS_UNDECIDABLE" : "OMITS_UNDECIDABLE",
].join(" "));
')
    assert_eq "RB-3 the generated table renders the three D2 escalation fields as separate columns" \
        "HAS_LEGACY_COL HAS_COMBO_COL HAS_SOLO_COL LISTS_UNDECIDABLE" "$got"

    local rubric_text
    rubric_text=$(cat "$RUBRIC")
    assert_not_contains "RB-4 the old single-threshold Routing Rule section is gone from the rubric" \
        "## Routing Rule" "$rubric_text"
    assert_not_contains "RB-5 the rubric no longer instructs the agent to emit a LEVEL line" \
        "LEVEL: high |" "$rubric_text"
    assert_contains "RB-6 the rubric's output format is the signals-only SIGNALS line" \
        "SIGNALS:" "$rubric_text"
    assert_contains "RB-7 the rubric points at complexity-routing.js as the routing authority" \
        "complexity-routing.js" "$rubric_text"
    # RB-8: the NORMATIVE WORDING, not the id token. RB-9 already guarantees the
    # bare `S1b-wide-change` string exists as a definition heading, so asserting
    # the token here would pass even if the threshold sentence and the inverted
    # guidance were both deleted. Each probe below is a separate regex over the
    # rubric prose; the alternations only tolerate phrasing/locale, never the
    # absence of the rule.
    local guidance
    guidance=$(RUBRIC_PATH="$RUBRIC" run_with_timeout node -e '
const src = require("fs").readFileSync(process.env.RUBRIC_PATH, "utf8");
// detail.md D2: the S1b trigger is "8 files or more".
const THRESHOLD = /(8\s*(\+|or more)?\s*files? or more|8\s*or more files|at least 8 files|8\+\s*files|8\s*files or more|8ファイル以上)/i;
// detail.md D2 (reversed guidance): assign S1b ONLY when certain.
const ONLY_WHEN_CERTAIN = /(only (when|if)[^.\n]{0,80}(certain|confident|sure|known)|(certain|confident|sure)[^.\n]{0,80}only|確実に[^。\n]{0,60}場合のみ)/i;
// ... and the uncertain case falls back to S1-multi-file alone.
const UNCERTAIN_FALLBACK = /(uncertain|not certain|unsure|cannot be (precisely )?determined|不確実)[^.\n]{0,120}S1-multi-file/i;
// The OLD guidance (uncertain => lean toward S1b) must be gone: it would undo
// the whole write_tests threshold raise.
const OLD_LEANS_TO_S1B = /(uncertain|unsure|cannot be (precisely )?determined|不確実)[^.\n]{0,120}S1b-wide-change/i;
console.log([
  "threshold=" + (THRESHOLD.test(src) ? "yes" : "no"),
  "only_when_certain=" + (ONLY_WHEN_CERTAIN.test(src) ? "yes" : "no"),
  "uncertain_falls_back_to_S1=" + (UNCERTAIN_FALLBACK.test(src) ? "yes" : "no"),
  "old_leans_to_S1b=" + (OLD_LEANS_TO_S1B.test(src) ? "yes" : "no"),
].join(" "));
' 2>&1)
    assert_eq "RB-8 the rubric states the 8-file threshold AND the inverted (only-when-certain) S1b guidance" \
        "threshold=yes only_when_certain=yes uncertain_falls_back_to_S1=yes old_leans_to_S1b=no" \
        "$guidance"

    # Teeth probe for RB-8: deleting the threshold sentence must break it. Without
    # this, a regex too loose to notice the deletion would still report yes.
    local stripped stripped_out
    stripped="$TMPDIR_BASE/rubric-no-threshold.md"
    sed -E 's/8( or more|\+)? ?files?( or more)?/several files/Ig; s/8ファイル以上/複数ファイル/g' "$RUBRIC" > "$stripped"
    stripped_out=$(RUBRIC_PATH="$stripped" run_with_timeout node -e '
const src = require("fs").readFileSync(process.env.RUBRIC_PATH, "utf8");
const THRESHOLD = /(8\s*(\+|or more)?\s*files? or more|8\s*or more files|at least 8 files|8\+\s*files|8\s*files or more|8ファイル以上)/i;
console.log(THRESHOLD.test(src) ? "yes" : "no");
' 2>&1)
    assert_eq "RB-8b removing the threshold wording actually breaks the RB-8 threshold probe" \
        "no" "$stripped_out"
}

# L2 (R3-C3): the hand-written definition headings must exactly cover
# SIGNAL_IDS + UNDECIDABLE_SIGNAL. A mutation probe proves the check can fail.
d2099_rubric_layer2() {
    local code_ids doc_ids
    code_ids=$(run_node '
const m = require(process.env.CR_MOD_N);
process.stdout.write(m.SIGNAL_IDS.concat([m.UNDECIDABLE_SIGNAL]).sort().join(","));
')
    doc_ids=$(d2099_rubric_heading_ids "$RUBRIC")
    assert_eq "RB-9 the rubric's hand-written signal headings match SIGNAL_IDS + UNDECIDABLE_SIGNAL" \
        "$code_ids" "$doc_ids"

    # Mutation probe 1: a typo'd heading must change the extracted set.
    local mutant
    mutant="$TMPDIR_BASE/rubric-typo.md"
    sed 's/^### S3-security$/### S3-securty/' "$RUBRIC" > "$mutant"
    local mutated_ids
    mutated_ids=$(d2099_rubric_heading_ids "$mutant")
    if [ "$mutated_ids" = "$code_ids" ]; then
        fail "RB-10 layer-2 parser is blind to a typo'd signal heading (extractor found: $mutated_ids)"
    else
        pass "RB-10 layer-2 parser detects a typo'd signal heading"
    fi

    # Mutation probe 2: a deleted heading must change the extracted set too.
    mutant="$TMPDIR_BASE/rubric-drop.md"
    grep -v '^### S4-installer$' "$RUBRIC" > "$mutant"
    mutated_ids=$(d2099_rubric_heading_ids "$mutant")
    if [ "$mutated_ids" = "$code_ids" ]; then
        fail "RB-11 layer-2 parser is blind to a deleted signal heading (extractor found: $mutated_ids)"
    else
        pass "RB-11 layer-2 parser detects a deleted signal heading"
    fi

    # The rubric is a prompt file: rules/coding/file-split.md HARD limit is 200.
    local lines
    lines=$(wc -l < "$RUBRIC" | tr -d ' ')
    if [ "$lines" -le 200 ]; then
        pass "RB-12 the rubric stays under the 200-line prompt HARD limit ($lines lines)"
    else
        fail "RB-12 the rubric exceeds the 200-line prompt HARD limit ($lines lines)"
    fi
}

d2099_rubric_layer1
d2099_rubric_layer2
