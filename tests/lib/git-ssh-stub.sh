#!/bin/sh
# tests/lib/git-ssh-stub.sh
# Tests: tests/lib/git-ssh-stub.sh
# Tags: scope:issue-specific, shared-lib, plan-sync, ssh-stub
# Test-only ssh stub for #2513 e2e; design: detail.md "テストの構成" item 4.

# Reached only via GIT_SSH_COMMAND="sh <abs>/git-ssh-stub.sh" + GIT_SSH_VARIANT=ssh.
# Host/options are ignored; only the last arg "<cmd> '<path>'" is parsed.
# Serves exactly /test-owner/test-repo.git (or $GIT_SSH_STUB_REPO) -> $GIT_SSH_STUB_BARE; others exit 128.
# Every requested path is appended to $GIT_SSH_STUB_LOG, one per line.

last=""
for arg in "$@"; do
  last="$arg"
done

cmd="${last%% *}"
repo_path="${last#* }"
repo_path="${repo_path#\'}"
repo_path="${repo_path%\'}"

if [ -n "${GIT_SSH_STUB_LOG:-}" ]; then
  printf '%s\n' "$repo_path" >> "$GIT_SSH_STUB_LOG"
fi

# GIT_SSH_STUB_REPO (optional) names another single repo to serve; the leading "/" is
# ignored on both sides so the scp form (owner/repo.git) and ssh:// form (/owner/repo.git) match.
want_repo="${GIT_SSH_STUB_REPO:-/test-owner/test-repo.git}"
if [ -n "${GIT_SSH_STUB_REPO:-}" ]; then
  [ "${repo_path#/}" = "${want_repo#/}" ] && repo_path="$want_repo"
fi
if [ "$repo_path" != "$want_repo" ]; then
  echo "git-ssh-stub: unknown repository: $repo_path" >&2
  exit 128
fi
if [ -z "${GIT_SSH_STUB_BARE:-}" ]; then
  echo "git-ssh-stub: GIT_SSH_STUB_BARE is not set" >&2
  exit 128
fi

case "$cmd" in
  git-receive-pack) exec git receive-pack "$GIT_SSH_STUB_BARE" ;;
  git-upload-pack) exec git upload-pack "$GIT_SSH_STUB_BARE" ;;
  *)
    echo "git-ssh-stub: unsupported command: $cmd" >&2
    exit 128
    ;;
esac
