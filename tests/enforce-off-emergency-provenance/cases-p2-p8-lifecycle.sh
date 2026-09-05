# tests/enforce-off-emergency-provenance/cases-p2-p8-lifecycle.sh
# P2-P8: marker lifecycle (staleness, attribution, freshness/future bounds,
# corruption) and the WORKTREE/WORKFLOW target symmetry (P8, CPR-ORTH).
# Sourced by ../enforce-off-emergency-provenance.sh; relies on that file's
# shared helpers (submit_prompt, run_emergency, marker_of, provenance_in, etc.).
# Tests: hooks/record-off-skill-invocation.js, hooks/lib/off-emergency-provenance.js, hooks/workflow-mark/enforce-override-handlers/off-clearance.js, hooks/lib/protected-basenames.js, hooks/block-clearance-token-write.js, settings.json
# Tags: off-clearance, emergency-off, provenance, audit, userpromptsubmit, session-marker, security, scope:common, pwsh-not-required, TL2, hook-registration

run_P2_stale_marker() {
# --- P2: any other prompt clears a stale marker ----------------------------
# The sentinel is emitted in the same turn as the invocation, so a marker that
# survives into the next prompt is stale by construction and must not be able to
# vouch for whatever the model does later.
sid=pv2sid
submit_prompt "$sid" "/enforce-workflow-off"
assert_file "P2 precondition: marker present" "$(marker_of "$sid")"
submit_prompt "$sid" "now please refactor the parser"
assert_absent "P2 an unrelated later prompt clears the stale marker" "$(marker_of "$sid")"

# Clearing is session-scoped: another session's marker must survive.
sid=pv2sid; other=pv2other
submit_prompt "$other" "/enforce-workflow-off"
submit_prompt "$sid" "unrelated prompt"
assert_file "P2 clearing is session-scoped (other session's marker survives)" "$(marker_of "$other")"
rm -f "$(marker_of "$other")"
}

# P3 and P4 are deliberately ONE function: P4's first case is the exact replay
# the single-use rule exists to stop, and it reuses P3's own `sid` (pv3sid) and
# the marker state P3 left behind - splitting them across files would hide that
# coupling instead of documenting it.
run_P3_P4_attribution() {
# --- P3: fresh marker -> attributed, stamped in BOTH records, consumed -----
sid=pv3sid
submit_prompt "$sid" "/enforce-workflow-off"
out=$(run_emergency "$sid" "$(emerg_cmd WORKFLOW 'examiner is broken')")
assert_contains "P3 handler reports the sentinel as handled" '"handled":true' "$out"
assert_file "P3 override marker written" "$TMP/$sid.workflow-off"
assert_eq "P3 override marker stamped provenance=user_skill_invocation" "user_skill_invocation" "$(provenance_in "$TMP/$sid.workflow-off")"
assert_file "P3 audit record written" "$(audit_of "$sid")"
audit=$(cat "$(audit_of "$sid")" 2>/dev/null)
assert_json_field "P3 audit record_type=escape_hatch_event" record_type escape_hatch_event "$audit"
assert_json_field "P3 audit stamped provenance=user_skill_invocation" provenance user_skill_invocation "$audit"
assert_absent "P3 provenance marker is CONSUMED (single-use)" "$(marker_of "$sid")"

# --- P4: no marker -> unattributed, and the override STILL applies ---------
# Re-emitting straight after P3 is the exact replay the single-use rule exists to
# stop: the marker is gone, so the second activation must be recorded honestly -
# and must still succeed.
out=$(run_emergency "$sid" "$(emerg_cmd WORKFLOW 'second emission, no marker')")
assert_contains "P4 replay still handled" '"handled":true' "$out"
assert_eq "P4 replay without a marker is unattributed" "unattributed" "$(provenance_in "$TMP/$sid.workflow-off")"
assert_contains "P4 override still applied (no fatal)" '"fatal":[]' "$out"
audit=$(cat "$(audit_of "$sid")" 2>/dev/null)
assert_json_field "P4 audit records the unattributed activation" provenance unattributed "$audit"

sid=pv4sid
out=$(run_emergency "$sid" "$(emerg_cmd WORKFLOW 'never invoked the skill')")
assert_file "P4 override applied with no marker ever present" "$TMP/$sid.workflow-off"
assert_eq "P4 provenance=unattributed when no marker ever existed" "unattributed" "$(provenance_in "$TMP/$sid.workflow-off")"
assert_contains "P4 absence of provenance never gates the escape hatch" '"fatal":[]' "$out"
}

run_P5_freshness() {
# --- P5: a marker older than the freshness bound is not evidence -----------
# The bound is belt-and-braces behind P2's clearing: if a marker somehow survives
# (crash, killed session, out-of-band write), age alone must disqualify it - while
# still being consumed so it cannot accumulate.
sid=pv5sid
mk_marker "$sid" -660000
out=$(run_emergency "$sid" "$(emerg_cmd WORKFLOW 'stale marker present')")
assert_eq "P5 marker older than the 10-minute bound is unattributed" "unattributed" "$(provenance_in "$TMP/$sid.workflow-off")"
assert_absent "P5 stale marker is consumed anyway" "$(marker_of "$sid")"
assert_contains "P5 override still applied despite the stale marker" '"fatal":[]' "$out"

# A marker just inside the bound must still count, or the bound would be a
# coin-flip rather than a rule.
sid=pv5fresh
mk_marker "$sid" -60000
run_emergency "$sid" "$(emerg_cmd WORKFLOW 'one minute old marker')" >/dev/null
assert_eq "P5 marker inside the bound is attributed" "user_skill_invocation" "$(provenance_in "$TMP/$sid.workflow-off")"
}

run_P6_future() {
# --- P6: a future-dated marker cannot buy attribution ----------------------
# Without the lower bound, `invoked_at` far in the future would stay "fresh"
# indefinitely - a single forged timestamp would vouch for every later emission.
sid=pv6sid
mk_marker "$sid" 600000
out=$(run_emergency "$sid" "$(emerg_cmd WORKFLOW 'future dated marker')")
assert_eq "P6 future-dated marker is unattributed" "unattributed" "$(provenance_in "$TMP/$sid.workflow-off")"
assert_contains "P6 override still applied" '"fatal":[]' "$out"
}

run_P7_corrupt() {
# --- P7: an unreadable marker degrades to unattributed, never to a failure -
sid=pv7sid
printf 'not json at all' > "$(marker_of "$sid")"
out=$(run_emergency "$sid" "$(emerg_cmd WORKFLOW 'corrupt marker')")
assert_eq "P7 corrupt marker is unattributed" "unattributed" "$(provenance_in "$TMP/$sid.workflow-off")"
assert_absent "P7 corrupt marker is consumed" "$(marker_of "$sid")"
assert_contains "P7 override still applied" '"fatal":[]' "$out"
}

run_P8_worktree_orth() {
# --- P8: CPR-ORTH - the WORKTREE emergency gets identical treatment ----------
sid=pv8sid
submit_prompt "$sid" "/enforce-workflow-off"
out=$(run_emergency "$sid" "$(emerg_cmd WORKTREE 'worktree emergency')")
assert_file "P8 worktree emergency writes .worktree-off" "$TMP/$sid.worktree-off"
assert_eq "P8 worktree emergency is provenance-stamped too" "user_skill_invocation" "$(provenance_in "$TMP/$sid.worktree-off")"
assert_absent "P8 worktree emergency consumes the marker" "$(marker_of "$sid")"
}
