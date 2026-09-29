#!/usr/bin/env bash
# Tests: hooks/workflow-state/state-io/review-tests.js
# Tags: TL2, workflow-state, review-tests, warnings, concurrency, event-stream, scope:issue-specific
#
# #2327 C11: a warnings_summary appended by a concurrent writer WHILE
# clearReviewTestsWarnings is in progress (after its clear batch has committed)
# must be PRESERVED — the clear may tombstone only the warning it observed in-lock,
# never a later one. Clear + reason + review_scope_manifest land in ONE batch.
# TDD: the manifest assertion FAILs until clearReviewTestsWarnings writes the manifest.

set -uo pipefail
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

TMPD="$(make_tmp)"
trap 'rm -rf "$TMPD"' EXIT
harness_isolate "$TMPD"
export CLAUDE_WORKFLOW_DIR="$(np "$CLAUDE_WORKFLOW_DIR")"
export WORKFLOW_PLANS_DIR="$(np "$WORKFLOW_PLANS_DIR")"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_PROJECT_DIR 2>/dev/null || true
cd "$TMPD" || exit 1

AGENTS_N="$(np "$AGENTS_DIR")"

# Interleaving is forced deterministically: events.appendEvents is wrapped BEFORE
# review-tests.js loads (it may destructure appendEvents at require time). W1 is
# seeded before the call; the wrapper injects W2 right after the first counted
# appendEvents (the clear batch) commits, while clearReviewTestsWarnings is still
# on the stack — any later clobbering write would therefore land after W2.
cat > "$TMPD/interleave.js" << 'JSEOF'
"use strict";
const [,, agents, sid] = process.argv;
const fs = require("fs"), path = require("path");
const base = agents + "/hooks/workflow-state/state-io/";
const out = {};
const W1 = "W1-early: 1 advisory finding";
const W2 = "W2-late: 1 advisory finding";
const ann = (value, origin) => ({ kind: "step_annotation", step: "review_tests", key: "warnings_summary",
  value, provenance: "observed", origin });
try {
  const core = require(base + "core");
  const events = require(base + "events");
  const origAppend = events.appendEvents;
  let counting = false;
  let appendCalls = 0;
  let injected = false;
  events.appendEvents = function(...a) {
    const r = origAppend.apply(this, a);
    if (counting) {
      appendCalls++;
      if (!injected) {
        injected = true;
        origAppend(sid, [ann(W2, "c11-writer-late")]);
      }
    }
    return r;
  };
  delete require.cache[require.resolve(base + "review-tests")];
  const RT = require(base + "review-tests");

  core.markStep(sid, "review_tests", "complete", {});
  origAppend(sid, [ann(W1, "c11-writer-early")]);
  const pre = core.readState(sid);
  out.pre_warn = (pre && pre.steps && pre.steps.review_tests && pre.steps.review_tests.warnings_summary) || "none";

  const manifest = { ok: true, v: 1, files: { "tests/a.sh": "1111111111111111111111111111111111111111" } };
  counting = true;
  RT.clearReviewTestsWarnings(sid, "c11-accepted", manifest);
  counting = false;

  const st = JSON.parse(fs.readFileSync(path.join(process.env.CLAUDE_WORKFLOW_DIR, sid + ".json"), "utf8"));
  const rt = (st.current && st.current.steps && st.current.steps.review_tests) || {};
  const evs = st.events || [];
  const w1 = evs.find((e) => e.origin === "c11-writer-early");
  const w2 = evs.find((e) => e.origin === "c11-writer-late");
  const clears = evs.filter((e) => e.key === "warnings_summary" && e.value === null);
  out.injected = !!w2;
  out.post_warn = rt.warnings_summary === undefined || rt.warnings_summary === null ? "none" : String(rt.warnings_summary);
  out.reason = rt.warnings_accepted_reason === undefined ? "none" : rt.warnings_accepted_reason;
  // The observed W1 is tombstoned between W1 and W2; nothing tombstones W2 afterwards.
  out.clear_between = !!(w1 && w2 && clears.some((c) => c.seq > w1.seq && c.seq < w2.seq));
  out.clear_after_late = !!(w2 && clears.some((c) => c.seq > w2.seq));
  out.append_calls = appendCalls;
  out.manifest_has_path = JSON.stringify(rt.review_scope_manifest || null).indexOf("tests/a.sh") !== -1;
  out.status = rt.status;
} catch (e) {
  out.error = String(e && e.message).split("\n")[0];
}
process.stdout.write(JSON.stringify(out));
JSEOF

field() { # <json> <key>
    node -e 'const o=JSON.parse(process.argv[1]);const v=o[process.argv[2]];process.stdout.write(v===undefined?"UNDEF":String(v))' "$1" "$2" 2>/dev/null || echo "PARSE_ERROR"
}

echo "=== C11: warning appended during clearReviewTestsWarnings is preserved ==="
OUT="$(run_with_timeout 60 node "$(np "$TMPD/interleave.js")" "$AGENTS_N" "c11-interleave-$$" 2>/dev/null || echo '{"error":"crashed"}')"
echo "probe: $OUT"
assert_eq "$(field "$OUT" error)" "UNDEF"
assert_eq "$(field "$OUT" pre_warn)" "W1-early: 1 advisory finding"
assert_eq "$(field "$OUT" injected)" "true"
assert_eq "$(field "$OUT" post_warn)" "W2-late: 1 advisory finding"
assert_eq "$(field "$OUT" reason)" "c11-accepted"
assert_eq "$(field "$OUT" clear_between)" "true"
assert_eq "$(field "$OUT" clear_after_late)" "false"
assert_eq "$(field "$OUT" append_calls)" "1"
assert_eq "$(field "$OUT" status)" "complete"
assert_eq "$(field "$OUT" manifest_has_path)" "true"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
