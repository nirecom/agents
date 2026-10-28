# tests/bin/feat-2529-glossary-ledger-tag/fail-closed.sh
# T8-6: every way the grant check can fail ends in rc 4 with nothing written;
# reject of a tagged concern stays 4 whatever the grant path looks like.

fmt=detail-plan; stage=detail; step=detail
LT_FC_STUB="$LT_ROOT/stub-node"; mkdir -p "$LT_FC_STUB" "$LT_ROOT/empty-agents"
printf '#!/usr/bin/env bash\nexit 127\n' > "$LT_FC_STUB/node"; chmod +x "$LT_FC_STUB/node"

# lt_fc_lib <label> <sid-arg> <fmt-arg> [env-assignments...] — library cl_accept on a
# granted C1 under one broken condition.
lt_fc_lib() {
  local label="$1" sa="$2" fa="$3" sid led before rc; shift 3
  sid="$(lt_sid "fc$((LT_FC_N))" "$fmt")"; LT_FC_N=$((LT_FC_N + 1))
  lt_build "$sid" "$fmt"; lt_seed_grants "$sid" "$step" "$stage" "$(lt_gj "foo bar" "$LT_D1")"
  led="$(lt_ledger "$sid" "$fmt")"; before="$(lt_snap "$sid" "$fmt")"
  [ "$sa" = "@" ] && sa="$sid"; [ "$fa" = "@" ] && fa="$fmt"
  rc="$(env "$@" bash -c '. "$1"; shift; cl_accept "$@" >/dev/null 2>&1; printf %s $?' _ "$LT_LIB" "$led" C1 "fixture reason" "$sa" "$fa" 2>/dev/null)"
  lt_eq "library accept with $label refuses (4)" 4 "$rc"
  lt_eq "library accept with $label writes nothing" "$before" "$(lt_snap "$sid" "$fmt")"
}
LT_FC_N=0
lt_fc_lib "an empty session id" "" "@" LT_FC=1
lt_fc_lib "an empty format" "@" "" LT_FC=1
lt_fc_lib "node failing to launch" "@" "@" "PATH=$LT_FC_STUB:$PATH"
# The grant reader is resolved beside the library: a library copy whose checkout lacks
# bin/check-glossary-ledger-grant refuses even though the real checkout has one.
LT_FC_NOGRANT="$LT_ROOT/nogrant-checkout"; mkdir -p "$LT_FC_NOGRANT/bin"
cp -R "$SCRIPT_CHECKOUT_ROOT/bin/lib" "$LT_FC_NOGRANT/bin/lib"
sid="$(lt_sid fcnogrant "$fmt")"; lt_build "$sid" "$fmt"; lt_seed_grants "$sid" "$step" "$stage" "$(lt_gj "foo bar" "$LT_D1")"
before="$(lt_snap "$sid" "$fmt")"
rc="$(env AGENTS_MAIN_ROOT="$SCRIPT_CHECKOUT_ROOT" bash -c '. "$1"; shift; cl_accept "$@" >/dev/null 2>&1; printf %s $?' _ "$LT_FC_NOGRANT/bin/lib/concern-ledger.sh" "$(lt_ledger "$sid" "$fmt")" C1 "fixture reason" "$sid" "$fmt" 2>/dev/null)"
lt_eq "library accept whose checkout lacks the grant reader refuses (4)" 4 "$rc"
lt_eq "library accept whose checkout lacks the grant reader writes nothing" "$before" "$(lt_snap "$sid" "$fmt")"
# Positive control for the helper: the same call with nothing broken succeeds.
sid="$(lt_sid fcok "$fmt")"; lt_build "$sid" "$fmt"; lt_seed_grants "$sid" "$step" "$stage" "$(lt_gj "foo bar" "$LT_D1")"
rc="$(bash -c '. "$1"; shift; cl_accept "$@" >/dev/null 2>&1; printf %s $?' _ "$LT_LIB" "$(lt_ledger "$sid" "$fmt")" C1 "fixture reason" "$sid" "$fmt" 2>/dev/null)"
lt_eq "library accept with a grant and nothing broken succeeds (control)" 0 "$rc"
# AGENTS_MAIN_ROOT at a decoy without the grant reader (a main worktree that predates it):
# the library still finds the reader in its own checkout, through both the library and the CLI.
sid="$(lt_sid fcdecoy "$fmt")"; lt_build "$sid" "$fmt"; lt_seed_grants "$sid" "$step" "$stage" "$(lt_gj "foo bar" "$LT_D1")"
rc="$(env AGENTS_MAIN_ROOT="$LT_ROOT/empty-agents" bash -c '. "$1"; shift; cl_accept "$@" >/dev/null 2>&1; printf %s $?' _ "$LT_LIB" "$(lt_ledger "$sid" "$fmt")" C1 "fixture reason" "$sid" "$fmt" 2>/dev/null)"
lt_eq "library accept with AGENTS_MAIN_ROOT at a decoy tree succeeds" 0 "$rc"
lt_eq "library accept with AGENTS_MAIN_ROOT at a decoy tree closes C1" rejected "$(lt_field "$sid" "$fmt" C1 3)"
sid="$(lt_sid fcdecoycli "$fmt")"; lt_build "$sid" "$fmt"; lt_seed_grants "$sid" "$step" "$stage" "$(lt_gj "foo bar" "$LT_D1")"
LT_FC_SAVED_ROOT="$AGENTS_MAIN_ROOT"; export AGENTS_MAIN_ROOT="$LT_ROOT/empty-agents"
lt_accept "$sid" "$fmt" C1
export AGENTS_MAIN_ROOT="$LT_FC_SAVED_ROOT"
lt_eq "CLI accept with AGENTS_MAIN_ROOT at a decoy tree exits 0" 0 "$LT_RC"
lt_eq "CLI accept with AGENTS_MAIN_ROOT at a decoy tree closes C1" rejected "$(lt_field "$sid" "$fmt" C1 3)"

# Corrupt state: the grant reader exits 2, accept refuses.
sid="$(lt_sid fccorrupt "$fmt")"; lt_build "$sid" "$fmt"; lt_seed_grants "$sid" "$step" "$stage" "$(lt_gj "foo bar" "$LT_D1")"
sp="$(run_with_timeout 30 node -e 'process.stdout.write(require(process.argv[1]).getStatePath(process.argv[2]))' "$LT_AGENTS_N/hooks/workflow-state/state-io/core" "$sid" 2>/dev/null)"
if [ -n "$sp" ] && [ -f "$sp" ]; then
  printf '{ not json' > "$sp"
  # A missing CLI would exit 1 from node itself; 127 keeps that from reading as a verdict.
  grc=127
  if [ -f "$SCRIPT_CHECKOUT_ROOT/bin/check-glossary-ledger-grant" ]; then
    grc=0; run_with_timeout 30 node "$LT_GRANT_CLI" --session "$sid" --format "$fmt" --norm "foo bar" --discrim "$LT_D1" >/dev/null 2>&1 || grc=$?
  fi
  lt_eq "grant reader on corrupt state exits 2" 2 "$grc"
  before="$(lt_snap "$sid" "$fmt")"
  lt_accept "$sid" "$fmt" C1
  lt_eq "accept on corrupt state refuses (4)" 4 "$LT_RC"
  lt_eq "accept on corrupt state writes nothing" "$before" "$(lt_snap "$sid" "$fmt")"
else
  fail "fixture: state file located for the corrupt-state case" "path=$sp"
fi

# A format with no stage (security-plan): neither accept nor reject closes it.
sid="$(lt_sid fcsec security-plan)"; lt_build "$sid" security-plan; before="$(lt_snap "$sid" security-plan)"
lt_accept "$sid" security-plan C1
lt_eq "security-plan accept refuses (4)" 4 "$LT_RC"
lt_reject "$sid" security-plan C1
lt_eq "security-plan reject of a tagged concern refuses (4)" 4 "$LT_RC"
lt_eq "security-plan refusals write nothing" "$before" "$(lt_snap "$sid" security-plan)"

# A tag with no term: no term, no grant can match.
sid="$(lt_sid fcnoterm "$fmt")"; led="$(lt_ledger "$sid" "$fmt")"
tx="the overview drifts [glossary-drift ] in the summary"
printf '#concern-ledger-v2|%s|%s|cycle=1\n' "$fmt" "$sid" > "$led"; lt_row "$led" C1 HIGH open "$tx"
lt_seed_grants "$sid" "$step" "$stage" "$(lt_gj "" "$(lt cl_discrim "$tx")")"
before="$(lt_snap "$sid" "$fmt")"
lt_accept "$sid" "$fmt" C1
lt_eq "accept of a termless tag refuses (4)" 4 "$LT_RC"
lt_eq "termless-tag refusal writes nothing" "$before" "$(lt_snap "$sid" "$fmt")"

# No ledger at all.
sid="$(lt_sid fcnoled "$fmt")"
lt_accept "$sid" "$fmt" C1
lt_eq "CLI accept with no ledger refuses (4)" 4 "$LT_RC"
lt_eq "library accept with no ledger refuses (4)" 4 "$(lt_rc cl_accept "$WORKFLOW_STATE_DIR/$sid.control/$fmt-concern-ledger.txt" C1 r "$sid" "$fmt")"
[ ! -e "$WORKFLOW_STATE_DIR/$sid.control/$fmt-concern-ledger.txt" ] && pass "no-ledger accept creates no ledger" || fail "no-ledger accept creates no ledger"

# Reject of a tagged concern is 4 regardless of how (or whether) grants can be read.
sid="$(lt_sid fcrj "$fmt")"; lt_build "$sid" "$fmt"; led="$(lt_ledger "$sid" "$fmt")"; before="$(lt_snap "$sid" "$fmt")"
lt_cli reject --ledger "$led" --id C1 --reason "addressed by ledger only"
lt_eq "CLI reject --ledger (no session) of a tagged concern exits 4" 4 "$LT_RC"
lt_eq "library reject under a failing node returns 4" 4 "$(PATH="$LT_FC_STUB:$PATH" lt_rc cl_reject "$led" C1 r)"
lt_eq "library reject under a bogus AGENTS_MAIN_ROOT returns 4" 4 "$(AGENTS_MAIN_ROOT="$LT_ROOT/empty-agents" lt_rc cl_reject "$led" C1 r)"
lt_eq "tagged rejects write nothing" "$before" "$(lt_snap "$sid" "$fmt")"
lt_eq "library reject of untagged C2 still returns 0" 0 "$(lt_rc cl_reject "$led" C2 "not a drift")"
