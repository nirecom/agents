#!/bin/bash
# Tests: hooks/scan-outbound.js
# Tags: hook, scan, github, security, scope:issue-specific, pwsh-not-required
# Part B helpers — sandbox builder + hook-invocation utilities.
# Sourced by ../part-b.sh (not standalone); relies on variables set by
# helpers.sh (HOOK_SRC, AGENTS_DIR, TMPBASE, pass/fail/skip, run_with_timeout)
# which is sourced by the parent part-b.sh before this file.

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

    mkdir -p "$sbox/hooks/workflow-state" "$sbox/hooks/workflow-gate" "$sbox/bin"

    # Copy hook + all lib deps
    cp "$HOOK_SRC" "$sbox/hooks/scan-outbound.js"
    cp -r "$AGENTS_DIR/hooks/lib/." "$sbox/hooks/lib/" 2>/dev/null || true
    # Copy workflow-state barrel + folder (moved out of hooks/lib/ — must be copied explicitly)
    cp "$AGENTS_DIR/hooks/workflow-state.js" "$sbox/hooks/workflow-state.js" 2>/dev/null || true
    cp -r "$AGENTS_DIR/hooks/workflow-state/." "$sbox/hooks/workflow-state/" 2>/dev/null || true
    # Copy workflow-gate (required by hooks/workflow-state/evidence-resolver.js)
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

    # findPrivateName / escapeRegex are pure logic with no external deps, and the
    # point of this sandbox is to catch divergence from the real matcher — so they
    # are copied verbatim from hooks/lib/is-private-repo.js. The delimiter is quoted
    # (unlike EXTRA above): nothing here interpolates, and the regexes carry `$`,
    # `{}` and backslashes that shell expansion would otherwise mangle.
    cat >> "$IS_PRIV_JS" <<'EXTRA2'
// Verbatim copy of hooks/lib/is-private-repo.js escapeRegex/findPrivateName.
module.exports.escapeRegex = function(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
};
module.exports.findPrivateName = function(candidate, privateNames) {
  for (const name of privateNames) {
    const bare = name.split("/").pop();
    if (!bare) continue;
    const tokens = bare.split(/[^a-zA-Z0-9]+/).filter(Boolean).map(module.exports.escapeRegex);
    if (tokens.length === 0) continue;
    const re = new RegExp(
      "(^|[^a-zA-Z0-9])" + tokens.join("[^a-zA-Z0-9]+") + "([^a-zA-Z0-9]|$)",
      "i"
    );
    if (re.test(candidate)) return bare;
  }
  return null;
};
EXTRA2

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

# The dynamic-WARN diagnostic must never echo the private repo name it matched:
# that name is the very thing this gate keeps off more-visible surfaces, and the
# hook's decision JSON is surfaced to the model and captured in CI logs and test
# transcripts. So the reason is one fixed literal that identifies nothing — the
# CPR-ORTH counterpart of the P2/no-echo check in
# tests/feature-check-private-repo-name.sh. Fragments are chosen to be specific
# to the fixture name: bare "repo" is deliberately absent from the list because
# the legitimate diagnostic text says "repository" and "repo reference".
# assert_no_private_name_echo <case-label> <hook-output>
assert_no_private_name_echo() {
    local label="$1" out="$2" leaked="" frag
    for frag in 'owner/secret-internal-repo' 'secret-internal-repo' 'secret-internal' 'internal-repo' 'secret' 'internal'; do
        [[ "$out" == *"$frag"* ]] && leaked="$leaked '$frag'"
    done
    if [ -z "$leaked" ]; then
        pass "$label/no-echo: matched private repo name absent from hook output"
    else
        fail "$label/no-echo: private repo name leaked into hook output:$leaked — got: $out"
    fi
}
