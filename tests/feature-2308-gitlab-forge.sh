#!/bin/bash
# tests/feature-2308-gitlab-forge.sh
# Tests: hooks/lib/parse-remote-url.js, hooks/lib/forge/gitlab.js, hooks/lib/forge-router.js, hooks/lib/is-private-repo.js, bin/detect-forge-type, bin/worker-dispatch/workers/commit-push/procedure.js
# Tags: scope:issue-specific, gitlab, forge, security, path-traversal, TL2
# Dispatch + aggregate entrypoint for the split suite (the flat file hit the
# 500-line HARD limit; rules/coding/file-split.md). Split groups = the
# SPLIT_GROUPS array below (SSOT); each also runs standalone. Shared scaffolding
# lives in feature-2308-gitlab-forge/_lib.sh (sourced, not a test file). #2308
# GitLab forge support: parse-remote-url resolveForgeTarget/extractProjectPath,
# codehostGitlab, is-private-repo dispatch, detect-forge-type CLI, commit-push MR.

set -uo pipefail

# Outer timeout so a wedged node cannot stall the suite (rules/test.md).
if command -v timeout >/dev/null 2>&1 && [ -z "${_FEAT2308_FORGE_INNER:-}" ]; then
    _FEAT2308_FORGE_INNER=1 timeout 240 bash "$0" "$@"
    exit $?
fi

SPLIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-2308-gitlab-forge"

SPLIT_GROUPS=(
    "gitlab-forge-abc.sh"
    "gitlab-forge-d.sh"
    "gitlab-forge-f.sh"
    "gitlab-forge-failsafe.sh"
)

TOTAL_PASS=0
TOTAL_FAIL=0

for group in "${SPLIT_GROUPS[@]}"; do
    script="$SPLIT_DIR/$group"
    if [ ! -f "$script" ]; then
        echo "FAIL: split group missing: $script"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        continue
    fi

    echo ""
    echo "═══ $group ═══"
    out_file="$(mktemp)"
    bash "$script" 2>&1 | tee "$out_file"
    rc=${PIPESTATUS[0]}

    results_line="$(grep -E '^Results: [0-9]+ passed, [0-9]+ failed' "$out_file" | tail -1)"
    if [ -n "$results_line" ]; then
        g_pass="$(printf '%s' "$results_line" | sed -E 's/^Results: ([0-9]+) passed.*/\1/')"
        g_fail="$(printf '%s' "$results_line" | sed -E 's/.* ([0-9]+) failed.*/\1/')"
        TOTAL_PASS=$((TOTAL_PASS + g_pass))
        TOTAL_FAIL=$((TOTAL_FAIL + g_fail))
    else
        echo "WARN: $group emitted no Results line (exit=$rc); counting as 1 failure"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
    rm -f "$out_file"
done

# C4-env (C4): readGitlabHostConfig() reading GITLAB_HOSTNAME from a real .env
# FILE via AGENTS_CONFIG_DIR — the SSOT path gitlab-forge-abc.sh's C4/C4b never
# hit (they export process.env instead). detect-forge-type must classify a
# gitlab.mycompany.com origin as gitlab when ONLY a .env declares the host
# (env var unset); the control (.env omits the key) falls back to unknown for
# the same origin. Source: hooks/lib/forge-router.js, bin/detect-forge-type.
echo ""
echo "═══ C4-env: .env-file GITLAB_HOSTNAME read path ═══"
C4_PASS=0
C4_FAIL=0
c4_pass() { echo "PASS: $1"; C4_PASS=$((C4_PASS + 1)); }
c4_fail() { echo "FAIL: $1"; C4_FAIL=$((C4_FAIL + 1)); }
c4_np() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
c4_rt() { if command -v timeout >/dev/null 2>&1; then timeout "$1" "${@:2}"; else "${@:2}"; fi; }

C4_AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
C4_DETECT_CLI="$C4_AGENTS_DIR/bin/detect-forge-type"
C4_TMP="$(mktemp -d)"
C4_CFG="$C4_TMP/cfg"; mkdir -p "$C4_CFG"
printf 'GITLAB_HOSTNAME=gitlab.mycompany.com\n' > "$C4_CFG/.env"
C4_CFG_EMPTY="$C4_TMP/cfg-empty"; mkdir -p "$C4_CFG_EMPTY"
printf '# no forge host declared here\n' > "$C4_CFG_EMPTY/.env"
C4_REPO="$C4_TMP/repo"; mkdir -p "$C4_REPO"
git -C "$C4_REPO" init -q
git -C "$C4_REPO" config core.hooksPath /dev/null 2>/dev/null || true
git -C "$C4_REPO" config user.email "test@example.com"
git -C "$C4_REPO" config user.name "Test"
git -C "$C4_REPO" remote add origin "git@gitlab.mycompany.com:team/app.git"

# c4_type <cfgdir> -> the CLI's JSON .type, with process.env.GITLAB_HOSTNAME
# always unset so the .env file is the ONLY possible source of the host.
c4_type() {
    local cfg="$1" out
    if [ ! -f "$C4_DETECT_CLI" ]; then printf 'ERR:no-cli'; return 0; fi
    out=$(cd "$C4_REPO" && unset GITLAB_HOSTNAME && export AGENTS_CONFIG_DIR="$cfg" && c4_rt 20 node "$C4_DETECT_CLI" 2>/dev/null)
    printf '%s' "$out" | c4_rt 20 node -e '
let s=""; process.stdin.on("data",d=>s+=d); process.stdin.on("end",()=>{
  try { process.stdout.write(String(JSON.parse(s).type)); } catch(e){ process.stdout.write("ERR:unparsable"); }
});' 2>/dev/null
}

C4_GOT="$(c4_type "$(c4_np "$C4_CFG")")"
if [ "$C4_GOT" = "gitlab" ]; then
    c4_pass "C4-env: .env GITLAB_HOSTNAME=gitlab.mycompany.com -> self-hosted origin classified gitlab"
else
    c4_fail "C4-env: expected gitlab from .env host, got: [$C4_GOT]"
fi

C4_CTRL="$(c4_type "$(c4_np "$C4_CFG_EMPTY")")"
if [ "$C4_CTRL" = "unknown" ]; then
    c4_pass "C4-env-ctrl: .env without the key + no env var -> same origin falls back to unknown"
else
    c4_fail "C4-env-ctrl: expected unknown without the .env host, got: [$C4_CTRL]"
fi

rm -rf "$C4_TMP" 2>/dev/null || true
echo "Results: $C4_PASS passed, $C4_FAIL failed"
TOTAL_PASS=$((TOTAL_PASS + C4_PASS))
TOTAL_FAIL=$((TOTAL_FAIL + C4_FAIL))

echo ""
echo "═════════════════════════════════════════"
echo "Aggregate Results: $TOTAL_PASS passed, $TOTAL_FAIL failed"
echo "Total: PASS=$TOTAL_PASS FAIL=$TOTAL_FAIL"
[ "$TOTAL_FAIL" -eq 0 ] && exit 0 || exit 1
