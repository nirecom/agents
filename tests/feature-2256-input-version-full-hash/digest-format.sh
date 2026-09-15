#!/usr/bin/env bash
# tests/feature-2256-input-version-full-hash/digest-format.sh
# Tests: hooks/lib/diff-fingerprint.js
# Tags: supervisor, input-version, sha256, digest-length, TL2, scope:issue-specific
# #2256 round-2 C4: every digest is a full 64-hex sha256, never truncated and never sha1.
# Parent: tests/feature-2256-input-version-full-hash.sh

set -uo pipefail
# shellcheck source=./_common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

repo="$(mk_repo r1)"
mkdir -p "$WORK/plans"
printf '# intent\nalpha\n' > "$WORK/plans/sess-a-intent.md"
printf '# outline\nbeta\n' > "$WORK/plans/sess-a-outline.md"
printf '# detail\ngamma\n' > "$WORK/plans/sess-a-detail.md"
printf 'changed\n' > "$WORK/r1/seed.txt"

HEX64='^[0-9a-f]{64}$'

# --- 1-3: all three exports return a full 64-hex digest ---
iv="$(fp computeInputVersion "$repo")"
assert_match "1: computeInputVersion returns a 64-hex sha256" "$iv" "$HEX64"

ak="$(fp computeArtifactKey "$WORK_NODE/plans" ", 'sess-a', ['intent', 'outline', 'detail']")"
assert_match "2: computeArtifactKey returns a 64-hex sha256" "$ak" "$HEX64"

fk_json="$(fp computeFreshnessKey "$repo" ", '$WORK_NODE/plans', 'sess-a'")"
fk="$(printf '%s' "$fk_json" | node -e "let s='';process.stdin.on('data',(d)=>s+=d).on('end',()=>{try{process.stdout.write(String(JSON.parse(s).freshness_key));}catch(e){process.stdout.write('PARSE-ERROR');}})" 2>&1)"
assert_match "3: computeFreshnessKey.freshness_key is a 64-hex sha256" "$fk" "$HEX64"

# --- 4-6: the composite result carries the three artifact keys and the input version ---
assert_match "4: computeFreshnessKey reports input_version" "$fk_json" '"input_version":"[0-9a-f]{64}"'
assert_match "5: computeFreshnessKey reports artifact_keys for intent/outline/detail" "$fk_json" '"artifact_keys":\{[^}]*"intent"[^}]*"outline"[^}]*"detail"'
assert_match "6: each artifact key is itself 64 hex characters" "$fk_json" '"detail":"[0-9a-f]{64}"'

# --- 7-8: the same tree and the same artifacts produce the same keys twice ---
iv2="$(fp computeInputVersion "$repo")"
assert_eq "7: computeInputVersion is stable for an unchanged tree" "$iv2" "$iv"
ak2="$(fp computeArtifactKey "$WORK_NODE/plans" ", 'sess-a', ['intent', 'outline', 'detail']")"
assert_eq "8: computeArtifactKey is stable for unchanged artifacts" "$ak2" "$ak"

# --- 9: the artifact key equals an independently computed sha256 (algorithm pin) ---
ref="$(node -e "
const crypto = require('crypto');
const fs = require('fs');
const h = crypto.createHash('sha256');
for (const n of ['intent', 'outline', 'detail']) {
  h.update(n); h.update('\0');
  h.update(fs.readFileSync('$WORK_NODE/plans/sess-a-' + n + '.md'));
  h.update('\0');
}
process.stdout.write(h.digest('hex'));
" 2>&1)"
if [ "$ak" = "$ref" ]; then
    pass "9: computeArtifactKey equals an independent sha256 over the artifact contents"
else
    fail "9: computeArtifactKey equals an independent sha256 over the artifact contents" \
        "module='$ak' independent='$ref' — differing composition or a non-sha256 algorithm"
fi

# --- 10-11: source-level pin against a truncation or sha1 regression ---
if grep -n "createHash('sha256')" "$AGENTS_DIR/hooks/lib/diff-fingerprint.js" >/dev/null 2>&1; then
    if grep -nE "digest\('hex'\)\s*\.slice\(|digest\('hex'\)\.substring\(|digest\('hex'\)\.substr\(" \
        "$AGENTS_DIR/hooks/lib/diff-fingerprint.js" >/dev/null 2>&1; then
        fail "10: no digest in diff-fingerprint.js is truncated" "a .slice/.substring follows digest('hex')"
    else
        pass "10: no digest in diff-fingerprint.js is truncated"
    fi
    if grep -n "sha1" "$AGENTS_DIR/hooks/lib/diff-fingerprint.js" >/dev/null 2>&1; then
        fail "11: diff-fingerprint.js never uses sha1" "a sha1 reference is present"
    else
        pass "11: diff-fingerprint.js never uses sha1"
    fi
else
    fail "10: no digest in diff-fingerprint.js is truncated" "hooks/lib/diff-fingerprint.js has no sha256 hash"
    fail "11: diff-fingerprint.js never uses sha1" "hooks/lib/diff-fingerprint.js has no sha256 hash"
fi

# --- 12-13: the key stored in the ledger and the key compared against are both 64 chars ---
sid="ivfmt-$$"
stored="$(node -e "
const writer = require('$AGENTS_NODE/hooks/lib/supervisor-state-writer.js');
const schema = require('$AGENTS_NODE/hooks/lib/supervisor-state-schema.js');
const ledgerMod = require('$AGENTS_NODE/hooks/lib/audit-ledger.js');
const fs = require('fs');
const st = schema.createEmptyState('$sid');
st.audit.ledger = [{ id: 'run-0001', outcome: 'terminal', verdict: 'CONTINUE', freshness_key: '$fk' }];
st.audit.last_terminal_run_id = 'run-0001';
fs.writeFileSync(writer.getStatePath('$sid'), JSON.stringify(st));
const a = writer.readState('$sid').audit;
const e = ledgerMod.lastTerminalRun(a);
process.stdout.write(String((e && e.freshness_key || '').length) + '|' + String(ledgerMod.isRunFresh(e, '$fk')));
" 2>&1)"
assert_match "12: the freshness_key persisted in the ledger is 64 characters" "$stored" '^64\|'
assert_match "13: the freshly computed key compares equal to the stored one" "$stored" '\|true$'

# --- 14: a truncated key must NOT match a full key (no prefix rescue) ---
short="$(printf '%s' "$fk" | cut -c1-12)"
res="$(node -e "
const ledgerMod = require('$AGENTS_NODE/hooks/lib/audit-ledger.js');
process.stdout.write(String(ledgerMod.isRunFresh({ freshness_key: '$short' }, '$fk')));
" 2>&1)"
assert_eq "14: a legacy 12-char key never matches a 64-char key" "$res" "false"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
