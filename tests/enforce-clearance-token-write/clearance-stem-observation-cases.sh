#!/usr/bin/env bash
# tests/enforce-clearance-token-write/clearance-stem-observation-cases.sh
# Tests: hooks/lib/protected-basenames.js, hooks/lib/active-session-ids.js, hooks/lib/worktree-notes-session-ids.js
# Tags: off-clearance, clearance-token, session-marker, stem-rule, config-dependent, observation, fail-closed, glob-bypass, table-driven, scope:common, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch): a real multi-worktree checkout with live
# sessions writing the state store concurrently — tests/TL3-hook-clearance-token-write.sh.
# isClearanceBearingStem's verdict is a function of OBSERVED STATE, not of the stem alone:
# the workflow state store, the agent-writable WORKTREE_NOTES.md Session-ID line, and
# whether the observation completed at all. Sibling suites inherit whatever environment
# the runner happened to have, so they only ever exercise ONE column of that matrix and a
# narrowing that keyed on the wrong column would pass all of them.

set -u

SEC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$(cd "$SEC_DIR/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
HOOK="$AGENTS_DIR/hooks/block-clearance-token-write.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
# shellcheck source=tests/lib/clearance-hook-harness.sh
. "$AGENTS_DIR/tests/lib/clearance-hook-harness.sh"

PB_NODE="$_AGENTS_DIR_NODE/hooks/lib/protected-basenames.js"
TMP=$(make_tmp)

# --- The three config axes, each set EXPLICITLY (rules/test/fixture-isolation.md).
# STORE holds one state entry per "live" session, so its stems are the noncanonical ids
# a clearance reader could be keyed on. CWD_NOTES carries the agent-writable Session-ID
# line; CWD_PLAIN is the same directory shape without it, so the notes axis moves alone.
# MISSING_STORE does not exist, which is what makes the observation INCOMPLETE.
mkdir -p "$TMP/store" "$TMP/plans" "$TMP/cwd-plain" "$TMP/cwd-notes"
printf '%s' '{}' > "$TMP/store/store-sid-42.json"
printf '%s' '{}' > "$TMP/store/other-live-sid.json"
printf 'Session-ID: notes-sid-7\n' > "$TMP/cwd-notes/WORKTREE_NOTES.md"
STORE="$(node_path "$TMP")/store"
MISSING_STORE="$(node_path "$TMP")/no-such-store"
PLANS="$(node_path "$TMP")/plans"

if [ "$HOOK_PRESENT" = "yes" ]; then pass "OS0 hook file present"; else fail "OS0 hook file MISSING at $HOOK"; fi

cat > "$TMP/observe-probe.js" <<'PROBE_EOF'
"use strict";
// Emits `<label>=<verdict>` lines. The stem rows call isClearanceBearingStem directly
// (the branch under test); the classifier rows go through the two public entry points,
// so a branch that is right in isolation but mis-wired downstream still shows up.
const p = require(process.argv[2]);
const sessionCtx = { sessionId: "stdin-sid-9" };
const UUID = "0f3d9a21-4b6c-4d7e-8f90-a1b2c3d4e5f6";
const stem = (s, spelling) => String(p.isClearanceBearingStem(s, { sessionCtx, spelling }));
const cleanPath = (b) => String(p.classifyProtectedPath(b, { sessionCtx, spelling: "clean" }));
const bashTok = (t) => String(p.classifyProtectedBashToken(t, { sessionCtx }));
const out = [];
for (const s of ["stdin-sid-9", "store-sid-42", "other-live-sid", "notes-sid-7",
                 "issue-2108-survey", "backup-store-sid-42", "report.2026-08-25", UUID]) {
  const label = s === UUID ? "uuid" : s;
  out.push(`stem-clean ${label}=${stem(s, "clean")}`);
  out.push(`stem-bash ${label}=${stem(s, "bash")}`);
}
out.push(`cls active=${cleanPath("store-sid-42.workflow-off")}`);
out.push(`cls inactive=${cleanPath("issue-2108-survey.workflow-off")}`);
out.push(`cls notes=${cleanPath("notes-sid-7.off-clearance")}`);
out.push(`cls stdin=${cleanPath("stdin-sid-9.off-clearance")}`);
// GLOB BYPASS: stemAllowed is consulted only on the NON-glob branch, because a glob's
// post-expansion stem is unprovable. The pair differs by one trailing `*`.
out.push(`cls nonglob-inactive=${bashTok("issue-2108-survey.workflow-off")}`);
out.push(`cls glob-inactive=${bashTok("issue-2108-survey.workflow-of*")}`);
out.push(`cls glob-active=${bashTok("store-sid-42.workflow-of*")}`);
out.push("DONE=yes");
process.stdout.write(out.join("\n") + "\n");
PROBE_EOF

# run_observation <cwd> <workflow-dir> -> the probe's output for that config
run_observation() {
    (
        cd "$1" || exit 1
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
        CLAUDE_WORKFLOW_DIR="$2" WORKFLOW_PLANS_DIR="$PLANS" \
            "$RWT" 30 node "$TMP/observe-probe.js" "$PB_NODE" 2>/dev/null
    )
}

# Each column is a SEPARATE node process on purpose: observeActiveSessionIds memoizes for
# the life of the process, keyed on [sessionId, transcriptPath, cwd], so two columns read
# inside one process would silently share the first column's answer.
OBS_STORE="$(run_observation "$TMP/cwd-plain" "$STORE")"
OBS_NOTES="$(run_observation "$TMP/cwd-notes" "$STORE")"
OBS_BROKEN="$(run_observation "$TMP/cwd-plain" "$MISSING_STORE")"

_get() { printf '%s\n' "$1" | grep -F "$2 $3=" | head -1 | sed 's/.*=//'; }

# The harness asserts hook VERDICTS; these rows assert classifier RETURN VALUES, so the
# comparison is spelled out here. An empty `got` (a probe line that never appeared) is
# reported as such rather than compared, so a renamed label cannot read as a mismatch.
assert_eq() {  # <name> <want> <got>
    if [ -z "$3" ]; then fail "$1 - no probe line (want '$2')"
    elif [ "$2" = "$3" ]; then pass "$1 -> $3"
    else fail "$1 want '$2' got '$3'"; fi
}

# A crashed probe prints nothing, and every _get below would return the empty string —
# which is neither "true" nor "false", so the tables would go red rather than vacuously
# green. This guard names the cause instead of leaving 40 identical mystery failures.
for _col in STORE NOTES BROKEN; do
    eval "_out=\$OBS_$_col"
    if [ "$(printf '%s\n' "$_out" | grep -c '^DONE=yes$')" = "1" ]; then
        pass "OS-run the $_col observation column ran to completion"
    else
        fail "OS-run the $_col observation column did NOT complete; output=$_out"
    fi
done

echo ""
echo "=== OS-A: isClearanceBearingStem across the three observation states ==="
# Columns: stem label | tag | want(store-only) | want(store+notes) | want(observation broken).
# Reading a ROW left to right is the config-dependence claim; reading a COLUMN down is the
# stem rule at one fixed configuration. Both directions have to hold.
while IFS='|' read -r label tag w_store w_notes w_broken; do
    [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
    label="$(trim "$label")"; tag="${tag//[[:space:]]/}"
    w_store="${w_store//[[:space:]]/}"; w_notes="${w_notes//[[:space:]]/}"; w_broken="${w_broken//[[:space:]]/}"
    assert_eq "OS-A $tag $label [store-only]" "$w_store" "$(_get "$OBS_STORE" "$tag" "$label")"
    assert_eq "OS-A $tag $label [store+notes]" "$w_notes" "$(_get "$OBS_NOTES" "$tag" "$label")"
    assert_eq "OS-A $tag $label [observation broken]" "$w_broken" "$(_get "$OBS_BROKEN" "$tag" "$label")"
done <<'STEM_TABLE'
# --- Observation-FREE branch: a canonical sid shape, and the id this process was handed ---
# --- on stdin, are clearance-bearing before anything on disk is consulted. Constant ---
# --- across all three columns — that is what makes them the control for the rows below. ---
uuid                 | stem-clean | true  | true  | true
uuid                 | stem-bash  | true  | true  | true
stdin-sid-9          | stem-clean | true  | true  | true
stdin-sid-9          | stem-bash  | true  | true  | true
# --- ACTIVE noncanonical stems: not a uuid, not a timestamp, clearance-bearing ONLY ---
# --- because a state entry (store-*) or a WORKTREE_NOTES.md line (notes-*) says a ---
# --- reader could key on them. The notes rows are false in the first column and true ---
# --- in the second with nothing else changed, which is the axis isolated. ---
store-sid-42         | stem-clean | true  | true  | true
other-live-sid       | stem-clean | true  | true  | true
notes-sid-7          | stem-clean | false | true  | true
notes-sid-7          | stem-bash  | false | true  | true
# --- INACTIVE stems: no reader can open them, so they are ordinary artifact names ---
# --- while the observation holds — and clearance-bearing the moment it does not. ---
issue-2108-survey    | stem-clean | false | false | true
issue-2108-survey    | stem-bash  | false | false | true
report.2026-08-25    | stem-clean | false | false | true
report.2026-08-25    | stem-bash  | false | false | true
# --- The spelling split (#2108 R2c) is orthogonal to observation: a stem that ENDS ---
# --- with a live id keeps its tail match on the Bash side in every column, and never ---
# --- gets one on the clean side until the observation itself fails. ---
backup-store-sid-42  | stem-clean | false | false | true
backup-store-sid-42  | stem-bash  | true  | true  | true
STEM_TABLE

echo ""
echo "=== OS-B: the same three states, read through the public classifiers ==="
while IFS='|' read -r label want_s want_n want_b; do
    [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
    label="${label//[[:space:]]/}"
    want_s="${want_s//[[:space:]]/}"; want_n="${want_n//[[:space:]]/}"; want_b="${want_b//[[:space:]]/}"
    assert_eq "OS-B $label [store-only]" "$want_s" "$(_get "$OBS_STORE" cls "$label")"
    assert_eq "OS-B $label [store+notes]" "$want_n" "$(_get "$OBS_NOTES" cls "$label")"
    assert_eq "OS-B $label [observation broken]" "$want_b" "$(_get "$OBS_BROKEN" cls "$label")"
done <<'CLS_TABLE'
# --- The stem verdict has to reach the verdict the hook actually acts on. ---
stdin            | token  | token  | token
active           | marker | marker | marker
notes            | null   | token  | token
inactive         | null   | null   | marker
# --- GLOB BYPASS: `stemAllowed` is consulted only where the post-expansion stem is ---
# --- knowable. The nonglob/glob pair below differs by ONE trailing `*` on an INACTIVE ---
# --- stem: the plain spelling is allowed while the observation holds, the glob is not, ---
# --- in every column. Without the nonglob twin the glob rows would also pass a build ---
# --- that had stopped narrowing anything at all. ---
nonglob-inactive | null   | null   | marker
glob-inactive    | marker | marker | marker
glob-active      | marker | marker | marker
CLS_TABLE

# --- Fixture integrity: the assertions above are only about observation if the store
# --- and notes files are still the ones this test wrote. A probe that mutated them
# --- would make the columns agree for the wrong reason.
if [ -f "$TMP/store/store-sid-42.json" ] && [ -f "$TMP/cwd-notes/WORKTREE_NOTES.md" ] \
   && [ ! -e "$TMP/no-such-store" ]; then
    pass "OS-NEG the observed fixture is unchanged, and the broken column stayed broken"
else
    fail "OS-NEG the fixture moved under the probe - the columns above are not comparable"
fi

rm -r -f "$TMP" 2>/dev/null || true

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
