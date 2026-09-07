#!/usr/bin/env bash
# tests/unit-credential-check.sh
# Tests: hooks/lib/credential-check.js
# Tags: unit, credentials, classifier, table-driven, security, scope:common, pwsh-not-required
# Unit coverage of isCredentialPath() / commandTouchesCredentials() — the pure
# predicates extracted from hooks/block-credentials.js (#2170), now also read by
# the scratchpad body scan in hooks/preuse-auto-approve/scratchpad-script.js.
# CPR-ORTH: every hit is paired with a near-miss (sibling path, text flag, echo
# positional) that MUST come back false, so over-blocking fails too.
# TL3 gap: does not prove the consumers CALL this lib (wiring: main-block-credentials.sh,
# part4-scratchpad D-6). Mitigation: WORKFLOW_USER_VERIFIED preflight, hook-registration.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
topath() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}
MODULE="$(topath "$AGENTS_DIR/hooks/lib/credential-check.js")"

command -v node >/dev/null 2>&1 || exit 77

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"; else fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TABLE="$TMP/cases.txt"

# Table columns: fn (path|cmd) | name | subject | want (true/false).
# Single-quoted heredoc: `~` and `$HOME` reach the module unexpanded, exactly the
# form a hook receives from a tool payload.
cat >"$TABLE" <<'TABLE'
# ---- isCredentialPath: hits ----
path | cred-ssh-key             | ~/.ssh/id_rsa                        | true
path | cred-ssh-root-itself     | ~/.ssh                               | true
path | cred-aws-credentials     | ~/.aws/credentials                   | true
path | cred-root-owned-ssh      | /root/.ssh/id_rsa                    | true
path | cred-gh-config           | ~/.config/gh/hosts.yml               | true
path | cred-npmrc               | ~/.npmrc                             | true
path | cred-kube-config         | ~/.kube/config                       | true
path | cred-vault-token         | ~/.vault-token                       | true
path | cred-docker-config-json  | ~/.docker/config.json                | true
path | cred-home-env-var-form   | $HOME/.aws/credentials               | true
path | cred-nested-deep         | ~/.gnupg/private-keys-v1.d/key.key   | true
# ---- isCredentialPath: near-misses (over-blocking guard) ----
path | miss-sibling-prefix-dir  | ~/.sshfoo/id_rsa                     | false
path | miss-sibling-file-suffix | ~/.npmrc.bak                         | false
path | miss-docker-daemon-json  | ~/.docker/daemon.json                | false
path | miss-config-nvim         | ~/.config/nvim/init.lua              | false
path | miss-plain-home-file     | ~/notes.txt                          | false
path | miss-traversal-escapes   | ~/.ssh/../notes.txt                  | false
path | miss-unrelated-abs       | /tmp/id_rsa                          | false
path | miss-empty-string        |                                      | false
# ---- commandTouchesCredentials: hits ----
cmd  | cmd-cat-ssh-key          | cat ~/.ssh/id_rsa                    | true
cmd  | cmd-copy-aws-creds       | cp ~/.aws/credentials /tmp/x         | true
cmd  | cmd-grep-gnupg           | grep -r foo ~/.gnupg                 | true
cmd  | cmd-root-owned-aws       | cat /root/.aws/credentials           | true
cmd  | cmd-env-var-netrc        | cat $HOME/.netrc                     | true
cmd  | cmd-shell-wrapper        | bash -c "cat ~/.ssh/id_rsa"          | true
cmd  | cmd-redirect-into-ssh    | echo pubkey > ~/.ssh/authorized_keys | true
cmd  | cmd-path-flag-value      | tar -f ~/.ssh/id_rsa                 | true
# ---- commandTouchesCredentials: near-misses ----
cmd  | cmd-echo-positional-miss | echo ~/.ssh/id_rsa                   | false
cmd  | cmd-text-flag-value-miss | git commit -m ~/.ssh/id_rsa          | false
cmd  | cmd-plain-home-file-miss | cat ~/notes.txt                      | false
cmd  | cmd-git-status-miss      | git status --short                   | false
cmd  | cmd-sibling-dir-miss     | cat ~/.sshfoo/id_rsa                 | false
cmd  | cmd-empty-string-miss    |                                      | false
TABLE

EXPECTED="$(grep -c -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$TABLE")"

# One node process evaluates the whole table; bash keeps the assertion, so a
# driver that dies yields zero result lines (caught by the count assertion)
# instead of a silently green table.
RESULTS="$TMP/results.txt"
run_with_timeout 60 node -e '
"use strict";
const fs = require("fs");
const { isCredentialPath, commandTouchesCredentials } = require(process.argv[1]);
const lines = fs.readFileSync(process.argv[2], "utf8").split(/\r?\n/);
for (const raw of lines) {
  const line = raw.trim();
  if (!line || line.startsWith("#")) continue;
  const p = line.split("|").map((s) => s.trim());
  const subject = p[2] || "";
  const got = p[0] === "path" ? isCredentialPath(subject) : commandTouchesCredentials(subject);
  process.stdout.write(p[1] + "|" + p[3] + "|" + (got ? "true" : "false") + "\n");
}
' "$MODULE" "$(topath "$TABLE")" >"$RESULTS" 2>"$TMP/err.txt"

GOT_LINES="$(grep -c . "$RESULTS" 2>/dev/null || printf '0')"
assert_eq "driver evaluated every table row" "$EXPECTED" "$GOT_LINES"
if [ "$GOT_LINES" = "0" ]; then
    echo "driver stderr: $(cat "$TMP/err.txt" 2>/dev/null)"
fi

while IFS='|' read -r name want got; do
    [ -n "$name" ] || continue
    assert_eq "$name" "$want" "$got"
done <"$RESULTS"

# CREDENTIALS_TABLE shape: the SSOT both hooks depend on must stay well-formed —
# a malformed entry would silently drop a whole credential family.
SHAPE="$(run_with_timeout 20 node -e '
const { CREDENTIALS_TABLE } = require(process.argv[1]);
const bad = CREDENTIALS_TABLE.filter((e) =>
  !e || typeof e.root !== "string" || !e.root.startsWith("~/") ||
  typeof e.displayName !== "string" || e.displayName === "");
process.stdout.write((CREDENTIALS_TABLE.length > 0 ? "ok" : "empty") + ":" + bad.length);
' "$MODULE" 2>/dev/null)"
assert_eq "CREDENTIALS_TABLE entries are well-formed" "ok:0" "$SHAPE"

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL"
exit "$FAIL"
