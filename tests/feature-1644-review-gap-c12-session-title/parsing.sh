# shellcheck shell=bash
# Tests: hooks/lib/session-title.js
# Tags: tl2, workflow, session-title, parser, scope:issue-specific, pwsh-not-required
# C12-1 (## Issues section parsing) and C12-2 (overwrite guard) case groups.
# Relies on helpers.sh being sourced first.

run_parsing_cases() {

echo "=== C12-1: ## Issues section parsing (table-driven) ==="
# case-name | intent.md body | expected title after writeSetIssue ("<none>" = no write)
run_parse_case() {
  local name="$1" body="$2" want="$3"
  local sid="p-$4"
  local jsonl="$JSONL_DIR/${sid}.jsonl"; : > "$jsonl"
  printf '%s' "$body" > "$PLANS_DIR/${sid}-intent.md"
  call "$jsonl" "m.writeSetIssue('$sid','$CWD_ARG_N','$PLANS_DIR_N');" >/dev/null
  check "C12-1 $name" "$want" "$(last_title "$jsonl" "$sid")"
}

run_parse_case "single issue with title" \
'# Intent

## Issues

- #42: Fix login bug
' "#42 Fix login bug" 1

# A SECOND "## Issues" heading: collectEntries-style scanning stops at the next
# "## " heading, so only the FIRST section contributes. Pinned as the current
# contract for a malformed multi-section intent.md.
run_parse_case "multiple ## Issues sections -> only the first is used" \
'## Issues

- #10: First section issue

## Notes

filler

## Issues

- #20: Second section issue
' "#10 First section issue" 2

# Section terminated by a following heading: entries after it are ignored.
run_parse_case "entries after the terminating heading are ignored" \
'## Issues

- #10: Kept

## Other

- #99: Ignored
' "#10 Kept" 3

# Malformed bullets (no leading "- ", prose lines, a non-numeric ref) are
# skipped; only well-formed entries survive.
run_parse_case "malformed entries are skipped, well-formed ones survive" \
'## Issues

* #11: wrong bullet marker
#12: no bullet at all
- not-an-issue-line
- #13: Good entry
' "#13 Good entry" 4

# A section with only malformed entries yields zero issues -> fail-open, no write.
run_parse_case "wholly malformed section -> no write" \
'## Issues

* #11: wrong bullet
- garbage
' "<none>" 5

# No "## Issues" heading at all -> no write. NOTE: unlike
# hooks/lib/parse-closes-issues.js, session-title.js has NO legacy
# "## closes_issues" fallback (pinned asymmetry between the two parsers).
run_parse_case "legacy ## closes_issues heading is NOT honored here" \
'## closes_issues

- #77: Legacy section
' "<none>" 6

# Bare numbers and numbers without titles are accepted by the regex.
run_parse_case "bare-number and title-less entries" \
'## Issues

- 55
- #56
' "#55 #56" 7

echo ""
echo "=== C12-2: overwrite guard over every existing-title form (table-driven) ==="
# existing title | expected title after writeSetIssue on "- #42: New title"
run_guard_case() {
  local name="$1" existing="$2" want="$3" idx="$4"
  local sid="g-$idx"
  local jsonl="$JSONL_DIR/${sid}.jsonl"; : > "$jsonl"
  if [ "$existing" != "<absent>" ]; then
    node -e '
      const fs=require("fs");
      fs.appendFileSync(process.argv[1], JSON.stringify({type:"custom-title",sessionId:process.argv[2],customTitle:process.argv[3]})+"\n");
    ' "$(nrm "$jsonl")" "$sid" "$existing"
  fi
  write_intent "$sid" '## Issues

- #42: New title
'
  call "$jsonl" "m.writeSetIssue('$sid','$CWD_ARG_N','$PLANS_DIR_N');" >/dev/null
  check "C12-2 $name" "$want" "$(last_title "$jsonl" "$sid")"
}

run_guard_case "no prior record (null) -> writes"          "<absent>"        "#42 New title" 1
run_guard_case "bare hourglass -> overwritten"             "⏳"              "#42 New title" 2
run_guard_case "hourglass + non-space (ext temp form)"     "⏳ai-guess"      "#42 New title" 3
run_guard_case "hourglass + space form -> preserved"       "⏳ waiting"      "⏳ waiting"    4
run_guard_case "real issue title -> preserved"             "#7 Real work"    "#7 Real work"  5
run_guard_case "title with PR suffix -> preserved"         "#7 Real PR #99"  "#7 Real PR #99" 6
run_guard_case "completed title -> preserved"              "✓ #7 Done"       "✓ #7 Done"     7
# An empty-string customTitle is normalized to null by _readCurrentTitle, so it
# behaves as "no prior title" and IS overwritten.
run_guard_case "empty-string customTitle -> treated as null" ""              "#42 New title" 8

}
