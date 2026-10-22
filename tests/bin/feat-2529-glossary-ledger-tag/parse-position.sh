# tests/bin/feat-2529-glossary-ledger-tag/parse-position.sh
# T8-13: the tag rides inside the concern TEXT. Each parser (numbered, C<N>
# reference, anchored) keeps it wherever the directive puts it, and staging and
# reduce carry it through unchanged. A tag placed before [SEV] is not a concern line.

PP="$LT_ROOT/pp"; mkdir -p "$PP"
lt_pp_report() { local f="$1"; shift; { printf '## Codex Review: PERFORMED\n\n## Concern Delta\n'; printf '%s\n' "$@"; printf '\n'; } > "$f"; }
lt_pp_text() { grep -v '^#' "$1" 2>/dev/null | sed -n "${2:-1}p" | cut -d'|' -f8-; }

# Numbered (outline-plan / detail-plan / test-review round 1).
printf '1. [HIGH] the heading is spelled another way [glossary-drift term=foo bar]\n2. [glossary-drift term=foo bar] [LOW] tag before the severity\n' > "$PP/num.txt"
lt cl_parse_numbered "$PP/num.txt" "$PP/num.out" >/dev/null 2>&1
lt_eq "numbered: only the well-formed line is picked" 1 "$(grep -vc '^#' "$PP/num.out" 2>/dev/null)"
t="$(lt_pp_text "$PP/num.out")"
lt_eq "numbered: tag kept at the end of TEXT" "the heading is spelled another way [glossary-drift term=foo bar]" "$t"
lt_eq "numbered: parsed TEXT is tagged" 0 "$(lt_rc cl_is_drift_tagged "$t")"

# Reduce the numbered round into a fresh test-review ledger.
lt cl_stage "$PP/stage-tr" test-review 1 codex COMPLETE COMPLETE "$PP/num.out" >/dev/null 2>&1
staged="$(cat "$PP"/stage-tr/test-review-round-1-delta-codex.txt 2>/dev/null)"
lt_has "staging (test-review) keeps the tag" "[glossary-drift term=foo bar]" "$staged"
lt cl_reduce "$PP/none.txt" "$PP/stage-tr/*" 1 test-review "$PP/tr-ledger.txt" >/dev/null 2>&1
row="$(grep -m1 '^C1|' "$PP/tr-ledger.txt" 2>/dev/null | cut -d'|' -f11-)"
lt_eq "reduce keeps the tag in the ledger TEXT" "the heading is spelled another way [glossary-drift term=foo bar]" "$row"
lt_eq "reduced row yields the term" "foo bar" "$(lt cl_drift_term "$row" 2>/dev/null)"

# C<N> reference (round 2+): a known ID keeps its stored tagged TEXT, a new ID keeps its own.
printf 'C1: restated without the tag\nC9: [glossary-drift term=baz qux] a new spelling drift\n' > "$PP/cn.txt"
lt cl_parse_cnref "$PP/cn.txt" "$PP/tr-ledger.txt" "$PP/cn.out" >/dev/null 2>&1
lt_eq "cnref: known C1 keeps the stored tagged TEXT" "the heading is spelled another way [glossary-drift term=foo bar]" \
  "$(grep -m1 '^C1|' "$PP/cn.out" 2>/dev/null | cut -d'|' -f8-)"
c9="$(grep -m1 '^C9|' "$PP/cn.out" 2>/dev/null | cut -d'|' -f8-)"
lt_eq "cnref: new C9 keeps its leading tag" "[glossary-drift term=baz qux] a new spelling drift" "$c9"
lt_eq "cnref: C9 yields its term" "baz qux" "$(lt cl_drift_term "$c9" 2>/dev/null)"

# Anchored (review-security-shared).
lt_pp_report "$PP/an.txt" \
  "[MEDIUM] - | bin/x.sh#f | correctness | [glossary-drift term=foo bar] the message spells it another way" \
  "[glossary-drift term=foo bar] [LOW] - | bin/x.sh#g | correctness | tag before the severity"
lt cl_parse_anchored "$PP/an.txt" review-code-codex "$PP/an.out" >/dev/null 2>&1
t="$(grep -v '^#' "$PP/an.out" 2>/dev/null | head -n1 | cut -d'|' -f8-)"
lt_eq "anchored: tag kept at the start of TEXT" "[glossary-drift term=foo bar] the message spells it another way" "$t"
lt_eq "anchored: parsed TEXT is tagged" 0 "$(lt_rc cl_is_drift_tagged "$t")"
lt_has "anchored: a tag before [SEV] is unparsed" "#unparsed|[glossary-drift term=foo bar] [LOW]" "$(cat "$PP/an.out" 2>/dev/null)"
lt cl_stage "$PP/stage-rs" review-security-shared 1 review-code-codex COMPLETE PARTIAL "$PP/an.out" >/dev/null 2>&1
lt_has "staging (review-security-shared) keeps the tag" "[glossary-drift term=foo bar] the message" \
  "$(cat "$PP"/stage-rs/review-security-shared-round-1-delta-review-code-codex.txt 2>/dev/null)"

# Staging outline-plan from the numbered parse.
lt cl_stage "$PP/stage-op" outline-plan 1 codex COMPLETE COMPLETE "$PP/num.out" >/dev/null 2>&1
lt_has "staging (outline-plan) keeps the tag" "[glossary-drift term=foo bar]" \
  "$(cat "$PP"/stage-op/outline-plan-round-1-delta-codex.txt 2>/dev/null)"
