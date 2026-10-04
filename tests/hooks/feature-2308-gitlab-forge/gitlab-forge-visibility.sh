#!/bin/bash
# Tests: hooks/lib/forge/gitlab.js, hooks/lib/forge-router.js
# Tags: scope:issue-specific, gitlab, forge, security, visibility, glab-stub, TL2, private-repo-list
set -u

# Issue #2513 — codehostGitlab.repoVisibility(remoteUrl) -> "public" | "private" |
#   "internal" | null via `glab api projects/<url-encoded path> --jq .visibility`.
#   A glab failure, a timeout, an unknown value or an unresolvable path is null, and an
#   unresolvable path never reaches glab. glab is a PATH stub (tests/lib/cli-stub.sh).

# TL3 gap: a real `glab api` round trip (auth, self-hosted host, 5xx) is not exercised.

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
# shellcheck source=../../lib/cli-stub.sh
. "$AGENTS_DIR/tests/lib/cli-stub.sh"

FORGE_ROUTER_JS="$(nodepath "$AGENTS_DIR/hooks/lib/forge-router.js")"
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
assert_eq "V-GL2 glab argv is api projects/acme%2Fwidgets --jq .visibility" \
    "glab api projects/acme%2Fwidgets --jq .visibility" "$(cat "$GL_LOG" 2>/dev/null)"
gl_case "V-GL3 glab says private -> private" 'gitlab:"private"' $'private\n' 0 0 "$GL_URL"
gl_case "V-GL4 glab says internal -> internal" 'gitlab:"internal"' $'internal\n' 0 0 "$GL_URL"
gl_case "V-GL5 nested namespace, glab says private -> private" 'gitlab:"private"' $'private\n' 0 0 \
    "https://gitlab.com/acme/sub/widgets.git"
assert_eq "V-GL5 nested namespace argv URL-encodes every separator" \
    "glab api projects/acme%2Fsub%2Fwidgets --jq .visibility" "$(cat "$GL_LOG" 2>/dev/null)"
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

# L-GL contract (#2513): codehostGitlab.listPrivateRepoNames() is the union of the
#   `visibility=private` and `visibility=internal` project queries, deduped, private
#   first; one failing call keeps the other's names, both failing -> []. spawnSync is
#   monkeypatched (as in C1) so the union logic is judged on the argv array alone.
LG_DRIVER="$TMPROOT/gl-list-union-driver.js"
cat > "$LG_DRIVER" <<'NODE'
"use strict";
const cp = require("child_process"); const fs = require("fs");
const realSpawn = cp.spawnSync.bind(cp);
const env = process.env;
cp.spawnSync = function (cmd, args, opts) {
  if (!/glab/.test(String(cmd))) return realSpawn(cmd, args, opts);
  const joined = (args || []).join(" ");
  if (env.LG_LOG) fs.appendFileSync(env.LG_LOG, "glab " + joined + "\n");
  const k = /visibility=internal\b/.test(joined) ? "INT" : /visibility=private\b/.test(joined) ? "PRIV" : "";
  if (!k) return { status: 3, stdout: "", stderr: "unexpected", error: null };
  return { status: Number(env["LG_" + k + "_RC"] || 0), stdout: env["LG_" + k + "_OUT"] || "", stderr: "", error: null };
};
let r;
try { r = require(process.argv[2]).codehostGitlab.listPrivateRepoNames(); } catch (e) { r = "THREW:" + e.message; }
process.stdout.write(JSON.stringify(r));
NODE
LG_LOG="$TMPROOT/gl-list-union.log"
# lg_run <priv-out> <priv-rc> <int-out> <int-rc>
lg_run() {
    : > "$LG_LOG"
    LG_PRIV_OUT="$1" LG_PRIV_RC="$2" LG_INT_OUT="$3" LG_INT_RC="$4" LG_LOG="$LG_LOG" \
        run_with_timeout 20 node "$LG_DRIVER" "$GITLAB_JS" 2>/dev/null
}

echo "=== L-GL: codehostGitlab.listPrivateRepoNames (private + internal union) ==="
case_begin "gitlab-list-private-repo-names-union" "hooks/lib/forge/gitlab.js"
assert_eq "L-GL1 private + internal -> union, private first" \
    '["acme/priv-a","group/sub/priv-b","acme/int-c"]' \
    "$(lg_run $'acme/priv-a\ngroup/sub/priv-b\n' 0 $'acme/int-c\n' 0)"
LG_SEEN="$(cat "$LG_LOG" 2>/dev/null)"
assert_contains "L-GL2 glab asked for visibility=private" "visibility=private" "$LG_SEEN"
assert_contains "L-GL3 glab asked for visibility=internal" "visibility=internal" "$LG_SEEN"
assert_eq "L-GL4 a path in both lists appears once" '["acme/a","acme/b","acme/c"]' \
    "$(lg_run $'acme/a\nacme/b\n' 0 $'acme/b\nacme/c\n' 0)"
case_end

case_begin "gitlab-list-private-repo-names-partial-failure" "hooks/lib/forge/gitlab.js"
assert_eq "L-GL5 internal call fails -> private paths still returned" '["acme/priv-a"]' \
    "$(lg_run $'acme/priv-a\n' 0 $'acme/int-c\n' 1)"
assert_eq "L-GL6 private call fails -> internal paths still returned" '["acme/int-c"]' \
    "$(lg_run $'acme/priv-a\n' 1 $'acme/int-c\n' 0)"
assert_eq "L-GL7 both calls fail -> []" '[]' "$(lg_run $'acme/priv-a\n' 1 $'acme/int-c\n' 1)"
case_end

case_begin "gitlab-list-private-repo-names-edge-output" "hooks/lib/forge/gitlab.js"
assert_eq "L-GL9 both calls succeed with empty output -> []" '[]' "$(lg_run '' 0 '' 0)"
assert_eq "L-GL10 CRLF, blank lines and padding dropped in both lists" '["acme/a","acme/c"]' \
    "$(lg_run $'acme/a\r\n\r\n' 0 $'  acme/c  \r\n\n' 0)"
case_end

# L-GL8: the real spawn path (PATH stub, shell on Windows). cmd.exe splits an unquoted
# `&`, so the query must reach glab whole: each visibility line keeps its trailing --jq.
case_begin "gitlab-list-private-query-reaches-glab-whole" "hooks/lib/forge/gitlab.js"
if [ -z "${GL_STUB_OK:-}" ]; then fail "L-GL8 glab stub unreachable; not run so the real glab stays untouched"
else
    : > "$GL_LOG"
    CLI_STUB_OUT=$'acme/x\n' CLI_STUB_RC=0 CLI_STUB_SLEEP_MS=0 CLI_STUB_LOG="$GL_LOG" \
        cli_stub_run run_with_timeout 20 node -e 'require(process.argv[1]).codehostGitlab.listPrivateRepoNames()' \
        "$GITLAB_JS" >/dev/null 2>&1
    LG8_SEEN="$(cat "$GL_LOG" 2>/dev/null)"
    for v in private internal; do
        if printf '%s\n' "$LG8_SEEN" | grep -F "visibility=$v" | grep -qF -- "--jq"; then
            pass "L-GL8 visibility=$v query reaches glab intact through the spawn shell"
        else fail "L-GL8 visibility=$v query reaches glab intact through the spawn shell — glab-log=[$LG8_SEEN]"; fi
    done
fi
case_end

finish
