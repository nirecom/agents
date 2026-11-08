# Tests: bin/lib/test-embed-cases.sh
# Tags: TL2, scope:common, audit-tests, embed-cases, flag-exclusivity, help, fixture
# Sourced by the -flags / -flags-common entrypoints — the flag exclusivity table, the
# --only-file rejection messages and the per-entrypoint row / help checks. Holds no cases.
# Every exit-2 row also proves the rejection is not the pre-existing "unknown argument" one.

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
  "2|--only-file tests/bin/t-alpha.sh"
  "2|--embed-cases --only-file tests/bin/t-alpha.sh --band-size 1"
  "2|--embed-cases --only-file tests/bin/t-alpha.sh --order priority"
  "2|--embed-apply WORKDIR --only-file tests/bin/t-alpha.sh"
  "2|--embed-cases --only-file tests/bin/t-alpha.sh --only-file tests/bin/t-bravo.sh"
  "2|--embed-cases --dry-run --only-file"
  "ok|--embed-cases --dry-run --only-file tests/bin/t-alpha.sh"
  "note|--embed-cases --dry-run --fix-headers --only-file tests/bin/t-alpha.sh"
)

# <args>|<message>: the tec_die text each --only-file exit-2 row of EX_TABLE must print.
EX_ONLY_MSG=(
  "--only-file tests/bin/t-alpha.sh|--only-file needs --embed-cases"
  "--embed-cases --only-file tests/bin/t-alpha.sh --band-size 1|--band-size has no meaning with --only-file"
  "--embed-cases --only-file tests/bin/t-alpha.sh --order priority|--order has no meaning with --only-file"
  "--embed-apply WORKDIR --only-file tests/bin/t-alpha.sh|--embed-apply takes no other stage flag"
  "--embed-cases --only-file tests/bin/t-alpha.sh --only-file tests/bin/t-bravo.sh|--only-file given more than once"
  "--embed-cases --dry-run --only-file|--only-file needs a value"
)

# RC / stderr of every table row already run, keyed "<entrypoint>|<args>": the
# message check reads the row's own run instead of running the same argv again.
declare -A EX_SEEN_RC=() EX_SEEN_ERR=()

# ex_args <argstr> — fills EX_ARGS with the row's argv, WORKDIR resolved.
ex_args() { read -r -a EX_ARGS <<<"${1//WORKDIR/$WORKFLOW_PLANS_DIR/sweep-tests-embed/ex-run}"; }

# ex_row <entrypoint> <row> — runs one table row and asserts its expectation.
ex_row() {
  local script="${1:?}" want="${2%%|*}" argstr="${2#*|}" label
  ex_args "$argstr"
  label="EX $(basename "$script") [$argstr]"
  ec_run "$EX_REPO" "$script" "${EX_ARGS[@]}"
  EX_SEEN_RC["$script|$argstr"]="$RC"
  EX_SEEN_ERR["$script|$argstr"]="$ERR"
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

# ex_only_msgs <entrypoint> — every EX_ONLY_MSG row exits 2 with its tec_die text.
ex_only_msgs() {
  local script="${1:?}" row argstr msg label
  for row in "${EX_ONLY_MSG[@]}"; do
    argstr="${row%%|*}" msg="${row#*|}"
    if [[ -n "${EX_SEEN_RC["$script|$argstr"]+set}" ]]; then
      RC="${EX_SEEN_RC["$script|$argstr"]}" ERR="${EX_SEEN_ERR["$script|$argstr"]}"
    else
      ex_args "$argstr"
      ec_run "$EX_REPO" "$script" "${EX_ARGS[@]}"
    fi
    label="EXO $(basename "$script") [$argstr]"
    check_eq "$label exits 2" "2" "$RC"
    if [[ "$ERR" == *"ERROR: embed-cases: $msg"* ]]; then pass "$label prints: $msg"; else fail "$label prints: $msg" "err=${ERR:0:300}"; fi
  done
}

# ex_short_help <entrypoint> — `--embed-cases -h` prints the embed usage and plans nothing.
ex_short_help() {
  local script="${1:?}" b
  b="$(basename "$script")"
  ec_run "$EX_REPO" "$script" --embed-cases -h
  check_eq "H1 $b --embed-cases -h exits 0 (err=${ERR:0:200})" "0" "$RC"
  if [[ "$OUT" == *"--band-size"* && "$OUT" == *"--order"* && "$OUT" == *"--embed-apply"* ]]; then
    pass "H1 $b --embed-cases -h prints the embed usage"
  else
    fail "H1 $b --embed-cases -h prints the embed usage" "out=${OUT:0:300}"
  fi
  if [[ "$OUT" == *"--only-file"* ]]; then pass "H1 $b --embed-cases -h mentions --only-file"; else fail "H1 $b --embed-cases -h mentions --only-file" "out=${OUT:0:300}"; fi
  if printf '%s\n' "$OUT" | grep -q '^BAND'; then fail "H1 $b -h plans nothing" "out=${OUT:0:200}"; else pass "H1 $b -h plans nothing"; fi
}

grp_done exclusivity-table.sh
