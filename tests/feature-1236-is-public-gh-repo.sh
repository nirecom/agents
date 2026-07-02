#!/bin/bash
# tests/feature-1236-is-public-gh-repo.sh
# Tests: hooks/lib/is-private-repo.js
# Tags: hook, scan, github, security, scope:issue-specific, pwsh-not-required
#
# Unit tests for the NEW exports shouldScanAsPublicTarget(ownerRepo) and
# listPrivateRepoNames() added to hooks/lib/is-private-repo.js.
#
# Strategy: node driver that require()s the module directly, catching
# MODULE_NOT_FOUND or missing-function and reporting "not yet implemented"
# for each case. gh is stubbed by prepending a temp dir to PATH.
#
# Security boundary: shouldScanAsPublicTarget is fail-CLOSED — any
# uncertainty (gh error, missing, empty output) → return true (scan).
# listPrivateRepoNames is fail-OPEN — error → return [].
#
# L3 gap (what this test does NOT catch):
# - real gh CLI round-trip against GitHub API (private/public status in live env)
# - stub-controlled gh value cases (gh=false/true) run on POSIX only; on Windows-native
#   spawnSync resolves the real gh.exe and the bash stub cannot override it
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

is_windows_native() {
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) return 0 ;;
        *) return 1 ;;
    esac
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

# ── Build the Node driver ─────────────────────────────────────────────────────

DRIVER="$TMPBASE/driver.js"
cat > "$DRIVER" <<'NODE'
"use strict";
const path = require("path");
const os   = require("os");

// argv[2] = agents dir (node path), argv[3] = mode, argv[4] = ownerRepo, argv[5] = ghBinDir
const AGENTS_NODE = process.argv[2];
const MODE        = process.argv[3]; // "public-target" | "list-names"
const OWNER_REPO  = process.argv[4] !== undefined ? process.argv[4] : "";
const GH_BIN_DIR  = process.argv[5] || "";

// Prepend stub gh bin to PATH so the module picks it up
if (GH_BIN_DIR) {
    const sep = process.platform === "win32" ? ";" : ":";
    process.env.PATH = GH_BIN_DIR + sep + (process.env.PATH || "");
}

let mod;
try {
    mod = require(path.join(AGENTS_NODE, "hooks", "lib", "is-private-repo.js"));
} catch (e) {
    if (e && e.code === "MODULE_NOT_FOUND") {
        console.log(JSON.stringify({ ok: false, missing: true, error: "is-private-repo.js MODULE_NOT_FOUND" }));
        process.exit(0);
    }
    console.log(JSON.stringify({ ok: false, missing: false, error: String((e && e.message) || e) }));
    process.exit(0);
}

// Check new exports exist
if (MODE === "public-target") {
    if (typeof mod.shouldScanAsPublicTarget !== "function") {
        console.log(JSON.stringify({ ok: false, missing: true, error: "shouldScanAsPublicTarget not yet exported" }));
        process.exit(0);
    }
    const arg = OWNER_REPO === "__UNDEFINED__" ? undefined
              : OWNER_REPO === "__NULL__"      ? null
              : OWNER_REPO;
    mod.shouldScanAsPublicTarget(arg).then(function(v) {
        console.log(JSON.stringify({ ok: true, value: v }));
    }).catch(function(e) {
        // Sync return also accepted — try direct call
        console.log(JSON.stringify({ ok: false, missing: false, error: String((e && e.message) || e) }));
    });
} else if (MODE === "list-names") {
    if (typeof mod.listPrivateRepoNames !== "function") {
        console.log(JSON.stringify({ ok: false, missing: true, error: "listPrivateRepoNames not yet exported" }));
        process.exit(0);
    }
    Promise.resolve(mod.listPrivateRepoNames()).then(function(v) {
        console.log(JSON.stringify({ ok: true, value: v }));
    }).catch(function(e) {
        console.log(JSON.stringify({ ok: false, missing: false, error: String((e && e.message) || e) }));
    });
} else {
    console.log(JSON.stringify({ ok: false, missing: false, error: "unknown mode: " + MODE }));
}
NODE

# Driver that handles both async (Promise) and sync returns
SYNC_DRIVER="$TMPBASE/sync-driver.js"
cat > "$SYNC_DRIVER" <<'NODE'
"use strict";
// Wraps the call to handle sync or Promise-returning functions
// argv[2]=agents argv[3]=mode argv[4]=ownerRepo argv[5]=ghBinDir
const path = require("path");

const AGENTS_NODE = process.argv[2];
const MODE        = process.argv[3];
const OWNER_REPO  = process.argv[4] !== undefined ? process.argv[4] : "";
const GH_BIN_DIR  = process.argv[5] || "";

if (GH_BIN_DIR) {
    const sep = process.platform === "win32" ? ";" : ":";
    process.env.PATH = GH_BIN_DIR + sep + (process.env.PATH || "");
}

let mod;
try {
    mod = require(path.join(AGENTS_NODE, "hooks", "lib", "is-private-repo.js"));
} catch (e) {
    if (e && e.code === "MODULE_NOT_FOUND") {
        process.stdout.write(JSON.stringify({ ok: false, missing: true, error: "is-private-repo.js MODULE_NOT_FOUND" }) + "\n");
        process.exit(0);
    }
    process.stdout.write(JSON.stringify({ ok: false, missing: false, error: String((e && e.message) || e) }) + "\n");
    process.exit(0);
}

function emit(v) { process.stdout.write(JSON.stringify(v) + "\n"); }

try {
    if (MODE === "public-target") {
        if (typeof mod.shouldScanAsPublicTarget !== "function") {
            emit({ ok: false, missing: true, error: "shouldScanAsPublicTarget not yet exported" });
            process.exit(0);
        }
        const arg = OWNER_REPO === "__UNDEFINED__" ? undefined
                  : OWNER_REPO === "__NULL__"      ? null
                  : OWNER_REPO;
        const ret = mod.shouldScanAsPublicTarget(arg);
        Promise.resolve(ret).then(function(v) { emit({ ok: true, value: v }); }).catch(function(e) { emit({ ok: false, error: String(e && e.message || e) }); });
    } else if (MODE === "list-names") {
        if (typeof mod.listPrivateRepoNames !== "function") {
            emit({ ok: false, missing: true, error: "listPrivateRepoNames not yet exported" });
            process.exit(0);
        }
        const ret = mod.listPrivateRepoNames();
        Promise.resolve(ret).then(function(v) { emit({ ok: true, value: v }); }).catch(function(e) { emit({ ok: false, error: String(e && e.message || e) }); });
    } else {
        emit({ ok: false, missing: false, error: "unknown mode: " + MODE });
    }
} catch (e) {
    emit({ ok: false, missing: false, error: String((e && e.message) || e) });
}
NODE

if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_NODE="$AGENTS_DIR"
fi

# ── Stub factory ─────────────────────────────────────────────────────────────

# make_gh_stub <dir> <private_output> <list_output> <exit_code_api> <exit_code_list>
# Creates an executable `gh` in <dir> that:
#   - `gh api repos/<any> --jq .private` → prints <private_output>, exits <exit_code_api>
#   - `gh repo list --visibility private --json nameWithOwner --jq ...` → prints <list_output>, exits <exit_code_list>
make_gh_stub() {
    local dir="$1" priv_out="$2" list_out="$3" api_rc="${4:-0}" list_rc="${5:-0}"
    mkdir -p "$dir"
    cat > "$dir/gh" <<STUB
#!/bin/bash
if [[ "\$1" == "api" ]]; then
    printf '%s\n' "$priv_out"
    exit $api_rc
elif [[ "\$1" == "repo" && "\$2" == "list" ]]; then
    printf '%s\n' "$list_out"
    exit $list_rc
else
    exit 0
fi
STUB
    chmod +x "$dir/gh"
}

# call_driver mode ownerRepo ghBinDir
call_driver() {
    local mode="$1" owner_repo="${2:-}" gh_bin="${3:-}"
    run_with_timeout 15 node "$SYNC_DRIVER" "$_AGENTS_NODE" "$mode" "$owner_repo" "$gh_bin"
}

# assert_public_target desc ownerRepo ghBinDir expected_bool
assert_public_target() {
    local desc="$1" owner_repo="$2" gh_bin="$3" want="$4"
    local out got
    out="$(call_driver public-target "$owner_repo" "$gh_bin" 2>/dev/null)"
    if echo "$out" | grep -q '"missing":true'; then
        fail "$desc — not yet implemented"
        return
    fi
    if ! echo "$out" | grep -q '"ok":true'; then
        fail "$desc — driver error: $out"
        return
    fi
    got="$(echo "$out" | node -e "const j=JSON.parse(require('fs').readFileSync(0,'utf8')); process.stdout.write(String(j.value));")"
    if [ "$got" = "$want" ]; then
        pass "$desc"
    else
        fail "$desc — want=$want got=$got"
    fi
}

# ── shouldScanAsPublicTarget cases ──────────────────────────────────────────

echo "=== shouldScanAsPublicTarget ==="

# Normal: gh reports false (public) → scan as public (true)
# Normal: gh reports true (private) → skip scan (false)
# These two cases depend on a PATH-prepended extensionless `gh` stub. On Windows-native,
# spawnSync("gh",[...]) resolves the real gh.exe via PATHEXT and cannot be overridden by
# a bash stub — running real gh repo list would also leak actual private repo names.
# Gate: skip on Windows, run on POSIX only.
GH1="$TMPBASE/gh-public"
GH2="$TMPBASE/gh-private"
if is_windows_native; then
    skip "gh=false (public) → shouldScan=true — gh cannot be PATH-stubbed on Windows (spawnSync resolves real gh.exe); stub-controlled value case is Linux-only"
    skip "gh=true (private) → shouldScan=false — gh cannot be PATH-stubbed on Windows (spawnSync resolves real gh.exe); stub-controlled value case is Linux-only"
else
    make_gh_stub "$GH1" "false" "" 0 0
    assert_public_target "gh=false (public) → shouldScan=true" "owner/pub-repo" "$GH1" "true"
    make_gh_stub "$GH2" "true" "" 0 0
    assert_public_target "gh=true (private) → shouldScan=false" "owner/priv-repo" "$GH2" "false"
fi

# Error: gh exits non-zero → fail-CLOSED → scan (true)
GH3="$TMPBASE/gh-apierr"
make_gh_stub "$GH3" "" "" 1 0
assert_public_target "gh api exit=1 → fail-closed → shouldScan=true" "owner/repo" "$GH3" "true"

# Error: gh not in PATH → fail-CLOSED → scan (true)
EMPTY_BIN="$TMPBASE/empty-bin"
mkdir -p "$EMPTY_BIN"
assert_public_target "gh missing → fail-closed → shouldScan=true" "owner/repo" "$EMPTY_BIN" "true"

# Edge: gh prints empty → fail-CLOSED → scan (true)
GH4="$TMPBASE/gh-empty"
make_gh_stub "$GH4" "" "" 0 0
assert_public_target "gh prints empty → fail-closed → shouldScan=true" "owner/repo" "$GH4" "true"

# Edge: gh prints garbage → fail-CLOSED → scan (true)
GH5="$TMPBASE/gh-garbage"
make_gh_stub "$GH5" "notaboolean" "" 0 0
assert_public_target "gh prints garbage → fail-closed → shouldScan=true" "owner/repo" "$GH5" "true"

# Edge: ownerRepo empty string → unknown → scan (true)
GH6="$TMPBASE/gh-ok"
make_gh_stub "$GH6" "false" "" 0 0
assert_public_target "ownerRepo='' → scan (true)" "" "$GH6" "true"

# Edge: ownerRepo undefined → scan (true)
assert_public_target "ownerRepo=undefined → scan (true)" "__UNDEFINED__" "$GH6" "true"

# Edge: ownerRepo null → scan (true)
assert_public_target "ownerRepo=null → scan (true)" "__NULL__" "$GH6" "true"

# #4 Security: shell-metachar injection via ownerRepo must NOT execute.
# ownerRepo must be passed to gh as an argument, not shell-interpolated.
# The stub gh is what must run; the injected `echo`/marker must never fire.
INJECT_MARKER="$TMPBASE/injected-marker"
GH_INJ="$TMPBASE/gh-inject"
make_gh_stub "$GH_INJ" "false" "" 0 0
run_inject_case() {
    local desc="$1" owner_repo="$2"
    rm -f "$INJECT_MARKER"
    local out got
    # Pass a payload whose shell-metachar fragment would create $INJECT_MARKER
    # if ownerRepo were shell-interpolated anywhere in the module.
    out="$(INJECT_MARKER="$INJECT_MARKER" call_driver public-target "$owner_repo" "$GH_INJ" 2>/dev/null)"
    if echo "$out" | grep -q '"missing":true'; then
        fail "$desc — not yet implemented"
        return
    fi
    # Primary security assertion: injected command must NOT have executed.
    if [ -e "$INJECT_MARKER" ]; then
        fail "$desc — INJECTION EXECUTED: marker file was created (ownerRepo shell-interpolated)"
        return
    fi
    if ! echo "$out" | grep -q '"ok":true'; then
        fail "$desc — driver error (no injection, but not ok): $out"
        return
    fi
    got="$(echo "$out" | node -e "const j=JSON.parse(require('fs').readFileSync(0,'utf8')); process.stdout.write(String(j.value));")"
    # Fail-closed boolean is fine (true or false); assert it is a boolean.
    if [ "$got" = "true" ] || [ "$got" = "false" ]; then
        pass "$desc — no injection, returned boolean ($got)"
    else
        fail "$desc — expected boolean, got='$got'"
    fi
}
run_inject_case "#4 injection: 'owner/repo; touch MARKER' does not execute" "owner/repo; touch $INJECT_MARKER"
run_inject_case "#4 injection: 'owner/repo\$(touch MARKER)' does not execute" "owner/repo\$(touch $INJECT_MARKER)"

# ── listPrivateRepoNames cases ──────────────────────────────────────────────

echo ""
echo "=== listPrivateRepoNames ==="

call_list() {
    local gh_bin="$1"
    call_driver list-names "" "$gh_bin" 2>/dev/null
}

assert_list_contains() {
    local desc="$1" gh_bin="$2" want_member="$3"
    local out
    out="$(call_list "$gh_bin")"
    if echo "$out" | grep -q '"missing":true'; then
        fail "$desc — not yet implemented"
        return
    fi
    if ! echo "$out" | grep -q '"ok":true'; then
        fail "$desc — driver error: $out"
        return
    fi
    local found
    found="$(echo "$out" | node -e "
const j=JSON.parse(require('fs').readFileSync(0,'utf8'));
const arr=j.value; const want=process.argv[1];
const ok=Array.isArray(arr) && arr.some(function(s){return s.indexOf(want)!==-1;});
process.stdout.write(ok?'yes':'no');
" "$want_member")"
    if [ "$found" = "yes" ]; then
        pass "$desc"
    else
        fail "$desc — '$want_member' not in result: $out"
    fi
}

assert_list_empty() {
    local desc="$1" gh_bin="$2"
    local out
    out="$(call_list "$gh_bin")"
    if echo "$out" | grep -q '"missing":true'; then
        fail "$desc — not yet implemented"
        return
    fi
    if ! echo "$out" | grep -q '"ok":true'; then
        fail "$desc — driver error: $out"
        return
    fi
    local len
    len="$(echo "$out" | node -e "
const j=JSON.parse(require('fs').readFileSync(0,'utf8'));
process.stdout.write(String(Array.isArray(j.value)?j.value.length:-1));
")"
    if [ "$len" = "0" ]; then
        pass "$desc"
    else
        fail "$desc — expected empty array, got length=$len: $out"
    fi
}

# listPrivateRepoNames value assertions: stub-dependent.
# On Windows-native, spawnSync resolves real gh.exe (not bash stub); running real
# `gh repo list --visibility private` is non-deterministic and would leak actual
# private repo names into test output.
# Gate: skip on Windows, run on POSIX only.
if is_windows_native; then
    skip "listPrivateRepoNames includes owner1/private-a — gh cannot be PATH-stubbed on Windows (spawnSync resolves real gh.exe); running real \`gh repo list --visibility private\` is non-deterministic and would leak actual private repo names — Linux-only"
    skip "listPrivateRepoNames includes owner2/private-b — gh cannot be PATH-stubbed on Windows (spawnSync resolves real gh.exe); running real \`gh repo list --visibility private\` is non-deterministic and would leak actual private repo names — Linux-only"
    skip "gh list exit=1 → listPrivateRepoNames=[] — gh cannot be PATH-stubbed on Windows (spawnSync resolves real gh.exe); running real \`gh repo list --visibility private\` is non-deterministic and would leak actual private repo names — Linux-only"
    skip "gh list prints nothing → listPrivateRepoNames=[] — gh cannot be PATH-stubbed on Windows (spawnSync resolves real gh.exe); running real \`gh repo list --visibility private\` is non-deterministic and would leak actual private repo names — Linux-only"
else
    # Normal: gh prints two owner/name lines → both appear in result
    GH_LIST1="$TMPBASE/gh-list-two"
    make_gh_stub "$GH_LIST1" "false" "owner1/private-a
owner2/private-b" 0 0
    assert_list_contains "listPrivateRepoNames includes owner1/private-a" "$GH_LIST1" "owner1/private-a"
    assert_list_contains "listPrivateRepoNames includes owner2/private-b" "$GH_LIST1" "owner2/private-b"

    # Error: gh list exits non-zero → returns [] (fail-OPEN)
    GH_LIST2="$TMPBASE/gh-list-err"
    make_gh_stub "$GH_LIST2" "false" "" 0 1
    assert_list_empty "gh list exit=1 → listPrivateRepoNames=[]" "$GH_LIST2"

    # Edge: gh prints nothing → returns []
    GH_LIST3="$TMPBASE/gh-list-empty"
    make_gh_stub "$GH_LIST3" "false" "" 0 0
    assert_list_empty "gh list prints nothing → listPrivateRepoNames=[]" "$GH_LIST3"
fi

echo ""
echo "================================"
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
