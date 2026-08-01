#!/usr/bin/env bash
# tests/feature-1640-step-started-at.sh
# Tests: hooks/workflow-state/step-timestamps.js, hooks/workflow-state/state-io.js, hooks/workflow-state/state-io/core.js, hooks/workflow-mark/reset-handler.js, hooks/workflow-mark/mark-step-handler.js, bin/workflow/next-step, bin/workflow/lib/next-step/
# Tags: measurement, started-at, workflow-state, mark-step, reset-from, toggle, scope:issue-specific, pwsh-not-required, TL2
#
# (c) of #1640. With RECORD_STEP_TIMESTAMPS=on, the workflow state file records when each
# step first left `pending`. The feature is defined by a STATE INVARIANT, not by a
# transition rule:
#
#   toggle on  => every step whose status is non-`pending` (in_progress / complete /
#                 skipped) HAS `started_at`, and every `pending` step has NONE.
#                 `started_at` is attempt-scoped: returning to `pending` loses it.
#   toggle off => `started_at` appears nowhere at all (byte-identical to today's file).
#
# check_invariant() below re-checks that biconditional over ALL VALID_STEPS after every
# case, so a future write path into state.steps[*] that forgets the rule fails here.
#
# ISOLATION CONTRACT: CLAUDE_WORKFLOW_DIR points at a temp dir, AGENTS_CONFIG_DIR points at
# a fixture config dir holding a .env WITHOUT the toggle (so the "unset" rows resolve
# deterministically instead of reading the developer's real .env), and HOME/USERPROFILE are
# redirected. The toggle is resolved once per process and cached, so EVERY row spawns its
# own `node` process.
#
# TL3 gap (what this test does NOT catch):
# - the real PostToolUse/PreToolUse hook registration: these rows call reset-handler and
#   mark-step-handler as modules, so a settings.json wiring mistake that stops workflow-mark
#   from firing at all is invisible here.
# - the real commit gate: hooks/workflow-gate.js needs a git repo with staged changes and
#   is not driven; only bin/workflow/next-step is compared across toggle values.
# - real elapsed durations: every row runs inside one test process, so `updated_at -
#   started_at` is milliseconds and cannot reveal a clock/timezone defect on the host.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMPROOT="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMPROOT" >/dev/null 2>&1 || true; rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
SKIP=0

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1)); fi
}

skip_case() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() { "$AGENTS_DIR/bin/run-with-timeout.sh" "$@"; }

native_path() { (cd "$1" 2>/dev/null && (pwd -W 2>/dev/null || pwd)) || printf '%s' "$1"; }

WF="$TMPROOT/wf";      mkdir -p "$WF"
CFG="$TMPROOT/cfg";    mkdir -p "$CFG"
ISO_HOME="$TMPROOT/h"; mkdir -p "$ISO_HOME"
# A fixture .env deliberately WITHOUT RECORD_STEP_TIMESTAMPS: the "unset" rows must resolve
# to off from a known file, never from the developer's real agents config.
printf '# fixture config for tests/feature-1640-step-started-at.sh\nAGENT_FIXTURE=1\n' > "$CFG/.env"
WF_NATIVE="$(native_path "$WF")"
CFG_NATIVE="$(native_path "$CFG")"
ISO_HOME_NATIVE="$(native_path "$ISO_HOME")"

SID_N=0
# Assigns a fresh session id to SID. NOT a command substitution: `SID=$(new_sid)` would
# increment the counter inside a subshell and hand every case the SAME state file.
next_sid() { SID_N=$((SID_N + 1)); printf -v SID "sid1640-%02d" "$SID_N"; }

# Runs one node process. <toggle> is either UNSET or the literal value of
# RECORD_STEP_TIMESTAMPS. One process per row: the toggle is cached per process.
nodejs() { # <toggle> <sid> <js>
    local t="$1" sid="$2" js="$3"
    NODE_RC=0
    if [ "$t" = "UNSET" ]; then
        NODE_OUT="$(cd "$AGENTS_DIR" && env -u RECORD_STEP_TIMESTAMPS \
            CLAUDE_WORKFLOW_DIR="$WF_NATIVE" AGENTS_CONFIG_DIR="$CFG_NATIVE" \
            HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" SID="$sid" \
            "$AGENTS_DIR/bin/run-with-timeout.sh" 60 node -e "$js" 2>&1)" || NODE_RC=$?
    else
        NODE_OUT="$(cd "$AGENTS_DIR" && env RECORD_STEP_TIMESTAMPS="$t" \
            CLAUDE_WORKFLOW_DIR="$WF_NATIVE" AGENTS_CONFIG_DIR="$CFG_NATIVE" \
            HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" SID="$sid" \
            "$AGENTS_DIR/bin/run-with-timeout.sh" 60 node -e "$js" 2>&1)" || NODE_RC=$?
    fi
}

# Shared JS preamble. `rd()` reads the state file, `raw()` its text, `sleep()` guarantees
# the ISO-8601 millisecond stamps of two consecutive writes actually differ.
PRE='const S = require("./hooks/workflow-state/state-io");
const fs = require("fs"), path = require("path");
const sid = process.env.SID;
const sp = () => path.join(process.env.CLAUDE_WORKFLOW_DIR, sid + ".json");
const raw = () => fs.readFileSync(sp(), "utf8");
const rd = () => JSON.parse(raw());
const sleep = (ms) => { const t = Date.now(); while (Date.now() - t < ms) {} };
'

# #1133 completion-approval gate interaction. `outline` and `detail` are the only steps
# that cannot be persisted `complete` without a `plan_approvals` record (see
# hooks/workflow-state/completion-approval.js APPROVAL_GATED_STEPS). started_at is
# step-agnostic, so rows that merely need SOME step drive the NON-gated `run_tests`;
# rows that genuinely need a gated step (D8 class-wide, C1 reset, D12 seeding) prepend
# APPROVE_GATED_JS below. That helper seeds the same audit record the sanctioned reset
# path writes — it changes no step status and no timestamp, so every started_at
# assertion below stays exactly as strong as it was.
APPROVE_GATED_JS='const CA = require("./hooks/workflow-state/completion-approval");
for (const s of CA.APPROVAL_GATED_STEPS) {
  CA.recordPlanApproval(sid, s, { source: "reset-sentinel", reason: "started_at fixture" });
}
'

# C1-c: the whole-class post-condition. mode=on asserts the biconditional over every
# VALID_STEPS entry; mode=off asserts `started_at` is absent everywhere.
INV_JS='const S = require("./hooks/workflow-state/state-io");
const fs = require("fs"), path = require("path");
const p = path.join(process.env.CLAUDE_WORKFLOW_DIR, process.env.SID + ".json");
let st;
try { st = JSON.parse(fs.readFileSync(p, "utf8")); }
catch (e) { console.log("READ-FAIL:" + (e.code || e.message)); process.exit(0); }
const steps = st.steps || {};
const bad = [];
for (const s of S.VALID_STEPS) {
  const e = steps[s] || {};
  const has = typeof e.started_at === "string" && e.started_at.length > 0;
  const nonPending = !!(e.status && e.status !== "pending");
  if (process.env.MODE === "on") { if (nonPending !== has) bad.push(s + "/" + e.status + "/" + (has ? "has" : "none")); }
  else if (has) bad.push(s + "/unexpected-started_at");
}
console.log(bad.length ? "VIOLATION " + bad.join(",") : "OK");
'

check_invariant() { # <label> <sid> <mode:on|off>
    local out rc=0
    out="$(cd "$AGENTS_DIR" && env CLAUDE_WORKFLOW_DIR="$WF_NATIVE" AGENTS_CONFIG_DIR="$CFG_NATIVE" \
        HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" SID="$2" MODE="$3" \
        "$AGENTS_DIR/bin/run-with-timeout.sh" 30 node -e "$INV_JS" 2>&1)" || rc=$?
    assert_eq "invariant/$1" "OK" "$out"
}

# ---- D1: default off is a byte-level regression guard ------------------------

echo "== D1: with the toggle unset, started_at never appears =="
next_sid
nodejs UNSET "$SID" "$PRE"'
S.markStep(sid, "run_tests", "pending");
S.markStep(sid, "run_tests", "in_progress");
S.markStep(sid, "run_tests", "complete");
console.log(/started_at/.test(raw()) ? "PRESENT" : "ABSENT");
'
assert_eq "D1/no-started_at-anywhere" "ABSENT" "$NODE_OUT"
check_invariant "D1" "$SID" off

echo "== D1b: with the toggle unset, a step object keeps exactly its two keys =="
next_sid
nodejs UNSET "$SID" "$PRE"'
S.markStep(sid, "run_tests", "complete");
console.log(Object.keys(rd().steps.run_tests).sort().join(","));
'
assert_eq "D1b/two-keys-only" "status,updated_at" "$NODE_OUT"
check_invariant "D1b" "$SID" off

# ---- D2: toggle value interpretation ----------------------------------------

echo "== D2: only a trimmed, case-insensitive \"on\" enables the feature =="
TOGGLE_PROBE="$PRE"'
S.markStep(sid, "run_tests", "complete");
console.log(typeof rd().steps.run_tests.started_at === "string" ? "on" : "off");
'
while IFS='|' read -r name value want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    case "$value" in
        *EMPTY*)   value="" ;;
        *SPACEON*) value=" on " ;;
        *)         value="${value//[[:space:]]/}" ;;
    esac
    next_sid
    nodejs "$value" "$SID" "$TOGGLE_PROBE"
    assert_eq "D2/$name" "$want" "$NODE_OUT"
    check_invariant "D2/$name" "$SID" "$want"
done <<'TABLE'
empty-string   | EMPTY   | off
literal-false  | false   | off
literal-zero   | 0       | off
literal-no     | no      | off
uppercase-OFF  | OFF     | off
lowercase-on   | on      | on
uppercase-ON   | ON      | on
padded-on      | SPACEON | on
TABLE

echo "== D2b: an unset toggle falls back to .env and resolves off =="
next_sid
nodejs UNSET "$SID" "$TOGGLE_PROBE"
assert_eq "D2b/unset-is-off" "off" "$NODE_OUT"
check_invariant "D2b" "$SID" off

# ---- C2: the cost of the toggle ---------------------------------------------

# A counting stub is installed into require.cache BEFORE the state layer is required, so
# step-timestamps.js resolves `require("../../load-env")` to it.
LOADENV_STUB='
const lePath = require.resolve("./hooks/lib/load-env.js");
global.__leCalls = 0;
require.cache[lePath] = {
  id: lePath, filename: lePath, loaded: true, children: [], paths: [],
  exports: {
    loadDefaultEnv() { global.__leCalls += 1; return true; },
    loadEnv() { return false; },
    filterOsBlocks(t) { return t; },
  },
};
'

echo "== C2-a: with the toggle explicitly off, load-env is never consulted =="
next_sid
nodejs off "$SID" "$LOADENV_STUB$PRE"'
for (let i = 0; i < 10; i++) S.markStep(sid, "run_tests", "complete");
console.log("CALLS=" + global.__leCalls);
'
assert_eq "C2-a/load-env-calls" "CALLS=0" "$NODE_OUT"
check_invariant "C2-a" "$SID" off

echo "== C2-b: with the toggle unset, load-env is consulted exactly once per process =="
next_sid
nodejs UNSET "$SID" "$LOADENV_STUB$PRE"'
for (let i = 0; i < 10; i++) S.markStep(sid, "run_tests", "complete");
console.log("CALLS=" + global.__leCalls);
'
assert_eq "C2-b/load-env-calls" "CALLS=1" "$NODE_OUT"
check_invariant "C2-b" "$SID" off

# ---- D3: stamping semantics with the toggle on ------------------------------

echo "== D3: the first non-pending write stamps started_at == updated_at =="
next_sid
nodejs on "$SID" "$PRE"'
S.markStep(sid, "run_tests", "complete");
const e = rd().steps.run_tests;
console.log(e.started_at === e.updated_at ? "EQ" : "NE:" + e.started_at + "/" + e.updated_at);
'
assert_eq "D3/first-stamp-equal" "EQ" "$NODE_OUT"
check_invariant "D3" "$SID" on

echo "== D4: non-pending -> non-pending carries started_at forward =="
next_sid
nodejs on "$SID" "$PRE"'
S.markStep(sid, "run_tests", "in_progress");
const a = rd().steps.run_tests;
sleep(5);
S.markStep(sid, "run_tests", "complete");
const b = rd().steps.run_tests;
console.log(
  (a.started_at === b.started_at ? "carry-ok" : "carry-lost") + " " +
  (b.updated_at > a.updated_at ? "advanced" : "stalled")
);
'
assert_eq "D4/carry-forward" "carry-ok advanced" "$NODE_OUT"
check_invariant "D4" "$SID" on

echo "== D5: pending clears started_at; the next attempt gets a NEW value =="
next_sid
nodejs on "$SID" "$PRE"'
S.markStep(sid, "run_tests", "complete");
const first = rd().steps.run_tests.started_at;
S.markStep(sid, "run_tests", "pending");
const cleared = !("started_at" in rd().steps.run_tests);
sleep(5);
S.markStep(sid, "run_tests", "in_progress");
const second = rd().steps.run_tests.started_at;
console.log(
  (cleared ? "cleared" : "still-present") + " " +
  (typeof second === "string" && second !== first ? "renewed" : "stale:" + second)
);
'
assert_eq "D5/clear-on-reset" "cleared renewed" "$NODE_OUT"
check_invariant "D5" "$SID" on

echo "== D6: skipped is non-pending, so it is stamped with a zero-duration value =="
next_sid
nodejs on "$SID" "$PRE"'
S.markStep(sid, "research", "skipped");
const e = rd().steps.research;
console.log((typeof e.started_at === "string" ? "stamped" : "missing") + " " +
            (e.started_at === e.updated_at ? "zero-duration" : "nonzero"));
'
assert_eq "D6/skipped-stamped" "stamped zero-duration" "$NODE_OUT"
check_invariant "D6" "$SID" on

echo "== D7: extraFields cannot forge started_at — the state layer owns it =="
next_sid
nodejs on "$SID" "$PRE"'
S.markStep(sid, "run_tests", "complete", { started_at: "1999-01-01T00:00:00.000Z" });
const e = rd().steps.run_tests;
console.log(e.started_at === "1999-01-01T00:00:00.000Z" ? "FORGED" : "STATE-LAYER-WINS");
'
assert_eq "D7/extrafields-defense" "STATE-LAYER-WINS" "$NODE_OUT"
check_invariant "D7" "$SID" on

echo "== D8: class-wide (CPR-4/5) — every VALID_STEPS member is stamped =="
next_sid
nodejs on "$SID" "$PRE$APPROVE_GATED_JS"'
const bad = [];
for (const step of S.VALID_STEPS) {
  S.markStep(sid, step, "complete");
  const e = rd().steps[step];
  if (typeof e.started_at !== "string" || !e.started_at) bad.push(step);
}
console.log("steps=" + S.VALID_STEPS.length + " missing=" + (bad.length ? bad.join(",") : "0"));
'
STEP_COUNT="$(cd "$AGENTS_DIR" && run_with_timeout 30 node -e \
    'console.log(require("./hooks/workflow-state/state-io").VALID_STEPS.length)' 2>&1)" || STEP_COUNT="?"
assert_eq "D8/all-steps-stamped" "steps=$STEP_COUNT missing=0" "$NODE_OUT"
check_invariant "D8" "$SID" on

# ---- C1: WORKFLOW_RESET_FROM_* ----------------------------------------------

echo "== C1-a/C1-b: reset synthesises started_at forward and drops it backward =="
next_sid
nodejs on "$SID" "$PRE$APPROVE_GATED_JS"'
const rh = require("./hooks/workflow-mark/reset-handler");
S.markStep(sid, "workflow_init", "complete");
S.markStep(sid, "clarify_intent", "complete");
S.markStep(sid, "outline", "complete");
sleep(5);
const msgs = [];
rh.handle({
  cmd: "echo \"<<WORKFLOW_RESET_FROM_detail: measurement timestamp coverage>>\"",
  sessionId: sid,
  pushMessage: (m) => msgs.push(m),
});
const st = rd();
const fwd = S.VALID_STEPS.slice(0, S.VALID_STEPS.indexOf("detail"));
const back = S.VALID_STEPS.slice(S.VALID_STEPS.indexOf("detail"));
const badF = [];
for (const s of fwd) {
  const e = st.steps[s] || {};
  if (e.status !== "complete") badF.push(s + "/status=" + e.status);
  else if (typeof e.started_at !== "string") badF.push(s + "/no-started_at");
  else if (e.started_at !== e.updated_at) badF.push(s + "/not-synthetic");
}
const badB = [];
for (const s of back) {
  const e = st.steps[s] || {};
  if (e.status !== "pending") badB.push(s + "/status=" + e.status);
  else if ("started_at" in e) badB.push(s + "/has-started_at");
}
console.log("fwd=" + (badF.length ? badF.join(",") : "ok") + " back=" + (badB.length ? badB.join(",") : "ok"));
'
assert_eq "C1-a+C1-b/reset-forward-and-back" "fwd=ok back=ok" "$NODE_OUT"
check_invariant "C1-ab" "$SID" on

echo "== C1-d: with the toggle off, reset writes exactly the two legacy keys =="
next_sid
nodejs off "$SID" "$PRE"'
const rh = require("./hooks/workflow-mark/reset-handler");
S.markStep(sid, "workflow_init", "complete");
rh.handle({
  cmd: "echo \"<<WORKFLOW_RESET_FROM_detail: measurement timestamp coverage>>\"",
  sessionId: sid,
  pushMessage: () => {},
});
const st = rd();
const shapes = new Set();
for (const s of S.VALID_STEPS.slice(0, S.VALID_STEPS.indexOf("detail"))) {
  shapes.add(Object.keys(st.steps[s]).sort().join(","));
}
console.log([...shapes].join("|"));
'
assert_eq "C1-d/legacy-shape" "status,updated_at" "$NODE_OUT"
check_invariant "C1-d" "$SID" off

# ---- D9: the other reset routes ---------------------------------------------

echo "== D9: workflow_init complete resets downstream steps and drops started_at =="
next_sid
nodejs on "$SID" "$PRE"'
const mh = require("./hooks/workflow-mark/mark-step-handler");
S.markStep(sid, "run_tests", "complete");
const had = typeof rd().steps.run_tests.started_at === "string";
mh.handle({
  cmd: "echo \"<<WORKFLOW_MARK_STEP_workflow_init_complete>>\"",
  sessionId: sid,
  pushMessage: () => {},
  signalFatal: () => {},
  repoCwd: process.cwd(),
});
const e = rd().steps.run_tests;
console.log("had=" + had + " after=" + ("started_at" in e) + " status=" + e.status);
'
assert_eq "D9/downstream-reset" "had=true after=false status=pending" "$NODE_OUT"
check_invariant "D9" "$SID" on

echo "== D10: bin/workflow/next-step --reset drops started_at =="
next_sid
nodejs on "$SID" "$PRE"'
S.markStep(sid, "run_tests", "complete");
console.log(typeof rd().steps.run_tests.started_at === "string" ? "seeded" : "not-seeded");
'
assert_eq "D10/seed" "seeded" "$NODE_OUT"
NS_RC=0
NS_OUT="$(cd "$AGENTS_DIR" && env RECORD_STEP_TIMESTAMPS=on CLAUDE_WORKFLOW_DIR="$WF_NATIVE" \
    AGENTS_CONFIG_DIR="$CFG_NATIVE" HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" \
    "$AGENTS_DIR/bin/run-with-timeout.sh" 60 node ./bin/workflow/next-step --session "$SID" --reset run_tests 2>&1)" || NS_RC=$?
assert_eq "D10/next-step-reset-exit-0" "0" "$NS_RC"
nodejs on "$SID" "$PRE"'
const e = rd().steps.run_tests;
console.log("status=" + e.status + " started_at=" + ("started_at" in e));
'
assert_eq "D10/after-reset" "status=pending started_at=false" "$NODE_OUT"
check_invariant "D10" "$SID" on

echo "== D11: the post-push reset route (markStep pending) drops started_at =="
next_sid
nodejs on "$SID" "$PRE"'
S.markStep(sid, "branching_complete", "complete");
S.setLastPushedSha(sid, "0000000000000000000000000000000000000000");
const had = typeof rd().steps.branching_complete.started_at === "string";
S.markStep(sid, "branching_complete", "pending");
const e = rd().steps.branching_complete;
console.log("had=" + had + " after=" + ("started_at" in e) + " status=" + e.status);
'
assert_eq "D11/post-push-route" "had=true after=false status=pending" "$NODE_OUT"
check_invariant "D11" "$SID" on

# ---- D12: existing gates are unaffected -------------------------------------

echo "== D12: next-step verdicts are identical with the toggle on and off =="
SEED_JS="$PRE$APPROVE_GATED_JS"'
S.markStep(sid, "workflow_init", "complete");
S.markStep(sid, "clarify_intent", "complete");
S.markStep(sid, "research", "skipped");
S.markStep(sid, "outline", "complete");
console.log("SEEDED");
'
next_sid; SID_ON="$SID";  nodejs on  "$SID_ON"  "$SEED_JS"; assert_eq "D12/seed-on"  "SEEDED" "$NODE_OUT"
next_sid; SID_OFF="$SID"; nodejs off "$SID_OFF" "$SEED_JS"; assert_eq "D12/seed-off" "SEEDED" "$NODE_OUT"

next_step_verdict() { # <toggle> <sid>
    local out
    out="$(cd "$AGENTS_DIR" && env RECORD_STEP_TIMESTAMPS="$1" CLAUDE_WORKFLOW_DIR="$WF_NATIVE" \
        AGENTS_CONFIG_DIR="$CFG_NATIVE" HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" \
        "$AGENTS_DIR/bin/run-with-timeout.sh" 60 node ./bin/workflow/next-step --session "$2" 2>&1)" || true
    grep -E '^(ACTION|NEXT_SKILL)=' <<< "$out" | tr '\n' ';'
}
VERDICT_ON="$(next_step_verdict on "$SID_ON")"
VERDICT_OFF="$(next_step_verdict off "$SID_OFF")"
NONEMPTY="empty"
[ -n "$VERDICT_ON" ] && NONEMPTY="nonempty"
assert_eq "D12/verdict-observable" "nonempty" "$NONEMPTY"
assert_eq "D12/verdicts-match" "$VERDICT_OFF" "$VERDICT_ON"
check_invariant "D12/on"  "$SID_ON"  on
check_invariant "D12/off" "$SID_OFF" off

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
