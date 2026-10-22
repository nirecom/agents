# tests/bin/feat-2529-glossary-ledger-tag/tag-grammar.sh
# T8-10: what counts as a tag (cl_is_drift_tagged: 0 tagged, 1 not) and which term
# it carries (cl_drift_term: empty when none). A tagged concern with no extractable
# term is refused by both accept and reject.
# lang-check: ignore — Japanese fixture strings are test data for Japanese term matching.

# name ; text ; tagged rc ; term
while IFS=';' read -r name text want_rc want_term; do
  [ -z "$name" ] && continue
  lt_eq "grammar/$name: tagged rc" "$want_rc" "$(lt_rc cl_is_drift_tagged "$text")"
  lt_eq "grammar/$name: term" "$want_term" "$(lt cl_drift_term "$text" 2>/dev/null)"
done <<'TABLE'
prefix tag;[glossary-drift term=foo bar] heading spelled another way;0;foo bar
mid-text tag;the heading [glossary-drift term=foo bar] is spelled another way;0;foo bar
suffix tag;the heading is spelled another way [glossary-drift term=foo bar];0;foo bar
japanese term;見出しの表記 [glossary-drift term=用語集] が揺れている;0;用語集
lookalike name;[glossary-driftx term=a] not the tag;1;
no space no fields;[glossary-drift] not the tag;1;
space no fields;[glossary-drift ] tagged but termless;0;
empty term;[glossary-drift term=] tagged but termless;0;
term not first;[glossary-drift cat=user term=foo] tagged but termless;0;
TABLE

# End to end: "term not first" is tagged, so reject refuses, and termless, so a
# grant for "foo" opens nothing.
fmt=outline-plan; sid="$(lt_sid tg "$fmt")"; led="$(lt_ledger "$sid" "$fmt")"
tx="[glossary-drift cat=user term=foo] tagged but termless"
printf '#concern-ledger-v2|%s|%s|cycle=1\n' "$fmt" "$sid" > "$led"; lt_row "$led" C1 HIGH open "$tx"
lt_seed_grants "$sid" outline outline "$(lt_gj foo "$(lt cl_discrim "$tx")")"
before="$(lt_snap "$sid" "$fmt")"
lt_accept "$sid" "$fmt" C1
lt_eq "termless tag with a grant for foo: accept refuses (4)" 4 "$LT_RC"
lt_reject "$sid" "$fmt" C1
lt_eq "termless tag: reject refuses (4)" 4 "$LT_RC"
lt_eq "termless tag refusals write nothing" "$before" "$(lt_snap "$sid" "$fmt")"
