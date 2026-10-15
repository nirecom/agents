#!/usr/bin/env bash
# Tests: bin/workflow/jev-judge
# Tags: TL2, bin, jev, two-stage, cli-args, usage-error, untrusted-input, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-judge.sh, sourced after _lib.sh (not standalone):
# invalid arguments exit 2 with empty stdout; an unknown or malformed ticket exits 4 with
# exactly RESULT=error and REASON=<why>, and finalize then writes nothing downstream.

echo "=== jev-judge: argument validation and ticket errors ==="
need_mod bin/workflow/jev-judge || return 0

# usage2 <label> <args...>: exit 2 and zero bytes on stdout.
usage2() {
  local label="$1"; shift
  jj "$@"
  check "$label: exit 2" "2" "$JJ_RC"
  check "$label: stdout empty" "0" "$(wc -c < "$OUT" | tr -d ' ')"
}

case_begin "jj-args-exit-2" "bin/workflow/jev-judge"
jj_fx args
usage2 "no subcommand"
usage2 "unknown subcommand" bogus --session "$SID"
usage2 "query without --session" query --point complexity-judge --stage complexity
usage2 "query sid with path traversal" query --session "../$SID" --point complexity-judge --stage complexity
usage2 "query sid with shell metacharacters" query --session "$SID;touch pwned" --point complexity-judge --stage complexity
usage2 "query point constructor (inherited key)" query --session "$SID" --point constructor --stage complexity
usage2 "query point __proto__" query --session "$SID" --point __proto__ --stage complexity
usage2 "query unknown stage" query --session "$SID" --point complexity-judge --stage bogus
usage2 "query underscore stage spelling" query --session "$SID" --point complexity-judge --stage write_code
usage2 "query outline-skip at a stage outside its stages" query --session "$SID" --point outline-skip --stage write-code
usage2 "query detail-skip at stage complexity" query --session "$SID" --point detail-skip --stage complexity
usage2 "failsafe with a point not in the registry" failsafe --session "$SID" --point plan-skip --stage outline --ticket -
usage2 "failsafe point __proto__" failsafe --session "$SID" --point __proto__ --stage outline --ticket -
usage2 "failsafe detail-skip at a stage outside its stages" failsafe --session "$SID" --point detail-skip --stage complexity --ticket -
usage2 "failsafe outline-skip at stage write-code" failsafe --session "$SID" --point outline-skip --stage write-code --ticket -
usage2 "finalize without --ticket" finalize --session "$SID"
usage2 "finalize with a non-hex ticket" finalize --session "$SID" --ticket 'zz;rm -rf /'
check "no file named pwned appeared in the neutral cwd" "absent" "$([ -e "$FX/cwd/pwned" ] && echo present || echo absent)"
check "a usage error queried Jev zero times" "0" "$(mock_count systemone)"
case_end

case_begin "jj-finalize-ticket-missing" "bin/workflow/jev-judge"
jj_fx missing
jj finalize --session "$SID" --ticket 0123456789abcdef
check "unknown ticket: exit 4" "4" "$JJ_RC"
check "unknown ticket: exactly two stdout lines" "2" "$(out_lines)"
check "unknown ticket: RESULT=error" "error" "$(kv RESULT)"
check "unknown ticket: REASON=ticket-missing" "ticket-missing" "$(kv REASON)"
check "unknown ticket: no decision log" "0" "$(log_count)"
check "unknown ticket: no fixed signals file" "<absent>" "$(fixed_csv complexity)"
check "unknown ticket: no owner marker" "absent" "$(pb sha "$(ctl complexity-signals-owner.json)")"
case_end

# invalid_ticket <label> <dotted-key> <json|__delete__>: query, tamper with the ticket, finalize.
invalid_ticket() {
  jj_fx "inv-$1"
  mock_p 0.01
  jj_query complexity
  local tf; tf="$(ticket_file "$TICKET")"
  if [ -z "$tf" ]; then fail "$1: ticket file for [$TICKET] not found"; return 0; fi
  pb json-set "$(np "$tf")" "$2" "$3" >/dev/null
  jj finalize --session "$SID" --ticket "$TICKET"
  check "$1: exit 4" "4" "$JJ_RC"
  check "$1: exactly two stdout lines" "2" "$(out_lines)"
  check "$1: REASON=ticket-invalid" "ticket-invalid" "$(kv REASON)"
  check "$1: no fixed signals file written" "<absent>" "$(fixed_csv complexity)"
  check "$1: no decision record" "0" "$(lq "$TICKET" 'recs.length')"
}

case_begin "jj-finalize-ticket-invalid" "bin/workflow/jev-judge"
invalid_ticket "version-bumped" "version" "99"
invalid_ticket "kind-deleted" "kind" "__delete__"
invalid_ticket "unregistered-point" "point" '"constructor"'
invalid_ticket "frozen-mode-deleted" "mode" "__delete__"
case_end
