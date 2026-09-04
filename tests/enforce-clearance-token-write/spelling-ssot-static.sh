#!/usr/bin/env bash
# tests/enforce-clearance-token-write/spelling-ssot-static.sh
# Tests: hooks/lib/off-clearance-invocation.js, hooks/block-clearance-token-write/dispatch.js, hooks/supervisor-off-proposal-shim.js, skills/enforce-workflow-off/SKILL.md
# Tags: anti-cheat, off-clearance, clearance-token, ssot, spelling, multi-defense, behavioural, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap: a real turn printing the invitation and a user running it; see
# tests/TL3-hook-clearance-token-write.sh, gap-checked by bin/check-verification-gate.sh.
# #1821 multi-defense — the block message INVITES a command, so a bare-substring mention
# gate over that spelling makes the hook refuse what it just told the user to run. S0-S3:
# one SSOT owns the spelling, S0b its bytes. S4: the VALUE survives narrowing. S1b (derived
# over every exported *_BLOCK_MSG) / S2b / S5: the messages actually EMITTED carry that
# value and pass the classifier. Sibling naming: <topic>-cases.sh, not <area>-<issue>-.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
SHIM="$AGENTS_DIR/hooks/supervisor-off-proposal-shim.js"
SSOT_REL="hooks/lib/off-clearance-invocation.js"
SSOT_ABS="$AGENTS_DIR/$SSOT_REL"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'ssotspell'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# assert_requires <label> <repo-relative file> — a bare grep for the module name passes on
# a comment alone, which is the false-green this replaces: require the actual import.
assert_requires() {
    local label="$1" rel="$2" abs="$AGENTS_DIR/$2"
    if [ ! -f "$abs" ]; then fail "$label: $rel does not exist"; return; fi
    if grep -qE "require\(.*off-clearance-invocation" "$abs" 2>/dev/null; then
        pass "$label: $rel require()s the SSOT module"
    else
        fail "$label: $rel does not require() hooks/lib/off-clearance-invocation.js"
    fi
}

echo "=== S: the OFF-clearance invitation has exactly one owner ==="

# Everything below compares against THIS string, so a missing module must be a loud
# failure rather than an empty needle that every grep would then match for free.
SSOT_VALUE=""
if [ -f "$SSOT_ABS" ]; then
    SSOT_VALUE="$("$RWT" 10 node -e "const m=require(process.argv[1]+'/hooks/lib/off-clearance-invocation.js');process.stdout.write(String(m.OFF_CLEARANCE_INVOCATION||''))" "$_AGENTS_DIR_NODE" 2>/dev/null)"
fi
if [ -n "$SSOT_VALUE" ]; then
    pass "S0 $SSOT_REL exports OFF_CLEARANCE_INVOCATION ($SSOT_VALUE)"
else
    fail "S0 $SSOT_REL does not export a non-empty OFF_CLEARANCE_INVOCATION — S1-S4 below cannot be meaningful"
fi

# S0b — a DELIBERATE change-detector, and the only assertion here that pins bytes.
# S0 (non-empty), S1b/S2b/S3 (substring containment) and S4 (a negative pattern) are all
# satisfied by a value that drifted but still contains the needle — and #1821 IS the story
# of an advertised invocation drifting away from what actually works. The exact bytes are
# the contract, so they are written out once, here.
# WHEN THE CONSTANT LEGITIMATELY CHANGES: update S0B_EXPECTED to the new value in the same
# commit as hooks/lib/off-clearance-invocation.js, and re-check S4 (the new spelling must
# still not arm a bare mention gate) and the wrapper cases in wrapper-equivalence-cases.sh
# (the new spelling must still name a program that exists and IS the minter).
S0B_EXPECTED='bash "$AGENTS_CONFIG_DIR/bin/request-off-mode-clearance"'
if [ "$SSOT_VALUE" = "$S0B_EXPECTED" ]; then
    pass "S0b OFF_CLEARANCE_INVOCATION is byte-for-byte the advertised invocation"
else
    fail "S0b OFF_CLEARANCE_INVOCATION drifted: got '$SSOT_VALUE', want '$S0B_EXPECTED'"
fi

assert_requires "S1 dispatch.js reads the SSOT" "hooks/block-clearance-token-write/dispatch.js"
assert_requires "S2 supervisor-off-proposal-shim.js reads the SSOT" "hooks/supervisor-off-proposal-shim.js"

# --------------------------------------------------------------------------
# S1b / S2b — BEHAVIOURAL. S1/S2 only prove a wire exists; they cannot tell a
# used import from a dead one. These two drive the real emitters and assert the
# two properties that actually matter, on the text a user will actually read:
# it carries the SSOT spelling, and running it back through the classifier is
# NOT blocked. A guard whose own remediation text trips it is the #1821 bug.
# --------------------------------------------------------------------------
# hits_protected <cwd> <text> -> the classifier's verdict for that text ("null" when clear)
hits_protected() {
    "$RWT" 12 node -e "const {bashHitsProtected}=require(process.argv[1]+'/hooks/block-clearance-token-write/bash-scan.js');process.stdout.write(String(bashHitsProtected(process.argv[2],{cwd:process.argv[3]})))" \
        "$_AGENTS_DIR_NODE" "$2" "$1" 2>/dev/null
}

# consume_kv <node output> — reads the OK|/NG| protocol the derived blocks below emit,
# so a node crash surfaces as a missing DONE| rather than as a vacuous green.
consume_kv() {
    local label="$1" out="$2" done_seen=no line
    while IFS= read -r line; do
        case "$line" in
            OK\|*)   pass "${line#OK|}" ;;
            NG\|*)   fail "${line#NG|}" ;;
            DONE\|*) done_seen=yes ;;
            "")      ;;
            *)       echo "  (node stderr: $line)" ;;
        esac
    done <<< "$out"
    [ "$done_seen" = "yes" ] && pass "$label ran to completion" \
        || fail "$label did NOT complete (node crashed or timed out); output=$out"
}

# Fixture isolation (rules/test/fixture-isolation.md): the workflow dir and the plans dir
# are dual-pinned and EXPORTED so every child node below reads the fixture instead of the
# developer's live workflow dir, and the inherited session ids are dropped. The cwd handed
# to the classifier is a SIBLING of the workflow dir, never the workflow dir itself — a
# real paste of the block message happens from the project directory, and making the two
# coincide resolves the message's own relative `bin/...` fragment into the workflow dir
# and blocks for a reason #1821 is not about.
TMP=$(make_tmp)
mkdir -p "$TMP/wf/plans" "$TMP/proj" 2>/dev/null || true
TN=$(node_path "$TMP/proj"); WFN=$(node_path "$TMP/wf")
export CLAUDE_WORKFLOW_DIR="$WFN"
export WORKFLOW_PLANS_DIR="$WFN/plans"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

echo ""
echo "=== S1b: EVERY block message dispatch.js can emit ==="
# Derived over the exported *_BLOCK_MSG constants rather than naming one (CPR-E2C): a
# fourth message added later is covered automatically. Two properties per message.
# (a) SSOT: a message that ADVERTISES the minter must quote the invitation verbatim.
# Membership is decided by the "request-off" stem, shared by the current and the
# pre-#1821 spelling, so a copy that drifted BACK to the old name is still recognized as
# advertising it and fails (a) rather than silently exempting itself. MARKER_BLOCK_MSG
# advertises the sentinels instead and is exempt by that derivation.
# (b) CLASSIFIER: no message may be blocked by the guard it belongs to — the #1821 defect
# itself. The blockMessageFor() composites are folded in: UNPARSED_PREFIX + a message is
# what a user reads on the unparsed route, and the prefix could reintroduce a mention.
S1B_OUT="$("$RWT" 30 node -e '
const A = process.argv[1], cwd = process.argv[2];
const d = require(A + "/hooks/block-clearance-token-write/dispatch.js");
const { bashHitsProtected } = require(A + "/hooks/block-clearance-token-write/bash-scan.js");
const { OFF_CLEARANCE_INVOCATION } = require(A + "/hooks/lib/off-clearance-invocation.js");
const out = (s) => process.stdout.write(s + "\n");
const names = Object.keys(d).filter((k) => /_BLOCK_MSG$/.test(k));
if (names.length < 3) out("NG|S1b dispatch.js exports " + names.length + " *_BLOCK_MSG constant(s); its own comment declares at least three");
const entries = names.map((n) => [n, d[n]]);
for (const kind of ["unparsed-token", "unparsed-marker"]) entries.push(["blockMessageFor(" + kind + ")", d.blockMessageFor(kind)]);
let quoting = 0;
for (const [name, msg] of entries) {
  if (typeof msg !== "string" || msg === "") { out("NG|S1b " + name + " is not a non-empty string"); continue; }
  if (msg.includes("request-off")) {
    if (msg.includes(OFF_CLEARANCE_INVOCATION)) { quoting++; out("OK|S1b-ssot " + name + " quotes the SSOT invitation verbatim"); }
    else out("NG|S1b-ssot " + name + " advertises the minter but has drifted from the SSOT spelling " + JSON.stringify(OFF_CLEARANCE_INVOCATION));
  } else {
    out("OK|S1b-ssot " + name + " does not advertise the minter, so the SSOT quote does not apply");
  }
  const v = String(bashHitsProtected(msg, { cwd }));
  if (v === "null") out("OK|S1b-clf " + name + " is not itself blocked by the classifier");
  else out("NG|S1b-clf " + name + " is blocked by the guard it belongs to (bashHitsProtected -> " + v + ")");
}
if (quoting >= 3) out("OK|S1b-ssot " + quoting + " emitted messages quote the SSOT invitation");
else out("NG|S1b-ssot only " + quoting + " emitted message(s) quote the SSOT invitation; dispatch.js declares at least three");
out("DONE|");
' "$_AGENTS_DIR_NODE" "$TN" 2>&1)"
consume_kv "S1b-run the derived block-message matrix" "$S1B_OUT"

echo ""
echo "=== S2b: the block message supervisor-off-proposal-shim.js actually emits ==="
# CLEARANCE_GUIDANCE is a function-local const, so the only way to observe it is to drive
# the shim end to end: a genuine OFF sentinel with no clearance token blocks with rc=2.
SHIM_TMP=$(make_tmp); SHIM_TN=$(node_path "$SHIM_TMP")
OFF_CMD='echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: [workflow-bug] cannot proceed>>"'
SHIM_IN="$("$RWT" 8 node -e "process.stdout.write(JSON.stringify({tool_name:'Bash',session_id:'s2bsid',tool_input:{command:process.argv[1]}}))" "$OFF_CMD")"
SHIM_OUT="$(WORKFLOW_PLANS_DIR="$SHIM_TN" CLAUDE_WORKFLOW_DIR="$SHIM_TN" AGENTS_CONFIG_DIR="$SHIM_TN" "$RWT" 15 node "$SHIM" <<< "$SHIM_IN" 2>/dev/null)"
SHIM_RC=$?
SHIM_REASON="$("$RWT" 8 node -e "let o={};try{o=JSON.parse(process.argv[1]);}catch(e){}process.stdout.write(String(o.reason||''))" "$SHIM_OUT" 2>/dev/null)"
if [ "$SHIM_RC" != "2" ] || [ -z "$SHIM_REASON" ]; then
    fail "S2b precondition: a genuine OFF emit without a token must block with rc=2 (got rc=$SHIM_RC out='$(printf '%.160s' "$SHIM_OUT")')"
elif [ -z "$SSOT_VALUE" ]; then
    fail "S2b skipped-as-failure: no SSOT value to look for inside the shim's block reason"
elif ! printf '%s' "$SHIM_REASON" | grep -qF -- "$SSOT_VALUE"; then
    fail "S2b the shim's block reason does not carry the SSOT invitation '$SSOT_VALUE'"
else
    pass "S2b the shim's emitted block reason carries the SSOT invitation verbatim"
fi
# Symmetric with S1b-clf (CPR-ORTH): both emitters advertise the same command, so both
# messages must survive the classifier — one being safe proves nothing about the other.
if [ -n "$SHIM_REASON" ]; then
    S2B_HIT="$(hits_protected "$TN" "$SHIM_REASON")"
    if [ "$S2B_HIT" = "null" ]; then
        pass "S2b-clf the shim's block reason is not itself blocked by the classifier"
    else
        fail "S2b-clf the shim's own remediation text is blocked (bashHitsProtected -> ${S2B_HIT:-<no output>})"
    fi
else
    fail "S2b-clf skipped-as-failure: the shim produced no reason to classify"
fi
rm -r -f "$SHIM_TMP" 2>/dev/null || true

echo ""
echo "=== S3: SKILL.md has not drifted from the SSOT ==="
# SKILL.md is Markdown and cannot require() the constant, so this comparison against
# the SSOT value is the only protection against one-sided drift.
# A whole-file substring match is a FALSE GREEN here: SKILL.md also names the minter
# proper (bin/request-off-clearance) while describing the category spelling, and that
# unrelated mention keeps a file-wide grep passing even after the SSOT is reverted to
# the old spelling. So S3 first isolates the INVITATION line — the one line that tells
# the reader to run the command through $AGENTS_CONFIG_DIR — and compares only that.
SKILL_MD="$AGENTS_DIR/skills/enforce-workflow-off/SKILL.md"
INVITE_LINE=""
INVITE_N=0
if [ -f "$SKILL_MD" ]; then
    INVITE_LINE="$(grep -E 'AGENTS_CONFIG_DIR[^`]*bin/' "$SKILL_MD" 2>/dev/null | head -n 1)"
    INVITE_N="$(grep -cE 'AGENTS_CONFIG_DIR[^`]*bin/' "$SKILL_MD" 2>/dev/null || echo 0)"
fi
if [ ! -f "$SKILL_MD" ]; then
    fail "S3-line skills/enforce-workflow-off/SKILL.md does not exist"
elif [ "$INVITE_N" != "1" ]; then
    fail "S3-line expected exactly one clearance-invitation line in SKILL.md, found $INVITE_N — the line-scoped comparison below would be ambiguous"
else
    pass "S3-line SKILL.md carries exactly one clearance-invitation line"
fi

if [ -z "$SSOT_VALUE" ]; then
    fail "S3 skipped-as-failure: no SSOT value to compare skills/enforce-workflow-off/SKILL.md against"
elif [ -z "$INVITE_LINE" ]; then
    fail "S3 no clearance-invitation line found in skills/enforce-workflow-off/SKILL.md"
elif printf '%s' "$INVITE_LINE" | grep -qF -- "$SSOT_VALUE"; then
    pass "S3 the SKILL.md invitation line quotes the SSOT invocation verbatim"
else
    fail "S3 the SKILL.md invitation line has drifted from the SSOT '$SSOT_VALUE' (line: $(printf '%.120s' "$INVITE_LINE"))"
fi

echo ""
echo "=== S4: the SSOT value is safe even if the mention gate regresses to a bare match ==="
# Deliberately does NOT import TOKEN_MENTION_RE / suffixesToMentionRe: the pattern is
# rebuilt from character codes so the assertion cannot inherit the narrowing's
# correctness. S4 stays green only while the SPELLING itself is immune.
if [ -n "$SSOT_VALUE" ]; then
    S4_HIT="$("$RWT" 10 node -e "const bare=new RegExp('off'+String.fromCharCode(45)+'clearance','i');process.stdout.write(bare.test(String(process.argv[1]))?'hit':'clear')" "$SSOT_VALUE" 2>/dev/null)"
    if [ "$S4_HIT" = "clear" ]; then
        pass "S4 the SSOT invitation does not arm a bare substring mention gate"
    else
        fail "S4 the SSOT invitation ('$SSOT_VALUE') still matches a bare mention pattern (got: ${S4_HIT:-<none>}) — a regression of the narrowing would make the hook block its own instructions"
    fi
else
    fail "S4 skipped-as-failure: no SSOT value to test against the bare pattern"
fi

echo ""
echo "=== S5: every block-reason branch of the shim carries the same guidance ==="
# S2b drives ONE branch (no-clearance-enoent) end to end and proves the guidance text
# carries the SSOT value and survives the classifier. The remaining branches emit the
# SAME function-local const, so what is left to establish is that each branch actually
# appends it — and buildReason is a closure, not an export, so this reads the source.
# Kinds are DERIVED from the `const blockKind =` selector rather than hand-copied, so a
# seventh kind added there without a guidance-bearing branch reddens here (CPR-SSOT).
# lock-busy is the one deliberate omission: it is transient and re-emitting the same
# sentinel is the remedy, so inviting a clearance request there would be wrong advice.
S5_OUT="$("$RWT" 20 node -e '
const fs = require("fs");
const out = (s) => process.stdout.write(s + "\n");
const src = fs.readFileSync(process.argv[1], "utf8");
const sel = src.match(/const blockKind =[\s\S]*?;\n/);
const fn = src.match(/function buildReason\([\s\S]*?\n    \}\n/);
if (!sel) out("NG|S5 could not locate the `const blockKind =` selector in the shim");
if (!fn) out("NG|S5 could not locate function buildReason() in the shim");
if (sel && fn) {
  const kinds = Array.from(new Set((sel[0].match(/"[a-z-]+"/g) || []).map((s) => s.slice(1, -1))));
  if (kinds.length < 5) out("NG|S5 the selector yielded only " + kinds.length + " kind(s) — the derivation is broken, not the source");
  const body = fn[0];
  for (const kind of kinds) {
    const at = body.indexOf("if (kind === \"" + kind + "\")");
    // No `if` of its own means the kind lands on the trailing fallback return.
    const branch = at === -1
      ? body.slice(body.lastIndexOf("}\n      return "))
      : body.slice(at, (() => { const n = body.indexOf("if (kind === \"", at + 10); return n === -1 ? body.length : n; })());
    const has = branch.includes("CLEARANCE_GUIDANCE");
    const want = kind !== "lock-busy";
    const where = at === -1 ? "fallback" : "own branch";
    if (has === want) out("OK|S5 " + kind + " (" + where + ") " + (want ? "appends" : "deliberately omits") + " CLEARANCE_GUIDANCE");
    else out("NG|S5 " + kind + " (" + where + ") " + (want ? "does NOT append" : "unexpectedly appends") + " CLEARANCE_GUIDANCE");
  }
}
out("DONE|");
' "$SHIM" 2>&1)"
consume_kv "S5-run the shim block-reason branch matrix" "$S5_OUT"

rm -r -f "$TMP" 2>/dev/null || true

# E0/E1 (wrapper vs minter execution equivalence) moved to the sibling
# wrapper-equivalence-cases.sh: it sources tests/lib/request-off-clearance-harness.sh,
# whose own PASS/FAIL counters would otherwise reset this file's.

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
