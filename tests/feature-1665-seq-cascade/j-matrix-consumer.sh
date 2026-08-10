#!/bin/bash
# tests/feature-1665-seq-cascade/j-matrix-consumer.sh
# Tests: hooks/lib/stop-exemption-policy.js, hooks/stop-premature-stop-guard.js, hooks/workflow-state/lifecycle.js, bin/workflow/lib/next-step/verdict.js
# Tags: workflow-state, write-code, stop-guard, exemption-matrix, registration, orthogonality, scope:issue-specific, pwsh-not-required, TL1
#
# J — the declarative exemption matrix and its consumers stay in agreement.
#
# WHY: EXEMPTION_MATRIX is documentation-shaped — it declares which quiet layers
# each condition affects (c4 / c2 / nextStep) but enforces nothing. A row added
# without the matching consumer registration is a silent no-op, and a consumer
# registered without a row is an undocumented bypass. J6 checks the whole class
# (CPR-E2C), not just the row #1665 adds.
#
# `write-code-in-flight` is c4-only by design: next-step must keep answering
# normally during /write-code (the session is expected to call it), and C2 is a
# scheduled supervisor review that a long implementation turn should not defer.

CASE_TAG=j
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

js '
const { EXEMPTION_MATRIX: M } = require(process.env.M_POLICY);
const G = require(process.env.M_GUARD);
const L = require(process.env.M_LIFE);

const row = M["write-code-in-flight"] || {};
console.log("J1.present=" + Object.prototype.hasOwnProperty.call(M, "write-code-in-flight"));
console.log("J1.c4=" + JSON.stringify(row.c4));
console.log("J1.c2=" + JSON.stringify(row.c2));
console.log("J1.nextStep=" + JSON.stringify(row.nextStep));

const ids = (G.C4_EXEMPTIONS || []).map((e) => e.id);
console.log("J2.registered=" + ids.includes("write-code-in-flight"));
console.log("J2.ids=" + ids.join(","));

const deps = G.buildExemptionDeps ? G.buildExemptionDeps() : {};
console.log("J3.dep_type=" + typeof deps.isWriteCodeInFlight);

console.log("J4.ttl=" + JSON.stringify(L.WRITE_CODE_IN_FLIGHT_TTL_MS));
console.log("J5.fn_type=" + typeof L.isWriteCodeInFlight);

// CPR-E2C: every c4:true row must have a guard registration, and every guard
// registration must have a row.
const missingRegistration = Object.keys(M).filter((k) => M[k].c4 && !ids.includes(k));
const missingRow = ids.filter((id) => !Object.prototype.hasOwnProperty.call(M, id));
console.log("J6.missing_registration=" + (missingRegistration.length ? missingRegistration.join(",") : "none"));
console.log("J6.missing_row=" + (missingRow.length ? missingRow.join(",") : "none"));
'

if require_js_ok "J: matrix probe"; then
    assert_js "J1 matrix declares the write-code-in-flight row" J1.present "true"
    assert_js "J1 row silences C4" J1.c4 "true"
    assert_js "J1 row does NOT silence C2" J1.c2 "false"
    assert_js "J1 row does NOT silence next-step" J1.nextStep "false"
    assert_js "J2 guard registers the exemption" J2.registered "true"
    assert_js "J3 buildExemptionDeps injects the predicate" J3.dep_type "function"
    assert_js "J4 TTL is 4 hours" J4.ttl "14400000"
    assert_js "J5 lifecycle exports the predicate" J5.fn_type "function"
    assert_js "J6 every c4 row has a guard registration" J6.missing_registration "none"
    assert_js "J6 every guard registration has a matrix row" J6.missing_row "none"
fi

# The nextStep:false declaration must be true of the code, not just the table.
VERDICT_REFS="$(grep -c "isWriteCodeInFlight" "$AGENTS_DIR/bin/workflow/lib/next-step/verdict.js" || true)"
assert_eq "J7 next-step does not consult the write_code in-flight marker" "0" "$VERDICT_REFS"

finish
