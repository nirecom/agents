#!/usr/bin/env bash
# Tests: agents/supervisor-audit.md, bin/supervisor-findings-codex, docs/architecture/claude-code/supervisor-codex-input.md
# Tags: scope:issue-specific, TL1, supervisor-audit, pre-confirm-audit, test-lang-exception:text-only
# #2853: audit criterion 1 first asks whether the decisions taken in the conversation and in the
# AskUserQuestion answers reached the plan, then cross-stage coherence; the three places that state it
# put the aspects in the same order.
# Canonical phrase (all three places, case-insensitive, backticks ignored): decisions made in the conversation and AskUserQuestion answers are reflected in the plan
# TL3 gap: text-only; whether a real audit run applies the criterion needs a live codex / Claude Code session.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/harness.sh"

AGENT="$ROOT/agents/supervisor-audit.md"
CODEX="$ROOT/bin/supervisor-findings-codex"
DOC="$ROOT/docs/architecture/claude-code/supervisor-codex-input.md"

# Aspect tokens, in the order criterion 1 must state them: the conversation aspect (conversation,
# AskUserQuestion answers) before the coherence aspect.
ASPECTS=("conversation" "AskUserQuestion" "coherence")
EXPECTED_ORDER="conversation,AskUserQuestion,coherence"

# first_at <text> <token>: character offset of the token's first case-insensitive match, or -1.
# Pure parameter expansion: Git-for-Windows grep aborts on -o -i over multibyte text.
first_at() {
  local hay="${1,,}" needle="${2,,}" head
  head="${hay%%"$needle"*}"
  if [[ "$head" == "$hay" ]]; then printf '%s' "-1"; else printf '%s' "${#head}"; fi
}

# aspect_order <text>: the aspect tokens present in the text, sorted by first occurrence, comma-joined.
aspect_order() {
  local text="$1" tok at
  for tok in "${ASPECTS[@]}"; do
    at="$(first_at "$text" "$tok")"
    [[ "$at" -ge 0 ]] && printf '%s %s\n' "$at" "$tok"
  done | sort -n | cut -d' ' -f2 | paste -sd, -
}

# check_order <label> <text>: every aspect is present and the conversation aspect precedes coherence.
check_order() {
  local label="$1" text="$2" got
  got="$(aspect_order "$text")"
  if [[ "$got" == "$EXPECTED_ORDER" ]]; then pass "$label orders $EXPECTED_ORDER"; else fail "$label orders $EXPECTED_ORDER" "got [$got] in: $text"; fi
}

PHRASE="decisions made in the conversation and AskUserQuestion answers are reflected in the plan"

# phrase_then_coherence <text>: 0 when the text (backticks stripped) holds PHRASE and a later "coherence".
phrase_then_coherence() {
  local text="${1//\`/}" p c
  p="$(first_at "$text" "$PHRASE")"
  [[ "$p" -ge 0 ]] || return 1
  c="$(first_at "${text:$((p + ${#PHRASE}))}" "coherence")"
  [[ "$c" -ge 0 ]]
}

# check_phrase <label> <text>: the canonical phrase is present and precedes the coherence aspect.
check_phrase() {
  local label="$1" text="$2"
  if phrase_then_coherence "$text"; then pass "$label states the canonical phrase before coherence"; else fail "$label states the canonical phrase before coherence" "in: $text"; fi
}

crit1="$(sed -n '/^## Decision criteria/,/^## /p' "$AGENT" | grep -E '^1\. \*\*')"
audit_prompt="$(sed -n '/if \[\[ "\$MODE" == "alert" \]\]; then/,/^fi/p' "$CODEX" | sed -n '/^else/,/^fi/p')"
codex_crit="$(printf '%s\n' "$audit_prompt" | grep -E "CODEX_PROMPT\+=.*coherence")"
codex_all="$(printf '%s\n' "$audit_prompt" | grep -E "CODEX_PROMPT\+=" | paste -sd' ' -)"
doc_line="$(grep -E '^- Audit ' "$DOC")"

case_begin "agent criterion 1 states the conversation aspect before coherence" "agents/supervisor-audit.md"
probe_ok="$(aspect_order "Conversation drift: are AskUserQuestion answers in the plan? Then cross-stage coherence.")"
probe_rev="$(aspect_order "Cross-stage coherence, then conversation and AskUserQuestion answers.")"
[[ "$probe_ok" == "$EXPECTED_ORDER" && "$probe_rev" != "$EXPECTED_ORDER" ]] && pass "order probe tells the two orders apart" || fail "order probe tells the two orders apart" "ok=[$probe_ok] rev=[$probe_rev]"
[[ -n "$crit1" ]] && pass "criterion 1 line present" || fail "criterion 1 line present"
check_order "agent criterion 1" "$crit1"
probe_p_ok=0; probe_p_rev=0; probe_p_none=0
phrase_then_coherence "Are \`Decisions made in the conversation and AskUserQuestion answers are reflected in the plan\`? Then coherence." && probe_p_ok=1
phrase_then_coherence "Cross-stage coherence; decisions made in the conversation and AskUserQuestion answers are reflected in the plan." && probe_p_rev=1
phrase_then_coherence "Conversation and AskUserQuestion answers, then coherence." && probe_p_none=1
[[ "$probe_p_ok" -eq 1 && "$probe_p_rev" -eq 0 && "$probe_p_none" -eq 0 ]] && pass "phrase probe accepts phrase-then-coherence only" || fail "phrase probe accepts phrase-then-coherence only" "ok=$probe_p_ok rev=$probe_p_rev none=$probe_p_none"
check_phrase "agent criterion 1" "$crit1"
phrase_at="$(first_at "${crit1//\`/}" "$PHRASE")"
issues_at="$(first_at "$crit1" "Issues→Class-members")"
coh_at="$(first_at "$crit1" "coherence")"
conv_at="$(first_at "$crit1" "conversation")"
if [[ "$issues_at" -ge 0 && "$conv_at" -ge 0 && "$conv_at" -lt "$issues_at" && "$coh_at" -lt "$issues_at" ]]; then
  pass "criterion 1 keeps the Issues→Class-members gap after both aspects"
else
  fail "criterion 1 keeps the Issues→Class-members gap after both aspects" "conv=$conv_at coh=$coh_at issues=$issues_at"
fi
issues_bt="$(first_at "${crit1//\`/}" "Issues→Class-members")"
if [[ "$phrase_at" -ge 0 && "$issues_bt" -gt "$phrase_at" ]]; then
  pass "criterion 1 keeps the Issues→Class-members gap after the canonical phrase"
else
  fail "criterion 1 keeps the Issues→Class-members gap after the canonical phrase" "phrase=$phrase_at issues=$issues_bt"
fi
lines="$(grep -c '' "$AGENT")"
[[ "$lines" -le 104 ]] && pass "agent is at most 104 lines ($lines)" || fail "agent is at most 104 lines" "$lines lines"
trig="$(grep -E '^- `Trigger: ' "$AGENT")"
printf '%s' "$trig" | grep -q 'pre-confirm:' && pass "Trigger form lists pre-confirm:" || fail "Trigger form lists pre-confirm:" "$trig"
case_end

case_begin "codex audit-mode criterion sentence states the conversation aspect before coherence" "bin/supervisor-findings-codex"
[[ -n "$audit_prompt" ]] && pass "audit-mode prompt branch found" || fail "audit-mode prompt branch found"
[[ -n "$codex_crit" ]] && pass "audit-mode criterion line found" || fail "audit-mode criterion line found" "$audit_prompt"
check_order "codex audit criterion" "$codex_crit"
check_phrase "codex audit-mode prompt" "$codex_all"
case_end

case_begin "doc audit bullet states the conversation aspect before coherence" "docs/architecture/claude-code/supervisor-codex-input.md"
[[ -n "$doc_line" ]] && pass "doc audit bullet present" || fail "doc audit bullet present"
check_order "doc audit bullet" "$doc_line"
check_phrase "doc audit bullet" "$doc_line"
case_end

case_begin "the three places put the aspects in the same order" "agents/supervisor-audit.md"
a="$(aspect_order "$crit1")"
c="$(aspect_order "$codex_crit")"
d="$(aspect_order "$doc_line")"
if [[ "$a" == "$EXPECTED_ORDER" && "$a" == "$c" && "$a" == "$d" ]]; then
  pass "agent, codex and doc agree on the aspect order ($a)"
else
  fail "agent, codex and doc agree on the aspect order" "agent=[$a] codex=[$c] doc=[$d]"
fi
has_a=0; has_c=0; has_d=0
[[ "$(first_at "${crit1//\`/}" "$PHRASE")" -ge 0 ]] && has_a=1
[[ "$(first_at "${codex_all//\`/}" "$PHRASE")" -ge 0 ]] && has_c=1
[[ "$(first_at "${doc_line//\`/}" "$PHRASE")" -ge 0 ]] && has_d=1
if [[ "$has_a" -eq 1 && "$has_c" -eq 1 && "$has_d" -eq 1 ]]; then
  pass "agent, codex and doc all carry the canonical phrase"
else
  fail "agent, codex and doc all carry the canonical phrase" "agent=$has_a codex=$has_c doc=$has_d"
fi
case_end

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
