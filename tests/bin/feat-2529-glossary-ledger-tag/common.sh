# tests/bin/feat-2529-glossary-ledger-tag/common.sh
# Shared fixture of the T8 parts (#2529): ledger builders, the CLI and library
# drivers, and the two ways a ledger grant reaches state (seeded directly, or
# through the real WORKFLOW_GLOSSARY_ACCEPTED sentinel and workflow-mark.js).
# Sourced after the pins by tests/bin/feat-2529-glossary-ledger-tag{,-core-review,-grant,-reading}.sh.

LT_CLI="$SCRIPT_CHECKOUT_ROOT/bin/concern-ledger"
LT_LIB="$SCRIPT_CHECKOUT_ROOT/bin/lib/concern-ledger.sh"
LT_DRIFT="$SCRIPT_CHECKOUT_ROOT/bin/lib/concern-ledger/drift-tag.sh"
LT_AGENTS_N="$(np "$SCRIPT_CHECKOUT_ROOT")"
LT_GRANT_CLI="$LT_AGENTS_N/bin/check-glossary-ledger-grant"
LT_WST="$LT_AGENTS_N/tests/lib/workflow-state-tool.js"
LT_FORMATS="outline-plan detail-plan test-review review-security-shared"
# The core-four-formats halves (one per entrypoint); together they must be LT_FORMATS.
LT_CORE_PLAN_FORMATS="outline-plan detail-plan"
LT_CORE_REVIEW_FORMATS="test-review review-security-shared"
[ "$LT_CORE_PLAN_FORMATS $LT_CORE_REVIEW_FORMATS" = "$LT_FORMATS" ] || fail "fixture: core halves cover LT_FORMATS" "plan=$LT_CORE_PLAN_FORMATS review=$LT_CORE_REVIEW_FORMATS"

# Name-first reporters (the harness's assert_eq is actual-first).
lt_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$(printf '%q' "$2") got=$(printf '%q' "$3")"; fi; }
# Literal substring match in-shell; the failure detail shows at most 240 chars of the haystack.
lt_has() { if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1" "missing $(printf '%q' "$2") in $(printf '%q' "${3:0:240}")"; fi; }
lt_lacks() { if [[ "$3" == *"$2"* ]]; then fail "$1" "unexpected $(printf '%q' "$2") in $(printf '%q' "${3:0:240}")"; else pass "$1"; fi; }

# Implementation presence: a missing module is a FAIL, never a quiet pass.
[ -f "$LT_DRIFT" ] || fail "implementation missing: bin/lib/concern-ledger/drift-tag.sh" "the tag rule has no module yet"
[ -f "$SCRIPT_CHECKOUT_ROOT/bin/check-glossary-ledger-grant" ] || fail "implementation missing: bin/check-glossary-ledger-grant" "accept has no grant reader yet"

LT_LIB_LOADED=0
set +u
if source "$LT_LIB" >/dev/null 2>&1; then LT_LIB_LOADED=1; fi
set -u
[ "$LT_LIB_LOADED" -eq 1 ] || fail "fixture: bin/lib/concern-ledger.sh loads" "the library refused to load"
# lt <fn> <args...> — one library call in its own subshell (pattern #2111).
lt() { ( set +u; "$@" ); }
lt_rc() { local rc=0; lt "$@" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }

# Fixture texts: C1/C3/C4 are tagged at HIGH/MEDIUM/LOW, C2 is untagged. C3
# shares C1's term but not its DISCRIM, so a grant for C1 must not open C3.
LT_T1="the summary drifts from the approved wording [glossary-drift term=foo bar] in section two"
LT_T2="the helper lacks an error path for empty input"
LT_T3="[glossary-drift term=foo bar] a second spelling drift sits in the closing table"
LT_T4="the appendix spells the name another way [glossary-drift term=baz qux]"
LT_D1="$(lt cl_discrim "$LT_T1")"; LT_D2="$(lt cl_discrim "$LT_T2")"
LT_D3="$(lt cl_discrim "$LT_T3")"; LT_D4="$(lt cl_discrim "$LT_T4")"
[ -n "$LT_D1" ] && [ "$LT_D1" != "$LT_D3" ] || fail "fixture: C1 and C3 have distinct DISCRIMs" "d1=$LT_D1 d3=$LT_D3"

lt_stage_of() {
  case "$1" in
    outline-plan) printf outline ;; detail-plan) printf detail ;;
    test-review) printf tests ;; review-security-shared) printf code ;;
  esac
}
lt_step_of() {
  case "$1" in
    intent) printf clarify_intent ;; outline) printf outline ;; detail) printf detail ;;
    tests) printf review_tests ;; code) printf review_security ;; docs) printf review_docs ;;
  esac
}
lt_sid() { printf 'lt-%s-%s-%s' "$1" "$2" "$$"; }

# lt_ledger <sid> <fmt> — the path the CLI resolves for this address.
lt_ledger() {
  mkdir -p "$WORKFLOW_STATE_DIR/$1.control"
  printf '%s/%s.control/%s-concern-ledger.txt' "$WORKFLOW_STATE_DIR" "$1" "$2"
}
lt_carrier() { local l; l="$(lt_ledger "$1" "$2")"; printf '%s-concern-carrier.md' "${l%-concern-ledger.txt}"; }
# lt_row <file> <id> <sev> <state> <text> — one 11-field row, SLOT/DISCRIM from the real helpers.
lt_row() {
  printf '%s|%s|%s|1|1|%s|%s|codex|codex|-|%s\n' "$2" "$3" "$4" \
    "$(lt cl_slot_body "$5")" "$(lt cl_discrim "$5")" "$5" >> "$1"
}
# lt_build <sid> <fmt> — the standard fixture: C1..C4 open, plus a carrier
# that already holds an earlier rejection, so "unchanged" is a real comparison.
lt_build() {
  local led car
  led="$(lt_ledger "$1" "$2")"; car="$(lt_carrier "$1" "$2")"
  printf '#concern-ledger-v2|%s|%s|cycle=1\n' "$2" "$1" > "$led"
  lt_row "$led" C1 HIGH open "$LT_T1"
  lt_row "$led" C2 MEDIUM open "$LT_T2"
  lt_row "$led" C3 MEDIUM open "$LT_T3"
  lt_row "$led" C4 LOW open "$LT_T4"
  printf -- '- dprior00 [LOW] REJECTED an earlier concern — reason: settled by the outline\n' > "$car"
}
lt_snap() {
  local f out=""
  for f in "$(lt_ledger "$1" "$2")" "$(lt_carrier "$1" "$2")"; do
    if [ -f "$f" ]; then out="$out$(cksum < "$f");"; else out="${out}none;"; fi
  done
  printf '%s' "$out"
}
lt_field() { grep -m1 -- "^$3|" "$(lt_ledger "$1" "$2")" 2>/dev/null | cut -d'|' -f"$4"; }

# lt_cli <args...> — the real CLI; sets LT_RC, LT_OUT, LT_ERR.
lt_cli() {
  LT_RC=0
  run_with_timeout 60 bash "$LT_CLI" "$@" >"$LT_ROOT/cli.out" 2>"$LT_ROOT/cli.err" || LT_RC=$?
  LT_OUT="$(tr -d '\r' < "$LT_ROOT/cli.out")"; LT_ERR="$(tr -d '\r' < "$LT_ROOT/cli.err")"
}
lt_reject() { lt_cli reject --plans-dir "$WORKFLOW_PLANS_DIR" --session-id "$1" --format "$2" --id "$3" --reason "${4:-the reviewer misread the glossary}"; }
lt_accept() { lt_cli accept --plans-dir "$WORKFLOW_PLANS_DIR" --session-id "$1" --format "$2" --id "$3" --reason "${4:-the user accepted this spelling}"; }
lt_list() { lt_cli list-drift --plans-dir "$WORKFLOW_PLANS_DIR" --session-id "$1" --format "$2"; }

# #2814 1-3: the refusal messages are generalised across the glossary-drift and
# upstream-inconsistency tags; only the stable prefix is pinned here.
LT_MSG_REJECT="concern-ledger: reject refused"
LT_MSG_ACCEPT="concern-ledger: accept refused"

# lt_gj <norm> <discrim> — one ledger grant as JSON.
lt_gj() { printf '{"norm":"%s","discrim":"%s","reason":"fixture grant"}' "$1" "$2"; }
# lt_seed_grants <sid> <step> <stage> <grant-json>... — the annotation the ACCEPTED handler writes.
lt_seed_grants() {
  local sid="$1" step="$2" stage="$3" list="" g out; shift 3
  for g in "$@"; do list="${list:+$list,}$g"; done
  out="$(run_with_timeout 30 node "$LT_WST" "$LT_AGENTS_N" seed "$sid" \
    "[{\"kind\":\"step_annotation\",\"step\":\"$step\",\"key\":\"glossary_check\",\"value\":{\"v\":1,\"stage\":\"$stage\",\"ledger_grants\":[$list]}}]" 2>&1)"
  [ -z "$out" ] || fail "fixture: grant seeded for $sid/$step" "$out"
}
lt_grants_of() { run_with_timeout 30 node "$LT_WST" "$LT_AGENTS_N" path "$1" "$2" glossary_check ledger_grants 2>/dev/null; }

# lt_seed_current <sid> <step> — settle every earlier step so <step> is the
# session's current step (resolveCurrentStep), which is the stage the handler binds.
LT_SKIPPABLE=" clarify_intent research outline detail write_tests review_tests run_tests review_security review_docs "
lt_seed_current() {
  local s ev="" st out
  for s in workflow_init clarify_intent research outline detail branching_complete write_tests review_tests write_code run_tests review_security docs review_docs; do
    [ "$s" = "$2" ] && break
    case "$LT_SKIPPABLE" in *" $s "*) st=skipped ;; *) st=complete ;; esac
    ev="${ev:+$ev,}{\"kind\":\"step_status\",\"step\":\"$s\",\"status\":\"$st\"}"
  done
  [ -n "$ev" ] || return 0
  out="$(run_with_timeout 30 node "$LT_WST" "$LT_AGENTS_N" seed "$1" "[$ev]" 2>&1)"
  [ -z "$out" ] || fail "fixture: steps before $2 settled for $1" "$out"
}
# lt_mark <sid> <command> — the user's sentinel through the real PostToolUse hook.
lt_mark() {
  run_with_timeout 30 node "$LT_WST" "$LT_AGENTS_N" hookjson "$1" "$2" "$(np "$LT_ROOT")" > "$LT_ROOT/mark-in.json"
  LT_MARK_OUT="$(run_with_timeout 30 node "$LT_AGENTS_N/hooks/workflow-mark.js" < "$LT_ROOT/mark-in.json" 2>&1 | tr -d '\r')"
}
lt_accepted() { printf 'echo "<<WORKFLOW_GLOSSARY_ACCEPTED: term=%s%s — %s>>"' "$1" "${2:+ stage=$2}" "the user accepted this spelling"; }
