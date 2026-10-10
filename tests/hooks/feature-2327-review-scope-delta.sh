#!/usr/bin/env bash
# Tests: hooks/workflow-gate/review-scope-delta.js
# Tags: workflow, gate, review-tests, scope-delta, pure-function, TL1, scope:issue-specific
#
# Pure-function unit tests for review-scope-delta.js:
#   latestRecordedManifest(events) and decideReviewScope(recorded, current).
# Event shapes match real state-io writes (events.js, review-tests.js).

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

TMPDIR_BASE="$(make_tmp)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
harness_isolate "$TMPDIR_BASE"

DELTA_JS="$(np "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-gate/review-scope-delta.js")"

# Write the JS test runner to a temp file at runtime
cat > "$TMPDIR_BASE/runner.js" << 'JSEOF'
"use strict";
const deltaJsPath = process.argv[2];
let m;
try { m = require(deltaJsPath); }
catch (e) {
  process.stdout.write("MODULE_MISSING:" + e.message.split("\n")[0] + "\n");
  process.exit(0);
}
const LRM = m.latestRecordedManifest;
const DRS = m.decideReviewScope;
if (typeof LRM !== "function") { process.stdout.write("MODULE_MISSING:latestRecordedManifest not exported\n"); process.exit(0); }
if (typeof DRS !== "function") { process.stdout.write("MODULE_MISSING:decideReviewScope not exported\n"); process.exit(0); }

function ok(name, cond, detail) {
  process.stdout.write((cond ? "PASS:" : "FAIL:") + name + ((!cond && detail) ? " -- " + detail : "") + "\n");
}

// --- event builders (shape = real state-io writes) ---
function mev(files) {
  return { kind:"step_annotation", step:"review_tests", key:"review_scope_manifest",
    value:{ v:1, files }, provenance:"observed", origin:"review-tests-complete", at:"2025-01-01T00:00:00.000Z" };
}
function tomb() {
  return { kind:"step_annotation", step:"review_tests", key:"review_scope_manifest",
    value:null, provenance:"declared", origin:"invalidate-review-tests", at:"2025-01-01T00:00:00.000Z" };
}
function widrClear() { // workflow-init-downstream-reset (discards)
  return { kind:"step_annotations_cleared", step:"review_tests",
    provenance:"declared", origin:"workflow-init-downstream-reset", at:"2025-01-01T00:00:00.000Z" };
}
function rstrClear() { // reset-handler (RESET_FROM, keeps manifest)
  return { kind:"step_annotations_cleared", step:"review_tests",
    provenance:"declared", origin:"reset-handler", at:"2025-01-01T00:00:00.000Z" };
}
function wcdPending() { // write-code-scope-drift (keeps manifest)
  return { kind:"step_status", step:"review_tests", status:"pending",
    provenance:"observed", origin:"write-code-scope-drift", at:"2025-01-01T00:00:00.000Z" };
}

// ============================================================
// latestRecordedManifest tests
// ============================================================

// L1: empty events → null
ok("L1.lrm-empty", LRM([]) === null);

// L2: single manifest → returns it
{ const r = LRM([mev({"tests/a.sh":"aaa"})]); ok("L2.lrm-basic", r !== null && r.v === 1 && r.files["tests/a.sh"] === "aaa"); }

// L3: tombstone discards prior manifest
ok("L3.lrm-tombstone", LRM([mev({"tests/a.sh":"aaa"}), tomb()]) === null);

// L4: workflow-init-downstream-reset clears, subsequent manifest survives
{
  const r = LRM([mev({"tests/a.sh":"old"}), widrClear(), mev({"tests/b.sh":"new"})]);
  ok("L4.lrm-widr-discards-prior", r !== null && r.files["tests/b.sh"] === "new" && !r.files["tests/a.sh"]);
}

// L5: workflow-init-downstream-reset with no subsequent manifest → null
ok("L5.lrm-widr-no-after", LRM([mev({"tests/a.sh":"aaa"}), widrClear()]) === null);

// L6: reset-handler clear does NOT discard manifest (RESET_FROM keeps it)
{
  const r = LRM([mev({"tests/a.sh":"aaa"}), rstrClear()]);
  ok("L6.lrm-reset-handler-keeps", r !== null && r.files["tests/a.sh"] === "aaa");
}

// L7: write-code-scope-drift (step_status pending) does NOT discard manifest
{
  const r = LRM([mev({"tests/a.sh":"aaa"}), wcdPending()]);
  ok("L7.lrm-wcdrift-keeps", r !== null && r.files["tests/a.sh"] === "aaa");
}

// L8: write_code reopen + 2nd review: latestRecordedManifest returns the 2nd (most recent) manifest
{
  const m1 = mev({"tests/a.sh":"aaa", "hooks/impl.js":"old"});
  const m2 = mev({"tests/a.sh":"aaa", "hooks/impl.js":"new"});
  const r = LRM([m1, wcdPending(), m2]);
  ok("L8.lrm-wcdrift-then-2nd-review", r !== null && r.files["hooks/impl.js"] === "new");
}

// ============================================================
// decideReviewScope tests
// ============================================================

// D1: recorded=null → full, no-record
{ const r = DRS(null, { ok:true, files:{"tests/a.sh":"x"} });
  ok("D1.drs-no-record-null", r.scope === "full" && r.reason === "no-record"); }

// D2: recorded v≠1 → full, no-record
{ const r = DRS({ v:2, files:{} }, { ok:true, files:{"tests/a.sh":"x"} });
  ok("D2.drs-no-record-v2", r.scope === "full" && r.reason === "no-record"); }

// D3: malformed recorded → full, no-record
{ const r = DRS("broken", { ok:true, files:{"tests/a.sh":"x"} });
  ok("D3.drs-no-record-broken", r.scope === "full" && r.reason === "no-record"); }

// D4: recorded with missing files → full, no-record
{ const r = DRS({ v:1 }, { ok:true, files:{"tests/a.sh":"x"} });
  ok("D4.drs-no-record-missing-files", r.scope === "full" && r.reason === "no-record"); }

// D5: D is empty (recorded=current) → full, explicit-rereview
{ const files = {"tests/a.sh":"aaa","hooks/impl.js":"bbb"};
  const r = DRS({ v:1, files }, { ok:true, files });
  ok("D5.drs-explicit-rereview", r.scope === "full" && r.reason === "explicit-rereview"); }

// D6: D has impl file → full, impl-changed
{ const r = DRS(
    { v:1, files:{"tests/a.sh":"aaa","hooks/impl.js":"old"} },
    { ok:true, files:{"tests/a.sh":"aaa","hooks/impl.js":"new"} });
  ok("D6.drs-impl-changed", r.scope === "full" && r.reason === "impl-changed"); }

// D7: D is tests-only → delta, tests-only
{ const r = DRS(
    { v:1, files:{"tests/a.sh":"old","hooks/impl.js":"same"} },
    { ok:true, files:{"tests/b.sh":"new","hooks/impl.js":"same"} });
  ok("D7.drs-tests-only-delta", r.scope === "delta" && r.reason === "tests-only"); }

// D8: delta scope — added test in review, deleted test in deleted, unchanged in inventory
{ const r = DRS(
    { v:1, files:{"tests/old.sh":"x","tests/keep.sh":"y","hooks/impl.js":"z"} },
    { ok:true, files:{"tests/new.sh":"n","tests/keep.sh":"y","hooks/impl.js":"z"} });
  ok("D8.drs-delta-scope", r.scope === "delta" && r.reason === "tests-only");
  ok("D8.drs-delta-review-has-new", (r.review||[]).some(p => String(p).replace(/\\/g,"/").includes("new.sh")));
  ok("D8.drs-delta-deleted-has-old", (r.deleted||[]).some(p => String(p).replace(/\\/g,"/").includes("old.sh")));
  ok("D8.drs-delta-inventory-has-keep", (r.inventory||[]).some(p => String(p).replace(/\\/g,"/").includes("keep.sh"))); }

// D9: delete-only D → REVIEW empty, DELETED non-empty
{ const r = DRS(
    { v:1, files:{"tests/old.sh":"x","tests/keep.sh":"y"} },
    { ok:true, files:{"tests/keep.sh":"y"} });
  ok("D9.drs-delete-only-scope", r.scope === "delta");
  ok("D9.drs-delete-only-review-empty", (r.review||[]).length === 0);
  ok("D9.drs-delete-only-has-deleted", (r.deleted||[]).some(p => String(p).replace(/\\/g,"/").includes("old.sh"))); }

// D10: full scope → REVIEW all staged tests, DELETED/INVENTORY empty
{ const r = DRS(null, { ok:true, files:{"tests/a.sh":"x","tests/b.sh":"y","hooks/impl.js":"z"} });
  ok("D10.drs-full-review-count", r.scope === "full" && (r.review||[]).length === 2);
  ok("D10.drs-full-deleted-empty", (r.deleted||[]).length === 0);
  ok("D10.drs-full-inventory-empty", (r.inventory||[]).length === 0); }

// D11: SOURCE excludes CHANGELOG.md, changelog/, docs/, root README.md
{ const r = DRS(null, { ok:true, files:{
    "hooks/impl.js":"a", "CHANGELOG.md":"b", "changelog/2026.md":"c",
    "docs/guide.md":"d", "README.md":"e"
  }});
  const srcs = (r.sources||[]).map(p => String(p).replace(/\\/g,"/"));
  ok("D11.source-has-impl",     srcs.some(p => p.endsWith("hooks/impl.js")));
  ok("D11.source-no-changelog", !srcs.some(p => p.includes("CHANGELOG.md")));
  ok("D11.source-no-clog-dir",  !srcs.some(p => p.includes("changelog/2026")));
  ok("D11.source-no-docs",      !srcs.some(p => p.includes("docs/guide")));
  ok("D11.source-no-readme",    !srcs.some(p => p === "README.md" || p.endsWith("/README.md"))); }

// D12: SOURCE excludes excluded paths in delta scope too
{ const r = DRS(
    { v:1, files:{"tests/a.sh":"old","hooks/impl.js":"same","CHANGELOG.md":"x"} },
    { ok:true, files:{"tests/b.sh":"new","hooks/impl.js":"same","CHANGELOG.md":"x"} });
  ok("D12.delta-source-no-changelog",
     r.scope === "delta" && !(r.sources||[]).some(p => String(p).includes("CHANGELOG"))); }
JSEOF

out=$(run_with_timeout 30 node "$TMPDIR_BASE/runner.js" "$DELTA_JS" 2>&1) || true

if printf '%s\n' "$out" | grep -q "^MODULE_MISSING:"; then
  msg=$(printf '%s\n' "$out" | grep "^MODULE_MISSING:" | head -1)
  fail "review-scope-delta.js (all tests)" "review-scope-delta.js not yet implemented — ${msg#MODULE_MISSING:}"
else
  while IFS= read -r line; do
    case "$line" in
      PASS:*) pass "${line#PASS:}" ;;
      FAIL:*) fail "${line#FAIL:}" ;;
    esac
  done <<< "$out"
  if ! printf '%s\n' "$out" | grep -qE "^(PASS|FAIL):"; then
    fail "review-scope-delta.js runner" "no PASS/FAIL output — unexpected: $out"
  fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
