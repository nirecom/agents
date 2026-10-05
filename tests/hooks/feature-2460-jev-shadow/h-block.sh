#!/usr/bin/env bash
# Tests: hooks/jev-shadow-post.js
# Tags: TL2, hooks, jev, additional-context, injection-safety, terminal-sanitisation, scope:issue-specific, pwsh-not-required, notes-session-step-fallback, no-injection, shadow-silent, notes-session-binding, latest-entered-binding, record-before-sweep

# Shadow mode shows the main conversation nothing of Jev: the post hook writes zero bytes to
# stdout (no hookSpecificOutput, no additionalContext, no [JEV] text) in every outcome, and
# the decision record is the only output. Untrusted response text never reaches the log, and
# the workflow step falls back to the cwd's WORKTREE_NOTES session only when that session's
# state is bound to this very worktree.

# TL3 gap (what this test does NOT catch): what the real host does with an empty PostToolUse
# stdout; TL3-hook-agent-jev-shadow.sh T4 observes that no [JEV] text reaches the transcript.

. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
mock_start

# vocab_only <text>: "ok" when every S<n>-token in <text> is a known signal id or S0.
vocab_only() {
  local t bad=""
  for t in $(printf '%s' "$1" | grep -oE 'S[0-9]+b?-[A-Za-z0-9-]+'); do
    case ",$SIGNAL_CSV,S0-undecidable," in *",$t,"*) ;; *) bad="$bad $t" ;; esac
  done
  if [ -z "$bad" ]; then echo ok; else echo "unknown:$bad"; fi
}

echo "=== the post hook is silent; the record is the output ==="
case_begin "h-post-silent-record-only" "hooks/jev-shadow-post.js"
fx_new h-shape
SID="jev2460-h-shape"
mock_mode '{}'
pair "$SID" toolu_h_shape
check "post exits 0 and writes zero bytes to stdout" "0|empty" "$HOOK_RC|$(stdout_state)"
check "the paired record is logged: jev ok, llm ok, agreement true" "1|ok|ok|true" \
  "$(rq toolu_h_shape 'recs.length + "|" + (r && [r.jev.status, r.llm.status, r.agreement].join("|"))')"
check "no [JEV] text and no API key anywhere in the state dir" "absent|absent" \
  "$(grep_absent '[JEV]' "$FX/state")|$(grep_absent "$SENTINEL_KEY" "$FX/state")"
case_end

echo "=== untrusted response text never reaches the record ==="
case_begin "h-record-no-echo-of-untrusted-response" "hooks/jev-shadow-post.js"
fx_new h-inject
SID="jev2460-h-inject"
mock_mode '{"systemone":"extra-inject"}'
pair "$SID" toolu_h_inject
check "extra-inject: post exits 0, stdout empty, one record" "0|empty|1" "$HOOK_RC|$(stdout_state)|$(rq toolu_h_inject 'recs.length')"
check "extra-inject: no S9-evil and no rm -rf in the log" "absent|absent" \
  "$(grep_absent 'S9-evil' "$FX/state")|$(grep_absent 'rm -rf' "$FX/state")"
check "extra-inject: every signal token in the jev answer is from the vocabulary" "ok" \
  "$(vocab_only "$(rq toolu_h_inject 'r && String(r.jev.answer)')")"
case_end

case_begin "h-record-sanitised-model" "hooks/jev-shadow-post.js"
fx_new h-model
SID="jev2460-h-model"
mock_mode '{"systemone":"badmodel-ctrl"}'
pair "$SID" toolu_h_model
check "control-char model: post stdout empty, model logged as unknown" "empty|unknown" \
  "$(stdout_state)|$(rq toolu_h_model 'r && r.jev.model')"
check "control-char model: no SIGNALS: line smuggled into the log" "absent" "$(grep_absent 'SIGNALS:' "$FX/state")"
case_end

echo "=== the logged stage follows the workflow step ==="
case_begin "h-record-stage-from-workflow-step" "hooks/jev-shadow-post.js"
fx_new h-stage
SID="jev2460-h-stage"
mock_mode '{}'
check "fixture: the workflow state sits at clarify_intent" "clarify_intent" "$(hq seed-step "$SID" clarify_intent)"
pair "$SID" toolu_h_stage
check "clarify_intent dispatch: the logged step and stage are clarify_intent and cos1; stdout empty" \
  "clarify_intent|cos1|empty" "$(rq toolu_h_stage 'r && [r.step, r.stage].join("|")')|$(stdout_state)"
case_end

# step_via_notes <tag> <hook-sid> <notes-sid>: WORKTREE_NOTES.md in the payload cwd names
# <notes-sid>; the pre hook runs alone (its pending is inspected), then the post hook.
# Sets PEND_STEP (pending step|stage) and REC_STEP (record step|stage).
step_via_notes() {
  local tid="toolu_h_wsid_$1"
  printf '# Worktree Notes\n\nSession-ID: %s\n' "$3" > "$FX/cwd/WORKTREE_NOTES.md"
  mkpayload "$FX/io/pre-$tid.json" pre "$2" "$tid" --cwd "$(np "$FX/cwd")"
  mkpayload "$FX/io/post-$tid.json" post "$2" "$tid" --cwd "$(np "$FX/cwd")"
  run_hook pre "$FX/io/pre-$tid.json"
  PEND_STEP="$(hq json-expr "$(np "$JEVDIR/$2/pending/$tid.json")" 'o && [String(o.step), o.stage].join("|")')"
  run_hook post "$FX/io/post-$tid.json"
  REC_STEP="$(rq "$tid" 'r && [String(r.step), r.stage].join("|")')"
}
case_begin "h-step-from-notes-session" "hooks/jev-shadow-post.js"
fx_new h-wsid
mock_mode '{}'
check "fixture: the WORKTREE_NOTES session sits at clarify_intent" "clarify_intent" "$(hq seed-step jev2460-h-wsid clarify_intent)"
check "fixture: the WORKTREE_NOTES session's state is bound to the payload cwd" "$(np "$FX/cwd")" \
  "$(hq bind-worktree jev2460-h-wsid "$(np "$FX/cwd")")"
step_via_notes a jev2460-h-hook-nostate jev2460-h-wsid
check "hook sid has no workflow state: the pre hook's pending carries the bound notes session's step and stage" \
  "clarify_intent|cos1" "$PEND_STEP"
check "hook sid has no workflow state: the post hook's record carries the bound notes session's step and stage" \
  "clarify_intent|cos1" "$REC_STEP"
case_end
case_begin "h-step-notes-unbound" "hooks/jev-shadow-post.js"
fx_new h-wsid-unbound
mock_mode '{}'
check "fixture: the WORKTREE_NOTES session sits at clarify_intent" "clarify_intent" "$(hq seed-step jev2460-h-wsid3 clarify_intent)"
check "fixture: its state.cwd is the fixture project (not the payload cwd), no session_worktree" "$(np "$FX/proj")|undefined" \
  "$(hq state-bind jev2460-h-wsid3)"
step_via_notes d jev2460-h-hook-nostate3 jev2460-h-wsid3
check "notes session state not bound to this worktree: step null, stage unknown in pending and record" \
  "null|unknown|null|unknown" "$PEND_STEP|$REC_STEP"
mkdir -p "$FX/other"
check "fixture: the notes session is now bound to a different worktree" "$(np "$FX/other")" \
  "$(hq bind-worktree jev2460-h-wsid3 "$(np "$FX/other")")"
step_via_notes e jev2460-h-hook-nostate3 jev2460-h-wsid3
check "notes session bound to another worktree: step null, stage unknown in pending and record" \
  "null|unknown|null|unknown" "$PEND_STEP|$REC_STEP"
case_end
case_begin "h-step-notes-entered-binds" "hooks/jev-shadow-post.js"
fx_new h-wsid-entered
mock_mode '{}'
check "fixture: the WORKTREE_NOTES session sits at clarify_intent" "clarify_intent" "$(hq seed-step jev2460-h-wsid4 clarify_intent)"
check "fixture: a worktree entered event projects the notes session's state.cwd to the payload cwd" "$(np "$FX/cwd")" \
  "$(hq bind-worktree jev2460-h-wsid4 "$(np "$FX/cwd")" entered)"
step_via_notes f jev2460-h-hook-nostate4 jev2460-h-wsid4
check "entered-event binding: pending and record carry the notes session's step and stage" \
  "clarify_intent|cos1|clarify_intent|cos1" "$PEND_STEP|$REC_STEP"
case_end
# C12: a session started on the main checkout has state.cwd = that checkout from its start context
# alone; that never binds, so a main-checkout WORKTREE_NOTES cannot lend another session's step.
case_begin "h-step-notes-start-context-unbound" "hooks/jev-shadow-post.js"
fx_new h-wsid-start
mock_mode '{}'
check "fixture: the WORKTREE_NOTES session sits at clarify_intent" "clarify_intent" "$(hq seed-step jev2460-h-wsid5 clarify_intent)"
check "fixture: only session_start_context.cwd names the payload cwd (no entered event, no session_worktree)" \
  "$(np "$FX/cwd")|undefined" "$(hq bind-worktree jev2460-h-wsid5 "$(np "$FX/cwd")" cwd >/dev/null; hq state-bind jev2460-h-wsid5)"
step_via_notes g jev2460-h-hook-nostate5 jev2460-h-wsid5
check "start-context-only cwd: step null, stage unknown in pending and record" \
  "null|unknown|null|unknown" "$PEND_STEP|$REC_STEP"
case_end
# C12: an entered event without its own usable cwd (null, absent, or a fallback-process-cwd guess) is no
# binding either, even though state.cwd then equals the payload cwd through the start context.
case_begin "h-step-notes-entered-no-own-cwd-unbound" "bin/workflow/lib/jev-complexity-adapter.js"
_i=0
for _via in entered-null-cwd entered-missing-cwd entered-fallback; do
  _i=$((_i + 1))
  fx_new "h-wsid-enc$_i"
  mock_mode '{}'
  check "fixture ($_via): the WORKTREE_NOTES session sits at clarify_intent" "clarify_intent" \
    "$(hq seed-step "jev2460-h-wsid-enc$_i" clarify_intent)"
  check "fixture ($_via): state.cwd projects to the payload cwd and worktree_entered_at is set" "$(np "$FX/cwd")|true" \
    "$(hq bind-worktree "jev2460-h-wsid-enc$_i" "$(np "$FX/cwd")" "$_via")"
  step_via_notes "enc$_i" "jev2460-h-hook-nostate-enc$_i" "jev2460-h-wsid-enc$_i"
  check "$_via: step null, stage unknown in pending and record" "null|unknown|null|unknown" "$PEND_STEP|$REC_STEP"
done
case_end
case_begin "h-step-hook-session-wins" "hooks/jev-shadow-post.js"
fx_new h-wsid-own
mock_mode '{}'
check "fixture: the hook session sits at outline" "outline" "$(hq seed-step jev2460-h-own outline)"
check "fixture: the WORKTREE_NOTES session sits at clarify_intent" "clarify_intent" "$(hq seed-step jev2460-h-wsid2 clarify_intent)"
check "fixture: the WORKTREE_NOTES session's state is bound to the payload cwd" "$(np "$FX/cwd")" \
  "$(hq bind-worktree jev2460-h-wsid2 "$(np "$FX/cwd")")"
step_via_notes b jev2460-h-own jev2460-h-wsid2
check "hook sid has a workflow state: pending and record keep its own step" "outline|outline|outline|outline" "$PEND_STEP|$REC_STEP"
case_end
case_begin "h-step-none-without-state" "hooks/jev-shadow-post.js"
fx_new h-wsid-none
mock_mode '{}'
step_via_notes c jev2460-h-none jev2460-h-wsid-nostate
check "neither session has a workflow state: step null, stage unknown in pending and record" \
  "null|unknown|null|unknown" "$PEND_STEP|$REC_STEP"
case_end

echo "=== fallback outcomes are recorded, never shown ==="
case_begin "h-record-on-no-key" "hooks/jev-shadow-post.js"
fx_new h-nokey
SID="jev2460-h-nokey"
mock_mode '{}'
pair "$SID" toolu_h_nokey TYPESAFE_API_KEY=__unset__
check "no-key: post exits 0 and writes nothing to stdout" "0|empty" "$HOOK_RC|$(stdout_state)"
check "no-key: the record carries jev.status no-key and fallback_reason no-key" "1|no-key|no-key" \
  "$(rq toolu_h_nokey 'recs.length + "|" + (r && [r.jev.status, r.fallback_reason].join("|"))')"
check "no-key: no key value and no SIGNALS: line in the log" "absent|absent" \
  "$(grep_absent "$SENTINEL_KEY" "$FX/state")|$(grep_absent 'SIGNALS:' "$FX/state")"
case_end

echo "=== the post hook's own record lands before the orphan sweeps run ==="
# An unbounded sweep must not eat the hook timeout first: with sweep or retention ahead of
# the record, an orphan record would be the first line of the log instead of the trigger's.
case_begin "h-record-before-sweeps" "hooks/jev-shadow-post.js"
fx_new h-order
SID="jev2460-h-order"
OLD_SID="jev2460-h-order-old"
mock_mode '{}'
for _t in toolu_h_orph1 toolu_h_orph2; do
  mkpayload "$FX/io/pre-$_t.json" pre "$SID" "$_t"
  run_hook pre "$FX/io/pre-$_t.json"
done
[ -d "$JEVDIR/$SID/pending" ] && hq age "$(np "$JEVDIR/$SID/pending")" 3900000 --recursive
mkpayload "$FX/io/pre-old.json" pre "$OLD_SID" toolu_h_old
run_hook pre "$FX/io/pre-old.json"
[ -d "$JEVDIR/$OLD_SID" ] && hq age "$(np "$JEVDIR/$OLD_SID")" $((8 * 86400000)) --recursive
check "fixture: three orphan pendings (two past the TTL here, one in an 8-day-old session), no log yet" "3|nolog" \
  "$(pending_count)|$([ -e "$LOG" ] && echo log || echo nolog)"
LLM_TEXT="SIGNALS: S1-multi-file" pair "$SID" toolu_h_trigger
check "post exits 0 and writes nothing to stdout" "0|empty" "$HOOK_RC|$(stdout_state)"
check "the trigger's record is the first log line; the session and retention orphans follow as llm missing" \
  "4|toolu_h_trigger:ok|toolu_h_old:missing,toolu_h_orph1:missing,toolu_h_orph2:missing" \
  "$(hq qa "$(np "$LOG")" 'recs.length + "|" + (recs[0] && recs[0].tool_use_id + ":" + recs[0].llm.status) + "|" + recs.slice(1).map((x) => x.tool_use_id + ":" + x.llm.status).sort().join(",")')"
check "both sweeps still ran: no pending left, the 8-day-old session dir is removed" "0|absent" \
  "$(pending_count)|$([ -d "$JEVDIR/$OLD_SID" ] && echo present || echo absent)"
case_end

finish
