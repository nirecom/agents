# shellcheck shell=bash
# Tests: hooks/workflow-state/state-io/migrations/v3-to-v4.js, hooks/workflow-state/state-io/core.js
# Tags: TL2, docs, review-docs, workflow, state-io, migration, schema-version, scope:issue-specific, pwsh-not-required
#
# GROUP F: the v3 -> v4 migration stage. review_docs is inserted between docs and
# user_verification. v3->v4 backfills review_docs=complete only when a step
# DOWNSTREAM of it (user_verification .. final_report) is already settled — docs
# is upstream and must NOT trigger it. Mirrors feature-1665-write-code-step/f-v2-to-v3.sh.

# mk_state <sid> <version> <step=status;...> — a versioned state file whose
# events[] is exactly the listed step_status records (seq 1..N, one hour apart).
mk_state() {
  local sid="$1" ver="$2" spec="$3"
  F_SID="$sid" F_VER="$ver" F_SPEC="$spec" run_node -e '
const fs = require("fs"), path = require("path");
const spec = (process.env.F_SPEC || "").split(";").filter(Boolean);
const events = spec.map((p, i) => {
  const [step, status] = p.split("=");
  return { kind: "step_status", step, status, seq: i + 1,
    at: new Date(Date.UTC(2026, 0, 1, i)).toISOString(),
    provenance: "observed", origin: "fixture-2340-f" };
});
const out = { version: Number(process.env.F_VER), session_id: process.env.F_SID,
  created_at: "2026-01-01T00:00:00.000Z",
  session_start_context: { cwd: null, git_branch: null },
  workflow_type: "wf-code", events };
fs.writeFileSync(path.join(process.env.CLAUDE_WORKFLOW_DIR, process.env.F_SID + ".json"),
  JSON.stringify(out, null, 2));
' 2>&1
}

# f_probe <sid> <js> — one node process with the fixture reader preamble bound.
f_probe() {
  local sid="$1" js="$2"
  F_SID="$sid" CORE_N="$AGENTS_DIR_N/hooks/workflow-state/state-io/core.js" \
  MIG_N="$AGENTS_DIR_N/hooks/workflow-state/state-io/migrations/v3-to-v4.js" \
  run_node -e '
const fs = require("fs"), path = require("path");
const CORE = require(process.env.CORE_N);
const sid = process.env.F_SID;
const sp = path.join(process.env.CLAUDE_WORKFLOW_DIR, sid + ".json");
const rd = () => JSON.parse(fs.readFileSync(sp, "utf8"));
const norm = () => CORE.normalizeStateVersion(rd());
const rdEvents = (st) => (st.events || []).filter((e) => e.kind === "step_status" && e.step === "review_docs");
'"$js" 2>&1
}

# Steps up to and including docs, review_docs deliberately absent.
UPTO_DOCS="workflow_init=complete;clarify_intent=complete;research=skipped;outline=complete;detail=complete;branching_complete=complete;write_tests=complete;review_tests=complete;write_code=complete;run_tests=complete;review_security=complete;docs=complete"

run_group_f() {
  require_module "F" "hooks/workflow-state/state-io/migrations/v3-to-v4.js" || return 0
  local out

  # F1: a settled downstream step (user_verification=complete) backfills review_docs.
  mk_state f1 3 "$UPTO_DOCS;user_verification=complete" >/dev/null
  out="$(f_probe f1 '
const { migrateV3ToV4 } = require(process.env.MIG_N);
const m = migrateV3ToV4(rd());
const ev = rdEvents(m);
console.log("version=" + m.version + " count=" + ev.length +
  " status=" + (ev[0] ? ev[0].status : "<none>") +
  " provenance=" + (ev[0] ? ev[0].provenance : "<none>"));
')"
  assert_eq "F1: user_verification settled → review_docs backfilled complete" \
    "version=4 count=1 status=complete provenance=backfilled" "$out"

  # F2: docs is UPSTREAM of review_docs; nothing after review_docs is settled →
  # no backfill (fabricating a completion would skip real unfinished review).
  mk_state f2 3 "$UPTO_DOCS" >/dev/null
  out="$(f_probe f2 '
const { migrateV3ToV4 } = require(process.env.MIG_N);
const m = migrateV3ToV4(rd());
console.log("version=" + m.version + " count=" + rdEvents(m).length);
')"
  assert_eq "F2: docs complete but nothing downstream → review_docs NOT backfilled" \
    "version=4 count=0" "$out"

  # F3: all pending → no backfill.
  mk_state f3 3 "workflow_init=complete;clarify_intent=complete" >/dev/null
  out="$(f_probe f3 '
const { migrateV3ToV4 } = require(process.env.MIG_N);
const m = migrateV3ToV4(rd());
console.log("version=" + m.version + " count=" + rdEvents(m).length);
')"
  assert_eq "F3: nothing settled after review_docs → NOT backfilled" \
    "version=4 count=0" "$out"

  # F4: a v4 file is already current → normalizeStateVersion is a no-op.
  mk_state f4 4 "$UPTO_DOCS;user_verification=complete" >/dev/null
  out="$(f_probe f4 '
const before = JSON.stringify(rd());
const n = norm();
console.log("version=" + n.version + " unchanged=" + (JSON.stringify(n) === before));
')"
  assert_eq "F4: v4 state → normalizeStateVersion no-op" \
    "version=4 unchanged=true" "$out"

  # F5: a v2 file chains v2->v3->v4 — write_code (v2->v3) AND review_docs (v3->v4)
  # are both backfilled when a step downstream of each is settled.
  mk_state f5 2 "workflow_init=complete;clarify_intent=complete;research=skipped;outline=complete;detail=complete;branching_complete=complete;write_tests=complete;review_tests=complete;run_tests=complete;review_security=complete;docs=complete;user_verification=complete" >/dev/null
  out="$(f_probe f5 '
const n = norm();
const has = (step) => n.events.some((e) => e.kind === "step_status" && e.step === step && e.provenance === "backfilled");
console.log("version=" + n.version + " write_code=" + has("write_code") + " review_docs=" + has("review_docs"));
')"
  assert_eq "F5: v2 chains v2->v3->v4, both write_code and review_docs backfilled" \
    "version=4 write_code=true review_docs=true" "$out"
}
