#!/bin/bash
# Tests: hooks/lib/forge/gitlab.js, hooks/lib/is-private-repo.js, hooks/lib/forge-router.js
# Tags: scope:issue-specific, gitlab, forge, security, fail-safe, TL2
set -u

# Issue #2308 — fail-safe / routing group of the split gitlab-forge suite.
#   C7 [HIGH, security]: codehostGitlab methods fail CLOSED (name-protecting) on
#     glab non-zero / throw / r.error — branches the Group B exit-0 mocks skip.
#   C8: is-private-repo.js#listPrivateRepoNames() routes to the forge-correct
#     descriptor (ORTH sibling of Group C/D isPrivateRepo routing coverage).
#   C6: readGitlabHostConfig() .env-vs-process.env precedence CONFLICT (C4d only
#     covered .env-only). glab/gh/git faked via spawnSync monkeypatch; no real API.

# TL3 gap: real `glab api` failure modes (auth/network/5xx) not exercised; only
# the spawnSync status/error surface the methods branch on is simulated.

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

FORGE_ROUTER_JS="$(nodepath "$AGENTS_DIR/hooks/lib/forge-router.js")"

# ============================================================================
# C7: codehostGitlab fail-safe returns (forge/gitlab.js)
# ============================================================================
echo "=== C7: codehostGitlab fail-safe (glab non-zero / throw / spawn error) ==="

# Driver: monkeypatch cp.spawnSync so every glab call fails per C7_MODE, then
# invoke one codehostGitlab method. Proves the method returns its CONSERVATIVE
# (name-protecting) value rather than crashing or leaking a permissive default.
C7_DRIVER="$TMPROOT/c7-failsafe-driver.js"
cat > "$C7_DRIVER" <<'NODE'
"use strict";
// C7_MODE: nonzero -> {status:1}; throw -> spawnSync throws (method catch);
// spawnerror -> {error:Error} (glab unavailable, r.error set).
const cp = require("child_process");
const realSpawn = cp.spawnSync.bind(cp);
const MODE = process.env.C7_MODE;
cp.spawnSync = function (cmd, args, opts) {
  const joined = (args || []).join(" ");
  const isGlab = cmd === "glab" || /glab/.test(String(cmd)) || /\bapi\b/.test(joined) || /\bmr\b/.test(joined);
  if (!isGlab) return realSpawn(cmd, args, opts);
  if (MODE === "throw") throw new Error("spawn glab ENOENT");
  if (MODE === "spawnerror") return { status: null, stdout: "", stderr: "", error: new Error("spawn glab ENOENT") };
  return { status: 1, stdout: "", stderr: "boom", error: null }; // nonzero
};
let gl;
try { gl = require(process.argv[2]).codehostGitlab; } catch (e) { process.stdout.write("ERR:require"); process.exit(0); }
const method = process.argv[3];
if (!gl || typeof gl[method] !== "function") { process.stdout.write("ERR:no-method"); process.exit(0); }
let r;
try { r = gl[method](process.argv[4]); } catch (e) { process.stdout.write("ERR:threw:" + e.message); process.exit(0); }
process.stdout.write(String(r));
NODE

run_c7() { # $1 = mode ; $2 = method ; $3 = arg
    C7_MODE="$1" run_with_timeout 20 node "$C7_DRIVER" "$GITLAB_JS" "$2" "$3" 2>/dev/null
}

# isPrivateRepo — glab exits non-zero (gitlab.js:47) -> true (private, fail-closed).
assert_eq "C7/isPrivateRepo glab non-zero -> true (fail-closed private)" "true" \
    "$(run_c7 nonzero isPrivateRepo 'https://gitlab.com/acme/widgets.git')"
# isPrivateRepo — spawnSync throws (gitlab.js:50 catch) -> true.
assert_eq "C7b/isPrivateRepo glab throws -> true (fail-closed private)" "true" \
    "$(run_c7 throw isPrivateRepo 'https://gitlab.com/acme/widgets.git')"

# shouldScanAsPublicTarget — glab exits non-zero (gitlab.js:59) -> true (scan).
assert_eq "C7c/shouldScanAsPublicTarget glab non-zero -> true (fail-closed scan)" "true" \
    "$(run_c7 nonzero shouldScanAsPublicTarget 'acme/widgets')"
# shouldScanAsPublicTarget — spawnSync throws (gitlab.js:62 catch) -> true.
assert_eq "C7d/shouldScanAsPublicTarget glab throws -> true (fail-closed scan)" "true" \
    "$(run_c7 throw shouldScanAsPublicTarget 'acme/widgets')"

# hasOpenPrForBranch — spawn result carries r.error / glab unavailable
# (gitlab.js:83) -> true (assume an MR may exist; do not push a duplicate).
assert_eq "C7e/hasOpenPrForBranch glab unavailable (r.error) -> true (fail-safe)" "true" \
    "$(run_c7 spawnerror hasOpenPrForBranch "$TMPROOT")"

# ============================================================================
# C8: is-private-repo.js#listPrivateRepoNames() forge routing
# ============================================================================
echo ""
echo "=== C8: is-private-repo.js#listPrivateRepoNames() routing to the forge descriptor ==="

# Existing C1* call codehostGitlab.listPrivateRepoNames() DIRECTLY, bypassing the
# router. This drives is-private-repo.js#listPrivateRepoNames(): it reads the CWD
# origin and must reach the forge-correct codehost. glab and gh return DISJOINT
# lists, so the returned array alone reveals which descriptor ran.
C8_DRIVER="$TMPROOT/c8-list-routing-driver.js"
cat > "$C8_DRIVER" <<'NODE'
"use strict";
const cp = require("child_process");
const fs = require("fs");
const realSpawn = cp.spawnSync.bind(cp);
const LOG = process.env.C8_LOG;
cp.spawnSync = function (cmd, args, opts) {
  const joined = (args || []).join(" ");
  if (LOG) { try { fs.appendFileSync(LOG, String(cmd) + " " + joined + "\n"); } catch (e) {} }
  if (cmd === "git") return realSpawn(cmd, args, opts); // real origin lookup
  if (cmd === "glab" || /glab/.test(String(cmd))) {
    return { status: 0, stdout: "gitlab-only/repo\n", stderr: "", error: null };
  }
  if (cmd === "gh" || /\bgh\b/.test(String(cmd))) {
    return { status: 0, stdout: "github-only/repo\n", stderr: "", error: null };
  }
  return realSpawn(cmd, args, opts);
};
let mod;
try { mod = require(process.argv[2]); } catch (e) { process.stdout.write("ERR:require"); process.exit(0); }
if (typeof mod.listPrivateRepoNames !== "function") { process.stdout.write("ERR:not-a-function"); process.exit(0); }
let r;
try { r = mod.listPrivateRepoNames(); } catch (e) { process.stdout.write("ERR:threw:" + e.message); process.exit(0); }
if (!Array.isArray(r)) { process.stdout.write("ERR:not-array"); process.exit(0); }
process.stdout.write(JSON.stringify(r));
NODE

# listPrivateRepoNames() reads origin via `git remote get-url origin` with NO cwd
# option (process.cwd()), so the driver must run FROM the repo dir.
run_c8() { # $1 = repo dir ; $2 = log file
    (cd "$1" && C8_LOG="$2" run_with_timeout 20 node "$C8_DRIVER" "$IPR_JS" 2>/dev/null)
}

C8_REPO_GL=$(setup_repo_with_origin "git@gitlab.com:acme/widgets.git")
C8_REPO_GH=$(setup_repo_with_origin "git@github.com:acme/widgets.git")

C8_GL_LOG="$TMPROOT/c8-gl.log"; : > "$C8_GL_LOG"
assert_eq "C8/gitlab origin routes listPrivateRepoNames -> codehostGitlab (glab list)" \
    '["gitlab-only/repo"]' "$(run_c8 "$C8_REPO_GL" "$C8_GL_LOG")"
if grep -q "glab" "$C8_GL_LOG" 2>/dev/null; then
    pass "C8b/gitlab origin actually consulted glab (not gh)"
else
    fail "C8b/gitlab origin actually consulted glab — log=[$(cat "$C8_GL_LOG" 2>/dev/null)]"
fi

C8_GH_LOG="$TMPROOT/c8-gh.log"; : > "$C8_GH_LOG"
assert_eq "C8c/github origin routes listPrivateRepoNames -> codehostGithub (gh list)" \
    '["github-only/repo"]' "$(run_c8 "$C8_REPO_GH" "$C8_GH_LOG")"

# ============================================================================
# C6: readGitlabHostConfig() .env vs process.env precedence CONFLICT
# ============================================================================
echo ""
echo "=== C6: readGitlabHostConfig() .env-vs-process.env precedence ==="

# forge-router.js readGitlabHostConfig(): .env FORGE_GITLAB_HOST wins; process.env
# is only the fallback. C4d covered .env-only; C6 pins the CONFLICT (both set to
# different hosts) proving the .env value is the one used.
C6_DRIVER="$TMPROOT/c6-host-precedence-driver.js"
cat > "$C6_DRIVER" <<'NODE'
"use strict";
let m;
try { m = require(process.argv[2]); } catch (e) { process.stdout.write("ERR:require"); process.exit(0); }
if (typeof m.readGitlabHostConfig !== "function") { process.stdout.write("ERR:not-a-function"); process.exit(0); }
let r;
try { r = m.readGitlabHostConfig(); } catch (e) { process.stdout.write("ERR:threw:" + e.message); process.exit(0); }
process.stdout.write(r === null || r === undefined ? "null" : String(r));
NODE

C6_NEUTRAL="$TMPROOT/c6-neutral"; mkdir -p "$C6_NEUTRAL"
# Config dir whose .env declares a host; a DIFFERENT host is exported in process.env.
C6_CFG="$TMPROOT/c6-cfg"; mkdir -p "$C6_CFG"
printf 'FORGE_GITLAB_HOST=gitlab.fromenvfile.example.com\n' > "$C6_CFG/.env"
# Control config dir whose .env omits the key (process.env is then the only source).
C6_CFG_EMPTY="$TMPROOT/c6-cfg-empty"; mkdir -p "$C6_CFG_EMPTY"
printf '# no forge host declared here\n' > "$C6_CFG_EMPTY/.env"

# Both sources set, different values -> .env wins (value is lowercased by the impl).
C6_CONFLICT="$(cd "$C6_NEUTRAL" && FORGE_GITLAB_HOST=gitlab.fromprocessenv.example.com AGENTS_CONFIG_DIR="$(nodepath "$C6_CFG")" \
    run_with_timeout 20 node "$C6_DRIVER" "$FORGE_ROUTER_JS" 2>/dev/null)"
assert_eq "C6/readGitlabHostConfig .env wins over process.env on conflict" \
    "gitlab.fromenvfile.example.com" "$C6_CONFLICT"

# Control: .env has no key, process.env set -> process.env value is the fallback.
C6_FALLBACK="$(cd "$C6_NEUTRAL" && FORGE_GITLAB_HOST=gitlab.fromprocessenv.example.com AGENTS_CONFIG_DIR="$(nodepath "$C6_CFG_EMPTY")" \
    run_with_timeout 20 node "$C6_DRIVER" "$FORGE_ROUTER_JS" 2>/dev/null)"
assert_eq "C6b/readGitlabHostConfig falls back to process.env when .env omits the key" \
    "gitlab.fromprocessenv.example.com" "$C6_FALLBACK"

finish
