#!/bin/sh
# tests/lib/git-ssh-stub.sh
# Tests: tests/lib/git-ssh-stub.sh
# Tags: scope:issue-specific, shared-lib, plan-sync, ssh-stub
# Test-only ssh stub for #2513 e2e; design: detail.md "Test composition" section, item 4.

# Reached only via GIT_SSH_COMMAND="sh <abs>/git-ssh-stub.sh" (the command guard trusts no wrapper).
# Host/options are ignored; only the last arg "<cmd> '<path>'" is parsed.
# Serves exactly /test-owner/test-repo.git (or $GIT_SSH_STUB_REPO) -> $GIT_SSH_STUB_BARE; others exit 128.
# Logs: each path to $GIT_SSH_STUB_LOG; the whole last arg (or the failure name) to $GIT_SSH_STUB_CALL_LOG.
# GIT_SSH_STUB_FAIL=auth|offline fails like ssh (255; auth names the destination arg as OpenSSH does);
# $GIT_SSH_STUB_INJECT runs once before a receive-pack.

last=""
dest=""
for arg in "$@"; do
  dest="$last"
  last="$arg"
done

case "${GIT_SSH_STUB_FAIL:-}" in
  "") ;;
  auth)
    [ -z "${GIT_SSH_STUB_CALL_LOG:-}" ] || printf '%s\n' auth-refused >> "$GIT_SSH_STUB_CALL_LOG"
    # OpenSSH names the destination ([user@]host, userinfo as git passed it) in this line.
    echo "${dest}: Permission denied (publickey)." >&2
    exit 255
    ;;
  offline)
    [ -z "${GIT_SSH_STUB_CALL_LOG:-}" ] || printf '%s\n' offline >> "$GIT_SSH_STUB_CALL_LOG"
    echo "ssh: connect to host github.com port 22: Network is unreachable" >&2
    exit 255
    ;;
  *)
    echo "git-ssh-stub: unknown GIT_SSH_STUB_FAIL: $GIT_SSH_STUB_FAIL" >&2
    exit 128
    ;;
esac
[ -z "${GIT_SSH_STUB_CALL_LOG:-}" ] || printf '%s\n' "$last" >> "$GIT_SSH_STUB_CALL_LOG"

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
  git-receive-pack)
    if [ -n "${GIT_SSH_STUB_INJECT:-}" ] && [ -f "$GIT_SSH_STUB_INJECT" ]; then
      sh "$GIT_SSH_STUB_INJECT"
      rm -f "$GIT_SSH_STUB_INJECT"
    fi
    exec git receive-pack "$GIT_SSH_STUB_BARE"
    ;;
  git-upload-pack) exec git upload-pack "$GIT_SSH_STUB_BARE" ;;
  *)
    echo "git-ssh-stub: unsupported command: $cmd" >&2
    exit 128
    ;;
esac
