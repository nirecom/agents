#!/bin/bash
# tests/hooks/feature-2099-complexity-stage-routing/rubric-table-consistency.sh
# Tests: skills/_shared/judge-task-complexity.md, hooks/workflow-state/complexity-routing.js, bin/workflow/derive-complexity-level
# Tags: complexity, routing, rubric, docs-code-consistency, mutation-probe, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.
# Two layers (detail.md D5): L1 byte-compares the generated blocks; L2 parses the
# HAND-WRITTEN signal-definition headings, which L1 is structurally blind to.
# lang-check: ignore -- asserts the rubric's bilingual (English/Japanese) threshold wording

# Extract a named generated block's inner body from a markdown file.
d2099_extract_block() {
    DOC="$1" BLOCK="$2" run_with_timeout node - 2>&1 <<'JS'
const fs = require("fs");
const name = process.env.BLOCK;
const src = fs.readFileSync(process.env.DOC, "utf8");
const begin = "<!-- BEGIN GENERATED: " + name + " -->";
const end = "<!-- END GENERATED: " + name + " -->";
const i = src.indexOf(begin);
const j = src.indexOf(end);
if (i === -1 || j === -1 || j < i) { process.stdout.write("BLOCK_NOT_FOUND"); process.exit(0); }
process.stdout.write(src.slice(i + begin.length, j).replace(/^\n+/, "").replace(/\n+$/, ""));
JS
}

# Collect the signal ids used as hand-written definition headings, ignoring
# anything inside a generated block.
d2099_rubric_heading_ids() {
    DOC="$1" run_with_timeout node - 2>&1 <<'JS'
const fs = require("fs");
const src = fs.readFileSync(process.env.DOC, "utf8");
const stripped = src.replace(/<!-- BEGIN GENERATED:[\s\S]*?<!-- END GENERATED: [a-z-]+ -->/g, "");
const ids = [];
for (const line of stripped.split(/\r?\n/)) {
  const m = line.match(/^#{2,4}\s+(S\d[a-z]?-[A-Za-z][\w-]*)\s*$/);
  if (m) ids.push(m[1]);
}
process.stdout.write(ids.sort().join(","));
JS
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
    # RB-8: the NORMATIVE WORDING, not the id token. S1b-wide-change is computed
    # deterministically (#2460), so the rubric keeps its 8-file threshold but no
    # longer carries judge guidance about falling back to (retired) S1-multi-file
    # or leaning toward S1b when uncertain. The alternations only tolerate
    # phrasing/locale, never the absence of the rule.
    local guidance
    guidance=$(RUBRIC_PATH="$RUBRIC" run_with_timeout node -e '
const src = require("fs").readFileSync(process.env.RUBRIC_PATH, "utf8");
// detail.md D2: the S1b trigger is "8 files or more".
const THRESHOLD = /(8\s*(\+|or more)?\s*files? or more|8\s*or more files|at least 8 files|8\+\s*files|8\s*files or more|8ファイル以上)/i;
// Retired judge guidance: the uncertain case falling back to S1-multi-file.
const UNCERTAIN_FALLBACK = /(uncertain|not certain|unsure|cannot be (precisely )?determined|不確実)[^.\n]{0,120}S1-multi-file/i;
// Older guidance (uncertain => lean toward S1b) must stay gone.
const OLD_LEANS_TO_S1B = /(uncertain|unsure|cannot be (precisely )?determined|不確実)[^.\n]{0,120}S1b-wide-change/i;
console.log([
  "threshold=" + (THRESHOLD.test(src) ? "yes" : "no"),
  "uncertain_falls_back_to_S1=" + (UNCERTAIN_FALLBACK.test(src) ? "yes" : "no"),
  "old_leans_to_S1b=" + (OLD_LEANS_TO_S1B.test(src) ? "yes" : "no"),
].join(" "));
' 2>&1)
    assert_eq "RB-8 the rubric keeps the 8-file S1b threshold and drops the judge-side S1 fallback guidance" \
        "threshold=yes uncertain_falls_back_to_S1=no old_leans_to_S1b=no" \
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

# L3 (#2460): the rubric's end-state structure. S1/S6 sections are gone, the
# rules are split by audience, and S1b/S4 are described as code-computed.
d2099_rubric_layer3() {
    local doc_ids
    doc_ids=",$(d2099_rubric_heading_ids "$RUBRIC"),"
    assert_not_contains "RB-13 the rubric has no S1-multi-file definition section" \
        ",S1-multi-file," "$doc_ids"
    assert_not_contains "RB-14 the rubric has no S6-long-plan definition section" \
        ",S6-long-plan," "$doc_ids"

    local headings
    headings=$(RUBRIC_PATH="$RUBRIC" run_with_timeout node - 2>&1 <<'JS'
const lines = require("fs").readFileSync(process.env.RUBRIC_PATH, "utf8").split(/\r?\n/);
function has(h) { return lines.some(function (l) { return l.trim() === h; }) ? "yes" : "no"; }
console.log(["judgment_rules=" + has("## Judgment rules"), "output_rules=" + has("## Output rules"), "plain_rules=" + has("## Rules")].join(" "));
JS
)
    assert_eq "RB-15 the rubric splits its rules into Judgment rules and Output rules headings" \
        "judgment_rules=yes output_rules=yes plain_rules=no" "$headings"

    # S1b/S4 are deterministic: the word must appear in the id's own definition
    # section or on a line naming the id.
    local det
    det=$(RUBRIC_PATH="$RUBRIC" run_with_timeout node - 2>&1 <<'JS'
const src = require("fs").readFileSync(process.env.RUBRIC_PATH, "utf8")
  .replace(/<!-- BEGIN GENERATED:[\s\S]*?<!-- END GENERATED: [a-z-]+ -->/g, "");
const lines = src.split(/\r?\n/);
function described(id) {
  const start = lines.findIndex(function (l) { return /^#{2,4}\s/.test(l) && l.indexOf(id) !== -1; });
  if (start !== -1) {
    let end = lines.length;
    for (let i = start + 1; i < lines.length; i++) { if (/^#{2,4}\s/.test(lines[i])) { end = i; break; } }
    if (/deterministic/i.test(lines.slice(start, end).join("\n"))) { return "yes"; }
  }
  return lines.some(function (l) { return l.indexOf(id) !== -1 && /deterministic/i.test(l); }) ? "yes" : "no";
}
console.log("S1b=" + described("S1b-wide-change") + " S4=" + described("S4-installer"));
JS
)
    assert_eq "RB-16 the rubric describes S1b-wide-change and S4-installer as deterministic" \
        "S1b=yes S4=yes" "$det"
}

case_begin "rubric-generated-blocks-and-wording" "skills/_shared/judge-task-complexity.md"
d2099_rubric_layer1
case_end

case_begin "rubric-headings-match-signal-ids" "hooks/workflow-state/complexity-routing.js"
d2099_rubric_layer2
case_end

case_begin "rubric-end-state-structure" "skills/_shared/judge-task-complexity.md"
d2099_rubric_layer3
case_end
