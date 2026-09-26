#!/bin/bash
# Tests: hooks/lib/parse-remote-url.js, hooks/lib/forge/gitlab.js, hooks/lib/forge-router.js, hooks/lib/is-private-repo.js, bin/detect-forge-type
# Tags: scope:issue-specific, gitlab, forge, security, path-traversal, TL2
set -u

# Issue #2308 — Groups A/B/C of the split gitlab-forge suite: resolveForgeTarget
# / extractProjectPath + the detect-forge-type CLI (A), codehostGitlab methods
# with mocked glab (B), and is-private-repo.js forge dispatch (C). C6 [HIGH]
# pins the path-traversal / bad-charset reject invariant on the GitLab project
# path. TDD: targeted symbols do not exist yet, so cases FAIL now, green once
# #2308 lands. glab is mocked (node wrapper on PATH); no real forge API is hit.
#
# # TL3 gap
#   - Real `glab api` against live GitLab (auth, server-side jq) not exercised.

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# Group A: resolveForgeTarget + extractProjectPath (parse-remote-url.js) and the
# bin/detect-forge-type CLI. detectForgeType() host classification is already
# covered by tests/fix-1899-parse-remote-url/detect-forge-type.sh; this group
# targets the NEW resolveForgeTarget/extractProjectPath and the NEW CLI.
echo "=== Group A: resolveForgeTarget / extractProjectPath / detect-forge-type CLI ==="

# call_resolve <url> <gitlabHost|__NONE__> -> "type|host|project" or ERR:<what>
call_resolve() {
    run_with_timeout 20 node -e '
const p = process.argv[1];
const url = process.argv[2];
let gh = process.argv[3];
if (gh === "__NONE__") gh = undefined;
let m;
try { m = require(p); } catch (e) { process.stdout.write("ERR:require"); process.exit(0); }
if (typeof m.resolveForgeTarget !== "function") { process.stdout.write("ERR:not-a-function"); process.exit(0); }
let r;
try { r = m.resolveForgeTarget(url, { gitlabHost: gh }); } catch (e) { process.stdout.write("ERR:threw"); process.exit(0); }
if (!r || typeof r !== "object") { process.stdout.write("ERR:not-an-object"); process.exit(0); }
process.stdout.write(String(r.type) + "|" + String(r.host) + "|" + String(r.project));
' "$PRU_JS" "$1" "$2" 2>/dev/null
}

# call_project <url> -> extractProjectPath(url) or ERR:<what>
call_project() {
    run_with_timeout 20 node -e '
const p = process.argv[1];
let m;
try { m = require(p); } catch (e) { process.stdout.write("ERR:require"); process.exit(0); }
if (typeof m.extractProjectPath !== "function") { process.stdout.write("ERR:not-a-function"); process.exit(0); }
let r;
try { r = m.extractProjectPath(process.argv[2]); } catch (e) { process.stdout.write("ERR:threw"); process.exit(0); }
process.stdout.write(r === null || r === undefined ? "null" : String(r));
' "$PRU_JS" "$1" 2>/dev/null
}

# A safe reject is null (returned) or ERR:threw (raised) from a REAL impl. A
# missing symbol (ERR:not-a-function / ERR:require) or a returned path string is
# NOT a reject, so it fails — keeping the C6 cases RED until #2308 lands.
assert_project_rejected() {
    local name="$1" got="$2"
    case "$got" in
        null|ERR:threw) pass "$name" ;;
        *) fail "$name — expected null or ERR:threw (safe reject), got: $got" ;;
    esac
}

case_begin "resolve-gitlab-com-url" "hooks/lib/parse-remote-url.js"
# A1: gitlab.com URL -> type=gitlab, host=gitlab.com, project=acme/widgets
assert_eq "A1/gitlab.com -> gitlab + project" "gitlab|gitlab.com|acme/widgets" \
    "$(call_resolve 'https://gitlab.com/acme/widgets.git' '__NONE__')"
case_end

case_begin "resolve-custom-host-option" "hooks/lib/parse-remote-url.js"
# A2: GITLAB_HOSTNAME override (gitlabHost option) resolves a custom host.
assert_eq "A2/custom host + gitlabHost override -> gitlab" "gitlab|gitlab.example.com|team/app" \
    "$(call_resolve 'https://gitlab.example.com/team/app.git' 'gitlab.example.com')"
case_end

case_begin "resolve-unknown-host-no-option" "hooks/lib/parse-remote-url.js"
# A3: unknown host with NO gitlabHost -> unknown (NO silent github fallback).
assert_eq "A3/unknown host, no override -> unknown" "unknown" \
    "$(call_resolve 'https://gitlab.example.com/team/app.git' '__NONE__' | cut -d'|' -f1)"
case_end

case_begin "resolve-github-com-url" "hooks/lib/parse-remote-url.js"
# A4: github.com URL -> github (unchanged behavior).
assert_eq "A4/github.com -> github" "github|github.com|acme/widgets" \
    "$(call_resolve 'https://github.com/acme/widgets.git' '__NONE__')"
case_end

case_begin "resolve-subgroup-project-path" "hooks/lib/parse-remote-url.js"
# A5: subgroup (multi-segment) project path preserved.
assert_eq "A5/subgroup project multi-segment" "gitlab|gitlab.com|group/sub/repo" \
    "$(call_resolve 'https://gitlab.com/group/sub/repo.git' '__NONE__')"
assert_eq "A5b/extractProjectPath multi-segment" "group/sub/repo" \
    "$(call_project 'https://gitlab.com/group/sub/repo.git')"
case_end

case_begin "reject-invalid-project-paths" "hooks/lib/parse-remote-url.js"
# C6 [HIGH]: extractProjectPath / resolveForgeTarget must REJECT dot-segment,
# out-of-charset, and under-length project paths before they reach
# `glab api projects/<path>` interpolation (the GitLab twin of the #1899 F1
# owner/repo charset invariant). A1/A5b above are the accept counterparts, so
# this narrowing cannot over-tighten a legitimate namespace/project path.
assert_project_rejected "C6/project dot-dot segment rejected" \
    "$(call_project 'https://gitlab.com/../evil/repo')"
assert_project_rejected "C6b/project percent-encoded NUL rejected" \
    "$(call_project 'https://gitlab.com/a%00b/repo')"
assert_project_rejected "C6c/project single-segment (<2) rejected" \
    "$(call_project 'https://gitlab.com/single-segment')"
assert_project_rejected "C6d/project shell-metachar segment rejected" \
    "$(call_project 'https://gitlab.com/a;rm -rf /b/c')"
# A poisoned dot-segment path must not resolve to a gitlab target (would be
# interpolated into a glab call); it degrades to unknown, never dispatched.
assert_eq "C6e/resolveForgeTarget dot-segment path -> unknown (no glab dispatch)" "unknown" \
    "$(call_resolve 'https://gitlab.com/./etc/passwd.git' '__NONE__' | cut -d'|' -f1)"
case_end

# bin/detect-forge-type CLI (A6-A8): reads origin from CWD, prints {type,host,project}.
# When ghost is not __NONE__, writes a temp .env so readEffectiveEnvFile() (which
# prefers AGENTS_CONFIG_DIR/.env over process.env) sees the intended GITLAB_HOSTNAME.
cli_type() {
    local repo="$1" ghost="$2" out cli_cfg
    if [ ! -f "$DETECT_CLI" ]; then printf 'ERR:no-cli'; return 0; fi
    if [ "$ghost" = "__NONE__" ]; then
        out=$(cd "$repo" && run_with_timeout 20 node "$DETECT_CLI" 2>/dev/null)
    else
        cli_cfg="$(mktemp -d)"
        printf 'GITLAB_HOSTNAME=%s\n' "$ghost" > "$cli_cfg/.env"
        out=$(cd "$repo" && AGENTS_CONFIG_DIR="$(nodepath "$cli_cfg")" run_with_timeout 20 node "$DETECT_CLI" 2>/dev/null)
        rm -rf "$cli_cfg" 2>/dev/null || true
    fi
    printf '%s' "$out" | run_with_timeout 20 node -e '
let s = ""; process.stdin.on("data", (d) => (s += d)); process.stdin.on("end", () => {
  try { const j = JSON.parse(s); process.stdout.write(String(j.type)); }
  catch (e) { process.stdout.write("ERR:unparsable"); }
});' 2>/dev/null
}

REPO_GH=$(setup_repo_with_origin "git@github.com:acme/widgets.git")
REPO_GL=$(setup_repo_with_origin "git@gitlab.com:acme/widgets.git")
REPO_UNK=$(setup_repo_with_origin "git@bitbucket.org:acme/widgets.git")

case_begin "cli-github-remote-type" "bin/detect-forge-type"
# A6: github remote -> JSON type=github
assert_eq "A6/CLI github remote -> type=github" "github" "$(cli_type "$REPO_GH" '__NONE__')"
case_end
case_begin "cli-gitlab-remote-type" "bin/detect-forge-type"
# A7: gitlab remote -> JSON type=gitlab
assert_eq "A7/CLI gitlab remote -> type=gitlab" "gitlab" "$(cli_type "$REPO_GL" '__NONE__')"
case_end
case_begin "cli-unknown-remote-type" "bin/detect-forge-type"
# A8: unknown remote -> JSON type=unknown, exit 0 (no github fallback)
assert_eq "A8/CLI unknown remote -> type=unknown" "unknown" "$(cli_type "$REPO_UNK" '__NONE__')"
if [ -f "$DETECT_CLI" ]; then
    (cd "$REPO_UNK" && run_with_timeout 20 node "$DETECT_CLI" >/dev/null 2>&1)
    assert_eq "A8b/CLI unknown remote exits 0" "0" "$?"
else
    fail "A8b/CLI unknown remote exits 0 — bin/detect-forge-type not found (pre-impl)"
fi
case_end

# cli_json <repo> <gitlabHost|__NONE__> -> "type|host|project" from the CLI's
# full JSON output (C5: A6-A8 only checked .type, never host/project).
# Same .env isolation as cli_type: writes a temp cfg so AGENTS_CONFIG_DIR picks up
# the intended GITLAB_HOSTNAME from the file rather than the developer's real .env.
cli_json() {
    local repo="$1" ghost="$2" out cli_cfg
    if [ ! -f "$DETECT_CLI" ]; then printf 'ERR:no-cli'; return 0; fi
    if [ "$ghost" = "__NONE__" ]; then
        out=$(cd "$repo" && run_with_timeout 20 node "$DETECT_CLI" 2>/dev/null)
    else
        cli_cfg="$(mktemp -d)"
        printf 'GITLAB_HOSTNAME=%s\n' "$ghost" > "$cli_cfg/.env"
        out=$(cd "$repo" && AGENTS_CONFIG_DIR="$(nodepath "$cli_cfg")" run_with_timeout 20 node "$DETECT_CLI" 2>/dev/null)
        rm -rf "$cli_cfg" 2>/dev/null || true
    fi
    printf '%s' "$out" | run_with_timeout 20 node -e '
let s = ""; process.stdin.on("data", (d) => (s += d)); process.stdin.on("end", () => {
  try { const j = JSON.parse(s); process.stdout.write(String(j.type) + "|" + String(j.host) + "|" + String(j.project)); }
  catch (e) { process.stdout.write("ERR:unparsable"); }
});' 2>/dev/null
}

case_begin "cli-full-json-output" "bin/detect-forge-type"
# C5: full {type,host,project} JSON from the CLI (not just .type).
REPO_GL_SUB=$(setup_repo_with_origin "git@gitlab.com:group/sub/repo.git")
REPO_GL_SELF=$(setup_repo_with_origin "git@gitlab.example.com:team/app.git")

assert_eq "C5/CLI github full JSON (host+project)" "github|github.com|acme/widgets" \
    "$(cli_json "$REPO_GH" '__NONE__')"
assert_eq "C5b/CLI gitlab.com subgroup full JSON" "gitlab|gitlab.com|group/sub/repo" \
    "$(cli_json "$REPO_GL_SUB" '__NONE__')"
assert_eq "C5c/CLI self-hosted gitlab full JSON (GITLAB_HOSTNAME)" "gitlab|gitlab.example.com|team/app" \
    "$(cli_json "$REPO_GL_SELF" 'gitlab.example.com')"
case_end

case_begin "resolve-gitlab-hostname-env" "hooks/lib/parse-remote-url.js"
# C4: GITLAB_HOSTNAME .env SSOT — both the parse-remote-url lib (via the env,
# NOT an explicit gitlabHost option) and the detect-forge-type CLI resolve the
# SAME self-hosted origin to gitlab. A2 only exercised the explicit option; this
# proves the env-var path (what .env actually feeds) is wired identically.
call_resolve_env() {
    GITLAB_HOSTNAME="$2" run_with_timeout 20 node -e '
const p = process.argv[1];
const url = process.argv[2];
let m;
try { m = require(p); } catch (e) { process.stdout.write("ERR:require"); process.exit(0); }
if (typeof m.resolveForgeTarget !== "function") { process.stdout.write("ERR:not-a-function"); process.exit(0); }
let r;
try { r = m.resolveForgeTarget(url, {}); } catch (e) { process.stdout.write("ERR:threw"); process.exit(0); }
if (!r || typeof r !== "object") { process.stdout.write("ERR:not-an-object"); process.exit(0); }
process.stdout.write(String(r.type) + "|" + String(r.host) + "|" + String(r.project));
' "$PRU_JS" "$1" 2>/dev/null
}

assert_eq "C4/resolveForgeTarget reads GITLAB_HOSTNAME env (no option)" "gitlab|gitlab.example.com|team/app" \
    "$(call_resolve_env 'https://gitlab.example.com/team/app.git' 'gitlab.example.com')"
case_end
# Same origin + same env var through the CLI (SSOT: one variable, both consumers).
assert_eq "C4b/detect-forge-type CLI reads the same GITLAB_HOSTNAME" "gitlab" \
    "$(cli_type "$REPO_GL_SELF" 'gitlab.example.com')"

case_begin "is-private-repo-self-hosted-gitlab" "hooks/lib/is-private-repo.js"
# C4c: is-private-repo.js dispatches a self-hosted gitlab origin (recognized via
# GITLAB_HOSTNAME) to codehostGitlab — proven by glab reporting PUBLIC → false,
# NOT the non-github fail-safe hardcoded true. spawnSync is monkeypatched in-proc
# (Windows-safe); git is delegated to the real binary; only glab is faked.
IPR_ENV_DRIVER="$TMPROOT/ipr-env-driver.js"
cat > "$IPR_ENV_DRIVER" <<'NODE'
"use strict";
const cp = require("child_process");
const realSpawn = cp.spawnSync.bind(cp);
cp.spawnSync = function (cmd, args, opts) {
  const joined = (args || []).join(" ");
  const isGlab = cmd === "glab" || /glab/.test(String(cmd)) || /\bapi\b/.test(joined);
  if (!isGlab) return realSpawn(cmd, args, opts);
  // glab reports the project as PUBLIC (visibility=public / "false").
  if (/--jq/.test(joined)) return { status: 0, stdout: "public\n", stderr: "", error: null };
  return { status: 0, stdout: JSON.stringify({ visibility: "public" }) + "\n", stderr: "", error: null };
};
let ipr;
try { ipr = require(process.argv[2]).isPrivateRepo; } catch (e) { process.stdout.write("ERR:require"); process.exit(0); }
if (typeof ipr !== "function") { process.stdout.write("ERR:not-a-function"); process.exit(0); }
let r;
try { r = ipr(process.argv[3]); } catch (e) { process.stdout.write("ERR:threw:" + e.message); process.exit(0); }
process.stdout.write(String(r));
NODE
# Use a temp cfg dir so readGitlabHostConfig() reads GITLAB_HOSTNAME from .env
# (AGENTS_CONFIG_DIR/.env wins over process.env; the developer's real .env must
# not interfere with the fixture hostname gitlab.example.com).
C4C_CFG="$TMPROOT/c4c-cfg"; mkdir -p "$C4C_CFG"
printf 'GITLAB_HOSTNAME=gitlab.example.com\n' > "$C4C_CFG/.env"
c4c=$(AGENTS_CONFIG_DIR="$(nodepath "$C4C_CFG")" run_with_timeout 20 node "$IPR_ENV_DRIVER" "$IPR_JS" "$REPO_GL_SELF" 2>/dev/null)
assert_eq "C4c/isPrivateRepo self-hosted gitlab + glab public -> false (dispatch)" "false" "$c4c"
case_end

case_begin "is-private-repo-reads-env-file" "hooks/lib/is-private-repo.js"
# C4d: isPrivateRepo reads GITLAB_HOSTNAME from a .env FILE (not process.env).
# readGitlabHostConfig() prefers .env over process.env; this case proves the .env
# priority path works end-to-end: no env var set, only .env declares the host.
# The mock glab returns "public" → isPrivateRepo returns false (proves dispatch
# reached glab rather than failing over to the hardcoded fail-safe true).
C4D_ROOT="$TMPROOT/c4d-root"
mkdir -p "$C4D_ROOT"
printf 'GITLAB_HOSTNAME=gitlab.mycompany.com\n' > "$C4D_ROOT/.env"
# Repo with origin pointing at the self-hosted host declared in the .env above.
C4D_REPO=$(setup_repo_with_origin "git@gitlab.mycompany.com:team/app.git")
IPR_FILE_DRIVER="$TMPROOT/ipr-file-driver.js"
cat > "$IPR_FILE_DRIVER" <<'NODE'
"use strict";
// process.argv[2] = IPR module path, process.argv[3] = repoDir.
// Run from $C4D_ROOT so readGitlabHostConfig() picks up ./.env via process.cwd().
const cp = require("child_process");
const realSpawn = cp.spawnSync.bind(cp);
cp.spawnSync = function (cmd, args, opts) {
  const joined = (args || []).join(" ");
  const isGlab = cmd === "glab" || /glab/.test(String(cmd)) || /\bapi\b/.test(joined);
  if (!isGlab) return realSpawn(cmd, args, opts);
  if (/--jq/.test(joined)) return { status: 0, stdout: "public\n", stderr: "", error: null };
  return { status: 0, stdout: JSON.stringify({ visibility: "public" }) + "\n", stderr: "", error: null };
};
let ipr;
try { ipr = require(process.argv[2]).isPrivateRepo; } catch (e) { process.stdout.write("ERR:require"); process.exit(0); }
if (typeof ipr !== "function") { process.stdout.write("ERR:not-a-function"); process.exit(0); }
let r;
try { r = ipr(process.argv[3]); } catch (e) { process.stdout.write("ERR:threw:" + e.message); process.exit(0); }
process.stdout.write(String(r));
NODE
# Run from C4D_ROOT with GITLAB_HOSTNAME unset so only the .env feeds the host.
C4D_SCRIPT="$TMPROOT/c4d-run.sh"
# AGENTS_CONFIG_DIR must point at C4D_ROOT so readDefaultEnvFile() reads
# C4D_ROOT/.env; GITLAB_HOSTNAME is explicitly unset from process.env.
printf '#!/bin/bash\ncd "%s" && unset GITLAB_HOSTNAME && AGENTS_CONFIG_DIR="%s" node "%s" "%s" "%s"\n' \
    "$C4D_ROOT" "$C4D_ROOT" "$(nodepath "$IPR_FILE_DRIVER")" "$(nodepath "$IPR_JS")" "$(nodepath "$C4D_REPO")" > "$C4D_SCRIPT"
chmod +x "$C4D_SCRIPT"
c4d=$(run_with_timeout 20 bash "$C4D_SCRIPT" 2>/dev/null)
assert_eq "C4d/isPrivateRepo reads host from .env file (not process.env), glab public -> false" "false" "$c4d"
case_end

# C4e: resolveForgeTarget recognizes GITLAB_SSH_HOSTNAME env var as a GitLab
# forge host when no gitlabHost option is passed. This proves the 案1 SSH-hostname
# path: a repo cloned via SSH from a host different from GITLAB_HOSTNAME is still
# classified as gitlab when GITLAB_SSH_HOSTNAME is set.
call_resolve_ssh_env() {
    GITLAB_SSH_HOSTNAME="$2" run_with_timeout 20 node -e '
const p = process.argv[1];
const url = process.argv[2];
let m;
try { m = require(p); } catch (e) { process.stdout.write("ERR:require"); process.exit(0); }
if (typeof m.resolveForgeTarget !== "function") { process.stdout.write("ERR:not-a-function"); process.exit(0); }
let r;
try { r = m.resolveForgeTarget(url, {}); } catch (e) { process.stdout.write("ERR:threw"); process.exit(0); }
if (!r || typeof r !== "object") { process.stdout.write("ERR:not-an-object"); process.exit(0); }
process.stdout.write(String(r.type) + "|" + String(r.host) + "|" + String(r.project));
' "$PRU_JS" "$1" 2>/dev/null
}
case_begin "resolve-gitlab-ssh-hostname-env" "hooks/lib/parse-remote-url.js"
assert_eq "C4e/resolveForgeTarget reads GITLAB_SSH_HOSTNAME env (SSH remote, no option)" "gitlab|git.mycompany.com|team/app" \
    "$(call_resolve_ssh_env 'git@git.mycompany.com:team/app.git' 'git.mycompany.com')"
case_end

case_begin "cli-gitlab-ssh-hostname-routing" "bin/detect-forge-type"
# C4f: detect-forge-type CLI classifies an SSH remote via GITLAB_SSH_HOSTNAME.
REPO_GL_SSH=$(setup_repo_with_origin "git@git.mycompany.com:team/app.git")
cli_type_ssh() {
    local repo="$1" shost="$2" out cli_cfg
    if [ ! -f "$DETECT_CLI" ]; then printf 'ERR:no-cli'; return 0; fi
    cli_cfg="$(mktemp -d)"
    printf 'GITLAB_SSH_HOSTNAME=%s\n' "$shost" > "$cli_cfg/.env"
    out=$(cd "$repo" && AGENTS_CONFIG_DIR="$(nodepath "$cli_cfg")" run_with_timeout 20 node "$DETECT_CLI" 2>/dev/null)
    rm -rf "$cli_cfg" 2>/dev/null || true
    printf '%s' "$out" | run_with_timeout 20 node -e '
let s = ""; process.stdin.on("data", (d) => (s += d)); process.stdin.on("end", () => {
  try { process.stdout.write(String(JSON.parse(s).type)); }
  catch (e) { process.stdout.write("ERR:unparsable"); }
});' 2>/dev/null
}
assert_eq "C4f/CLI classifies SSH remote via GITLAB_SSH_HOSTNAME" "gitlab" \
    "$(cli_type_ssh "$REPO_GL_SSH" 'git.mycompany.com')"
case_end

# Group B: codehostGitlab (forge/gitlab.js) with mocked glab.
echo ""
echo "=== Group B: codehostGitlab methods (mocked glab) ==="

case_begin "codehost-gitlab-api-parity" "hooks/lib/forge/gitlab.js"
# B1: API parity — codehostGitlab exposes the same 4 methods as codehostGithub.
b1=$(run_with_timeout 20 node -e '
const need = ["isPrivateRepo", "shouldScanAsPublicTarget", "listPrivateRepoNames", "hasOpenPrForBranch"];
let gl, gh;
try { gl = require(process.argv[1]).codehostGitlab; } catch (e) { process.stdout.write("ERR:require-gitlab"); process.exit(0); }
try { gh = require(process.argv[2]).codehostGithub; } catch (e) { process.stdout.write("ERR:require-github"); process.exit(0); }
if (!gl) { process.stdout.write("ERR:no-codehostGitlab"); process.exit(0); }
const missing = need.filter((m) => typeof gl[m] !== "function" || typeof gh[m] !== "function");
process.stdout.write(missing.length === 0 ? "parity" : "missing:" + missing.join(","));
' "$GITLAB_JS" "$GITHUB_JS" 2>/dev/null)
assert_eq "B1/codehostGitlab has 4-method parity with codehostGithub" "parity" "$b1"
case_end

# call_codehost_bool <method> <arg> -> "true"/"false"/ERR, with glab on PATH.
call_codehost_bool() {
    PATH="$MOCK_BIN:$PATH" run_with_timeout 20 node -e '
let gl;
try { gl = require(process.argv[1]).codehostGitlab; } catch (e) { process.stdout.write("ERR:require"); process.exit(0); }
if (!gl || typeof gl[process.argv[2]] !== "function") { process.stdout.write("ERR:no-method"); process.exit(0); }
let r;
try { r = gl[process.argv[2]](process.argv[3]); } catch (e) { process.stdout.write("ERR:threw"); process.exit(0); }
process.stdout.write(String(r));
' "$GITLAB_JS" "$1" "$2" 2>/dev/null
}

case_begin "codehost-gitlab-is-private" "hooks/lib/forge/gitlab.js"
# B2: isPrivateRepo — glab reports private -> true.
GLAB_MOCK_VISIBILITY=private
export GLAB_MOCK_VISIBILITY
assert_eq "B2/isPrivateRepo private -> true" "true" \
    "$(call_codehost_bool isPrivateRepo 'https://gitlab.com/acme/widgets.git')"
case_end

case_begin "codehost-gitlab-is-public" "hooks/lib/forge/gitlab.js"
# B3: isPrivateRepo — glab reports public -> false.
GLAB_MOCK_VISIBILITY=public
export GLAB_MOCK_VISIBILITY
assert_eq "B3/isPrivateRepo public -> false" "false" \
    "$(call_codehost_bool isPrivateRepo 'https://gitlab.com/acme/widgets.git')"
case_end

case_begin "codehost-gitlab-scan-public-target" "hooks/lib/forge/gitlab.js"
# B4: shouldScanAsPublicTarget == !isPrivateRepo.
GLAB_MOCK_VISIBILITY=public
export GLAB_MOCK_VISIBILITY
assert_eq "B4/shouldScanAsPublicTarget public -> true" "true" \
    "$(call_codehost_bool shouldScanAsPublicTarget 'https://gitlab.com/acme/widgets.git')"
GLAB_MOCK_VISIBILITY=private
export GLAB_MOCK_VISIBILITY
assert_eq "B4b/shouldScanAsPublicTarget private -> false" "false" \
    "$(call_codehost_bool shouldScanAsPublicTarget 'https://gitlab.com/acme/widgets.git')"
case_end

case_begin "codehost-gitlab-open-mr" "hooks/lib/forge/gitlab.js"
# B5: hasOpenPrForBranch — open MR found -> true.
GLAB_MOCK_MR=open
export GLAB_MOCK_MR
assert_eq "B5/hasOpenPrForBranch open MR -> true" "true" \
    "$(call_codehost_bool hasOpenPrForBranch "$REPO_GL")"
case_end

case_begin "codehost-gitlab-no-mr" "hooks/lib/forge/gitlab.js"
# B6: hasOpenPrForBranch — no open MR -> false.
GLAB_MOCK_MR=none
export GLAB_MOCK_MR
assert_eq "B6/hasOpenPrForBranch no MR -> false" "false" \
    "$(call_codehost_bool hasOpenPrForBranch "$REPO_GL")"
unset GLAB_MOCK_MR GLAB_MOCK_VISIBILITY
case_end

# C1: listPrivateRepoNames — must query glab for PRIVATE repos only and return
# the parsed path list (subgroup paths preserved), [] on empty, [] on error.
# spawnSync is monkeypatched: canned stdout keyed by CG_MODE, every glab argv
# logged so the private-only query is asserted. Windows-safe.
CG_DRIVER="$TMPROOT/cg-list-driver.js"
cat > "$CG_DRIVER" <<'NODE'
"use strict";
const cp = require("child_process");
const fs = require("fs");
const realSpawn = cp.spawnSync.bind(cp);
const LOG = process.env.CG_LOG;
const MODE = process.env.CG_MODE; // list3 | empty | error
cp.spawnSync = function (cmd, args, opts) {
  const joined = (args || []).join(" ");
  const isGlab = cmd === "glab" || /glab/.test(String(cmd)) || (cmd === "bash" && /glab/.test(joined));
  if (!isGlab) return realSpawn(cmd, args, opts);
  if (LOG) { try { fs.appendFileSync(LOG, String(cmd) + " " + joined + "\n"); } catch (e) {} }
  if (MODE === "error") return { status: 1, stdout: "", stderr: "boom", error: null };
  if (MODE === "empty") return { status: 0, stdout: "", stderr: "", error: null };
  // Three private projects incl. a subgroup path; trailing blank line on purpose
  // (the parser must trim/filter it, like the github side does).
  return { status: 0, stdout: "acme/widgets\ngroup/sub/repo\nteam/app\n\n", stderr: "", error: null };
};
let gl;
try { gl = require(process.argv[2]).codehostGitlab; } catch (e) { process.stdout.write("ERR:require"); process.exit(0); }
if (!gl || typeof gl.listPrivateRepoNames !== "function") { process.stdout.write("ERR:no-method"); process.exit(0); }
let r;
try { r = gl.listPrivateRepoNames(); } catch (e) { process.stdout.write("ERR:threw:" + e.message); process.exit(0); }
if (!Array.isArray(r)) { process.stdout.write("ERR:not-array"); process.exit(0); }
process.stdout.write(JSON.stringify(r));
NODE
run_cg() { # $1 = mode ; $2 = log file ; echoes the JSON array (or ERR:*)
    CG_MODE="$1" CG_LOG="$2" run_with_timeout 20 node "$CG_DRIVER" "$GITLAB_JS" 2>/dev/null
}
case_begin "codehost-gitlab-list-private-repos" "hooks/lib/forge/gitlab.js"
CG_LIST3_LOG="$TMPROOT/cg-list3.log"; : > "$CG_LIST3_LOG"
CG_LIST3="$(run_cg list3 "$CG_LIST3_LOG")"
assert_eq "C1/listPrivateRepoNames parses list + preserves subgroup path" \
    '["acme/widgets","group/sub/repo","team/app"]' "$CG_LIST3"
case_end
case_begin "codehost-gitlab-list-private-query" "hooks/lib/forge/gitlab.js"
# Prove the query asked glab for PRIVATE repos specifically (not all repos).
if grep -qi "private" "$CG_LIST3_LOG" 2>/dev/null; then
    pass "C1b/listPrivateRepoNames issues a private-only query"
else
    fail "C1b/listPrivateRepoNames issues a private-only query — glab-log=[$(cat "$CG_LIST3_LOG" 2>/dev/null)]"
fi
case_end
case_begin "codehost-gitlab-list-private-empty" "hooks/lib/forge/gitlab.js"
case_end
assert_eq "C1c/listPrivateRepoNames empty result -> []" "[]" "$(run_cg empty "$TMPROOT/cg-empty.log")"
case_begin "codehost-gitlab-list-private-error" "hooks/lib/forge/gitlab.js"
case_end
assert_eq "C1d/listPrivateRepoNames glab error -> [] (safe)" "[]" "$(run_cg error "$TMPROOT/cg-error.log")"

# C2: hasOpenPrForBranch must target the CURRENT branch — an MR on the checked-out
# branch is reused; an MR that exists only for a DIFFERENT branch is ignored. The
# driver resolves the branch glab would infer (explicit --source-branch, else the
# repo's current branch via real git) and returns an OPEN MR only when that branch
# is in CB_MR_BRANCHES. Catches a hardcoded/wrong-branch query B5/B6 could not.
CB_DRIVER="$TMPROOT/cb-branch-driver.js"
cat > "$CB_DRIVER" <<'NODE'
"use strict";
const cp = require("child_process");
const fs = require("fs");
const realSpawn = cp.spawnSync.bind(cp);
const LOG = process.env.CB_LOG;
const MR_BRANCHES = (process.env.CB_MR_BRANCHES || "").split(/\s+/).filter(Boolean);
cp.spawnSync = function (cmd, args, opts) {
  const joined = (args || []).join(" ");
  const isMrQuery = /\bmr\b/.test(joined);
  if (!isMrQuery) return realSpawn(cmd, args, opts); // real git (branch inference), glab locate, etc.
  let branch = null;
  const m = joined.match(/--source-branch[ =]([^ "']+)/);
  if (m) branch = m[1];
  if (!branch) {
    const g = realSpawn("git", ["rev-parse", "--abbrev-ref", "HEAD"], { cwd: opts && opts.cwd, encoding: "utf8" });
    branch = (g.stdout || "").trim();
  }
  if (LOG) { try { fs.appendFileSync(LOG, "MRQUERY " + joined + " :: branch=" + branch + "\n"); } catch (e) {} }
  if (MR_BRANCHES.indexOf(branch) >= 0) return { status: 0, stdout: "opened\n", stderr: "", error: null };
  return { status: 1, stdout: "", stderr: "", error: null }; // glab mr view: no MR for this branch
};
let gl;
try { gl = require(process.argv[2]).codehostGitlab; } catch (e) { process.stdout.write("ERR:require"); process.exit(0); }
if (!gl || typeof gl.hasOpenPrForBranch !== "function") { process.stdout.write("ERR:no-method"); process.exit(0); }
let r;
try { r = gl.hasOpenPrForBranch(process.argv[3]); } catch (e) { process.stdout.write("ERR:threw:" + e.message); process.exit(0); }
process.stdout.write(String(r));
NODE
REPO_GL_BR="$(setup_branch_repo 'git@gitlab.com:acme/widgets.git' 'feature/x')"
run_cb() { # $1 = repo ; $2 = space-separated branches that have an OPEN MR
    CB_MR_BRANCHES="$2" run_with_timeout 20 node "$CB_DRIVER" "$GITLAB_JS" "$1" 2>/dev/null
}
case_begin "codehost-gitlab-mr-current-branch" "hooks/lib/forge/gitlab.js"
# MR exists for the checked-out branch feature/x -> reused -> true.
assert_eq "C2/hasOpenPrForBranch: MR on current branch reused -> true" "true" \
    "$(run_cb "$REPO_GL_BR" "feature/x")"
case_end
case_begin "codehost-gitlab-mr-other-branch" "hooks/lib/forge/gitlab.js"
# MR exists ONLY for a different branch -> current branch has none -> false.
assert_eq "C2b/hasOpenPrForBranch: MR only on other branch ignored -> false" "false" \
    "$(run_cb "$REPO_GL_BR" "other/y")"
case_end
case_begin "codehost-gitlab-mr-none" "hooks/lib/forge/gitlab.js"
# No MR anywhere -> false.
assert_eq "C2c/hasOpenPrForBranch: no MR -> false" "false" \
    "$(run_cb "$REPO_GL_BR" "")"
case_end

# Group C: is-private-repo.js GitLab dispatch. Intentionally NOT appended to
# tests/main-private-repo-detection/unit-is-private-repo.sh — its D1 pins
# gitlab.com -> true (a #2307 pin), conflicting with #2308's gitlab->codehostGitlab
# dispatch. Kept here with a controlled glab mock.
echo ""
echo "=== Group C: is-private-repo.js forge dispatch ==="

run_ipr() {
    PATH="$MOCK_BIN:$PATH" run_with_timeout 20 node -e '
const { isPrivateRepo } = require(process.argv[1]);
console.log(isPrivateRepo(process.argv[2]));
' "$IPR_JS" "$1" 2>/dev/null
}

case_begin "dispatch-gitlab-remote-public" "hooks/lib/is-private-repo.js"
# C1: GitLab remote dispatches to codehostGitlab — NOT a hardcoded true.
# glab reports PUBLIC, so `false` proves the codehostGitlab path ran (old code
# returned true unconditionally for any non-github host).
setup_mock_gh true
GLAB_MOCK_VISIBILITY=public
export GLAB_MOCK_VISIBILITY
assert_eq "C1/gitlab remote + glab public -> false (dispatch, not hardcoded)" "false" \
    "$(run_ipr "$REPO_GL")"
case_begin "dispatch-gitlab-remote-private" "hooks/lib/is-private-repo.js"
GLAB_MOCK_VISIBILITY=private
export GLAB_MOCK_VISIBILITY
assert_eq "C1b/gitlab remote + glab private -> true" "true" "$(run_ipr "$REPO_GL")"
unset GLAB_MOCK_VISIBILITY
case_end

case_begin "dispatch-unknown-host-failsafe" "hooks/lib/is-private-repo.js"
# C2: unknown host -> true (fail-safe maintained).
setup_mock_gh false
assert_eq "C2/unknown host -> true (fail-safe)" "true" "$(run_ipr "$REPO_UNK")"
case_end

case_begin "dispatch-github-remote" "hooks/lib/is-private-repo.js"
# C3: github.com dispatches to codehostGithub (mock gh drives the answer).
setup_mock_gh true
assert_eq "C3/github remote + gh private -> true" "true" "$(run_ipr "$REPO_GH")"
setup_mock_gh false
assert_eq "C3b/github remote + gh public -> false" "false" "$(run_ipr "$REPO_GH")"
case_end
rm -f "$MOCK_BIN/gh" "$MOCK_BIN/gh.cmd"
case_end


finish
