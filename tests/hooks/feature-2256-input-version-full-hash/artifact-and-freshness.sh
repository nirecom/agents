#!/usr/bin/env bash
# tests/hooks/feature-2256-input-version-full-hash/artifact-and-freshness.sh
# Tests: hooks/lib/diff-fingerprint.js, hooks/lib/audit-ledger.js
# Tags: supervisor, artifact-key, freshness-key, sub-check-independence, TL2, scope:issue-specific, unreadable-artifact, dangling-symlink
# #2256 C1 + S6-b: the freshness key composes code and plan artifacts, and a settled TR1
# must never no-op TR2/TR3. Parent: tests/hooks/feature-2256-input-version-full-hash.sh

set -uo pipefail
# Harness first (per-case markers only); _common.sh then overrides its reporters.
# shellcheck source=../../lib/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/harness.sh"
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
    printf '%s\n' "fs.writeFileSync(writer.getStatePath('$sid', { forWrite: true }), JSON.stringify(st));"
} > "$seed_js"
bash "$RWT" 30 node "$seed_js" >/dev/null 2>&1 || fail "14-18 seed: supervisor-state seed write failed"

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

# --- 21-27 (#2400 D3): an unreadable artifact is not an absent one ---
DETAIL="$WORK/plans/$SID-detail.md"
NOX="$WORK/plans-nox"
trap 'chmod 755 "$NOX" 2>/dev/null; chmod 644 "$DETAIL" 2>/dev/null; rm -rf "$WORK"' EXIT
case_begin "directory-artifact-is-unreadable" "hooks/lib/diff-fingerprint.js"
mv "$DETAIL" "$WORK/plans/$SID-detail.bak"
mkdir "$DETAIL"
j="$(freshness)"
assert_eq "21: a directory in place of detail.md collapses artifact_keys to null" "$(field "$j" artifact_keys)" "null"
assert_eq "22: it collapses freshness_key to null" "$(field "$j" freshness_key)" "null"
assert_eq "23: it lists detail in unreadable_artifacts" "$(field "$j" unreadable_artifacts)" "detail"
assert_eq "24: computeArtifactKey keeps its single-key null contract" "$(fp computeArtifactKey "$PLANS" ", '$SID', ['detail']")" "null"
rmdir "$DETAIL"
j="$(freshness)"
assert_eq "25: an absent detail.md lists nothing as unreadable" "$(field "$j" unreadable_artifacts)" "undefined"
assert_eq "25b: an absent detail.md is still a null value in artifact_keys" "$(field "$j" artifact_keys.detail)" "null"
mv "$WORK/plans/$SID-detail.bak" "$DETAIL"
case_end

case_begin "permission-denied-read-is-unreadable" "hooks/lib/diff-fingerprint.js"
chmod 000 "$DETAIL"
if [[ -r "$DETAIL" ]]; then
    skip "26: chmod 000 does not revoke read here (stubbed by 29-30)"
else
    assert_eq "26: a read-denied detail.md is listed as unreadable" "$(field "$(freshness)" unreadable_artifacts)" "detail"
fi
chmod 644 "$DETAIL"
case_end

case_begin "parent-dir-stat-denied-is-unreadable" "hooks/lib/diff-fingerprint.js"
mkdir -p "$NOX"
cp "$WORK/plans/$SID-intent.md" "$WORK/plans/$SID-outline.md" "$DETAIL" "$NOX/"
chmod a-x "$NOX"
if [[ -e "$NOX/$SID-detail.md" ]]; then
    skip "27: parent-dir search permission not enforced here (stubbed by 28)"
else
    j="$(fp computeFreshnessKey "$repo" ", '$WORK_NODE/plans-nox', '$SID'")"
    assert_eq "27: a stat EACCES lists every artifact as unreadable" "$(field "$j" unreadable_artifacts)" "intent,outline,detail"
    assert_eq "27b: a stat EACCES collapses artifact_keys to null" "$(field "$j" artifact_keys)" "null"
fi
chmod 755 "$NOX"
rm -rf "$NOX"
case_end

# --- 28-34: stubbed fs errors run on every platform; the stub hits only <SID>-detail.md ---
# argv: <code> <stat|open> [<lstat code>|real] — lstatSync passes through unless a code is given.
stub_js="$WORK/stub-fs.js"
{
    printf '%s\n' "const fs = require('fs');"
    printf '%s\n' "const [code, mode, lstat = 'real'] = process.argv.slice(2);"
    printf '%s\n' "const hit = (p) => require('path').basename(String(p)) === '$SID-detail.md';"
    printf '%s\n' "const stub = (name, c) => { const orig = fs[name]; fs[name] = function (p, ...rest) { if (hit(p)) { const e = new Error(c + ': stub'); e.code = c; throw e; } return orig.call(this, p, ...rest); }; };"
    printf '%s\n' "stub(mode === 'stat' ? 'statSync' : 'openSync', code);"
    printf '%s\n' "if (lstat !== 'real') stub('lstatSync', lstat);"
    printf '%s\n' "process.stdout.write(JSON.stringify(require('$FP_NODE').computeFreshnessKey('$repo', '$PLANS', '$SID')));"
} > "$stub_js"
stubbed() { bash "$RWT" 60 node "$stub_js" "$@" 2>&1; }

case_begin "stat-error-codes-are-unreadable" "hooks/lib/diff-fingerprint.js"
for code in EACCES EPERM ELOOP; do
    j="$(stubbed "$code" stat)"
    assert_eq "28: a stat $code lists detail in unreadable_artifacts" "$(field "$j" unreadable_artifacts)" "detail"
    assert_eq "28b: a stat $code collapses artifact_keys to null" "$(field "$j" artifact_keys)" "null"
    assert_eq "28c: a stat $code collapses freshness_key to null" "$(field "$j" freshness_key)" "null"
done
case_end

case_begin "read-failure-after-stat-is-unreadable" "hooks/lib/diff-fingerprint.js"
j="$(stubbed EACCES open)"
assert_eq "29: an open EACCES after a good stat lists detail as unreadable" "$(field "$j" unreadable_artifacts)" "detail"
assert_eq "30: an open EACCES collapses artifact_keys to null" "$(field "$j" artifact_keys)" "null"
case_end

case_begin "enotdir-is-absent" "hooks/lib/diff-fingerprint.js"
for code in ENOENT ENOTDIR; do
    j="$(stubbed "$code" stat "$code")"
    assert_eq "31: a stat $code lists nothing as unreadable" "$(field "$j" unreadable_artifacts)" "undefined"
    assert_eq "31b: a stat $code is an absent (null) detail key" "$(field "$j" artifact_keys.detail)" "null"
    assert_match "31c: a stat $code leaves the outline key computed" "$(field "$j" artifact_keys.outline)" '^[0-9a-f]{64}$'
done
assert_eq "31d: a stat ENOENT with an lstat ENOTDIR is still absent" "$(field "$(stubbed ENOENT stat ENOTDIR)" unreadable_artifacts)" "undefined"
printf 'not a dir\n' > "$WORK/plans-file"
j="$(fp computeFreshnessKey "$repo" ", '$WORK_NODE/plans-file', '$SID'")"
assert_eq "32: a regular file as the parent component is absent, not unreadable" "$(field "$j" unreadable_artifacts)" "undefined"
assert_eq "32b: it yields artifact_keys.detail = null" "$(field "$j" artifact_keys.detail)" "null"
rm -f "$WORK/plans-file"
case_end

# --- 33-34 (#2400 S21): stat ENOENT is absent only when lstat agrees nothing is there ---
case_begin "dangling-symlink-is-unreadable" "hooks/lib/diff-fingerprint.js"
mv "$DETAIL" "$WORK/plans/$SID-detail.bak"
MSYS=winsymlinks:nativestrict ln -s "$WORK/plans/no-such-target.md" "$DETAIL" 2>/dev/null
node_link="$(node -e "const fs = require('fs'); const p = process.argv[1]; try { process.stdout.write(String(fs.lstatSync(p).isSymbolicLink() && !fs.existsSync(p))); } catch (e) { process.stdout.write('false'); }" "$WORK_NODE/plans/$SID-detail.md" 2>&1)"
if [[ ! -L "$DETAIL" || -e "$DETAIL" || "$node_link" != "true" ]]; then
    skip "33: no real dangling symlink here (ln -s needs Developer Mode/symlink privilege; stubbed by 34)"
else
    j="$(freshness)"
    assert_eq "33: a dangling-symlink detail.md lists detail in unreadable_artifacts" "$(field "$j" unreadable_artifacts)" "detail"
    assert_eq "33b: it collapses artifact_keys to null" "$(field "$j" artifact_keys)" "null"
    assert_eq "33c: it collapses freshness_key to null" "$(field "$j" freshness_key)" "null"
    assert_eq "33d: computeArtifactKey returns null for it" "$(fp computeArtifactKey "$PLANS" ", '$SID', ['detail']")" "null"
fi
rm -f "$DETAIL"
case_end

case_begin "absent-stays-absent-after-lstat" "hooks/lib/diff-fingerprint.js"
j="$(freshness)"
assert_eq "33e: a truly absent detail.md (no link) lists nothing as unreadable" "$(field "$j" unreadable_artifacts)" "undefined"
assert_eq "33f: it is still a null value in artifact_keys" "$(field "$j" artifact_keys.detail)" "null"
mv "$WORK/plans/$SID-detail.bak" "$DETAIL"
case_end

case_begin "stat-enoent-lstat-present-is-unreadable" "hooks/lib/diff-fingerprint.js"
for code in ENOENT ENOTDIR; do
    j="$(stubbed "$code" stat real)"
    assert_eq "34: a stat $code with a present lstat lists detail as unreadable" "$(field "$j" unreadable_artifacts)" "detail"
    assert_eq "34b: it collapses artifact_keys to null" "$(field "$j" artifact_keys)" "null"
    assert_eq "34c: it collapses freshness_key to null" "$(field "$j" freshness_key)" "null"
done
case_end

case_begin "stat-enoent-lstat-error-is-unreadable" "hooks/lib/diff-fingerprint.js"
j="$(stubbed ENOENT stat EACCES)"
assert_eq "34d: a stat ENOENT with an lstat EACCES lists detail as unreadable" "$(field "$j" unreadable_artifacts)" "detail"
assert_eq "34e: it collapses freshness_key to null" "$(field "$j" freshness_key)" "null"
case_end

# --- 35 (#2400 C1): an absent artifact never hides an unreadable one, in either order ---
case_begin "absent-outline-plus-unreadable-detail" "hooks/lib/diff-fingerprint.js"
OUTLINE="$WORK/plans/$SID-outline.md"
mv "$OUTLINE" "$WORK/plans/$SID-outline.bak"
mv "$DETAIL" "$WORK/plans/$SID-detail.bak"
mkdir "$DETAIL"
j="$(freshness)"
assert_eq "35: absent outline + unreadable detail lists only detail as unreadable" "$(field "$j" unreadable_artifacts)" "detail"
assert_eq "35b: unreadable wins over absent: artifact_keys collapses to null" "$(field "$j" artifact_keys)" "null"
assert_eq "35c: it collapses freshness_key to null" "$(field "$j" freshness_key)" "null"
rmdir "$DETAIL"
mkdir "$OUTLINE"
j="$(freshness)"
assert_eq "35d: unreadable outline + absent detail lists only outline as unreadable" "$(field "$j" unreadable_artifacts)" "outline"
assert_eq "35e: it collapses artifact_keys to null" "$(field "$j" artifact_keys)" "null"
assert_eq "35f: it collapses freshness_key to null" "$(field "$j" freshness_key)" "null"
rmdir "$OUTLINE"
mv "$WORK/plans/$SID-outline.bak" "$OUTLINE"
mv "$WORK/plans/$SID-detail.bak" "$DETAIL"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
