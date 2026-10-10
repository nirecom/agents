#!/bin/bash
# Tests: hooks/lib/forge/gitlab.js, hooks/lib/forge-router.js
# Tags: scope:issue-specific, gitlab, forge, security, visibility, glab-stub, TL2, private-repo-list
set -u
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# Issue #2513 — codehostGitlab.repoVisibility(remoteUrl) -> "public" | "private" |
#   "internal" | null via `glab api projects/<url-encoded path> --jq .visibility`.
#   A glab failure, a timeout, an unknown value or an unresolvable path is null, and an
#   unresolvable path never reaches glab. glab is a PATH stub (tests/lib/cli-stub.sh).

# TL3 gap: a real `glab api` round trip (auth, self-hosted host, 5xx) is not exercised.

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
# shellcheck source=../../lib/cli-stub.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/cli-stub.sh"

FORGE_ROUTER_JS="$(nodepath "$SCRIPT_CHECKOUT_ROOT/hooks/lib/forge-router.js")"
GL_LOG="$TMPROOT/glab-stub.log"
GL_URL="https://gitlab.com/acme/widgets.git"
GL_DRIVER="$TMPROOT/gl-visibility-driver.js"
cat > "$GL_DRIVER" <<'NODE'
"use strict";
// argv: <forge-router.js> <mode> <url>. mode "vis" -> repoVisibility, "pre" -> stub reachability.
const mode = process.argv[3], url = process.argv[4];
if (mode === "pre") {
  const cp = require("child_process"); const o = { encoding: "utf8", windowsHide: true };
  const a = cp.spawnSync("glab", ["api", "x"], o);
  const b = cp.spawnSync("glab", ["api", "x"], Object.assign({ shell: process.platform === "win32" }, o));
  process.stdout.write(a.stdout + "|" + b.stdout); process.exit(0);
}
let v;
try { const d = require(process.argv[2]).resolveCodehostDescriptor(url); v = d.type + ":" + JSON.stringify(d.repoVisibility(url)); }
catch (e) { v = "THREW:" + e.message; }
process.stdout.write(String(v));
NODE

# gl_run <stdout> <rc> <sleep-ms> <mode> <url> <secs>
gl_run() {
    : > "$GL_LOG"
    CLI_STUB_OUT="$1" CLI_STUB_RC="$2" CLI_STUB_SLEEP_MS="$3" CLI_STUB_LOG="$GL_LOG" \
        cli_stub_run run_with_timeout "$6" node "$GL_DRIVER" "$FORGE_ROUTER_JS" "$4" "$5" 2>/dev/null
}
# gl_case <name> <want> <stdout> <rc> <sleep-ms> <url> [secs]
gl_case() {
    if [ -z "${GL_STUB_OK:-}" ]; then fail "$1 — glab stub unreachable; not run so the real glab stays untouched"; return; fi
    assert_eq "$1" "$2" "$(gl_run "$3" "$4" "$5" vis "$6" "${7:-20}")"
}

echo "=== V-GL: codehostGitlab.repoVisibility ==="
case_begin "gitlab-visibility-stub-precondition" "hooks/lib/forge/gitlab.js"
GL_STUB_OK=""
if cli_stub_make "$TMPROOT/glab-stub" glab \
    && [ "$(gl_run STUBOK 0 0 pre x 20)" = "STUBOK|STUBOK" ]; then
    GL_STUB_OK=1; pass "V-GL0 glab stub reached with and without a shell"
else
    fail "V-GL0 glab stub reached with and without a shell"
fi
case_end

case_begin "gitlab-visibility-answers" "hooks/lib/forge/gitlab.js"
gl_case "V-GL1 glab says public -> public" 'gitlab:"public"' $'public\n' 0 0 "$GL_URL"
assert_eq "V-GL2 glab argv is api --hostname gitlab.com projects/acme%2Fwidgets --jq .visibility" \
    "glab api --hostname gitlab.com projects/acme%2Fwidgets --jq .visibility" "$(cat "$GL_LOG" 2>/dev/null)"
gl_case "V-GL3 glab says private -> private" 'gitlab:"private"' $'private\n' 0 0 "$GL_URL"
gl_case "V-GL4 glab says internal -> internal" 'gitlab:"internal"' $'internal\n' 0 0 "$GL_URL"
gl_case "V-GL5 nested namespace, glab says private -> private" 'gitlab:"private"' $'private\n' 0 0 \
    "https://gitlab.com/acme/sub/widgets.git"
assert_eq "V-GL5 nested namespace argv URL-encodes every separator" \
    "glab api --hostname gitlab.com projects/acme%2Fsub%2Fwidgets --jq .visibility" "$(cat "$GL_LOG" 2>/dev/null)"
case_end

case_begin "gitlab-visibility-failures-null" "hooks/lib/forge/gitlab.js"
gl_case "V-GL6 glab exits nonzero (stdout public) -> null" 'gitlab:null' $'public\n' 1 0 "$GL_URL"
gl_case "V-GL7 glab prints an unknown value -> null" 'gitlab:null' $'secret\n' 0 0 "$GL_URL"
gl_case "V-GL8 glab prints nothing -> null" 'gitlab:null' '' 0 0 "$GL_URL"
# The stub answers "public" only after 17s, past the 15s descriptor timeout.
gl_case "V-GL9 glab exceeds the timeout -> null (late public ignored)" 'gitlab:null' $'public\n' 0 17000 "$GL_URL" 45
case_end

case_begin "gitlab-visibility-traversal-null" "hooks/lib/forge/gitlab.js"
# A "." / ".." segment makes the path unresolvable: never a gitlab call, always null.
gl_case "V-GL10 dot-dot path segment -> null" 'unknown:null' $'public\n' 0 0 "https://gitlab.com/acme/../widgets.git"
assert_eq "V-GL10 dot-dot path never reaches glab" "" "$(cat "$GL_LOG" 2>/dev/null)"
case_end

# L-GL contract (#2513): codehostGitlab.listPrivateRepoNames() makes ONE membership listing
#   whose rows are "<visibility>\t<path>"; private and internal rows are kept (any case),
#   public / unknown / malformed rows dropped, deduped first-seen, any failure -> [].
#   spawnSync is monkeypatched (as in C1) so the parsing is judged on canned stdout alone.
LG_DRIVER="$TMPROOT/gl-list-single-driver.js"
cat > "$LG_DRIVER" <<'NODE'
"use strict";
const cp = require("child_process"); const fs = require("fs");
const realSpawn = cp.spawnSync.bind(cp);
const env = process.env;
cp.spawnSync = function (cmd, args, opts) {
  if (!/glab/.test(String(cmd))) return realSpawn(cmd, args, opts);
  if (env.LG_LOG) fs.appendFileSync(env.LG_LOG, "glab " + (args || []).join(" ") + "\n");
  if (env.LG_MODE === "spawn-error") return { status: null, stdout: "", stderr: "", error: new Error("ENOENT") };
  if (env.LG_MODE === "throw") throw new Error("spawn threw");
  return { status: Number(env.LG_RC || 0), stdout: env.LG_OUT || "", stderr: "", error: null };
};
let r;
try { r = require(process.argv[2]).codehostGitlab.listPrivateRepoNames(); } catch (e) { r = "THREW:" + e.message; }
process.stdout.write(JSON.stringify(r));
NODE
LG_LOG="$TMPROOT/gl-list-single.log"
# lg_run <stdout> <rc> [mode]
lg_run() {
    : > "$LG_LOG"
    LG_OUT="$1" LG_RC="$2" LG_MODE="${3:-}" LG_LOG="$LG_LOG" \
        run_with_timeout 20 node "$LG_DRIVER" "$GITLAB_JS" 2>/dev/null
}

echo "=== L-GL: codehostGitlab.listPrivateRepoNames (single membership listing) ==="
case_begin "gitlab-list-private-repo-names-single-listing" "hooks/lib/forge/gitlab.js"
assert_eq "L-GL1 mixed rows -> private + internal kept in order, public dropped" \
    '["acme/priv-a","acme/int-c","group/sub/priv-b"]' \
    "$(lg_run $'private\tacme/priv-a\npublic\tacme/pub\ninternal\tacme/int-c\nprivate\tgroup/sub/priv-b\n' 0)"
assert_eq "L-GL2 exactly one glab spawn per call" "1" "$(grep -c '^glab ' "$LG_LOG" 2>/dev/null)"
LG_SEEN="$(head -n 1 "$LG_LOG" 2>/dev/null | tr -d '"')"
assert_contains "L-GL3 query asks for membership=true" "membership=true" "$LG_SEEN"
assert_contains "L-GL3 query asks for per_page=100" "per_page=100" "$LG_SEEN"
assert_contains "L-GL3 listing is paginated" " --paginate" "$LG_SEEN"
assert_not_contains "L-GL3 query carries no visibility= filter" "visibility=" "$LG_SEEN"
case "$LG_SEEN" in
    *"--jq "*.visibility*.path_with_namespace*@tsv*) pass "L-GL3 jq emits visibility and path_with_namespace as tsv" ;;
    *) fail "L-GL3 jq emits visibility and path_with_namespace as tsv — got: $LG_SEEN" ;;
esac
assert_eq "L-GL4 a path listed twice appears once" '["acme/a","acme/b"]' \
    "$(lg_run $'private\tacme/a\ninternal\tacme/b\nprivate\tacme/a\n' 0)"
case_end

case_begin "gitlab-list-private-repo-names-failure" "hooks/lib/forge/gitlab.js"
assert_eq "L-GL5 glab exits nonzero (stdout has rows) -> []" '[]' "$(lg_run $'private\tacme/priv-a\n' 1)"
assert_eq "L-GL5 spawn error -> []" '[]' "$(lg_run $'private\tacme/priv-a\n' 0 spawn-error)"
assert_eq "L-GL5 spawn throws -> []" '[]' "$(lg_run $'private\tacme/priv-a\n' 0 throw)"
assert_eq "L-GL6 empty output -> []" '[]' "$(lg_run '' 0)"
case_end

case_begin "gitlab-list-private-repo-names-edge-output" "hooks/lib/forge/gitlab.js"
assert_eq "L-GL7 CRLF, blank lines and padding tolerated" '["acme/a","acme/c"]' \
    "$(lg_run $'private\tacme/a\r\n\r\n  internal\tacme/c  \r\n\n' 0)"
assert_eq "L-GL9 malformed rows dropped, subgroup path preserved" '["group/sub/proj","acme/ok"]' \
    "$(lg_run $'acme/no-tab\nprivate\t\nsecret\tacme/unknown\nprivate\tgroup/sub/proj\nPRIVATE\tacme/ok\n' 0)"
case_end

# L-GL10: the listing spawn timeout (4000 ms) stays under the 5 s scan-outbound hook budget.
case_begin "gitlab-list-private-repo-names-spawn-timeout" "hooks/lib/forge/gitlab.js"
assert_eq "L-GL10 listPrivateRepoNames spawns glab with timeout 4000" "glab:4000" \
    "$(run_with_timeout 20 node -e 'const cp = require("child_process"); const seen = [];
cp.spawnSync = (c, a, o) => { seen.push(String(c) + ":" + (o && o.timeout)); return { status: 0, stdout: "", stderr: "", error: null }; };
require(process.argv[1]).codehostGitlab.listPrivateRepoNames(); process.stdout.write(seen.join(","));' \
    "$GITLAB_JS" 2>&1)"
case_end

# L-GL8: the real spawn path (PATH stub, shell on Windows). cmd.exe splits an unquoted `&`
# and pipes on `|`, so the query and the --jq program must each reach glab whole.
case_begin "gitlab-list-private-query-reaches-glab-whole" "hooks/lib/forge/gitlab.js"
if [ -z "${GL_STUB_OK:-}" ]; then fail "L-GL8 glab stub unreachable; not run so the real glab stays untouched"
else
    : > "$GL_LOG"
    LG8_OUT="$(CLI_STUB_OUT=$'private\tacme/x\n' CLI_STUB_RC=0 CLI_STUB_SLEEP_MS=0 CLI_STUB_LOG="$GL_LOG" \
        cli_stub_run run_with_timeout 20 node -e \
        'process.stdout.write(JSON.stringify(require(process.argv[1]).codehostGitlab.listPrivateRepoNames()))' \
        "$GITLAB_JS" 2>/dev/null)"
    LG8_SEEN="$(tr -d '"' < "$GL_LOG" 2>/dev/null)"
    assert_eq "L-GL8 exactly one glab line logged" "1" "$(grep -c '^glab ' "$GL_LOG" 2>/dev/null)"
    assert_contains "L-GL8 query with & reaches glab whole" "projects?membership=true&per_page=100" "$LG8_SEEN"
    assert_contains "L-GL8 --jq program arrives intact" "@tsv" "$LG8_SEEN"
    assert_eq "L-GL8 real spawn parses the tsv row" '["acme/x"]' "$LG8_OUT"
fi
case_end

# H-GL contract (#2513): repoVisibility asks the plan remote's own GitLab instance, so its
#   glab argv carries `--hostname <host>` (lowercased, no userinfo/port) right before
#   projects/<path>. Sibling methods keep their host-less argv (isPrivateRepo gap: follow-up).
HG_DRIVER="$TMPROOT/gl-hostname-driver.js"
cat > "$HG_DRIVER" <<'NODE'
"use strict";
// argv: <gitlab.js> <method> [arg]. Each glab spawn is logged as one JSON argv line.
const cp = require("child_process"); const fs = require("fs");
const realSpawn = cp.spawnSync.bind(cp);
const env = process.env;
cp.spawnSync = function (cmd, args, opts) {
  if (!/glab/.test(String(cmd))) return realSpawn(cmd, args, opts);
  fs.appendFileSync(env.HG_LOG, JSON.stringify(args || []) + "\n");
  if (env.HG_MODE === "spawn-error") return { status: null, stdout: "", stderr: "", error: new Error("ENOENT") };
  return { status: Number(env.HG_RC || 0), stdout: env.HG_OUT || "", stderr: "", error: null };
};
const gl = require(process.argv[2]).codehostGitlab, m = process.argv[3], a = process.argv[4];
let r;
try { r = m === "listPrivateRepoNames" ? gl[m]() : gl[m](a); } catch (e) { r = "THREW:" + e.message; }
process.stdout.write(JSON.stringify(r));
NODE
HG_LOG="$(nodepath "$TMPROOT/gl-hostname.log")"
HG_CWD="$TMPROOT/hg-neutral"; mkdir -p "$HG_CWD"
# AGENTS_MAIN_ROOT/.env wins over process.env, so each fixture cfg pins the host exactly.
HG_CFG_SELF="$TMPROOT/hg-cfg-self"; mkdir -p "$HG_CFG_SELF"
printf 'GITLAB_HOSTNAME=gitlab.example.com\n' > "$HG_CFG_SELF/.env"
HG_CFG_NONE="$TMPROOT/hg-cfg-none"; mkdir -p "$HG_CFG_NONE"
printf '# no forge host declared here\n' > "$HG_CFG_NONE/.env"
# hg_run <cfgdir> <stdout> <rc> <mode> <method> [arg]
hg_run() {
    : > "$HG_LOG"
    (cd "$HG_CWD" && unset GITLAB_HOSTNAME GITLAB_SSH_HOSTNAME \
        && AGENTS_MAIN_ROOT="$(nodepath "$1")" HG_LOG="$HG_LOG" HG_OUT="$2" HG_RC="$3" HG_MODE="$4" \
        run_with_timeout 20 node "$HG_DRIVER" "$GITLAB_JS" "$5" "${6:-}" 2>/dev/null)
}
hg_log() { cat "$HG_LOG" 2>/dev/null; }

echo "=== H-GL: repoVisibility targets the remote's own host (--hostname) ==="
# id|cfg|remote|expected --hostname value
HG_ROWS=(
    "H-GL1 self-hosted ssh remote|$HG_CFG_SELF|git@gitlab.example.com:team/plans.git|gitlab.example.com"
    "H-GL2 gitlab.com https remote|$HG_CFG_NONE|https://gitlab.com/team/plans.git|gitlab.com"
    "H-GL3 https userinfo+port stripped|$HG_CFG_SELF|https://user:tok@gitlab.example.com:8443/team/plans.git|gitlab.example.com"
    "H-GL4 uppercase host lowercased|$HG_CFG_SELF|git@GitLab.Example.com:team/plans.git|gitlab.example.com"
)
case_begin "gitlab-visibility-hostname-argv" "hooks/lib/forge/gitlab.js"
for row in "${HG_ROWS[@]}"; do
    IFS='|' read -r hg_id hg_cfg hg_url hg_host <<< "$row"
    assert_eq "$hg_id: glab internal -> internal" '"internal"' \
        "$(hg_run "$hg_cfg" $'internal\n' 0 "" repoVisibility "$hg_url")"
    assert_eq "$hg_id: argv is api --hostname $hg_host projects/team%2Fplans --jq .visibility" \
        "[\"api\",\"--hostname\",\"$hg_host\",\"projects/team%2Fplans\",\"--jq\",\".visibility\"]" "$(hg_log)"
done
# Re-run H-GL3 so the log under inspection is its own: no credential or port reaches glab.
hg_run "$HG_CFG_SELF" $'internal\n' 0 "" repoVisibility \
    "https://user:tok@gitlab.example.com:8443/team/plans.git" >/dev/null
assert_not_contains "H-GL3 token never in argv" "tok" "$(hg_log)"
assert_not_contains "H-GL3 userinfo never in argv" "user" "$(hg_log)"
assert_not_contains "H-GL3 port never in argv" "8443" "$(hg_log)"
case_end

case_begin "gitlab-visibility-hostname-unresolvable" "hooks/lib/forge/gitlab.js"
assert_eq "H-GL5 github remote -> null" 'null' \
    "$(hg_run "$HG_CFG_NONE" $'public\n' 0 "" repoVisibility "git@github.com:a/b.git")"
assert_eq "H-GL5 github remote spawns no glab" "" "$(hg_log)"
assert_eq "H-GL5 dot-dot gitlab path -> null" 'null' \
    "$(hg_run "$HG_CFG_NONE" $'public\n' 0 "" repoVisibility "git@gitlab.com:../x.git")"
assert_eq "H-GL5 dot-dot gitlab path spawns no glab" "" "$(hg_log)"
case_end

case_begin "gitlab-visibility-hostname-mapping-regression" "hooks/lib/forge/gitlab.js"
HG_URL="https://gitlab.com/team/plans.git"
assert_eq "H-GL6 glab PUBLIC -> public" '"public"' "$(hg_run "$HG_CFG_NONE" $'PUBLIC\n' 0 "" repoVisibility "$HG_URL")"
assert_eq "H-GL6 unknown value -> null" 'null' "$(hg_run "$HG_CFG_NONE" $'secret\n' 0 "" repoVisibility "$HG_URL")"
assert_eq "H-GL6 nonzero exit -> null" 'null' "$(hg_run "$HG_CFG_NONE" $'public\n' 1 "" repoVisibility "$HG_URL")"
assert_eq "H-GL6 spawn error -> null" 'null' \
    "$(hg_run "$HG_CFG_NONE" $'public\n' 0 spawn-error repoVisibility "$HG_URL")"
case_end

case_begin "gitlab-siblings-no-hostname" "hooks/lib/forge/gitlab.js"
assert_eq "H-GL7 isPrivateRepo glab private -> true" 'true' \
    "$(hg_run "$HG_CFG_SELF" $'private\n' 0 "" isPrivateRepo "git@gitlab.example.com:team/plans.git")"
assert_contains "H-GL7 isPrivateRepo still queries projects/team%2Fplans" "projects/team%2Fplans" "$(hg_log)"
assert_not_contains "H-GL7 isPrivateRepo argv carries no --hostname" "--hostname" "$(hg_log)"
assert_eq "H-GL7 shouldScanAsPublicTarget glab public -> true" 'true' \
    "$(hg_run "$HG_CFG_SELF" $'public\n' 0 "" shouldScanAsPublicTarget "team/plans")"
assert_contains "H-GL7 shouldScanAsPublicTarget still queries projects/team%2Fplans" "projects/team%2Fplans" "$(hg_log)"
assert_not_contains "H-GL7 shouldScanAsPublicTarget argv carries no --hostname" "--hostname" "$(hg_log)"
assert_eq "H-GL7 listPrivateRepoNames parses rows" '["acme/a"]' \
    "$(hg_run "$HG_CFG_SELF" $'private\tacme/a\n' 0 "" listPrivateRepoNames)"
assert_not_contains "H-GL7 listPrivateRepoNames argv carries no --hostname" "--hostname" "$(hg_log)"
case_end

# HS-GL contract (#2513): the host reaches spawnSync (shell:true on Windows), so
#   repoVisibility gates it on /^[a-z0-9.-]+$/ first; a misfit is null with no glab spawn.
#   Each row's cfg names the URL host exactly, so the row reaches type === "gitlab".
# hs_cfg <n> <host> -> fixture cfg dir whose .env pins GITLAB_HOSTNAME=<host>
hs_cfg() {
    local d="$TMPROOT/hs-cfg-$1"; mkdir -p "$d"
    printf 'GITLAB_HOSTNAME=%s\n' "$2" > "$d/.env"
    printf '%s' "$d"
}
# hs_url <form> <host>: https -> https://<host>/team/plans.git, scp -> git@<host>:team/plans.git
hs_url() {
    if [ "$1" = "scp" ]; then printf 'git@%s:team/plans.git' "$2"; else printf 'https://%s/team/plans.git' "$2"; fi
}

echo "=== HS-GL: repoVisibility rejects a host outside [a-z0-9.-] before glab ==="
case_begin "gitlab-visibility-host-shape-invalid" "hooks/lib/forge/gitlab.js"
# id|form|host — host is the last field, so it may itself contain '|'.
hs_n=0
while IFS='|' read -r hs_id hs_form hs_host; do
    [[ -z "$hs_id" || "$hs_id" =~ ^[[:space:]]*# ]] && continue
    hs_n=$((hs_n + 1))
    hs_dir="$(hs_cfg "neg$hs_n" "$hs_host")"
    assert_eq "$hs_id: host '$hs_host' -> null" 'null' \
        "$(hg_run "$hs_dir" $'internal\n' 0 "" repoVisibility "$(hs_url "$hs_form" "$hs_host")" < /dev/null)"
    assert_eq "$hs_id: host '$hs_host' never reaches glab" "" "$(hg_log)"
done <<'TABLE'
HS-GL1 ampersand (cmd command separator)|https|git&lab.example
HS-GL2 pipe (cmd pipe)|https|gitlab.example|x
HS-GL3 percent pair (cmd variable expansion)|https|gitlab%x%.example
HS-GL4 caret (cmd escape)|https|gitlab^x.example
HS-GL5 underscore (outside the allowed shape)|https|gitlab_x.example
HS-GL6 inner space (argv split)|https|git lab.example
HS-GL7 double quote (cmd quoting)|https|gitlab"x.example
HS-GL8 angle brackets (cmd redirect)|https|gitlab<x>.example
HS-GL9 dollar sign|https|gitlab$x.example
HS-GL10 bang (cmd delayed expansion)|https|gitlab!x.example
HS-GL11 parentheses (cmd grouping)|https|gitlab(x).example
HS-GL12 semicolon and comma (cmd argument delimiters)|https|gitlab;x,y.example
HS-GL13 question mark and hash|https|gitlab?x#y.example
HS-GL14 scp host carrying a slash|scp|gitlab/x.example
HS-GL15 scp host carrying an at-sign|scp|a@gitlab.example
TABLE
case_end

case_begin "gitlab-visibility-host-shape-valid" "hooks/lib/forge/gitlab.js"
# id|cfg host|url host|expected --hostname value
while IFS='|' read -r hs_id hs_cfg_host hs_url_host hs_want; do
    [[ -z "$hs_id" || "$hs_id" =~ ^[[:space:]]*# ]] && continue
    hs_n=$((hs_n + 1))
    hs_dir="$(hs_cfg "pos$hs_n" "$hs_cfg_host")"
    assert_eq "$hs_id: glab private passes through" '"private"' \
        "$(hg_run "$hs_dir" $'private\n' 0 "" repoVisibility "$(hs_url https "$hs_url_host")" < /dev/null)"
    assert_eq "$hs_id: one spawn, argv --hostname $hs_want" \
        "[\"api\",\"--hostname\",\"$hs_want\",\"projects/team%2Fplans\",\"--jq\",\".visibility\"]" "$(hg_log)"
done <<'TABLE'
HS-GL16 dotted dns host|gitlab.example.com|gitlab.example.com|gitlab.example.com
HS-GL17 hyphenated multi-label host|git-lab.example.co.jp|git-lab.example.co.jp|git-lab.example.co.jp
HS-GL18 ipv4 literal|10.0.0.5|10.0.0.5|10.0.0.5
HS-GL19 uppercase cfg and url host fold to lowercase|GitLab.Example.COM|GitLab.Example.COM|gitlab.example.com
TABLE
case_end

finish
