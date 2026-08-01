#!/usr/bin/env bash
# tests/feat-1763-confirm-gate-matrix.sh
# Tests: skills/issue-create/scripts/eval-confirm-gate.sh, skills/issue-create/SKILL.md
# Tags: issue-create, confirm-gate, truth-table, table-driven, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - The skill actually raising AskUserQuestion when the script says "confirm: yes".
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# S15 — the confirm gate is the logical OR of four independent conditions:
#   G1  final verdict touches EXISTING issues            (destructive / restructuring)
#       reopen | make-parent | sub-of | bulk-sub-of — all four re-parent or reopen
#       something that already exists, and sub-of/bulk-sub-of can reopen every closed
#       ancestor of the parent chain, so they are not the "additive" case (CPR-5).
#   G2  the review stage replaced the survey verdict     (survey != review)
#   G3  provenance is mid-workflow AND severity is not high
#   G4  review_result is invalid or skipped              (unverified verdict)
# Contract: eval-confirm-gate.sh <final-json> <provenance> <severity-label>
#   <final-json>  = the S13 `--out` artifact (survey.verdict / review.status live there)
#   stdout line 1: "confirm: yes" | "confirm: no"
#   stdout line 2: "reasons: G1,G3"  (empty list => "reasons: ")
#   exit 0 always — the caller decides, the script only classifies.
#
# G2 is read off review.status == "replaced" (equivalently survey.verdict != verdict);
# G4 off review.status in {invalid, skipped}. Both switches are pinned in run_gate.
#
# G3 has TWO inputs, not one. The <provenance> argument reaches the gate through the
# model, and the very thing G3 exists to detect is the model filing an issue by itself —
# so the gate also re-reads the classifier's own decision record
# (`issue-provenance --result`, a non-consuming replay) and combines the two at MINIMUM
# privilege: the argument can lower the answer, never raise it. Every row below therefore
# runs against a REAL recorded decision, arranged by running the real classifier once per
# environment (see setup_replay_envs) rather than by inventing a record shape here.
# Without that setup every row would silently collapse to "no record → mid-workflow → G3"
# and the table would be pinning the absence of a record instead of the gate.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
_AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"
GATE="$AGENTS_DIR/skills/issue-create/scripts/eval-confirm-gate.sh"
SKILL="$AGENTS_DIR/skills/issue-create/SKILL.md"
PROV_CLI="$AGENTS_DIR/bin/github-issues/issue-provenance"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

GATE_PRESENT=no; [ -f "$GATE" ] && GATE_PRESENT=yes

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# mk_json <file> <final-verdict> <survey-verdict> <review-status>
# Shape is the S13 `--out` artifact — the ONLY thing the main conversation reads.
# Note what is deliberately absent: no `proposal`, and `candidates[]` carries only
# number/title/state (never `body`). The gate must not need either.
mk_json() {
    V="$2" SV="$3" RS="$4" node -e "
const fs=require('fs');
fs.writeFileSync(process.argv[1], JSON.stringify({
  schema_version: 2,
  verdict: process.env.V, target: null, children: [], related: [], reason: 'r',
  provenance: 'user-explicit', provenance_layer: 'A',
  survey: { verdict: process.env.SV, target: null, children: [], related: [], reason: 's' },
  review: { status: process.env.RS, verdict: process.env.V, target: null,
            children: [], related: [], reason: 'r', detail: '' },
  candidates: [{ number: 1, title: 't', state: 'open' }]
}, null, 2));" "$1"
}

# --- replay environments -----------------------------------------------------------
# The gate calls `issue-provenance --result` itself, so the truth table needs a session
# whose decision record actually says what each row assumes. The record is produced by
# running the REAL classifier once per environment: re-deriving its file name, TTL and
# field names here would fork the SSOT (hooks/lib/issue-provenance-keys.js), and a test
# that invented the shape would keep passing after the real one changed.
#
#   grant → no workflow state file  ⇒ layer C fires ⇒ record says user-explicit
#   deny  → workflow state present, transcript holds no request ⇒ record says mid-workflow
#
# `--consume` is run exactly ONCE per environment: it is single-use, and a second call
# would spend the turn and rewrite the record as mid-workflow.
SID="cc-session-gate"
REPLAY_GRANT=""
REPLAY_DENY=""

mk_replay_env() {  # <name> <workflow-active: yes|no> <newest-user-message> → base dir
    local base="$WORK/env-$1"
    mkdir -p "$base/state" "$base/plans" "$base/cwd"
    printf 'Session-ID: %s\n' "$SID" > "$base/cwd/WORKTREE_NOTES.md"
    : > "$base/plans/$SID-intent.md"
    MSG="$3" node -e "
const fs=require('fs');
fs.writeFileSync(process.argv[1], JSON.stringify({type:'user',message:{role:'user',content:process.env.MSG}}) + '\n');
" "$(node_path "$base/transcript.jsonl")" 2>/dev/null
    printf '%s' "$(node_path "$base/transcript.jsonl")" > "$base/state/$SID.session-transcript"
    # "Active" is PART WAY through, so the deny env needs a started step AND an
    # unfinished one. An all-complete state is a finished workflow and reads inactive,
    # which would make the deny env grant user-explicit and silently invert every row
    # that is graded against it.
    [ "$2" = "yes" ] && printf '%s' \
        '{"steps":{"research":{"status":"complete"},"write_code":{"status":"pending"}}}' \
        > "$base/state/$SID.json"
    printf '%s' "$base"
}

replay_env() {  # <base> → env assignments consumed via `env`
    printf 'CLAUDE_WORKFLOW_DIR=%s\nWORKFLOW_PLANS_DIR=%s\nAGENTS_CONFIG_DIR=%s\nCLAUDE_CODE_SESSION_ID=%s\n' \
        "$(node_path "$1/state")" "$(node_path "$1/plans")" "$_AGENTS_DIR_NODE" "$SID"
}

consume_once() {  # <base> → prints the classification the record now holds
    ( cd "$1/cwd" && env $(replay_env "$1") ISSUE_PROVENANCE=on ISSUE_VERDICT_REVIEW=on \
        "$RWT" 20 bash "$PROV_CLI" --consume 2>/dev/null ) | head -n 1 | tr -d '[:space:]'
}

replay_result() {  # <base> → what a non-consuming replay answers now
    ( cd "$1/cwd" && env $(replay_env "$1") ISSUE_PROVENANCE=on ISSUE_VERDICT_REVIEW=on \
        "$RWT" 20 bash "$PROV_CLI" --result 2>/dev/null ) | head -n 1 | tr -d '[:space:]'
}

# run_gate <json> <provenance> <severity> [replay-base] → sets CONFIRM / REASONS / RC
# Config pinning (rules/test.md): the gate is a pure classifier of its three arguments
# PLUS the recorded decision, so BOTH feature switches are pinned `on` here and the
# session env is pinned to a replay environment. An ambient `off` in the developer's
# .env, or an inherited real session, must not silently change the truth table below.
run_gate() {
    if [ "$GATE_PRESENT" != "yes" ]; then CONFIRM="<missing>"; REASONS="<missing>"; RC=127; return; fi
    local base="${4:-$REPLAY_GRANT}"
    local out
    if [ -n "$base" ] && [ -d "$base/cwd" ]; then
        out=$( cd "$base/cwd" && env $(replay_env "$base") ISSUE_VERDICT_REVIEW=on ISSUE_PROVENANCE=on \
            "$RWT" 20 bash "$GATE" "$1" "$2" "$3" 2>"$WORK/gate-stderr.txt" )
    else
        # No replay environment (the provenance CLI is missing, so none could be built).
        # The R-section above already reported that; run bare so the rest still classifies.
        out=$( ISSUE_VERDICT_REVIEW=on ISSUE_PROVENANCE=on \
            "$RWT" 20 bash "$GATE" "$1" "$2" "$3" 2>"$WORK/gate-stderr.txt" )
    fi
    RC=$?
    CONFIRM=$(printf '%s\n' "$out" | sed -n 's/^confirm: *//p' | head -n 1 | tr -d '[:space:]')
    REASONS=$(printf '%s\n' "$out" | sed -n 's/^reasons: *//p' | head -n 1 | tr -d '[:space:]')
}

# assert_row <name> <final-verdict> <survey-verdict> <review-status> <provenance> <severity> <want-confirm> <want-reasons> [replay-base]
# The 9th argument defaults to the granting environment, so every row's <provenance>
# argument is the only variable in G3 unless the row says otherwise.
assert_row() {
    local name="$1" want_c="$7" want_r="$8" base="${9:-$REPLAY_GRANT}"
    local jf="$WORK/$name.json"
    mk_json "$jf" "$2" "$3" "$4"
    run_gate "$jf" "$5" "$6" "$base"
    if [ "$CONFIRM" = "<missing>" ]; then
        fail "$name" "RED-EXPECTED: skills/issue-create/scripts/eval-confirm-gate.sh not yet created"
        return
    fi
    if [ "$RC" -ne 0 ]; then
        fail "$name" "want exit 0 (classifier never aborts), got $RC: $(head -n 1 "$WORK/gate-stderr.txt" 2>/dev/null)"
        return
    fi
    if [ "$CONFIRM" != "$want_c" ]; then
        fail "$name" "confirm want=$want_c got=$CONFIRM (reasons=$REASONS)"
        return
    fi
    # Compare reason sets order-insensitively.
    local got_sorted want_sorted
    got_sorted=$(printf '%s' "$REASONS"  | tr ',' '\n' | grep -v '^$' | sort | paste -sd, -)
    want_sorted=$(printf '%s' "$want_r"  | tr ',' '\n' | grep -v '^$' | sort | paste -sd, -)
    if [ "$got_sorted" = "$want_sorted" ]; then
        pass "$name"
    else
        fail "$name" "reasons want=[$want_sorted] got=[$got_sorted]"
    fi
}

echo "=== replay environments: the recorded decision each row is graded against ==="
# If this section is red, every G3 assertion below is vacuous — the rows would be
# pinning "no record exists" rather than the gate's combination rule. It runs first
# for exactly that reason.
REPLAY_GRANT="$(mk_replay_env grant no  "fix the typo in the readme")"
REPLAY_DENY="$(mk_replay_env  deny  yes "run the tests please")"
if [ ! -f "$PROV_CLI" ]; then
    fail "R1-grant-env-records-user-explicit" "RED-EXPECTED: bin/github-issues/issue-provenance not found"
    fail "R2-deny-env-records-mid-workflow"   "RED-EXPECTED: bin/github-issues/issue-provenance not found"
else
    GRANT_CONSUMED="$(consume_once "$REPLAY_GRANT")"
    DENY_CONSUMED="$(consume_once "$REPLAY_DENY")"
    GRANT_REPLAY="$(replay_result "$REPLAY_GRANT")"
    DENY_REPLAY="$(replay_result "$REPLAY_DENY")"

    if [ "$GRANT_CONSUMED" = "user-explicit" ] && [ "$GRANT_REPLAY" = "user-explicit" ]; then
        pass "R1-grant-env-records-user-explicit"
    else
        fail "R1-grant-env-records-user-explicit" \
            "the granting environment must replay user-explicit (consumed=$GRANT_CONSUMED replay=$GRANT_REPLAY)"
    fi
    if [ "$DENY_CONSUMED" = "mid-workflow" ] && [ "$DENY_REPLAY" = "mid-workflow" ]; then
        pass "R2-deny-env-records-mid-workflow"
    else
        fail "R2-deny-env-records-mid-workflow" \
            "the denying environment must replay mid-workflow (consumed=$DENY_CONSUMED replay=$DENY_REPLAY)"
    fi
fi

echo ""
echo "=== truth table: verdict | survey | review_result | provenance | severity ==="
# Every row below runs in the GRANTING environment unless a 9th argument says otherwise.
# name                       verdict      survey       review    provenance     severity        confirm reasons
assert_row T01-none-clean    none         none         upheld    user-explicit  severity:low    no      ""
assert_row T02-sibling-clean sibling      sibling      upheld    user-explicit  severity:low    no      ""

echo ""
echo "--- G1: verdicts that touch existing issues always confirm ---"
assert_row T04-reopen        reopen       reopen       upheld    user-explicit  severity:low    yes     "G1"
assert_row T05-make-parent   make-parent  make-parent  upheld    user-explicit  severity:high   yes     "G1"
# sub-of and bulk-sub-of are in the same class: attaching under a parent can reopen every
# closed ancestor of that parent chain, which is exactly the "changes something that
# already exists" property G1 names. Treating them as additive would have let the one
# verdict that silently reopens issues through without a question.
assert_row T03-subof-clean   sub-of       sub-of       upheld    user-explicit  severity:medium yes     "G1"
assert_row T19-bulk-subof    bulk-sub-of  bulk-sub-of  upheld    user-explicit  severity:low    yes     "G1"

echo ""
echo "--- G2: the review stage replaced the survey verdict ---"
assert_row T06-replaced      sibling      none         replaced  user-explicit  severity:low    yes     "G2"
assert_row T07-replaced-subof sub-of      sibling      replaced  user-explicit  severity:medium yes     "G1,G2"

echo ""
echo "--- G3: mid-workflow provenance, unless severity is high ---"
assert_row T08-midwf-low     none         none         upheld    mid-workflow   severity:low    yes     "G3"
assert_row T09-midwf-medium  none         none         upheld    mid-workflow   severity:medium yes     "G3"
assert_row T10-midwf-high    none         none         upheld    mid-workflow   severity:high   no      ""
assert_row T11-userexp-any   none         none         upheld    user-explicit  severity:high   no      ""

echo ""
echo "--- G4: an unverified verdict always confirms ---"
assert_row T12-review-invalid none        none         invalid   user-explicit  severity:low    yes     "G4"
assert_row T13-review-skipped none        none         skipped   user-explicit  severity:high   yes     "G4"

# T20/T21 — the no-Node degraded path in review-survey-verdict-codex.sh writes the final
# artifact by COPYING the survey artifact, so what reaches the gate has no `review`
# object at all. That path is only safe because the gate reads a missing review.status
# the same way it reads `invalid`: nobody reviewed this. G4 stated as an allowlist is
# what makes that true; stated as a denylist of {invalid, skipped} it would be false,
# and the one environment without node would be the one that skips the question.
if [ "$GATE_PRESENT" != "yes" ]; then
    fail "T20-no-review-object-fires-G4" "RED-EXPECTED: eval-confirm-gate.sh not yet created"
    fail "T21-review-without-status-fires-G4" "RED-EXPECTED: eval-confirm-gate.sh not yet created"
else
    # Faithful to the copy: proposal and candidate bodies are still present, because the
    # degraded path never got to strip them. The gate must not need either.
    node -e "
const fs=require('fs');
fs.writeFileSync(process.argv[1], JSON.stringify({
  schema_version: 2,
  proposal: { title: 't', background: 'b', changes: 'c' },
  verdict: 'none', target: null, children: [], related: [], reason: 'r',
  candidates: [{ number: 1, title: 't', state: 'open', body: 'b1', labels: [] }]
}, null, 2));" "$WORK/nonode.json"
    run_gate "$WORK/nonode.json" user-explicit severity:high
    if [ "$CONFIRM" = "yes" ] && printf '%s' "$REASONS" | grep -q 'G4'; then
        pass "T20-no-review-object-fires-G4"
    else
        fail "T20-no-review-object-fires-G4" "an artifact with no review object means no review happened (confirm=$CONFIRM, reasons=$REASONS)"
    fi

    node -e "
const fs=require('fs');
fs.writeFileSync(process.argv[1], JSON.stringify({
  schema_version: 2,
  verdict: 'none', target: null, children: [], related: [], reason: 'r',
  survey: { verdict: 'none', target: null, children: [], related: [], reason: 's' },
  review: { detail: 'partially written', verdict: null, target: null },
  candidates: [{ number: 1, title: 't', state: 'open' }]
}, null, 2));" "$WORK/nostatus.json"
    run_gate "$WORK/nostatus.json" user-explicit severity:high
    if [ "$CONFIRM" = "yes" ] && printf '%s' "$REASONS" | grep -q 'G4'; then
        pass "T21-review-without-status-fires-G4"
    else
        fail "T21-review-without-status-fires-G4" "a review object without a status is not a completed review (confirm=$CONFIRM, reasons=$REASONS)"
    fi
fi

echo ""
echo "--- OR semantics: overlapping conditions accumulate reasons ---"
assert_row T14-G1-G2         reopen       none         replaced  user-explicit  severity:low    yes     "G1,G2"
assert_row T15-G1-G3         make-parent  make-parent  upheld    mid-workflow   severity:low    yes     "G1,G3"
assert_row T16-G3-G4         none         none         skipped   mid-workflow   severity:low    yes     "G3,G4"
assert_row T17-all-four      reopen       none         invalid   mid-workflow   severity:low    yes     "G1,G2,G3,G4"
assert_row T18-G1-G4-high    reopen       reopen       skipped   mid-workflow   severity:high   yes     "G1,G4"

echo ""
echo "--- G3 minimum privilege: the argument lowers the answer, it never raises it ---"
# The gate has two witnesses to "who asked for this issue": the value handed to it, and
# the record the classifier left behind. Only their agreement earns silence. The two
# rows below are the same disagreement seen from each side, and both must land on G3 —
# if either one passed, one witness would be able to overrule the other, and the useful
# direction of that overrule is the one the gate exists to prevent.
#                                            verdict survey review  prov          severity     confirm reasons  env
assert_row M1-recorded-explicit-arg-midworkflow none none upheld mid-workflow  severity:low  yes "G3" "$REPLAY_GRANT"
assert_row M2-recorded-midworkflow-arg-explicit none none upheld user-explicit severity:low  yes "G3" "$REPLAY_DENY"
# M3 is the control that makes M2 mean something: the identical row differs only in the
# environment, so a gate that ignored the record entirely would pass M2 and M3 alike.
assert_row M3-recorded-explicit-arg-explicit    none none upheld user-explicit severity:low  no  ""   "$REPLAY_GRANT"
# M4 pins the one place the argument alone still decides: the severity:high carve-out is
# read off the ARGUMENT, so a self-reported `user-explicit` suppresses G3 here. That is
# not a privilege gain — T10 shows an honest `mid-workflow` buys the same silence at
# severity:high — but the asymmetry is deliberate and must not drift unnoticed.
assert_row M4-high-severity-carveout-reads-arg  none none upheld user-explicit severity:high no  ""   "$REPLAY_DENY"

echo ""
echo "=== G3 fail-closed: an unusable provenance value is not 'user-explicit' ==="
# The provenance classifier exits 0 unconditionally and prints its answer on stdout.
# That means every failure inside it — missing marker, unreadable transcript, a value
# the classifier never expected — surfaces here as an empty or unrecognised string.
# The dangerous default is to treat "not the literal string mid-workflow" as safe:
# the gate would then stay silent for exactly the cases where the pipeline broke.
# The safe reading is the reverse — only an explicit `user-explicit` earns silence.
mk_json_prov() {  # <file> <provenance-field-value-or-__OMIT__> <layer>
    V="$2" L="$3" node -e "
const fs=require('fs');
const o = { schema_version: 2,
  verdict: 'none', target: null, children: [], related: [], reason: 'r',
  provenance_layer: process.env.L,
  survey: { verdict: 'none', target: null, children: [], related: [], reason: 's' },
  review: { status: 'upheld', verdict: 'none', target: null,
            children: [], related: [], reason: 'r', detail: '' },
  candidates: [{ number: 1, title: 't', state: 'open' }] };
if (process.env.V !== '__OMIT__') o.provenance = process.env.V;
fs.writeFileSync(process.argv[1], JSON.stringify(o, null, 2));" "$1"
}

# assert_failclosed <name> <artifact-provenance> <layer> <arg-provenance> <severity>
assert_failclosed() {
    local name="$1" jf="$WORK/fc-$1.json"
    mk_json_prov "$jf" "$2" "$3"
    run_gate "$jf" "$4" "$5"
    if [ "$CONFIRM" = "<missing>" ]; then
        fail "$name" "RED-EXPECTED: skills/issue-create/scripts/eval-confirm-gate.sh not yet created"
    elif [ "$RC" -ne 0 ]; then
        fail "$name" "want exit 0 (classifier never aborts), got $RC"
    elif [ "$CONFIRM" = "yes" ] && printf '%s' "$REASONS" | grep -q 'G3'; then
        pass "$name"
    else
        fail "$name" "an unusable provenance must fall to the confirm side via G3 (confirm=$CONFIRM, reasons=$REASONS)"
    fi
}

#                  name                        artifact-prov  layer  arg-prov       severity
assert_failclosed P1-arg-empty-string          user-explicit  A      ""             severity:low
assert_failclosed P2-arg-unknown-value         user-explicit  A      unknown        severity:medium
assert_failclosed P3-arg-typo-near-miss        user-explicit  A      user_explicit  severity:low
assert_failclosed P4-arg-whitespace-only       user-explicit  A      "   "          severity:medium
assert_failclosed P5-arg-error-text            user-explicit  A      "layer: none"  severity:low
assert_failclosed P6-artifact-field-absent     __OMIT__       none   ""             severity:low
assert_failclosed P7-artifact-field-empty      ""             none   ""             severity:medium
assert_failclosed P8-artifact-field-unknown    garbage        none   garbage        severity:low
assert_failclosed P9-artifact-field-null-layer user-explicit  ""     ""             severity:medium

# P10: provenance argument omitted entirely — the gate receives two arguments where
# it expects three, which is what a caller sees when the classifier produced no output.
if [ "$GATE_PRESENT" != "yes" ]; then
    fail "P10-arg-omitted-confirms" "RED-EXPECTED: eval-confirm-gate.sh not yet created"
    fail "P11-high-severity-does-not-rescue-unusable-provenance" "RED-EXPECTED: eval-confirm-gate.sh not yet created"
else
    mk_json_prov "$WORK/fc-omit.json" user-explicit A
    # Run inside the GRANTING environment on purpose: even where the recorded decision
    # says the user did ask, a caller that supplies no provenance argument has not
    # completed the pipeline, and the gate must confirm on the argument count alone.
    OUT=$( cd "$REPLAY_GRANT/cwd" && env $(replay_env "$REPLAY_GRANT") ISSUE_VERDICT_REVIEW=on ISSUE_PROVENANCE=on \
          "$RWT" 20 bash "$GATE" "$WORK/fc-omit.json" 2>/dev/null ); RC=$?
    if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'confirm: *yes'; then
        pass "P10-arg-omitted-confirms"
    else
        fail "P10-arg-omitted-confirms" "a missing provenance argument must fail-safe to confirm at exit 0 (rc=$RC, out=$(printf '%s' "$OUT" | tr '\n' ' '))"
    fi

    # P11 pins the direction of the G3 carve-out. `severity:high` suppresses G3 only
    # for a KNOWN mid-workflow provenance (T10). It must not double as a blanket
    # override that also silences the unusable-provenance case — otherwise the single
    # most severe issues would be the ones created without confirmation.
    mk_json_prov "$WORK/fc-high.json" garbage none
    run_gate "$WORK/fc-high.json" garbage severity:high
    if [ "$CONFIRM" = "yes" ]; then
        pass "P11-high-severity-does-not-rescue-unusable-provenance"
    else
        fail "P11-high-severity-does-not-rescue-unusable-provenance" "severity:high must not turn an unusable provenance into silence (confirm=$CONFIRM, reasons=$REASONS)"
    fi
fi

echo ""
echo "=== argument / robustness handling ==="
if [ "$GATE_PRESENT" != "yes" ]; then
    fail "A1-missing-args-exit-0"     "RED-EXPECTED: eval-confirm-gate.sh not yet created"
    fail "A2-unreadable-json-confirms" "RED-EXPECTED: eval-confirm-gate.sh not yet created"
    fail "A3-unknown-severity-treated-as-not-high" "RED-EXPECTED: eval-confirm-gate.sh not yet created"
else
    OUT=$("$RWT" 20 bash "$GATE" 2>/dev/null); RC=$?
    if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'confirm: *yes'; then
        pass "A1-missing-args-exit-0"
    else
        fail "A1-missing-args-exit-0" "with no arguments the gate must fail-safe to 'confirm: yes' at exit 0 (rc=$RC, out=$(printf '%s' "$OUT" | tr '\n' ' '))"
    fi

    printf '%s' '{ broken' > "$WORK/broken.json"
    run_gate "$WORK/broken.json" user-explicit severity:high
    if [ "$RC" -eq 0 ] && [ "$CONFIRM" = "yes" ]; then
        pass "A2-unreadable-json-confirms"
    else
        fail "A2-unreadable-json-confirms" "an unparseable verdict file must fail-safe to confirm (rc=$RC, confirm=$CONFIRM)"
    fi

    mk_json "$WORK/unk.json" none none upheld
    run_gate "$WORK/unk.json" mid-workflow ""
    if [ "$CONFIRM" = "yes" ] && printf '%s' "$REASONS" | grep -q 'G3'; then
        pass "A3-unknown-severity-treated-as-not-high"
    else
        fail "A3-unknown-severity-treated-as-not-high" "an absent severity label is not 'high', so G3 must fire (confirm=$CONFIRM, reasons=$REASONS)"
    fi
fi

echo ""
echo "=== SKILL.md documents the gate and delegates the decision to the script ==="
if [ ! -f "$SKILL" ]; then
    fail "D1-skill-references-gate" "skills/issue-create/SKILL.md not found"
    fail "D2-skill-documents-G1-G4" "skills/issue-create/SKILL.md not found"
else
    if grep -qF 'eval-confirm-gate.sh' "$SKILL"; then
        pass "D1-skill-references-gate"
    else
        fail "D1-skill-references-gate" "RED-EXPECTED: SKILL.md does not call scripts/eval-confirm-gate.sh yet"
    fi
    MISSING=""
    for g in G1 G2 G3 G4; do grep -qF "$g" "$SKILL" || MISSING="$MISSING $g"; done
    if [ -z "$MISSING" ]; then
        pass "D2-skill-documents-G1-G4"
    else
        fail "D2-skill-documents-G1-G4" "RED-EXPECTED: gate condition(s) undocumented:$MISSING"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
