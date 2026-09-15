#!/usr/bin/env bash
# tests/feature-2256-input-version-full-hash/artifact-and-freshness.sh
# Tests: hooks/lib/diff-fingerprint.js, hooks/lib/audit-ledger.js
# Tags: supervisor, artifact-key, freshness-key, sub-check-independence, TL2, scope:issue-specific
# #2256 C1 + S6-b: the freshness key composes code and plan artifacts, and a settled TR1
# must never no-op TR2/TR3. Parent: tests/feature-2256-input-version-full-hash.sh

set -uo pipefail
# shellcheck source=./_common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

WRITER_NODE="$AGENTS_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$AGENTS_NODE/hooks/lib/supervisor-state-schema.js"
LEDGER_NODE="$AGENTS_NODE/hooks/lib/audit-ledger.js"

repo="$(mk_repo fr)"
printf 'code\n' > "$WORK/fr/seed.txt"
SID="frsess"
PLANS="$WORK_NODE/plans"
printf '# intent\nI1\n' > "$WORK/plans/$SID-intent.md"
printf '# outline\nO1\n' > "$WORK/plans/$SID-outline.md"
printf '# detail\nD1\n' > "$WORK/plans/$SID-detail.md"

freshness() { fp computeFreshnessKey "$repo" ", '$PLANS', '$SID'"; }
field() {
    printf '%s' "$1" | node -e "
let s = '';
process.stdin.on('data', (d) => (s += d)).on('end', () => {
  try { const o = JSON.parse(s); const p = '$2'.split('.'); let v = o; for (const k of p) v = v && v[k]; process.stdout.write(String(v)); }
  catch (e) { process.stdout.write('PARSE-ERROR'); }
});" 2>&1
}

base_json="$(freshness)"
base_iv="$(field "$base_json" input_version)"
base_fk="$(field "$base_json" freshness_key)"

# --- 1-3: editing a plan artifact moves the freshness key but not the input version ---
printf '# detail\nD2\n' > "$WORK/plans/$SID-detail.md"
j="$(freshness)"
assert_eq "1: editing detail.md leaves input_version unchanged" "$(field "$j" input_version)" "$base_iv"
assert_ne "2: editing detail.md moves freshness_key" "$(field "$j" freshness_key)" "$base_fk"
assert_ne "3: editing detail.md moves artifact_keys.detail" "$(field "$j" artifact_keys.detail)" "$(field "$base_json" artifact_keys.detail)"

printf '# detail\nD1\n' > "$WORK/plans/$SID-detail.md"
printf '# outline\nO2\n' > "$WORK/plans/$SID-outline.md"
j="$(freshness)"
assert_ne "4: editing outline.md moves freshness_key" "$(field "$j" freshness_key)" "$base_fk"
assert_eq "5: editing outline.md leaves artifact_keys.detail alone" "$(field "$j" artifact_keys.detail)" "$(field "$base_json" artifact_keys.detail)"

printf '# outline\nO1\n' > "$WORK/plans/$SID-outline.md"
printf '# intent\nI2\n' > "$WORK/plans/$SID-intent.md"
j="$(freshness)"
assert_ne "6: editing intent.md moves freshness_key" "$(field "$j" freshness_key)" "$base_fk"
printf '# intent\nI1\n' > "$WORK/plans/$SID-intent.md"

# --- 7-8: the code side still moves it, and the key is stable when nothing moves ---
printf 'code-changed\n' > "$WORK/fr/seed.txt"
j="$(freshness)"
assert_ne "7: a code change alone moves freshness_key" "$(field "$j" freshness_key)" "$base_fk"
again="$(freshness)"
assert_eq "8: freshness_key is stable across two calls on an unchanged tree" "$(field "$again" freshness_key)" "$(field "$j" freshness_key)"
printf 'code\n' > "$WORK/fr/seed.txt"

# --- 9-11: a missing artifact makes the key null (fail-closed), never a partial digest ---
mv "$WORK/plans/$SID-detail.md" "$WORK/plans/$SID-detail.bak"
j="$(freshness)"
assert_eq "9: a missing detail.md yields artifact_keys.detail = null" "$(field "$j" artifact_keys.detail)" "null"
assert_eq "10: a null component collapses freshness_key to null" "$(field "$j" freshness_key)" "null"
ak_missing="$(fp computeArtifactKey "$PLANS" ", '$SID', ['detail']")"
assert_eq "11: computeArtifactKey returns null for a missing artifact" "$ak_missing" "null"
mv "$WORK/plans/$SID-detail.bak" "$WORK/plans/$SID-detail.md"

# --- 12-13: an unresolvable code side also collapses the key ---
plain="$WORK/notarepo"
mkdir -p "$plain"
if command -v cygpath >/dev/null 2>&1; then plain_node="$(cygpath -m "$plain")"; else plain_node="$plain"; fi
j="$(fp computeFreshnessKey "$plain_node" ", '$PLANS', '$SID'")"
assert_eq "12: a non-repo cwd yields input_version = null" "$(field "$j" input_version)" "null"
assert_eq "13: a null input_version collapses freshness_key to null" "$(field "$j" freshness_key)" "null"

# --- 14-18: TR-wise sub-check independence (S6-b) ---
# TR1 settles intent-internal against the intent-only artifact key; adding outline.md must
# leave intent-outline unsettled even though no code changed.
SID2="indep"
printf '# intent\nI1\n' > "$WORK/plans/$SID2-intent.md"
k_intent="$(fp computeArtifactKey "$PLANS" ", '$SID2', ['intent']")"
assert_match "14: the intent-only artifact key is computable on its own" "$k_intent" '^[0-9a-f]{64}$'

sid="indep-$$"
seed_js="$WORK/indep.js"
{
    printf '%s\n' "const writer = require('$WRITER_NODE');"
    printf '%s\n' "const schema = require('$SCHEMA_NODE');"
    printf '%s\n' "const fs = require('fs');"
    printf '%s\n' "const st = schema.createEmptyState('$sid');"
    printf '%s\n' "st.audit.ledger = [{ id: 'run-0001', outcome: 'terminal', verdict: 'CONTINUE', tr_ids: ['TR1'], sub_checks: ['intent-internal'], input_key: { 'intent-internal': '$k_intent' } }];"
    printf '%s\n' "st.audit.last_terminal_run_id = 'run-0001';"
    printf '%s\n' "fs.writeFileSync(writer.getStatePath('$sid'), JSON.stringify(st));"
} > "$seed_js"
bash "$RWT" 30 node "$seed_js" >/dev/null 2>&1

printf '# outline\nO1\n' > "$WORK/plans/$SID2-outline.md"
k_io="$(fp computeArtifactKey "$PLANS" ", '$SID2', ['intent', 'outline']")"
q_js="$WORK/indepq.js"
{
    printf '%s\n' "const writer = require('$WRITER_NODE');"
    printf '%s\n' "const ledger = require('$LEDGER_NODE');"
    printf '%s\n' "const a = writer.readState('$sid').audit;"
    printf '%s\n' "process.stdout.write([ledger.isSubCheckSettled(a, 'intent-internal', '$k_intent'), ledger.isSubCheckSettled(a, 'intent-outline', '$k_io'), ledger.isSubCheckSettled(a, 'outline-detail', '$k_io')].join('|'));"
} > "$q_js"
q="$(bash "$RWT" 30 node "$q_js" 2>&1)"
assert_match "15: the TR1 sub-check stays settled" "$q" '^true\|'
assert_ne "16: the intent+outline key differs from the intent-only key" "$k_io" "$k_intent"
assert_match "17: a settled TR1 does not settle TR2's intent-outline" "$q" '^true\|false\|'
assert_match "18: a settled TR1 does not settle TR3's outline-detail" "$q" '\|false$'

# --- 19-20: a detail.md edit moves only the TR3 key ---
printf '# detail\nD1\n' > "$WORK/plans/$SID2-detail.md"
k_od1="$(fp computeArtifactKey "$PLANS" ", '$SID2', ['outline', 'detail']")"
printf '# detail\nD2\n' > "$WORK/plans/$SID2-detail.md"
k_od2="$(fp computeArtifactKey "$PLANS" ", '$SID2', ['outline', 'detail']")"
k_io2="$(fp computeArtifactKey "$PLANS" ", '$SID2', ['intent', 'outline']")"
assert_ne "19: a detail.md edit moves the outline-detail key" "$k_od1" "$k_od2"
assert_eq "20: a detail.md edit leaves the intent-outline key untouched" "$k_io2" "$k_io"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
