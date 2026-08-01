# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, bin/lib/test-frontmatter-fix.sh, bin/lib/test-frontmatter-constants.sh
# Tags: TL2, scope:issue-specific, fix-1576-test-frontmatter, fix-1782-normalize-token-glob
# tests/fix-1576-audit-tests-fix-headers/root-like-tokens-report.sh
# Sourced fragment of tests/fix-1576-audit-tests-fix-headers.sh — NOT a
# standalone test file (no shebang execution; not discovered by
# tests/run-all.sh's `tests/*.sh` glob, which is non-recursive).
#
# TC11, TC12, TC22-TC26 (#1782): glob-expansion and root-equivalent-token
# report-mode coverage against bin/audit-tests.sh (and bin/audit-tests-common.sh
# for CPR-5 symmetry). TC11/TC12/TC23 are bespoke (single-token annotation,
# embedded-prose, and cross-binary CPR-5-symmetry fixtures respectively — none
# fit the table shape). TC22/TC24-TC26 are table-driven (round-4 test-review
# gap C1) into a single input(token)->expected-MRR-presence loop; this moves
# TC22 to run after TC23 (was before it pre-refactor) since it now shares a
# loop with TC24-TC26 — a harmless reorder, all four cases are independent.
#
# Depends on the caller (tests/fix-1576-audit-tests-fix-headers.sh) having
# already defined: $AUDIT, $AUDIT_COMMON, PASS/FAIL, pass(), fail(),
# make_fixture(), write_dispatcher(), run_in().

# TC11 (#1782): glob-expansion regression. Token "bin/*.sh" is a literal glob
# pattern in the header prose; normalize_token()'s unquoted `for word in $pre`
# must NOT let the shell glob-expand it against the fixture's real bin/*.sh
# files. Desired: the token is left unresolved (MANUAL_REVIEW_REQUIRED), never
# silently "fixed" to whichever real file the glob happened to expand to.
R11="$(make_fixture)"
write_dispatcher "$R11" "feature-11-glob.sh" '# Tests: bin/*.sh (see all)'
run_in "$R11" "$AUDIT" --fix-headers --offline
if [[ "$OUT$ERR" == *"MANUAL_REVIEW_REQUIRED"* \
   && "$OUT$ERR" != *"FIX_A:"*"bin/foo.sh"* \
   && "$OUT$ERR" != *"FIX_A:"*"bin/bar.sh"* ]]; then
  pass "TC11 glob token bin/*.sh is not silently glob-expanded to a real file"
else
  fail "TC11 glob token bin/*.sh is not silently glob-expanded to a real file" "rc=$RC out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R11"

# TC12 (#1782 issue example): bare "/" embedded in prose ("CI-4 / workflow-init")
# must not be accepted as a valid existing path via `[[ -e "/" ]]`.
R12="$(make_fixture)"
write_dispatcher "$R12" "feature-12-slash.sh" '# Tests: bin/foo.sh, clarify-intent CI-4 / workflow-init Path A1'
run_in "$R12" "$AUDIT" --fix-headers --offline
bad_line=0
if printf '%s\n' "$OUT" "$ERR" | grep -qxF "FIX_A: tests/feature-12-slash.sh: /"; then
  bad_line=1
fi
if [[ "$bad_line" -eq 0 && "$OUT$ERR" == *"MANUAL_REVIEW_REQUIRED"* && "$OUT$ERR" == *"clarify-intent"* ]]; then
  pass "TC12 bare / embedded in prose is not accepted as a valid path"
else
  fail "TC12 bare / embedded in prose is not accepted as a valid path" "rc=$RC out=<<$OUT>> err=<<$ERR>> bad_line=$bad_line"
fi
rm -rf "$R12"

# TC23 (#1782 CPR-5 symmetry): the same standalone-root-equivalent-token
# regression (TC14's bare "/") must also be caught through
# bin/audit-tests-common.sh's --fix-headers path, not only bin/audit-tests.sh.
if [[ -f "$AUDIT_COMMON" ]]; then
  R23="$(make_fixture)"
  write_dispatcher "$R23" "check-bareroot.sh" '# Tests: bin/foo.sh, /'
  run_in "$R23" "$AUDIT_COMMON" --fix-headers
  if printf '%s\n' "$OUT" "$ERR" | grep -qxF "MANUAL_REVIEW_REQUIRED: tests/check-bareroot.sh: /"; then
    pass "TC23 audit-tests-common.sh --fix-headers flags standalone / CSV token via MANUAL_REVIEW_REQUIRED (CPR-5 symmetry)"
  else
    fail "TC23 audit-tests-common.sh --fix-headers flags standalone / CSV token via MANUAL_REVIEW_REQUIRED (CPR-5 symmetry)" "rc=$RC out=<<$OUT>> err=<<$ERR>>"
  fi
  rm -rf "$R23"
fi

# TC24-TC26 (#1782 round-3 review gap C1 — root-equivalent spelling coverage):
# Codex flagged that only the 5 literal case-list spellings ("/", ".", "..",
# "./", "../") were exercised as standalone CSV tokens. Per the approved fix
# design read from the session detail plan (Step 1, `_is_root_like_token()`):
#
#   _is_root_like_token() {
#     case "$1" in
#       /|.|..|./|../) return 0 ;;
#       *) return 1 ;;
#     esac
#   }
#
# this is a literal 5-member denylist compared by exact string match — it does
# NOT canonicalize or resolve paths (confirmed by direct verification: running
# `bin/audit-tests.sh --fix-headers --offline` against synthetic fixtures with
# "bin/.", "tests/..", and an absolute sandbox-root token all currently produce
# ZERO diagnostic output — i.e. all three are already silently bucketed as
# CHR_TOKENS_OK today, and none of the three textually equals one of the 5
# denylist members, so the approved literal-list fix will not change that
# classification either). The detail plan's Risks section explicitly documents
# this as an intentional non-goal: "多段親参照(../../)まで捕捉しない...本プラン
# では広げない" (multi-segment parent-reference resolution is out of scope for
# this PR; broadening to resolved-path identity is deferred to a future issue).
#
# So TC24-TC26 are written as boundary/negative-control regressions that
# genuinely round-trip through the actual (literal-match-only) mechanism,
# rather than forcing an assertion the approved design cannot satisfy: each
# asserts the token is accepted as a normal existing path (no FIX_A, no
# MANUAL_REVIEW_REQUIRED line for that token) — true today and expected to
# remain true after #1782 lands, since none of the three is one of the 5
# literal forms. This guards two things: (1) a future literal-list
# implementation doesn't accidentally overreach via prefix/suffix/substring
# matching instead of exact case-arm matching (which would wrongly flag
# "bin/."), and (2) the documented multi-segment-traversal / resolved-absolute-
# path non-goal boundary stays visible and doesn't silently regress into being
# either always-flagged or a crash.

# TC22, TC24-TC26 (table-driven per skills/_shared/test-design/parser-regex-tests.md):
# a single input(token)->expected-behavior(present/absent MANUAL_REVIEW_REQUIRED)
# loop covering both the positive root-equivalent case (TC22 — "./" is the
# fifth _is_root_like_token() case-list member not yet covered by TC14-TC17,
# and takes the same direct-match branch, where `[[ -e "./" ]]` is always true
# and must NOT be silently accepted) and the three round-3 Codex gap-C1
# negative controls (TC24-TC26 — root-equivalent-*spelling* coverage beyond
# the 5 literal case-list members):
#
#   _is_root_like_token() {
#     case "$1" in
#       /|.|..|./|../) return 0 ;;
#       *) return 1 ;;
#     esac
#   }
#
# this is a literal 5-member denylist compared by exact string match — it does
# NOT canonicalize or resolve paths (confirmed by direct verification: running
# `bin/audit-tests.sh --fix-headers --offline` against synthetic fixtures with
# "bin/.", "tests/..", and an absolute sandbox-root token all currently produce
# ZERO diagnostic output — i.e. all three are already silently bucketed as
# CHR_TOKENS_OK today, and none of the three textually equals one of the 5
# denylist members, so the approved literal-list fix will not change that
# classification either). The detail plan's Risks section explicitly documents
# this as an intentional non-goal: "多段親参照(../../)まで捕捉しない...本プラン
# では広げない" (multi-segment parent-reference resolution is out of scope for
# this PR; broadening to resolved-path identity is deferred to a future issue).
#
# So TC24-TC26 are written as boundary/negative-control regressions that
# genuinely round-trip through the actual (literal-match-only) mechanism,
# rather than forcing an assertion the approved design cannot satisfy: each
# asserts the token is accepted as a normal existing path (no FIX_A, no
# MANUAL_REVIEW_REQUIRED line for that token) — true today and expected to
# remain true after #1782 lands, since none of the three is one of the 5
# literal forms. This guards two things: (1) a future literal-list
# implementation doesn't accidentally overreach via prefix/suffix/substring
# matching instead of exact case-arm matching (which would wrongly flag
# "bin/."), and (2) the documented multi-segment-traversal / resolved-absolute-
# path non-goal boundary stays visible and doesn't silently regress into being
# either always-flagged or a crash.
#
# Round-3 Codex gap C3 fix: every row now also asserts RC==0 on the underlying
# --fix-headers invocation (not just absence/presence of a diagnostic line) —
# a crash could otherwise produce empty output and a false-green "absent"
# pass for TC24-TC26. Uses the same rc_ok pattern TC18/TC19 use.
#
# __ROOT__ in the header/token fields is substituted with this iteration's
# fixture root (TC26 needs the fixture's own absolute sandbox-root path).
while IFS='|' read -r tc fname header token expect desc; do
  [[ -z "$tc" || "$tc" =~ ^[[:space:]]*# ]] && continue
  tc="${tc//[[:space:]]/}"
  fname="${fname//[[:space:]]/}"
  header="$(printf '%s' "$header" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  token="$(printf '%s' "$token" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  expect="${expect//[[:space:]]/}"
  desc="$(printf '%s' "$desc" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  root="$(make_fixture)"
  header="${header//__ROOT__/$root}"
  token="${token//__ROOT__/$root}"
  write_dispatcher "$root" "$fname" "# Tests: $header"
  run_in "$root" "$AUDIT" --fix-headers --offline
  rc_ok=0; [[ "$RC" -eq 0 ]] && rc_ok=1
  mrr_found=0
  if printf '%s\n' "$OUT" "$ERR" | grep -qxF "MANUAL_REVIEW_REQUIRED: tests/$fname: $token"; then
    mrr_found=1
  fi
  ok=0
  if [[ "$rc_ok" -eq 1 ]]; then
    [[ "$expect" == "present" && "$mrr_found" -eq 1 ]] && ok=1
    [[ "$expect" == "absent" && "$mrr_found" -eq 0 ]] && ok=1
  fi
  if [[ "$ok" -eq 1 ]]; then
    pass "$desc"
  else
    fail "$desc" "rc=$RC rc_ok=$rc_ok mrr_found=$mrr_found expect=$expect out=<<$OUT>> err=<<$ERR>>"
  fi
  rm -rf "$root"
done <<'TABLE'
TC22 | feature-22-dotslash-standalone.sh | bin/foo.sh, ./ | ./ | present | TC22 standalone ./ CSV token is flagged via MANUAL_REVIEW_REQUIRED, not silently accepted as valid
TC24 | feature-24-bindot.sh | bin/., bin/foo.sh | bin/. | absent | TC24 bin/. (existing non-root directory) is accepted as a valid path, not flagged MANUAL_REVIEW_REQUIRED
TC25 | feature-25-testsdotdot.sh | tests/.., bin/foo.sh | tests/.. | absent | TC25 tests/.. (multi-segment traversal resolving to repo root) is accepted as a valid path — documented non-goal, not literal-denylist match
TC26 | feature-26-absroot.sh | __ROOT__, bin/foo.sh | __ROOT__ | absent | TC26 absolute path to the fixture's own sandbox root is accepted as a valid path — documented non-goal, not literal-denylist match
TABLE
