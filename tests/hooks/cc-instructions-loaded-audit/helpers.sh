# shellcheck shell=bash
# Tests: hooks/instructions-loaded-audit.js, hooks/lib/instructions-loaded-receipt.js, hooks/lib/rules-policy-reader.js
# Tags: rules-injection, instructions-loaded, fixtures, TL2, scope:common
#
# Fixture tree, environment pinning, and the fire()/read_field() drivers for
# ../cc-instructions-loaded-audit.sh. Assumes AGENTS_DIR, HOOK, pass(), fail(),
# and node_path() are already defined by the dispatcher.

TOKEN='.on-demand-only/never-match'
MARKER='<!-- injection: on-demand-only - auto-injection disabled; the owning skill Reads it explicitly. -->'

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT

REPO="$BASE/repo"
WFDIR="$BASE/workflow"
PLANS="$BASE/plans"
mkdir -p "$REPO/rules" "$REPO/hooks/lib" "$REPO/docs" "$WFDIR" "$PLANS"
git -C "$REPO" init -q
git -C "$REPO" config core.hooksPath /dev/null
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"

# Fixture isolation (rules/test/fixture-isolation.md): dual-pin the pair, drop
# any inherited session id, keep CWD neutral.
export CLAUDE_WORKFLOW_DIR; CLAUDE_WORKFLOW_DIR="$(node_path "$WFDIR")"
export WORKFLOW_PLANS_DIR; WORKFLOW_PLANS_DIR="$(node_path "$PLANS")"
export CLAUDE_PROJECT_DIR; CLAUDE_PROJECT_DIR="$(node_path "$REPO")"
unset CLAUDE_SESSION_ID || true
unset CLAUDE_CODE_SESSION_ID || true

# --- rules fixtures on disk (the verdict is decided from the ON-DISK frontmatter) ---
cat > "$REPO/rules/ok-conditional.md" <<'EOF'
---
paths:
  - "tests/**"
---

# has paths: -> ok
EOF
cat > "$REPO/rules/ok-listed.md" <<'EOF'
# no paths:, but listed in EXPECTED_UNCONDITIONAL -> ok
EOF
cat > "$REPO/rules/missing.md" <<'EOF'
# no paths: and not listed -> S-MISSING
EOF
cat > "$REPO/rules/malformed.md" <<'EOF'
---
paths: [ "tests/**"
---

# frontmatter block present but paths: unparseable -> S-MALFORMED
EOF
cat > "$REPO/rules/leak.md" <<EOF
---
paths:
  - "$TOKEN"
---
$MARKER

# reserved glob on disk, yet the hook fired -> S-LEAK
EOF
cat > "$REPO/docs/not-a-rule.md" <<'EOF'
# outside rules/**/*.md -> ok regardless of frontmatter
EOF

cat > "$REPO/hooks/lib/rules-injection-policy.js" <<POLICY_EOF
"use strict";
const ON_DEMAND_TOKEN = "$TOKEN";
const ON_DEMAND_MARKER_RE = /<!--\s*injection:\s*on-demand-only\b/;
const ON_DEMAND_READERS = ["rules/leak.md|skills/leak-owner/SKILL.md"];
const EXPECTED_UNCONDITIONAL = ["rules/ok-listed.md"];
module.exports = { ON_DEMAND_TOKEN, ON_DEMAND_MARKER_RE, ON_DEMAND_READERS, EXPECTED_UNCONDITIONAL };
POLICY_EOF
export RULES_INJECTION_POLICY; RULES_INJECTION_POLICY="$(node_path "$REPO/hooks/lib/rules-injection-policy.js")"

sha1_of() { printf '%s' "$1" | node -e "
let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{
  console.log(require('crypto').createHash('sha1').update(d).digest('hex'));});"; }

# fire <session_id> <abs_file_path> <load_reason_json_or_OMIT> -> prints "<rc>|<stdout>"
fire() {
    local sid="$1" fp="$2" lr="$3" payload out rc=0
    if [ "$lr" = "OMIT" ]; then
        payload="$(node -e 'console.log(JSON.stringify({session_id:process.argv[1],file_path:process.argv[2],hook_event_name:"InstructionsLoaded"}))' "$sid" "$fp")"
    else
        payload="$(node -e 'console.log(JSON.stringify({session_id:process.argv[1],file_path:process.argv[2],load_reason:JSON.parse(process.argv[3]),hook_event_name:"InstructionsLoaded"}))' "$sid" "$fp" "$lr")"
    fi
    out="$(printf '%s' "$payload" | (cd "$BASE" && node "$(node_path "$HOOK")" 2>/dev/null))" || rc=$?
    printf '%s|%s' "$rc" "$out"
}

# fire_raw <json_payload> -> prints "<rc>|<stdout>|<stderr>" with NUL-free separators.
# Used where the payload must not be re-serialized by node (injection cases).
fire_raw() {
    local payload="$1" rc=0
    local o="$BASE/.raw-out.$$" e="$BASE/.raw-err.$$"
    printf '%s' "$payload" | (cd "$BASE" && node "$(node_path "$HOOK")" >"$o" 2>"$e") || rc=$?
    printf '%s|%s|%s' "$rc" "$(cat "$o" 2>/dev/null)" "$(cat "$e" 2>/dev/null)"
}

# read_field <session_id> <abs_file_path> <field> -> prints value or MISSING_RECEIPT
read_field() {
    local sid="$1" fp="$2" field="$3" key
    key="$(sha1_of "$fp")"
    local rf="$WFDIR/$sid.instructions-loaded/$key.json"
    [ -f "$rf" ] || { echo "MISSING_RECEIPT"; return; }
    node -e "
const j = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
const v = j[process.argv[2]];
console.log(v === undefined ? 'ABSENT' : (v === null ? 'null' : String(v)));
" "$(node_path "$rf")" "$field" 2>/dev/null || echo "UNREADABLE"
}

# rules_fire <session_id> <rules-relative-name> <content> -> writes the rule then fires.
# Returns nothing; read the verdict with read_field.
rules_fire() {
    local sid="$1" name="$2" content="$3" fp
    printf '%s' "$content" > "$REPO/rules/$name"
    fp="$(node_path "$REPO/rules/$name")"
    fire "$sid" "$fp" OMIT >/dev/null
    read_field "$sid" "$fp" verdict
}
