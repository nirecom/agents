#!/usr/bin/env bash
# Tests: tests/lib/command-guard/resolve-target.js, tests/lib/command-guard/main.js
# Tags: scope:issue-specific, tl2, command-guard, fixture-isolation
#
# The command guard's network rule (#2590): isNetworkUrl() tells local paths (drive letters,
# MSYS paths, ./a:b) from network URLs (scp-style, scheme://, <transport>::); push / fetch /
# ls-remote to a repo inside the run root pass, while clone / submodule add / push / fetch that
# reach the network or write outside the run root are refused.
# Fixtures and helpers: feature-2590-command-guard/setup.sh.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/state"
unset CLAUDE_CODE_SESSION_ID

. "$SCRIPT_DIR/feature-2590-command-guard/setup.sh"

cg_setup || { echo "FAIL: fixture setup"; exit 1; }

RESOLVE_JS="$(np "$SCRIPT_CHECKOUT_ROOT/tests/lib/command-guard/resolve-target.js")"
CG_GIT_ENV=(env "GIT_CONFIG_SYSTEM=$TMP_ROOT/system.gitconfig" "GIT_SSH_COMMAND=false" "GIT_TERMINAL_PROMPT=0")

# URLs go in on stdin: MSYS would rewrite /c/... and a:b arguments before node saw them.
nu_classify() {
  local js='const { isNetworkUrl } = require(process.argv[1]); for (const l of require("fs").readFileSync(0, "utf8").split(/\r?\n/)) if (l !== "") process.stdout.write(`${l}\t${isNetworkUrl(l)}\n`);'
  printf '%s\n' "$@" | PATH="$SAFE_PATH" node -e "$js" "$RESOLVE_JS"
}

# nu_expect <want true|false> <url...>
nu_expect() {
  local want="$1" out url
  shift
  out="$(nu_classify "$@")"
  for url in "$@"; do
    expect_has "isNetworkUrl($url) is $want" "$out" "$url"$'\t'"$want"
  done
}

# expect_network_reject <label> <cwd> <command...> — refused as a network URL.
expect_network_reject() {
  local label="$1"
  expect_reject "$@"
  expect_has "$label: refused as a network URL" "$ERR_TEXT" "(network URL)"
}

case_begin "is-network-url-local-forms" "tests/lib/command-guard/resolve-target.js"
nu_expect false 'C:/some/path' 'C:\some\path' '/c/some/path' './a:b' 'file:///c/some/path'
case_end

case_begin "is-network-url-network-forms" "tests/lib/command-guard/resolve-target.js"
nu_expect true 'host:path' 'user@host:path' 'https://github.com/x/y' 'ssh://host/repo' 'git://host/repo' 'ext::sh -c x'
case_end

IN_BARE="$RR/inbare.git"
SRC_REPO="$RR/src repo"
rgit init -q --bare "$IN_BARE" || { echo "FAIL: inside bare repo"; exit 1; }
PATH="$SAFE_PATH" harness_git_init "$SRC_REPO" && rcommit "$SRC_REPO" src || { echo "FAIL: inside source repo"; exit 1; }
IN_BARE_N="$(np "$IN_BARE")"
case "$IN_BARE_N" in /*) IN_BARE_URL="file://$IN_BARE_N" ;; *) IN_BARE_URL="file:///$IN_BARE_N" ;; esac

case_begin "local-remotes-inside-the-run-root-pass" "tests/lib/command-guard/main.js"
if cg_require "push / fetch / ls-remote to a repo inside the run root pass"; then
  want="$(rgit -C "$IN_REPO" rev-parse HEAD)"
  expect_allow "push to an inside bare repo" "$IN_REPO" git push -q "$IN_BARE_N" HEAD:refs/heads/plain
  expect_eq "push path: ref landed" "$(rgit --git-dir="$IN_BARE" rev-parse refs/heads/plain)" "$want"
  expect_allow "push to an inside bare repo via file://" "$IN_REPO" git push -q "$IN_BARE_URL" HEAD:refs/heads/viafile
  expect_eq "push file://: ref landed" "$(rgit --git-dir="$IN_BARE" rev-parse refs/heads/viafile)" "$want"
  expect_allow "ls-remote an inside repo" "$IN_REPO" git ls-remote "$(np "$SRC_REPO")"
  expect_has "ls-remote: real git output" "$OUT_TEXT" "$(rgit -C "$SRC_REPO" rev-parse HEAD)"
  expect_allow "fetch from an inside repo" "$IN_REPO" git fetch -q "$(np "$SRC_REPO")"
  expect_eq "fetch: FETCH_HEAD names the source commit" "$(rgit -C "$IN_REPO" rev-parse FETCH_HEAD)" "$(rgit -C "$SRC_REPO" rev-parse HEAD)"
fi
case_end

case_begin "clone-and-submodule-network-or-outside-are-refused" "tests/lib/command-guard/main.js"
if cg_require "clone / submodule add reaching the network or outside are refused"; then
  expect_network_reject "clone an https URL" "$RR" "${CG_GIT_ENV[@]}" git clone -q https://example.invalid/x/y
  expect_eq "clone https: nothing created" "$([[ -e "$RR/y" ]] && echo made)" ""
  expect_reject "clone an inside repo to an outside dest" "$RR" git clone -q "$(np "$SRC_REPO")" "$(np "$OUTSIDE/dest")"
  expect_has "clone outside dest: refused as an outside write" "$ERR_TEXT" "(write outside the run root)"
  expect_eq "clone outside dest: nothing created" "$([[ -e "$OUTSIDE/dest" ]] && echo made)" ""
  expect_network_reject "submodule add an https URL" "$IN_REPO" "${CG_GIT_ENV[@]}" git submodule add https://example.invalid/x/y
  expect_eq "submodule add https: no .gitmodules" "$([[ -e "$IN_REPO/.gitmodules" ]] && echo made)" ""
fi
case_end

case_begin "push-and-fetch-to-network-remotes-are-refused" "tests/lib/command-guard/main.js"
if cg_require "push / fetch to network remotes are refused"; then
  expect_network_reject "push ssh://" "$IN_REPO" "${CG_GIT_ENV[@]}" git push ssh://example.invalid/repo HEAD:refs/heads/leak
  expect_network_reject "push git://" "$IN_REPO" "${CG_GIT_ENV[@]}" git push git://example.invalid/repo HEAD:refs/heads/leak
  expect_network_reject "push ext::" "$IN_REPO" "${CG_GIT_ENV[@]}" git push "ext::sh -c false" HEAD:refs/heads/leak
  expect_network_reject "fetch origin with a -c network url" "$IN_REPO" "${CG_GIT_ENV[@]}" git -c remote.origin.url=https://example.invalid/x fetch origin
  expect_eq "network refusals: inside repo has no origin config" "$(rgit -C "$IN_REPO" config --get remote.origin.url)" ""
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
