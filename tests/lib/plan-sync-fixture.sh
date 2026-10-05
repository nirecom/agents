#!/usr/bin/env bash
# tests/lib/plan-sync-fixture.sh
# Tests: tests/lib/plan-sync-fixture.sh
# Tags: scope:issue-specific, shared-lib, plan-sync, fixture
# Shared #2513 plan-sync fixture; rules: detail.md "テストの構成" (fixture helper).
# Needs AGENTS_DIR. Defines only psf_* helpers + setup_ssh_stub, never pass/fail
# (psf_tag_unimplemented_fails wraps the caller's fail only on request). Caller owns EXIT trap.

PSF_AGENTS_DIR="${AGENTS_DIR:?plan-sync-fixture.sh: set AGENTS_DIR before sourcing}"
PSF_LIB="$PSF_AGENTS_DIR/hooks/lib/plan-sync.js"
PSF_ORIGIN_GH="git@github.com:test-owner/test-repo.git"
PSF_ORIGIN_E2E="ssh://git@github.com/test-owner/test-repo.git"
PSF_ORIGIN_DEAD="ssh://git@127.0.0.1:1/o/r.git"

psf_np() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}

psf_timeout() { bash "$PSF_AGENTS_DIR/bin/run-with-timeout.sh" "$@"; }

# psf_git_version_ok — GIT_CONFIG_GLOBAL isolation needs git >= 2.32 (fail, never skip).
psf_git_version_ok() {
  local v major minor
  v="$(git version 2>/dev/null)"
  v="${v#git version }"
  major="${v%%.*}"
  minor="${v#*.}"
  minor="${minor%%.*}"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
  (( major > 2 || (major == 2 && minor >= 32) ))
}

# psf_setup — temp root, dual-pin, empty config dir, isolated git config, neutral cwd.
psf_setup() {
  PSF_ROOT="$(psf_np "$(mktemp -d 2>/dev/null || mktemp -d -t psf)")"
  mkdir -p "$PSF_ROOT/workflow-state" "$PSF_ROOT/plans" "$PSF_ROOT/cfg" \
    "$PSF_ROOT/neutral" "$PSF_ROOT/transcripts"
  export CLAUDE_WORKFLOW_DIR="$PSF_ROOT/workflow-state"
  export WORKFLOW_PLANS_DIR="$PSF_ROOT/plans"
  export AGENTS_CONFIG_DIR="$PSF_ROOT/cfg"
  export CLAUDE_TRANSCRIPT_BASE_DIR="$PSF_ROOT/transcripts"
  export PLAN_SYNC_REMOTE_URL=""
  export PSF_LIB_PATH; PSF_LIB_PATH="$(psf_np "$PSF_LIB")"
  unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE 2>/dev/null || true
  unset CONFIRM_INTENT CONFIRM_OUTLINE CONFIRM_DETAIL TERM_PROGRAM CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
  unset GIT_SSH_COMMAND GIT_SSH GIT_SSH_VARIANT GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE 2>/dev/null || true
  export GIT_CONFIG_GLOBAL="$PSF_ROOT/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_TERMINAL_PROMPT=0
  printf '[core]\n\thooksPath = /dev/null\n[user]\n\tname = plan-sync-test\n\temail = plan-sync-test@example.invalid\n' \
    > "$GIT_CONFIG_GLOBAL"
  cd "$PSF_ROOT/neutral" || return 1
}

psf_cleanup() {
  cd / 2>/dev/null || true
  if [ -n "${PSF_ROOT:-}" ] && [ -d "$PSF_ROOT" ]; then
    chmod -R u+rwX "$PSF_ROOT" 2>/dev/null
    rm -rf "$PSF_ROOT"
  fi
}

psf_lib_present() { [ -f "$PSF_LIB" ]; }

# psf_tag_unimplemented_fails — opt-in, call after the caller's fail() exists. While
# hooks/lib/plan-sync.js is absent (TDD red), every fail label gains a "not implemented" tag.
psf_tag_unimplemented_fails() {
  psf_lib_present && return 0
  declare -F fail >/dev/null || return 0
  declare -F _psf_base_fail >/dev/null && return 0
  eval "_psf_base_fail() $(declare -f fail | tail -n +2)"
  fail() { _psf_base_fail "$1 [not implemented: hooks/lib/plan-sync.js absent]" "${@:2}"; }
}

# psf_node <js> [args...] — runs <js> with `ps` = hooks/lib/plan-sync.js.
# Prints "NOT_IMPLEMENTED: <code>" and exits 3 when the module cannot load.
psf_node() {
  local js="$1"
  shift
  psf_timeout 90 node -e "
let ps;
try { ps = require(process.env.PSF_LIB_PATH); }
catch (e) { console.log('NOT_IMPLEMENTED: ' + (e.code || e.message)); process.exit(3); }
const fs = require('fs'); const path = require('path');
const allowLocal = { isAllowedRemoteUrl: (u) => ps.isAllowedRemoteUrl(u) || path.isAbsolute(u) };
$js" "$@"
}

psf_make_bare() {
  git init -q --bare "$1" || return 1
  git -C "$1" symbolic-ref HEAD refs/heads/main
}

# psf_make_provisioned <dir> <origin-url> — "provisioned" repo built by plumbing, no network:
# plansync.version, rendered .gitignore, origin, main commit from a temp index, origin/main.
psf_make_provisioned() {
  local d="$1" url="$2" ver blob tree commit idx
  mkdir -p "$d"
  git init -q "$d" || return 1
  git -C "$d" symbolic-ref HEAD refs/heads/main
  git -C "$d" config core.hooksPath /dev/null
  git -C "$d" config core.autocrlf false
  psf_node 'fs.writeFileSync(path.join(process.argv[1], ".gitignore"), ps.renderGitignore());' "$d" \
    >/dev/null || return 1
  ver="$(psf_node 'process.stdout.write(String(ps.INIT_VERSION));')" || return 1
  idx="$d/.git/psf-index"
  blob="$(git -C "$d" hash-object -w -- .gitignore)" || return 1
  GIT_INDEX_FILE="$idx" git -C "$d" update-index --add --cacheinfo "100644,$blob,.gitignore" || return 1
  tree="$(GIT_INDEX_FILE="$idx" git -C "$d" write-tree)" || return 1
  rm -f "$idx"
  commit="$(git -C "$d" commit-tree "$tree" -m 'plan-sync fixture: initial')" || return 1
  git -C "$d" update-ref refs/heads/main "$commit"
  git -C "$d" remote add origin "$url"
  git -C "$d" config plansync.version "$ver"
  git -C "$d" update-ref refs/remotes/origin/main "$commit"
}

# psf_commit_file <dir> <rel> [extra-ref...] — overlay the working-tree file <rel>
# onto refs/heads/main (and each extra ref, e.g. refs/remotes/origin/main).
psf_commit_file() {
  local d="$1" rel="$2" idx parent blob tree commit ref
  shift 2
  idx="$d/.git/psf-index"
  parent="$(git -C "$d" rev-parse refs/heads/main)" || return 1
  blob="$(git -C "$d" hash-object -w -- "$rel")" || return 1
  GIT_INDEX_FILE="$idx" git -C "$d" read-tree "$parent" || return 1
  GIT_INDEX_FILE="$idx" git -C "$d" update-index --add --cacheinfo "100644,$blob,$rel" || return 1
  tree="$(GIT_INDEX_FILE="$idx" git -C "$d" write-tree)" || return 1
  rm -f "$idx"
  commit="$(git -C "$d" commit-tree "$tree" -p "$parent" -m "plan-sync fixture: $rel")" || return 1
  for ref in refs/heads/main "$@"; do
    git -C "$d" update-ref "$ref" "$commit"
  done
}

# setup_ssh_stub <bare> — route ssh transport to tests/lib/git-ssh-stub.sh for this process env.
setup_ssh_stub() {
  export GIT_SSH_STUB_BARE; GIT_SSH_STUB_BARE="$(psf_np "$1")"
  export GIT_SSH_STUB_LOG="$PSF_ROOT/ssh-stub.log"
  : > "$GIT_SSH_STUB_LOG"
  export GIT_SSH_COMMAND; GIT_SSH_COMMAND="sh $(psf_np "$PSF_AGENTS_DIR/tests/lib/git-ssh-stub.sh")"
  export GIT_SSH_VARIANT=ssh
}

# psf_up <path> — POSIX form for PATH entries (a drive-letter colon would split PATH).
psf_up() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s\n' "$1"; fi
}

# psf_drop_gh_from_path — exports PATH without any directory holding a gh executable, so
# no test reaches the real GitHub CLI (network). Such a directory that also holds git /
# node / sh / bash (e.g. /usr/bin) becomes a shim dir linking everything except gh.
psf_drop_gh_from_path() {
  local kept="" dir f t shim n=0 essential
  local -a dirs
  IFS=: read -r -a dirs <<< "$PATH"
  for dir in "${dirs[@]}"; do
    [ -z "$dir" ] && continue
    if [ -e "$dir/gh" ] || [ -e "$dir/gh.exe" ] || [ -e "$dir/gh.cmd" ] || [ -e "$dir/gh.bat" ]; then
      essential=""
      for t in git node sh bash; do [ -e "$dir/$t" ] || [ -e "$dir/$t.exe" ] && essential=1; done
      [ -z "$essential" ] && continue
      n=$((n + 1)); shim="$(psf_up "$PSF_ROOT/path-shim-$n")"; mkdir -p "$shim"
      for f in "$dir"/*; do
        case "${f##*/}" in gh|gh.exe|gh.cmd|gh.bat) continue ;; esac
        ln -s "$f" "$shim/${f##*/}" 2>/dev/null || true
      done
      dir="$shim"
    fi
    kept="${kept:+$kept:}$dir"
  done
  export PATH="$kept"
}

# psf_node_finds_gh — prints what Node's shell-less spawnSync sees for "gh": ENOENT when absent.
psf_node_finds_gh() {
  psf_timeout 30 node -e '
const r = require("child_process").spawnSync("gh", ["--version"], { windowsHide: true });
process.stdout.write(r.error ? String(r.error.code) : "found:" + r.status);'
}

# psf_make_gh_stub — a gh stub under $PSF_ROOT/gh-stub (tests/lib/cli-stub.sh).
psf_make_gh_stub() {
  # shellcheck source=cli-stub.sh
  . "$PSF_AGENTS_DIR/tests/lib/cli-stub.sh"
  cli_stub_make "$PSF_ROOT/gh-stub" gh || return 1
  PSF_GH_STUB_LOG="$PSF_ROOT/gh-stub.log"
}

# psf_with_gh_stub <stdout> <rc> <cmd...> — runs <cmd> with the gh stub first on PATH.
# Each gh call appends "gh <args>" to $PSF_GH_STUB_LOG.
psf_with_gh_stub() {
  CLI_STUB_OUT="$1" CLI_STUB_RC="$2" CLI_STUB_SLEEP_MS=0 CLI_STUB_LOG="$PSF_GH_STUB_LOG" cli_stub_run "${@:3}"
}

# psf_sysmsg <hook-stdout> — prints .systemMessage of a hook JSON output (empty if none).
psf_sysmsg() {
  printf '%s' "$1" | psf_timeout 30 node -e "
let d; try { d = JSON.parse(require('fs').readFileSync(0, 'utf8')); } catch (e) { process.exit(1); }
process.stdout.write(d.systemMessage || '');" 2>/dev/null
}

# psf_write_json <file_path> [session_id] — PostToolUse Write payload.
psf_write_json() {
  psf_timeout 30 node -e "
process.stdout.write(JSON.stringify({ tool_name: 'Write', tool_input: { file_path: process.argv[1] },
  tool_response: { success: true }, session_id: process.argv[2] || undefined }));" "$1" "${2:-}"
}
