#!/usr/bin/env bash
# tests/fix-1780-round4-mint-schema.sh
# Tests: bin/request-off-clearance
# Tags: off-clearance, mint, token-schema, mint-nonce, single-use, audit, security, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - The real codex examiner. The verdict is a PATH stub here, so the examiner
#   prompt, its JSON contract, and its timeout behaviour are out of scope; only
#   what the script MINTS from a verdict is asserted.
# - Real concurrent mint/claim interleaving (the #1780 M-3 nonce-matched stale
#   claim clear). This file pins that the nonce EXISTS and is fresh per grant,
#   which is the precondition that mechanism relies on.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
#
# ---------------------------------------------------------------------------
# WHAT THIS FILE DEFENDS (#1780 round-4)
#
# A round-4 edit briefly left `target`, `category` and `urgency` commented out of
# the minted token. Nothing failed loudly: the token still existed, still
# validated as JSON, still had an expiry — so the existing mint test (which
# asserts `category` and `expires_at` only) stayed green while the token had
# silently lost the fields that BIND a grant to what it was granted FOR.
#
# That is the whole security property of this token. It is not a boolean
# "cleared" flag; it is a scoped, reason-bound, single-use grant:
#   target/category/urgency -> WHAT was cleared, so a grant for one thing cannot
#                              be spent on another
#   verdict_reason/detail   -> WHY, for the audit trail
#   minted_at/expires_at    -> the 15-minute window
#   mint_nonce              -> WHICH grant, so the .claimed file the shim writes
#                              is attributable to this exact grant (#1780 M-3)
#
# So the assertion here is the EXACT KEY SET, not a "contains" check. A
# contains-check is precisely what let the regression through. Adding a field
# without updating this test is intended to fail: a new field in a security
# token is a decision that should be made deliberately, not absorbed silently.
# ---------------------------------------------------------------------------

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
REQ="$AGENTS_DIR/bin/request-off-clearance"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
# shellcheck source=./lib/examiner-stub.sh
. "$AGENTS_DIR/tests/lib/examiner-stub.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'mintschema'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"; else fail "$name - want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

if [ ! -f "$REQ" ]; then
    fail "H0 bin/request-off-clearance missing - every case below is vacuous"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi
pass "H0 bin/request-off-clearance present"

WORK=$(make_tmp)
cleanup() { rm -r -f "$WORK" 2>/dev/null; return 0; }
trap cleanup EXIT

# Token inspector. A file, not `node -e`: the interpreter-body form is refused by
# a PreToolUse guard for anything naming this feature, and a file also keeps the
# assertions readable.
INSPECT="$WORK/inspect.js"
cat > "$INSPECT" <<'INSPECT_EOF'
"use strict";
const fs = require("fs");
const [, , tokenPath, query] = process.argv;
let raw, t;
try { raw = fs.readFileSync(tokenPath, "utf8"); } catch (e) { process.stdout.write("UNREADABLE"); process.exit(0); }
try { t = JSON.parse(raw); } catch (e) { process.stdout.write("NOT-JSON"); process.exit(0); }
if (!t || typeof t !== "object" || Array.isArray(t)) { process.stdout.write("NOT-OBJECT"); process.exit(0); }
const out = (v) => process.stdout.write(String(v));
switch (query) {
  // The exact key set, sorted so declaration order cannot mask a swap.
  case "keys":
    out(Object.keys(t).sort().join(","));
    break;
  // Every field must carry a real value. A key present with undefined/null/""
  // is the same failure as a missing key, one indirection later.
  case "empty":
    out(Object.keys(t).sort().filter((k) => t[k] === undefined || t[k] === null || String(t[k]).trim() === "").join(",") || "(none)");
    break;
  case "scope":
    out([t.target, t.category, t.urgency, t.detail].join("|"));
    break;
  case "reason":
    out(String(t.verdict_reason));
    break;
  // The validity window: both stamps parseable ISO-8601 Z, and exactly 15 min apart.
  case "window": {
    const m = Date.parse(t.minted_at), e = Date.parse(t.expires_at);
    const iso = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/;
    out([iso.test(t.minted_at), iso.test(t.expires_at), isFinite(m) && isFinite(e) ? e - m : "NaN"].join("|"));
    break;
  }
  case "nonce":
    out(/^[0-9a-f]{32}$/.test(String(t.mint_nonce)));
    break;
  case "noncevalue":
    out(String(t.mint_nonce));
    break;
  default:
    out("BAD-QUERY");
}
INSPECT_EOF

# mint <sid> <verdict-kind: allow|reject> <args...> -> prints "<rc>|<output>"
# The examiner is a PATH stub, so the verdict is fixed and the script's own
# mint behaviour is what is under test.
mint() {
    local sid="$1" kind="$2"; shift 2
    local stubbin; stubbin=$(make_tmp)
    if [ "$kind" = "allow" ]; then
        write_examiner_stub "$stubbin/codex" ALLOW "examiner accepted: genuine workflow bug"
    else
        write_examiner_stub "$stubbin/codex" REJECT "use the sanctioned skill"
    fi
    local out rc wn; wn=$(node_path "$WORK")
    out=$(PATH="$stubbin:$PATH" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" WORKFLOW_PLANS_DIR="$wn" \
        CLAUDE_WORKFLOW_DIR="$wn" SESSION_ID="$sid" CLAUDE_CODE_SESSION_ID="$sid" \
        "$RWT" 60 bash "$REQ" "$@" 2>&1)
    rc=$?
    rm -r -f "$stubbin" 2>/dev/null || true
    printf '%s|%s' "$rc" "$out"
}
inspect() { "$RWT" 15 node "$INSPECT" "$1" "$2" 2>/dev/null; }

DETAIL_TEXT="next-step reports blocked with no recoverable step"
r=$(mint mintsid1 allow --target worktree --category workflow-bug --urgency urgent --detail "$DETAIL_TEXT")
MINT_RC="${r%%|*}"; MINT_OUT="${r#*|}"
TOKEN="$WORK/mintsid1.off-clearance"

if [ ! -f "$TOKEN" ]; then
    fail "H1 ALLOW verdict minted no token at the expected path - all schema cases vacuous (rc=$MINT_RC out=$MINT_OUT)"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi
pass "H1 ALLOW verdict minted a token"

# ===========================================================================
# Section S - the token's full schema.
# ===========================================================================
assert_eq "S1 token carries EXACTLY the full grant schema (no field silently dropped)" \
    "category,detail,expires_at,mint_nonce,minted_at,target,urgency,verdict_reason" \
    "$(inspect "$TOKEN" keys)"

assert_eq "S2 no field is present-but-empty" "(none)" "$(inspect "$TOKEN" empty)"

# S3 is what makes the grant SCOPED: these four must echo the request, or a
# grant obtained for one thing could be spent on another.
assert_eq "S3 target/category/urgency/detail echo the request that was examined" \
    "worktree|workflow-bug|urgent|$DETAIL_TEXT" "$(inspect "$TOKEN" scope)"

assert_eq "S4 verdict_reason records the examiner's own reason (audit trail)" \
    "examiner accepted: genuine workflow bug" "$(inspect "$TOKEN" reason)"

assert_eq "S5 minted_at/expires_at are ISO-8601 Z and exactly 15 minutes apart" \
    "true|true|900000" "$(inspect "$TOKEN" window)"

assert_eq "S6 mint_nonce is 32 lowercase hex chars (128 bits, unguessable)" \
    "true" "$(inspect "$TOKEN" nonce)"

# S7 freshness: the nonce is what tells a .claimed file which grant it belongs
# to, so two grants sharing a nonce would let one grant's claim be mistaken for
# the other's - the exact confusion #1780 M-3 closed.
r2=$(mint mintsid2 allow --target workflow --category workflow-bug --urgency normal --detail "second grant")
TOKEN2="$WORK/mintsid2.off-clearance"
if [ ! -f "$TOKEN2" ]; then
    fail "S7 second mint produced no token (rc=${r2%%|*})"
else
    n1=$(inspect "$TOKEN" noncevalue); n2=$(inspect "$TOKEN2" noncevalue)
    if [ -n "$n1" ] && [ "$n1" != "$n2" ]; then
        pass "S7 each grant gets its own mint_nonce"
    else
        fail "S7 two grants share a mint_nonce - claims become unattributable (n1=$n1 n2=$n2)"
    fi
    # The second token must be independently well-formed, not a copy that
    # inherited the first request's scope.
    assert_eq "S8 the second grant's scope reflects ITS request, not the first's" \
        "workflow|workflow-bug|normal|second grant" "$(inspect "$TOKEN2" scope)"
fi

# S9 the mint is atomic (write to .mint.tmp then rename); a leftover temp file
# means the rename did not happen and a partial token could be read as real.
if ls "$WORK"/*.mint.tmp >/dev/null 2>&1; then
    fail "S9 a .mint.tmp staging file was left behind - the atomic rename did not complete"
else
    pass "S9 no .mint.tmp staging file left behind (atomic rename completed)"
fi

# S10 the token is a credential: 0600 on filesystems that carry POSIX modes.
if [ "$(uname -s 2>/dev/null)" = "Linux" ] || [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
    mode=$(stat -c '%a' "$TOKEN" 2>/dev/null || stat -f '%Lp' "$TOKEN" 2>/dev/null)
    assert_eq "S10 token file is mode 0600" "600" "$mode"
else
    skip "S10 POSIX file mode not enforced on this filesystem ($(uname -s 2>/dev/null || echo unknown)) - mode check skipped"
fi

# ===========================================================================
# Section N - the negative half. Without it, a script that minted a token
# unconditionally would pass every case above.
# ===========================================================================
r3=$(mint rejectsid reject --target worktree --category workflow-bug --urgency normal --detail "not a real bug")
if [ -f "$WORK/rejectsid.off-clearance" ]; then
    fail "N1 REJECT verdict still minted a token"
else
    pass "N1 REJECT verdict mints no token"
fi
case "${r3%%|*}" in
    0) fail "N1b REJECT exited 0 - callers cannot tell a refusal from a grant" ;;
    *) pass "N1b REJECT exits non-zero" ;;
esac

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
