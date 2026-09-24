# tests/enforce-off-emergency-provenance/cases-p13-verify-bounds.sh
# P13: the reader's bounds, at the exact millisecond they turn over. P5/P6 prove
# the bounds exist; only these prove WHERE they are. Sourced by
# ../enforce-off-emergency-provenance.sh; relies on that file's shared helpers
# (assert_eq, TMP, PROVENANCE_SSOT, RWT).
# Tests: hooks/record-off-skill-invocation.js, hooks/lib/off-emergency-provenance.js, hooks/workflow-mark/enforce-override-handlers/off-clearance.js, hooks/lib/protected-basenames.js, hooks/block-clearance-token-write.js, settings.json
# Tags: off-clearance, emergency-off, provenance, audit, userpromptsubmit, session-marker, security, scope:common, pwsh-not-required, TL2, hook-registration

run_P13_verify_bounds() {
# The driver hands verifyProvenanceMarker() the same `now` it dated the marker
# from, so `bound` and `bound + 1ms` are decided by the comparison operator,
# never by elapsed time. Shape edges live here too: they are the reader's
# contract, not the writer's.
VDRIVER="$TMP/verify-driver.js"
cat > "$VDRIVER" <<'VDRIVER_EOF'
"use strict";
const lib = require(process.argv[2]);
const target = process.argv[3];
const delta = Number(process.argv[4]);
const override = process.argv[5] || "";
const now = Date.now();
let raw;
if (override.indexOf("RAW:") === 0) {
  raw = override.slice(4);
} else {
  const m = lib.buildProvenanceMarker(now + delta);
  if (override) Object.assign(m, JSON.parse(override));
  if (m.source === "__DELETE__") delete m.source;
  raw = JSON.stringify(m);
}
const r = lib.verifyProvenanceMarker(raw, target, now);
process.stdout.write(String(!!(r && r.attributed === true)));
VDRIVER_EOF

while IFS='|' read -r name want target delta override; do
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    got=$("$RWT" 10 node "$VDRIVER" "$PROVENANCE_SSOT" "$target" "$delta" "$override" 2>/dev/null)
    assert_eq "P13 verifyProvenanceMarker: $name" "$want" "$got"
done <<'P13_BOUNDS'
exactly-at-the-10-minute-bound|true|workflow|-600000|
one-ms-past-the-10-minute-bound|false|workflow|-600001|
exactly-at-the-60-second-future-tolerance|true|workflow|60000|
one-ms-past-the-60-second-future-tolerance|false|workflow|60001|
empty-target-list-authorizes-nothing|false|workflow|-1000|{"targets":[]}
duplicate-targets-still-authorize|true|workflow|-1000|{"targets":["workflow","workflow"]}
targets-as-a-bare-string-is-not-a-list|false|workflow|-1000|{"targets":"workflow"}
unparseable-invoked-at|false|workflow|-1000|{"invoked_at":"not-a-date"}
null-invoked-at|false|workflow|-1000|{"invoked_at":null}
numeric-invoked-at-is-not-the-contract|false|workflow|-1000|{"invoked_at":1}
empty-raw-marker|false|workflow|0|RAW:
array-shaped-marker|false|workflow|0|RAW:[]
null-shaped-marker|false|workflow|0|RAW:null
target-not-in-the-list|false|worktree|-1000|{"targets":["workflow"]}
attacker-controlled-source-is-rejected|false|workflow|-1000|{"source":"attacker-controlled"}
null-source-is-rejected|false|workflow|-1000|{"source":null}
missing-source-field-is-rejected|false|workflow|-1000|{"source":"__DELETE__"}
P13_BOUNDS
}
