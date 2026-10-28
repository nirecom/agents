# tests/bin/feat-2529-glossary-ledger-tag/static-directives.sh
# T8-14: the prompt directives that make the tag work end to end. Each check is
# scoped to the step block or line that must carry it, so a mention elsewhere in
# the file does not satisfy it.

R="$SCRIPT_CHECKOUT_ROOT"
# lt_block <file> <start-ERE> — from the start line to the next step marker or heading.
lt_block() {
  awk -v s="$2" '
    f && /^([A-Z]{2,4}-[0-9]+[a-z]?\.|\*\*[A-Z]{2,4}-[0-9]+[a-z]?|#{1,3} )/ { exit }
    !f && $0 ~ s { f = 1 }
    f { print }
  ' "$1" 2>/dev/null
}
# lt_line_with <label> <text> <needle>... — some single line of <text> holds every needle.
lt_line_with() {
  local label="$1" text="$2" line n ok; shift 2
  while IFS= read -r line; do
    ok=1
    for n in "$@"; do [[ "${line,,}" == *"${n,,}"* ]] || { ok=0; break; }; done
    if [ "$ok" -eq 1 ]; then pass "$label"; return; fi
  done <<< "$text"
  fail "$label" "no single line holds: $*"
}

for p in outline-planner detail-planner; do
  f="$R/agents/$p.md"; body="$(cat "$f" 2>/dev/null)"
  lt_has "$p: names the [glossary-drift term= tag" "[glossary-drift term=" "$body"
  lt_has "$p: defines the accepted(glossary-drift): <reason> disposition" "accepted(glossary-drift): <" "$body"
  lt_line_with "$p: one line forbids reject: for a tagged concern" "$body" "glossary-drift" "reject:"
  trailer="$(grep -E '^[[:space:]]*1\. <reviewer concern' "$f" 2>/dev/null)"
  lt_has "$p: trailer dispositions offer accepted(glossary-drift)" "accepted(glossary-drift)" "$trailer"
done

lt_line_with "priority-hierarchy: one line keeps tagged concerns out of reject:" \
  "$(cat "$R/skills/_shared/priority-hierarchy.md" 2>/dev/null)" "glossary-drift" "reject:"

mop="$R/skills/make-outline-plan/SKILL.md"; mdp="$R/skills/make-detail-plan/SKILL.md"
for spec in "$mop|- \*\*Confirmation dialogs per run\*\*" "$mop|- Never pause for user confirmation" "$mdp|- \*\*One user-facing confirmation per run\*\*"; do
  f="${spec%%|*}"; pat="${spec#*|}"
  line="$(grep -E -m1 -- "^$pat" "$f" 2>/dev/null)"
  lt_has "$(basename "$(dirname "$f")"): '${pat//\\/}' names the AskUserQuestion exception" "AskUserQuestion" "$line"
  lt_has "$(basename "$(dirname "$f")"): '${pat//\\/}' points at glossary-drift-check.md" "glossary-drift-check.md" "$line"
done

g="$R/skills/_shared/glossary-drift-check.md"
if [ -f "$g" ]; then
  gd="$(cat "$g")"
  hdr="$(grep -E '^\|[^|]+\|[^|]+\|[^|]+\|[[:space:]]*$' "$g" | head -n1)"
  if printf '%s' "$hdr" | cut -d'|' -f2 | grep -qi 'term'; then pass "glossary-drift-check: a 3-column list (term first)"
  else fail "glossary-drift-check: a 3-column list (term first)" "header=$hdr"; fi
  for src in CI-4a concerns-log unresolved-concerns.json UD-4a; do
    lt_has "glossary-drift-check: names the $src source" "$src" "$gd"
  done
  lt_line_with "glossary-drift-check: the not-a-rejection directive keys on the tag" "$gd" "[glossary-drift " "reject"
  bad="$(grep -i 'exit 4' "$g" | grep -i 'reject' | grep -vF '[glossary-drift ')"
  lt_eq "glossary-drift-check: no directive keys on exit 4 alone" "" "$bad"
else
  fail "glossary-drift-check.md exists" "skills/_shared/glossary-drift-check.md missing"
fi

rt="$(lt_block "$R/skills/review-tests/SKILL.md" '^RT-4a\.')"
rcs="$(lt_block "$R/skills/review-code-security/SKILL.md" '^RCS-3\.')"
for pair in "RT-4a|$rt" "RCS-3|$rcs"; do
  n="${pair%%|*}"; b="${pair#*|}"
  lt_has "$n: triage keys on the [glossary-drift tag" "[glossary-drift " "$b"
  lt_has "$n: points at glossary-drift-check.md" "glossary-drift-check.md" "$b"
done

cpa="$(lt_block "$R/skills/_shared/confirm-plan.md" '^\*\*CPA-3')"
lt_has "CPA-3: runs check-glossary-drift before the gate check" "check-glossary-drift" "$cpa"
lt_has "CPA-3: with --record" "--record" "$cpa"
lt_line_with "CPA-3: one line puts the list in all three presentations" "$cpa" \
  "presentation turn" "present-and-stop" "proceed" "glossary-drift-check.md"

ud="$R/skills/update-docs/SKILL.md"
lt_has "UD-5: references the same list" "glossary-drift-check.md" "$(lt_block "$ud" '^UD-5\.')"
for spec in "$ud|^UD-4a\.|UD-4a" "$R/skills/clarify-intent/SKILL.md|^CI-4a\.|CI-4a"; do
  f="${spec%%|*}"; rest="${spec#*|}"; pat="${rest%%|*}"; n="${rest#*|}"
  b="$(lt_block "$f" "$pat")"
  lt_has "$n: self-review via combined-glossary.md" "combined-glossary.md" "$b"
  lt_has "$n: uses the reviewer directive" "reviewer" "$b"
done
lt_has "RD-3: references glossary-drift-check.md" "glossary-drift-check.md" "$(lt_block "$R/skills/review-docs/SKILL.md" '^RD-3\.')"
