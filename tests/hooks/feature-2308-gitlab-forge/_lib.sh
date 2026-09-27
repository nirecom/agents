#!/bin/bash
# tests/hooks/feature-2308-gitlab-forge/_lib.sh — shared scaffolding for the split
# feature-2308-gitlab-forge suite: module paths, pass/fail + assert helpers,
# run_with_timeout, a per-process TMPROOT, the mocked glab + setup_mock_gh, the
# setup_repo_with_origin/setup_branch_repo fixture builders, and finish().
# Sourced by each split group so each also runs standalone; guarded idempotent.
# NOT a test file: no # Tests:/# Tags: frontmatter; excluded from SPLIT_GROUPS.

if [ -n "${_FEAT2308_FORGE_LIB_SOURCED:-}" ]; then
    return 0
fi
_FEAT2308_FORGE_LIB_SOURCED=1

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$AGENTS_DIR/tests/lib/harness.sh"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

PRU_JS="$(nodepath "$AGENTS_DIR/hooks/lib/parse-remote-url.js")"
GITLAB_JS="$(nodepath "$AGENTS_DIR/hooks/lib/forge/gitlab.js")"
GITHUB_JS="$(nodepath "$AGENTS_DIR/hooks/lib/forge/github.js")"
IPR_JS="$(nodepath "$AGENTS_DIR/hooks/lib/is-private-repo.js")"
DETECT_CLI="$AGENTS_DIR/bin/detect-forge-type"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
assert_contains() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) pass "$name" ;;
        *) fail "$name — expected to contain '$needle', got: $hay" ;;
    esac
}
assert_not_contains() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) fail "$name — expected NOT to contain '$needle', got: $hay" ;;
        *) pass "$name" ;;
    esac
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# Mock glab: node wrapper reachable from Node spawnSync (resolves glab.cmd on
# Windows) and bash PATH lookups. Keyed by env: GLAB_MOCK_VISIBILITY
# (private|public), GLAB_MOCK_MR (open|none), GLAB_MOCK_LIST (newline paths),
# GLAB_MOCK_LOG (file appended with each invocation argv).
MOCK_BIN="$TMPROOT/mock-bin"
mkdir -p "$MOCK_BIN"
GLAB_JS_MOCK="$MOCK_BIN/glab-mock.js"
cat > "$GLAB_JS_MOCK" <<'NODE'
"use strict";
const fs = require("fs");
const args = process.argv.slice(2);
const joined = args.join(" ");
const log = process.env.GLAB_MOCK_LOG;
if (log) { try { fs.appendFileSync(log, joined + "\n"); } catch (e) {} }
const hasJq = args.includes("--jq") || args.some((a) => a.startsWith("--jq="));
function out(s) { process.stdout.write(s); process.exit(0); }
if (/merge_request/.test(joined) || /\bmr\b/.test(joined)) {
  const open = (process.env.GLAB_MOCK_MR || "none") === "open";
  if (hasJq) out(open ? "opened\n" : "");
  out(open ? '[{"iid":3,"state":"opened","web_url":"https://gitlab.com/acme/widgets/-/merge_requests/3"}]\n' : "[]\n");
}
if (/membership/.test(joined) || /visibility=private/.test(joined) || /--per-page/.test(joined)) {
  const list = (process.env.GLAB_MOCK_LIST || "").split(/\r?\n/).filter(Boolean);
  if (hasJq) out(list.join("\n") + (list.length ? "\n" : ""));
  out(JSON.stringify(list.map((p) => ({ path_with_namespace: p }))) + "\n");
}
const vis = process.env.GLAB_MOCK_VISIBILITY || "private";
if (hasJq) out(vis + "\n");
out(JSON.stringify({ visibility: vis, path_with_namespace: "acme/widgets" }) + "\n");
NODE
GLAB_JS_MOCK_WIN="$(winpath "$GLAB_JS_MOCK")"
cat > "$MOCK_BIN/glab" <<EOF
#!/bin/bash
exec node "$GLAB_JS_MOCK" "\$@"
EOF
chmod +x "$MOCK_BIN/glab"
printf '@echo off\r\nnode "%s" %%*\r\n' "$GLAB_JS_MOCK_WIN" > "$MOCK_BIN/glab.cmd"

# Mock gh: visibility echo, mirrors main-private-repo-detection.sh.
setup_mock_gh() {
    printf '#!/bin/bash\necho "%s"\n' "$1" > "$MOCK_BIN/gh"
    printf '@echo off\r\necho %s\r\n' "$1" > "$MOCK_BIN/gh.cmd"
    chmod +x "$MOCK_BIN/gh"
}

setup_repo_with_origin() {
    local url="$1"
    local repo="$TMPROOT/repo-$RANDOM$RANDOM"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config core.hooksPath /dev/null 2>/dev/null || true
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" remote add origin "$url"
    nodepath "$repo"
}

# setup_branch_repo <url> <branch> : setup_repo_with_origin plus an initial
# commit and a checked-out feature branch, so a hook can read the current branch
# via `git rev-parse --abbrev-ref HEAD`.
setup_branch_repo() {
    local url="$1" branch="$2"
    local repo="$TMPROOT/repo-$RANDOM$RANDOM"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config core.hooksPath /dev/null 2>/dev/null || true
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" remote add origin "$url"
    git -C "$repo" commit --allow-empty -q -m "init"
    git -C "$repo" checkout -q -b "$branch"
    nodepath "$repo"
}

# Print results summary and exit with appropriate code.
finish() {
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ] && exit 0 || exit 1
}
