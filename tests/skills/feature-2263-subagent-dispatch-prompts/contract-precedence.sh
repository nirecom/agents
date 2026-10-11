# shellcheck shell=bash
# tests/skills/feature-2263-subagent-dispatch-prompts/contract-precedence.sh
# Tests: agents/web-researcher.md, agents/security-scanner.md, agents/issue-create-survey-worker.md, rules/shell-commands.md
# Tags: TL2, agents, rules, dispatch, output-contract, scope:issue-specific, pwsh-not-required
# Agents whose output contract fixes the exact reply shape must not get a trailing
# Command-form deviations section: each is either write-less exempt (never receives the line)
# or covered by the canonical line's "unless your own output contract fixes..." clause.

FIXED_CONTRACT_ERE='Respond with exactly|No other output|exactly one (output )?line|exactly one of these two|end your reply with exactly'
FIXED_CONTRACT_AGENTS=(
  complexity-judge detail-planner detail-reviewer issue-create-survey-worker outline-planner
  plan-security-reviewer security-scanner test-reviewer web-researcher
)
JSON_INPUT_AGENTS=(issue-create-survey-worker security-scanner web-researcher)

# contract_class <root> <agent> -> exempt | unless | unclassified
contract_class() {
  if [ "$(agent_exempt "$1/agents/$2.md")" = "yes" ]; then printf 'exempt'
  elif [ "$(rule_has_unless "$1/rules/shell-commands.md")" = "yes" ]; then printf 'unless'
  else printf 'unclassified'; fi
}

# input_contract_has_key <agent-md> -> yes|no : the "## Input contract" section names the key
input_contract_has_key() {
  [ -f "$1" ] || { printf 'no'; return; }
  awk '/^## Input contract[[:space:]]*$/ { on = 1; next } on && /^## / { exit } on { print }' "$1" \
    | grep -qF -- "$JSON_KEY" && printf 'yes' || printf 'no'
}

echo "=== contract precedence: fixed-contract agents vs the canonical line ==="
case_begin "CP1-fixed-contract-set" "agents/web-researcher.md"
CP_FOUND="$(grep -lE -- "$FIXED_CONTRACT_ERE" "$SCRIPT_CHECKOUT_ROOT"/agents/*.md 2>/dev/null | sed 's#.*/##; s#\.md$##' | sort | tr '\n' ' ')"
CP_WANT="$(printf '%s\n' "${FIXED_CONTRACT_AGENTS[@]}" | sort | tr '\n' ' ')"
ck "CP1: the 9-agent fixed-contract list matches the agents whose prompt fixes the reply shape" "$CP_WANT" "$CP_FOUND"
ck "CP1: fixed-contract agent count" "9" "${#FIXED_CONTRACT_AGENTS[@]}"
case_end

case_begin "CP2-classification" "rules/shell-commands.md"
for a in "${FIXED_CONTRACT_AGENTS[@]}"; do
  ROWS=$((ROWS + 1))
  want="unless"; [ "$a" = "complexity-judge" ] && want="exempt"
  ck "CP2: $a is classified (exempt by tools, or covered by the canonical line's unless clause)" \
    "$want" "$(contract_class "$SCRIPT_CHECKOUT_ROOT" "$a")"
done
case_end

case_begin "CP3-json-input-agents" "agents/issue-create-survey-worker.md"
CP_JSON_FOUND="$(grep -lF -- 'Receive a JSON object' "$SCRIPT_CHECKOUT_ROOT"/agents/*.md 2>/dev/null | sed 's#.*/##; s#\.md$##' | sort | tr '\n' ' ')"
ck "CP3: JSON-input agent set" "$(printf '%s\n' "${JSON_INPUT_AGENTS[@]}" | sort | tr '\n' ' ')" "$CP_JSON_FOUND"
for a in "${JSON_INPUT_AGENTS[@]}"; do
  ck "CP3: agents/$a.md lists $JSON_KEY in its ## Input contract" "yes" \
    "$(input_contract_has_key "$SCRIPT_CHECKOUT_ROOT/agents/$a.md")"
done
case_end

# Why complexity-judge must stay exempt: a trailing deviations section degrades its verdict.
case_begin "CP4-judge-trailer-degrades" "agents/web-researcher.md"
CP_NORM="$(node -e '
  const n = require(process.argv[1]).normalize;
  console.log([n("SIGNALS: none"), n("SIGNALS: none\n\n## Command-form deviations\n\n0")].map(JSON.stringify).join(" "));
' "$(np "$SCRIPT_CHECKOUT_ROOT/bin/workflow/normalize-judge-signals")" 2>&1)"
ck "CP4: SIGNALS: none alone -> empty CSV; with a deviations trailer -> S0-undecidable" '"" "S0-undecidable"' "$CP_NORM"
case_end
