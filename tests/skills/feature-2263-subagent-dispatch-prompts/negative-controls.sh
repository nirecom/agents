# shellcheck shell=bash
# tests/skills/feature-2263-subagent-dispatch-prompts/negative-controls.sh
# Tests: rules/shell-commands.md, agents/web-researcher.md
# Tags: TL2, skills, agents, dispatch, negative-control, scope:issue-specific, pwsh-not-required
# Fixture trees prove each predicate the other parts use can say both yes and no, so a
# green real-tree run is never a vacuous pass.

NC="$TMPROOT/nc"
mkdir -p "$NC/skills/s" "$NC/agents" "$NC/rules"
nc_skill() { printf '%s\n' "$@" > "$NC/skills/s/SKILL.md"; }
nc_agent() { printf -- '---\nname: %s\ntools: %s\n---\n%s\n' "$1" "$2" "${3:-body}" > "$NC/agents/$1.md"; }
nc_rule() { printf '# R\n\n## Subagent Dispatch Prompts\n\n%s\n\n## Next\n' "$1" > "$NC/rules/shell-commands.md"; }

echo "=== negative controls: fixtures exercise every verdict ==="
case_begin "NC-inventory-verdicts" "rules/shell-commands.md"
nc_skill 'X-1. **Launch subagent** (Agent tool) with:' '   - follow `rules/shell-commands.md` Subagent Dispatch Prompts'
ck "NC-INV: good reference -> yes" "yes" "$(inv_verdict "$NC" skills/s/SKILL.md '^X-1\. ' 0 2 plain)"
ck "NC-INV: anchor absent -> anchor-missing" "anchor-missing" "$(inv_verdict "$NC" skills/s/SKILL.md '^X-9\. ' 0 2 plain)"
ck "NC-INV: missing file -> file-missing" "file-missing" "$(inv_verdict "$NC" skills/none/SKILL.md '^X-1\. ' 0 2 plain)"
ck "NC-INV: json form without the key -> no-json-key" "no-json-key" "$(inv_verdict "$NC" skills/s/SKILL.md '^X-1\. ' 0 2 json)"
nc_skill 'X-1. **Launch subagent** (Agent tool) with:' '   - follow Subagent Dispatch Prompts and set `dispatch_directive`'
ck "NC-INV: json form with the key -> yes" "yes" "$(inv_verdict "$NC" skills/s/SKILL.md '^X-1\. ' 0 2 json)"
nc_skill 'X-1. **Launch subagent** (Agent tool) with:' '   - a prompt'
ck "NC-INV: no reference line -> no-ref" "no-ref" "$(inv_verdict "$NC" skills/s/SKILL.md '^X-1\. ' 0 2 plain)"
nc_skill 'X-1. **Launch subagent** (Agent tool) with:' '   - follow the Subagent Dispatch Prompt section'
ck "NC-INV: wrong section name -> no-ref" "no-ref" "$(inv_verdict "$NC" skills/s/SKILL.md '^X-1\. ' 0 2 plain)"
nc_skill 'X-1. **Launch subagent** (Agent tool) with:' 'a' 'b' 'c' 'Subagent Dispatch Prompts'
ck "NC-INV: reference outside the window -> no-ref" "no-ref" "$(inv_verdict "$NC" skills/s/SKILL.md '^X-1\. ' 0 2 plain)"
case_end

case_begin "NC-detection" "rules/shell-commands.md"
nc_skill 'X-1. **Launch subagent** (Agent tool) with:' 'Dispatch `subagent_type: brand-new` here.'
NC_ROWS=('skills/s/SKILL.md|^X-1\. |excl:fixture')
ck "NC-DET: a new subagent_type line without a row is reported" "skills/s/SKILL.md:2" \
  "$(det_uncovered "$NC" NC_ROWS | tr '\n' ' ' | sed 's/ $//')"
NC_ROWS+=('skills/s/SKILL.md|subagent_type: brand-new|excl:fixture')
ck "NC-DET: adding its row covers it" "" "$(det_uncovered "$NC" NC_ROWS | tr '\n' ' ')"
nc_skill 'X-1. Launch the subagent; see Subagent Dispatch Prompts' 'plain text'
ck "NC-DET: a line naming the section is a reference, not a hit" "" "$(det_hits "$NC" | tr '\n' ' ')"
ck "NC-DET: a row whose ERE matches nothing is stale" "stale" \
  "$(det_row_verdict "$NC" 'skills/s/SKILL.md|^gone line$|excl:fixture')"
ck "NC-DET: an unknown inventory id is rejected" "bad-inv:99" \
  "$(det_row_verdict "$NC" 'skills/s/SKILL.md|plain text|inv:99')"
ck "NC-DET: an empty disposition is rejected" "bad-disposition" \
  "$(det_row_verdict "$NC" 'skills/s/SKILL.md|plain text|excl:')"
nc_agent fx-judge 'Read, Glob, Bash'
ck "NC-DET: an exempt agent that gained Bash fails its exemption" "not-exempt:fx-judge" \
  "$(det_row_verdict "$NC" 'skills/s/SKILL.md|plain text|exempt:fx-judge')"
nc_agent fx-judge 'Read, Glob'
ck "NC-DET: a Read/Glob-only agent keeps its exemption" "ok" \
  "$(det_row_verdict "$NC" 'skills/s/SKILL.md|plain text|exempt:fx-judge')"
case_end

case_begin "NC-contract-class" "agents/web-researcher.md"
nc_agent fx-worker 'Bash, Read' 'Respond with exactly three lines:'
nc_rule 'Read `<AGENTS_MAIN_ROOT>/rules/shell-commands.md` before the first Bash command and end with a `Command-form deviations` section.'
ck "NC-CP: Bash agent + rule without the unless clause -> unclassified" "unclassified" "$(contract_class "$NC" fx-worker)"
nc_rule 'Read `<AGENTS_MAIN_ROOT>/rules/shell-commands.md` first, and end with a `Command-form deviations` section unless your own output contract fixes the exact shape of your reply.'
ck "NC-CP: Bash agent + rule with the unless clause -> unless" "unless" "$(contract_class "$NC" fx-worker)"
nc_agent fx-worker 'Read'
ck "NC-CP: Read-only agent -> exempt" "exempt" "$(contract_class "$NC" fx-worker)"
nc_rule 'Some other line unless your own output contract fixes the exact shape of your reply.'
ck "NC-CP: the clause on a non-canonical line does not count" "no" "$(rule_has_unless "$NC/rules/shell-commands.md")"
printf -- '---\nname: j\ntools: Read\n---\n## Input contract\n\nReceive a JSON object with: `topic`\n\n## Output\n\ndispatch_directive\n' > "$NC/agents/fx-json.md"
ck "NC-CP: key only outside ## Input contract -> no" "no" "$(input_contract_has_key "$NC/agents/fx-json.md")"
printf -- '---\nname: j\ntools: Read\n---\n## Input contract\n\n- `dispatch_directive`: string\n' > "$NC/agents/fx-json.md"
ck "NC-CP: key inside ## Input contract -> yes" "yes" "$(input_contract_has_key "$NC/agents/fx-json.md")"
case_end
