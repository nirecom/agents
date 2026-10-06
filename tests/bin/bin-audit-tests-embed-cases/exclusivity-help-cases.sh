# Tests: bin/lib/test-embed-cases.sh, bin/audit-tests.sh, bin/audit-tests-common.sh
# Tags: TL2, scope:common, audit-tests, embed-cases, flag-exclusivity, help
# Sourced by tests/bin/bin-audit-tests-embed-cases.sh — every row of the flag
# exclusivity table on both entrypoints, the tec_main -h usage, and the new
# --help lines. Every exit-2 row also proves the rejection is not the
# pre-existing "unknown argument" one.

EX_REPO="$(ec_make_repo)"
ec_add_test "$EX_REPO" tests/bin/t-alpha.sh "bin/alpha.sh"
ec_add_test "$EX_REPO" tests/bin/t-bravo.sh "bin/bravo.sh"
ec_commit "$EX_REPO" init

# Table: <expect: 2|ok|note> <args...> — "ok" = rc 0; "note" = rc 0 + subsumed NOTE.
EX_TABLE=(
  "note|--embed-cases --dry-run --fix-headers"
  "2|--embed-cases --dry-run --dup-groups"
  "2|--embed-cases --dry-run --format json"
  "ok|--embed-cases --dry-run --format text"
  "2|--embed-cases --dry-run --stale-months 3"
  "2|--embed-cases --dry-run --offline"
  "2|--band-size 2"
  "2|--order priority"
  "2|--dry-run --band-size 2"
  "2|--embed-cases --dry-run --order newest"
  "2|--embed-apply WORKDIR --embed-cases"
  "2|--embed-apply WORKDIR --band-size 2"
  "2|--embed-apply WORKDIR --order frequency"
  "2|--embed-apply WORKDIR --dry-run"
  "ok|--embed-cases --apply --band-size 1"
)

# ex_row <entrypoint> <row> — runs one table row and asserts its expectation.
ex_row() {
  local script="$1" want="${2%%|*}" argstr="${2#*|}" label
  local -a args
  read -r -a args <<<"${argstr//WORKDIR/$WORKFLOW_PLANS_DIR/sweep-tests-embed/ex-run}"
  label="EX $(basename "$script") [$argstr]"
  ec_run "$EX_REPO" "$script" "${args[@]}"
  case "$want" in
    2)
      if [[ "$RC" -eq 2 ]] && ec_not_unknown_arg; then pass "$label exits 2"; else fail "$label exits 2" "rc=$RC err=${ERR:0:200}"; fi
      ;;
    ok)
      check_eq "$label is accepted (err=${ERR:0:200})" "0" "$RC"
      ;;
    note)
      check_eq "$label is accepted (err=${ERR:0:200})" "0" "$RC"
      if [[ "$ERR" == *"NOTE: --fix-headers is subsumed by --embed-cases (selected files only)"* ]]; then
        pass "$label prints the subsumed NOTE on stderr"
      else
        fail "$label prints the subsumed NOTE on stderr" "err=${ERR:0:200}"
      fi
      ;;
  esac
}

case_begin "exclusivity-table-audit-tests" "bin/audit-tests.sh"
for _row in "${EX_TABLE[@]}"; do ex_row "$AUDIT" "$_row"; done
case_end

case_begin "exclusivity-table-audit-tests-common" "bin/audit-tests-common.sh"
for _row in "${EX_TABLE[@]}"; do ex_row "$AUDIT_COMMON" "$_row"; done
case_end

case_begin "exclusivity-rejects-leave-repo-clean" "bin/lib/test-embed-cases.sh"
check_eq "EX the whole table leaves no worktree change in the fixture" "" "$(git -C "$EX_REPO" status --porcelain)"
case_end

case_begin "embed-cases-short-help" "bin/lib/test-embed-cases.sh"
for _s in "$AUDIT" "$AUDIT_COMMON"; do
  ec_run "$EX_REPO" "$_s" --embed-cases -h
  check_eq "H1 $(basename "$_s") --embed-cases -h exits 0 (err=${ERR:0:200})" "0" "$RC"
  if [[ "$OUT" == *"--band-size"* && "$OUT" == *"--order"* && "$OUT" == *"--embed-apply"* ]]; then
    pass "H1 $(basename "$_s") --embed-cases -h prints the embed usage"
  else
    fail "H1 $(basename "$_s") --embed-cases -h prints the embed usage" "out=${OUT:0:300}"
  fi
  if printf '%s\n' "$OUT" | grep -q '^BAND'; then fail "H1 $(basename "$_s") -h plans nothing" "out=${OUT:0:200}"; else pass "H1 $(basename "$_s") -h plans nothing"; fi
done
case_end

case_begin "entrypoint-help-lists-embed-cases" "bin/audit-tests.sh"
ec_run "$EX_REPO" "$AUDIT" --help
check_eq "H2 audit-tests.sh --help exits 0" "0" "$RC"
for _w in "--embed-cases" "--band-size" "--order frequency|priority" "sweep-tests-embed-cases.md" "Unit=case"; do
  if [[ "$OUT" == *"$_w"* ]]; then pass "H2 audit-tests.sh --help mentions $_w"; else fail "H2 audit-tests.sh --help mentions $_w" "out=${OUT:0:400}"; fi
done
case_end

case_begin "entrypoint-common-help-lists-embed-cases" "bin/audit-tests-common.sh"
ec_run "$EX_REPO" "$AUDIT_COMMON" --help
check_eq "H3 audit-tests-common.sh --help exits 0" "0" "$RC"
for _w in "--embed-cases" "--band-size" "--order frequency|priority" "sweep-tests-embed-cases.md" "unit=case"; do
  if [[ "$OUT" == *"$_w"* ]]; then pass "H3 audit-tests-common.sh --help mentions $_w"; else fail "H3 audit-tests-common.sh --help mentions $_w" "out=${OUT:0:400}"; fi
done
case_end

grp_done exclusivity-help-cases.sh
