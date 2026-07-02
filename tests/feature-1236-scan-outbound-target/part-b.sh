#!/bin/bash
# Part B — scan-outbound.js integration (sandboxed hook + gh stub).
# Sourced-and-run standalone: builds its own PASS/FAIL via helpers.sh.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./helpers.sh
. "$HERE/helpers.sh"

echo "=== Part B: scan-outbound.js target-visibility integration ==="

if [ ! -f "$HOOK_SRC" ]; then
    skip "Part B — hooks/scan-outbound.js not present"
    echo "Part B: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
    exit 0
fi

# ── Sandbox builder ──────────────────────────────────────────────────────────
# build_sandbox <dir> <gh_api_private_output> <gh_list_output>
#               <scan_outbound_rc> <scan_offensive_rc>
#               <blocklist_content>
build_sandbox() {
    local sbox="$1"
    local gh_priv="$2"     # what "gh api repos/... --jq .private" prints
    local gh_list="$3"     # what "gh repo list --visibility private ..." prints
    local ob_rc="${4:-0}"  # bin/scan-outbound.sh exit code
    local off_rc="${5:-0}" # bin/scan-offensive exit code
    local blocklist="${6:-}" # content to write into .private-info-blocklist

    mkdir -p "$sbox/hooks/lib/workflow-state" "$sbox/hooks/workflow-gate" "$sbox/bin"

    # Copy hook + all lib deps
    cp "$HOOK_SRC" "$sbox/hooks/scan-outbound.js"
    cp -r "$AGENTS_DIR/hooks/lib/." "$sbox/hooks/lib/" 2>/dev/null || true
    # Copy workflow-gate (required by hooks/lib/workflow-state/evidence-resolver.js)
    cp -r "$AGENTS_DIR/hooks/workflow-gate/." "$sbox/hooks/workflow-gate/" 2>/dev/null || true
    # Stub session-markers.js to avoid deep dependency chain for sandbox isolation
    cat > "$sbox/hooks/lib/session-markers.js" <<'SESSIONSTUB'
"use strict";
// Sandbox stub: never bypass, never session-off
module.exports = {
  isWorkflowOff: function() { return false; },
  isWorktreeOff: function() { return false; },
  workflowOffNoticeText: function() { return ""; },
  worktreeOffNoticeText: function() { return ""; },
};
SESSIONSTUB

    # Stub gh that controls API responses
    local gh_bin="$sbox/bin/gh-stub"
    mkdir -p "$gh_bin"
    cat > "$gh_bin/gh" <<GHSTUB
#!/bin/bash
if [[ "\$1" == "api" ]]; then
    printf '%s\n' "$gh_priv"
    exit 0
elif [[ "\$1" == "repo" && "\$2" == "list" ]]; then
    printf '%s\n' "$gh_list"
    exit 0
else
    exit 0
fi
GHSTUB
    chmod +x "$gh_bin/gh"

    # stub is-private-repo.js to use the gh stub PATH
    # We replace it with a version that prepends our stub gh to PATH
    local IS_PRIV_JS="$sbox/hooks/lib/is-private-repo.js"
    cat > "$IS_PRIV_JS" <<ISPRIV
"use strict";
const { execSync } = require("child_process");
const path = require("path");
const sep = process.platform === "win32" ? ";" : ":";
process.env.PATH = "${gh_bin}" + sep + (process.env.PATH || "");

const { parseGitCArg } = require("./parse-git-args");

function shellPath(p) { return p.split(path.sep).join("/"); }
function toNativePath(p) {
    if (process.platform !== "win32") return p;
    const m = p.match(/^\/([a-z])\/(.*)$/i);
    return m ? (m[1].toUpperCase() + ":/" + m[2]) : p;
}
function isPrivateRepo(repoDir) {
    if (!repoDir) return false;
    try {
        const remoteUrl = execSync('git -C "' + shellPath(repoDir) + '" remote get-url origin', {encoding:"utf8",timeout:5000,stdio:["pipe","pipe","pipe"]}).trim();
        if (!remoteUrl) return false;
        const hostM = remoteUrl.match(/^(?:ssh|https?):\/\/(?:[^@]+@)?([^/:]+)/);
        const scpM = remoteUrl.match(/^[^@]+@([^:]+):/);
        const host = (hostM && hostM[1]) || (scpM && scpM[1]) || null;
        if (host && host !== "github.com") return true;
        const idM = remoteUrl.match(/[/:] ([^/]+\\/[^/]+?)(?:\\.git)?\$/);
        const repoId = idM ? idM[1] : null;
        if (!repoId) return false;
        const r = execSync("gh api repos/" + repoId + " --jq .private", {encoding:"utf8",timeout:10000,stdio:["pipe","pipe","pipe"]}).trim();
        return r === "true";
    } catch(e) { return false; }
}
function resolveRepoDir(cmd) {
    if (process.env.CLAUDE_PROJECT_DIR) return process.env.CLAUDE_PROJECT_DIR;
    const raw = parseGitCArg(cmd) || ".";
    return toNativePath(raw);
}
module.exports = { isPrivateRepo, resolveRepoDir, toNativePath, extractRepoDirFromCommand: parseGitCArg };
ISPRIV

    # Also stub shouldScanAsPublicTarget / listPrivateRepoNames stubs for the
    # target-visibility gate (they may not exist yet — we patch them in).
    # When the gate reads these from is-private-repo.js, our stub will be in place.
    # We append them as conditional exports so existing tests still pass.
    cat >> "$IS_PRIV_JS" <<EXTRA
// Stub new exports for target-visibility gate testing
const GH_PRIV_OUT = "${gh_priv}";
const GH_LIST_OUT = "${gh_list}";
module.exports.shouldScanAsPublicTarget = function(ownerRepo) {
    if (!ownerRepo) return Promise.resolve(true);
    return Promise.resolve(GH_PRIV_OUT !== "true");
};
module.exports.listPrivateRepoNames = function() {
    if (!GH_LIST_OUT) return Promise.resolve([]);
    return Promise.resolve(GH_LIST_OUT.split("\\n").filter(Boolean));
};
EXTRA

    # Stub bin/scan-outbound.sh
    cat > "$sbox/bin/scan-outbound.sh" <<STUBSH
#!/bin/bash
exit ${ob_rc}
STUBSH
    chmod +x "$sbox/bin/scan-outbound.sh"

    # Stub bin/scan-offensive
    cat > "$sbox/bin/scan-offensive" <<STUBOFF
#!/usr/bin/env node
process.exit(${off_rc});
STUBOFF
    chmod +x "$sbox/bin/scan-offensive"

    # Write .private-info-blocklist if content provided
    if [ -n "$blocklist" ]; then
        printf '%s\n' "$blocklist" > "$sbox/.private-info-blocklist"
    fi
}

run_hook() {
    local sbox="$1" json="$2"
    local sbox_node
    if command -v cygpath >/dev/null 2>&1; then
        sbox_node="$(cygpath -m "$sbox")"
    else
        sbox_node="$sbox"
    fi
    echo "$json" | run_with_timeout 15 node "$sbox_node/hooks/scan-outbound.js" 2>/dev/null
}

# Check if scan-outbound.js contains the target-visibility gate
hook_has_target_gate() {
    grep -q 'shouldScanAsPublicTarget\|extractRepoFlag\|target.*visibility\|listPrivateRepoNames' "$HOOK_SRC" 2>/dev/null
}

# Approve = literal "approve" decision OR empty-object allow.
is_approve() {
    local out="$1"
    if echo "$out" | grep -q '"approve"'; then return 0; fi
    echo "$out" | node -e "try{const j=JSON.parse(require('fs').readFileSync(0,'utf8'));process.exit(Object.keys(j).length===0?0:1);}catch(e){process.exit(1);}" 2>/dev/null
}

# ── Tests ────────────────────────────────────────────────────────────────────

# B-1: Public target + static-blocklisted content → HARD block (core attack scenario)
run_b1() {
    local sbox="$TMPBASE/b1-pub-hard"
    build_sandbox "$sbox" "false" "" 1 0 "PRIVATE_HOSTNAME=secret.internal.example.com"

    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create --repo owner/public-repo --body \"See secret.internal.example.com for details\""}}'

    if ! hook_has_target_gate; then
        out="$(run_hook "$sbox" "$json")"
        if echo "$out" | grep -q '"block"'; then
            pass "B-1: public-target HARD block (static blocklist) — gate not yet integrated but scan-outbound.sh rc=1 blocks"
        else
            fail "B-1: expected block (static blocklist), got: $out — not yet implemented"
        fi
    else
        out="$(run_hook "$sbox" "$json")"
        if echo "$out" | grep -q '"block"'; then
            pass "B-1: public-target + static-blocklisted content → HARD block"
        else
            fail "B-1: expected HARD block for public target with blocklisted content, got: $out"
        fi
    fi
}
run_b1

# B-2: Public target + dynamic-only private repo name → WARN-tier block
run_b2() {
    local sbox="$TMPBASE/b2-pub-warn"
    build_sandbox "$sbox" "false" "owner/secret-internal-repo" 0 0 ""

    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create --repo owner/public-repo --body \"See owner/secret-internal-repo for context\""}}'

    if ! hook_has_target_gate; then
        out="$(run_hook "$sbox" "$json")"
        if echo "$out" | grep -q '"block"'; then
            pass "B-2: dynamic WARN block (gate not yet integrated but blocked by other reason)"
        else
            fail "B-2: public-target + dynamic private repo name → expected WARN-tier block — not yet implemented"
        fi
    else
        out="$(run_hook "$sbox" "$json")"
        if echo "$out" | grep -q '"block"'; then
            if echo "$out" | grep -qi 'warn'; then
                pass "B-2: dynamic WARN-tier block for private-repo-name leak to public target"
            else
                pass "B-2: dynamic private-repo-name leak blocked (reason may vary)"
            fi
        else
            fail "B-2: expected WARN-tier block for dynamic-only private repo name leak, got: $out"
        fi
    fi
}
run_b2

# B-3: HARD-before-WARN precedence — both static+dynamic match → HARD reason dominates
run_b3() {
    local sbox="$TMPBASE/b3-precedence"
    build_sandbox "$sbox" "false" "owner/secret-internal-repo" 1 0 "PRIVATE_HOSTNAME=secret.internal.example.com"

    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create --repo owner/public-repo --body \"Contact secret.internal.example.com or see owner/secret-internal-repo\""}}'

    if ! hook_has_target_gate; then
        out="$(run_hook "$sbox" "$json")"
        if echo "$out" | grep -q '"block"'; then
            pass "B-3: HARD block fires (gate not yet integrated, blocked by scan-outbound.sh rc=1)"
        else
            fail "B-3: expected HARD block, got: $out — not yet implemented"
        fi
    else
        out="$(run_hook "$sbox" "$json")"
        if echo "$out" | grep -q '"block"'; then
            if echo "$out" | grep -qi 'warn-only\|warn only'; then
                fail "B-3: HARD-before-WARN violated — got warn-only reason instead of HARD: $out"
            else
                pass "B-3: HARD-before-WARN precedence — HARD reason returned (not warn-only)"
            fi
        else
            fail "B-3: expected HARD block for combined static+dynamic match, got: $out"
        fi
    fi
}
run_b3

# B-4: Private target + offensive content → offensive scanner STILL blocks
run_b4() {
    local sbox="$TMPBASE/b4-private-target-offensive"
    build_sandbox "$sbox" "true" "" 0 1 ""

    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create --repo owner/private-repo --body \"offensive content that should always be caught\""}}'
    out="$(run_hook "$sbox" "$json")"
    if echo "$out" | grep -q '"block"'; then
        pass "B-4: private target + offensive content → offensive scanner blocks (private skip does not exempt offensive)"
    else
        fail "B-4: offensive scanner must run even for private targets — got: $out"
    fi
}
run_b4

# B-4b (#15): Private target bypasses the private-info scan.
# scan-outbound.sh WOULD HARD-block (rc=1) if it ran, but the target is private
# so the visibility gate must SKIP the private-info scan. Offensive is clean (rc=0).
# → hook must APPROVE. If it blocks here, the private-info scan wrongly ran.
run_b4b() {
    local sbox="$TMPBASE/b4b-private-skips-privinfo"
    # gh api → "true" (private); scan-outbound.sh rc=1 (would HARD-block if run);
    # scan-offensive rc=0 (clean).
    build_sandbox "$sbox" "true" "" 1 0 "PRIVATE_HOSTNAME=secret.internal.example.com"

    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create --repo owner/private-repo --body \"See secret.internal.example.com for details\""}}'

    if ! hook_has_target_gate; then
        # Pre-fix vulnerable state: no gate → scan-outbound.sh rc=1 runs unconditionally → blocks.
        # This is the RED proof that the private-info scan is NOT yet skipped for private targets.
        out="$(run_hook "$sbox" "$json")"
        if is_approve "$out"; then
            fail "B-4b: private target unexpectedly approved before gate exists — check sandbox"
        else
            fail "B-4b: private target still runs private-info scan (blocks) — visibility gate not yet implemented"
        fi
    else
        out="$(run_hook "$sbox" "$json")"
        if is_approve "$out"; then
            pass "B-4b: private target → private-info scan SKIPPED → approve (offensive clean)"
        else
            fail "B-4b: private target must skip private-info scan and approve, got block: $out"
        fi
    fi
}
run_b4b

# B-5: gh api error (stub exits non-zero) → shouldScanAsPublicTarget fail-closed → still HARD-blocks
run_b5() {
    local sbox="$TMPBASE/b5-gh-api-err"
    build_sandbox "$sbox" "" "" 1 0 "PRIVATE_HOSTNAME=secret.internal.example.com"
    cat > "$sbox/bin/gh-stub/gh" <<'GHSTUB'
#!/bin/bash
if [[ "$1" == "api" ]]; then
    exit 1
fi
exit 0
GHSTUB
    chmod +x "$sbox/bin/gh-stub/gh"

    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create --repo owner/maybe-public --body \"See secret.internal.example.com\""}}'
    out="$(run_hook "$sbox" "$json")"
    if echo "$out" | grep -q '"block"'; then
        pass "B-5: gh api error → fail-closed → scan runs → HARD block"
    else
        fail "B-5: expected HARD block when gh api fails (fail-closed), got: $out"
    fi
}
run_b5

# B-6: Short -R flag behaves same as --repo for public-target HARD case
run_b6() {
    local sbox="$TMPBASE/b6-short-flag"
    build_sandbox "$sbox" "false" "" 1 0 "PRIVATE_HOSTNAME=secret.internal.example.com"

    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create -R owner/public-repo --body \"See secret.internal.example.com\""}}'
    out="$(run_hook "$sbox" "$json")"
    if echo "$out" | grep -q '"block"'; then
        pass "B-6: -R short flag → same as --repo → public-target HARD block"
    else
        fail "B-6: expected HARD block with -R short flag, got: $out — not yet implemented"
    fi
}
run_b6

# SKIPPED: B-7 no-flag cwd-based target resolution (L2-fragile; see dispatcher L3 gap).

# B-8: Bare #N in body (no owner/repo prefix) → approve (not flagged as private-repo-name)
run_b8() {
    local sbox="$TMPBASE/b8-bare-hash"
    build_sandbox "$sbox" "false" "" 0 0 ""

    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create --repo owner/public-repo --body \"see #123 for context\""}}'
    out="$(run_hook "$sbox" "$json")"
    if is_approve "$out"; then
        pass "B-8: bare #N in body → approved (bare issue ref not flagged)"
    else
        fail "B-8: bare #N in body should be approved, got: $out"
    fi
}
run_b8

# B-9 (#14): Clean public-target → approved (positive-pass proof).
# gh api → "false" (public via --repo owner/public-repo); scan-outbound.sh rc=0
# (no blocklist hit); scan-offensive rc=0 (clean); no dynamic private-repo match.
# → hook must APPROVE. A legitimate clean public write is allowed.
run_b9() {
    local sbox="$TMPBASE/b9-clean-public-approve"
    build_sandbox "$sbox" "false" "" 0 0 ""

    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create --repo owner/public-repo --body \"A perfectly ordinary public note with no secrets\""}}'
    out="$(run_hook "$sbox" "$json")"
    if is_approve "$out"; then
        pass "B-9: clean public target → approved (legitimate clean write allowed)"
    else
        fail "B-9: clean public target must be approved, got: $out"
    fi
}
run_b9

# B-write-warn (#16): Edit/Write branch dynamic WARN.
# STEP-3b routes listPrivateRepoNames() dynamic WARN through the Edit/Write tool
# branch. Content contains a private repo name that is ONLY in the dynamic
# listPrivateRepoNames() stub output (NOT in the static blocklist fixture).
# → hook must WARN-block. RED until the JS dynamic WARN + Edit/Write wiring exists.
run_b_write_warn() {
    local sbox="$TMPBASE/bwrite-dynamic-warn"
    # dynamic list has the private repo name; static blocklist is empty; scans clean.
    build_sandbox "$sbox" "false" "owner/secret-internal-repo" 0 0 ""

    local json out
    json='{"tool_name":"Write","tool_input":{"file_path":"/tmp/note.md","content":"See owner/secret-internal-repo for context"},"session_id":"test-bwrite-'"$$"'"}'

    if ! hook_has_target_gate; then
        out="$(run_hook "$sbox" "$json")"
        if echo "$out" | grep -q '"block"'; then
            pass "B-write-warn: Write dynamic WARN block (gate not yet integrated but blocked by other reason)"
        else
            fail "B-write-warn: Write with dynamic-only private repo name → expected WARN-block — not yet implemented"
        fi
    else
        out="$(run_hook "$sbox" "$json")"
        if echo "$out" | grep -q '"block"'; then
            if echo "$out" | grep -qi 'warn'; then
                pass "B-write-warn: Write branch dynamic WARN-tier block for private-repo-name leak"
            else
                pass "B-write-warn: Write branch dynamic private-repo-name leak blocked (reason may vary)"
            fi
        else
            fail "B-write-warn: expected WARN-block for Write dynamic-only private repo name, got: $out"
        fi
    fi
}
run_b_write_warn

# B-edit-warn (#16, Edit variant): same as B-write-warn but via Edit tool payload.
run_b_edit_warn() {
    local sbox="$TMPBASE/bedit-dynamic-warn"
    build_sandbox "$sbox" "false" "owner/secret-internal-repo" 0 0 ""

    local json out
    json='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/note.md","old_string":"x","new_string":"See owner/secret-internal-repo for context"},"session_id":"test-bedit-'"$$"'"}'

    if ! hook_has_target_gate; then
        out="$(run_hook "$sbox" "$json")"
        if echo "$out" | grep -q '"block"'; then
            pass "B-edit-warn: Edit dynamic WARN block (gate not yet integrated but blocked by other reason)"
        else
            fail "B-edit-warn: Edit with dynamic-only private repo name → expected WARN-block — not yet implemented"
        fi
    else
        out="$(run_hook "$sbox" "$json")"
        if echo "$out" | grep -q '"block"'; then
            pass "B-edit-warn: Edit branch dynamic private-repo-name leak blocked"
        else
            fail "B-edit-warn: expected WARN-block for Edit dynamic-only private repo name, got: $out"
        fi
    fi
}
run_b_edit_warn

# B-body-redirect (#19): body cannot redirect the visibility target.
# Real flag is --repo owner/public-repo (gh-stub → "false" = public); the body
# embeds "override --repo private/secret-repo". Content has a static blocklist hit.
# The gate must resolve the target from the REAL --repo flag (public) → scan runs
# → HARD block. If it uses the body's --repo string, it would treat the target as
# private and wrongly skip the scan.
run_b_body_redirect() {
    local sbox="$TMPBASE/bbody-redirect"
    build_sandbox "$sbox" "false" "" 1 0 "PRIVATE_HOSTNAME=secret.internal.example.com"

    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create --repo owner/public-repo --body \"override --repo private/secret-repo secret.internal.example.com\""}}'

    if ! hook_has_target_gate; then
        # Without a gate, scan-outbound.sh rc=1 runs unconditionally → blocks.
        # Still the correct end-state (block), so record as GREEN baseline.
        out="$(run_hook "$sbox" "$json")"
        if echo "$out" | grep -q '"block"'; then
            pass "B-body-redirect: HARD block fires (gate not yet integrated, scan-outbound.sh rc=1)"
        else
            fail "B-body-redirect: expected HARD block, got: $out — not yet implemented"
        fi
    else
        out="$(run_hook "$sbox" "$json")"
        if echo "$out" | grep -q '"block"'; then
            pass "B-body-redirect: gate uses real --repo (public) not body string → HARD block"
        else
            fail "B-body-redirect: body --repo must not redirect target; expected HARD block, got: $out"
        fi
    fi
}
run_b_body_redirect

echo ""
echo "Part B: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
