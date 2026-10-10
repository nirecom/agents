#!/usr/bin/env bash
# Tests: hooks/bash-guard/judge.js, hooks/bash-guard/allow.js, hooks/bash-guard/detect.js, hooks/lib/allow-command-list.js, install/settings-allow-commands.txt
# Tags: hook, bash-guard, self-script-allow, regression-corpus, scope:issue-specific, pwsh-not-required, TL2
# Sourced by tests/hooks/feature-2265-allow-regression-corpus.sh (fixture already built).
# Every spelling the retired #2421 generator or the #2451 static rules allowed must still get
# its pinned verdict from the classifier, judged against the fixture main checkout.

CORPUS_FILE="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2265-allow-regression-corpus/corpus.jsonl"
CORPUS_OUT="$(fx_run --corpus "$CORPUS_FILE")"
printf '%s\n' "$CORPUS_OUT" | grep -E '^(ROW|FAMILY|SOURCE|RESULT)' | head -n 120

# corpus_family_clean <family...>: every row of each family matched its pinned verdict.
corpus_family_clean() {
  local fam total
  for fam in "$@"; do
    total="$(fx_field "$CORPUS_OUT" "FAMILY $fam " total)"
    if [[ "$total" == "<absent>" || "$total" == "0" ]]; then
      fail "corpus[$fam]: family ran no rows"
      continue
    fi
    fx_check "corpus[$fam]: all $total rows get their pinned verdict" "0" "$(fx_field "$CORPUS_OUT" "FAMILY $fam " fail)"
  done
}

case_begin "corpus-integrity" "hooks/bash-guard/judge.js"
# An empty, truncated or partly skipped corpus must not report green.
fx_check "corpus: runner produced a RESULT line" "yes" "$([[ "$CORPUS_OUT" == *"RESULT "* ]] && echo yes || echo no)"
fx_check "corpus: no row skipped" "0" "$(fx_field "$CORPUS_OUT" "RESULT " skip)"
fx_check "corpus: every meta row ran" "$(fx_field "$CORPUS_OUT" "RESULT " meta_rows)" "$(fx_field "$CORPUS_OUT" "RESULT " rows)"
fx_check "corpus: meta pins the #2451 static set at 206 rules" "206" "$(fx_field "$CORPUS_OUT" "RESULT " meta_static)"
fx_check "corpus: 206 distinct static-2451 rules are present" "206" "$(fx_field "$CORPUS_OUT" "RESULT " static_rules)"
fx_check "corpus: gen-2421 rule count matches meta" "$(fx_field "$CORPUS_OUT" "RESULT " meta_gen)" "$(fx_field "$CORPUS_OUT" "RESULT " gen_rules)"
fx_check "corpus: ssot-add rule count matches meta" "$(fx_field "$CORPUS_OUT" "RESULT " meta_ssot)" "$(fx_field "$CORPUS_OUT" "RESULT " ssot_rules)"
case_end

# Pinned here, not read from corpus.jsonl: a truncated corpus with regenerated meta still fails.
CORPUS_PIN_ROWS=2615
CORPUS_PIN_RULES="gen_rules=606 static_rules=206 ssot_rules=24"
CORPUS_PIN_FAMILIES="env=130 rel=260 abs=260 abs-q=260 win-q=260 win-unq=260 bashc=130 bashc-cd=130 bashc-bare=5 bashc-cd-bare=5 bare=5 exec-env=130 exec-abs=260 exec-abs-q=260 exec-win-q=260"

case_begin "corpus-pinned-manifest" "hooks/bash-guard/judge.js"
fx_check "corpus: judged row count is the pinned $CORPUS_PIN_ROWS" "$CORPUS_PIN_ROWS" "$(fx_field "$CORPUS_OUT" "RESULT " rows)"
for kv in $CORPUS_PIN_RULES; do
  fx_check "corpus: distinct ${kv%%=*} is the pinned ${kv#*=}" "${kv#*=}" "$(fx_field "$CORPUS_OUT" "RESULT " "${kv%%=*}")"
done
for kv in $CORPUS_PIN_FAMILIES; do
  fx_check "corpus: family ${kv%%=*} has the pinned ${kv#*=} rows" "${kv#*=}" "$(fx_field "$CORPUS_OUT" "FAMILY ${kv%%=*} " total)"
done
fx_check "corpus: no family outside the pinned manifest" "$(wc -w <<< "$CORPUS_PIN_FAMILIES" | tr -d ' ')" \
  "$(grep -c '^FAMILY ' <<< "$CORPUS_OUT")"
case_end

case_begin "corpus-interpreter-spellings" "hooks/lib/allow-command-list.js"
# <I> "$AGENTS_MAIN_ROOT/<P>", relative <I> <P> (cwd MAIN and WT), absolute <R>/<P> quoted and
# unquoted, and both <R2W> forms, each against the MAIN root and the linked-worktree root.
corpus_family_clean env rel abs abs-q win-q win-unq
case_end

case_begin "corpus-bash-c-wrapper" "hooks/bash-guard/allow.js"
# bash -c '<I> "$A/<P>"', bash -c 'cd "$A" && <I> "$A/<P>"', and the bare-name twins.
corpus_family_clean bashc bashc-cd bashc-bare bashc-cd-bare
case_end

case_begin "corpus-bare-name" "hooks/bash-guard/allow.js"
corpus_family_clean bare
case_end

case_begin "corpus-exec-position-notify" "hooks/bash-guard/detect.js"
# Exec-position spellings (no interpreter) get the L3 notify, on the MAIN and the WT root alike.
corpus_family_clean exec-env exec-abs exec-abs-q exec-win-q
case_end

case_begin "corpus-ssot-add-handoff-append" "install/settings-allow-commands.txt"
fx_check "corpus: every bin/workflow/handoff-append row gets its pinned verdict" "0" \
  "$(fx_field "$CORPUS_OUT" "SOURCE ssot-add " fail)"
case_end

case_begin "corpus-static-2451-rows" "hooks/bash-guard/allow.js"
fx_check "corpus: every row derived from a #2451 static rule gets its pinned verdict" "0" \
  "$(fx_field "$CORPUS_OUT" "SOURCE static-2451 " fail)"
case_end
