#!/bin/bash
# tests/hooks/feature-2099-complexity-stage-routing/judge-boundary-live-cases.sh
# Tests: skills/_shared/judge-task-complexity.md, bin/workflow/derive-complexity-level
# Tags: complexity, routing, judge, live-agent, boundary, tl3, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh after judge-threshold-live-cases.sh.
# #2460 retired S1-multi-file and S6-long-plan, so their live boundary pairs
# (JT-11..JT-14) were removed. What remains is deterministic and spends no
# token: the rubric must no longer state either retired numeric threshold.

# Counts, per retired id, the rubric places that state its old numeric rule: the
# id's own heading section, or any line naming the id. Generated blocks stripped.
d2099jb_retired_rule_count() {
    RUBRIC_PATH="$1" run_with_timeout node - 2>&1 <<'JS'
const src = require("fs").readFileSync(process.env.RUBRIC_PATH, "utf8")
  .replace(/<!-- BEGIN GENERATED:[\s\S]*?<!-- END GENERATED: [a-z-]+ -->/g, "");
const lines = src.split(/\r?\n/);
function count(id, unit) {
  const re = new RegExp("[0-9]+\\s*(\\+|or more|or greater)?\\s*" + unit, "i");
  let n = 0, inSection = false;
  for (const l of lines) {
    if (/^#{1,4}\s/.test(l)) { inSection = l.indexOf(id) !== -1; }
    // A line naming another id too (e.g. the S1b rule mentioning its old
    // parent) states that other rule, not the retired one.
    const ids = l.match(/S\d[a-z]?-[A-Za-z][\w-]*/g) || [];
    const solelyNamed = ids.length > 0 && ids.every(function (x) { return x === id; });
    if ((inSection || solelyNamed) && re.test(l)) { n++; }
  }
  return n;
}
console.log("s1_file_rule=" + count("S1-multi-file", "files?") + " s6_line_rule=" + count("S6-long-plan", "lines?"));
JS
}

d2099jb_retired_thresholds_gone() {
    assert_eq "JB-1 the rubric states neither the retired S1-multi-file file count nor the S6-long-plan line count" \
        "s1_file_rule=0 s6_line_rule=0" "$(d2099jb_retired_rule_count "$RUBRIC")"

    # Teeth: the same counter must see a planted copy of each retired rule.
    local probe="$TMPDIR_BASE/rubric-retired-rules.md"
    printf '### S1-multi-file\nEstimated change spans 3 or more files.\n\n### S6-long-plan\nArtifacts exceed 200 lines combined.\n' > "$probe"
    assert_eq "JB-2 the counter flags a planted copy of both retired rules (the check has teeth)" \
        "s1_file_rule=1 s6_line_rule=1" "$(d2099jb_retired_rule_count "$probe")"
}

case_begin "retired-boundary-thresholds-absent" "skills/_shared/judge-task-complexity.md"
d2099jb_retired_thresholds_gone
case_end
