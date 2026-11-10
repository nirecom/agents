#!/usr/bin/env bash
# tests/bin/feature-2960-host-symmetry.sh
# Tests: bin/github-issues/lib/host-adapter.sh, bin/lib/migrate-needs.js
# Tags: TL2, bin, migrate, gitlab, forge, table-driven, scope:issue-specific, test-lang-exception:symmetry
# Issue #2960: hia_host (bash) and hostOf (JS) judge one origin the same way, both through
# bin/detect-forge-type --guess-unconfigured-host: a GITLAB_HOSTNAME in the root's .env.local counts,
# an unconfigured gitlab.* host is guessed gitlab, ssh.github.com and a poisoned path stay unknown.
# hia_host falls back to unknown when the CLI is missing. Contract: the #2960 detail plan S4 / S9.
# TL3 gap: a real self-managed GitLab origin; here every origin is a URL string never contacted.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMPBASE="$(make_tmp)"
readonly TMPBASE
trap 'rm -rf "$TMPBASE"' EXIT
harness_isolate "$TMPBASE/iso"
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR GIT_DIR GIT_WORK_TREE HIA_ROOT
# No global .env and no exported GitLab host: only a fixture's .env.local may configure one.
unset GITLAB_HOSTNAME GITLAB_SSH_HOSTNAME
mkdir -p "$TMPBASE/stub-agents"
export AGENTS_MAIN_ROOT="$TMPBASE/stub-agents"

ADAPTER="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/lib/host-adapter.sh"
NEEDS="$SCRIPT_CHECKOUT_ROOT/bin/lib/migrate-needs.js"
# shellcheck source=../../bin/github-issues/lib/host-adapter.sh
source "$ADAPTER"

# fx_repo <name> <origin> [GITLAB_HOSTNAME for .env.local] [GITLAB_SSH_HOSTNAME for .env.local]
fx_repo() {
  local d="$TMPBASE/repos/$1"
  mkdir -p "$d"
  harness_git_init "$d"
  git -C "$d" remote add origin "$2"
  [ -n "${3:-}" ] && printf 'GITLAB_HOSTNAME=%s\n' "$3" >>"$d/.env.local"
  [ -n "${4:-}" ] && printf 'GITLAB_SSH_HOSTNAME=%s\n' "$4" >>"$d/.env.local"
  printf '%s' "$d"
}
# js_host_of <url> <root> — hostOf(url, root) from bin/lib/migrate-needs.js.
js_host_of() {
  node -e 'process.stdout.write(String(require(process.argv[1]).hostOf(process.argv[2], process.argv[3])))' "$(np "$NEEDS")" "$1" "$(np "$2")" 2>&1
}

# name|origin|.env.local GITLAB_HOSTNAME|want[|.env.local GITLAB_SSH_HOSTNAME] — the rows of
# tests/bin/feature-2960-migrate-forge-type.js.
ROWS=(
  "configured|git@git.example.com:grp/sub/proj.git|git.example.com|gitlab"
  "gitlab-com-subgroup|git@gitlab.com:grp/sub/proj.git||gitlab"
  "unconfigured-gitlab|https://gitlab.example.com/grp/proj.git||gitlab"
  "unconfigured-gitlab-inner-label|https://git.gitlab.internal/grp/proj.git||gitlab"
  "unconfigured-other|https://git.example.org/grp/proj.git||unknown"
  "gitlab-substring-host|https://notgitlab.example.com/grp/proj.git||unknown"
  "gitlab-label-prefix|https://gitlab-ci.example.com/grp/proj.git||unknown"
  "gitlab-label-suffix|https://example.gitlabx.com/grp/proj.git||unknown"
  "gitlab-in-path-only|https://example.com/gitlab.x/proj.git||unknown"
  "github|git@github.com:o/r.git||github"
  "ssh-github|git@ssh.github.com:o/r.git||unknown"
  "poisoned-path|https://gitlab.example.com/grp/../proj.git||unknown"
  "scp-no-user|gitlab.example.com:grp/proj.git||unknown"
  "ssh-host-configured|git@ssh.git.example.com:grp/proj.git||gitlab|ssh.git.example.com"
  "ssh-host-unconfigured|git@ssh.git.example.com:grp/proj.git||unknown"
)

case_begin "HS-adapter-table" "bin/github-issues/lib/host-adapter.sh"
for row in "${ROWS[@]}"; do
  IFS='|' read -r name origin cfg want ssh_cfg <<<"$row"
  repo="$(fx_repo "$name" "$origin" "$cfg" "$ssh_cfg")"
  got="$(hia_host "$repo")"
  if [ "$got" = "$want" ]; then pass "hia_host $name: $want"; else fail "hia_host $name" "want $want, got [$got]"; fi
done
case_end

case_begin "HS-hostOf-table" "bin/lib/migrate-needs.js"
for row in "${ROWS[@]}"; do
  IFS='|' read -r name origin _cfg want _ssh_cfg <<<"$row"
  got="$(js_host_of "$origin" "$TMPBASE/repos/$name")"
  if [ "$got" = "$want" ]; then pass "hostOf $name: $want"; else fail "hostOf $name" "want $want, got [$got]"; fi
  a="$(hia_host "$TMPBASE/repos/$name")"
  if [ "$a" = "$got" ]; then pass "symmetry $name: hia_host = hostOf"; else fail "symmetry $name" "hia_host [$a] vs hostOf [$got]"; fi
done
case_end

case_begin "HS-adapter-hia-root" "bin/github-issues/lib/host-adapter.sh"
got="$(HIA_ROOT="$TMPBASE/repos/configured" hia_host)"
if [ "$got" = gitlab ]; then pass "hia_host without an argument reads HIA_ROOT's .env.local"; else fail "hia_host via HIA_ROOT" "want gitlab, got [$got]"; fi
got="$(cd "$TMPBASE/repos/unconfigured-gitlab" && hia_host)"
if [ "$got" = gitlab ]; then pass "hia_host without an argument or HIA_ROOT judges the cwd"; else fail "hia_host via cwd" "want gitlab, got [$got]"; fi
case_end

case_begin "HS-global-env-host" "bin/github-issues/lib/host-adapter.sh"
# A tmp global root stands in for the agents .env; the repo has no .env.local.
GLOBAL="$TMPBASE/global-root"
mkdir -p "$GLOBAL"
printf 'GITLAB_HOSTNAME=git.example.com\n' >"$GLOBAL/.env"
GREPO="$(fx_repo global-env-configured "git@git.example.com:grp/sub/proj.git")"
if [ ! -e "$GREPO/.env.local" ]; then pass "fixture: no .env.local"; else fail "fixture" ".env.local exists"; fi
got="$(hia_host "$GREPO")"
if [ "$got" = unknown ]; then pass "empty global root: hia_host is unknown"; else fail "empty global root" "want unknown, got [$got]"; fi
got="$(AGENTS_MAIN_ROOT="$GLOBAL" hia_host "$GREPO")"
if [ "$got" = gitlab ]; then pass "global .env GITLAB_HOSTNAME: hia_host is gitlab"; else fail "global .env hia_host" "want gitlab, got [$got]"; fi
js="$(AGENTS_MAIN_ROOT="$GLOBAL" js_host_of "git@git.example.com:grp/sub/proj.git" "$GREPO")"
if [ "$js" = "$got" ]; then pass "global .env symmetry: hia_host = hostOf"; else fail "global .env symmetry" "hia_host [$got] vs hostOf [$js]"; fi
case_end

case_begin "HS-adapter-no-cli-unknown" "bin/github-issues/lib/host-adapter.sh"
# A copy holding host-adapter.sh only: no bin/detect-forge-type next to it.
NOCLI="$TMPBASE/no-cli"
mkdir -p "$NOCLI/bin/github-issues/lib"
cp "$ADAPTER" "$NOCLI/bin/github-issues/lib/host-adapter.sh"
for name in gitlab-com-subgroup github configured; do
  # shellcheck source=/dev/null
  got="$(source "$NOCLI/bin/github-issues/lib/host-adapter.sh" && hia_host "$TMPBASE/repos/$name")"
  if [ "$got" = unknown ]; then pass "no CLI, $name: hia_host is unknown"; else fail "no CLI, $name" "want unknown, got [$got]"; fi
done
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
