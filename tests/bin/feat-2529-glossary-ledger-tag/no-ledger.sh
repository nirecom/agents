# tests/bin/feat-2529-glossary-ledger-tag/no-ledger.sh
# T8-11: intent and docs have no ledger. Their recorded check depends only on the
# deterministic scan — tagged concerns in every other format's ledger change
# neither the exit code, the fingerprint nor the findings — and ACCEPTED there
# records no ledger grant (handler side: T4-2).

LT_DRIFT_CLI="$LT_AGENTS_N/bin/check-glossary-drift"
LT_NL_REPO="$LT_ROOT/nl-repo"
harness_git_init "$LT_NL_REPO"
git -C "$LT_NL_REPO" config core.autocrlf false
mkdir -p "$LT_NL_REPO/docs"
printf '# Notes\n\nThe foo-bar flow is described here.\n' > "$LT_NL_REPO/docs/notes.md"
git -C "$LT_NL_REPO" add docs/notes.md

# lt_nl_record <sid> <stage> — run --record from the fixture repo; prints "rc|fingerprint|findings".
lt_nl_record() {
  local rc=0 step fp fd
  step="$(lt_step_of "$2")"
  ( cd "$LT_NL_REPO" && CLAUDE_PROJECT_DIR="$LT_NL_REPO" run_with_timeout 60 node "$LT_DRIFT_CLI" --session "$1" --stage "$2" --record ) >/dev/null 2>&1 || rc=$?
  fp="$(run_with_timeout 30 node "$LT_WST" "$LT_AGENTS_N" path "$1" "$step" glossary_check fingerprint 2>/dev/null)"
  fd="$(run_with_timeout 30 node "$LT_WST" "$LT_AGENTS_N" path "$1" "$step" glossary_check findings 2>/dev/null)"
  printf '%s|%s|%s' "$rc" "$fp" "$fd"
}

for stage in intent docs; do
  sid="$(lt_sid nl "$stage")"
  printf '# Intent\n\n## Issues\n\n- #1: fixture\n\n## Glossary\n\n| Term | Category | Definition |\n|---|---|---|\n| foo bar | user | A fixture term. |\n\n## Background/Motivation\n\nThe foo-bar flow and the Foo Bar flow.\n' > "$WORKFLOW_PLANS_DIR/$sid-intent.md"
  first="$(lt_nl_record "$sid" "$stage")"
  rc="${first%%|*}"; rest="${first#*|}"; fp="${rest%%|*}"
  # node exits 1 on a missing script too, so rc alone does not prove the CLI ran.
  if [ ! -f "$SCRIPT_CHECKOUT_ROOT/bin/check-glossary-drift" ]; then fail "$stage: --record ran" "bin/check-glossary-drift missing"
  else case "$rc" in 0|1) pass "$stage: --record ran (rc=$rc)" ;; *) fail "$stage: --record ran" "rc=$rc out=$first" ;; esac; fi
  if [ -n "$fp" ] && [ "$fp" != "(absent)" ]; then pass "$stage: a fingerprint was recorded"
  else fail "$stage: a fingerprint was recorded" "got=$fp"; fi
  for fmt in $LT_FORMATS; do lt_build "$sid" "$fmt"; done
  second="$(lt_nl_record "$sid" "$stage")"
  # Two absent records are equal without proving anything; compare only a real record.
  if [ -z "$fp" ] || [ "$fp" = "(absent)" ]; then fail "$stage: tagged ledgers change neither rc, fingerprint nor findings" "no first record to compare"
  else lt_eq "$stage: tagged ledgers change neither rc, fingerprint nor findings" "$first" "$second"; fi

  # ACCEPTED at a ledgerless stage records no ledger grant.
  sid="$(lt_sid nla "$stage")"; step="$(lt_step_of "$stage")"
  for fmt in $LT_FORMATS; do lt_build "$sid" "$fmt"; done
  lt_seed_current "$sid" "$step"
  lt_mark "$sid" "$(lt_accepted "foo bar" "$stage")"
  lt_eq "$stage: ACCEPTED records no ledger_grants on $step" "(absent)" "$(lt_grants_of "$sid" "$step")"
done

# Positive control: the same sentinel at a ledger stage does record the grant.
sid="$(lt_sid nlctl test-review)"; lt_build "$sid" test-review
lt_seed_current "$sid" review_tests
lt_mark "$sid" "$(lt_accepted "foo bar" tests)"
lt_has "control: ACCEPTED at tests records C1's ledger grant" "$LT_D1" "$(lt_grants_of "$sid" review_tests)"
